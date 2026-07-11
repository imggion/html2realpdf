import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { spawn } from "node:child_process";

import {
  analyticsReportHtml,
  complexInvoiceHtml,
  presentationDeckHtml,
  roundedOperationsReportHtml,
} from "../web/pdf-fixtures.js";

const root = resolve(import.meta.dirname, "../..");
const outputDir = resolve(import.meta.dirname, "0.1.0-alpha.0");
const wasmPath = resolve(root, "bindings/js/dist/libhtml2realpdf.wasm");
const wasm = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(wasm, {});
const api = instance.exports;
const encoder = new TextEncoder();
const fixtures = [
  { name: "complex-invoice", html: complexInvoiceHtml, width: 595.2756, height: 841.8898, pages: 2 },
  { name: "analytics-report", html: analyticsReportHtml, width: 595.2756, height: 841.8898, pages: 3 },
  { name: "rounded-operations", html: roundedOperationsReportHtml, width: 595.2756, height: 841.8898, pages: 2 },
  { name: "presentation-deck", html: presentationDeckHtml, width: 841.8898, height: 595.2756, pages: 4 },
];

await mkdir(outputDir, { recursive: true });
const manifest = {
  profile: "document",
  version: "0.1.0-alpha.0",
  wasmBytes: wasm.length,
  fixtures: {},
};

for (const fixture of fixtures) {
  const input = encoder.encode(fixture.html);
  const pointer = api.alloc(input.length);
  if (pointer === 0) throw new Error(`allocation failed for ${fixture.name}`);
  let handle = 0;
  const memoryBefore = api.memory.buffer.byteLength;
  const started = performance.now();
  try {
    new Uint8Array(api.memory.buffer, pointer, input.length).set(input);
    handle = api.render_html_to_pdf_with_options(pointer, input.length, fixture.width, fixture.height, 36, 36, 36, 36);
    if (handle === 0 || api.pdf_result_status(handle) !== 0) throw new Error(`render failed for ${fixture.name}`);
    const pageCount = api.pdf_result_page_count(handle);
    if (pageCount !== fixture.pages) throw new Error(`${fixture.name}: expected ${fixture.pages} pages, got ${pageCount}`);
    const data = new Uint8Array(api.memory.buffer, api.pdf_result_data_ptr(handle), api.pdf_result_data_len(handle)).slice();
    const pdfPath = resolve(outputDir, `${fixture.name}.pdf`);
    await writeFile(pdfPath, data);
    await run("pdftoppm", ["-f", "1", "-singlefile", "-png", "-r", "96", pdfPath, resolve(outputDir, `${fixture.name}-page-1`)]);
    manifest.fixtures[fixture.name] = {
      pages: pageCount,
      pdfBytes: data.length,
      sha256: createHash("sha256").update(data).digest("hex"),
      renderMilliseconds: Number((performance.now() - started).toFixed(3)),
      wasmMemoryBytesBefore: memoryBefore,
      wasmMemoryBytesAfter: api.memory.buffer.byteLength,
      screenshot: `${fixture.name}-page-1.png`,
    };
  } finally {
    if (handle !== 0) api.pdf_result_free(handle);
    api.free(pointer, input.length);
  }
}

await writeFile(resolve(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Wrote ${Object.keys(manifest.fixtures).length} PDF and first-page PNG baselines to ${outputDir}`);

function run(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", (code) => code === 0
      ? resolvePromise()
      : reject(new Error(`${basename(command)} exited with ${code} while writing ${dirname(args.at(-1))}`)));
  });
}

