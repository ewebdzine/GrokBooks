-- migration 20261013000103_0004_deposits_journals_banking
-- GrokBooks 0004: deposits, journal entries (balanced double entry), bank accounts,
-- imported bank transactions and reconciliations.

-- Deposits ------------------------------------------------------------------
create table public.deposits (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  txn_date               date not null,
  deposit_to_account_id  uuid not null,
  total_amount           numeric(14,2) not null,
  private_note           text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  foreign key (company_id, deposit_to_account_id) references public.accounts(company_id, id)
);
create index deposits_company_acct_idx on public.deposits (company_id, deposit_to_account_id);
create index deposits_company_date_idx on public.deposits (company_id, txn_date);

create table public.deposit_lines (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  deposit_id      uuid not null,
  qbo_line_id     text,
  line_num        integer,
  account_id      uuid,                           -- DepositLineDetail.AccountRef (source account)
  payment_id      uuid,                           -- customer payment swept out of Undeposited Funds
  customer_id     uuid,                           -- DepositLineDetail.Entity (customer)
  vendor_id       uuid,                           -- DepositLineDetail.Entity (vendor)
  description     text,
  amount          numeric(14,2) not null,
  payment_method  text,
  check_number    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (deposit_id, qbo_line_id),
  check (account_id is not null or payment_id is not null),
  check (customer_id is null or vendor_id is null),
  foreign key (company_id, deposit_id)  references public.deposits(company_id, id) on delete cascade,
  foreign key (company_id, account_id)  references public.accounts(company_id, id),
  foreign key (company_id, payment_id)  references public.payments(company_id, id),
  foreign key (company_id, customer_id) references public.customers(company_id, id),
  foreign key (company_id, vendor_id)   references public.vendors(company_id, id)
);
create index deposit_lines_company_deposit_idx  on public.deposit_lines (company_id, deposit_id);
create index deposit_lines_company_account_idx  on public.deposit_lines (company_id, account_id);
create index deposit_lines_company_customer_idx on public.deposit_lines (company_id, customer_id);
create index deposit_lines_company_vendor_idx   on public.deposit_lines (company_id, vendor_id);
-- A payment can only be deposited once.
create unique index deposit_lines_payment_once_idx on public.deposit_lines (company_id, payment_id)
  where payment_id is not null;

-- Journal entries -----------------------------------------------------------
create table public.journal_entries (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  qbo_id          text,
  qbo_sync_token  text,
  doc_number      text,
  txn_date        date not null,
  is_adjustment   boolean not null default false,
  private_note    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id)
);
create index journal_entries_company_date_idx on public.journal_entries (company_id, txn_date);

create table public.journal_lines (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete cascade,
  journal_entry_id  uuid not null,
  qbo_line_id       text,
  line_num          integer,
  posting_type      text not null check (posting_type in ('debit','credit')),
  amount            numeric(14,2) not null check (amount >= 0),
  account_id        uuid not null,
  customer_id       uuid,
  vendor_id         uuid,
  description       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (journal_entry_id, qbo_line_id),
  check (customer_id is null or vendor_id is null),
  foreign key (company_id, journal_entry_id) references public.journal_entries(company_id, id) on delete cascade,
  foreign key (company_id, account_id)       references public.accounts(company_id, id),
  foreign key (company_id, customer_id)      references public.customers(company_id, id),
  foreign key (company_id, vendor_id)        references public.vendors(company_id, id)
);
create index journal_lines_company_entry_idx    on public.journal_lines (company_id, journal_entry_id);
create index journal_lines_company_account_idx  on public.journal_lines (company_id, account_id);
create index journal_lines_company_customer_idx on public.journal_lines (company_id, customer_id);
create index journal_lines_company_vendor_idx   on public.journal_lines (company_id, vendor_id);

-- Debits must equal credits per entry. Deferred to commit time so all lines of an
-- entry can be inserted in one transaction.
create or replace function public.check_journal_entry_balanced()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  entry_ids uuid[];
  e uuid;
  dr numeric; cr numeric;
begin
  if tg_op = 'DELETE' then
    entry_ids := array[old.journal_entry_id];
  elsif tg_op = 'UPDATE' then
    entry_ids := array[old.journal_entry_id, new.journal_entry_id];
  else
    entry_ids := array[new.journal_entry_id];
  end if;
  foreach e in array entry_ids loop
    select coalesce(sum(amount) filter (where posting_type = 'debit'), 0),
           coalesce(sum(amount) filter (where posting_type = 'credit'), 0)
      into dr, cr
      from public.journal_lines where journal_entry_id = e;
    if dr <> cr then
      raise exception 'Journal entry % is out of balance: debits % <> credits %', e, dr, cr
        using errcode = 'check_violation';
    end if;
  end loop;
  return null;
end $$;

create constraint trigger journal_lines_balanced
  after insert or update or delete on public.journal_lines
  deferrable initially deferred
  for each row execute function public.check_journal_entry_balanced();

-- Bank accounts and imported bank CSV rows ---------------------------------
create table public.bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete cascade,
  account_id        uuid not null,                -- the chart-of-accounts Bank / Credit Card account
  name              text not null,
  institution_name  text,
  account_mask      text check (account_mask is null or account_mask ~ '^[0-9]{2,4}$'),  -- last digits only
  account_kind      text not null default 'checking'
                      check (account_kind in ('checking','savings','credit_card','other')),
  currency          char(3) not null default 'USD',
  is_active         boolean not null default true,
  last_imported_at  timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, account_id),
  foreign key (company_id, account_id) references public.accounts(company_id, id)
);

create table public.reconciliations (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  bank_account_id       uuid not null,
  statement_start_date  date,
  statement_end_date    date not null,
  beginning_balance     numeric(14,2) not null,
  ending_balance        numeric(14,2) not null,
  status                text not null default 'in_progress' check (status in ('in_progress','completed')),
  completed_at          timestamptz,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, id),
  unique (bank_account_id, statement_end_date),
  check (statement_start_date is null or statement_start_date <= statement_end_date),
  check ((status = 'completed') = (completed_at is not null)),
  foreign key (company_id, bank_account_id) references public.bank_accounts(company_id, id)
);
create index reconciliations_company_bank_idx on public.reconciliations (company_id, bank_account_id);

create table public.bank_transactions (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete cascade,
  bank_account_id    uuid not null,
  posted_date        date not null,
  amount             numeric(14,2) not null,      -- signed: positive = money in, negative = money out
  description        text,
  payee              text,
  check_number       text,
  bank_reference     text,                        -- bank's own transaction id (FITID) when present
  row_fingerprint    text not null,               -- hash of the normalized CSV row, for idempotent re-imports
  import_batch_id    uuid,
  source_filename    text,
  raw                jsonb,                       -- original CSV row
  status             text not null default 'unreviewed'
                       check (status in ('unreviewed','matched','categorized','excluded')),
  matched_txn_type   text check (matched_txn_type in
                       ('payment','deposit','purchase','bill_payment','journal_entry')),
  matched_txn_id     uuid,
  reconciliation_id  uuid,
  cleared_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (bank_account_id, row_fingerprint),
  check ((matched_txn_type is null) = (matched_txn_id is null)),
  foreign key (company_id, bank_account_id)   references public.bank_accounts(company_id, id),
  foreign key (company_id, reconciliation_id) references public.reconciliations(company_id, id)
);
create index bank_transactions_company_bank_date_idx on public.bank_transactions (company_id, bank_account_id, posted_date);
create index bank_transactions_company_recon_idx     on public.bank_transactions (company_id, reconciliation_id);
create index bank_transactions_matched_idx           on public.bank_transactions (matched_txn_type, matched_txn_id)
  where matched_txn_id is not null;

do $$
declare t text;
begin
  foreach t in array array['deposits','deposit_lines','journal_entries','journal_lines','bank_accounts','reconciliations','bank_transactions'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
