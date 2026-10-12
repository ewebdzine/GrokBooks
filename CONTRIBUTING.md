# Contributing

GrokBooks is a UI-less accounting backend. Changes should stay generic: the
schema, functions, and docs must work for any company. Do not add data, logos,
ids, or copy that belong to one business.

## Setup

Follow the README. Use a Supabase project you control. Keep secrets in Vault or
in an untracked `.env`. `.env.example` lists names only.

## Schema changes

Add a new file under `supabase/migrations/` with the Supabase CLI so the
timestamp sorts after the existing files:

```bash
supabase migration new describe_the_change
```

Write the final SQL in that file (`create table`, `alter table`, `create or replace function`).
Do not rewrite an existing function by selecting its source and running a text
replace on it. A fresh database should be able to apply every migration in
order with `supabase db reset`.

Enable row level security on new tables in exposed schemas. Leave policies off
unless you have an access model that is not "service role only". Views over
those tables should use `security_invoker = true`.

`security definer` helpers that read Vault or record payments stay executable
by `service_role` only. Revoke `public`, `anon`, and `authenticated`.

## Edge functions

`invoice-pdf`, `invoice-view`, and `stripe-webhook` must not branch on a
company id, name, or bundled asset. Branding is `companies.logo_path`,
`address`, `remit_to`, and `payment_instructions`. If those are missing, show
the generic placeholder.

`invoice-view` and `stripe-webhook` are public (`verify_jwt = false` in
`supabase/config.toml`). Keep the token check and the Stripe signature check.

## What not to commit

* Secrets, webhook signing values, or API keys
* Database dumps, QuickBooks exports, or one-off data-fix scripts
* Logos or other binary brand assets
* Sample rows that name a real customer, vendor, or company

`supabase/seed.sql` may contain the fictional Acme Co sample only.

## Pull requests

Describe the behavior change and how you checked it (migration apply, function
request, or both). Do not include production data in the description.
