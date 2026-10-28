# invoice-pdf (Supabase Edge Function)

Generates a one-page invoice PDF from GrokBooks data, or a stamped copy used as
the payment receipt, stores it in the private Storage bucket `invoices`, and
records it in `public.invoice_documents`.

* `verify_jwt = true`, and the handler also requires the JWT role `service_role`.
* Every stored render is a **new version**; older versions are kept with `is_current=false`.
* Plain invoice:   `invoices/invoices/<company_id>/<invoice_number>/v<N>.pdf` (bucket/path)
* Stamped receipt: `invoices/invoices/<company_id>/<invoice_number>/receipts/v<N>.pdf`
* Versioning is per `(invoice_id, document_type)`. SQL helpers (service_role only):
  `next_invoice_document_version()`, `record_invoice_document()` (advisory lock; demotes the
  old current row and inserts the new one in one transaction), `get_or_create_invoice_link()`,
  `consume_invoice_link()` (used by `invoice-view`).
  (`stamp=paid` → **PAID** stamp with paid date, amount and method/reference when
  fully paid; **PARTIAL PAYMENT** with amount paid and remaining balance otherwise;
  409 if nothing is applied or the invoice is void).

## Request

POST JSON (or GET query string):

| field | notes |
|---|---|
| `invoice_id` | invoice uuid, **or** |
| `company_id` + `qbo_id` / `doc_number` | QuickBooks Id or invoice number |
| `stamp` | optional, `paid` |
| `store` | default `true`; `false` = render only |
| `response` | `pdf` (default) or `json` (path, version, document id, link) |
| `link` | `true` = create/return an active `invoice_links` token; returned as `view_url` (json) / `X-View-Url` header |

Public customer link: `https://<project>.supabase.co/functions/v1/invoice-view?t=<token>`
(see `../invoice-view`).

```bash
curl -X POST "$SUPABASE_URL/functions/v1/invoice-pdf" \
  -H "Authorization: Bearer $SERVICE_ROLE_JWT" -H "Content-Type: application/json" \
  -d '{"company_id":"<uuid>","doc_number":"1001","stamp":"paid"}' -o receipt.pdf
```

## Branding / configuration (`public.companies`)

`legal_name` (falls back to `name`), `address` (QuickBooks-style jsonb), `phone`, `email`,
`website`, `logo_path` (PNG or JPEG object path inside the `invoices` bucket, for example
`<company_id>/branding/logo.png`). Upload the file to that private bucket and set
`companies.logo_path`. When the path is null, or the object is missing or not a PNG/JPEG,
the PDF draws a generic LOGO placeholder. No logo is bundled in this function.
`remit_to` and `payment_instructions` (multi-line text; a red **[PLACEHOLDER]**
is printed when null).

## Files

* `index.ts` – HTTP handler, data loading, versioned storage upload, `record_invoice_document` RPC, optional link
* `data.ts`  – maps database rows to render input (stamp logic lives here)
* `render.ts` – pure pdf-lib renderer (no I/O)
* `dev/preview.ts` – local render from a JSON bundle (placeholder logo unless the bundle supplies bytes):
  `deno run -A dev/preview.ts bundle.json out.pdf [paid]`
