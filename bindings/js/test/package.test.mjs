import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import html2pdf, {
  CompatWorker,
  PdfDocument,
  PdfPreview,
  UnsupportedCompatibilityFeatureError,
  createRenderer,
  renderPdf,
} from "../dist/index.js";
import { normalizePage } from "../dist/page.js";

test("package entrypoint is safe to import without a browser", () => {
  assert.equal(typeof html2pdf, "function");
  assert.equal(html2pdf.Worker, CompatWorker);
  assert.equal(typeof createRenderer, "function");
  assert.equal(typeof renderPdf, "function");
  assert.equal(typeof PdfPreview, "function");
});

test("browser harness runtime uses a content-addressed package build", async () => {
  const manifest = JSON.parse(await readFile(new URL("../.browser-build/manifest.json", import.meta.url), "utf8"));
  assert.match(manifest.buildId, /^[a-f0-9]{16}$/);
  assert.equal(manifest.entry, `${manifest.buildId}/index.js`);
  assert.equal(manifest.wasm, `${manifest.buildId}/libhtml2realpdf.wasm`);
  const runtime = await import(new URL(`../.browser-build/${manifest.entry}`, import.meta.url));
  assert.equal(typeof runtime.PdfDocument.prototype.preview, "function");
  assert.equal(typeof runtime.PdfPreview.prototype.dispose, "function");
});

test("page options normalize A4, Letter, orientation, units, and margins", () => {
  const a4 = normalizePage();
  assert.equal(a4.widthPoints, 595.2756);
  assert.equal(a4.heightPoints, 841.8898);

  const letter = normalizePage({ format: "letter", orientation: "landscape", unit: "in", margin: [0.5, 1] });
  assert.equal(letter.widthPoints, 792);
  assert.equal(letter.heightPoints, 612);
  assert.equal(letter.marginTopPoints, 36);
  assert.equal(letter.marginRightPoints, 72);
});

test("compat worker rejects raster-only stages explicitly", () => {
  const worker = html2pdf();
  assert.throws(() => worker.toCanvas(), UnsupportedCompatibilityFeatureError);
});

test("PdfDocument returns defensive byte copies", () => {
  const pdf = new PdfDocument(new Uint8Array([1, 2, 3]), 1);
  const first = pdf.toUint8Array();
  first[0] = 9;
  assert.deepEqual([...pdf.toUint8Array()], [1, 2, 3]);
  assert.equal(pdf.toBlob().type, "application/pdf");
  pdf.dispose();
  assert.throws(() => pdf.toUint8Array(), /disposed/);
});

test("packaged WASM renders a real PDF with a result handle", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  assert.equal(exports.html2realpdf_abi_version(), 1);
  const input = new TextEncoder().encode("<h1>Packaged PDF</h1><p>Selectable text</p>");
  const inputPointer = exports.alloc(input.length);
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  const result = exports.render_html_to_pdf_with_options(inputPointer, input.length, 612, 792, 36, 36, 36, 36);

  try {
    assert.equal(exports.pdf_result_status(result), 0);
    assert.equal(exports.pdf_result_page_count(result), 1);
    const pointer = exports.pdf_result_data_ptr(result);
    const length = exports.pdf_result_data_len(result);
    const bytes = new Uint8Array(exports.memory.buffer, pointer, length);
    assert.equal(new TextDecoder().decode(bytes.subarray(0, 8)), "%PDF-1.7");
  } finally {
    exports.pdf_result_free(result);
    exports.free(inputPointer, input.length);
  }
});

test("packaged WASM exposes structured render errors", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const input = new TextEncoder().encode("<p>invalid page</p>");
  const inputPointer = exports.alloc(input.length);
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  const result = exports.render_html_to_pdf_with_options(inputPointer, input.length, 10, 10, 6, 6, 6, 6);

  try {
    assert.equal(exports.pdf_result_status(result), -4);
    const pointer = exports.pdf_result_error_ptr(result);
    const length = exports.pdf_result_error_len(result);
    const message = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(message, /positive content area/);
  } finally {
    exports.pdf_result_free(result);
    exports.free(inputPointer, input.length);
  }
});

test("packaged WASM context registers and embeds a custom TrueType family", async () => {
  const [wasm, font] = await Promise.all([
    readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url)),
    readFile(new URL("../../../src/assets/fonts/NotoSans-Regular.ttf", import.meta.url)),
  ]);
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const context = exports.pdf_context_create();
  const encoder = new TextEncoder();
  const family = encoder.encode("Fixture Font");
  const html = encoder.encode("<p style=\"font-family:'Fixture Font'\">custom</p>");
  const options = encoder.encode(JSON.stringify({ pageWidthPoints: 595.2756, pageHeightPoints: 841.8898 }));
  const familyPointer = exports.alloc(family.length);
  const fontPointer = exports.alloc(font.length);
  const htmlPointer = exports.alloc(html.length);
  const optionsPointer = exports.alloc(options.length);

  try {
    new Uint8Array(exports.memory.buffer, familyPointer, family.length).set(family);
    new Uint8Array(exports.memory.buffer, fontPointer, font.length).set(font);
    assert.equal(exports.pdf_context_register_font(context, familyPointer, family.length, fontPointer, font.length, 400, 0), 0);
    new Uint8Array(exports.memory.buffer, htmlPointer, html.length).set(html);
    new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
    const result = exports.render_html_to_pdf_with_context_json_options(
      context,
      htmlPointer,
      html.length,
      optionsPointer,
      options.length,
    );
    try {
      assert.equal(exports.pdf_result_status(result), 0);
      const pointer = exports.pdf_result_data_ptr(result);
      const length = exports.pdf_result_data_len(result);
      const pdf = new TextDecoder("latin1").decode(new Uint8Array(exports.memory.buffer, pointer, length));
      assert.match(pdf, /HREALP\+Fixture-Font/);
    } finally {
      exports.pdf_result_free(result);
    }
  } finally {
    exports.free(familyPointer, family.length);
    exports.free(fontPointer, font.length);
    exports.free(htmlPointer, html.length);
    exports.free(optionsPointer, options.length);
    exports.pdf_context_free(context);
  }
});
