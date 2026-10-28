-- migration 20261013000105_0006_transfers_import_issues
-- GrokBooks 0006: transfers between balance-sheet accounts, an import issue log,
-- and relaxing the invoice due-date check (QuickBooks allows a due date before the invoice date).

create table public.transfers (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  txn_date               date not null,
  from_account_id        uuid not null,
  to_account_id          uuid not null,
  amount                 numeric(14,2) not null check (amount > 0),
  private_note           text,
  qbo_recur_template_id  text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  check (from_account_id <> to_account_id),
  foreign key (company_id, from_account_id) references public.accounts(company_id, id),
  foreign key (company_id, to_account_id)   references public.accounts(company_id, id)
);
create index transfers_company_from_idx on public.transfers (company_id, from_account_id);
create index transfers_company_to_idx   on public.transfers (company_id, to_account_id);
create index transfers_company_date_idx on public.transfers (company_id, txn_date);

-- Rows an import rejected, skipped or adjusted, so nothing disappears silently.
create table public.import_issues (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  source          text not null default 'qbo',
  entity          text not null,                  -- e.g. 'payment_application'
  qbo_id          text,
  related_qbo_id  text,
  action          text not null check (action in ('rejected','skipped','adjusted')),
  reason          text not null,
  payload         jsonb,
  resolved_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index import_issues_company_idx on public.import_issues (company_id, entity);

alter table public.invoices drop constraint if exists invoices_check;

alter table public.bank_transactions drop constraint if exists bank_transactions_matched_txn_type_check;
alter table public.bank_transactions add constraint bank_transactions_matched_txn_type_check
  check (matched_txn_type in ('payment','deposit','purchase','bill_payment','journal_entry','transfer'));

do $$
declare t text;
begin
  foreach t in array array['transfers','import_issues'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
