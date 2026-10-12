// Pure PDF renderers for the GrokBooks CAM true-up (no I/O): a landscape summary
// report and per-tenant statements. Styling (fonts, colours, header, remit-to box)
// matches functions/invoice-pdf/render.ts. Input is the jsonb produced by
// public.cam_trueup_bundle / public.cam_tenant_statement (compacted).
import { PDFDocument, PDFPage, PDFImage, StandardFonts, rgb, degrees, RGB } from "npm:pdf-lib@1.17.1";
import { Writer, money, usDate, addressLines, type Address } from "../../supabase/functions/invoice-pdf/render.ts";

const INK = rgb(0.13, 0.15, 0.18), MUTED = rgb(0.42, 0.45, 0.5);
const RULE = rgb(0.82, 0.84, 0.87), SHADE = rgb(0.94, 0.95, 0.97);
const ACCENT = rgb(0.12, 0.29, 0.49), RED = rgb(0.75, 0.1, 0.1), GREEN = rgb(0.09, 0.45, 0.25);
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const M = 36;

export interface Company { logo?: { bytes: Uint8Array; type: "png" | "jpg" } | null; name: string; legal_name?: string | null; address?: Address; phone?: string | null; email?: string | null; remit_to?: string | null; payment_instructions?: string | null }
export interface StatementLine { c: string; l: string; p: number; s: number; pct: number }
export interface Statement {
  kind: "due" | "refund" | "zero"; balance: number; est_total: number; est_count: number; pool_total: number; share_total: number;
  tenant: { name: string; customer?: string; attention?: string | null; address?: Address; email?: string | null };
  lease: { suite: string; sf: number; building_sf: number; start_date?: string | null; end_date?: string | null; status: string; owner_occupied: boolean;
           cam_billable: boolean; non_billable_reason?: string | null; occupancy_days: number; days_in_year: number; occupancy_factor: number; pro_rata_pct: number };
  lines: StatementLine[];
}
export interface MonthlyRow { suite: string; tenant: string; share: number; est: number; months: number; n: number; avg: number | null; cur: number | null; cur_date?: string | null; bal: number; diff: number | null; dir: string | null; note: string }
export interface SummaryInput {
  year: number; generated_on: string; company: Company; property: { name: string; address?: Address };
  expenses: Record<string, any>[]; income: Record<string, any>[]; statements: Statement[];
  vacant: { sf: number; eff: number; total_share: number; shares: Record<string, number> };
  monthly: MonthlyRow[]; warnings: { severity: string; code: string; message: string }[];
  comparison?: { suite: string; tenant: string; original_due: number; original_note?: string }[];
}

const pct = (v: number | null | undefined, d = 2) => (v == null ? "" : (v * 100).toFixed(d) + "%");
const num = (v: number | null | undefined) => (v == null ? "" : Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
const signed = (v: number) => (v > 0 ? "+" : v < 0 ? "-" : "") + money(Math.abs(v)).replace("-", "");

async function embedLogo(doc: PDFDocument, c: Company): Promise<PDFImage | null> {
  const l = c.logo;
  if (!l) return null;
  return l.type === "png" ? await doc.embedPng(l.bytes) : await doc.embedJpg(l.bytes);
}

// Header: company logo when the caller supplies one, otherwise a placeholder
// plus the company name. Address and contact lines come from the company record.
function header(page: PDFPage, W: Writer, c: Company, title: string, meta: [string, string][], pageW: number, pageH: number, logo: PDFImage | null) {
  let y = pageH - M;
  const logoMaxH = 48;
  let logoH = logoMaxH;
  if (logo) {
    const s = Math.min(200 / logo.width, logoMaxH / logo.height);
    logoH = logo.height * s;
    page.drawImage(logo, { x: M, y: y - logoH, width: logo.width * s, height: logoH });
  } else {
    page.drawRectangle({ x: M, y: y - logoH, width: 120, height: logoH, borderColor: RULE, borderWidth: 1 });
    W.text(page, "LOGO", M + 60, y - logoH / 2 - 3, 8, { color: MUTED, align: "center" });
  }
  W.text(page, title, pageW - M, y - 24, 22, { bold: true, color: ACCENT, align: "right" });
  let cy = y - Math.max(logoH, 40) - 16;
  if (!logo) { W.text(page, c.legal_name || c.name, M, cy, 11, { bold: true }); cy -= 13; }
  for (const l of [...addressLines(c.address ?? null), [c.phone, c.email].filter(Boolean).join("  |  ")].filter(Boolean)) { W.text(page, l, M, cy, 8.5, { color: MUTED }); cy -= 11; }
  let my = y - Math.max(logoH, 40) - 16; const lx = pageW - M - 230;
  for (const [k, v] of meta) { W.text(page, k, lx, my, 8.5, { color: MUTED }); W.text(page, v, pageW - M, my, 9, { bold: k === meta[0][0], align: "right" }); my -= 13; }
  return Math.min(cy, my) - 8;
}

function footer(page: PDFPage, W: Writer, c: Company, pageW: number, left: string, right: string) {
  page.drawLine({ start: { x: M, y: M - 2 }, end: { x: pageW - M, y: M - 2 }, thickness: 0.5, color: RULE });
  W.text(page, left, M, M - 14, 7.5, { color: MUTED });
  W.text(page, right, pageW - M, M - 14, 7.5, { color: MUTED, align: "right" });
}

// ---------------------------------------------------------------------------
// Summary report (landscape letter)
// ---------------------------------------------------------------------------
type Col = { key: string; label: string; w: number; align?: "left" | "right"; fmt?: (v: any, r: any) => string };

export async function renderCamSummaryPdf(d: SummaryInput): Promise<Uint8Array> {
  const PW = 792, PH = 612;
  const doc = await PDFDocument.create();
  const co = d.company.legal_name || d.company.name;
  doc.setTitle(`${d.property.name} - ${d.year} CAM True-Up Summary`); doc.setAuthor(co); doc.setCreator("GrokBooks cam-trueup-pdf");
  const W = new Writer(await doc.embedFont(StandardFonts.Helvetica), await doc.embedFont(StandardFonts.HelveticaBold));
  const pages: PDFPage[] = [];
  let page = doc.addPage([PW, PH]); pages.push(page);
  const meta: [string, string][] = [["Property", d.property.name], ["Reporting period", `01/01/${d.year} - 12/31/${d.year}`],
    ["Building sq ft", (d.statements[0]?.lease.building_sf ?? 0).toLocaleString("en-US")], ["Prepared", usDate(d.generated_on)]];
  let y = header(page, W, d.company, `${d.year} CAM TRUE-UP SUMMARY`, meta, PW, PH, await embedLogo(doc, d.company));

  const newPage = () => { page = doc.addPage([PW, PH]); pages.push(page); y = PH - M - 6; W.text(page, `${d.property.name} - ${d.year} CAM True-Up Summary (continued)`, M, y, 8.5, { color: MUTED }); y -= 18; };
  const need = (h: number) => { if (y - h < M + 14) newPage(); };
  const section = (t: string, sub?: string) => {
    need(60); y -= 6;
    page.drawLine({ start: { x: M, y: y + 12 }, end: { x: PW - M, y: y + 12 }, thickness: 0.75, color: RULE });
    W.text(page, t.toUpperCase(), M, y, 9, { bold: true, color: ACCENT });
    if (sub) W.text(page, sub, M + W.width(t.toUpperCase(), 9, true) + 10, y, 7.5, { color: MUTED });
    y -= 14;
  };
  const table = (cols: Col[], rows: any[], style: (r: any) => { bold?: boolean; shade?: boolean; color?: RGB; rule?: boolean } = () => ({}), size = 7) => {
    const total = cols.reduce((s, c) => s + c.w, 0); const scale = (PW - 2 * M) / total;
    const xs: number[] = []; let x = M; for (const c of cols) { xs.push(x); x += c.w * scale; }
    const drawHead = () => {
      page.drawRectangle({ x: M, y: y - 4, width: PW - 2 * M, height: 14, color: SHADE });
      cols.forEach((c, i) => W.text(page, c.label, c.align === "left" ? xs[i] + 3 : xs[i] + c.w * scale - 3, y, size - 0.5, { bold: true, color: MUTED, align: c.align === "left" ? "left" : "right" }));
      y -= 14;
    };
    need(30); drawHead();
    for (const r of rows) {
      const st = style(r);
      // wrap first left column if needed
      const first = cols.findIndex((c) => c.align === "left" && c.key !== "suite");
      const firstLines = first >= 0 ? W.wrap(String(cols[first].fmt ? cols[first].fmt!(r[cols[first].key], r) : r[cols[first].key] ?? ""), size, cols[first].w * scale - 6, !!st.bold) : [""];
      const h = Math.max(1, firstLines.length) * (size + 2.5) + 2;
      if (y - h < M + 14) { newPage(); drawHead(); }
      if (st.shade) page.drawRectangle({ x: M, y: y - h + size + 1, width: PW - 2 * M, height: h, color: SHADE });
      cols.forEach((c, i) => {
        if (i === first) { firstLines.forEach((t, k) => W.text(page, t, xs[i] + 3, y - k * (size + 2.5), size, { bold: st.bold, color: st.color })); return; }
        const v = c.fmt ? c.fmt(r[c.key], r) : r[c.key] == null ? "" : String(r[c.key]);
        W.text(page, v, c.align === "left" ? xs[i] + 3 : xs[i] + c.w * scale - 3, y, size, { bold: st.bold, color: st.color, align: c.align === "left" ? "left" : "right" });
      });
      if (st.rule) page.drawLine({ start: { x: M, y: y + size + 1.5 }, end: { x: PW - M, y: y + size + 1.5 }, thickness: 0.5, color: RULE });
      y -= h;
    }
    y -= 6;
  };

  // ---- Key figures
  const S = d.statements;
  const pool = d.expenses.find((r) => r.row_type === "grand_total")?.total ?? 0;
  const tenantShare = S.reduce((s, x) => s + x.share_total, 0);
  const est = S.reduce((s, x) => s + x.est_total, 0);
  const billable = S.filter((x) => x.lease.cam_billable);
  const billBal = billable.reduce((s, x) => s + x.balance, 0);
  const nonBill = S.filter((x) => !x.lease.cam_billable).reduce((s, x) => s + x.balance, 0);
  const kpis: [string, string][] = [["Total CAM pool (incl. admin fee)", money(pool)], ["Tenant shares", money(tenantShare)], ["Vacant / landlord share", money(d.vacant.total_share)],
    ["CAM estimates billed (4025)", money(est)], ["Balance due - billable tenants", money(billBal)], ["Not billed (owner / broken lease)", money(nonBill)]];
  const kw = (PW - 2 * M) / kpis.length;
  kpis.forEach(([k, v], i) => {
    const x = M + i * kw;
    page.drawRectangle({ x: x + 2, y: y - 30, width: kw - 4, height: 36, color: i === 4 ? SHADE : undefined, borderColor: RULE, borderWidth: 0.75 });
    W.text(page, k, x + 8, y - 6, 6.8, { color: MUTED });
    W.text(page, v, x + 8, y - 22, 11, { bold: true, color: i === 4 ? ACCENT : INK });
  });
  y -= 44;

  // ---- Expenses
  section("CAM expenses by category and month", "GL accrual basis; real estate taxes use the tax bill for the year (GL cash paid shown for reference)");
  const mcols: Col[] = MONTHS.map((m, i) => ({ key: `m${String(i + 1).padStart(2, "0")}`, label: m, w: 44, fmt: (v: any) => (v == null ? "" : num(v)) }));
  const exp = d.expenses.filter((r) => !(r.row_type === "account" && !r.total && MONTHS.every((_, i) => r[`m${String(i + 1).padStart(2, "0")}`] == null)));
  table([{ key: "label", label: "Category / account", w: 190, align: "left", fmt: (v: any, r: any) => (r.row_type === "account" || r.row_type === "tax_bill" ? "   " : "") + v },
    ...mcols, { key: "total", label: "Total", w: 56, fmt: (v: any) => num(v) }], exp,
    (r) => ({ bold: ["pool_total", "subtotal", "admin_fee", "grand_total"].includes(r.row_type), shade: ["subtotal", "grand_total"].includes(r.row_type),
              color: r.row_type === "account" && r.pool_code === "TAX" ? MUTED : r.row_type === "tax_bill" ? ACCENT : undefined, rule: r.row_type === "pool_total" }));

  // ---- Income
  section("CAM income by tenant and month", "estimates billed on tenant invoices, account 4025 CAM Income");
  table([{ key: "suite_number", label: "Suite", w: 30, align: "left" }, { key: "tenant_name", label: "Tenant", w: 160, align: "left" }, ...mcols,
    { key: "total", label: "Total", w: 56, fmt: (v: any) => num(v) }, { key: "invoice_count", label: "Inv.", w: 24 }], d.income,
    (r) => ({ bold: r.row_type === "total", shade: r.row_type === "total" }));

  // ---- Allocation
  section("Allocation by tenant", "share = pool x (suite sq ft / building sq ft) x (days occupied / days in year); balance = share - estimates billed");
  const share = (c: string) => (v: any, r: any) => num(r.shares?.[c]);
  const allocRows = S.map((s) => ({
    suite: s.lease.suite, tenant: s.tenant.name, sf: s.lease.sf, prp: s.lease.pro_rata_pct, days: s.lease.occupancy_days, eff: s.lines[0]?.pct,
    shares: Object.fromEntries(s.lines.map((l) => [l.c, l.s])), total: s.share_total, est: s.est_total, bal: s.balance,
    action: !s.lease.cam_billable ? (s.lease.owner_occupied ? "Not billed - owner" : "Not billed - broken lease") : s.balance > 0 ? "Bill" : s.balance < 0 ? "Refund" : "-",
    billable: s.lease.cam_billable,
  }));
  const vac = { suite: "", tenant: "Vacant / landlord share", sf: d.vacant.sf, prp: null, days: null, eff: d.vacant.eff, shares: d.vacant.shares, total: d.vacant.total_share, est: null, bal: null, action: "Landlord absorbs", vacant: true };
  const tot = { suite: "", tenant: "Total", sf: S[0]?.lease.building_sf, prp: null, days: null, eff: 1,
    shares: Object.fromEntries(S[0].lines.map((l) => [l.c, l.p])), total: pool, est, bal: S.reduce((s, x) => s + x.balance, 0), action: `Billable: ${money(billBal)}`, total_row: true };
  table([{ key: "suite", label: "Suite", w: 30, align: "left" }, { key: "tenant", label: "Tenant", w: 150, align: "left" },
    { key: "sf", label: "Sq ft", w: 40, fmt: (v: any) => (v == null ? "" : Number(v).toLocaleString("en-US", { maximumFractionDigits: 0 })) },
    { key: "prp", label: "Pro-rata", w: 40, fmt: (v: any) => pct(v) }, { key: "days", label: "Days", w: 28 }, { key: "eff", label: "Share %", w: 40, fmt: (v: any) => pct(v) },
    { key: "TAX", label: "Taxes", w: 50, fmt: share("TAX") }, { key: "INS", label: "Insurance", w: 46, fmt: share("INS") }, { key: "CAM", label: "CAM", w: 44, fmt: share("CAM") },
    { key: "SNOW", label: "Snow", w: 38, fmt: share("SNOW") }, { key: "UTIL", label: "Utilities", w: 44, fmt: share("UTIL") }, { key: "ADMIN", label: "Admin 10%", w: 42, fmt: share("ADMIN") },
    { key: "total", label: "Total share", w: 54, fmt: (v: any) => num(v) }, { key: "est", label: "Est. billed", w: 52, fmt: (v: any) => num(v) },
    { key: "bal", label: "Balance", w: 52, fmt: (v: any) => (v == null ? "" : num(v)) }, { key: "action", label: "Action", w: 92, align: "left" }],
    [...allocRows, vac, tot],
    (r) => ({ bold: !!r.total_row, shade: !!r.total_row || !!r.vacant, color: r.billable === false ? MUTED : undefined, rule: !!r.vacant }));

  // ---- Monthly adjustment
  section("Monthly CAM adjustment", "balanced monthly = annual true-up share / months billed in the year; difference = balanced monthly - current monthly estimate");
  table([{ key: "suite", label: "Suite", w: 30, align: "left" }, { key: "tenant", label: "Tenant", w: 160, align: "left" },
    { key: "share", label: `${d.year} share`, w: 56, fmt: (v: any) => num(v) }, { key: "est", label: "Est. billed", w: 56, fmt: (v: any) => num(v) },
    { key: "months", label: "Months", w: 36 }, { key: "avg", label: "Avg billed/mo", w: 58, fmt: (v: any) => num(v) },
    { key: "cur", label: "Current est./mo", w: 62, fmt: (v: any) => num(v) }, { key: "cur_date", label: "as of", w: 50, fmt: (v: any) => usDate(v) },
    { key: "bal", label: "Balanced/mo", w: 58, fmt: (v: any) => num(v) },
    { key: "diff", label: "Difference/mo", w: 62, fmt: (v: any, r: any) => (v == null ? "" : (v > 0 ? "+" : "") + num(v)) },
    { key: "dir", label: "Change", w: 46, align: "left" }, { key: "note", label: "Note", w: 150, align: "left" }], d.monthly,
    (r) => ({ color: r.note && /owner|broken/i.test(r.note) ? MUTED : undefined }));

  // ---- Comparison with original workbook
  if (d.comparison?.length) {
    section("Comparison with the original workbook", "original = Total CAM Percentage Due (E40) on each tenant tab");
    const rows = d.comparison.map((c) => { const s = S.find((x) => x.lease.suite === c.suite)!; return { ...c, now: s.balance, diff: s.balance - c.original_due, why: c.original_note ?? "" }; });
    rows.push({ suite: "", tenant: "Total", original_due: rows.reduce((a, r) => a + r.original_due, 0), now: rows.reduce((a, r) => a + r.now, 0), diff: rows.reduce((a, r) => a + r.diff, 0), why: "", total: true } as any);
    table([{ key: "suite", label: "Suite", w: 30, align: "left" }, { key: "tenant", label: "Tenant", w: 160, align: "left" },
      { key: "original_due", label: "Workbook due", w: 62, fmt: (v: any) => num(v) }, { key: "now", label: "GrokBooks balance", w: 70, fmt: (v: any) => num(v) },
      { key: "diff", label: "Difference", w: 60, fmt: (v: any) => (v > 0 ? "+" : "") + num(v) }, { key: "why", label: "Main reasons", w: 400, align: "left" }],
      rows, (r) => ({ bold: !!r.total, shade: !!r.total }));
  }

  // ---- Warnings
  section("Warnings and notes");
  for (const w of d.warnings) {
    const lines = W.wrap(w.message, 8, PW - 2 * M - 70);
    need(lines.length * 11 + 4);
    W.text(page, w.severity.toUpperCase(), M, y, 7.5, { bold: true, color: w.severity === "warning" ? RED : ACCENT });
    lines.forEach((l, i) => W.text(page, l, M + 60, y - i * 11, 8));
    y -= lines.length * 11 + 3;
  }
  need(14);
  W.text(page, "No invoices were created and nothing was written to QuickBooks. True-up invoices require separate approval.", M, y - 4, 7.5, { color: MUTED });

  pages.forEach((p, i) => footer(p, W, d.company, PW, `${co} - ${d.property.name} - ${d.year} CAM true-up summary`, `Page ${i + 1} of ${pages.length}`));
  return await doc.save();
}

// ---------------------------------------------------------------------------
// Tenant statement (portrait letter, invoice styling)
// ---------------------------------------------------------------------------
export async function renderCamStatementPdf(s: Statement, ctx: { year: number; company: Company; property: { name: string; address?: Address }; statement_date: string; monthly?: MonthlyRow | null }): Promise<Uint8Array> {
  const PW = 612, PH = 792;
  const doc = await PDFDocument.create();
  const co = ctx.company.legal_name || ctx.company.name;
  const number = `CAM-${ctx.year}-${s.lease.suite}`;
  doc.setTitle(`${number} - ${s.tenant.name} - ${ctx.year} CAM statement`); doc.setAuthor(co); doc.setCreator("GrokBooks cam-trueup-pdf");
  const W = new Writer(await doc.embedFont(StandardFonts.Helvetica), await doc.embedFont(StandardFonts.HelveticaBold));
  const page = doc.addPage([PW, PH]);
  const L = 50, R = PW - 50;
  let y = header(page, W, ctx.company, "CAM STATEMENT", [["Statement #", number], ["Statement date", usDate(ctx.statement_date)],
    ["Reporting period", `01/01/${ctx.year} - 12/31/${ctx.year}`], ["Terms", s.lease.cam_billable ? "Due on receipt" : "Not billed"]], PW, PH, await embedLogo(doc, ctx.company)) - 4;

  // Bill to + RE
  page.drawLine({ start: { x: L, y }, end: { x: R, y }, thickness: 0.75, color: RULE }); y -= 16;
  W.text(page, "TENANT", L, y, 8.5, { bold: true, color: ACCENT });
  W.text(page, "PREMISES", 330, y, 8.5, { bold: true, color: ACCENT }); y -= 14;
  let ty = y;
  W.text(page, s.tenant.name, L, ty, 11, { bold: true }); ty -= 13;
  if (s.tenant.attention) { W.text(page, `Attn: ${s.tenant.attention}`, L, ty, 9.5); ty -= 12; }
  for (const l of addressLines(s.tenant.address ?? null, [s.tenant.name])) { W.text(page, l, L, ty, 9.5); ty -= 12; }
  if (s.tenant.email) { W.text(page, s.tenant.email, L, ty, 9, { color: MUTED }); ty -= 12; }
  let py = y;
  const prem: [string, string][] = [["Property", ctx.property.name], ["Suite", s.lease.suite], ["Lease start", usDate(s.lease.start_date) || "-"],
    ["Suite sq ft", s.lease.sf.toLocaleString("en-US")], ["Building sq ft", s.lease.building_sf.toLocaleString("en-US")],
    ["Pro-rata share", pct(s.lease.pro_rata_pct, 3)], ["Days occupied", `${s.lease.occupancy_days} of ${s.lease.days_in_year}`]];
  for (const [k, v] of prem) { W.text(page, k, 330, py, 8.5, { color: MUTED }); W.text(page, v, R, py, 9, { align: "right" }); py -= 12; }
  y = Math.min(ty, py) - 10;
  const place = addressLines(ctx.property.address ?? null).join(", ");
  const re = place
    ? `RE: ${ctx.property.name}, ${place} - ${ctx.year} Taxes, Insurance, CAM Expenses`
    : `RE: ${ctx.property.name} - ${ctx.year} Taxes, Insurance, CAM Expenses`;
  W.text(page, re, L, y, 9.5, { bold: true }); y -= 18;

  // Line table
  const cTot = R - 190, cPct = R - 95, cAmt = R - 8;
  page.drawRectangle({ x: L, y: y - 6, width: R - L, height: 20, color: SHADE });
  W.text(page, "DESCRIPTION", L + 8, y, 8.5, { bold: true, color: MUTED });
  W.text(page, "CENTER TOTAL", cTot, y, 8.5, { bold: true, color: MUTED, align: "right" });
  W.text(page, "YOUR SHARE %", cPct, y, 8.5, { bold: true, color: MUTED, align: "right" });
  W.text(page, "YOUR SHARE", cAmt, y, 8.5, { bold: true, color: MUTED, align: "right" }); y -= 22;
  for (const ln of s.lines) {
    const label = ln.c === "ADMIN" ? "Administrative Fee (10% of CAM, snow and utilities)" : ln.l;
    W.text(page, label, L + 8, y, 9.5, { bold: true });
    if (ln.c === "TAX") W.text(page, `Tax bill for ${ctx.year}`, L + 8, y - 11, 8, { color: MUTED });
    if (ln.c === "INS") W.text(page, "Actual premiums posted in GrokBooks", L + 8, y - 11, 8, { color: MUTED });
    W.text(page, money(ln.p), cTot, y, 9.5, { align: "right" });
    W.text(page, pct(ln.pct, 3), cPct, y, 9.5, { align: "right" });
    W.text(page, money(ln.s), cAmt, y, 9.5, { align: "right" });
    const h = ln.c === "TAX" || ln.c === "INS" ? 26 : 18;
    page.drawLine({ start: { x: L, y: y - h + 12 }, end: { x: R, y: y - h + 12 }, thickness: 0.5, color: RULE });
    y -= h;
  }
  if (s.lease.occupancy_factor < 1) { W.text(page, `Share % = ${pct(s.lease.pro_rata_pct, 3)} pro-rata x ${s.lease.occupancy_days}/${s.lease.days_in_year} days occupied.`, L + 8, y + 2, 8, { color: MUTED }); y -= 12; }

  // Totals
  y -= 10; const tl = R - 250;
  W.text(page, "Center total (incl. admin fee)", tl, y, 9.5, { color: MUTED }); W.text(page, money(s.pool_total), cAmt, y, 9.5, { align: "right" }); y -= 15;
  W.text(page, `Your ${ctx.year} share`, tl, y, 9.5, { color: MUTED }); W.text(page, money(s.share_total), cAmt, y, 9.5, { bold: true, align: "right" }); y -= 15;
  W.text(page, `Less: CAM estimates billed (${s.est_count} invoice${s.est_count === 1 ? "" : "s"})`, tl, y, 9.5, { color: MUTED }); W.text(page, money(-s.est_total), cAmt, y, 9.5, { align: "right" }); y -= 10;
  const label = !s.lease.cam_billable ? (s.balance >= 0 ? "BALANCE (NOT BILLED)" : "CREDIT (NOT ISSUED)") : s.balance >= 0 ? "BALANCE DUE" : "CREDIT DUE TO TENANT";
  page.drawRectangle({ x: tl - 8, y: y - 18, width: R - tl + 8, height: 24, color: SHADE });
  W.text(page, label, tl, y - 10, 10.5, { bold: true }); W.text(page, money(Math.abs(s.balance)), cAmt, y - 10, 12, { bold: true, align: "right", color: s.balance < 0 ? GREEN : INK });
  y -= 36;

  // Not-billed banner (owner-occupied / lease broken)
  if (!s.lease.cam_billable) {
    const t1 = s.lease.owner_occupied ? "NOT BILLED - OWNER OCCUPIED (PART OWNER)" : "NOT BILLABLE - LEASE BROKEN";
    page.drawRectangle({ x: L, y: y - 26, width: R - L, height: 34, borderColor: RED, borderWidth: 1.5, borderOpacity: 0.8, color: RED, opacity: 0.05 });
    W.text(page, t1, PW / 2, y - 6, 13, { bold: true, color: RED, align: "center" });
    W.text(page, (s.lease.non_billable_reason ?? "") + ". Shown for reference only; no invoice will be issued.", PW / 2, y - 19, 7.5, { color: RED, align: "center" });
    y -= 44;
  }

  // Monthly estimate note
  if (ctx.monthly && ctx.monthly.cur != null) {
    const m = ctx.monthly;
    W.text(page, "MONTHLY CAM ESTIMATE", L, y, 8.5, { bold: true, color: ACCENT }); y -= 12;
    const t = `Current monthly CAM estimate ${money(m.cur!)}. The monthly amount that would have balanced ${ctx.year} exactly is ${money(m.bal)} (${ctx.year} share / ${m.months} months billed), ` +
      `a difference of ${signed(m.diff ?? 0)} per month${m.dir && m.dir !== "no change" ? ` (${m.dir})` : ""}.`;
    for (const l of W.wrap(t, 9, R - L)) { W.text(page, l, L, y, 9); y -= 11; }
    y -= 6;
  }

  // Remit-to + notes
  const boxTop = Math.min(y, 50 + 125), boxH = 95, gap = 16, boxW = (R - L - gap) / 2;
  const block = (x: number, title: string, text: string) => {
    page.drawRectangle({ x, y: boxTop - boxH, width: boxW, height: boxH, borderColor: RULE, borderWidth: 0.75 });
    W.text(page, title, x + 10, boxTop - 16, 8.5, { bold: true, color: ACCENT });
    let by = boxTop - 31; for (const l of W.wrap(text, 8.5, boxW - 20).slice(0, 7)) { W.text(page, l, x + 10, by, 8.5); by -= 11.5; }
  };
  block(L, "REMIT TO", ctx.company.remit_to || co);
  block(L + boxW + gap, "HOW THIS WAS CALCULATED",
    `Each expense is shared by suite sq ft / ${s.lease.building_sf.toLocaleString("en-US")} building sq ft` +
    (s.lease.occupancy_factor < 1 ? `, prorated for ${s.lease.occupancy_days} days occupied` : "") +
    `. Taxes use the ${ctx.year} tax bill. A 10% administrative fee applies to CAM, snow and utilities only. ` +
    `Estimates billed are the CAM charges on your ${ctx.year} invoices. Please reference ${number} with payment.`);

  const contact = [ctx.company.phone, ctx.company.email].filter(Boolean).join("  |  ");
  W.text(page, "Thank you for your business.", PW / 2, 50 - 4, 9.5, { bold: true, align: "center" });
  if (contact) W.text(page, `Questions? ${contact}`, PW / 2, 50 - 17, 8.5, { color: MUTED, align: "center" });
  return await doc.save();
}
