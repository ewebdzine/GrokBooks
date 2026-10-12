# stripe-webhook (public, verify_jwt = false)

Receives Stripe Checkout events for test and live mode. Point a Stripe webhook
endpoint at `/functions/v1/stripe-webhook` and subscribe to:

* `checkout.session.completed`
* `checkout.session.async_payment_succeeded`
* `checkout.session.async_payment_failed`
* `checkout.session.expired`

Create one endpoint in test mode and one in live mode. Store each endpoint's
signing secret in Vault under the name below. Do not put the secret in the repo.

* Signature is checked against Vault `STRIPE_WEBHOOK_SECRET` (test) and
  `STRIPE_WEBHOOK_SECRET_LIVE` (live). The matching secret must agree with
  `event.livemode` (5-minute tolerance).
* Every event is logged once in `stripe_events` (unique Stripe event id). A failed
  event keeps `processed_at` null and stores `error`, so a Stripe retry reprocesses it.
* Paid checkouts whose metadata `source` is `grokbooks-invoice-view` call
  `record_stripe_checkout_payment()`: payment method (one-off) + charge attempt
  (succeeded) + payment + application capped at the balance due.
  Test payments use `txn_source` `Stripe TEST`. Live payments use `Stripe`.
  The deposit account is the company's `Undeposited Funds` account when that name exists.
* Remove test payment rows only: `select public.delete_stripe_test_payments();`
  That function never deletes live sessions, live events, or payments tagged `Stripe`.

Which secret key is used follows the event's livemode, and must be the matching
Vault secret (`STRIPE_SECRET_KEY` or `STRIPE_SECRET_KEY_LIVE`). Checkout itself
is started by `invoice-view`, which reads `companies.stripe_mode`.

Secrets live in Supabase Vault (read via `app_secret_get`, service_role only):

| Vault name | Used when |
|---|---|
| `STRIPE_SECRET_KEY` | test mode API calls |
| `STRIPE_WEBHOOK_SECRET` | test mode webhook signatures |
| `STRIPE_PAYMENT_METHOD_CONFIG` | test mode Checkout (card and ACH only) |
| `STRIPE_SECRET_KEY_LIVE` | live mode API calls |
| `STRIPE_WEBHOOK_SECRET_LIVE` | live mode webhook signatures |
| `STRIPE_PAYMENT_METHOD_CONFIG_LIVE` | live mode Checkout |
