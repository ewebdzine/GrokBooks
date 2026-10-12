-- migration 20261013000101_0002_sales_receivables
-- GrokBooks 0002: sales / accounts receivable
-- invoices, invoice_lines, payments, payment_applications (many-to-many with application date),
-- over-application guards, and the invoice_balances / payment_unapplied views.

create table public.invoices (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  doc_number             text,
  customer_id            uuid not null,
  txn_date               date not null,
  due_date               date,
  ar_account_id          uuid,
  terms                  text,
  total_amount           numeric(14,2) not null check (total_amount >= 0),
  currency               char(3) not null default 'USD',
  private_note           text,
  customer_memo          text,
  bill_email             text,
  bill_address           jsonb,
  ship_address           jsonb,
  email_status           text,
  qbo_recur_template_id  text,                    -- QB RecurDataRef
  voided_at              timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  check (due_date is null or due_date >= txn_date),
  foreign key (company_id, customer_id)   references public.customers(company_id, id),
  foreign key (company_id, ar_account_id) references public.accounts(company_id, id)
);
create index invoices_company_customer_idx on public.invoices (company_id, customer_id);
create index invoices_company_ar_acct_idx  on public.invoices (company_id, ar_account_id);
create index invoices_company_txn_date_idx on public.invoices (company_id, txn_date);
create index invoices_company_doc_idx      on public.invoices (company_id, doc_number);

create table public.invoice_lines (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  invoice_id    uuid not null,
  qbo_line_id   text,                             -- QB Line.Id (unique within the invoice)
  line_num      integer,
  item_id       uuid,
  account_id    uuid,                             -- QB ItemAccountRef (income account)
  description   text,
  qty           numeric(14,4),
  unit_price    numeric(14,4),
  amount        numeric(14,2) not null,
  service_date  date,
  tax_code      text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (invoice_id, qbo_line_id),
  foreign key (company_id, invoice_id) references public.invoices(company_id, id) on delete cascade,
  foreign key (company_id, item_id)    references public.items(company_id, id),
  foreign key (company_id, account_id) references public.accounts(company_id, id)
);
create index invoice_lines_company_invoice_idx on public.invoice_lines (company_id, invoice_id);
create index invoice_lines_company_item_idx    on public.invoice_lines (company_id, item_id);
create index invoice_lines_company_account_idx on public.invoice_lines (company_id, account_id);

-- One row per money received (check, ACH, card, Stripe).
create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete cascade,
  qbo_id              text,
  qbo_sync_token      text,
  customer_id         uuid not null,
  payment_date        date not null,
  amount              numeric(14,2) not null check (amount >= 0),  -- 0 allowed: QB credit-only payments
  method              text not null default 'other'
                        check (method in ('check','ach','card','cash','stripe','other')),
  reference           text,                        -- check number, etc.
  deposit_account_id  uuid,                        -- Checking or Undeposited Funds
  ar_account_id       uuid,
  txn_source          text,                        -- QB TxnSource
  memo                text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  foreign key (company_id, customer_id)        references public.customers(company_id, id),
  foreign key (company_id, deposit_account_id) references public.accounts(company_id, id),
  foreign key (company_id, ar_account_id)      references public.accounts(company_id, id)
);
create index payments_company_customer_idx    on public.payments (company_id, customer_id);
create index payments_company_deposit_acct_idx on public.payments (company_id, deposit_account_id);
create index payments_company_ar_acct_idx     on public.payments (company_id, ar_account_id);
create index payments_company_date_idx        on public.payments (company_id, payment_date);

-- One row = one slice of one payment applied to one invoice (QB Payment Line[].LinkedTxn).
create table public.payment_applications (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  payment_id      uuid not null,
  invoice_id      uuid not null,
  amount_applied  numeric(14,2) not null check (amount_applied > 0),
  applied_on      date not null,                   -- defaults to the payment date (trigger)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (payment_id, invoice_id),
  foreign key (company_id, payment_id) references public.payments(company_id, id) on delete cascade,
  foreign key (company_id, invoice_id) references public.invoices(company_id, id)
);
create index payment_applications_company_payment_idx on public.payment_applications (company_id, payment_id);
create index payment_applications_company_invoice_idx on public.payment_applications (company_id, invoice_id);

-- Guard: slices never exceed the payment, and never over-apply an invoice.
-- Locks the payment row then the invoice row (always in that order) so concurrent
-- applications serialize instead of both passing the check.
create or replace function public.check_payment_application()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  pay_total numeric; pay_date date; pay_applied numeric;
  inv_total numeric; inv_applied numeric;
begin
  select p.amount, p.payment_date into pay_total, pay_date
    from public.payments p where p.id = new.payment_id for update;
  if new.applied_on is null then
    new.applied_on := pay_date;
  end if;
  select coalesce(sum(pa.amount_applied), 0) into pay_applied
    from public.payment_applications pa
   where pa.payment_id = new.payment_id and pa.id is distinct from new.id;
  if pay_applied + new.amount_applied > pay_total then
    raise exception 'Payment % over-applied: % + % > %',
      new.payment_id, pay_applied, new.amount_applied, pay_total
      using errcode = 'check_violation';
  end if;

  select i.total_amount into inv_total
    from public.invoices i where i.id = new.invoice_id for update;
  select coalesce(sum(pa.amount_applied), 0) into inv_applied
    from public.payment_applications pa
   where pa.invoice_id = new.invoice_id and pa.id is distinct from new.id;
  if inv_applied + new.amount_applied > inv_total then
    raise exception 'Invoice % over-paid: % + % > %',
      new.invoice_id, inv_applied, new.amount_applied, inv_total
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger payment_applications_check
  before insert or update on public.payment_applications
  for each row execute function public.check_payment_application();

-- Guard: a payment's amount can't drop below what is already applied.
create or replace function public.check_payment_amount()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.amount < (select coalesce(sum(pa.amount_applied), 0)
                     from public.payment_applications pa where pa.payment_id = new.id) then
    raise exception 'Payment % amount is below its applied total', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger payments_amount_check
  before update of amount on public.payments
  for each row execute function public.check_payment_amount();

-- Guard: an invoice total can't drop below what is already paid.
create or replace function public.check_invoice_total()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.total_amount < (select coalesce(sum(pa.amount_applied), 0)
                           from public.payment_applications pa where pa.invoice_id = new.id) then
    raise exception 'Invoice % total is below its paid amount', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger invoices_total_check
  before update of total_amount on public.invoices
  for each row execute function public.check_invoice_total();

-- Balances are always calculated, never typed in.
create view public.invoice_balances
with (security_invoker = true) as
select i.id as invoice_id,
       i.company_id,
       i.customer_id,
       i.doc_number,
       i.txn_date,
       i.due_date,
       i.total_amount,
       coalesce(sum(pa.amount_applied), 0)                  as amount_paid,
       i.total_amount - coalesce(sum(pa.amount_applied), 0) as balance,
       case when i.voided_at is not null then 'void'
            when coalesce(sum(pa.amount_applied), 0) = 0 and i.total_amount > 0 then 'unpaid'
            when coalesce(sum(pa.amount_applied), 0) < i.total_amount then 'partial'
            else 'paid' end                                 as status,
       min(pa.applied_on)                                   as first_payment_date,
       max(pa.applied_on)                                   as last_payment_date
from public.invoices i
left join public.payment_applications pa on pa.invoice_id = i.id
group by i.id;

-- Unapplied money is its own item (a customer credit), not a hidden leftover.
create view public.payment_unapplied
with (security_invoker = true) as
select p.id as payment_id,
       p.company_id,
       p.customer_id,
       p.payment_date,
       p.amount,
       coalesce(sum(pa.amount_applied), 0)            as applied,
       p.amount - coalesce(sum(pa.amount_applied), 0) as unapplied
from public.payments p
left join public.payment_applications pa on pa.payment_id = p.id
group by p.id;

do $$
declare t text;
begin
  foreach t in array array['invoices','invoice_lines','payments','payment_applications'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
