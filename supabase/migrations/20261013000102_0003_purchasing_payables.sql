-- migration 20261013000102_0003_purchasing_payables
-- GrokBooks 0003: purchasing / accounts payable
-- bills, bill_lines, bill_payments, bill_payment_applications (with over-application guards),
-- purchases (direct expenses / checks / card charges) and purchase_lines,
-- plus bill_balances / bill_payment_unapplied views.

create table public.bills (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  doc_number             text,
  vendor_id              uuid not null,
  txn_date               date not null,
  due_date               date,
  ap_account_id          uuid,
  terms                  text,
  total_amount           numeric(14,2) not null check (total_amount >= 0),
  currency               char(3) not null default 'USD',
  private_note           text,
  vendor_address         jsonb,
  qbo_recur_template_id  text,
  voided_at              timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  foreign key (company_id, vendor_id)     references public.vendors(company_id, id),
  foreign key (company_id, ap_account_id) references public.accounts(company_id, id)
);
create index bills_company_vendor_idx   on public.bills (company_id, vendor_id);
create index bills_company_ap_acct_idx  on public.bills (company_id, ap_account_id);
create index bills_company_txn_date_idx on public.bills (company_id, txn_date);

create table public.bill_lines (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  bill_id          uuid not null,
  qbo_line_id      text,
  line_num         integer,
  detail_type      text not null default 'account' check (detail_type in ('account','item')),
  account_id       uuid,                          -- AccountBasedExpenseLineDetail.AccountRef
  item_id          uuid,                          -- ItemBasedExpenseLineDetail.ItemRef
  description      text,
  qty              numeric(14,4),
  unit_price       numeric(14,4),
  amount           numeric(14,2) not null,
  customer_id      uuid,                          -- billable-to customer
  billable_status  text check (billable_status in ('Billable','NotBillable','HasBeenBilled')),
  tax_code         text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (bill_id, qbo_line_id),
  check (account_id is not null or item_id is not null),
  foreign key (company_id, bill_id)     references public.bills(company_id, id) on delete cascade,
  foreign key (company_id, account_id)  references public.accounts(company_id, id),
  foreign key (company_id, item_id)     references public.items(company_id, id),
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create index bill_lines_company_bill_idx     on public.bill_lines (company_id, bill_id);
create index bill_lines_company_account_idx  on public.bill_lines (company_id, account_id);
create index bill_lines_company_item_idx     on public.bill_lines (company_id, item_id);
create index bill_lines_company_customer_idx on public.bill_lines (company_id, customer_id);

create table public.bill_payments (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  qbo_id           text,
  qbo_sync_token   text,
  doc_number       text,                          -- check number
  vendor_id        uuid not null,
  txn_date         date not null,
  amount           numeric(14,2) not null check (amount >= 0),
  pay_type         text not null default 'check' check (pay_type in ('check','credit_card')),
  payment_account_id uuid,                        -- CheckPayment.BankAccountRef / CreditCardPayment.CCAccountRef
  ap_account_id    uuid,
  print_status     text,
  private_note     text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  foreign key (company_id, vendor_id)          references public.vendors(company_id, id),
  foreign key (company_id, payment_account_id) references public.accounts(company_id, id),
  foreign key (company_id, ap_account_id)      references public.accounts(company_id, id)
);
create index bill_payments_company_vendor_idx   on public.bill_payments (company_id, vendor_id);
create index bill_payments_company_pay_acct_idx on public.bill_payments (company_id, payment_account_id);
create index bill_payments_company_ap_acct_idx  on public.bill_payments (company_id, ap_account_id);
create index bill_payments_company_date_idx     on public.bill_payments (company_id, txn_date);

create table public.bill_payment_applications (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  bill_payment_id  uuid not null,
  bill_id          uuid not null,
  amount_applied   numeric(14,2) not null check (amount_applied > 0),
  applied_on       date not null,                 -- defaults to the bill payment date (trigger)
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (bill_payment_id, bill_id),
  foreign key (company_id, bill_payment_id) references public.bill_payments(company_id, id) on delete cascade,
  foreign key (company_id, bill_id)         references public.bills(company_id, id)
);
create index bill_payment_applications_company_bp_idx   on public.bill_payment_applications (company_id, bill_payment_id);
create index bill_payment_applications_company_bill_idx on public.bill_payment_applications (company_id, bill_id);

create or replace function public.check_bill_payment_application()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  pay_total numeric; pay_date date; pay_applied numeric;
  bill_total numeric; bill_applied numeric;
begin
  select bp.amount, bp.txn_date into pay_total, pay_date
    from public.bill_payments bp where bp.id = new.bill_payment_id for update;
  if new.applied_on is null then
    new.applied_on := pay_date;
  end if;
  select coalesce(sum(a.amount_applied), 0) into pay_applied
    from public.bill_payment_applications a
   where a.bill_payment_id = new.bill_payment_id and a.id is distinct from new.id;
  if pay_applied + new.amount_applied > pay_total then
    raise exception 'Bill payment % over-applied: % + % > %',
      new.bill_payment_id, pay_applied, new.amount_applied, pay_total
      using errcode = 'check_violation';
  end if;

  select b.total_amount into bill_total
    from public.bills b where b.id = new.bill_id for update;
  select coalesce(sum(a.amount_applied), 0) into bill_applied
    from public.bill_payment_applications a
   where a.bill_id = new.bill_id and a.id is distinct from new.id;
  if bill_applied + new.amount_applied > bill_total then
    raise exception 'Bill % over-paid: % + % > %',
      new.bill_id, bill_applied, new.amount_applied, bill_total
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger bill_payment_applications_check
  before insert or update on public.bill_payment_applications
  for each row execute function public.check_bill_payment_application();

create or replace function public.check_bill_payment_amount()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.amount < (select coalesce(sum(a.amount_applied), 0)
                     from public.bill_payment_applications a where a.bill_payment_id = new.id) then
    raise exception 'Bill payment % amount is below its applied total', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger bill_payments_amount_check
  before update of amount on public.bill_payments
  for each row execute function public.check_bill_payment_amount();

create or replace function public.check_bill_total()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.total_amount < (select coalesce(sum(a.amount_applied), 0)
                           from public.bill_payment_applications a where a.bill_id = new.id) then
    raise exception 'Bill % total is below its paid amount', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger bills_total_check
  before update of total_amount on public.bills
  for each row execute function public.check_bill_total();

-- Purchases: direct expenses paid by cash, check or credit card (no bill).
create table public.purchases (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete cascade,
  qbo_id                 text,
  qbo_sync_token         text,
  doc_number             text,
  txn_date               date not null,
  payment_type           text not null check (payment_type in ('Cash','Check','CreditCard')),
  payment_account_id     uuid not null,          -- QB AccountRef: account paid from
  vendor_id              uuid,                   -- QB EntityRef type Vendor
  customer_id            uuid,                   -- QB EntityRef type Customer
  total_amount           numeric(14,2) not null,
  is_credit              boolean not null default false,  -- card refund / credit
  payment_method         text,
  print_status           text,
  private_note           text,
  qbo_recur_template_id  text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, qbo_id),
  check (vendor_id is null or customer_id is null),
  foreign key (company_id, payment_account_id) references public.accounts(company_id, id),
  foreign key (company_id, vendor_id)          references public.vendors(company_id, id),
  foreign key (company_id, customer_id)        references public.customers(company_id, id)
);
create index purchases_company_pay_acct_idx on public.purchases (company_id, payment_account_id);
create index purchases_company_vendor_idx   on public.purchases (company_id, vendor_id);
create index purchases_company_customer_idx on public.purchases (company_id, customer_id);
create index purchases_company_date_idx     on public.purchases (company_id, txn_date);

create table public.purchase_lines (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  purchase_id      uuid not null,
  qbo_line_id      text,
  line_num         integer,
  detail_type      text not null default 'account' check (detail_type in ('account','item')),
  account_id       uuid,
  item_id          uuid,
  description      text,
  qty              numeric(14,4),
  unit_price       numeric(14,4),
  amount           numeric(14,2) not null,
  customer_id      uuid,                          -- billable-to customer
  billable_status  text check (billable_status in ('Billable','NotBillable','HasBeenBilled')),
  tax_code         text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (purchase_id, qbo_line_id),
  check (account_id is not null or item_id is not null),
  foreign key (company_id, purchase_id) references public.purchases(company_id, id) on delete cascade,
  foreign key (company_id, account_id)  references public.accounts(company_id, id),
  foreign key (company_id, item_id)     references public.items(company_id, id),
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create index purchase_lines_company_purchase_idx on public.purchase_lines (company_id, purchase_id);
create index purchase_lines_company_account_idx  on public.purchase_lines (company_id, account_id);
create index purchase_lines_company_item_idx     on public.purchase_lines (company_id, item_id);
create index purchase_lines_company_customer_idx on public.purchase_lines (company_id, customer_id);

create view public.bill_balances
with (security_invoker = true) as
select b.id as bill_id,
       b.company_id,
       b.vendor_id,
       b.doc_number,
       b.txn_date,
       b.due_date,
       b.total_amount,
       coalesce(sum(a.amount_applied), 0)                  as amount_paid,
       b.total_amount - coalesce(sum(a.amount_applied), 0) as balance,
       case when b.voided_at is not null then 'void'
            when coalesce(sum(a.amount_applied), 0) = 0 and b.total_amount > 0 then 'unpaid'
            when coalesce(sum(a.amount_applied), 0) < b.total_amount then 'partial'
            else 'paid' end                                as status,
       min(a.applied_on)                                   as first_payment_date,
       max(a.applied_on)                                   as last_payment_date
from public.bills b
left join public.bill_payment_applications a on a.bill_id = b.id
group by b.id;

create view public.bill_payment_unapplied
with (security_invoker = true) as
select bp.id as bill_payment_id,
       bp.company_id,
       bp.vendor_id,
       bp.txn_date,
       bp.amount,
       coalesce(sum(a.amount_applied), 0)             as applied,
       bp.amount - coalesce(sum(a.amount_applied), 0) as unapplied
from public.bill_payments bp
left join public.bill_payment_applications a on a.bill_payment_id = bp.id
group by bp.id;

do $$
declare t text;
begin
  foreach t in array array['bills','bill_lines','bill_payments','bill_payment_applications','purchases','purchase_lines'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
