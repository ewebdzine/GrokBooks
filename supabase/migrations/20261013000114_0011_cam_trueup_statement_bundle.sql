-- migration 20261013000114_0011_cam_trueup_statement_bundle
create or replace function public.cam_tenant_statement(p_lease_id uuid, p_year integer)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with le as (
    select l.*, s.property_id, s.suite_number from public.leases l join public.suites s on s.id = l.suite_id where l.id = p_lease_id
  ),
  pr as (select pp.* from public.properties pp join le on le.property_id = pp.id),
  co as (select c.* from public.companies c join pr on pr.company_id = c.id),
  cu as (select c.* from public.customers c join le on le.customer_id = c.id),
  ly as (select y.* from public.cam_leases_for_year((select property_id from le), p_year) y where y.lease_id = p_lease_id),
  al as (select a.* from public.cam_allocation_lines((select property_id from le), p_year) a where a.lease_id = p_lease_id),
  pools as (
    select a.pool_code, a.pool_label, a.sort_order, a.pool_amount, a.share_amount, a.pro_rata_pct, a.allocation_factor, a.admin_fee_pct
      from al a
  ),
  est as (
    select i.doc_number, i.txn_date, il.amount
      from public.invoices i join public.invoice_lines il on il.invoice_id = i.id
      left join public.items it on it.id = il.item_id
      cross join pr cross join le
     where i.customer_id = le.customer_id and i.voided_at is null
       and i.txn_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31)
       and coalesce(il.account_id, it.income_account_id) = pr.cam_income_account_id
  ),
  tb as (select t.* from public.cam_tax_bills t join pr on pr.id = t.property_id where t.cam_year = p_year)
  select jsonb_build_object(
    'year', p_year,
    'period', jsonb_build_object('start', make_date(p_year, 1, 1), 'end', make_date(p_year, 12, 31)),
    'company', (select jsonb_build_object('name', co.name, 'legal_name', co.legal_name, 'address', co.address, 'phone', co.phone,
                                          'email', co.email, 'website', co.website, 'remit_to', co.remit_to,
                                          'payment_instructions', co.payment_instructions) from co),
    'property', (select jsonb_build_object('name', pr.name, 'address', pr.address) from pr),
    'tenant', (select jsonb_build_object('name', coalesce(le.statement_name, cu.company_name, cu.display_name),
                                         'customer', cu.display_name, 'attention', le.statement_attention,
                                         'address', coalesce(le.statement_address, cu.bill_address), 'email', cu.email) from le, cu),
    'lease', (select jsonb_build_object('lease_id', le.id, 'suite', le.suite_number, 'start_date', le.start_date, 'end_date', le.end_date,
                                        'status', le.status, 'owner_occupied', le.owner_occupied, 'cam_billable', le.cam_billable,
                                        'non_billable_reason', le.non_billable_reason,
                                        'sf', ly.sf, 'building_sf', ly.building_sf, 'occupancy_days', ly.occupancy_days,
                                        'days_in_year', ly.days_in_year, 'occupancy_factor', round(ly.occupancy_factor, 6),
                                        'pro_rata_pct', round(ly.sf / nullif(ly.building_sf, 0), 6)) from le, ly),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('code', p.pool_code, 'label', p.pool_label, 'pool_amount', p.pool_amount,
                                         'share_pct', round(p.allocation_factor, 6), 'admin_fee_pct', p.admin_fee_pct, 'share', p.share_amount)
                                         order by p.sort_order, p.pool_code) from pools p), '[]'::jsonb),
    'pool_total', (select sum(p.pool_amount) from pools p),
    'share_total', (select sum(p.share_amount) from pools p),
    'tax_bill', (select jsonb_build_object('tax_year', tb.tax_year, 'amount', tb.amount, 'source', tb.source) from tb),
    'estimates', jsonb_build_object(
        'total', coalesce((select sum(e.amount) from est e), 0),
        'count', (select count(*) from est),
        'invoices', coalesce((select jsonb_agg(jsonb_build_object('doc_number', e.doc_number, 'date', e.txn_date, 'amount', e.amount) order by e.txn_date, e.doc_number) from est e), '[]'::jsonb)),
    'balance', (select sum(p.share_amount) from pools p) - coalesce((select sum(e.amount) from est e), 0),
    'balance_kind', case when (select sum(p.share_amount) from pools p) - coalesce((select sum(e.amount) from est e), 0) > 0.004 then 'due'
                         when (select sum(p.share_amount) from pools p) - coalesce((select sum(e.amount) from est e), 0) < -0.004 then 'refund'
                         else 'zero' end
  );
$$;

create or replace function public.report_cam_monthly_adjustment(p_property_id uuid, p_year integer)
returns table (
  row_no integer, lease_id uuid, suite_number text, tenant_name text, status text, owner_occupied boolean, cam_billable boolean,
  annual_share numeric(14,2), estimates_billed numeric(14,2), months_billed integer, invoice_count integer,
  avg_monthly_billed numeric(14,2), current_monthly_estimate numeric(14,2), current_estimate_date date,
  balanced_monthly numeric(14,2), monthly_difference numeric(14,2), direction text, note text
)
language sql stable security invoker set search_path = ''
as $$
  with pr as (select * from public.properties where id = p_property_id),
  a as (select * from public.report_cam_allocation(p_property_id, p_year) r where r.row_type = 'tenant'),
  l as (select * from public.cam_leases_for_year(p_property_id, p_year)),
  cam as (
    select i.customer_id, i.id as invoice_id, i.txn_date, il.amount
      from public.invoices i
      join public.invoice_lines il on il.invoice_id = i.id
      left join public.items it on it.id = il.item_id
      cross join pr
     where i.company_id = pr.company_id and i.voided_at is null
       and coalesce(il.account_id, it.income_account_id) = pr.cam_income_account_id
  ),
  yr_cam as (
    select c.customer_id, count(distinct date_trunc('month', c.txn_date))::int as months, count(distinct c.invoice_id)::int as n
      from cam c where c.txn_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31) group by 1
  ),
  cur as (   -- latest monthly CAM line billed to date (falls back to leases.monthly_cam_estimate)
    select distinct on (c.customer_id) c.customer_id, c.amount, c.txn_date
      from cam c where c.txn_date <= current_date order by c.customer_id, c.txn_date desc, c.amount desc
  ),
  x as (
    select a.*, lf.customer_id, le.monthly_cam_estimate, le.non_billable_reason,
           coalesce(y.months, 0) as months, coalesce(y.n, 0) as n,
           coalesce(nullif(y.months, 0), ceil(lf.occupancy_days * 12.0 / lf.days_in_year)::int) as div_months,
           coalesce(le.monthly_cam_estimate, cur.amount) as cur_amt,
           case when le.monthly_cam_estimate is not null then null else cur.txn_date end as cur_date
      from a
      join l lf on lf.lease_id = a.lease_id
      join public.leases le on le.id = a.lease_id
      left join yr_cam y on y.customer_id = lf.customer_id
      left join cur on cur.customer_id = lf.customer_id
  )
  select (row_number() over (order by x.suite_number))::integer, x.lease_id, x.suite_number, x.tenant_name, x.status, x.owner_occupied, x.cam_billable,
         x.total_share, x.estimates_billed, x.months, x.n,
         case when x.months > 0 then round(x.estimates_billed / x.months, 2) end,
         x.cur_amt, x.cur_date,
         round(x.total_share / nullif(x.div_months, 0), 2),
         round(x.total_share / nullif(x.div_months, 0), 2) - x.cur_amt,
         case when x.cur_amt is null then null
              when round(x.total_share / nullif(x.div_months, 0), 2) - x.cur_amt > 0.004 then 'increase'
              when round(x.total_share / nullif(x.div_months, 0), 2) - x.cur_amt < -0.004 then 'decrease'
              else 'no change' end,
         concat_ws('; ',
           case when x.owner_occupied then 'Owner-occupied (part owner): not billed' end,
           case when x.status = 'defaulted' then 'Lease broken: not billable' end,
           case when not x.cam_billable and not x.owner_occupied and x.status <> 'defaulted' then x.non_billable_reason end,
           case when x.n > x.months then x.n || ' CAM invoices in ' || x.months || ' months' end,
           case when x.months = 0 then 'No CAM billed; divided by months occupied' end,
           case when x.months > 0 and x.months < 12 then 'Billed ' || x.months || ' months' end)
    from x
   order by 1;
$$;

create or replace function public.cam_trueup_bundle(p_property_id uuid, p_year integer)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object(
    'year', p_year,
    'generated_at', now(),
    'property', (select jsonb_build_object('id', pp.id, 'name', pp.name, 'address', pp.address) from public.properties pp where pp.id = p_property_id),
    'company', (select jsonb_build_object('name', c.name, 'legal_name', c.legal_name, 'address', c.address, 'phone', c.phone, 'email', c.email,
                                          'remit_to', c.remit_to, 'payment_instructions', c.payment_instructions)
                  from public.companies c join public.properties pp on pp.company_id = c.id where pp.id = p_property_id),
    'expenses', (select jsonb_agg(to_jsonb(r) order by r.row_no) from public.report_cam_expenses(p_property_id, p_year) r),
    'income', (select jsonb_agg(to_jsonb(r) order by r.row_no) from public.report_cam_income(p_property_id, p_year) r),
    'allocation', (select jsonb_agg(to_jsonb(r) order by r.row_no) from public.report_cam_allocation(p_property_id, p_year) r),
    'monthly_adjustment', (select jsonb_agg(to_jsonb(r) order by r.row_no) from public.report_cam_monthly_adjustment(p_property_id, p_year) r),
    'warnings', coalesce((select jsonb_agg(to_jsonb(w)) from public.cam_trueup_warnings(p_property_id, p_year) w), '[]'::jsonb),
    'statements', (select jsonb_agg(public.cam_tenant_statement(l.lease_id, p_year) order by l.suite_number)
                     from public.cam_leases_for_year(p_property_id, p_year) l)
  );
$$;
