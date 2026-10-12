-- migration 20261013000110_0011_cam_trueup
-- GrokBooks 0011: CAM (common area maintenance) true-up module. See migrations/0011_cam_trueup.sql for full header.

create table public.properties (
  id                            uuid primary key default gen_random_uuid(),
  company_id                    uuid not null references public.companies(id) on delete cascade,
  name                          text not null,
  address                       jsonb,
  cam_income_account_id         uuid,
  cam_trueup_income_account_id  uuid,
  notes                         text,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, name),
  foreign key (company_id, cam_income_account_id) references public.accounts(company_id, id),
  foreign key (company_id, cam_trueup_income_account_id) references public.accounts(company_id, id)
);

create table public.property_area_history (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  property_id     uuid not null,
  total_sf        numeric(12,2) not null check (total_sf > 0),
  effective_from  date not null default '1900-01-01',
  effective_to    date,
  source          text,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (property_id, effective_from),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade
);

create table public.suites (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  property_id   uuid not null,
  suite_number  text not null,
  description   text,
  is_active     boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, id),
  unique (property_id, suite_number),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade
);

create table public.suite_area_history (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  suite_id        uuid not null,
  sf              numeric(12,2) not null check (sf >= 0),
  effective_from  date not null default '1900-01-01',
  effective_to    date,
  source          text,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (suite_id, effective_from),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (company_id, suite_id) references public.suites(company_id, id) on delete cascade
);

create table public.leases (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  suite_id              uuid not null,
  customer_id           uuid not null,
  statement_name        text,
  statement_attention   text,
  statement_address     jsonb,
  start_date            date,
  end_date              date,
  status                text not null default 'active'
                          check (status in ('pending','active','ended','defaulted')),
  owner_occupied        boolean not null default false,
  cam_billable          boolean not null default true,
  non_billable_reason   text,
  monthly_cam_estimate  numeric(14,2),
  date_source           text,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, id),
  check (end_date is null or start_date is null or end_date >= start_date),
  check (cam_billable or non_billable_reason is not null),
  foreign key (company_id, suite_id) references public.suites(company_id, id) on delete cascade,
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create index leases_company_suite_idx on public.leases (company_id, suite_id);
create index leases_company_customer_idx on public.leases (company_id, customer_id);

create table public.cam_pools (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete cascade,
  property_id         uuid not null,
  code                text not null check (code ~ '^[A-Z][A-Z0-9_]*$' and code <> 'ADMIN'),
  name                text not null,
  statement_label     text,
  sort_order          integer not null default 100,
  admin_fee_eligible  boolean not null default false,
  expense_source      text not null default 'gl' check (expense_source in ('gl','tax_bill')),
  expect_monthly      boolean not null default false,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (company_id, id),
  unique (property_id, code),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade
);

create table public.cam_pool_accounts (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  pool_id         uuid not null,
  account_id      uuid not null,
  effective_from  date not null default '1900-01-01',
  effective_to    date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (pool_id, account_id, effective_from),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (company_id, pool_id) references public.cam_pools(company_id, id) on delete cascade,
  foreign key (company_id, account_id) references public.accounts(company_id, id)
);

create table public.cam_tax_bills (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  property_id   uuid not null,
  cam_year      smallint not null,
  tax_year      smallint,
  amount        numeric(14,2) not null check (amount >= 0),
  installments  jsonb,
  parcel        text,
  source        text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (property_id, cam_year),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade
);

create table public.cam_expense_adjustments (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  property_id  uuid not null,
  pool_id      uuid not null,
  cam_year     smallint not null,
  month        smallint check (month between 1 and 12),
  amount       numeric(14,2) not null,
  reason       text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade,
  foreign key (company_id, pool_id) references public.cam_pools(company_id, id) on delete cascade
);

create table public.cam_allocation_rules (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references public.companies(id) on delete cascade,
  property_id             uuid not null,
  lease_id                uuid,
  pool_id                 uuid,
  method                  text not null default 'pro_rata_sf' check (method in ('pro_rata_sf','fixed_pct','excluded')),
  fixed_pct               numeric(9,6) check (fixed_pct is null or fixed_pct between 0 and 1),
  denominator             text not null default 'building_sf' check (denominator in ('building_sf','occupied_sf')),
  prorate_by_occupancy    boolean not null default true,
  admin_fee_pct           numeric(7,4) check (admin_fee_pct is null or admin_fee_pct between 0 and 1),
  cap_amount              numeric(14,2),
  cap_pct_increase        numeric(7,4),
  base_year               smallint,
  base_year_amount        numeric(14,2),
  gross_up_occupancy_pct  numeric(7,4),
  effective_from          date not null default '1900-01-01',
  effective_to            date,
  notes                   text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check (method <> 'fixed_pct' or fixed_pct is not null),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (company_id, property_id) references public.properties(company_id, id) on delete cascade,
  foreign key (company_id, lease_id) references public.leases(company_id, id) on delete cascade,
  foreign key (company_id, pool_id) references public.cam_pools(company_id, id) on delete cascade
);
create index cam_allocation_rules_property_idx on public.cam_allocation_rules (property_id, lease_id, pool_id);

do $$
declare t text;
begin
  foreach t in array array['properties','property_area_history','suites','suite_area_history','leases',
                           'cam_pools','cam_pool_accounts','cam_tax_bills','cam_expense_adjustments','cam_allocation_rules']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
