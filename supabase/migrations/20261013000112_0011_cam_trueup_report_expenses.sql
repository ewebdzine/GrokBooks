-- migration 20261013000112_0011_cam_trueup_report_expenses
create or replace function public.report_cam_expenses(p_property_id uuid, p_year integer)
returns table (
  row_no integer, row_type text, pool_code text, label text,
  m01 numeric(14,2), m02 numeric(14,2), m03 numeric(14,2), m04 numeric(14,2), m05 numeric(14,2), m06 numeric(14,2),
  m07 numeric(14,2), m08 numeric(14,2), m09 numeric(14,2), m10 numeric(14,2), m11 numeric(14,2), m12 numeric(14,2),
  total numeric(14,2), note text
)
language sql stable security invoker set search_path = ''
as $$
  with yr as (select make_date(p_year, 1, 1) as ys, make_date(p_year, 12, 31) as ye),
  p as (select * from public.cam_pool_amounts(p_property_id, p_year)),
  admin_pct as (select public.cam_default_admin_fee_pct(p_property_id, p_year) as pct),
  acct as (
    select pa.pool_id, a.id as account_id, coalesce(a.account_number || ' ', '') || a.name as label, a.account_number,
           greatest(yr.ys, pa.effective_from) as d1, least(yr.ye, coalesce(pa.effective_to, yr.ye)) as d2
      from public.cam_pool_accounts pa join public.accounts a on a.id = pa.account_id
      join p on p.pool_id = pa.pool_id cross join yr
  ),
  am as (
    select ac.pool_id, ac.account_id, ac.label, ac.account_number, extract(month from g.txn_date)::int as m, sum(g.amount) as amt
      from acct ac
      left join public.gl_entries g on g.account_id = ac.account_id and g.txn_date between ac.d1 and ac.d2
     group by 1, 2, 3, 4, 5
  ),
  adj as (
    select a.pool_id, a.month as m, a.reason, sum(a.amount) as amt from public.cam_expense_adjustments a
     where a.property_id = p_property_id and a.cam_year = p_year group by 1, 2, 3
  ),
  rws as (
    -- account rows
    select p.sort_order, 1 as part, coalesce(am.account_number, am.label) as k, 'account'::text as rtype, p.pool_code, am.label,
           am.m, am.amt,
           case when p.amount_basis = 'tax_bill' then 'GL cash paid (informational; tax bill used)' end as note
      from p join am on am.pool_id = p.pool_id
    union all
    select p.sort_order, 2, adj.reason, 'adjustment', p.pool_code, 'Adjustment: ' || adj.reason, adj.m, adj.amt, null
      from p join adj on adj.pool_id = p.pool_id
    union all
    select p.sort_order, 3, '', 'tax_bill', p.pool_code, 'Real estate tax bill (overrides GL)', null, p.tax_bill_amount,
           'GL paid ' || to_char(p.gl_amount, 'FM999,999,990.00') || '; difference ' || to_char(p.gl_amount - p.tax_bill_amount, 'FM999,999,990.00')
      from p where p.amount_basis = 'tax_bill'
  ),
  pivot as (
    select r.sort_order, r.part, r.k, r.rtype, r.pool_code, r.label, r.note,
           sum(r.amt) filter (where r.m = 1) m01, sum(r.amt) filter (where r.m = 2) m02, sum(r.amt) filter (where r.m = 3) m03,
           sum(r.amt) filter (where r.m = 4) m04, sum(r.amt) filter (where r.m = 5) m05, sum(r.amt) filter (where r.m = 6) m06,
           sum(r.amt) filter (where r.m = 7) m07, sum(r.amt) filter (where r.m = 8) m08, sum(r.amt) filter (where r.m = 9) m09,
           sum(r.amt) filter (where r.m = 10) m10, sum(r.amt) filter (where r.m = 11) m11, sum(r.amt) filter (where r.m = 12) m12,
           coalesce(sum(r.amt), 0) as total
      from rws r group by 1, 2, 3, 4, 5, 6, 7
  ),
  pool_month as (   -- monthly pool totals for GL-based pools
    select r.pool_code, r.m, sum(r.amt) as amt from rws r where r.rtype in ('account', 'adjustment') group by 1, 2
  ),
  totals as (
    select p.sort_order, 9 as part, '' as k, 'pool_total' as rtype, p.pool_code, 'Total ' || p.statement_label as label,
           case p.amount_basis when 'tax_bill' then 'Tax bill basis' when 'gl_no_tax_bill' then 'No tax bill on file; GL used' end as note,
           pm.*
      from p
      left join lateral (
        select sum(x.amt) filter (where x.m = 1 and p.amount_basis <> 'tax_bill') m01, sum(x.amt) filter (where x.m = 2 and p.amount_basis <> 'tax_bill') m02,
               sum(x.amt) filter (where x.m = 3 and p.amount_basis <> 'tax_bill') m03, sum(x.amt) filter (where x.m = 4 and p.amount_basis <> 'tax_bill') m04,
               sum(x.amt) filter (where x.m = 5 and p.amount_basis <> 'tax_bill') m05, sum(x.amt) filter (where x.m = 6 and p.amount_basis <> 'tax_bill') m06,
               sum(x.amt) filter (where x.m = 7 and p.amount_basis <> 'tax_bill') m07, sum(x.amt) filter (where x.m = 8 and p.amount_basis <> 'tax_bill') m08,
               sum(x.amt) filter (where x.m = 9 and p.amount_basis <> 'tax_bill') m09, sum(x.amt) filter (where x.m = 10 and p.amount_basis <> 'tax_bill') m10,
               sum(x.amt) filter (where x.m = 11 and p.amount_basis <> 'tax_bill') m11, sum(x.amt) filter (where x.m = 12 and p.amount_basis <> 'tax_bill') m12,
               p.pool_amount as total
          from pool_month x where x.pool_code = p.pool_code
      ) pm on true
  ),
  allrows as (
    select * from pivot
    union all
    select * from totals
    union all
    select 90000, 0, '', 'subtotal', null, 'Total pool expenses',
           case when exists (select 1 from p where p.amount_basis = 'tax_bill') then 'Monthly columns exclude tax-bill pools' end,
           sum(t.m01), sum(t.m02), sum(t.m03), sum(t.m04), sum(t.m05), sum(t.m06), sum(t.m07), sum(t.m08), sum(t.m09), sum(t.m10), sum(t.m11), sum(t.m12),
           sum(t.total)
      from totals t
    union all
    select 90001, 0, '', 'admin_fee', 'ADMIN',
           'Administrative fee (' || to_char((select pct from admin_pct) * 100, 'FM990.##') || '% of ' ||
             coalesce((select string_agg(p.statement_label, ', ' order by p.sort_order) from p where p.admin_fee_eligible), 'none') || ')', null,
           round(sum(t.m01) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m02) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(sum(t.m03) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m04) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(sum(t.m05) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m06) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(sum(t.m07) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m08) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(sum(t.m09) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m10) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(sum(t.m11) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2), round(sum(t.m12) filter (where e.admin_fee_eligible) * (select pct from admin_pct), 2),
           round(coalesce(sum(t.total) filter (where e.admin_fee_eligible), 0) * (select pct from admin_pct), 2)
      from totals t join p e on e.pool_code = t.pool_code
  )
  select (row_number() over (order by a.sort_order, a.part, a.k collate "C"))::integer, a.rtype, a.pool_code, a.label,
         a.m01, a.m02, a.m03, a.m04, a.m05, a.m06, a.m07, a.m08, a.m09, a.m10, a.m11, a.m12, a.total, a.note
    from allrows a
  union all
  select 1000000, 'grand_total', null, 'Total CAM, taxes and insurance (incl. admin fee)',
         null, null, null, null, null, null, null, null, null, null, null, null,
         (select sum(t.total) from allrows t where t.rtype in ('subtotal', 'admin_fee')), null
   order by 1;
$$;
