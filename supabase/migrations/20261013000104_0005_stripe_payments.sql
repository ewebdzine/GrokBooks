-- migration 20261013000104_0005_stripe_payments
-- GrokBooks 0005: Stripe link tables (design v2).
-- GrokBooks is the source of truth; Stripe only stores payment methods and runs charges.
-- Recurring = US bank account (ACH) only; cards = one-off only.

alter table public.customers
  add column stripe_customer_id         text unique,     -- cus_...
  add column stripe_synced_at           timestamptz,
  add column autopay_enabled            boolean not null default false,
  add column autopay_payment_method_id  uuid;

-- Saved payment methods (Stripe holds the actual bank or card details).
create table public.payment_methods (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid not null references public.companies(id) on delete cascade,
  customer_id               uuid not null,
  stripe_payment_method_id  text not null unique,         -- pm_...
  type                      text not null check (type in ('us_bank_account','card')),
  usage                     text not null check (usage in ('recurring','one_off')),
  bank_name                 text,
  last4                     text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  card_brand                text,
  stripe_mandate_id         text,                         -- ACH debit authorization (mandate_...)
  status                    text not null default 'active'
                              check (status in ('active','verification_pending','inactive')),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, customer_id, id),
  -- Recurring = bank only (with a mandate). Cards = one-off only.
  check ((type = 'us_bank_account' and usage = 'recurring' and stripe_mandate_id is not null)
      or (type = 'us_bank_account' and usage = 'one_off')
      or (type = 'card' and usage = 'one_off')),
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create index payment_methods_company_customer_idx on public.payment_methods (company_id, customer_id);

-- Autopay method must belong to the same customer.
alter table public.customers
  add constraint customers_autopay_pm_fk
  foreign key (company_id, id, autopay_payment_method_id)
  references public.payment_methods(company_id, customer_id, id);
create index customers_autopay_pm_idx on public.customers (company_id, id, autopay_payment_method_id);
alter table public.customers
  add constraint customers_autopay_requires_pm
  check (not autopay_enabled or autopay_payment_method_id is not null);

-- One row per charge attempt. A failed ACH debit retried by hand is a new attempt.
create table public.charge_attempts (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid not null references public.companies(id) on delete cascade,
  invoice_id                uuid not null,
  payment_method_id         uuid not null,
  attempt_number            integer not null default 1 check (attempt_number > 0),
  amount                    numeric(14,2) not null check (amount > 0),
  stripe_payment_intent_id  text not null unique,         -- pi_...
  idempotency_key           text unique,                  -- inv-<invoice_id>-attempt-<n>
  status                    text not null check (status in
                              ('requires_action','processing','succeeded','failed','canceled')),
  failure_code              text,                         -- e.g. insufficient_funds, account_closed
  failure_message           text,
  initiated_by              text not null check (initiated_by in ('autopay','manual')),
  settled_at                timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (company_id, id),
  unique (invoice_id, attempt_number),
  foreign key (company_id, invoice_id)        references public.invoices(company_id, id),
  foreign key (company_id, payment_method_id) references public.payment_methods(company_id, id)
);
create index charge_attempts_company_invoice_idx on public.charge_attempts (company_id, invoice_id);
create index charge_attempts_company_pm_idx      on public.charge_attempts (company_id, payment_method_id);
-- Stops the same invoice from being charged twice at once.
create unique index charge_attempts_one_live_per_invoice on public.charge_attempts (invoice_id)
  where status in ('requires_action','processing');

-- Stripe link columns on payments.
alter table public.payments
  add column charge_attempt_id  uuid unique,              -- set for Stripe payments
  add column stripe_charge_id   text unique,              -- ch_... / py_...
  add column stripe_fee         numeric(14,2) check (stripe_fee is null or stripe_fee >= 0),
  add constraint payments_charge_attempt_fk
    foreign key (company_id, charge_attempt_id) references public.charge_attempts(company_id, id);
create index payments_company_charge_attempt_idx on public.payments (company_id, charge_attempt_id);

-- Stripe webhook log: a replayed event can never post twice.
create table public.stripe_events (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid references public.companies(id) on delete cascade,  -- null until routed to a tenant
  stripe_event_id  text not null unique,                  -- evt_...
  type             text not null,
  livemode         boolean not null default false,
  payload          jsonb not null,
  received_at      timestamptz not null default now(),
  processed_at     timestamptz,
  error            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index stripe_events_company_idx on public.stripe_events (company_id);
create index stripe_events_unprocessed_idx on public.stripe_events (received_at) where processed_at is null;

do $$
declare t text;
begin
  foreach t in array array['payment_methods','charge_attempts','stripe_events'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
