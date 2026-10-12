-- migration 20261013000121_stripe_checkout
-- Pay Now checkout sessions, Vault helpers, and test/live payment recording.
-- This is the final definition of record_stripe_checkout_payment and
-- delete_stripe_test_payments. Earlier revisions patched function source at
-- apply time; a fresh database gets these create-or-replace bodies directly.
--
-- companies.stripe_mode selects which Vault secrets the edge functions use:
--   test -> STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PAYMENT_METHOD_CONFIG
--   live -> the same names with a _LIVE suffix
-- Test payments are tagged txn_source 'Stripe TEST' and can be removed with
-- delete_stripe_test_payments(). Live payments are tagged 'Stripe' and are left alone.

alter table public.companies
  add column if not exists stripe_mode text not null default 'test'
  check (stripe_mode in ('test','live'));

-- App secrets in Supabase Vault (service_role only).
create or replace function public.app_secret_set(p_name text, p_value text) returns void
language plpgsql security definer set search_path=public, vault as $$
declare v_id uuid;
begin
  select id into v_id from vault.secrets where name=p_name;
  if v_id is null then perform vault.create_secret(p_value, p_name, 'GrokBooks edge function secret');
  else perform vault.update_secret(v_id, p_value); end if;
end $$;
create or replace function public.app_secret_get(p_name text) returns text
language sql stable security definer set search_path=public, vault as $$
  select decrypted_secret from vault.decrypted_secrets where name=p_name limit 1;
$$;
revoke all on function public.app_secret_set(text,text), public.app_secret_get(text) from public, anon, authenticated;
grant execute on function public.app_secret_set(text,text), public.app_secret_get(text) to service_role;

-- Checkout sessions (Pay Now). The payment intent and payment method are unknown
-- until the customer pays, so the session is tracked here and a charge_attempt
-- is written on completion.
create table public.stripe_checkout_sessions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  invoice_id uuid not null,
  invoice_link_id uuid references invoice_links(id) on delete set null,
  stripe_checkout_session_id text not null unique,
  url text,
  amount numeric(12,2) not null check (amount > 0),
  livemode boolean not null default false,
  status text not null default 'open' check (status in ('open','processing','paid','failed','expired')),
  stripe_payment_intent_id text,
  stripe_payment_method_id text,
  charge_attempt_id uuid,
  payment_id uuid,
  expires_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (company_id, invoice_id) references invoices(company_id, id)
);
create index on public.stripe_checkout_sessions (invoice_id);
alter table public.stripe_checkout_sessions enable row level security;

-- Atomically record a paid Stripe checkout: payment method, charge attempt, payment, application.
-- p_livemode must match the session. Test rows are labeled so they can be deleted later.
create or replace function public.record_stripe_checkout_payment(
  p_session_id text, p_payment_intent_id text, p_charge_id text, p_pm_id text, p_pm_type text,
  p_last4 text, p_brand text, p_bank text, p_amount numeric, p_fee numeric, p_paid_on date, p_livemode boolean)
returns uuid language plpgsql security definer set search_path=public as $$
declare s stripe_checkout_sessions; inv invoices; v_pm uuid; v_ca uuid; v_pay uuid; v_bal numeric; v_dep uuid; v_n int;
begin
  select * into s from stripe_checkout_sessions where stripe_checkout_session_id=p_session_id for update;
  if not found then raise exception 'unknown checkout session %', p_session_id; end if;
  if s.payment_id is not null then return s.payment_id; end if;
  if s.livemode <> p_livemode then raise exception 'livemode mismatch for session %', p_session_id; end if;
  select * into inv from invoices where id=s.invoice_id;

  insert into payment_methods(company_id, customer_id, stripe_payment_method_id, type, usage, bank_name, last4, card_brand)
  values (s.company_id, inv.customer_id, p_pm_id, p_pm_type, 'one_off', p_bank, p_last4, p_brand)
  on conflict (stripe_payment_method_id) do update set updated_at=now()
  returning id into v_pm;

  select coalesce(max(attempt_number),0)+1 into v_n from charge_attempts where invoice_id=s.invoice_id;
  insert into charge_attempts(company_id, invoice_id, payment_method_id, attempt_number, amount, stripe_payment_intent_id, idempotency_key, status, initiated_by, settled_at)
  values (s.company_id, s.invoice_id, v_pm, v_n, p_amount, p_payment_intent_id, p_session_id, 'succeeded', 'manual', now())
  on conflict (stripe_payment_intent_id) do update set status='succeeded', settled_at=now(), updated_at=now()
  returning id into v_ca;

  select id into v_dep from accounts where company_id=s.company_id and name='Undeposited Funds' limit 1;
  insert into payments(company_id, customer_id, payment_date, amount, method, reference, deposit_account_id, txn_source, memo, charge_attempt_id, stripe_charge_id, stripe_fee)
  values (s.company_id, inv.customer_id, p_paid_on, p_amount, case when p_pm_type='us_bank_account' then 'ach' else 'card' end,
          p_payment_intent_id, v_dep,
          case when p_livemode then 'Stripe' else 'Stripe TEST' end,
          case when p_livemode then 'Stripe checkout '||p_session_id else 'Stripe TEST checkout '||p_session_id||' (test mode - safe to delete)' end,
          v_ca, p_charge_id, p_fee)
  returning id into v_pay;

  select greatest(coalesce(b.balance, inv.total_amount),0) into v_bal from invoice_balances b where b.invoice_id=inv.id;
  v_bal := coalesce(v_bal, inv.total_amount);
  if least(p_amount, v_bal) > 0 then
    insert into payment_applications(company_id, payment_id, invoice_id, amount_applied, applied_on)
    values (s.company_id, v_pay, inv.id, least(p_amount, v_bal), p_paid_on);
  end if;

  update stripe_checkout_sessions
     set status='paid',
         stripe_payment_intent_id=p_payment_intent_id,
         stripe_payment_method_id=p_pm_id,
         charge_attempt_id=v_ca,
         payment_id=v_pay,
         completed_at=now(),
         updated_at=now()
   where id=s.id;
  return v_pay;
end $$;
revoke all on function public.record_stripe_checkout_payment(text,text,text,text,text,text,text,text,numeric,numeric,date,boolean) from public, anon, authenticated;
grant execute on function public.record_stripe_checkout_payment(text,text,text,text,text,text,text,text,numeric,numeric,date,boolean) to service_role;

-- Remove TEST checkout rows only. Never touches livemode sessions, livemode events,
-- or payments that are not tagged 'Stripe TEST'.
create or replace function public.delete_stripe_test_payments() returns int
language plpgsql security definer set search_path=public as $$
declare n int; v_pis text[]; v_pms text[]; v_sess text[];
begin
  select array_agg(stripe_checkout_session_id), array_agg(stripe_payment_intent_id), array_agg(stripe_payment_method_id)
    into v_sess, v_pis, v_pms from stripe_checkout_sessions where livemode=false;
  delete from payments p where p.txn_source='Stripe TEST'
    and not exists (select 1 from stripe_checkout_sessions s where s.payment_id=p.id and s.livemode);
  get diagnostics n = row_count;
  delete from charge_attempts where stripe_payment_intent_id = any(coalesce(v_pis,'{}')) and stripe_payment_intent_id like 'pi_%'
    and not exists (select 1 from stripe_checkout_sessions s where s.livemode and s.stripe_payment_intent_id=charge_attempts.stripe_payment_intent_id);
  delete from payment_methods pm where pm.stripe_payment_method_id = any(coalesce(v_pms,'{}'))
    and not exists (select 1 from charge_attempts ca where ca.payment_method_id=pm.id);
  delete from stripe_checkout_sessions where livemode=false;
  delete from stripe_events where livemode=false;
  return n;
end $$;
revoke all on function public.delete_stripe_test_payments() from public, anon, authenticated;
grant execute on function public.delete_stripe_test_payments() to service_role;
