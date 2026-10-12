-- migration 20261013000111_0011_cam_trueup_building_blocks
create or replace function public.cam_pool_amounts(p_property_id uuid, p_year integer)
returns table (
  pool_id uuid, pool_code text, pool_name text, statement_label text, sort_order integer,
  admin_fee_eligible boolean, expense_source text, gl_amount numeric(14,2), tax_bill_amount numeric(14,2),
  adjustment_amount numeric(14,2), pool_amount numeric(14,2), amount_basis text
)
language sql stable security invoker set search_path = ''
as $$
  with yr as (select make_date(p_year, 1, 1) as ys, make_date(p_year, 12, 31) as ye),
  pools as (select p.* from public.cam_pools p where p.property_id = p_property_id and p.is_active),
  gl as (
    select pa.pool_id, sum(g.amount) as amt
      from public.cam_pool_accounts pa
      join pools p on p.id = pa.pool_id
      cross join yr
      join public.gl_entries g on g.company_id = pa.company_id and g.account_id = pa.account_id
       and g.txn_date between greatest(yr.ys, pa.effective_from) and least(yr.ye, coalesce(pa.effective_to, yr.ye))
     group by 1
  ),
  tb as (select t.amount from public.cam_tax_bills t where t.property_id = p_property_id and t.cam_year = p_year),
  adj as (
    select a.pool_id, sum(a.amount) as amt from public.cam_expense_adjustments a
     where a.property_id = p_property_id and a.cam_year = p_year group by 1
  )
  select p.id, p.code, p.name, coalesce(p.statement_label, p.name), p.sort_order, p.admin_fee_eligible, p.expense_source,
         coalesce(gl.amt, 0)::numeric(14,2),
         (case when p.expense_source = 'tax_bill' then (select tb.amount from tb) end)::numeric(14,2),
         coalesce(adj.amt, 0)::numeric(14,2),
         ((case when p.expense_source = 'tax_bill' and exists (select 1 from tb) then (select tb.amount from tb)
                else coalesce(gl.amt, 0) end) + coalesce(adj.amt, 0))::numeric(14,2),
         case when p.expense_source = 'tax_bill' and exists (select 1 from tb) then 'tax_bill'
              when p.expense_source = 'tax_bill' then 'gl_no_tax_bill' else 'gl' end
    from pools p
    left join gl on gl.pool_id = p.id
    left join adj on adj.pool_id = p.id
   order by p.sort_order, p.code;
$$;

create or replace function public.cam_leases_for_year(p_property_id uuid, p_year integer)
returns table (
  lease_id uuid, suite_id uuid, suite_number text, customer_id uuid, tenant_name text, status text,
  owner_occupied boolean, cam_billable boolean, non_billable_reason text, start_date date, end_date date,
  sf numeric(12,2), building_sf numeric(12,2), occupancy_days integer, days_in_year integer, occupancy_factor numeric
)
language sql stable security invoker set search_path = ''
as $$
  with yr as (select make_date(p_year, 1, 1) as ys, make_date(p_year, 12, 31) as ye),
  bsf as (
    select h.total_sf from public.property_area_history h, yr
     where h.property_id = p_property_id and h.effective_from <= yr.ye and (h.effective_to is null or h.effective_to >= yr.ys)
     order by h.effective_from desc limit 1
  )
  select l.id, s.id, s.suite_number, l.customer_id, coalesce(l.statement_name, c.company_name, c.display_name), l.status,
         l.owner_occupied, l.cam_billable, l.non_billable_reason, l.start_date, l.end_date,
         sa.sf, (select total_sf from bsf),
         od.days, (yr.ye - yr.ys + 1),
         od.days::numeric / (yr.ye - yr.ys + 1)
    from public.leases l
    join public.suites s on s.id = l.suite_id
    join public.customers c on c.id = l.customer_id
    cross join yr
    left join lateral (
      select h.sf from public.suite_area_history h
       where h.suite_id = s.id and h.effective_from <= yr.ye and (h.effective_to is null or h.effective_to >= yr.ys)
       order by h.effective_from desc limit 1
    ) sa on true
    cross join lateral (
      select greatest(0, least(coalesce(l.end_date, yr.ye), yr.ye) - greatest(coalesce(l.start_date, yr.ys), yr.ys) + 1)::integer as days
    ) od
   where s.property_id = p_property_id
     and (l.start_date is null or l.start_date <= yr.ye)
     and (l.end_date is null or l.end_date >= yr.ys)
   order by s.suite_number, l.start_date nulls first;
$$;

create or replace function public.cam_allocation_lines(p_property_id uuid, p_year integer)
returns table (
  lease_id uuid, pool_code text, pool_label text, sort_order integer, pool_amount numeric(14,2),
  method text, pro_rata_pct numeric, occupancy_factor numeric, allocation_factor numeric,
  admin_fee_pct numeric, share_amount numeric(14,2)
)
language sql stable security invoker set search_path = ''
as $$
  with yr as (select make_date(p_year, 1, 1) as ys, make_date(p_year, 12, 31) as ye),
  l as (select * from public.cam_leases_for_year(p_property_id, p_year)),
  p as (select * from public.cam_pool_amounts(p_property_id, p_year)),
  occ as (select sum(l.sf * l.occupancy_factor) as occupied_sf from l),
  r as (
    select l.lease_id, p.pool_id, rr.method, rr.fixed_pct, rr.denominator, rr.prorate_by_occupancy,
           rr.admin_fee_pct, rr.cap_amount, rr.base_year_amount
      from l cross join p
      left join lateral (
        select ar.method, ar.fixed_pct, ar.denominator, ar.prorate_by_occupancy, ar.admin_fee_pct, ar.cap_amount, ar.base_year_amount
          from public.cam_allocation_rules ar, yr
         where ar.property_id = p_property_id
           and (ar.lease_id = l.lease_id or ar.lease_id is null)
           and (ar.pool_id = p.pool_id or ar.pool_id is null)
           and ar.effective_from <= yr.ye and (ar.effective_to is null or ar.effective_to >= yr.ys)
         order by (ar.lease_id is not null) desc, (ar.pool_id is not null) desc, ar.effective_from desc
         limit 1
      ) rr on true
  ),
  b as (
    select l.lease_id, p.pool_code, p.statement_label, p.sort_order, p.pool_amount, p.admin_fee_eligible,
           coalesce(r.method, 'pro_rata_sf') as method,
           case coalesce(r.method, 'pro_rata_sf')
             when 'fixed_pct' then r.fixed_pct
             when 'excluded' then 0::numeric
             else coalesce(l.sf, 0) / nullif(case when r.denominator = 'occupied_sf' then (select occupied_sf from occ) else l.building_sf end, 0)
           end as pct,
           case when coalesce(r.prorate_by_occupancy, true) then l.occupancy_factor else 1::numeric end as factor,
           coalesce(r.admin_fee_pct, 0) as admin_pct, r.cap_amount, r.base_year_amount
      from l cross join p
      join r on r.lease_id = l.lease_id and r.pool_id = p.pool_id
  ),
  s as (
    select b.*,
           (case when b.cap_amount is not null
                 then least(greatest(b.pool_amount - coalesce(b.base_year_amount, 0), 0) * coalesce(b.pct, 0) * b.factor, b.cap_amount)
                 else greatest(b.pool_amount - coalesce(b.base_year_amount, 0), 0) * coalesce(b.pct, 0) * b.factor end) as raw_share
      from b
  )
  select s.lease_id, s.pool_code, s.statement_label, s.sort_order, s.pool_amount, s.method,
         s.pct, s.factor, coalesce(s.pct, 0) * s.factor, null::numeric, round(s.raw_share, 2)::numeric(14,2)
    from s
  union all
  select s.lease_id, 'ADMIN', 'Administrative Fee', 100000,
         round(sum(s.pool_amount * s.admin_pct), 2)::numeric(14,2), 'admin_fee',
         max(s.pct), max(s.factor), max(coalesce(s.pct, 0) * s.factor), max(s.admin_pct),
         round(sum(s.raw_share * s.admin_pct), 2)::numeric(14,2)
    from s where s.admin_fee_eligible
   group by s.lease_id
  having max(s.admin_pct) > 0;
$$;

create or replace function public.cam_default_admin_fee_pct(p_property_id uuid, p_year integer)
returns numeric
language sql stable security invoker set search_path = ''
as $$
  select coalesce((
    select ar.admin_fee_pct from public.cam_allocation_rules ar
     where ar.property_id = p_property_id and ar.lease_id is null and ar.pool_id is null
       and ar.effective_from <= make_date(p_year, 12, 31)
       and (ar.effective_to is null or ar.effective_to >= make_date(p_year, 1, 1))
     order by ar.effective_from desc limit 1), 0);
$$;
