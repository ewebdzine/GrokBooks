-- GrokBooks 0019: project vendors (many-to-many between projects and vendors).
-- Same conventions as 0017/0018: uuid PK, company_id + composite FKs, created_at/updated_at +
-- set_updated_at trigger, RLS enabled with no policies, security_invoker view, no seed data.
--
-- vendors has no contractor flag (only is_1099), so contractors are simply vendors; this table says which
-- vendors work on which project. A vendor can be on many projects; a project can have many vendors.
-- Nothing is assigned or tagged by this migration, and there are no auto-tag rules.

create table public.project_vendors (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  project_id       uuid not null,
  vendor_id        uuid not null,
  role             text,                          -- free text, e.g. 'electrician'
  contract_amount  numeric(14,2) check (contract_amount is null or contract_amount >= 0),
  status           text not null default 'active' check (status in ('active','completed','removed')),
  start_date       date,
  end_date         date,
  note             text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, id),
  unique (project_id, vendor_id),
  check (end_date is null or start_date is null or end_date >= start_date),
  foreign key (company_id, project_id) references public.projects(company_id, id) on delete cascade,
  foreign key (company_id, vendor_id)  references public.vendors(company_id, id)
);
create index project_vendors_company_vendor_idx on public.project_vendors (company_id, vendor_id);

create trigger project_vendors_set_updated_at
  before update on public.project_vendors
  for each row execute function public.set_updated_at();
alter table public.project_vendors enable row level security;

-- project_vendor_summary: one row per assigned vendor per project, with that vendor's tagged spend on the project.
-- Spend = expense_projects tags whose expense resolves to the vendor (purchase -> purchases.vendor_id,
-- bill line -> bills.vendor_id, journal line -> journal_lines.vendor_id). Bank-feed rows carry only a free-text
-- payee, so they are not attributed to a vendor until matched to a book entry that is tagged instead.
create view public.project_vendor_summary with (security_invoker = true) as
select pv.id as project_vendor_id, pv.company_id, pv.project_id, pr.name as project_name, pr.code as project_code,
       pv.vendor_id, v.display_name as vendor, pv.role, pv.status,
       pv.start_date, pv.end_date, pv.contract_amount,
       coalesce(sp.expense_count, 0)                    as expense_count,
       coalesce(sp.spend, 0)::numeric(14,2)             as spend,
       case when pv.contract_amount is null then null
            else (pv.contract_amount - coalesce(sp.spend, 0))::numeric(14,2) end as contract_remaining,
       sp.last_expense_date,
       pv.note
  from public.project_vendors pv
  join public.projects pr on pr.company_id = pv.company_id and pr.id = pv.project_id
  join public.vendors v   on v.company_id = pv.company_id and v.id = pv.vendor_id
  left join (
    select x.company_id, x.project_id, x.vendor_id,
           count(*) as expense_count, sum(x.amount) as spend, max(x.expense_date) as last_expense_date
      from (
        select e.company_id, e.project_id, p.vendor_id, e.amount, p.txn_date as expense_date
          from public.expense_projects e
          join public.purchase_lines pl on pl.id = e.purchase_line_id
          join public.purchases p on p.id = pl.purchase_id
        union all
        select e.company_id, e.project_id, b.vendor_id, e.amount, b.txn_date
          from public.expense_projects e
          join public.bill_lines bl on bl.id = e.bill_line_id
          join public.bills b on b.id = bl.bill_id
        union all
        select e.company_id, e.project_id, jl.vendor_id, e.amount, je.txn_date
          from public.expense_projects e
          join public.journal_lines jl on jl.id = e.journal_line_id
          join public.journal_entries je on je.id = jl.journal_entry_id
      ) x
     where x.vendor_id is not null
     group by x.company_id, x.project_id, x.vendor_id
  ) sp on sp.company_id = pv.company_id and sp.project_id = pv.project_id and sp.vendor_id = pv.vendor_id;

comment on table public.project_vendors is 'Which vendors/contractors are assigned to which project (many-to-many), with optional role and contract amount.';
