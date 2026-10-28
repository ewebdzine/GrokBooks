# GrokBooks: Stripe sync and payment applications (draft v2, Sep 30, 2026)

GrokBooks (Supabase/Postgres) is the source of truth. Stripe is only used to collect payments. Stripe IDs are stored on our rows as link columns, and Stripe never owns a customer, invoice or balance.

## Decided
1. **Billing logic lives in GrokBooks, not Stripe.** Stripe only stores payment methods and runs the charges. GrokBooks decides what to bill, when and for how much, and creates one PaymentIntent per invoice each billing cycle. There are no Stripe Subscription, Price, Product or Stripe Invoice objects, and no effort to keep Stripe in step with our recurring billing.
2. **Recurring payments are bank ACH only.** Only a couple of tenants will use recurring payments, and rent is the main case. Stripe's built-in retry and dunning (collections follow-up) are not being built now. A failed ACH payment gets flagged in GrokBooks and retried by hand.
3. **Allowed payment types:** US bank account (ACH) for recurring payments, and cards for one-off charges only. No wallets (Apple Pay, Google Pay), no Stripe Link, and no other third-party methods. Every PaymentIntent and SetupIntent sets `payment_method_types` explicitly (`['us_bank_account']` or `['card']`) and never uses automatic payment methods, so nothing else can show up.

## 1. Schema additions

```sql
-- Customers: we own identity. Stripe gets a copy of the email.
alter table customers
  add column qb_customer_id      text unique,          -- QuickBooks Customer.Id
  add column stripe_customer_id  text unique,          -- cus_...
  add column stripe_synced_at    timestamptz;

alter table customers
  add column autopay_enabled     boolean not null default false,
  add column autopay_payment_method_id bigint;      -- FK added below

-- Saved payment methods (Stripe holds the actual bank or card details).
create table payment_methods (
  id                        bigint generated always as identity primary key,
  customer_id               bigint not null references customers(id),
  stripe_payment_method_id  text not null unique,   -- pm_...
  type                      text not null check (type in ('us_bank_account','card')),
  usage                     text not null check (usage in ('recurring','one_off')),
  bank_name text, last4 text, card_brand text,
  stripe_mandate_id         text,                   -- ACH debit authorization (mandate_...)
  status                    text not null default 'active'
                            check (status in ('active','verification_pending','inactive')),
  created_at                timestamptz not null default now(),
  -- Recurring = bank only. Cards = one-off only.
  check ((type = 'us_bank_account' and usage = 'recurring' and stripe_mandate_id is not null)
      or (type = 'card' and usage = 'one_off')
      or (type = 'us_bank_account' and usage = 'one_off'))
);
alter table customers add constraint autopay_pm_fk
  foreign key (autopay_payment_method_id) references payment_methods(id);

-- Invoices: we generate them. Stripe only charges them.
alter table invoices
  add column qb_invoice_id       text unique;

-- One row per charge attempt. A failed ACH debit that gets retried by hand becomes a new attempt.
create table charge_attempts (
  id                        bigint generated always as identity primary key,
  invoice_id                bigint not null references invoices(id),
  payment_method_id         bigint not null references payment_methods(id),
  amount                    numeric(12,2) not null check (amount > 0),
  stripe_payment_intent_id  text not null unique,   -- pi_...
  status                    text not null check (status in
        ('requires_action','processing','succeeded','failed','canceled')),
  failure_code              text,                   -- e.g. insufficient_funds, account_closed
  initiated_by              text not null check (initiated_by in ('autopay','manual')),
  created_at                timestamptz not null default now(),
  settled_at                timestamptz
);
-- Stops the same invoice from being charged twice at once.
create unique index one_live_attempt_per_invoice on charge_attempts (invoice_id)
  where status in ('requires_action','processing');

-- Payments: one row per money received (check, ACH, card, Stripe).
create table payments (
  id                  bigint generated always as identity primary key,
  customer_id         bigint not null references customers(id),
  payment_date        date   not null,
  amount              numeric(12,2) not null check (amount > 0),
  method              text   not null,               -- check, ach, card, stripe
  reference           text,                          -- check number, etc.
  deposit_account_id  bigint references accounts(id),-- Checking or Undeposited Funds
  qb_payment_id       text unique,
  charge_attempt_id   bigint unique references charge_attempts(id), -- set for Stripe payments
  stripe_charge_id    text unique,                   -- ch_... / py_...
  stripe_fee          numeric(12,2),                 -- posted to Bank Charges / QB Payments Fees
  memo                text,
  created_at          timestamptz not null default now()
);

-- Payment applications: follows Fivetran's payment_line pattern.
-- One row = one slice of one payment applied to one invoice.
create table payment_applications (
  id                bigint generated always as identity primary key,
  payment_id        bigint not null references payments(id) on delete cascade,
  invoice_id        bigint not null references invoices(id),
  amount_applied    numeric(12,2) not null check (amount_applied > 0),
  applied_on        date,                            -- optional; defaults to payment_date in views
  created_at        timestamptz not null default now(),
  unique (payment_id, invoice_id)
);
create index on payment_applications (invoice_id);

-- Rule 1: slices can never exceed the payment.
-- Rule 2: can never over-apply an invoice.
create or replace function check_payment_application() returns trigger
language plpgsql as $$
declare pay_total numeric; pay_applied numeric; inv_total numeric; inv_applied numeric;
begin
  select amount into pay_total from payments where id = new.payment_id for update;
  select coalesce(sum(amount_applied),0) into pay_applied
    from payment_applications where payment_id = new.payment_id and id <> coalesce(new.id,-1);
  if pay_applied + new.amount_applied > pay_total then
    raise exception 'Payment % over-applied: % + % > %',
      new.payment_id, pay_applied, new.amount_applied, pay_total;
  end if;

  select total_amount into inv_total from invoices where id = new.invoice_id for update;
  select coalesce(sum(amount_applied),0) into inv_applied
    from payment_applications where invoice_id = new.invoice_id and id <> coalesce(new.id,-1);
  if inv_applied + new.amount_applied > inv_total then
    raise exception 'Invoice % over-paid: % + % > %',
      new.invoice_id, inv_applied, new.amount_applied, inv_total;
  end if;
  return new;
end $$;

create trigger payment_applications_check
  before insert or update on payment_applications
  for each row execute function check_payment_application();

-- Also block lowering a payment's amount below what is already applied.
create or replace function check_payment_amount() returns trigger
language plpgsql as $$
begin
  if new.amount < (select coalesce(sum(amount_applied),0)
                   from payment_applications where payment_id = new.id) then
    raise exception 'Payment % amount is below its applied total', new.id;
  end if;
  return new;
end $$;
create trigger payments_amount_check before update of amount on payments
  for each row execute function check_payment_amount();

-- Balances are always calculated, never typed in.
create view invoice_balances as
select i.id as invoice_id, i.total_amount,
       coalesce(sum(pa.amount_applied),0)                  as amount_paid,
       i.total_amount - coalesce(sum(pa.amount_applied),0) as balance,
       case when coalesce(sum(pa.amount_applied),0) = 0 then 'unpaid'
            when coalesce(sum(pa.amount_applied),0) < i.total_amount then 'partial'
            else 'paid' end                                as status,
       min(coalesce(pa.applied_on, p.payment_date))        as first_payment_date,
       max(coalesce(pa.applied_on, p.payment_date))        as last_payment_date
from invoices i
left join payment_applications pa on pa.invoice_id = i.id
left join payments p on p.id = pa.payment_id
group by i.id, i.total_amount;

-- Unapplied money is its own item (a customer credit), not a hidden leftover.
create view payment_unapplied as
select p.id as payment_id, p.customer_id, p.amount,
       coalesce(sum(pa.amount_applied),0)            as applied,
       p.amount - coalesce(sum(pa.amount_applied),0) as unapplied
from payments p left join payment_applications pa on pa.payment_id = p.id
group by p.id;

-- Stripe webhook log: a replayed event can never post twice.
create table stripe_events (
  id            text primary key,       -- evt_...
  type          text not null,
  payload       jsonb not null,
  received_at   timestamptz not null default now(),
  processed_at  timestamptz,
  error         text
);
```

Why a trigger and not a CHECK constraint: Postgres CHECK constraints can't look at other rows, so enforcing a sum takes a trigger. The `for update` locks stop two payments posting at the same moment from both passing the check.

## 2. Sync flow

### A. Customer sync (GrokBooks to Stripe)
1. A tenant is added or edited in `customers`.
2. If `stripe_customer_id` is empty, create the Stripe Customer with email, name and `metadata.grokbooks_customer_id` (and `qb_customer_id` if known). Send an idempotency key of `cust-<id>`.
3. Save the returned `cus_...` ID into `stripe_customer_id` and set `stripe_synced_at`.
4. When the email or name changes on our side, update the Stripe Customer. Changes made in Stripe are ignored, because our row wins.

### B. Collecting payment (GrokBooks decides, Stripe charges)
**Saving a payment method**
- *Bank account for recurring payments:* create a SetupIntent with `payment_method_types=['us_bank_account']`, `usage='off_session'` and the tenant's `stripe_customer_id`. The tenant links a bank through Stripe's bank connection (Financial Connections), or by entering account numbers with microdeposit verification, and accepts the ACH debit authorization. We save the `pm_...` ID and `mandate_...` ID in `payment_methods` with usage 'recurring', then set `customers.autopay_enabled` and `autopay_payment_method_id`.
- *Card for one-off charges:* the card is collected at the moment of payment on a PaymentIntent with `payment_method_types=['card']`. It isn't saved for recurring use; `setup_future_usage` is never set for cards.

**Each billing cycle (GrokBooks is the scheduler)**
1. A scheduled job in GrokBooks (Supabase cron) creates the month's invoices from each lease's rent and CAM amounts.
2. For tenants with autopay on, on the due date, it creates a PaymentIntent: `amount` = the invoice balance from `invoice_balances`, `currency='usd'`, `customer`, `payment_method` = the saved bank account, `payment_method_types=['us_bank_account']`, `off_session=true`, `confirm=true`, `metadata.grokbooks_invoice_id`. The idempotency key is `inv-<invoice_id>-attempt-<n>`. It inserts a `charge_attempts` row with status 'processing'. ACH usually takes about 4 business days to settle.
3. Tenants without autopay get our own invoice email. For a one-off card payment, we create a card-only PaymentIntent on demand, and the tenant pays on our own pay page with Stripe's card field. There are no Stripe-hosted invoices or payment links.

**Webhooks** (a Supabase Edge Function checks each notification's Stripe signature, logs it once in `stripe_events`, then acts on it)
- `payment_intent.processing`: the attempt stays 'processing'. Nothing is posted yet.
- `payment_intent.succeeded`: set the attempt to 'succeeded'. Create the `payments` row (method 'ach' or 'card', `stripe_charge_id`, `charge_attempt_id`, deposit account = Undeposited Funds until the payout lands). Create a `payment_applications` row for the invoice. Record the fee from the balance transaction in `stripe_fee`, posted to a bank-charges expense account.
- `payment_intent.payment_failed`: set the attempt to 'failed' with `failure_code` and flag the invoice for follow-up. Nothing is posted and there's no automatic retry. Retrying is a manual action that creates a new attempt. For codes like `account_closed` or a revoked authorization, set the payment method to 'inactive' and turn off autopay.
- `charge.dispute.created` / `charge.refunded`: flag for review. We reverse the payment application by hand after deciding.

**Payments outside Stripe** (checks, direct ACH to the bank): record the payment and its applications in GrokBooks. There's nothing to update in Stripe because it holds no invoice.

### C. Payment applications
- **One payment across several invoices**: one `payments` row plus one `payment_applications` row per invoice. The trigger stops the slices from adding up to more than the payment.
- **Partial payment**: an application smaller than the invoice total. `invoice_balances.status` then reads 'partial'. Autopay always charges the current balance, so partial payments usually arrive as checks entered in GrokBooks.
- **Leftover or unapplied money**: the payment stays partly unapplied. It appears in `payment_unapplied` as a customer credit, which can be applied to the next invoice later with its own `applied_on` date.
- **QuickBooks import**: each QuickBooks Payment becomes a `payments` row. Each `Line[].LinkedTxn` with TxnType 'Invoice' becomes a `payment_applications` row using `Line[].Amount`. Then run a check that `invoice_balances.balance` matches the QuickBooks `Invoice.Balance`.

## 3. Still open
- Card fees on one-off charges: keep adding the card processing fee as a separate invoice line (current practice) or absorb it. ACH fees are small and absorbed.
- Whether Stripe payouts should create deposit rows automatically (sweeping Undeposited Funds into Checking).
- Build and test everything in Stripe test mode first, using separate test keys.
