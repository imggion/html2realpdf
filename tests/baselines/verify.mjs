import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import {
  analyticsReportHtml,
  complexInvoiceHtml,
  presentationDeckHtml,
  roundedOperationsReportHtml,
} from "../web/pdf-fixtures.js";

const root = resolve(import.meta.dirname, "../..");
const baselineDir = resolve(import.meta.dirname, "0.1.0-alpha.0");
const manifest = JSON.parse(await readFile(resolve(baselineDir, "manifest.json"), "utf8"));
const wasm = await readFile(resolve(root, "bindings/js/dist/libhtml2realpdf.wasm"));
const { instance } = await WebAssembly.instantiate(wasm, {});
const api = instance.exports;
const encoder = new TextEncoder();
const fixtures = {
  "complex-invoice": { html: complexInvoiceHtml, width: 595.2756, height: 841.8898 },
  "analytics-report": { html: analyticsReportHtml, width: 595.2756, height: 841.8898 },
  "rounded-operations": { html: roundedOperationsReportHtml, width: 595.2756, height: 841.8898 },
  "presentation-deck": { html: presentationDeckHtml, width: 841.8898, height: 595.2756 },
};

for (const [name, fixture] of Object.entries(fixtures)) {
  const input = encoder.encode(fixture.html);
  const pointer = api.alloc(input.length);
  let handle = 0;
  try {
    new Uint8Array(api.memory.buffer, pointer, input.length).set(input);
    handle = api.render_html_to_pdf_with_options(pointer, input.length, fixture.width, fixture.height, 36, 36, 36, 36);
    assert.notEqual(handle, 0, `${name}: result handle`);
    assert.equal(api.pdf_result_status(handle), 0, `${name}: render status`);
    assert.equal(api.pdf_result_page_count(handle), manifest.fixtures[name].pages, `${name}: page count`);
    const data = new Uint8Array(api.memory.buffer, api.pdf_result_data_ptr(handle), api.pdf_result_data_len(handle));
    assert.equal(createHash("sha256").update(data).digest("hex"), manifest.fixtures[name].sha256, `${name}: PDF digest`);
  } finally {
    if (handle !== 0) api.pdf_result_free(handle);
    api.free(pointer, input.length);
  }
  console.log(`PASS: ${name}`);
}

