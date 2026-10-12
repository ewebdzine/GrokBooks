-- migration 20261013000116_0012_retainers_time_vendor_rules
-- GrokBooks 0012: retainer agreements, time entries, vendor category rules.
-- Generic, company-scoped tables (any company can use them). Same conventions as 0001:
-- uuid PKs, company_id + composite FKs, created_at/updated_at + set_updated_at trigger,
-- RLS enabled with no policies (deny by default; service role bypasses RLS).

-- time_entries.invoice_line_id needs a (company_id, id) key to reference, like every other table.
alter table public.invoice_lines add constraint invoice_lines_company_id_id_key unique (company_id, id);

-- Retainer agreements: a fixed monthly amount billed to a customer -----------------
create table public.retainer_agreements (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  customer_id     uuid not null,
  item_id         uuid,                               -- product/service used on the invoice line
  description     text,
  monthly_amount  numeric(12,2) not null check (monthly_amount >= 0),
  billing_day     smallint not null default 1 check (billing_day between 1 and 31),
  start_date      date not null,
  end_date        date,
  status          text not null default 'active' check (status in ('active','paused','ended')),
  auto_send       boolean not null default false,     -- email the invoice automatically when generated
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, id),
  check (end_date is null or end_date >= start_date),
  foreign key (company_id, customer_id) references public.customers(company_id, id),
  foreign key (company_id, item_id)     references public.items(company_id, id)
);
create index retainer_agreements_company_customer_idx on public.retainer_agreements (company_id, customer_id);
create index retainer_agreements_company_item_idx     on public.retainer_agreements (company_id, item_id);
create index retainer_agreements_company_status_idx   on public.retainer_agreements (company_id, status, billing_day);

-- Time entries: hours worked for a customer, optionally billed on an invoice line ---
create table public.time_entries (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  qbo_id           text,                              -- QB TimeActivity Id, if imported from QuickBooks
  customer_id      uuid not null,
  item_id          uuid,
  work_date        date not null,
  hours            numeric(6,2) not null check (hours > 0),
  hourly_rate      numeric(10,2) check (hourly_rate is null or hourly_rate >= 0),
  description      text,
  billable         boolean not null default true,
  invoice_id       uuid,                              -- set once billed
  invoice_line_id  uuid,
  source           text not null default 'manual',    -- e.g. manual, timer, import, qbo
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  check (invoice_line_id is null or invoice_id is not null),
  foreign key (company_id, customer_id) references public.customers(company_id, id),
  foreign key (company_id, item_id)     references public.items(company_id, id),
  -- QB re-syncs replace invoice lines, so losing a line (or invoice) only un-links the entry.
  foreign key (company_id, invoice_id)      references public.invoices(company_id, id)      on delete set null (invoice_id),
  foreign key (company_id, invoice_line_id) references public.invoice_lines(company_id, id) on delete set null (invoice_line_id)
);
create index time_entries_company_customer_date_idx on public.time_entries (company_id, customer_id, work_date);
create index time_entries_company_item_idx          on public.time_entries (company_id, item_id);
create index time_entries_company_invoice_idx       on public.time_entries (company_id, invoice_id);
create index time_entries_company_invoice_line_idx  on public.time_entries (company_id, invoice_line_id);
create index time_entries_unbilled_idx              on public.time_entries (company_id, customer_id, work_date)
  where billable and invoice_id is null;

-- Vendor category rules: how to categorize bank-feed lines --------------------------
create table public.vendor_category_rules (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  vendor_id        uuid,                              -- payee to assign (null = no vendor, e.g. bank memo only)
  match_pattern    text not null check (length(btrim(match_pattern)) > 0),  -- matched against the bank description
  match_type       text not null default 'contains' check (match_type in ('contains','starts_with','regex')),
  account_id       uuid not null,                     -- category (chart-of-accounts) to assign
  is_recurring     boolean not null default false,
  expected_amount  numeric(14,2),
  frequency        text check (frequency in ('monthly','annual','irregular')),
  priority         integer not null default 100,      -- lower number is evaluated first
  active           boolean not null default true,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, match_type, match_pattern),
  foreign key (company_id, vendor_id)  references public.vendors(company_id, id),
  foreign key (company_id, account_id) references public.accounts(company_id, id)
);
create index vendor_category_rules_company_active_priority_idx on public.vendor_category_rules (company_id, active, priority);
create index vendor_category_rules_company_vendor_idx  on public.vendor_category_rules (company_id, vendor_id);
create index vendor_category_rules_company_account_idx on public.vendor_category_rules (company_id, account_id);

do $$
declare t text;
begin
  foreach t in array array['retainer_agreements','time_entries','vendor_category_rules'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
