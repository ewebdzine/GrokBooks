// Local render of the CAM true-up PDFs from JSON pulled out of cam_trueup_bundle().
//   deno run -A dev/render_local.ts <data_dir> <out_dir>
// data_dir: part1.json (company, property, expenses, income), statements.json, extra.json
//           (vacant row, monthly adjustment, warnings) and optional comparison.json.
import { renderCamSummaryPdf, renderCamStatementPdf, type SummaryInput } from "../render.ts";
const [dataDir, outDir] = Deno.args;
const rd = async (f: string) => JSON.parse(await Deno.readTextFile(`${dataDir}/${f}`));
const p1 = await rd("part1.json"), statements = await rd("statements.json"), extra = await rd("extra.json");
let comparison; try { comparison = await rd("comparison.json"); } catch { comparison = undefined; }
const year = Number(p1.year ?? new Date().getFullYear()), today = new Date().toISOString().slice(0, 10);
const input: SummaryInput = { year, generated_on: today, company: p1.company, property: p1.property, expenses: p1.expenses, income: p1.income,
  statements, vacant: extra.vacant, monthly: extra.monthly, warnings: extra.warnings, comparison };
await Deno.mkdir(`${outDir}/statements`, { recursive: true });
await Deno.writeFile(`${outDir}/CAM_TrueUp_${year}_Summary.pdf`, await renderCamSummaryPdf(input));
for (const s of statements) {
  const slug = s.tenant.name.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_|_$/g, "");
  const monthly = extra.monthly.find((m: any) => m.suite === s.lease.suite) ?? null;
  const f = `${outDir}/statements/CAM_${year}_Suite_${s.lease.suite}_${slug}.pdf`;
  await Deno.writeFile(f, await renderCamStatementPdf(s, { year, company: p1.company, property: p1.property, statement_date: today, monthly }));
  console.log(f);
}
