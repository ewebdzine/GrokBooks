# invoice-view (public Edge Function, verify_jwt = false)

Customer-facing invoice link. Tokens live in `public.invoice_links` (create with
`invoice-pdf` `link: true`, or `select get_or_create_invoice_link(company_id, invoice_id)`).

* `GET /functions/v1/invoice-view?t=<token>` → 302 to a 10-minute signed URL of the current PDF
* `&dl=1` → forces download; `&page=1` → HTML summary page (only renders as HTML behind a
  custom domain; Supabase serves text/html as text/plain on *.supabase.co)
* Valid hit: `view_count += 1`, `last_viewed_at = now()` (via `consume_invoice_link`).
* Document choice: current stamped PAID receipt if the invoice is fully paid, else current plain
  `invoice_pdf`, else current receipt.
* Invalid / inactive / revoked / expired / no document → generic 404 text, nothing leaked.
* Disable a link: `update invoice_links set is_active=false, revoked_at=now() where token=...`.

## Pay Now
`?t=<token>&pay=1` -> 303 to Stripe Checkout for the current balance due (card and ACH via a
Payment Method Configuration; Stripe no longer accepts `payment_method_types` on Checkout).
Mode comes from `companies.stripe_mode` (`test` by default, or `live`):

* test uses Vault `STRIPE_SECRET_KEY` and `STRIPE_PAYMENT_METHOD_CONFIG`
* live uses Vault `STRIPE_SECRET_KEY_LIVE` and `STRIPE_PAYMENT_METHOD_CONFIG_LIVE`

The secret key's mode must match `stripe_mode`. An open session for the same amount
(expiring more than 5 minutes out) is reused and tracked in `stripe_checkout_sessions`.
Success returns to the view link with `&paid=1`, cancel returns to the view link.
Paid or void invoices redirect to the view without starting Checkout.
