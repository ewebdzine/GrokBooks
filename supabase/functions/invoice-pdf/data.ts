// Maps raw GrokBooks rows to the renderer's InvoicePdfData. Shared by index.ts
// and local preview scripts so both produce identical output.
import type { Address, InvoicePdfData } from "./render.ts";

export interface RawInvoiceBundle {
  invoice: {
    id: string; company_id: string; qbo_id: string | null; doc_number: string | null;
    txn_date: string; due_date: string | null; terms: string | null; total_amount: number | string;
    customer_memo: string | null; bill_address: Address; bill_email?: string | null; voided_at: string | null;
  };
  company: {
    name: string; legal_name: string | null; address: Address; phone: string | null; email: string | null;
    website: string | null; logo_path: string | null; remit_to: string | null; payment_instructions: string | null;
  };
  customer: { display_name: string; company_name: string | null; bill_address: Address; email: string | null };
  lines: { line_num: number | null; description: string | null; qty: number | string | null; unit_price: number | string | null; amount: number | string; items: { name: string } | null }[];
  balance: { amount_paid: number | string; balance: number | string } | null;
  applications: { amount_applied: number | string; applied_on: string | null; payments: { id: string; qbo_id: string | null; payment_date: string; method: string | null; reference: string | null } | null }[];
}

export class HttpError extends Error { constructor(public status: number, msg: string) { super(msg); } }

const n = (v: unknown) => (v == null ? 0 : Number(v));
const hasAddr = (a: Address) => !!a && Object.values(a).some((v) => v && String(v).trim());

export function invoiceNumber(inv: RawInvoiceBundle["invoice"]): string {
  return inv.doc_number?.trim() || (inv.qbo_id ? `QB-${inv.qbo_id}` : inv.id.slice(0, 8));
}

export function storageFileName(inv: RawInvoiceBundle["invoice"]): string {
  const base = (inv.doc_number?.trim() || (inv.qbo_id ? `qbo-${inv.qbo_id}` : inv.id)).replace(/[^A-Za-z0-9._-]+/g, "_");
  return `${base}.pdf`;
}

export function assemble(raw: RawInvoiceBundle, stamp: "paid" | null): { data: InvoicePdfData; stampKind: "paid" | "partial" | null; latestPaymentId: string | null } {
  const total = n(raw.invoice.total_amount);
  const paid = raw.balance ? n(raw.balance.amount_paid) : raw.applications.reduce((s, a) => s + n(a.amount_applied), 0);
  const balance = raw.balance ? n(raw.balance.balance) : total - paid;

  let stampKind: "paid" | "partial" | null = null;
  let latestPaymentId: string | null = null;
  let stampData: InvoicePdfData["stamp"] = null;
  if (stamp) {
    if (raw.invoice.voided_at) throw new HttpError(409, "Invoice is voided; no receipt can be stamped.");
    if (paid <= 0) throw new HttpError(409, "No payments are applied to this invoice; nothing to stamp.");
    stampKind = balance <= 0.004 ? "paid" : "partial";
    const pays = raw.applications.filter((a) => a.payments).map((a) => ({ ...a.payments!, applied: n(a.amount_applied), applied_on: a.applied_on }));
    pays.sort((a, b) => (a.payment_date < b.payment_date ? -1 : 1));
    const latest = pays[pays.length - 1];
    latestPaymentId = latest?.id ?? null;
    const distinct = new Set(pays.map((p) => p.id));
    const refs = [...new Set(pays.map((p) => p.reference).filter(Boolean))] as string[];
    const methods = [...new Set(pays.map((p) => p.method).filter(Boolean))] as string[];
    stampData = {
      kind: stampKind,
      paid_date: latest?.payment_date ?? null,
      amount_paid: paid,
      balance_due: Math.max(balance, 0),
      reference: refs.length === 1 ? refs[0] : refs.length > 1 ? refs.join(", ") : null,
      method: methods.length === 1 && methods[0] !== "other" ? methods[0] : null,
      payment_count: distinct.size,
    };
  }

  const custName = raw.customer.company_name || raw.customer.display_name;
  const data: InvoicePdfData = {
    company: {
      name: raw.company.name, legal_name: raw.company.legal_name, address: raw.company.address,
      phone: raw.company.phone, email: raw.company.email, website: raw.company.website,
      remit_to: raw.company.remit_to, payment_instructions: raw.company.payment_instructions,
    },
    customer: {
      display_name: raw.customer.display_name,
      company_name: custName,
      address: hasAddr(raw.invoice.bill_address) ? raw.invoice.bill_address : raw.customer.bill_address,
      email: raw.customer.email || raw.invoice.bill_email || null,
    },
    invoice: {
      number: invoiceNumber(raw.invoice), txn_date: raw.invoice.txn_date, due_date: raw.invoice.due_date,
      terms: raw.invoice.terms, customer_memo: raw.invoice.customer_memo, total_amount: total, voided: !!raw.invoice.voided_at,
    },
    lines: [...raw.lines].sort((a, b) => (a.line_num ?? 0) - (b.line_num ?? 0)).map((l) => ({
      item_name: l.items?.name ?? null, description: l.description,
      qty: l.qty == null ? null : n(l.qty), unit_price: l.unit_price == null ? null : n(l.unit_price), amount: n(l.amount),
    })),
    amount_paid: paid,
    balance_due: balance,
    stamp: stampData,
  };
  return { data, stampKind, latestPaymentId };
}
