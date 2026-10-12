-- migration 20261013000113_0011_cam_trueup_reports
create or replace function public.report_cam_income(p_property_id uuid, p_year integer)
returns table (
  row_no integer, row_type text, lease_id uuid, customer_id uuid, suite_number text, tenant_name text,
  m01 numeric(14,2), m02 numeric(14,2), m03 numeric(14,2), m04 numeric(14,2), m05 numeric(14,2), m06 numeric(14,2),
  m07 numeric(14,2), m08 numeric(14,2), m09 numeric(14,2), m10 numeric(14,2), m11 numeric(14,2), m12 numeric(14,2),
  total numeric(14,2), invoice_count integer, note text
)
language sql stable security invoker set search_path = ''
as $$
  with pr as (select * from public.properties where id = p_property_id),
  l as (select * from public.cam_leases_for_year(p_property_id, p_year)),
  li as (
    select i.customer_id, i.id as invoice_id, extract(month from i.txn_date)::int as m, il.amount
      from public.invoices i
      join public.invoice_lines il on il.invoice_id = i.id
      left join public.items it on it.id = il.item_id
      cross join pr
     where i.company_id = pr.company_id and i.voided_at is null
       and i.txn_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31)
       and coalesce(il.account_id, it.income_account_id) = pr.cam_income_account_id
  ),
  who as (   -- one row per lease, plus customers billed CAM without a lease in this property
    select l.lease_id, l.customer_id, l.suite_number, l.tenant_name, null::text as note from l
    union all
    select null, x.customer_id, null, c.display_name, 'CAM billed but no lease in this property'
      from (select distinct li.customer_id from li) x join public.customers c on c.id = x.customer_id
     where x.customer_id not in (select l.customer_id from l)
  ),
  agg as (
    select w.lease_id, w.customer_id, w.suite_number, w.tenant_name, w.note,
           sum(li.amount) filter (where li.m = 1) m01, sum(li.amount) filter (where li.m = 2) m02, sum(li.amount) filter (where li.m = 3) m03,
           sum(li.amount) filter (where li.m = 4) m04, sum(li.amount) filter (where li.m = 5) m05, sum(li.amount) filter (where li.m = 6) m06,
           sum(li.amount) filter (where li.m = 7) m07, sum(li.amount) filter (where li.m = 8) m08, sum(li.amount) filter (where li.m = 9) m09,
           sum(li.amount) filter (where li.m = 10) m10, sum(li.amount) filter (where li.m = 11) m11, sum(li.amount) filter (where li.m = 12) m12,
           coalesce(sum(li.amount), 0) as total, count(distinct li.invoice_id)::int as n
      from who w left join li on li.customer_id = w.customer_id
     group by 1, 2, 3, 4, 5
  )
  select (row_number() over (order by a.suite_number nulls last, a.tenant_name))::integer, 'tenant', a.lease_id, a.customer_id, a.suite_number, a.tenant_name,
         a.m01, a.m02, a.m03, a.m04, a.m05, a.m06, a.m07, a.m08, a.m09, a.m10, a.m11, a.m12, a.total, a.n, a.note
    from agg a
  union all
  select 1000000, 'total', null, null, null, 'Total CAM estimates billed',
         sum(a.m01), sum(a.m02), sum(a.m03), sum(a.m04), sum(a.m05), sum(a.m06), sum(a.m07), sum(a.m08), sum(a.m09), sum(a.m10), sum(a.m11), sum(a.m12),
         sum(a.total), sum(a.n)::int, null
    from agg a
   order by 1;
$$;

create or replace function public.report_cam_allocation(p_property_id uuid, p_year integer)
returns table (
  row_no integer, row_type text, lease_id uuid, suite_number text, tenant_name text, status text,
  owner_occupied boolean, cam_billable boolean, sf numeric(12,2), building_sf numeric(12,2),
  occupancy_days integer, days_in_year integer, pro_rata_pct numeric, effective_pct numeric,
  pool_shares jsonb, total_share numeric(14,2), estimates_billed numeric(14,2), balance numeric(14,2),
  action text, note text
)
language sql stable security invoker set search_path = ''
as $$
  with l as (select * from public.cam_leases_for_year(p_property_id, p_year)),
  al as (select * from public.cam_allocation_lines(p_property_id, p_year)),
  p as (select * from public.cam_pool_amounts(p_property_id, p_year)),
  admin_pct as (select public.cam_default_admin_fee_pct(p_property_id, p_year) as pct),
  pools as (   -- pool totals incl. the property-level admin fee
    select p.pool_code, p.statement_label, p.sort_order, p.pool_amount from p
    union all
    select 'ADMIN', 'Administrative Fee', 100000,
           round(coalesce(sum(p.pool_amount) filter (where p.admin_fee_eligible), 0) * (select pct from admin_pct), 2)
      from p having (select pct from admin_pct) > 0
  ),
  inc as (
    select r.customer_id, r.total from public.report_cam_income(p_property_id, p_year) r where r.row_type = 'tenant' and r.lease_id is not null
  ),
  t as (
    select l.*,
           (select jsonb_agg(jsonb_build_object('code', al.pool_code, 'label', al.pool_label, 'amount', al.share_amount) order by al.sort_order, al.pool_code)
              from al where al.lease_id = l.lease_id) as shares,
           (select sum(al.share_amount) from al where al.lease_id = l.lease_id and al.pool_code <> 'ADMIN') as base_share,
           (select sum(al.share_amount) from al where al.lease_id = l.lease_id) as total_share,
           (select max(al.pro_rata_pct) from al where al.lease_id = l.lease_id and al.pool_code <> 'ADMIN') as pct,
           (select max(al.allocation_factor) from al where al.lease_id = l.lease_id and al.pool_code <> 'ADMIN') as eff,
           coalesce((select sum(inc.total) from inc where inc.customer_id = l.customer_id), 0) as est
      from l
  ),
  vac as (
    select jsonb_agg(jsonb_build_object('code', po.pool_code, 'label', po.statement_label,
                     'amount', po.pool_amount - coalesce((select sum(al.share_amount) from al where al.pool_code = po.pool_code), 0))
                     order by po.sort_order, po.pool_code) as shares,
           sum(po.pool_amount) - coalesce((select sum(al.share_amount) from al), 0) as total_share
      from pools po
  ),
  tot as (
    select jsonb_agg(jsonb_build_object('code', po.pool_code, 'label', po.statement_label, 'amount', po.pool_amount)
                     order by po.sort_order, po.pool_code) as shares,
           sum(po.pool_amount) as total_share
      from pools po
  )
  select (row_number() over (order by t.suite_number, t.start_date nulls first))::integer, 'tenant', t.lease_id, t.suite_number, t.tenant_name, t.status,
         t.owner_occupied, t.cam_billable, t.sf, t.building_sf, t.occupancy_days, t.days_in_year, t.pct, t.eff,
         t.shares, t.total_share::numeric(14,2), t.est::numeric(14,2), (t.total_share - t.est)::numeric(14,2),
         case when not t.cam_billable then 'Do not bill: ' || coalesce(t.non_billable_reason, 'not billable')
              when t.total_share - t.est > 0.004 then 'Bill balance due'
              when t.total_share - t.est < -0.004 then 'Refund / credit'
              else 'No balance' end,
         case when t.occupancy_days < t.days_in_year then 'Partial year: ' || t.occupancy_days || ' of ' || t.days_in_year || ' days' end
    from t
  union all
  select 900000, 'vacant', null, null, 'Vacant / landlord share', null, null, false,
         (select max(l.building_sf) - coalesce(sum(l.sf * l.occupancy_factor), 0) from l)::numeric(12,2),
         (select max(l.building_sf) from l), null, null, null,
         1 - coalesce((select sum(t.eff) from t), 0),
         vac.shares, vac.total_share::numeric(14,2), 0, null, 'Absorbed by landlord',
         'Unleased sq ft and partial-year vacancy (sq ft shown as full-year equivalent)'
    from vac
  union all
  select 1000000, 'total', null, null, 'Total', null, null, null,
         (select max(l.building_sf) from l), (select max(l.building_sf) from l), null, null, null, 1,
         tot.shares, tot.total_share::numeric(14,2), (select sum(t.est) from t)::numeric(14,2),
         ((select sum(t.total_share) from t) - (select sum(t.est) from t))::numeric(14,2), null,
         'Balance column = tenants only'
    from tot
   order by 1;
$$;

create or replace function public.cam_trueup_warnings(p_property_id uuid, p_year integer)
returns table (severity text, code text, message text)
language sql stable security invoker set search_path = ''
as $$
  with yr as (select make_date(p_year, 1, 1) as ys, make_date(p_year, 12, 31) as ye),
  pr as (select * from public.properties where id = p_property_id),
  p as (select * from public.cam_pool_amounts(p_property_id, p_year)),
  l as (select * from public.cam_leases_for_year(p_property_id, p_year)),
  missing as (
    select cp.code, cp.name, string_agg(to_char(make_date(p_year, m.m, 1), 'Mon'), ', ' order by m.m) as months, count(*) as n
      from public.cam_pools cp
      cross join generate_series(1, 12) m(m)
     where cp.property_id = p_property_id and cp.is_active and cp.expect_monthly
       and not exists (
         select 1 from public.cam_pool_accounts pa join public.gl_entries g on g.account_id = pa.account_id
          where pa.pool_id = cp.id and g.txn_date >= make_date(p_year, m.m, 1)
            and g.txn_date < (make_date(p_year, m.m, 1) + interval '1 month')::date)
     group by 1, 2
  ),
  open_cam as (
    select l.tenant_name, count(*) as n, sum(b.balance) as bal
      from l
      join public.invoice_balances b on b.customer_id = l.customer_id
      cross join pr
     where b.txn_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31) and b.balance > 0
       and exists (select 1 from public.invoice_lines il left join public.items it on it.id = il.item_id
                    where il.invoice_id = b.invoice_id and coalesce(il.account_id, it.income_account_id) = pr.cam_income_account_id)
     group by 1
  ),
  sfsum as (
    select coalesce(sum(h.sf), 0) as suites_sf from public.suites s
      join lateral (select h.sf from public.suite_area_history h, yr where h.suite_id = s.id and h.effective_from <= yr.ye
                     and (h.effective_to is null or h.effective_to >= yr.ys) order by h.effective_from desc limit 1) h on true
     where s.property_id = p_property_id and s.is_active
  )
  select 'warning', 'missing_months',
         m.name || ': no postings in ' || p_year || ' for ' || m.months || ' (' || m.n || ' month' || case when m.n > 1 then 's' else '' end ||
         '). GL actuals are used as-is; total ' || to_char((select p.pool_amount from p where p.pool_code = m.code), 'FM$999,999,990.00') || '.'
    from missing m
  union all
  select 'info', 'tax_bill_override',
         p.statement_label || ': tax bill ' || to_char(p.tax_bill_amount, 'FM$999,999,990.00') || ' used instead of GL cash paid ' ||
         to_char(p.gl_amount, 'FM$999,999,990.00') || ' (difference ' || to_char(p.gl_amount - p.tax_bill_amount, 'FM$999,999,990.00') || ').'
    from p where p.amount_basis = 'tax_bill' and p.gl_amount <> p.tax_bill_amount
  union all
  select 'warning', 'tax_bill_missing', p.statement_label || ': no tax bill on file for ' || p_year || '; GL cash paid used.'
    from p where p.amount_basis = 'gl_no_tax_bill'
  union all
  select 'info', 'not_billable', l.tenant_name || ' (Suite ' || l.suite_number || '): share calculated but not billable - ' || l.non_billable_reason || '.'
    from l where not l.cam_billable
  union all
  select 'info', 'partial_year', l.tenant_name || ' (Suite ' || l.suite_number || '): occupied ' || l.occupancy_days || ' of ' || l.days_in_year ||
         ' days (lease ' || coalesce(to_char(l.start_date, 'MM/DD/YYYY'), '...') || ' - ' || coalesce(to_char(l.end_date, 'MM/DD/YYYY'), 'open') || ').'
    from l where l.occupancy_days < l.days_in_year
  union all
  select 'warning', 'missing_sf', l.tenant_name || ': no square footage on file for Suite ' || l.suite_number || '.' from l where l.sf is null
  union all
  select 'warning', 'open_cam_invoices', o.tenant_name || ': ' || o.n || ' invoice(s) with CAM from ' || p_year || ' still open, balance ' ||
         to_char(o.bal, 'FM$999,999,990.00') || ' (estimates are counted as billed, not as paid).'
    from open_cam o
  union all
  select 'warning', 'sf_mismatch', 'Suites total ' || to_char(s.suites_sf, 'FM999,999') || ' sq ft but building total is ' ||
         to_char((select max(l.building_sf) from l), 'FM999,999') || ' sq ft.'
    from sfsum s where s.suites_sf <> (select max(l.building_sf) from l)
  union all
  select 'warning', 'unsupported_rule', 'Allocation rule ' || ar.id || ' sets gross-up or cap % increase, which are stored but not yet applied.'
    from public.cam_allocation_rules ar
   where ar.property_id = p_property_id and (ar.gross_up_occupancy_pct is not null or ar.cap_pct_increase is not null)
  union all
  select 'warning', 'cam_billed_no_lease', r.tenant_name || ': CAM billed (' || to_char(r.total, 'FM$999,999,990.00') || ') but no lease in this property.'
    from public.report_cam_income(p_property_id, p_year) r where r.row_type = 'tenant' and r.lease_id is null;
$$;
