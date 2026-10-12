// GrokBooks Edge Function: invoice-view (PUBLIC, verify_jwt = false)
//
// GET /functions/v1/invoice-view?t=<token>            -> 302 to a 10-minute signed URL (PDF opens inline)
// GET /functions/v1/invoice-view?t=<token>&dl=1       -> same, but forces a download
// GET /functions/v1/invoice-view?t=<token>&page=1     -> HTML summary page (company, invoice #, status, embedded PDF).
//   NOTE: on the default *.supabase.co domain Supabase rewrites text/html to text/plain, so the
//   HTML page only renders properly behind a custom domain / proxy. Default is therefore the redirect.
// GET /functions/v1/invoice-view?t=<token>&pay=1      -> 303 to a Stripe Checkout Session (card + ACH via payment_method_configuration) for the
//   current balance due. Mode comes from companies.stripe_mode ('test' default | 'live'):
//   test -> Vault STRIPE_SECRET_KEY / STRIPE_PAYMENT_METHOD_CONFIG (key must be *_test_),
//   live -> Vault STRIPE_SECRET_KEY_LIVE / STRIPE_PAYMENT_METHOD_CONFIG_LIVE (key must be *_live_).
//   Reuses an open, unexpired session for the same amount; records it in stripe_checkout_sessions.
//
// The token must exist in public.invoice_links, be active, not revoked and not expired.
// Each valid hit increments view_count / last_viewed_at. Anything invalid returns the
// same generic 404 page (no data leaked). Uses the service role key from env.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SIGNED_TTL = 600;
const TOKEN_RE = /^[0-9a-f]{32,128}$/i;
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const money = (v: unknown) => Number(v ?? 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
const SEC = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store", "X-Robots-Tag": "noindex" };

const notFound = () => new Response("Link not found. This invoice link is invalid or has expired.\n",
  { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8", ...SEC } });

Deno.serve(async (req) => {
  try {
    if (req.method !== "GET" && req.method !== "HEAD") return notFound();
    const url = new URL(req.url);
    const token = url.searchParams.get("t") ?? "";
    if (!TOKEN_RE.test(token)) return notFound();
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

    const { data: hit, error } = await sb.rpc("consume_invoice_link", { p_token: token });
    if (error || !hit?.length) return notFound();
    const { company_id, invoice_id } = hit[0];

    const [inv, bal, co, docs] = await Promise.all([
      sb.from("invoices").select("doc_number, qbo_id, total_amount, due_date, voided_at").eq("company_id", company_id).eq("id", invoice_id).single(),
      sb.from("invoice_balances").select("amount_paid, balance").eq("invoice_id", invoice_id).maybeSingle(),
      sb.from("companies").select("name, stripe_mode").eq("id", company_id).single(),
      sb.from("invoice_documents").select("document_type, stamp, storage_bucket, storage_path").eq("company_id", company_id).eq("invoice_id", invoice_id).eq("is_current", true),
    ]);
    if (inv.error || co.error || docs.error || !inv.data) return notFound();
    const total = Number(inv.data.total_amount ?? 0);
    const balance = bal.data ? Number(bal.data.balance) : total;
    const paid = bal.data ? Number(bal.data.amount_paid) : 0;
    const fullyPaid = balance <= 0.004 && !inv.data.voided_at;
    const list = docs.data ?? [];
    const doc = (fullyPaid && list.find((d) => d.document_type === "invoice_receipt_pdf" && d.stamp === "paid"))
      || list.find((d) => d.document_type === "invoice_pdf")
      || list.find((d) => d.document_type === "invoice_receipt_pdf");
    if (!doc && url.searchParams.get("pay") !== "1") return notFound();

    const num0 = inv.data.doc_number || (inv.data.qbo_id ? `QB-${inv.data.qbo_id}` : "");
    if (url.searchParams.get("pay") === "1") {
      const viewUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-view?t=${token}`;
      if (inv.data.voided_at || balance <= 0.004) return new Response(null, { status: 303, headers: { Location: viewUrl, ...SEC } });
      const amount = Math.round(balance * 100) / 100;
      const live = co.data.stripe_mode === "live";
      const reuse = await sb.from("stripe_checkout_sessions").select("url").eq("invoice_id", invoice_id).eq("status", "open")
        .eq("amount", amount).eq("livemode", live).gt("expires_at", new Date(Date.now() + 5 * 60_000).toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (reuse.data?.url) return new Response(null, { status: 303, headers: { Location: reuse.data.url, ...SEC } });
      const { data: key } = await sb.rpc("app_secret_get", { p_name: live ? "STRIPE_SECRET_KEY_LIVE" : "STRIPE_SECRET_KEY" });
      if (typeof key !== "string" || !/^(sk|rk)_(test|live)_/.test(key) || key.includes("_live_") !== live) { console.error("invoice-view pay: Stripe key missing or wrong mode"); return notFound(); }
      const [cust, link] = await Promise.all([
        sb.from("invoices").select("bill_email, customers(email)").eq("id", invoice_id).single(),
        sb.from("invoice_links").select("id").eq("token", token).single(),
      ]);
      // deno-lint-ignore no-explicit-any
      const email = String(((cust.data as any)?.customers?.email || cust.data?.bill_email || "")).split(/[,;\s]+/)[0];
      const f = new URLSearchParams();
      f.set("mode", "payment");
      // Stripe no longer accepts payment_method_types on Checkout; a Payment Method Configuration
      // limited to card + us_bank_account (no wallets/Link) is used instead (Vault: STRIPE_PAYMENT_METHOD_CONFIG).
      const { data: pmc } = await sb.rpc("app_secret_get", { p_name: live ? "STRIPE_PAYMENT_METHOD_CONFIG_LIVE" : "STRIPE_PAYMENT_METHOD_CONFIG" });
      if (typeof pmc === "string" && pmc) f.set("payment_method_configuration", pmc);
      f.set("line_items[0][quantity]", "1");
      f.set("line_items[0][price_data][currency]", "usd");
      f.set("line_items[0][price_data][unit_amount]", String(Math.round(amount * 100)));
      f.set("line_items[0][price_data][product_data][name]", `Invoice ${num0} - ${co.data.name}`);
      f.set("success_url", `${viewUrl}&paid=1`);
      f.set("cancel_url", viewUrl);
      if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) f.set("customer_email", email);
      for (const [k, v] of Object.entries({ invoice_id, company_id, invoice_number: num0, source: "grokbooks-invoice-view" })) {
        f.set(`metadata[${k}]`, String(v)); f.set(`payment_intent_data[metadata][${k}]`, String(v));
      }
      f.set("payment_intent_data[description]", `Invoice ${num0} - ${co.data.name}`);
      const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded", "Idempotency-Key": `gb-${invoice_id}-${crypto.randomUUID()}` },
        body: f,
      });
      const cs = await r.json();
      if (!r.ok || !cs.url) { console.error("stripe checkout error", cs?.error?.message); return notFound(); }
      const ins = await sb.from("stripe_checkout_sessions").upsert({
        company_id, invoice_id, invoice_link_id: link.data?.id ?? null, stripe_checkout_session_id: cs.id, url: cs.url,
        amount, livemode: !!cs.livemode, status: "open", expires_at: new Date(cs.expires_at * 1000).toISOString(),
      }, { onConflict: "stripe_checkout_session_id" });
      if (ins.error) console.error("record checkout session", ins.error.message);
      return new Response(null, { status: 303, headers: { Location: cs.url, ...SEC } });
    }
    if (!doc) return notFound();
    const num = inv.data.doc_number || (inv.data.qbo_id ? `QB-${inv.data.qbo_id}` : "");
    const { data: signed, error: sErr } = await sb.storage.from(doc.storage_bucket).createSignedUrl(doc.storage_path, SIGNED_TTL, { download: url.searchParams.get("dl") === "1" ? `invoice-${num}.pdf` : undefined });
    if (sErr || !signed) return notFound();
    if (url.searchParams.get("page") !== "1") {
      return new Response(null, { status: 302, headers: { Location: signed.signedUrl, ...SEC } });
    }

    const status = inv.data.voided_at ? "VOID" : fullyPaid ? "PAID" : paid > 0 ? "PARTIALLY PAID" : "OPEN";
    const color = status === "PAID" ? "#1a7f37" : status === "VOID" ? "#888" : "#b35900";
    const pdfUrl = esc(signed.signedUrl);
    const html = `<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Invoice ${esc(num)} – ${esc(co.data.name)}</title></head>
<body style="font-family:system-ui,sans-serif;margin:0;background:#f5f5f5;color:#222">
<div style="max-width:900px;margin:0 auto;padding:24px">
<h1 style="margin:0 0 4px">${esc(co.data.name)}</h1>
<p style="margin:0 0 16px">Invoice <b>#${esc(num)}</b> &middot; Total ${money(total)} &middot; Balance due <b>${money(Math.max(balance, 0))}</b>
${inv.data.due_date && !fullyPaid ? ` &middot; Due ${esc(inv.data.due_date)}` : ""}
&middot; <span style="color:${color};font-weight:700">${status}</span></p>
<p><a href="${pdfUrl}" style="display:inline-block;padding:10px 16px;background:#222;color:#fff;border-radius:6px;text-decoration:none">Open / download PDF</a>
${!fullyPaid && !inv.data.voided_at ? `<a href="?t=${esc(token)}&pay=1" style="display:inline-block;padding:10px 16px;background:#1a7f37;color:#fff;border-radius:6px;text-decoration:none;margin-left:8px">Pay now</a>` : ""}
<span style="color:#777;font-size:13px;margin-left:8px">(link valid ${SIGNED_TTL / 60} minutes; reload this page for a fresh one)</span></p>
<iframe src="${pdfUrl}" style="width:100%;height:80vh;border:1px solid #ddd;background:#fff" title="Invoice PDF"></iframe>
</div></body></html>`;
    return new Response(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8", ...SEC } });
  } catch (e) {
    console.error("invoice-view error", e);
    return notFound();
  }
});
