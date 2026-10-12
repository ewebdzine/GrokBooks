-- migration 20261013000109_0010_general_ledger_reports
-- GrokBooks 0010: general ledger views and QuickBooks-style reports.
--   company_control_accounts  default A/R, A/P, Undeposited Funds and unapplied-cash accounts
--   gl_entries                accrual-basis general ledger (signed amount, debit, credit)
--   gl_entries_cash           cash-basis postings to income and expense accounts
--   report_profit_and_loss    P&L by total / month / customer, accrual or cash
--   report_sales_by_customer_detail  sales detail by customer, optional product filter
-- All views use security_invoker so row level security on the base tables applies.

create or replace view public.company_control_accounts
with (security_invoker = true) as
select c.id as company_id,
  (select a.id from public.accounts a where a.company_id = c.id and a.account_subtype = 'AccountsReceivable' order by a.account_number nulls last, a.name limit 1) as ar_account_id,
  (select a.id from public.accounts a where a.company_id = c.id and a.account_subtype = 'AccountsPayable' order by a.account_number nulls last, a.name limit 1) as ap_account_id,
  (select a.id from public.accounts a where a.company_id = c.id and a.account_subtype = 'UndepositedFunds' order by a.account_number nulls last, a.name limit 1) as undeposited_funds_account_id,
  (select a.id from public.accounts a where a.company_id = c.id and a.account_subtype = 'UnappliedCashPaymentIncome' order by a.account_number nulls last, a.name limit 1) as unapplied_cash_income_account_id,
  (select a.id from public.accounts a where a.company_id = c.id and a.account_subtype = 'UnappliedCashBillPaymentExpense' order by a.account_number nulls last, a.name limit 1) as unapplied_cash_bill_expense_account_id
from public.companies c;

create or replace view public.gl_entries
with (security_invoker = true) as
with e as (
  select i.company_id, 'invoice'::text as txn_type, i.id as txn_id, i.qbo_id as txn_qbo_id, i.txn_date, i.doc_number,
         l.id as line_id, l.line_num, l.account_id, -l.amount as amount, i.customer_id, null::uuid as vendor_id, l.item_id, l.description
    from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
   where i.voided_at is null
  union all
  select i.company_id, 'invoice', i.id, i.qbo_id, i.txn_date, i.doc_number,
         null, 0, coalesce(i.ar_account_id, ca.ar_account_id), i.total_amount, i.customer_id, null, null, null
    from public.invoices i join public.company_control_accounts ca on ca.company_id = i.company_id
   where i.voided_at is null and i.total_amount <> 0
  union all
  select p.company_id, 'payment', p.id, p.qbo_id, p.payment_date, p.reference,
         null, 1, coalesce(p.deposit_account_id, ca.undeposited_funds_account_id), p.amount, p.customer_id, null, null, p.memo
    from public.payments p join public.company_control_accounts ca on ca.company_id = p.company_id
  union all
  select p.company_id, 'payment', p.id, p.qbo_id, p.payment_date, p.reference,
         null, 2, coalesce(p.ar_account_id, ca.ar_account_id), -p.amount, p.customer_id, null, null, p.memo
    from public.payments p join public.company_control_accounts ca on ca.company_id = p.company_id
  union all
  select d.company_id, 'deposit', d.id, d.qbo_id, d.txn_date, null,
         null, 0, d.deposit_to_account_id, d.total_amount, null, null, null, d.private_note
    from public.deposits d
  union all
  select d.company_id, 'deposit', d.id, d.qbo_id, d.txn_date, l.check_number,
         l.id, l.line_num, l.account_id, -l.amount, l.customer_id, l.vendor_id, null, l.description
    from public.deposits d join public.deposit_lines l on l.deposit_id = d.id
  union all
  select p.company_id, 'purchase', p.id, p.qbo_id, p.txn_date, p.doc_number,
         null, 0, p.payment_account_id, case when p.is_credit then p.total_amount else -p.total_amount end, p.customer_id, p.vendor_id, null, p.private_note
    from public.purchases p
  union all
  select p.company_id, 'purchase', p.id, p.qbo_id, p.txn_date, p.doc_number,
         l.id, l.line_num, l.account_id, case when p.is_credit then -l.amount else l.amount end, coalesce(l.customer_id, p.customer_id), p.vendor_id, l.item_id, l.description
    from public.purchases p join public.purchase_lines l on l.purchase_id = p.id
  union all
  select b.company_id, 'bill', b.id, b.qbo_id, b.txn_date, b.doc_number,
         null, 0, coalesce(b.ap_account_id, ca.ap_account_id), -b.total_amount, null, b.vendor_id, null, b.private_note
    from public.bills b join public.company_control_accounts ca on ca.company_id = b.company_id
   where b.voided_at is null and b.total_amount <> 0
  union all
  select b.company_id, 'bill', b.id, b.qbo_id, b.txn_date, b.doc_number,
         l.id, l.line_num, l.account_id, l.amount, l.customer_id, b.vendor_id, l.item_id, l.description
    from public.bills b join public.bill_lines l on l.bill_id = b.id
   where b.voided_at is null
  union all
  select bp.company_id, 'bill_payment', bp.id, bp.qbo_id, bp.txn_date, bp.doc_number,
         null, 1, coalesce(bp.ap_account_id, ca.ap_account_id), bp.amount, null, bp.vendor_id, null, bp.private_note
    from public.bill_payments bp join public.company_control_accounts ca on ca.company_id = bp.company_id
  union all
  select bp.company_id, 'bill_payment', bp.id, bp.qbo_id, bp.txn_date, bp.doc_number,
         null, 2, bp.payment_account_id, -bp.amount, null, bp.vendor_id, null, bp.private_note
    from public.bill_payments bp
  union all
  select je.company_id, 'journal_entry', je.id, je.qbo_id, je.txn_date, je.doc_number,
         l.id, l.line_num, l.account_id, case when l.posting_type = 'debit' then l.amount else -l.amount end, l.customer_id, l.vendor_id, null, coalesce(l.description, je.private_note)
    from public.journal_entries je join public.journal_lines l on l.journal_entry_id = je.id
  union all
  select t.company_id, 'transfer', t.id, t.qbo_id, t.txn_date, null, null, 1, t.to_account_id, t.amount, null, null, null, t.private_note
    from public.transfers t
  union all
  select t.company_id, 'transfer', t.id, t.qbo_id, t.txn_date, null, null, 2, t.from_account_id, -t.amount, null, null, null, t.private_note
    from public.transfers t
)
select e.company_id, e.txn_type, e.txn_id, e.txn_qbo_id, e.txn_date, e.doc_number, e.line_id, e.line_num,
       e.account_id, e.customer_id, e.vendor_id, e.item_id, e.description,
       e.amount,
       greatest(e.amount, 0)::numeric(14,2) as debit,
       greatest(-e.amount, 0)::numeric(14,2) as credit
  from e
 where e.amount <> 0;

create or replace view public.gl_entries_cash
with (security_invoker = true) as
with pl as (
  select a.id from public.accounts a where a.classification in ('Revenue', 'Expense')
),
inv_app as (
  select p.company_id, p.id as payment_id, p.qbo_id as payment_qbo_id, p.payment_date, p.reference,
         i.id as invoice_id, i.doc_number, i.txn_date as invoice_date, i.customer_id, i.total_amount,
         pa.id as app_id, pa.amount_applied
    from public.payment_applications pa
    join public.payments p on p.id = pa.payment_id
    join public.invoices i on i.id = pa.invoice_id
   where i.voided_at is null and i.total_amount <> 0
),
inv_alloc as (
  select a.*, l.id as line_id, l.line_num, l.account_id, l.item_id, l.description,
         round(a.amount_applied * l.amount / a.total_amount, 2) as share,
         row_number() over (partition by a.app_id order by abs(l.amount) desc, l.line_num desc) as rn,
         sum(round(a.amount_applied * l.amount / a.total_amount, 2)) over (partition by a.app_id) as share_total
    from inv_app a join public.invoice_lines l on l.invoice_id = a.invoice_id
),
bill_app as (
  select bp.company_id, bp.id as bill_payment_id, bp.qbo_id as bp_qbo_id, bp.txn_date as paid_date, bp.doc_number as bp_doc,
         b.id as bill_id, b.doc_number, b.txn_date as bill_date, b.vendor_id, b.total_amount,
         ba.id as app_id, ba.amount_applied
    from public.bill_payment_applications ba
    join public.bill_payments bp on bp.id = ba.bill_payment_id
    join public.bills b on b.id = ba.bill_id
   where b.voided_at is null and b.total_amount <> 0
),
bill_alloc as (
  select a.*, l.id as line_id, l.line_num, l.account_id, l.item_id, l.description, l.customer_id,
         round(a.amount_applied * l.amount / a.total_amount, 2) as share,
         row_number() over (partition by a.app_id order by abs(l.amount) desc, l.line_num desc) as rn,
         sum(round(a.amount_applied * l.amount / a.total_amount, 2)) over (partition by a.app_id) as share_total
    from bill_app a join public.bill_lines l on l.bill_id = a.bill_id
),
e as (
  select g.company_id, g.txn_type, g.txn_id, g.txn_qbo_id, g.txn_date, g.doc_number, g.line_id, g.line_num,
         g.account_id, g.customer_id, g.vendor_id, g.item_id, g.description, g.amount
    from public.gl_entries g
   where g.txn_type in ('deposit', 'purchase', 'journal_entry', 'transfer')
     and g.account_id in (select id from pl)
  union all
  select a.company_id, 'payment', a.payment_id, a.payment_qbo_id, greatest(a.payment_date, a.invoice_date), a.doc_number,
         a.line_id, a.line_num, a.account_id, a.customer_id, null::uuid, a.item_id, a.description,
         -(a.share + case when a.rn = 1 then a.amount_applied - a.share_total else 0 end)
    from inv_alloc a
  union all
  select a.company_id, 'payment', a.payment_id, a.payment_qbo_id, a.payment_date, a.reference,
         null, null, ca.unapplied_cash_income_account_id, a.customer_id, null, null, 'Prepayment of invoice ' || coalesce(a.doc_number, ''),
         -a.amount_applied
    from inv_app a join public.company_control_accounts ca on ca.company_id = a.company_id
   where a.invoice_date > a.payment_date
  union all
  select a.company_id, 'payment', a.payment_id, a.payment_qbo_id, a.invoice_date, a.doc_number,
         null, null, ca.unapplied_cash_income_account_id, a.customer_id, null, null, 'Prepayment applied to invoice ' || coalesce(a.doc_number, ''),
         a.amount_applied
    from inv_app a join public.company_control_accounts ca on ca.company_id = a.company_id
   where a.invoice_date > a.payment_date
  union all
  select p.company_id, 'payment', p.id, p.qbo_id, p.payment_date, p.reference,
         null, null, ca.unapplied_cash_income_account_id, p.customer_id, null, null, 'Unapplied payment',
         -(p.amount - coalesce(x.applied, 0))
    from public.payments p
    join public.company_control_accounts ca on ca.company_id = p.company_id
    left join (select payment_id, sum(amount_applied) as applied from public.payment_applications group by 1) x on x.payment_id = p.id
   where p.amount - coalesce(x.applied, 0) <> 0
  union all
  select a.company_id, 'bill_payment', a.bill_payment_id, a.bp_qbo_id, greatest(a.paid_date, a.bill_date), a.doc_number,
         a.line_id, a.line_num, a.account_id, a.customer_id, a.vendor_id, a.item_id, a.description,
         a.share + case when a.rn = 1 then a.amount_applied - a.share_total else 0 end
    from bill_alloc a
  union all
  select a.company_id, 'bill_payment', a.bill_payment_id, a.bp_qbo_id, a.paid_date, a.bp_doc,
         null, null, ca.unapplied_cash_bill_expense_account_id, null, a.vendor_id, null, 'Prepayment of bill ' || coalesce(a.doc_number, ''),
         a.amount_applied
    from bill_app a join public.company_control_accounts ca on ca.company_id = a.company_id
   where a.bill_date > a.paid_date
  union all
  select a.company_id, 'bill_payment', a.bill_payment_id, a.bp_qbo_id, a.bill_date, a.doc_number,
         null, null, ca.unapplied_cash_bill_expense_account_id, null, a.vendor_id, null, 'Prepayment applied to bill ' || coalesce(a.doc_number, ''),
         -a.amount_applied
    from bill_app a join public.company_control_accounts ca on ca.company_id = a.company_id
   where a.bill_date > a.paid_date
  union all
  select bp.company_id, 'bill_payment', bp.id, bp.qbo_id, bp.txn_date, bp.doc_number,
         null, null, ca.unapplied_cash_bill_expense_account_id, null, bp.vendor_id, null, 'Unapplied bill payment',
         bp.amount - coalesce(x.applied, 0)
    from public.bill_payments bp
    join public.company_control_accounts ca on ca.company_id = bp.company_id
    left join (select bill_payment_id, sum(amount_applied) as applied from public.bill_payment_applications group by 1) x on x.bill_payment_id = bp.id
   where bp.amount - coalesce(x.applied, 0) <> 0
)
select e.company_id, e.txn_type, e.txn_id, e.txn_qbo_id, e.txn_date, e.doc_number, e.line_id, e.line_num,
       e.account_id, e.customer_id, e.vendor_id, e.item_id, e.description,
       e.amount,
       greatest(e.amount, 0)::numeric(14,2) as debit,
       greatest(-e.amount, 0)::numeric(14,2) as credit
  from e
 where e.amount <> 0
   and e.account_id in (select id from pl);

create or replace function public.report_profit_and_loss(
  p_company_id uuid,
  p_start date,
  p_end date,
  p_basis text default 'accrual',
  p_columns text default 'total'
)
returns table (
  row_no integer, row_type text, section text, depth integer, account_id uuid, label text,
  col_no integer, col_key text, col_label text, amount numeric(14,2)
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_basis not in ('accrual', 'cash') then
    raise exception 'p_basis must be accrual or cash' using errcode = 'invalid_parameter_value';
  end if;
  if p_columns not in ('total', 'month', 'customer') then
    raise exception 'p_columns must be total, month or customer' using errcode = 'invalid_parameter_value';
  end if;
  if p_end < p_start then
    raise exception 'p_end must be on or after p_start' using errcode = 'invalid_parameter_value';
  end if;

  return query
  with recursive
  sections(sec, sec_order, sign) as (
    values ('Income', 1, -1), ('Cost of Goods Sold', 2, 1), ('Expenses', 3, 1),
           ('Other Income', 4, -1), ('Other Expenses', 5, 1)
  ),
  acct as (
    select a.id, a.parent_id, a.account_number, a.name,
           coalesce(a.account_number || ' ', '') || a.name as acct_label,
           coalesce(a.account_number, '~') || ' ' || lower(a.name) as sort_key,
           case a.account_type
             when 'Income' then 'Income'
             when 'Cost of Goods Sold' then 'Cost of Goods Sold'
             when 'Expense' then 'Expenses'
             when 'Other Income' then 'Other Income'
             when 'Other Expense' then 'Other Expenses'
           end as sec
      from public.accounts a
     where a.company_id = p_company_id
  ),
  tree as (
    select a.id, a.parent_id, 0 as lvl, array[a.sort_key] as path, array[a.id] as lineage
      from acct a where a.parent_id is null
    union all
    select c.id, c.parent_id, t.lvl + 1, t.path || c.sort_key, t.lineage || c.id
      from acct c join tree t on c.parent_id = t.id
  ),
  entries as (
    select g.account_id, g.txn_date, g.customer_id, g.amount
      from public.gl_entries g
     where p_basis = 'accrual' and g.company_id = p_company_id and g.txn_date between p_start and p_end
    union all
    select g.account_id, g.txn_date, g.customer_id, g.amount
      from public.gl_entries_cash g
     where p_basis = 'cash' and g.company_id = p_company_id and g.txn_date between p_start and p_end
  ),
  pl_entries as (
    select e.*, a.sec, s.sign * e.amount as signed_amount,
           case p_columns
             when 'month' then to_char(e.txn_date, 'YYYY-MM')
             when 'customer' then coalesce(e.customer_id::text, '~none')
             else 'total'
           end as ckey
      from entries e join acct a on a.id = e.account_id join sections s on s.sec = a.sec
  ),
  cols as (
    select x.ckey as col_key, x.clabel as col_label, (row_number() over (order by x.csort collate "C"))::integer as col_no
      from (
        select to_char(m.d, 'YYYY-MM') as ckey,
               case
                 when m.d >= p_start and m.me <= p_end then to_char(m.d, 'Mon YYYY')
                 when greatest(m.d, p_start) = least(m.me, p_end) then to_char(greatest(m.d, p_start), 'Mon FMDD YYYY')
                 else to_char(greatest(m.d, p_start), 'Mon FMDD') || '-' || to_char(least(m.me, p_end), 'FMDD YYYY')
               end as clabel,
               to_char(m.d, 'YYYY-MM') as csort
          from (select gs::date as d, (gs + interval '1 month - 1 day')::date as me
                  from generate_series(date_trunc('month', p_start), p_end::timestamp, interval '1 month') gs) m
         where p_columns = 'month'
        union all
        select c.ckey, coalesce(cu.display_name, 'Not specified'),
               case when c.ckey = '~none' then '~~' else lower(cu.display_name) end
          from (select distinct pe.ckey from pl_entries pe where p_columns = 'customer') c
          left join public.customers cu on cu.id::text = c.ckey
      ) x
    union all
    select 'total', 'Total', 100000
  ),
  cells as (
    select pe.account_id, k.col_key, sum(pe.signed_amount) as amt
      from pl_entries pe
      cross join lateral (values (pe.ckey), ('total')) k(col_key)
     where p_columns <> 'total' or k.col_key = 'total'
     group by 1, 2
  ),
  used as (select distinct c.account_id as id from cells c),
  shown as (   -- used accounts plus their ancestors
    select distinct l.id from tree t join used u on u.id = t.id cross join lateral unnest(t.lineage) l(id)
  ),
  node as (
    select t.id, t.lvl, t.path, t.lineage, a.acct_label, a.sec, s.sec_order,
           exists (select 1 from tree c join shown sh on sh.id = c.id where c.parent_id = t.id) as has_children
      from tree t join shown sh on sh.id = t.id join acct a on a.id = t.id join sections s on s.sec = a.sec
  ),
  -- report lines: (sort tuple, type, label, depth, account, set of accounts summed)
  lines as (
    select n.sec_order::numeric as so, n.path as sk, case when n.has_children then 'parent_header' else 'account' end as rtype,
           n.sec, n.lvl + 1 as dpt, n.id as acc, n.acct_label as lbl, array[n.id] as members
      from node n
    union all
    select n.sec_order, n.path || '~~~~'::text, 'parent_total', n.sec, n.lvl + 1, n.id, 'Total for ' || n.acct_label,
           array(select d.id from tree d where n.id = any(d.lineage))
      from node n where n.has_children
    union all
    select s.sec_order, array['']::text[], 'section_header', s.sec, 0, null::uuid, s.sec, null::uuid[]
      from sections s where exists (select 1 from node n where n.sec = s.sec)
    union all
    select s.sec_order, array['~~~~~']::text[], 'section_total', s.sec, 0, null, 'Total for ' || s.sec,
           array(select a.id from acct a where a.sec = s.sec)
      from sections s where exists (select 1 from node n where n.sec = s.sec)
    union all
    select v.so, array['']::text[], 'computed', null, 0, null, v.lbl, null
      from (values (2.5, 'Gross Profit'), (3.5, 'Net Operating Income'), (5.5, 'Net Other Income'), (6.0, 'Net Income')) v(so, lbl)
     where v.lbl <> 'Net Other Income' or exists (select 1 from node n where n.sec in ('Other Income', 'Other Expenses'))
  ),
  numbered as (
    select l.*, (row_number() over (order by l.so, l.sk collate "C"))::integer as rn from lines l
  ),
  sec_tot as (
    select a.sec, c.col_key, sum(c.amt) as amt
      from cells c join acct a on a.id = c.account_id group by 1, 2
  ),
  calc as (
    select co.col_key,
           max(st.amt) filter (where st.sec = 'Income') as inc,
           max(st.amt) filter (where st.sec = 'Cost of Goods Sold') as cogs,
           max(st.amt) filter (where st.sec = 'Expenses') as exp,
           max(st.amt) filter (where st.sec = 'Other Income') as oinc,
           max(st.amt) filter (where st.sec = 'Other Expenses') as oexp
      from cols co left join sec_tot st on st.col_key = co.col_key
     group by co.col_key
  )
  select n.rn, n.rtype, n.sec, n.dpt, n.acc, n.lbl, co.col_no, co.col_key, co.col_label,
         (case
            when n.rtype in ('section_header') then null
            when n.rtype = 'parent_header' then (select sum(c.amt) from cells c where c.col_key = co.col_key and c.account_id = n.acc)
            when n.rtype in ('account', 'parent_total', 'section_total') then (select sum(c.amt) from cells c where c.col_key = co.col_key and c.account_id = any(n.members))
            when n.lbl = 'Gross Profit' then
              case when k.inc is null and k.cogs is null then null else coalesce(k.inc, 0) - coalesce(k.cogs, 0) end
            when n.lbl = 'Net Operating Income' then
              case when k.inc is null and k.cogs is null and k.exp is null then null else coalesce(k.inc, 0) - coalesce(k.cogs, 0) - coalesce(k.exp, 0) end
            when n.lbl = 'Net Other Income' then
              case when k.oinc is null and k.oexp is null then null else coalesce(k.oinc, 0) - coalesce(k.oexp, 0) end
            when n.lbl = 'Net Income' then
              case when k.inc is null and k.cogs is null and k.exp is null and k.oinc is null and k.oexp is null then null
                   else coalesce(k.inc, 0) - coalesce(k.cogs, 0) - coalesce(k.exp, 0) + coalesce(k.oinc, 0) - coalesce(k.oexp, 0) end
          end)::numeric(14,2)
    from numbered n
    cross join cols co
    join calc k on k.col_key = co.col_key
   order by n.rn, co.col_no;
end
$$;

create or replace function public.report_sales_by_customer_detail(
  p_company_id uuid,
  p_start date,
  p_end date,
  p_item_name text default null,
  p_sort text default 'num'
)
returns table (
  row_no integer, row_type text, customer_id uuid, customer_name text, txn_date date,
  txn_type text, doc_number text, product_service text, description text, qty numeric, amount numeric(14,2)
)
language sql
stable
security invoker
set search_path = ''
as $$
  with d as (
    select i.customer_id, c.display_name, i.txn_date, i.doc_number, it.fully_qualified_name as product, it.name as item_name,
           l.description, l.qty, l.amount, l.line_num,
           case when i.doc_number ~ '^[0-9]+$' then lpad(i.doc_number, 20, '0') else coalesce(i.doc_number, '') end as num_key
      from public.invoices i
      join public.invoice_lines l on l.invoice_id = i.id
      join public.customers c on c.id = i.customer_id
      left join public.items it on it.id = l.item_id
     where i.company_id = p_company_id
       and i.voided_at is null
       and i.txn_date between p_start and p_end
       and (p_item_name is null or it.name = p_item_name or it.fully_qualified_name = p_item_name)
  ),
  cust as (
    select d.customer_id, d.display_name,
           row_number() over (order by
             case p_sort when 'num' then min(d.num_key) when 'date' then to_char(min(d.txn_date), 'YYYYMMDD') else lower(d.display_name) end,
             lower(d.display_name)) as corder,
           sum(d.amount) as total
      from d group by 1, 2
  ),
  r as (
    select c.corder, 0 as part, ''::text as k1, 0 as k2, 'customer_header'::text as rtype, c.customer_id, c.display_name,
           null::date as txn_date, null::text as txn_type, null::text as doc_number, null::text as product, null::text as description, null::numeric as qty, null::numeric as amount
      from cust c
    union all
    select c.corder, 1,
           case p_sort when 'date' then to_char(d.txn_date, 'YYYYMMDD') || d.num_key else d.num_key || to_char(d.txn_date, 'YYYYMMDD') end,
           d.line_num, 'detail', d.customer_id, d.display_name, d.txn_date, 'Invoice', d.doc_number, d.product, d.description, d.qty, d.amount
      from d join cust c on c.customer_id = d.customer_id
    union all
    select c.corder, 2, '', 0, 'customer_total', c.customer_id, c.display_name, null, null, null, null, null, null, c.total
      from cust c
    union all
    select 1e9, 3, '', 0, 'grand_total', null, null, null, null, null, null, null, null, (select sum(total) from cust)
     where exists (select 1 from cust)
  )
  select (row_number() over (order by r.corder, r.part, r.k1, r.k2))::integer, r.rtype, r.customer_id, r.display_name,
         r.txn_date, r.txn_type, r.doc_number, r.product, r.description, r.qty, r.amount::numeric(14,2)
    from r
   order by 1;
$$;
