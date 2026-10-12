// Pure PDF renderer for GrokBooks invoices (no I/O). Used by index.ts and by
// local preview scripts. Letter size, Helvetica (WinAnsi) fonts via pdf-lib.
import {
  PDFDocument, PDFFont, PDFPage, PDFName, PDFString, StandardFonts, rgb, degrees, RGB,
} from "npm:pdf-lib@1.17.1";

export type Address = {
  Line1?: string | null; Line2?: string | null; Line3?: string | null;
  Line4?: string | null; Line5?: string | null; City?: string | null;
  CountrySubDivisionCode?: string | null; PostalCode?: string | null;
  Country?: string | null;
} | null;

export interface InvoicePdfData {
  company: {
    name: string; legal_name?: string | null; address?: Address;
    phone?: string | null; email?: string | null; website?: string | null;
    remit_to?: string | null; payment_instructions?: string | null;
  };
  customer: { display_name: string; company_name?: string | null; address?: Address; email?: string | null };
  invoice: {
    number: string; txn_date: string; due_date?: string | null; terms?: string | null;
    customer_memo?: string | null; total_amount: number; voided?: boolean;
  };
  lines: { item_name?: string | null; description?: string | null; qty?: number | null; unit_price?: number | null; amount: number }[];
  amount_paid: number;
  balance_due: number;
  pay_url?: string | null;          // invoice-view link with &pay=1 (Pay Online button)
  stamp?: null | {
    kind: "paid" | "partial";
    paid_date?: string | null;      // latest payment date (YYYY-MM-DD)
    amount_paid: number;
    balance_due: number;
    reference?: string | null;      // payment reference / check number
    method?: string | null;         // ach, check, card, ...
    payment_count?: number;
  };
  logo?: { bytes: Uint8Array; type: "png" | "jpg" } | null;
}

const PAGE_W = 612, PAGE_H = 792, M = 50;
const INK = rgb(0.13, 0.15, 0.18), MUTED = rgb(0.42, 0.45, 0.5);
const RULE = rgb(0.82, 0.84, 0.87), SHADE = rgb(0.94, 0.95, 0.97);
const ACCENT = rgb(0.12, 0.29, 0.49), PLACEHOLDER = rgb(0.75, 0.1, 0.1);

export const money = (n: number) =>
  (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const usDate = (d?: string | null) => {
  if (!d) return "";
  const [y, m, day] = d.slice(0, 10).split("-");
  return `${m}/${day}/${y}`;
};
const qtyFmt = (q?: number | null) =>
  q == null ? "" : Number(q).toLocaleString("en-US", { maximumFractionDigits: 4 });

export function addressLines(a: Address, skip: string[] = []): string[] {
  if (!a) return [];
  const out: string[] = [];
  for (const k of ["Line1", "Line2", "Line3", "Line4", "Line5"] as const) {
    const v = (a[k] ?? "").trim();
    if (v && !skip.some((s) => s.trim().toLowerCase() === v.toLowerCase())) out.push(v);
  }
  const cityLine = [a.City, [a.CountrySubDivisionCode, a.PostalCode].filter(Boolean).join(" ")]
    .filter((s) => s && String(s).trim()).join(", ");
  if (cityLine) out.push(cityLine);
  return out;
}

export class Writer {
  cache = new Map<string, boolean>();
  constructor(public regular: PDFFont, public bold: PDFFont) {}
  // Replace characters Helvetica/WinAnsi cannot encode.
  safe(text: string): string {
    const map: Record<string, string> = { "\u2018": "'", "\u2019": "'", "\u201C": '"', "\u201D": '"', "\u2013": "-", "\u2014": "-", "\u00A0": " " };
    let out = "";
    for (const ch of String(text ?? "")) {
      const c = map[ch] ?? ch;
      let ok = this.cache.get(c);
      if (ok === undefined) {
        try { this.regular.encodeText(c); ok = true; } catch { ok = false; }
        this.cache.set(c, ok);
      }
      out += ok ? c : (c === "\n" || c === "\t" ? " " : "?");
    }
    return out;
  }
  width(t: string, size: number, b = false) { return (b ? this.bold : this.regular).widthOfTextAtSize(this.safe(t), size); }
  text(p: PDFPage, t: string, x: number, y: number, size: number, opts: { bold?: boolean; color?: RGB; align?: "left" | "right" | "center" } = {}) {
    const s = this.safe(t);
    const font = opts.bold ? this.bold : this.regular;
    const w = font.widthOfTextAtSize(s, size);
    const dx = opts.align === "right" ? -w : opts.align === "center" ? -w / 2 : 0;
    p.drawText(s, { x: x + dx, y, size, font, color: opts.color ?? INK });
  }
  wrap(t: string, size: number, maxW: number, b = false): string[] {
    const lines: string[] = [];
    for (const para of String(t ?? "").split(/\r?\n/)) {
      let cur = "";
      for (const word of para.split(/\s+/).filter(Boolean)) {
        const next = cur ? cur + " " + word : word;
        if (this.width(next, size, b) <= maxW) cur = next;
        else {
          if (cur) lines.push(cur);
          // hard-break very long words
          let w = word;
          while (this.width(w, size, b) > maxW && w.length > 1) {
            let i = w.length - 1;
            while (i > 1 && this.width(w.slice(0, i), size, b) > maxW) i--;
            lines.push(w.slice(0, i)); w = w.slice(i);
          }
          cur = w;
        }
      }
      lines.push(cur);
    }
    return lines;
  }
}

export async function renderInvoicePdf(d: InvoicePdfData): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const companyName = d.company.legal_name || d.company.name;
  doc.setTitle(`Invoice ${d.invoice.number} - ${companyName}`);
  doc.setAuthor(companyName);
  doc.setSubject(d.stamp ? `Invoice ${d.invoice.number} (${d.stamp.kind === "paid" ? "paid" : "partial payment"})` : `Invoice ${d.invoice.number}`);
  doc.setCreator("GrokBooks invoice-pdf");
  const W = new Writer(await doc.embedFont(StandardFonts.Helvetica), await doc.embedFont(StandardFonts.HelveticaBold));

  let page = doc.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - M;

  // ---- Header: logo (or placeholder) + company block on the left, title on the right
  // A wide wordmark logo already carries the company name, so the bold name line is
  // dropped when a logo is drawn (address/contact lines stay).
  const logoW = 210, logoMaxH = 52;
  let logoH = logoMaxH;
  if (d.logo) {
    const img = d.logo.type === "png" ? await doc.embedPng(d.logo.bytes) : await doc.embedJpg(d.logo.bytes);
    const s = Math.min(logoW / img.width, logoMaxH / img.height);
    logoH = img.height * s;
    page.drawImage(img, { x: M, y: y - logoH, width: img.width * s, height: logoH });
  } else {
    page.drawRectangle({ x: M, y: y - logoH, width: 130, height: logoH, borderColor: RULE, borderWidth: 1, borderDashArray: [3, 3] });
    W.text(page, "LOGO", M + 65, y - logoH / 2 - 3, 9, { color: MUTED, align: "center" });
  }
  W.text(page, "INVOICE", PAGE_W - M, y - 26, 26, { bold: true, color: ACCENT, align: "right" });

  const headTop = y - Math.max(logoH, 40) - 18;
  let cy = headTop;
  if (!d.logo) { W.text(page, companyName, M, cy, 12, { bold: true }); cy -= 14; }
  const contact = [...addressLines(d.company.address ?? null), [d.company.phone, d.company.email].filter(Boolean).join("  |  "), d.company.website ?? ""].filter(Boolean);
  for (const l of contact) { W.text(page, l, M, cy, 9, { color: MUTED }); cy -= 12; }

  // Meta box (right)
  const meta: [string, string][] = [
    ["Invoice #", d.invoice.number],
    ["Invoice date", usDate(d.invoice.txn_date)],
    ["Due date", usDate(d.invoice.due_date) || usDate(d.invoice.txn_date)],
    ["Terms", d.invoice.terms || "Due on receipt"],
  ];
  let my = headTop;
  const labelX = PAGE_W - M - 200;
  for (const [k, v] of meta) {
    W.text(page, k, labelX, my, 9, { color: MUTED });
    W.text(page, v, PAGE_W - M, my, 9.5, { bold: k === "Invoice #", align: "right" });
    my -= 14;
  }
  // Pay Online button (page 1, under the meta box). Hidden for receipts, void and paid invoices.
  if (d.pay_url && !d.stamp && !d.invoice.voided && d.balance_due > 0.004) {
    my -= 4;
    W.text(page, "Balance due", labelX, my, 9, { color: MUTED });
    W.text(page, money(d.balance_due), PAGE_W - M, my, 11, { bold: true, align: "right" });
    my -= 14;
    const bw = 200, bh = 26, bx = PAGE_W - M - bw, by = my - bh + 6;
    page.drawRectangle({ x: bx, y: by, width: bw, height: bh, color: rgb(0.1, 0.5, 0.22) });
    W.text(page, "PAY ONLINE  >", bx + bw / 2, by + 9, 11, { bold: true, color: rgb(1, 1, 1), align: "center" });
    const short = d.pay_url.replace(/^https?:\/\//, "").replace(/^([^/]+)\/.*?\?t=([0-9a-f]{8}).*$/i, "$1/…?t=$2…");
    const urlY = by - 11;
    W.text(page, "Card or bank (ACH) - secure link:", bx, urlY, 7.5, { color: MUTED });
    W.text(page, short.replace("…", "...").replace("…", "..."), bx, urlY - 9, 7, { color: ACCENT });
    addLink(page, d.pay_url, bx, urlY - 12, bw, by + bh - (urlY - 12));
    my = urlY - 16;
  }
  y = Math.min(cy, my) - 14;

  // ---- Bill to
  page.drawLine({ start: { x: M, y }, end: { x: PAGE_W - M, y }, thickness: 0.75, color: RULE });
  y -= 18;
  W.text(page, "BILL TO", M, y, 8.5, { bold: true, color: ACCENT }); y -= 14;
  const custName = d.customer.company_name || d.customer.display_name;
  W.text(page, custName, M, y, 11, { bold: true }); y -= 13;
  for (const l of addressLines(d.customer.address ?? null, [custName, d.customer.display_name])) { W.text(page, l, M, y, 9.5); y -= 12; }
  if (d.customer.email) { W.text(page, d.customer.email, M, y, 9, { color: MUTED }); y -= 12; }
  if (d.invoice.voided) { W.text(page, "VOID", PAGE_W - M, y + 20, 18, { bold: true, color: PLACEHOLDER, align: "right" }); }
  y -= 14;

  // ---- Line table
  const colQty = PAGE_W - M - 230, colRate = PAGE_W - M - 110, colAmt = PAGE_W - M - 8;
  const descX = M + 8, descW = colQty - 40 - descX;
  const drawHeader = () => {
    page.drawRectangle({ x: M, y: y - 6, width: PAGE_W - 2 * M, height: 20, color: SHADE });
    W.text(page, "DESCRIPTION", descX, y, 8.5, { bold: true, color: MUTED });
    W.text(page, "QTY", colQty, y, 8.5, { bold: true, color: MUTED, align: "right" });
    W.text(page, "RATE", colRate, y, 8.5, { bold: true, color: MUTED, align: "right" });
    W.text(page, "AMOUNT", colAmt, y, 8.5, { bold: true, color: MUTED, align: "right" });
    y -= 24;
  };
  drawHeader();
  const FOOTER_SPACE = 250; // totals + remit/payment blocks + footer
  d.lines.forEach((ln, idx) => {
    const title = ln.item_name || ln.description || "";
    const sub = ln.item_name && ln.description && ln.description.trim() !== ln.item_name ? W.wrap(ln.description, 8.5, PAGE_W - 2 * M - 16) : []; // full table width below the title row
    const titleLines = W.wrap(title, 9.5, descW, true);
    const newPage = () => { page = doc.addPage([PAGE_W, PAGE_H]); y = PAGE_H - M; W.text(page, `Invoice ${d.invoice.number} (continued)`, M, y, 9, { color: MUTED }); y -= 24; drawHeader(); };
    const bottom = M + 40;
    // Only move the row to a new page if not even the title + a couple of description lines fit.
    if (y - (titleLines.length * 12 + Math.min(sub.length, 2) * 11 + 14) < bottom) newPage();
    const rowTop = y;
    titleLines.forEach((t, i) => W.text(page, t, descX, y - i * 12, 9.5, { bold: true }));
    W.text(page, qtyFmt(ln.qty), colQty, rowTop, 9.5, { align: "right" });
    W.text(page, ln.unit_price == null ? "" : money(Number(ln.unit_price)), colRate, rowTop, 9.5, { align: "right" });
    W.text(page, money(Number(ln.amount)), colAmt, rowTop, 9.5, { align: "right" });
    let sy = y - titleLines.length * 12;
    // Long descriptions flow line by line and continue on the next page when needed.
    for (const s of sub) {
      if (sy - 11 < bottom) { newPage(); sy = y; W.text(page, "(continued)", descX, sy, 8.5, { color: MUTED }); sy -= 11; }
      W.text(page, s, descX, sy, 8.5, { color: MUTED }); sy -= 11;
    }
    const sepY = sy + 11 - 8;
    y = sepY - 11;
    if (idx < d.lines.length - 1) page.drawLine({ start: { x: M, y: sepY }, end: { x: PAGE_W - M, y: sepY }, thickness: 0.5, color: RULE });
    else page.drawLine({ start: { x: M, y: sepY }, end: { x: PAGE_W - M, y: sepY }, thickness: 0.75, color: RULE });
  });
  if (!d.lines.length) y -= 6;
  if (y < M + FOOTER_SPACE) { page = doc.addPage([PAGE_W, PAGE_H]); y = PAGE_H - M - 10; }

  // ---- Totals
  y -= 16;
  const tl = PAGE_W - M - 220;
  const subtotal = d.lines.reduce((s, l) => s + Number(l.amount), 0);
  W.text(page, "Subtotal", tl, y, 9.5, { color: MUTED }); W.text(page, money(subtotal), colAmt, y, 9.5, { align: "right" }); y -= 15;
  if (Math.abs(subtotal - d.invoice.total_amount) > 0.004) {
    W.text(page, "Invoice total", tl, y, 9.5, { color: MUTED }); W.text(page, money(d.invoice.total_amount), colAmt, y, 9.5, { align: "right" }); y -= 15;
  }
  W.text(page, "Payments applied", tl, y, 9.5, { color: MUTED }); W.text(page, d.amount_paid ? money(-d.amount_paid) : money(0), colAmt, y, 9.5, { align: "right" }); y -= 10;
  page.drawRectangle({ x: tl - 8, y: y - 18, width: PAGE_W - M - tl + 8, height: 24, color: SHADE });
  W.text(page, "BALANCE DUE", tl, y - 10, 10.5, { bold: true }); W.text(page, money(d.balance_due), colAmt, y - 10, 12, { bold: true, align: "right" });
  y -= 40;
  const totalsBottom = y;

  if (d.invoice.customer_memo) {
    W.text(page, "MESSAGE", M, y, 8.5, { bold: true, color: ACCENT }); y -= 12;
    for (const l of W.wrap(d.invoice.customer_memo, 9, PAGE_W - 2 * M).slice(0, 4)) { W.text(page, l, M, y, 9); y -= 11; }
    y -= 8;
  }

  // ---- Remit-to and payment instructions
  const boxTop = Math.min(y, M + 150), boxH = 110, gap = 16, boxW = (PAGE_W - 2 * M - gap) / 2;
  const block = (x: number, title: string, value: string | null | undefined, column: string) => {
    page.drawRectangle({ x, y: boxTop - boxH, width: boxW, height: boxH, borderColor: RULE, borderWidth: 0.75 });
    W.text(page, title, x + 10, boxTop - 16, 8.5, { bold: true, color: ACCENT });
    let by = boxTop - 31;
    if (value && value.trim()) {
      for (const l of W.wrap(value, 9, boxW - 20).slice(0, 6)) { W.text(page, l, x + 10, by, 9); by -= 12; }
    } else {
      for (const l of W.wrap(`[PLACEHOLDER] Not configured. Set companies.${column} for this company.`, 9, boxW - 20)) { W.text(page, l, x + 10, by, 9, { bold: true, color: PLACEHOLDER }); by -= 12; }
    }
  };
  block(M, "REMIT TO", d.company.remit_to, "remit_to");
  block(M + boxW + gap, "PAYMENT INSTRUCTIONS", d.company.payment_instructions, "payment_instructions");

  // ---- Footer
  const contactLine = [d.company.phone, d.company.email].filter(Boolean).join("  |  ");
  W.text(page, "Thank you for your business.", PAGE_W / 2, M - 4, 9.5, { bold: true, align: "center" });
  if (contactLine) W.text(page, `Questions? ${contactLine}`, PAGE_W / 2, M - 17, 8.5, { color: MUTED, align: "center" });

  // ---- PAID / PARTIAL PAYMENT stamp (overlay on the totals page)
  // Centered in the open space between the totals and the remit blocks; if
  // there is little room it simply overlays the page (it is semi-transparent).
  if (d.stamp) {
    const cy = Math.max((totalsBottom + boxTop) / 2 + 14, boxTop + 45);
    drawStamp(page, W, d.stamp, PAGE_W / 2, Math.min(cy, PAGE_H / 2 + 60));
  }

  return await doc.save();
}

function drawStamp(page: PDFPage, W: Writer, s: NonNullable<InvoicePdfData["stamp"]>, cx: number, cy: number) {
  const paid = s.kind === "paid";
  const color = paid ? rgb(0.09, 0.55, 0.27) : rgb(0.8, 0.12, 0.12);
  const angle = 14, rad = (angle * Math.PI) / 180;
  const title = paid ? "PAID" : "PARTIAL PAYMENT";
  const titleSize = paid ? 64 : 34;
  const details: string[] = [];
  if (paid) {
    if (s.paid_date) details.push(usDate(s.paid_date));
    details.push(money(s.amount_paid));
  } else {
    details.push(`Paid ${money(s.amount_paid)}${s.paid_date ? "  on " + usDate(s.paid_date) : ""}`);
    details.push(`Remaining balance ${money(s.balance_due)}`);
  }
  const ref = [s.method ? s.method.toUpperCase() : null, s.reference ? `Ref ${s.reference}` : null, (s.payment_count ?? 0) > 1 ? `${s.payment_count} payments` : null].filter(Boolean).join("  |  ");
  if (ref) details.push(ref);
  const detailSize = 13;
  const innerW = Math.max(W.width(title, titleSize, true), ...details.map((t) => W.width(t, detailSize, true)));
  const padX = 22, padY = 14;
  const boxW = innerW + padX * 2;
  const boxH = titleSize * 0.78 + details.length * (detailSize + 6) + padY * 2 + 6;
  const rot = (lx: number, ly: number) => ({ x: cx + lx * Math.cos(rad) - ly * Math.sin(rad), y: cy + lx * Math.sin(rad) + ly * Math.cos(rad) });
  const outer = rot(-boxW / 2, -boxH / 2);
  page.drawRectangle({ x: outer.x, y: outer.y, width: boxW, height: boxH, rotate: degrees(angle), borderColor: color, borderWidth: 4, borderOpacity: 0.6, color, opacity: 0.05 });
  const inner = rot(-boxW / 2 + 6, -boxH / 2 + 6);
  page.drawRectangle({ x: inner.x, y: inner.y, width: boxW - 12, height: boxH - 12, rotate: degrees(angle), borderColor: color, borderWidth: 1.25, borderOpacity: 0.55 });
  let ly = boxH / 2 - padY - titleSize * 0.74;
  const put = (t: string, size: number, bold: boolean) => {
    const st = W.safe(t);
    const w = (bold ? W.bold : W.regular).widthOfTextAtSize(st, size);
    const p = rot(-w / 2, ly);
    page.drawText(st, { x: p.x, y: p.y, size, font: bold ? W.bold : W.regular, color, opacity: 0.6, rotate: degrees(angle) });
  };
  put(title, titleSize, true);
  ly -= 10;
  for (const t of details) { ly -= detailSize + 6; put(t, detailSize, true); }
}

// URI link annotation over a rectangle (clickable in PDF viewers).
function addLink(page: PDFPage, url: string, x: number, y: number, w: number, h: number) {
  const ctx = page.doc.context;
  const annot = ctx.register(ctx.obj({
    Type: "Annot", Subtype: "Link", Rect: [x, y, x + w, y + h], Border: [0, 0, 0],
    A: { Type: "Action", S: "URI", URI: PDFString.of(url) },
  }));
  const existing = page.node.lookup(PDFName.of("Annots"));
  if (existing && "push" in existing) (existing as unknown as { push(v: unknown): void }).push(annot);
  else page.node.set(PDFName.of("Annots"), ctx.obj([annot]));
}
