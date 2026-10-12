-- migration 20261013000117_0013_journal_line_invoice_link
-- Let journal lines (write-offs, credit adjustments) be applied against a specific invoice so
-- invoice_balances reflects them. Generic, company-scoped; no effect on invoices without linked lines.
alter table public.journal_lines add column if not exists invoice_id uuid;
alter table public.journal_lines
  add constraint journal_lines_company_id_invoice_id_fkey
  foreign key (company_id, invoice_id) references public.invoices(company_id, id) on delete set null (invoice_id);
create index if not exists journal_lines_company_invoice_idx on public.journal_lines (company_id, invoice_id) where invoice_id is not null;
comment on column public.journal_lines.invoice_id is 'Optional: invoice this A/R line adjusts (write-off, credit memo stand-in). Credit reduces the invoice balance in invoice_balances; debit increases it.';

create or replace view public.invoice_balances with (security_invoker = true) as
with pa as (
  select invoice_id, sum(amount_applied) amt, min(applied_on) first_d, max(applied_on) last_d
  from public.payment_applications group by invoice_id
), adj as (
  select invoice_id, sum(case when posting_type = 'credit' then amount else -amount end) amt
  from public.journal_lines where invoice_id is not null group by invoice_id
)
select i.id as invoice_id,
  i.company_id, i.customer_id, i.doc_number, i.txn_date, i.due_date, i.total_amount,
  coalesce(pa.amt, 0::numeric) as amount_paid,
  i.total_amount - coalesce(pa.amt, 0::numeric) - coalesce(adj.amt, 0::numeric) as balance,
  case
    when i.voided_at is not null then 'void'
    when coalesce(adj.amt, 0::numeric) <> 0 and i.total_amount - coalesce(pa.amt, 0::numeric) - coalesce(adj.amt, 0::numeric) <= 0 and coalesce(pa.amt, 0::numeric) < i.total_amount then 'written_off'
    when coalesce(pa.amt, 0::numeric) = 0 and coalesce(adj.amt, 0::numeric) = 0 and i.total_amount > 0 then 'unpaid'
    when coalesce(pa.amt, 0::numeric) + coalesce(adj.amt, 0::numeric) < i.total_amount then 'partial'
    else 'paid'
  end as status,
  pa.first_d as first_payment_date,
  pa.last_d as last_payment_date,
  coalesce(adj.amt, 0::numeric) as amount_adjusted
from public.invoices i
left join pa on pa.invoice_id = i.id
left join adj on adj.invoice_id = i.id;
