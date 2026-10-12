// GrokBooks Edge Function: stripe-webhook (PUBLIC, verify_jwt = false) — test + live
// Signature is checked against STRIPE_WEBHOOK_SECRET (test) and STRIPE_WEBHOOK_SECRET_LIVE (live);
// the matching secret must agree with event.livemode. Test payments are tagged txn_source 'Stripe TEST';
// live payments are recorded as txn_source 'Stripe' (never touched by delete_stripe_test_payments()).
//
// Logs every event idempotently in public.stripe_events and records paid checkouts via
// record_stripe_checkout_payment(). Remove TEST rows only with: select public.delete_stripe_test_payments();
//
// Handled: checkout.session.completed (paid => record; unpaid ACH => processing),
//          checkout.session.async_payment_succeeded (record), checkout.session.async_payment_failed,
//          checkout.session.expired. Everything else is just logged.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const res = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function verify(payload: string, header: string, secret: string): Promise<boolean> {
  const parts = Object.fromEntries([]) as Record<string, string[]>;
  for (const kv of header.split(",")) { const [k, v] = kv.split("="); (parts[k] ??= []).push(v); }
  const t = parts.t?.[0]; const sigs = parts.v1 ?? [];
  if (!t || !sigs.length || Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`)));
  return sigs.some((s) => s.length === expected.length && [...s].reduce((a, c, i) => a | (c.charCodeAt(0) ^ expected.charCodeAt(i)), 0) === 0);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return res(405, { error: "method" });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const payload = await req.text();
  const sigHeader = req.headers.get("stripe-signature") ?? "";
  const [{ data: whTest }, { data: whLive }] = await Promise.all([
    sb.rpc("app_secret_get", { p_name: "STRIPE_WEBHOOK_SECRET" }),
    sb.rpc("app_secret_get", { p_name: "STRIPE_WEBHOOK_SECRET_LIVE" }),
  ]);
  let sigLive: boolean | null = null;
  if (typeof whTest === "string" && await verify(payload, sigHeader, whTest)) sigLive = false;
  else if (typeof whLive === "string" && await verify(payload, sigHeader, whLive)) sigLive = true;
  if (sigLive === null) return res(400, { error: "bad signature" });
  const evt = JSON.parse(payload);
  if (!!evt.livemode !== sigLive) return res(400, { error: "mode mismatch" });
  const { data: key } = await sb.rpc("app_secret_get", { p_name: sigLive ? "STRIPE_SECRET_KEY_LIVE" : "STRIPE_SECRET_KEY" });
  const obj = evt.data?.object ?? {};
  const companyId = obj.metadata?.company_id ?? null;

  const ins = await sb.from("stripe_events").insert({ stripe_event_id: evt.id, type: evt.type, livemode: !!evt.livemode, payload: evt, company_id: companyId });
  if (ins.error) {
    if (ins.error.code !== "23505") { console.error(ins.error); return res(500, { error: "log failed" }); }
    const prev = await sb.from("stripe_events").select("processed_at").eq("stripe_event_id", evt.id).single();
    if (prev.data?.processed_at) return res(200, { received: true, duplicate: true });
  }
  const done = (error: string | null = null) => sb.from("stripe_events").update({ processed_at: new Date().toISOString(), error }).eq("stripe_event_id", evt.id);

  try {
    if (typeof key !== "string" || key.includes("_live_") !== !!evt.livemode) throw new Error("Stripe key missing or wrong mode");
    const stripe = async (path: string) => {
      const r = await fetch(`https://api.stripe.com/v1/${path}`, { headers: { Authorization: `Bearer ${key}` } });
      const j = await r.json(); if (!r.ok) throw new Error(j?.error?.message ?? `stripe ${r.status}`); return j;
    };
    const setStatus = (status: string, pi: string | null = null) => sb.from("stripe_checkout_sessions")
      .update({ status, ...(pi ? { stripe_payment_intent_id: pi } : {}), updated_at: new Date().toISOString() })
      .eq("stripe_checkout_session_id", obj.id).neq("status", "paid");

    if (evt.type.startsWith("checkout.session.") && obj.metadata?.source === "grokbooks-invoice-view") {
      const paid = (evt.type === "checkout.session.completed" && obj.payment_status === "paid") || evt.type === "checkout.session.async_payment_succeeded";
      if (paid) {
        const pi = await stripe(`payment_intents/${obj.payment_intent}?expand[]=payment_method&expand[]=latest_charge.balance_transaction`);
        const pm = pi.payment_method ?? {};
        const ch = pi.latest_charge ?? {};
        const fee = ch.balance_transaction?.fee != null ? ch.balance_transaction.fee / 100 : null;
        const paidOn = new Date(((ch.created ?? evt.created) as number) * 1000).toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
        const { error } = await sb.rpc("record_stripe_checkout_payment", {
          p_session_id: obj.id, p_payment_intent_id: pi.id, p_charge_id: ch.id ?? null, p_pm_id: pm.id, p_pm_type: pm.type,
          p_last4: pm.card?.last4 ?? pm.us_bank_account?.last4 ?? null, p_brand: pm.card?.brand ?? null,
          p_bank: pm.us_bank_account?.bank_name ?? null, p_amount: pi.amount_received / 100, p_fee: fee, p_paid_on: paidOn, p_livemode: !!evt.livemode,
        });
        if (error) throw new Error(error.message);
      } else if (evt.type === "checkout.session.completed") await setStatus("processing", obj.payment_intent);
      else if (evt.type === "checkout.session.async_payment_failed") await setStatus("failed", obj.payment_intent);
      else if (evt.type === "checkout.session.expired") await setStatus("expired");
    }
    await done();
    return res(200, { received: true });
  } catch (e) {
    console.error("stripe-webhook", e);
    // leave processed_at null so Stripe's retry re-processes this event
    await sb.from("stripe_events").update({ error: String((e as Error).message ?? e) }).eq("stripe_event_id", evt.id);
    return res(500, { error: "processing failed" });
  }
});
