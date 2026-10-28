-- GrokBooks 0017: project tagging for expenses.
-- Same conventions as 0001/0012/0014: uuid PKs, company_id + composite FKs, created_at/updated_at +
-- set_updated_at trigger, RLS enabled with no policies (deny by default; service role / postgres bypass).
--
-- Model
--   projects          one row per project/job (name, optional code, optional customer, status, dates, budget).
--   expense_projects  link table: one row = "this expense LINE (or bank row) is charged to this project, for $X".
--                     Exactly one of purchase_line_id / bill_line_id / journal_line_id / bank_transaction_id is set
--                     (real foreign keys, not a polymorphic string). Several rows per line = a split across projects.
--   project_expenses / project_expense_totals / project_expense_by_category: read-only reporting views.
--
-- No seed data. Nothing is tagged by this migration.

-- 1) Composite (company_id, id) keys on the expense tables so the link table can use company-scoped FKs ---------
do $$
declare t text;
begin
  foreach t in array array['purchase_lines','bill_lines','journal_lines','bank_transactions'] loop
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || t)::regclass and conname = t || '_company_id_id_key') then
      execute format('alter table public.%I add constraint %I unique (company_id, id)', t, t || '_company_id_id_key');
    end if;
  end loop;
end $$;

-- 2) projects -------------------------------------------------------------------------------------------------
create table public.projects (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  name         text not null check (length(btrim(name)) > 0),
  code         text,
  customer_id  uuid,                                   -- optional: who the project is for
  description  text,
  status       text not null default 'active' check (status in ('active','closed','archived')),
  start_date   date,
  end_date     date,
  budget       numeric(14,2) check (budget is null or budget >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, name),
  check (end_date is null or start_date is null or end_date >= start_date),
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create unique index projects_company_code_key on public.projects (company_id, code) where code is not null;
create index projects_company_status_idx on public.projects (company_id, status);
create index projects_company_customer_idx on public.projects (company_id, customer_id) where customer_id is not null;

-- 3) expense_projects (the reference table) -------------------------------------------------------------------
create table public.expense_projects (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references public.companies(id) on delete cascade,
  project_id           uuid not null,
  purchase_line_id     uuid,        -- expense / check / card purchase line
  bill_line_id         uuid,        -- vendor bill line
  journal_line_id      uuid,        -- journal entry line
  bank_transaction_id  uuid,        -- bank-feed row (useful before it is matched to a book entry)
  amount               numeric(14,2) not null,   -- portion charged to the project; filled with the full amount when omitted
  note                 text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (company_id, id),
  -- exactly one expense reference
  check (num_nonnulls(purchase_line_id, bill_line_id, journal_line_id, bank_transaction_id) = 1),
  -- the same line can be tagged to a given project only once (split a line across DIFFERENT projects)
  unique (project_id, purchase_line_id),
  unique (project_id, bill_line_id),
  unique (project_id, journal_line_id),
  unique (project_id, bank_transaction_id),
  foreign key (company_id, project_id)          references public.projects(company_id, id) on delete cascade,
  foreign key (company_id, purchase_line_id)    references public.purchase_lines(company_id, id) on delete cascade,
  foreign key (company_id, bill_line_id)        references public.bill_lines(company_id, id) on delete cascade,
  foreign key (company_id, journal_line_id)     references public.journal_lines(company_id, id) on delete cascade,
  foreign key (company_id, bank_transaction_id) references public.bank_transactions(company_id, id) on delete cascade
);
create index expense_projects_company_project_idx on public.expense_projects (company_id, project_id);
create index expense_projects_purchase_line_idx   on public.expense_projects (purchase_line_id)    where purchase_line_id is not null;
create index expense_projects_bill_line_idx       on public.expense_projects (bill_line_id)        where bill_line_id is not null;
create index expense_projects_journal_line_idx    on public.expense_projects (journal_line_id)     where journal_line_id is not null;
create index expense_projects_bank_txn_idx        on public.expense_projects (bank_transaction_id) where bank_transaction_id is not null;

-- Amount handling: expense amounts are positive for money spent (refund/credit lines are negative).
--   purchase_line -> amount (negated when the purchase is a credit)    bill_line -> amount
--   journal_line  -> amount if debit, negated if credit                 bank_transaction -> -amount (outflows are negative in the feed)
-- When amount is omitted it defaults to the full source amount. The tagged amounts for one expense line may
-- not exceed that line's amount (so a split can never over-allocate) and must have the same sign.
create or replace function public.expense_projects_check_amount()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_src   numeric(14,2);
  v_other numeric(14,2);
  v_key   uuid := coalesce(new.purchase_line_id, new.bill_line_id, new.journal_line_id, new.bank_transaction_id);
begin
  if num_nonnulls(new.purchase_line_id, new.bill_line_id, new.journal_line_id, new.bank_transaction_id) <> 1 then
    raise exception 'expense_projects needs exactly one of purchase_line_id, bill_line_id, journal_line_id, bank_transaction_id'
      using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_key::text, 0));

  if new.purchase_line_id is not null then
    select case when p.is_credit then -pl.amount else pl.amount end into v_src
      from public.purchase_lines pl join public.purchases p on p.id = pl.purchase_id
     where pl.id = new.purchase_line_id;
  elsif new.bill_line_id is not null then
    select amount into v_src from public.bill_lines where id = new.bill_line_id;
  elsif new.journal_line_id is not null then
    select case when posting_type = 'debit' then amount else -amount end into v_src
      from public.journal_lines where id = new.journal_line_id;
  else
    select -amount into v_src from public.bank_transactions where id = new.bank_transaction_id;
  end if;

  if new.amount is null then
    new.amount := v_src;
  end if;
  if new.amount is null or new.amount = 0 then
    raise exception 'expense_projects.amount must be non-zero';
  end if;
  if v_src is null or v_src = 0 then
    return new;   -- nothing to compare against
  end if;
  if sign(new.amount) <> sign(v_src) then
    raise exception 'tagged amount % has the opposite sign of the expense amount %', new.amount, v_src;
  end if;

  select coalesce(sum(abs(e.amount)), 0) into v_other
    from public.expense_projects e
   where e.id is distinct from new.id
     and e.purchase_line_id    is not distinct from new.purchase_line_id
     and e.bill_line_id        is not distinct from new.bill_line_id
     and e.journal_line_id     is not distinct from new.journal_line_id
     and e.bank_transaction_id is not distinct from new.bank_transaction_id;
  if v_other + abs(new.amount) > abs(v_src) then
    raise exception 'tagged amounts (%) would exceed the expense amount (%)', v_other + abs(new.amount), abs(v_src);
  end if;
  return new;
end $$;

create trigger expense_projects_check_amount
  before insert or update on public.expense_projects
  for each row execute function public.expense_projects_check_amount();

do $$
declare t text;
begin
  foreach t in array array['projects','expense_projects'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- 4) Reporting views (security_invoker: they honor the caller's RLS) ---------------------------------------------
-- One row per tagged expense line. counted_in_totals is false for a tagged bank-feed row that is already matched to a
-- book entry (purchase/bill payment/etc.), so the same dollars are not counted twice if the book entry is tagged too.
create view public.project_expenses with (security_invoker = true) as
select e.id as tag_id, e.company_id, e.project_id, pr.name as project_name, pr.code as project_code,
       'purchase_line'::text as source_type, e.purchase_line_id as source_id,
       p.txn_date as expense_date, v.display_name as vendor, a.name as category,
       coalesce(pl.description, p.private_note) as description,
       case when p.is_credit then -pl.amount else pl.amount end as expense_amount,
       e.amount as project_amount, e.note, true as counted_in_totals, e.created_at
  from public.expense_projects e
  join public.projects pr on pr.company_id = e.company_id and pr.id = e.project_id
  join public.purchase_lines pl on pl.id = e.purchase_line_id
  join public.purchases p on p.id = pl.purchase_id
  left join public.vendors v on v.id = p.vendor_id
  left join public.accounts a on a.id = pl.account_id
union all
select e.id, e.company_id, e.project_id, pr.name, pr.code,
       'bill_line', e.bill_line_id,
       b.txn_date, v.display_name, a.name,
       coalesce(bl.description, b.private_note),
       bl.amount, e.amount, e.note, true, e.created_at
  from public.expense_projects e
  join public.projects pr on pr.company_id = e.company_id and pr.id = e.project_id
  join public.bill_lines bl on bl.id = e.bill_line_id
  join public.bills b on b.id = bl.bill_id
  left join public.vendors v on v.id = b.vendor_id
  left join public.accounts a on a.id = bl.account_id
union all
select e.id, e.company_id, e.project_id, pr.name, pr.code,
       'journal_line', e.journal_line_id,
       je.txn_date, v.display_name, a.name,
       coalesce(jl.description, je.private_note),
       case when jl.posting_type = 'debit' then jl.amount else -jl.amount end, e.amount, e.note, true, e.created_at
  from public.expense_projects e
  join public.projects pr on pr.company_id = e.company_id and pr.id = e.project_id
  join public.journal_lines jl on jl.id = e.journal_line_id
  join public.journal_entries je on je.id = jl.journal_entry_id
  left join public.vendors v on v.id = jl.vendor_id
  left join public.accounts a on a.id = jl.account_id
union all
select e.id, e.company_id, e.project_id, pr.name, pr.code,
       'bank_transaction', e.bank_transaction_id,
       bt.posted_date, bt.payee, 'Uncategorized (bank feed)'::text,
       bt.description,
       -bt.amount, e.amount, e.note, (bt.matched_txn_type is null), e.created_at
  from public.expense_projects e
  join public.projects pr on pr.company_id = e.company_id and pr.id = e.project_id
  join public.bank_transactions bt on bt.id = e.bank_transaction_id;

-- One row per project (including projects with no expenses yet).
create view public.project_expense_totals with (security_invoker = true) as
select pr.id as project_id, pr.company_id, pr.name, pr.code, pr.status, pr.customer_id,
       pr.start_date, pr.end_date, pr.budget,
       count(pe.tag_id)                                   as expense_count,
       coalesce(sum(pe.project_amount), 0)::numeric(14,2) as total_amount,
       case when pr.budget is null then null
            else (pr.budget - coalesce(sum(pe.project_amount), 0))::numeric(14,2) end as budget_remaining,
       min(pe.expense_date) as first_expense_date,
       max(pe.expense_date) as last_expense_date
  from public.projects pr
  left join public.project_expenses pe
         on pe.project_id = pr.id and pe.company_id = pr.company_id and pe.counted_in_totals
 group by pr.id;

-- Per project and category (account).
create view public.project_expense_by_category with (security_invoker = true) as
select pe.company_id, pe.project_id, pe.project_name, pe.category,
       count(*) as expense_count,
       sum(pe.project_amount)::numeric(14,2) as total_amount
  from public.project_expenses pe
 where pe.counted_in_totals
 group by pe.company_id, pe.project_id, pe.project_name, pe.category;

comment on table public.projects is 'Projects/jobs that expenses can be charged to.';
comment on table public.expense_projects is 'Tags one expense line (purchase line, bill line, journal line or bank row) to a project for an amount; several rows per line = a split.';
