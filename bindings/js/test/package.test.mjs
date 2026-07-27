import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import html2pdf, {
  CanvasToSvgError,
  CompatWorker,
  Html2RealPdfError,
  InvalidSourceError,
  PdfDocument,
  PdfPreview,
  ResourceLoadError,
  UnsupportedCompatibilityFeatureError,
  UnsupportedCssError,
  UnsupportedEnvironmentError,
  WasmRenderError,
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

test("public error names are stable", () => {
  const errors = [
    new Html2RealPdfError("base", "TEST_ERROR"),
    new UnsupportedEnvironmentError(),
    new InvalidSourceError("invalid"),
    new UnsupportedCssError("unsupported"),
    new WasmRenderError("render failed", -1),
    new ResourceLoadError("fixture.png"),
    new CanvasToSvgError("conversion failed", "body > canvas"),
    new UnsupportedCompatibilityFeatureError("toCanvas"),
  ];
  assert.deepEqual(errors.map((error) => error.name), [
    "Html2RealPdfError",
    "UnsupportedEnvironmentError",
    "InvalidSourceError",
    "UnsupportedCssError",
    "WasmRenderError",
    "ResourceLoadError",
    "CanvasToSvgError",
    "UnsupportedCompatibilityFeatureError",
  ]);
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

test("package carries consolidated project and third-party licenses", async () => {
  const license = await readFile(new URL("../dist/LICENSE.md", import.meta.url), "utf8");
  assert.match(license, /html2realpdf - MIT License/);
  assert.match(license, /Noto fonts - SIL Open Font License 1\.1/);
  assert.match(license, /HarfBuzz - Old MIT License/);
  assert.match(license, /SheenBidi and PDF\.js - Apache License 2\.0/);
  assert.match(license, /libunibreak - zlib License/);
  assert.match(license, /Unicode data files - Unicode License v3/);
  assert.match(license, /Adapted Web Platform Tests - BSD 3-Clause License/);
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
  const pdf = PdfDocument.create(new Uint8Array([1, 2, 3]), 1);
  const first = pdf.toUint8Array();
  first[0] = 9;
  assert.deepEqual([...pdf.toUint8Array()], [1, 2, 3]);
  assert.equal(pdf.toBlob().type, "application/pdf");
  pdf.dispose();
  assert.throws(() => pdf.toUint8Array(), /disposed/);
});

test("compat worker rejects raster-only options explicitly", () => {
  assert.throws(() => html2pdf().set({ image: { type: "jpeg" } }), UnsupportedCompatibilityFeatureError);
  assert.throws(() => html2pdf().set({ html2canvas: {} }), UnsupportedCompatibilityFeatureError);
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

test("packaged WASM rejects unsafe and unresolved PDF links", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const input = new TextEncoder().encode(`
    <a href="https://safe.example/report">safe</a>
    <a href="mailto:?subject=Report">mail query</a>
    <a href="/relative/report">relative</a>
    <a href="http://[]">malformed host</a>
    <a href="javascript:alert(1)">script</a>
    <a href="file:///etc/passwd">file</a>
  `);
  const inputPointer = exports.alloc(input.length);
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  const result = exports.render_html_to_pdf(inputPointer, input.length);

  try {
    assert.equal(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_data_ptr(result);
    const length = exports.pdf_result_data_len(result);
    const serialized = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(serialized, /https:\/\/safe\.example\/report/);
    assert.match(serialized, /mailto:\?subject=Report/);
    assert.doesNotMatch(serialized, /\/relative\/report|http:\/\/\[\]|javascript:alert|file:\/\/\/etc\/passwd/);
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

test("packaged WASM returns owned structured CSS diagnostics", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const input = new TextEncoder().encode('<p style="filter:blur(2px);color:red">diagnostic</p>');
  const inputPointer = exports.alloc(input.length);
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  const result = exports.render_html_to_pdf(inputPointer, input.length);

  try {
    assert.equal(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_diagnostics_ptr(result);
    const length = exports.pdf_result_diagnostics_len(result);
    const diagnostics = JSON.parse(new TextDecoder().decode(new Uint8Array(exports.memory.buffer, pointer, length)));
    assert.deepEqual(diagnostics, [{
      code: "UNSUPPORTED_CSS_PROPERTY",
      severity: "warning",
      message: "Unsupported CSS property was ignored: filter",
      property: "filter",
      phase: "computed",
    }]);
  } finally {
    exports.pdf_result_free(result);
    exports.free(inputPointer, input.length);
  }
});

test("packaged WASM strict profile rejects unsupported CSS", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const encoder = new TextEncoder();
  const input = encoder.encode('<p style="filter:blur(2px);color:red">strict</p>');
  const options = encoder.encode(JSON.stringify({
    pageWidthPoints: 595.2756,
    pageHeightPoints: 841.8898,
    cssProfile: "strict",
  }));
  const inputPointer = exports.alloc(input.length);
  const optionsPointer = exports.alloc(options.length);
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
  const result = exports.render_html_to_pdf_with_json_options(inputPointer, input.length, optionsPointer, options.length);

  try {
    assert.notEqual(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_error_ptr(result);
    const length = exports.pdf_result_error_len(result);
    const message = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(message, /UnsupportedCss/);
  } finally {
    exports.pdf_result_free(result);
    exports.free(inputPointer, input.length);
    exports.free(optionsPointer, options.length);
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

test("web profile shapes ligatures and built-in RTL script fallbacks in WASM", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const encoder = new TextEncoder();
  const html = encoder.encode("<p>office مرحبا שלום</p>");
  const options = encoder.encode(JSON.stringify({
    pageWidthPoints: 595.2756,
    pageHeightPoints: 841.8898,
    cssProfile: "web",
  }));
  const htmlPointer = exports.alloc(html.length);
  const optionsPointer = exports.alloc(options.length);
  let result = 0;
  try {
    new Uint8Array(exports.memory.buffer, htmlPointer, html.length).set(html);
    new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
    result = exports.render_html_to_pdf_with_json_options(htmlPointer, html.length, optionsPointer, options.length);
    assert.equal(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_data_ptr(result);
    const length = exports.pdf_result_data_len(result);
    const pdf = new TextDecoder("latin1").decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(pdf, /<\w{4}> <006600660069>/);
    assert.match(pdf, /HREALP\+NotoSansArabic-Regular/);
    assert.match(pdf, /HREALP\+NotoSansHebrew-Regular/);
  } finally {
    if (result !== 0) exports.pdf_result_free(result);
    exports.free(htmlPointer, html.length);
    exports.free(optionsPointer, options.length);
  }
});

test("WASM applies full and language-sensitive Unicode text transforms", async () => {
  const wasm = await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const encoder = new TextEncoder();
  const html = encoder.encode("<p lang='tr' style='text-transform:uppercase'>iyi</p><p style='text-transform:uppercase'>straße</p>");
  const options = encoder.encode(JSON.stringify({
    pageWidthPoints: 595.2756,
    pageHeightPoints: 841.8898,
    cssProfile: "web",
  }));
  const htmlPointer = exports.alloc(html.length);
  const optionsPointer = exports.alloc(options.length);
  let result = 0;
  try {
    new Uint8Array(exports.memory.buffer, htmlPointer, html.length).set(html);
    new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
    result = exports.render_html_to_pdf_with_json_options(htmlPointer, html.length, optionsPointer, options.length);
    assert.equal(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_data_ptr(result);
    const length = exports.pdf_result_data_len(result);
    const pdf = new TextDecoder("latin1").decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(pdf, /<\w{4}> <0130>/);
    assert.match(pdf, /<\w{4}> <0053>/);
  } finally {
    if (result !== 0) exports.pdf_result_free(result);
    exports.free(htmlPointer, html.length);
    exports.free(optionsPointer, options.length);
  }
});

test("registered fallback keeps emoji as selectable embedded text", async () => {
  const [wasm, emojiFont] = await Promise.all([
    readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url)),
    readFile(new URL("../../../tests/assets/fonts/Html2RealPdfEmojiFixture.ttf", import.meta.url)),
  ]);
  const { instance } = await WebAssembly.instantiate(wasm, {});
  const exports = instance.exports;
  const context = exports.pdf_context_create();
  const encoder = new TextEncoder();
  const family = encoder.encode("Emoji Fixture");
  const html = encoder.encode("<p style=\"font-family:'Noto Sans','Emoji Fixture'\">Rocket 🚀 ready</p>");
  const options = encoder.encode(JSON.stringify({
    pageWidthPoints: 595.2756,
    pageHeightPoints: 841.8898,
    cssProfile: "web",
  }));
  const familyPointer = exports.alloc(family.length);
  const fontPointer = exports.alloc(emojiFont.length);
  const htmlPointer = exports.alloc(html.length);
  const optionsPointer = exports.alloc(options.length);
  let result = 0;
  try {
    new Uint8Array(exports.memory.buffer, familyPointer, family.length).set(family);
    new Uint8Array(exports.memory.buffer, fontPointer, emojiFont.length).set(emojiFont);
    assert.equal(exports.pdf_context_register_font(context, familyPointer, family.length, fontPointer, emojiFont.length, 400, 0), 0);
    new Uint8Array(exports.memory.buffer, htmlPointer, html.length).set(html);
    new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
    result = exports.render_html_to_pdf_with_context_json_options(context, htmlPointer, html.length, optionsPointer, options.length);
    assert.equal(exports.pdf_result_status(result), 0);
    const pointer = exports.pdf_result_data_ptr(result);
    const length = exports.pdf_result_data_len(result);
    const pdf = new TextDecoder("latin1").decode(new Uint8Array(exports.memory.buffer, pointer, length));
    assert.match(pdf, /HREALP\+Emoji-Fixture/);
    assert.match(pdf, /<\w{4}> <D83DDE80>/);
  } finally {
    if (result !== 0) exports.pdf_result_free(result);
    exports.free(familyPointer, family.length);
    exports.free(fontPointer, emojiFont.length);
    exports.free(htmlPointer, html.length);
    exports.free(optionsPointer, options.length);
    exports.pdf_context_free(context);
  }
});
