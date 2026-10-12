-- Fictional sample for local development. Acme Co is not a real company.
-- Loaded by `supabase db reset` / `supabase start`. Do not apply this file to a
-- production database (do not pass --include-seed to supabase db push).

insert into public.companies (
  name, legal_name, address, website, remit_to, payment_instructions, stripe_mode
) values (
  'Acme Co',
  'Acme Company',
  '{"Line1":"100 Example Ave","City":"Anytown","CountrySubDivisionCode":"CA","PostalCode":"00000","Country":"US"}'::jsonb,
  'https://example.com',
  E'Acme Company\n100 Example Ave\nAnytown, CA 00000',
  'Pay online from the invoice link, or mail a check payable to Acme Company.',
  'test'
);

insert into public.accounts (company_id, name, account_number, account_type, account_subtype, classification)
select id, 'Accounts Receivable', '1100', 'Accounts Receivable', 'AccountsReceivable', 'Asset'
from public.companies where name = 'Acme Co';

insert into public.accounts (company_id, name, account_number, account_type, account_subtype, classification)
select id, 'Undeposited Funds', '1200', 'Other Current Asset', 'UndepositedFunds', 'Asset'
from public.companies where name = 'Acme Co';

insert into public.accounts (company_id, name, account_number, account_type, account_subtype, classification)
select id, 'Checking', '1000', 'Bank', 'Checking', 'Asset'
from public.companies where name = 'Acme Co';

insert into public.accounts (company_id, name, account_number, account_type, account_subtype, classification)
select id, 'Services Income', '4000', 'Income', 'ServiceFeeIncome', 'Revenue'
from public.companies where name = 'Acme Co';

insert into public.customers (company_id, display_name, company_name, bill_address)
select c.id, 'Example Customer', 'Example Customer LLC',
       '{"Line1":"1 Sample St","City":"Anytown","CountrySubDivisionCode":"CA","PostalCode":"00000"}'::jsonb
from public.companies c where c.name = 'Acme Co';

insert into public.invoices (
  company_id, customer_id, doc_number, txn_date, due_date, ar_account_id,
  terms, total_amount, customer_memo, bill_address
)
select c.id, cu.id, '1001', date '2026-01-15', date '2026-02-14', ar.id,
       'Net 30', 100.00, 'Sample invoice for local development.',
       '{"Line1":"1 Sample St","City":"Anytown","CountrySubDivisionCode":"CA","PostalCode":"00000"}'::jsonb
from public.companies c
join public.customers cu on cu.company_id = c.id and cu.display_name = 'Example Customer'
join public.accounts ar on ar.company_id = c.id and ar.name = 'Accounts Receivable'
where c.name = 'Acme Co';

insert into public.invoice_lines (company_id, invoice_id, line_num, account_id, description, qty, unit_price, amount)
select i.company_id, i.id, 1, inc.id, 'Sample service', 1, 100.00, 100.00
from public.invoices i
join public.companies c on c.id = i.company_id and c.name = 'Acme Co'
join public.accounts inc on inc.company_id = c.id and inc.name = 'Services Income'
where i.doc_number = '1001';
