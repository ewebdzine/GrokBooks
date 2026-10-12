-- migration 20261013000100_0001_core_entities
-- GrokBooks 0001: core entities (companies, chart of accounts, customers, vendors, items)
-- Conventions:
--   * uuid primary keys, numeric(14,2) for money, created_at/updated_at on every table
--   * company_id on every table; children use composite FKs (company_id, x_id) so rows can
--     never point at another tenant's data
--   * qbo_id = QuickBooks Online entity Id, unique per company, for idempotent sync
--   * RLS enabled on every table with no policies (deny by default; service role bypasses RLS)

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Companies (tenants) -------------------------------------------------------
create table public.companies (
  id                      uuid primary key default gen_random_uuid(),
  name                    text not null,
  legal_name              text,
  qbo_realm_id            text unique,            -- QuickBooks company (realm) id
  base_currency           char(3) not null default 'USD',
  fiscal_year_start_month smallint not null default 1 check (fiscal_year_start_month between 1 and 12),
  timezone                text not null default 'America/Chicago',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- Chart of accounts -----------------------------------------------------------
create table public.accounts (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  qbo_id                text,
  qbo_sync_token        text,
  account_number        text,                     -- QB AcctNum
  name                  text not null,
  fully_qualified_name  text,                     -- e.g. 'Parent:Child'
  account_type          text not null check (account_type in (
                          'Bank','Accounts Receivable','Other Current Asset','Fixed Asset','Other Asset',
                          'Accounts Payable','Credit Card','Other Current Liability','Long Term Liability',
                          'Equity','Income','Cost of Goods Sold','Expense','Other Income','Other Expense')),
  account_subtype       text,                     -- QB AccountSubType / detail type
  classification        text not null check (classification in ('Asset','Liability','Equity','Revenue','Expense')),
  normal_balance        text generated always as
                          (case when classification in ('Asset','Expense') then 'debit' else 'credit' end) stored,
  parent_id             uuid,
  description           text,
  is_active             boolean not null default true,
  currency              char(3) not null default 'USD',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  unique (company_id, account_number),
  check (parent_id is null or parent_id <> id),
  foreign key (company_id, parent_id) references public.accounts(company_id, id)
);
create index accounts_company_parent_idx on public.accounts (company_id, parent_id);

-- Customers -------------------------------------------------------------------
create table public.customers (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  display_name           text not null,
  company_name           text,
  given_name             text,
  middle_name            text,
  family_name            text,
  print_on_check_name    text,
  email                  text,
  phone                  text,
  mobile                 text,
  bill_address           jsonb,
  ship_address           jsonb,
  parent_customer_id     uuid,                    -- QB sub-customer / job
  is_active              boolean not null default true,
  taxable                boolean not null default false,
  preferred_delivery     text,
  notes                  text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  check (parent_customer_id is null or parent_customer_id <> id),
  foreign key (company_id, parent_customer_id) references public.customers(company_id, id)
);
create index customers_company_parent_idx on public.customers (company_id, parent_customer_id);
create index customers_company_name_idx on public.customers (company_id, display_name);

-- Vendors ---------------------------------------------------------------------
create table public.vendors (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  display_name           text not null,
  company_name           text,
  given_name             text,
  middle_name            text,
  family_name            text,
  print_on_check_name    text,
  email                  text,
  phone                  text,
  bill_address           jsonb,
  tax_identifier_masked  text,                    -- never store a full TIN
  is_1099                boolean not null default false,
  account_number         text,                    -- our account number with the vendor
  terms                  text,
  is_active              boolean not null default true,
  notes                  text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id)
);
create index vendors_company_name_idx on public.vendors (company_id, display_name);

-- Items (products and services) -----------------------------------------------
create table public.items (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  name                   text not null,
  fully_qualified_name   text,
  sku                    text,
  item_type              text not null default 'Service'
                           check (item_type in ('Service','Inventory','NonInventory','Group','Category')),
  description            text,
  unit_price             numeric(14,4),           -- rates may carry more than 2 decimals
  purchase_description   text,
  purchase_cost          numeric(14,4),
  income_account_id      uuid,
  expense_account_id     uuid,
  asset_account_id       uuid,
  taxable                boolean not null default false,
  track_qty_on_hand      boolean not null default false,
  qty_on_hand            numeric(14,4),
  is_active              boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  foreign key (company_id, income_account_id)  references public.accounts(company_id, id),
  foreign key (company_id, expense_account_id) references public.accounts(company_id, id),
  foreign key (company_id, asset_account_id)   references public.accounts(company_id, id)
);
create index items_company_income_acct_idx  on public.items (company_id, income_account_id);
create index items_company_expense_acct_idx on public.items (company_id, expense_account_id);
create index items_company_asset_acct_idx   on public.items (company_id, asset_account_id);

-- updated_at triggers + RLS ---------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['companies','accounts','customers','vendors','items'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
