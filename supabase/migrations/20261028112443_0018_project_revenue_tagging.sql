-- GrokBooks 0018: project tagging for revenue (companion to 0017 expense tagging).
-- Same conventions as 0017: uuid PKs, company_id + composite FKs, created_at/updated_at +
-- set_updated_at trigger, RLS enabled with no policies, security_invoker views, no seed data.
--
-- revenue_projects: one row = "this invoice line (or deposit line) is credited to this project, for $X".
-- Exactly one of invoice_line_id / deposit_line_id is set (real foreign keys). Several rows per line = a split
-- across projects. The tagged amounts for one line can never exceed that line's amount.
-- Tagging an invoice header = tag each of its lines (header-level tags would duplicate the line-level ones).
--
-- Double counting: money can be tagged twice - once on the invoice and once on the deposit that paid it. The views
-- flag a deposit-line tag as counted_in_totals = false when the deposit line's payment is applied to an invoice that
-- has line tags on the SAME project (the invoice tag wins). Tags on voided invoices are also not counted.
-- Nothing is tagged by this migration.

-- 1) Composite (company_id, id) key on deposit_lines (invoice_lines already has one) ------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.deposit_lines'::regclass and conname = 'deposit_lines_company_id_id_key') then
    alter table public.deposit_lines add constraint deposit_lines_company_id_id_key unique (company_id, id);
  end if;
end $$;

-- 2) revenue_projects ----------------------------------------------------------------------------------------------
create table public.revenue_projects (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  project_id       uuid not null,
  invoice_line_id  uuid,
  deposit_line_id  uuid,
  amount           numeric(14,2) not null,   -- portion credited to the project; filled with the full line amount when omitted
  note             text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, id),
  check (num_nonnulls(invoice_line_id, deposit_line_id) = 1),
  unique (project_id, invoice_line_id),
  unique (project_id, deposit_line_id),
  foreign key (company_id, project_id)      references public.projects(company_id, id) on delete cascade,
  foreign key (company_id, invoice_line_id) references public.invoice_lines(company_id, id) on delete cascade,
  foreign key (company_id, deposit_line_id) references public.deposit_lines(company_id, id) on delete cascade
);
create index revenue_projects_company_project_idx on public.revenue_projects (company_id, project_id);
create index revenue_projects_invoice_line_idx    on public.revenue_projects (invoice_line_id) where invoice_line_id is not null;
create index revenue_projects_deposit_line_idx    on public.revenue_projects (deposit_line_id) where deposit_line_id is not null;

-- Amount handling mirrors expense_projects_check_amount(): amount defaults to the full line amount, must have the
-- same sign as the line (credit/discount lines are negative) and the tags on one line may not add up to more.
create or replace function public.revenue_projects_check_amount()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_src   numeric(14,2);
  v_other numeric(14,2);
  v_key   uuid := coalesce(new.invoice_line_id, new.deposit_line_id);
begin
  if num_nonnulls(new.invoice_line_id, new.deposit_line_id) <> 1 then
    raise exception 'revenue_projects needs exactly one of invoice_line_id, deposit_line_id'
      using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_key::text, 0));

  if new.invoice_line_id is not null then
    select amount into v_src from public.invoice_lines where id = new.invoice_line_id;
  else
    select amount into v_src from public.deposit_lines where id = new.deposit_line_id;
  end if;

  if new.amount is null then
    new.amount := v_src;
  end if;
  if new.amount is null or new.amount = 0 then
    raise exception 'revenue_projects.amount must be non-zero';
  end if;
  if v_src is null or v_src = 0 then
    return new;
  end if;
  if sign(new.amount) <> sign(v_src) then
    raise exception 'tagged amount % has the opposite sign of the line amount %', new.amount, v_src;
  end if;

  select coalesce(sum(abs(r.amount)), 0) into v_other
    from public.revenue_projects r
   where r.id is distinct from new.id
     and r.invoice_line_id is not distinct from new.invoice_line_id
     and r.deposit_line_id is not distinct from new.deposit_line_id;
  if v_other + abs(new.amount) > abs(v_src) then
    raise exception 'tagged amounts (%) would exceed the line amount (%)', v_other + abs(new.amount), abs(v_src);
  end if;
  return new;
end $$;

create trigger revenue_projects_check_amount
  before insert or update on public.revenue_projects
  for each row execute function public.revenue_projects_check_amount();

create trigger revenue_projects_set_updated_at
  before update on public.revenue_projects
  for each row execute function public.set_updated_at();
alter table public.revenue_projects enable row level security;

-- 3) Views (security_invoker) ---------------------------------------------------------------------------------------
-- project_revenue: one row per tagged invoice/deposit line.
create view public.project_revenue with (security_invoker = true) as
select r.id as tag_id, r.company_id, r.project_id, pr.name as project_name, pr.code as project_code,
       'invoice_line'::text as source_type, r.invoice_line_id as source_id,
       i.txn_date as revenue_date, c.display_name as customer, a.name as category,
       coalesce(il.description, i.private_note) as description,
       i.doc_number as reference,
       il.amount as revenue_amount, r.amount as project_amount, r.note,
       (i.voided_at is null) as counted_in_totals, r.created_at
  from public.revenue_projects r
  join public.projects pr on pr.company_id = r.company_id and pr.id = r.project_id
  join public.invoice_lines il on il.id = r.invoice_line_id
  join public.invoices i on i.id = il.invoice_id
  left join public.customers c on c.id = i.customer_id
  left join public.accounts a on a.id = il.account_id
union all
select r.id, r.company_id, r.project_id, pr.name, pr.code,
       'deposit_line', r.deposit_line_id,
       d.txn_date, c.display_name, a.name,
       coalesce(dl.description, d.private_note),
       dl.check_number,
       dl.amount, r.amount, r.note,
       not exists (            -- paid invoice already tagged to the same project => counted there, not here
         select 1
           from public.payment_applications pa
           join public.invoice_lines il2 on il2.invoice_id = pa.invoice_id
           join public.revenue_projects r2 on r2.invoice_line_id = il2.id and r2.project_id = r.project_id
          where pa.payment_id = dl.payment_id),
       r.created_at
  from public.revenue_projects r
  join public.projects pr on pr.company_id = r.company_id and pr.id = r.project_id
  join public.deposit_lines dl on dl.id = r.deposit_line_id
  join public.deposits d on d.id = dl.deposit_id
  left join public.customers c on c.id = dl.customer_id
  left join public.accounts a on a.id = dl.account_id;

-- project_profit: one row per project (including projects with no activity).
create view public.project_profit with (security_invoker = true) as
select pr.id as project_id, pr.company_id, pr.name, pr.code, pr.status, pr.customer_id,
       pr.start_date, pr.end_date, pr.budget,
       coalesce(rv.revenue_count, 0)                    as revenue_count,
       coalesce(rv.revenue_total, 0)::numeric(14,2)     as revenue_total,
       coalesce(et.expense_count, 0)                    as expense_count,
       coalesce(et.total_amount, 0)::numeric(14,2)      as expense_total,
       (coalesce(rv.revenue_total, 0) - coalesce(et.total_amount, 0))::numeric(14,2) as net,
       case when pr.budget is null then null
            else (pr.budget - coalesce(et.total_amount, 0))::numeric(14,2) end as budget_remaining
  from public.projects pr
  left join (select pv.company_id, pv.project_id, count(*) as revenue_count, sum(pv.project_amount) as revenue_total
               from public.project_revenue pv
              where pv.counted_in_totals
              group by pv.company_id, pv.project_id) rv
         on rv.company_id = pr.company_id and rv.project_id = pr.id
  left join public.project_expense_totals et
         on et.company_id = pr.company_id and et.project_id = pr.id;

comment on table public.revenue_projects is 'Tags one invoice line or deposit line to a project for an amount; several rows per line = a split.';
