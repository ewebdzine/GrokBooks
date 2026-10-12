// Local preview: render from a raw bundle JSON (same shape the function loads).
// Optional logo bytes are not loaded from disk. Put logo bytes on the assembled
// data if you have them; otherwise the PDF draws a placeholder.
import { renderInvoicePdf } from "../render.ts";
import { assemble } from "../data.ts";
const [inFile, outFile, stamp] = Deno.args;
const raw = JSON.parse(await Deno.readTextFile(inFile));
const { data, stampKind } = assemble(raw, stamp === "paid" ? "paid" : null);
await Deno.writeFile(outFile, await renderInvoicePdf(data));
console.log(outFile, "stamp:", stampKind);
