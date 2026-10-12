// GrokBooks Edge Function: invoice-pdf
//
// Generates a one-page invoice PDF (or a PAID / PARTIAL PAYMENT stamped copy
// used as the payment receipt), stores it in the private "invoices" bucket and
// records it in public.invoice_documents. Returns the PDF bytes.
//
// Auth: deployed with verify_jwt = true, and additionally requires the caller's
// JWT role to be service_role (no end-user access until RLS policies exist).
//
// Request (POST JSON or GET query string):
//   invoice_id   uuid                      -- or --
//   company_id + qbo_id | doc_number       (QuickBooks Id or invoice number)
//   stamp        "paid"  (optional)        -> stamped receipt copy; PAID when
//                                            fully paid, PARTIAL PAYMENT otherwise
//   store        true|false (default true) -> upload + record in invoice_documents
//   response     "pdf" (default) | "json"  -> json returns path/metadata only
//   link         true|false (default false)-> create/return an active invoice_links
//                                            token + public invoice-view URL
//
// Every stored render is a NEW version (old versions are kept, is_current=false):
//   invoices/<company_id>/<invoice_number>/v<N>.pdf
//   invoices/<company_id>/<invoice_number>/receipts/v<N>.pdf   (stamped)
// Versioning is per (invoice_id, document_type); see record_invoice_document().
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { renderInvoicePdf } from "./render.ts";
import { assemble, HttpError, RawInvoiceBundle, storageFileName } from "./data.ts";

const BUCKET = "invoices";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function jwtRole(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parts[1].length / 4) * 4, "=")));
    return payload.role ?? null;
  } catch { return null; }
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function sha256Hex(bytes: Uint8Array) {
  const h = await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "GET" && req.method !== "POST") return json(405, { error: "Method not allowed" });
    // Gateway already verified the JWT signature (verify_jwt = true).
    if (jwtRole(req) !== "service_role") return json(403, { error: "service_role required" });

    const url = new URL(req.url);
    const body: Record<string, unknown> = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const p = (k: string) => (body[k] ?? url.searchParams.get(k) ?? undefined) as string | boolean | undefined;
    const invoiceId = p("invoice_id") as string | undefined;
    const companyId = p("company_id") as string | undefined;
    const qboId = p("qbo_id") as string | undefined;
    const docNumber = p("doc_number") as string | undefined;
    const stampParam = String(p("stamp") ?? "").toLowerCase();
    if (stampParam && stampParam !== "paid") return json(400, { error: "stamp must be 'paid' (PARTIAL PAYMENT is chosen automatically)" });
    const stamp = stampParam === "paid" ? "paid" as const : null;
    const store = String(p("store") ?? "true").toLowerCase() !== "false";
    const responseMode = String(p("response") ?? "pdf").toLowerCase();
    const wantLink = String(p("link") ?? "false").toLowerCase() === "true";

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });

    // ---- Locate the invoice
    let q = sb.from("invoices").select("id, company_id, qbo_id, doc_number, customer_id, txn_date, due_date, terms, total_amount, customer_memo, bill_address, bill_email, voided_at");
    if (invoiceId) {
      if (!UUID_RE.test(invoiceId)) return json(400, { error: "invoice_id must be a uuid" });
      q = q.eq("id", invoiceId);
      if (companyId) q = q.eq("company_id", companyId);
    } else if (companyId && (qboId || docNumber)) {
      if (!UUID_RE.test(companyId)) return json(400, { error: "company_id must be a uuid" });
      q = q.eq("company_id", companyId);
      q = qboId ? q.eq("qbo_id", String(qboId)) : q.eq("doc_number", String(docNumber));
    } else {
      return json(400, { error: "Provide invoice_id, or company_id with qbo_id or doc_number" });
    }
    const { data: invRows, error: invErr } = await q.limit(2);
    if (invErr) throw invErr;
    if (!invRows?.length) return json(404, { error: "Invoice not found" });
    if (invRows.length > 1) return json(409, { error: "More than one invoice matched; use invoice_id or qbo_id" });
    const inv = invRows[0];

    const [company, customer, lines, balance, apps] = await Promise.all([
      sb.from("companies").select("name, legal_name, address, phone, email, website, logo_path, remit_to, payment_instructions").eq("id", inv.company_id).single(),
      sb.from("customers").select("display_name, company_name, bill_address, email").eq("company_id", inv.company_id).eq("id", inv.customer_id).single(),
      sb.from("invoice_lines").select("line_num, description, qty, unit_price, amount, items(name)").eq("company_id", inv.company_id).eq("invoice_id", inv.id).order("line_num"),
      sb.from("invoice_balances").select("amount_paid, balance").eq("invoice_id", inv.id).maybeSingle(),
      sb.from("payment_applications").select("amount_applied, applied_on, payments(id, qbo_id, payment_date, method, reference)").eq("invoice_id", inv.id),
    ]);
    for (const r of [company, customer, lines, balance, apps]) if (r.error) throw r.error;

    const raw = {
      invoice: inv, company: company.data, customer: customer.data,
      lines: lines.data, balance: balance.data, applications: apps.data,
    } as unknown as RawInvoiceBundle;
    const { data, stampKind, latestPaymentId } = assemble(raw, stamp);

    // Logo comes only from this company's object in the private invoices bucket
    // (companies.logo_path, PNG or JPEG). A missing or unreadable logo renders
    // as a generic placeholder. Nothing is bundled in the function.
    if (raw.company.logo_path) {
      const { data: blob } = await sb.storage.from(BUCKET).download(raw.company.logo_path);
      if (blob) {
        const bytes = new Uint8Array(await blob.arrayBuffer());
        const isPng = bytes[0] === 0x89 && bytes[1] === 0x50;
        const isJpg = bytes[0] === 0xff && bytes[1] === 0xd8;
        if (isPng || isJpg) data.logo = { bytes, type: isPng ? "png" : "jpg" };
      }
    }

    // Pay Online button: invoice-view link with &pay=1 (not for receipts, void or paid invoices).
    let payToken: string | null = null;
    if (!stamp && !inv.voided_at && data.balance_due > 0.004) {
      const { data: tok, error: lErr } = await sb.rpc("get_or_create_invoice_link", { p_company_id: inv.company_id, p_invoice_id: inv.id });
      if (!lErr && typeof tok === "string") { payToken = tok; data.pay_url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-view?t=${tok}&pay=1`; }
    }
    const pdf = await renderInvoicePdf(data);
    const docType = stamp ? "invoice_receipt_pdf" : "invoice_pdf";
    const folder = `invoices/${inv.company_id}/${storageFileName(inv).replace(/\.pdf$/, "")}${stamp ? "/receipts" : ""}`;
    let path: string | null = null;
    let version: number | null = null;
    let documentId: string | null = null;

    if (store) {
      const sha = await sha256Hex(pdf);
      // Reserve the next version number; retry if a concurrent render took the path.
      for (let attempt = 0; attempt < 3 && !path; attempt++) {
        const { data: nv, error: nvErr } = await sb.rpc("next_invoice_document_version", { p_invoice_id: inv.id, p_document_type: docType });
        if (nvErr) throw nvErr;
        const candidate = `${folder}/v${nv}.pdf`;
        const up = await sb.storage.from(BUCKET).upload(candidate, pdf, { contentType: "application/pdf", upsert: false });
        if (up.error) {
          if (/exist|duplicate/i.test(up.error.message)) continue;
          throw up.error;
        }
        path = candidate; version = nv as number;
      }
      if (!path) throw new Error("Could not reserve a new document version");
      // Atomically demote the previous current row and insert the new version.
      const { data: docId, error: docErr } = await sb.rpc("record_invoice_document", {
        p_company_id: inv.company_id, p_invoice_id: inv.id, p_payment_id: stamp ? latestPaymentId : null,
        p_document_type: docType, p_stamp: stampKind, p_storage_bucket: BUCKET, p_storage_path: path,
        p_version: version, p_file_size_bytes: pdf.byteLength, p_sha256: sha,
        p_invoice_total: data.invoice.total_amount, p_amount_paid: data.amount_paid, p_balance_due: data.balance_due,
      });
      if (docErr) {
        await sb.storage.from(BUCKET).remove([path]);
        throw docErr;
      }
      documentId = docId as string;
    }

    let linkToken: string | null = null;
    if (wantLink) {
      const { data: tok, error: lErr } = await sb.rpc("get_or_create_invoice_link", { p_company_id: inv.company_id, p_invoice_id: inv.id });
      if (lErr) throw lErr;
      linkToken = tok as string;
    }
    const viewUrl = linkToken ? `${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-view?t=${linkToken}` : null;

    if (responseMode === "json") {
      return json(200, { invoice_id: inv.id, invoice_number: data.invoice.number, stamp: stampKind, stored: store, storage_bucket: BUCKET, storage_path: path, version, document_id: documentId, link_token: linkToken, view_url: viewUrl, bytes: pdf.byteLength });
    }
    return new Response(pdf as Uint8Array<ArrayBuffer>, {
      status: 200,
      headers: {
        "Content-Type": "application/pdf",
        "Content-Disposition": `inline; filename="${stamp ? "receipt" : "invoice"}-${storageFileName(inv)}"`,
        ...(store ? { "X-Storage-Path": `${BUCKET}/${path}` } : {}),
        ...(documentId ? { "X-Document-Id": documentId, "X-Document-Version": String(version) } : {}),
        ...(viewUrl ? { "X-View-Url": viewUrl } : {}),
      },
    });
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.message });
    console.error("invoice-pdf error", e);
    return json(500, { error: "Internal error generating invoice PDF" });
  }
});
