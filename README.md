# GrokBooks

GrokBooks is a UI-less accounting backend on [Supabase](https://supabase.com). It stores a QuickBooks-style general ledger in Postgres and collects invoice payments with Stripe. There is no application UI in this repository: you talk to the database and three Edge Functions.

## What it does

* Companies, chart of accounts, customers, vendors, and items
* Invoices, payments, and payment applications, with balances computed in views
* Bills, purchases, deposits, journal entries, transfers, loans, and fixed assets
* General-ledger and cash-basis report views
* Common-area-maintenance (CAM) true-up reports, plus a local PDF renderer under `tools/cam-trueup-pdf`
* Versioned invoice PDFs with a Pay Online button
* Public invoice links and Stripe Checkout (card and ACH)
* Webhook recording of those payments, in test or live mode per company

Row level security is enabled on application tables with no policies, so the Data API roles cannot read or write them. Edge Functions use the service role, which bypasses RLS. Helper functions that read Vault or post payments are granted to `service_role` only.

## Architecture

```
companies, invoices, payments, ...     Postgres (migrations in supabase/migrations)
        |                                        |
        v                                        v
invoice-pdf  ---- stores PDF + link token --> Storage bucket "invoices"
        |                                        invoice_links
        v
invoice-view (public token) -- Pay Now --> Stripe Checkout
        ^                                        |
        |                                        v
        +-------- stripe-webhook <-------- checkout.session.* events
                     |
                     v
            record_stripe_checkout_payment()
```

`companies.stripe_mode` is `test` (the default) or `live`. That column chooses which Vault secrets the functions use. Test payments are stored with `txn_source` `Stripe TEST` and can be removed later. Live payments are stored as `Stripe` and are not removed by the test cleanup function.

Branding is per company and is never bundled in the functions:

| Column | Used for |
|---|---|
| `legal_name`, `name` | Name on the PDF |
| `address`, `phone`, `email`, `website` | Header and footer |
| `logo_path` | PNG or JPEG object inside the private `invoices` bucket |
| `remit_to`, `payment_instructions` | Footer blocks. A placeholder is printed when null |

If `logo_path` is null, or the object is missing, the PDF draws a generic LOGO box.

## Setup

1. Create a Supabase project and install the [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started).
2. From this directory, link it (use your own project ref; do not commit it):

   ```bash
   supabase login
   supabase link --project-ref <your-project-ref>
   ```

3. Apply the migrations. They rebuild the schema from scratch and contain no company data:

   ```bash
   supabase db push
   ```

   Locally, with Docker: `supabase start` then `supabase db reset`. Reset also loads `supabase/seed.sql`.

4. In the Dashboard, enable the Vault extension if it is not already on (Database -> Extensions -> vault). The checkout migration defines `app_secret_set` / `app_secret_get` on top of Vault.

5. Deploy the functions. JWT settings are in `supabase/config.toml` (`invoice-pdf` verifies a JWT and then requires `service_role`; `invoice-view` and `stripe-webhook` are public):

   ```bash
   supabase functions deploy invoice-pdf
   supabase functions deploy invoice-view
   supabase functions deploy stripe-webhook
   ```

6. Store secrets in Vault. Names are listed in `.env.example`. Set them with the service role, for example in the SQL editor:

   ```sql
   select public.app_secret_set('STRIPE_SECRET_KEY', '<test secret key>');
   select public.app_secret_set('STRIPE_WEBHOOK_SECRET', '<test webhook signing secret>');
   select public.app_secret_set('STRIPE_PAYMENT_METHOD_CONFIG', '<test payment method configuration id>');
   ```

   Repeat with the `_LIVE` names when you are ready to charge real cards. Do not put the values in git.

### Stripe webhook

In the Stripe Dashboard, add an endpoint for each mode:

`https://<project-ref>.supabase.co/functions/v1/stripe-webhook`

Subscribe to:

* `checkout.session.completed`
* `checkout.session.async_payment_succeeded`
* `checkout.session.async_payment_failed`
* `checkout.session.expired`

Put the test endpoint's signing secret in `STRIPE_WEBHOOK_SECRET` and the live endpoint's signing secret in `STRIPE_WEBHOOK_SECRET_LIVE`. The function checks the signature and requires it to match `event.livemode`.

Create a Payment Method Configuration in each Stripe mode that allows only card and US bank account (ACH). Stripe Checkout no longer accepts a payment-method type list on the session; the configuration id is what limits the methods. Store those ids in `STRIPE_PAYMENT_METHOD_CONFIG` and `STRIPE_PAYMENT_METHOD_CONFIG_LIVE`.

### Test mode and live mode

`companies.stripe_mode` defaults to `test`. While it is `test`, Pay Now uses the non-`_LIVE` Vault secrets and the webhook records `txn_source = 'Stripe TEST'`. Set the column to `live` only after the live secrets and live webhook endpoint exist. The function rejects a secret key whose mode does not match the company.

To delete test payments after a trial:

```sql
select public.delete_stripe_test_payments();
```

That deletes rows tagged `Stripe TEST`, test checkout sessions, and test webhook events. It does not delete live sessions or payments tagged `Stripe`.

### Invoice PDF and the public link

`invoice-pdf` is called with the service-role JWT:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/invoice-pdf" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"invoice_id":"<invoice uuid>","link":true}'
```

Each stored render is a new version under `invoices/<company_id>/<invoice_number>/v<N>.pdf`. A `stamp=paid` request writes a receipt under `.../receipts/v<N>.pdf` (PAID when the balance is zero, PARTIAL PAYMENT otherwise).

The Pay Online button is an `invoice-view` URL with `pay=1`. Customers open:

`https://<project-ref>.supabase.co/functions/v1/invoice-view?t=<token>`

See `supabase/functions/invoice-pdf/README.md`, `supabase/functions/invoice-view/README.md`, and `supabase/functions/stripe-webhook/README.md`.

### Logo

Upload a PNG or JPEG to the private `invoices` bucket and set `companies.logo_path` to that object path (for example `<company_id>/branding/logo.png`). The bucket allows PDF, PNG, and JPEG. Address, remit-to, and payment instructions are columns on `companies`.

### Sample data

`supabase/seed.sql` inserts one fictional company, **Acme Co**, a few accounts (including `Undeposited Funds`, which checkout payments deposit into), one customer, and invoice `1001`. It runs on local `supabase db reset`. Do not load it into production (`supabase db push` does not include seed data unless you pass `--include-seed`).

## Docs

* `docs/stripe_sync_design.md` — how Stripe ids hang off GrokBooks rows
* `docs/quickbooks_field_dictionary.md` — QuickBooks field names the schema follows
* `docs/quickbooks_schema_reference_repos.md` — public schema references

## Layout

```
supabase/migrations/     schema, in order
supabase/functions/      invoice-pdf, invoice-view, stripe-webhook
supabase/seed.sql        fictional Acme Co sample
supabase/config.toml     function JWT settings and seed path
tools/cam-trueup-pdf/    local CAM statement PDFs (logo from the caller, or a placeholder)
```

This repository does not include QuickBooks import scripts or one-off data fixes. Those are company-specific and stay out of the public tree.
