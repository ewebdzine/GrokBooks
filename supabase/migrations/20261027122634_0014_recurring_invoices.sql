-- GrokBooks 0014: recurring invoices (templates, template lines, run log, generator function).
-- Same conventions as 0001/0012: uuid PKs, company_id + composite FKs, created_at/updated_at +
-- set_updated_at trigger, RLS enabled with no policies (deny by default; service role / postgres bypass).
--
-- Model: one recurring_invoices row per customer/lease, N recurring_invoice_lines (Base Rent, CAM, ...).
-- next_run_date is the TXN DATE of the next invoice. The generator creates the invoice when
-- next_run_date - days_before <= today, but ONLY for templates with auto_generate = true.
-- Never emails anything (invoices are created with email_status 'NotSet').

create table public.recurring_invoices (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  customer_id           uuid not null,
  lease_id              uuid references public.leases(id),   -- optional link to the tenant lease
  name                  text not null,
  interval_months       smallint not null default 1 check (interval_months between 1 and 12),
  day_of_month          smallint not null default 1 check (day_of_month between 1 and 31), -- 31 = last day if shorter
  days_before           smallint not null default 0 check (days_before between 0 and 60),  -- create this many days ahead
  start_date            date not null,
  end_date              date,
  next_run_date         date not null,                      -- txn date of the next invoice to create
  last_run_date         date,
  terms                 text,                               -- e.g. 'Due on receipt', 'Net 30'
  terms_days            smallint not null default 0 check (terms_days >= 0),
  currency              char(3) not null default 'USD',
  bill_email            text,
  customer_memo         text,
  status                text not null default 'active' check (status in ('active','paused','ended')),
  auto_generate         boolean not null default false,     -- false = mirror mode: nothing is generated
  qbo_recur_template_id text,                               -- QuickBooks RecurringTransaction Id, if mirrored from QBO
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, id),
  check (end_date is null or end_date >= start_date),
  foreign key (company_id, customer_id) references public.customers(company_id, id)
);
create index recurring_invoices_company_customer_idx on public.recurring_invoices (company_id, customer_id);
create index recurring_invoices_company_due_idx on public.recurring_invoices (company_id, status, auto_generate, next_run_date);
create unique index recurring_invoices_company_qbo_tmpl_key on public.recurring_invoices (company_id, qbo_recur_template_id) where qbo_recur_template_id is not null;

create table public.recurring_invoice_lines (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  recurring_invoice_id  uuid not null,
  line_num              integer not null,
  item_id               uuid,
  account_id            uuid,
  description           text,
  qty                   numeric(14,4) not null default 1,
  unit_price            numeric(14,4) not null,
  amount                numeric(14,2) generated always as (round(qty * unit_price, 2)) stored,
  tax_code              text not null default 'NON',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (company_id, id),
  unique (recurring_invoice_id, line_num),
  foreign key (company_id, recurring_invoice_id) references public.recurring_invoices(company_id, id) on delete cascade,
  foreign key (company_id, item_id)    references public.items(company_id, id),
  foreign key (company_id, account_id) references public.accounts(company_id, id)
);
create index recurring_invoice_lines_company_ri_idx on public.recurring_invoice_lines (company_id, recurring_invoice_id);

-- Run log: one row per template + period. The unique key is what makes generation idempotent.
create table public.recurring_invoice_runs (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies(id) on delete cascade,
  recurring_invoice_id  uuid not null,
  period_start          date not null,                      -- first day of the month being billed
  txn_date              date not null,
  status                text not null check (status in ('created','skipped_existing_invoice')),
  invoice_id            uuid references public.invoices(id) on delete set null,  -- created, or the pre-existing invoice that caused the skip
  note                  text,
  created_at            timestamptz not null default now(),
  unique (recurring_invoice_id, period_start),
  foreign key (company_id, recurring_invoice_id) references public.recurring_invoices(company_id, id) on delete cascade
);
create index recurring_invoice_runs_company_idx on public.recurring_invoice_runs (company_id, period_start);

do $$
declare t text;
begin
  foreach t in array array['recurring_invoices','recurring_invoice_lines'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', t || '_set_updated_at', t);
  end loop;
  foreach t in array array['recurring_invoices','recurring_invoice_lines','recurring_invoice_runs'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Generator ---------------------------------------------------------------------------
-- generate_recurring_invoices(as_of, company, dry_run)
--   * considers only status='active' AND auto_generate=true templates whose
--     next_run_date - days_before <= as_of (one period per template per call)
--   * skips (and records) the period if a non-voided invoice already exists for that customer in
--     that month - including QuickBooks-imported ones
--   * idempotent per template + period (recurring_invoice_runs unique key)
--   * p_dry_run = true only reports what it WOULD do; nothing is written
--   * never emails; created invoices have email_status 'NotSet'
create or replace function public.generate_recurring_invoices(
  p_as_of      date    default current_date,
  p_company_id uuid    default null,
  p_dry_run    boolean default false)
returns table(out_template_id uuid, out_customer text, out_period_start date, out_txn_date date,
              out_action text, out_invoice_id uuid, out_doc_number text, out_total numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  t            record;
  c            record;
  v_period     date;
  v_base       date;
  v_next       date;
  v_total      numeric(14,2);
  v_doc        text;
  v_inv        uuid;
  v_existing   uuid;
  v_action     text;
begin
  for t in
    select ri.*
      from public.recurring_invoices ri
     where ri.auto_generate
       and ri.status = 'active'
       and (p_company_id is null or ri.company_id = p_company_id)
       and ri.next_run_date >= ri.start_date
       and (ri.end_date is null or ri.next_run_date <= ri.end_date)
       and ri.next_run_date - ri.days_before::int <= p_as_of
     order by ri.company_id, ri.next_run_date, ri.id
       for update of ri skip locked
  loop
    v_period := date_trunc('month', t.next_run_date)::date;
    v_base   := (v_period + make_interval(months => t.interval_months))::date;
    v_next   := v_base + (least(t.day_of_month::int,
                  extract(day from (v_base + interval '1 month' - interval '1 day'))::int) - 1);
    select cu.display_name, cu.bill_address, cu.ship_address into c
      from public.customers cu where cu.company_id = t.company_id and cu.id = t.customer_id;
    select sum(l.amount) into v_total
      from public.recurring_invoice_lines l where l.recurring_invoice_id = t.id;
    v_inv := null; v_doc := null; v_existing := null;

    if exists (select 1 from public.recurring_invoice_runs r
                where r.recurring_invoice_id = t.id and r.period_start = v_period) then
      v_action := 'skipped_already_run';
    else
      select i.id into v_existing
        from public.invoices i
       where i.company_id = t.company_id and i.customer_id = t.customer_id
         and i.voided_at is null
         and i.txn_date >= v_period
         and i.txn_date <  (v_period + make_interval(months => t.interval_months))::date
       order by i.txn_date limit 1;
      if v_existing is not null then
        v_action := 'skipped_existing_invoice';
        v_inv := v_existing;
      elsif v_total is null or v_total <= 0 then
        v_action := 'skipped_no_lines';
      else
        v_action := case when p_dry_run then 'would_create' else 'created' end;
      end if;
    end if;

    if not p_dry_run then
      if v_action = 'created' then
        perform pg_advisory_xact_lock(hashtextextended(t.company_id::text, 0));
        select (coalesce(max(i.doc_number::bigint), 0) + 1)::text into v_doc
          from public.invoices i where i.company_id = t.company_id and i.doc_number ~ '^[0-9]{1,15}$';
        insert into public.invoices (company_id, doc_number, customer_id, txn_date, due_date, terms,
                                     total_amount, currency, customer_memo, bill_email,
                                     bill_address, ship_address, email_status)
        values (t.company_id, v_doc, t.customer_id, t.next_run_date,
                t.next_run_date + t.terms_days::int, t.terms, v_total, t.currency, t.customer_memo,
                t.bill_email, c.bill_address, c.ship_address, 'NotSet')
        returning id into v_inv;
        insert into public.invoice_lines (company_id, invoice_id, line_num, item_id, account_id,
                                          description, qty, unit_price, amount, tax_code)
        select l.company_id, v_inv, l.line_num, l.item_id, l.account_id,
               l.description, l.qty, l.unit_price, l.amount, l.tax_code
          from public.recurring_invoice_lines l
         where l.recurring_invoice_id = t.id
         order by l.line_num;
      end if;
      if v_action in ('created','skipped_existing_invoice') then
        insert into public.recurring_invoice_runs (company_id, recurring_invoice_id, period_start,
                                                   txn_date, status, invoice_id, note)
        values (t.company_id, t.id, v_period, t.next_run_date,
                case when v_action = 'created' then 'created' else 'skipped_existing_invoice' end,
                v_inv, null);
      end if;
      -- advance the schedule once the period is handled (created, skipped, or already run)
      if v_action in ('created','skipped_existing_invoice','skipped_already_run') then
        update public.recurring_invoices ri
           set last_run_date = t.next_run_date, next_run_date = v_next
         where ri.id = t.id;
      end if;
    end if;

    out_template_id := t.id; out_customer := c.display_name; out_period_start := v_period;
    out_txn_date := t.next_run_date; out_action := v_action; out_invoice_id := v_inv;
    out_doc_number := v_doc; out_total := v_total;
    return next;
  end loop;
end $$;

revoke all on function public.generate_recurring_invoices(date, uuid, boolean) from public, anon, authenticated;
grant execute on function public.generate_recurring_invoices(date, uuid, boolean) to service_role;
