-- migration 20261013000115_0011_cam_trueup_monthly_adjustment_note
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
  cur as (
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
           case when x.n > x.months then x.n || ' CAM invoices in ' || x.months || ' months billed' end,
           case when x.months = 0 then 'No CAM billed; divided by months occupied' end,
           case when x.months > 0 and x.months < 12 and x.n <= x.months then 'Billed ' || x.months || ' months' end)
    from x
   order by 1;
$$;
