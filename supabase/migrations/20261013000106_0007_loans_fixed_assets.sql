-- migration 20261013000106_0007_loans_fixed_assets
-- GrokBooks 0007: loans, loan activity, fixed assets and depreciation.

create table public.loans (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references public.companies(id) on delete cascade,
  name                    text not null,
  lender_name             text not null,
  lender_vendor_id        uuid,
  account_last4           text check (account_last4 is null or account_last4 ~ '^[0-9]{4}$'),
  original_principal      numeric(14,2) check (original_principal is null or original_principal > 0),
  interest_rate           numeric(7,5) check (interest_rate is null or (interest_rate >= 0 and interest_rate < 1)),  -- annual, 0.07250 = 7.25%
  rate_type               text check (rate_type in ('fixed','variable')),
  term_months             integer check (term_months is null or term_months > 0),
  start_date              date,
  maturity_date           date,
  payment_amount          numeric(14,2) check (payment_amount is null or payment_amount > 0),
  liability_account_id    uuid not null,
  interest_account_id     uuid,
  status                  text not null default 'active' check (status in ('active','paid_off','refinanced')),
  notes                   text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (company_id, id),
  check (maturity_date is null or start_date is null or maturity_date > start_date),
  foreign key (company_id, lender_vendor_id)     references public.vendors(company_id, id),
  foreign key (company_id, liability_account_id) references public.accounts(company_id, id),
  foreign key (company_id, interest_account_id)  references public.accounts(company_id, id)
);
create index loans_company_vendor_idx    on public.loans (company_id, lender_vendor_id);
create index loans_company_liability_idx on public.loans (company_id, liability_account_id);
create index loans_company_interest_idx  on public.loans (company_id, interest_account_id);

-- One row per loan event. principal_amount is the reduction in principal:
-- positive for payments, negative for advances and upward balance adjustments.
create table public.loan_payments (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete cascade,
  loan_id            uuid not null,
  payment_date       date not null,
  entry_type         text not null default 'payment' check (entry_type in ('payment','advance','adjustment')),
  total_amount       numeric(14,2) not null,
  principal_amount   numeric(14,2) not null default 0,
  interest_amount    numeric(14,2) not null default 0,
  escrow_amount      numeric(14,2) not null default 0,
  ending_balance     numeric(14,2),
  source             text not null check (source in ('bank','qb','lender_statement','manual')),
  bill_id            uuid,
  purchase_id        uuid,
  journal_entry_id   uuid,
  deposit_id         uuid,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (entry_type <> 'payment' or total_amount = principal_amount + interest_amount + escrow_amount),
  check (num_nonnulls(bill_id, purchase_id, journal_entry_id, deposit_id) <= 1),
  unique (loan_id, bill_id),
  unique (loan_id, purchase_id),
  unique (loan_id, journal_entry_id),
  unique (loan_id, deposit_id),
  foreign key (company_id, loan_id)          references public.loans(company_id, id) on delete cascade,
  foreign key (company_id, bill_id)          references public.bills(company_id, id),
  foreign key (company_id, purchase_id)      references public.purchases(company_id, id),
  foreign key (company_id, journal_entry_id) references public.journal_entries(company_id, id),
  foreign key (company_id, deposit_id)       references public.deposits(company_id, id)
);
create index loan_payments_company_loan_date_idx on public.loan_payments (company_id, loan_id, payment_date);
create index loan_payments_company_bill_idx      on public.loan_payments (company_id, bill_id);
create index loan_payments_company_purchase_idx  on public.loan_payments (company_id, purchase_id);
create index loan_payments_company_je_idx        on public.loan_payments (company_id, journal_entry_id);
create index loan_payments_company_deposit_idx   on public.loan_payments (company_id, deposit_id);

create table public.fixed_assets (
  id                                   uuid primary key default gen_random_uuid(),
  company_id                           uuid not null references public.companies(id) on delete cascade,
  name                                 text not null,
  category                             text not null check (category in ('building','land','land_improvement','building_improvement',
                                         'machinery','equipment','vehicle','furniture','computer','other')),
  acquisition_date                     date,
  in_service_date                      date,
  cost                                 numeric(14,2) not null check (cost >= 0),
  salvage_value                        numeric(14,2) not null default 0 check (salvage_value >= 0),
  depreciation_method                  text not null default 'straight_line'
                                         check (depreciation_method in ('straight_line','macrs_200db','macrs_150db','declining_balance','none')),
  convention                           text check (convention in ('mid_month','half_year','mid_quarter','full_month')),
  useful_life_months                   integer check (useful_life_months is null or useful_life_months > 0),
  asset_account_id                     uuid not null,
  accumulated_depreciation_account_id  uuid,
  depreciation_expense_account_id      uuid,
  disposed_date                        date,
  disposal_proceeds                    numeric(14,2),
  notes                                text,
  created_at                           timestamptz not null default now(),
  updated_at                           timestamptz not null default now(),
  unique (company_id, id),
  check (salvage_value <= cost),
  check (depreciation_method = 'none' or useful_life_months is not null),
  check (category <> 'land' or depreciation_method = 'none'),
  check (disposed_date is null or in_service_date is null or disposed_date >= in_service_date),
  foreign key (company_id, asset_account_id)                    references public.accounts(company_id, id),
  foreign key (company_id, accumulated_depreciation_account_id) references public.accounts(company_id, id),
  foreign key (company_id, depreciation_expense_account_id)     references public.accounts(company_id, id)
);
create index fixed_assets_company_asset_acct_idx   on public.fixed_assets (company_id, asset_account_id);
create index fixed_assets_company_accum_acct_idx   on public.fixed_assets (company_id, accumulated_depreciation_account_id);
create index fixed_assets_company_expense_acct_idx on public.fixed_assets (company_id, depreciation_expense_account_id);

create table public.depreciation_entries (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete cascade,
  fixed_asset_id    uuid not null,
  fiscal_year       smallint not null,
  period_start      date,
  period_end        date not null,
  amount            numeric(14,2) not null check (amount >= 0),
  journal_entry_id  uuid,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (fixed_asset_id, period_end),
  unique (fixed_asset_id, journal_entry_id),
  check (period_start is null or period_start <= period_end),
  foreign key (company_id, fixed_asset_id)   references public.fixed_assets(company_id, id) on delete cascade,
  foreign key (company_id, journal_entry_id) references public.journal_entries(company_id, id)
);
create index depreciation_entries_company_asset_idx on public.depreciation_entries (company_id, fixed_asset_id);
create index depreciation_entries_company_je_idx    on public.depreciation_entries (company_id, journal_entry_id);

do $$
declare t text;
begin
  foreach t in array array['loans','loan_payments','fixed_assets','depreciation_entries'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
