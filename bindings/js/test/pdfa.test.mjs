import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { inflateSync } from "node:zlib";
import { preparePdfExtras } from "../dist/attachments.js";
import { WasmBridge } from "../dist/wasm.js";
import { normalizePage } from "../dist/page.js";
import { createBridge } from "../../../tests/pdfa/helpers.mjs";
import { getDocument } from "../node_modules/pdfjs-dist/legacy/build/pdf.mjs";

test("PDF/A and attachments are deterministic, per-render, and preserve subarray ownership", async () => {
  const bridge = await createBridge();
  const bytes = new Uint8Array([99, 0, 255, 42, 88]);
  const extras = preparePdfExtras({ conformance: "pdfa-3u", attachments: [{ name: "dati-è.bin", data: bytes.subarray(1, 4) }] });
  try {
    const first = bridge.render("<p>office caffè</p>", normalizePage(), { title: "Fattura & <test>" }, "web", undefined, undefined, extras);
    const again = bridge.render("<p>office caffè</p>", normalizePage(), { title: "Fattura & <test>" }, "web", undefined, undefined, extras);
    assert.deepEqual(first.bytes, again.bytes);
    assert.deepEqual([...bytes], [99, 0, 255, 42, 88]);
    const text = Buffer.from(first.bytes).toString("latin1");
    assert.match(text, /pdfaid:conformance>U/);
    assert.match(text, /\/AFRelationship \/Unspecified/);
    assert.match(text, /\/Subtype \/application#2Foctet-stream/);
    assert.match(text, /\/ID \[<([A-F0-9]{32})> <\1>\]/);
    assert.doesNotMatch(text, /\/Params/);
    assert.ok(Buffer.from(first.bytes).includes(Buffer.from([0, 255, 42])));
    const plain = bridge.render("<p>ordinary</p>", normalizePage());
    assert.doesNotMatch(Buffer.from(plain.bytes).toString("latin1"), /pdfaid:|\/EmbeddedFile|\/AF \[/);
    const attachedPlain = bridge.render("<p>ordinary</p>", normalizePage(), undefined, "document", undefined, undefined, preparePdfExtras({ attachments: [{ name: "a", data: new Uint8Array(), modifiedAt: new Date("2024-02-29T12:34:56Z") }] }));
    const attachedText = Buffer.from(attachedPlain.bytes).toString("latin1");
    assert.match(attachedText, /\/Size 0 \/ModDate \(D:20240229123456Z\)/);
    assert.doesNotMatch(attachedText, /pdfaid:/);
  } finally { bridge.dispose(); }
});

test("attachment options reject invalid data before transferring caller buffers", () => {
  const base = { name: "a", data: new Uint8Array() };
  for (const patch of [{ name: " " }, { name: "\ud800" }, { data: "text" }, { mimeType: "text/plain; charset=utf8" }, { mimeType: "x/y/z" }, { relationship: "Unknown" }, { modifiedAt: new Date(NaN) }, { modifiedAt: new Date("+010000-01-01") }]) {
    assert.throws(() => preparePdfExtras({ attachments: [{ ...base, ...patch }] }));
  }
  assert.throws(() => preparePdfExtras({ attachments: [base, base] }), /Duplicate/);
  assert.throws(() => preparePdfExtras({ conformance: "pdfa-1b" }), /conformance/);
});

test("WASM ABI 2 rejects overflowing attachment ranges and survives subsequent renders", async () => {
  const { instance: { exports: wasm } } = await WebAssembly.instantiate(await readFile(new URL("../dist/libhtml2realpdf.wasm", import.meta.url)), {});
  const encode = (value) => {
    const data = new TextEncoder().encode(value);
    const pointer = wasm.alloc(data.length);
    new Uint8Array(wasm.memory.buffer, pointer, data.length).set(data);
    return [pointer, data.length];
  };
  const html = encode("<p>safe</p>");
  for (const descriptor of [{ dataPointer: 0xfffffff0, dataLength: 256 }, { dataPointer: 0, dataLength: 1 }, { dataPointer: 1, dataLength: 0xffffffff }]) {
    const options = encode(JSON.stringify({ pageWidthPoints: 595, pageHeightPoints: 842, conformance: "pdfa-3u", attachments: [{ name: "a", ...descriptor }] }));
    const handle = wasm.render_html_to_pdf_with_json_options(...html, ...options);
    assert.notEqual(wasm.pdf_result_status(handle), 0);
    wasm.pdf_result_free(handle);
    wasm.free(...options);
  }
  const handle = wasm.render_html_to_pdf(...html);
  assert.equal(wasm.pdf_result_status(handle), 0);
  wasm.pdf_result_free(handle);
  wasm.free(...html);
});

test("stale ABI is rejected before a render can silently ignore PDF/A", async () => {
  const original = WebAssembly.instantiateStreaming;
  WebAssembly.instantiateStreaming = async () => ({ instance: { exports: { html2realpdf_abi_version: () => 1 } } });
  try { await assert.rejects(WasmBridge.create("data:application/wasm;base64,AA=="), /expected 2/); }
  finally { WebAssembly.instantiateStreaming = original; }
});

test("PDF/A completes combining-cluster mappings and rejects non-splittable limits", async () => {
  const bridge = await createBridge();
  const extras = preparePdfExtras({ conformance: "pdfa-3u" });
  try {
    const result = bridge.render("<p>q\u0301 office مرحبا שלום</p>", normalizePage(), undefined, "web", undefined, undefined, extras);
    assert.doesNotMatch(Buffer.from(result.bytes).toString("latin1"), /<[A-F0-9]{4}> <>/);
    const adjacent = bridge.render("<p><span>a</span><span>q\u0301</span></p>", normalizePage(), undefined, "web", undefined, undefined, extras);
    const document = await getDocument({ data: adjacent.bytes }).promise;
    try {
      const text = (await (await document.getPage(1)).getTextContent()).items.map((item) => item.str).join("").replace(/\s/g, "");
      assert.equal(text, "aq́", "A merged simple run must not consume the complex run's ActualText");
    } finally { await document.destroy(); }
    assert.throws(() => bridge.render("<p>a</p>", { ...normalizePage(), widthPoints: 15000 }, undefined, "document", undefined, undefined, extras), /PdfaInvalidPageSize/);
    assert.throws(() => bridge.render("<p>a</p>", normalizePage(), { title: "x".repeat(16383) }, "document", undefined, undefined, extras), /PdfaStringTooLong/);
    assert.throws(() => bridge.render("<p>\u0378</p>", normalizePage(), undefined, "web", undefined, undefined, extras), /MissingGlyph/);
    assert.throws(() => bridge.render("<p>a</p>", normalizePage({ margin: 36, unit: "pt" }), undefined, "web", [{ name: "bottom_center", content: "\u0378" }], undefined, extras), /MissingGlyph/);
  } finally { bridge.dispose(); }
});

test("font no-subsetting permission embeds complete bytes and bitmap-only embedding fails", async () => {
  const data = new Uint8Array(await readFile(new URL("../../../src/assets/fonts/NotoSans-Regular.ttf", import.meta.url)));
  const view = new DataView(data.buffer);
  let os2;
  for (let i = 0; i < view.getUint16(4); i++) {
    const start = 12 + i * 16;
    if (new TextDecoder().decode(data.subarray(start, start + 4)) === "OS/2") os2 = view.getUint32(start + 8);
  }
  view.setUint16(os2 + 8, 0x0100);
  const bridge = await createBridge([{ family: "Whole", data }]);
  try {
    const result = bridge.render("<p style='font-family:Whole'>Font</p>", normalizePage(), undefined, "web", undefined, undefined, preparePdfExtras({ conformance: "pdfa-3u" }));
    const bytes = Buffer.from(result.bytes);
    const text = bytes.toString("latin1");
    const match = /\/Length (\d+) \/Length1 (\d+) \/Filter \/FlateDecode >>\nstream\n/.exec(text);
    assert.equal(Number(match[2]), data.length);
    const start = match.index + match[0].length;
    assert.deepEqual(inflateSync(bytes.subarray(start, start + Number(match[1]))), Buffer.from(data));
    assert.doesNotMatch(text, /[A-Z]{6}\+Whole/);
  } finally { bridge.dispose(); }
  view.setUint16(os2 + 8, 0x0200);
  await assert.rejects(createBridge([{ family: "Bitmap", data }]), /registration failed/);
});


test("PDF/A rejects CMYK JPEG and SVG missing glyphs without ordinary fallback", async () => {
  const bridge = await createBridge();
  const extras = preparePdfExtras({ conformance: "pdfa-3u" });
  const jpeg = Buffer.from([255,216,255,192,0,11,8,0,2,0,3,4,1,17,0]);
  const svg = `<svg viewBox="0 0 100 30"><text x="0" y="20">\u0378</text></svg>`;
  try {
    assert.throws(() => bridge.render(`<img src="data:image/jpeg;base64,${jpeg.toString("base64")}" width="3" height="2">`, normalizePage(), undefined, "web", undefined, undefined, extras), /PdfaCmykImage/);
    assert.throws(() => bridge.render(`<img src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}" width="100" height="30">`, normalizePage(), undefined, "web", undefined, undefined, extras), /MissingGlyph/);
  } finally { bridge.dispose(); }
});

test("bridge frees binary allocations after native, JSON and allocation failures", async () => {
  const bridge = await createBridge();
  const original = bridge.exports;
  const live = new Set();
  let allocations = 0;
  let failAt = Infinity;
  bridge.exports = {
    ...original,
    alloc(length) {
      if (++allocations === failAt) return 0;
      const pointer = original.alloc(length);
      live.add(pointer);
      return pointer;
    },
    free(pointer, length) {
      live.delete(pointer);
      original.free(pointer, length);
    },
  };
  const extras = preparePdfExtras({ conformance: "pdfa-3u", attachments: [{ name: "a.bin", data: new Uint8Array([1, 2, 3]) }] });
  try {
    assert.throws(() => bridge.render("<p>\u0378</p>", normalizePage(), undefined, "web", undefined, undefined, extras), /MissingGlyph/);
    assert.equal(live.size, 0);
    const metadata = {};
    metadata.title = metadata;
    assert.throws(() => bridge.render("<p>a</p>", normalizePage(), metadata, "web", undefined, undefined, extras), /circular/i);
    assert.equal(live.size, 0);
    failAt = allocations + 2;
    assert.throws(() => bridge.render("<p>a</p>", normalizePage(), undefined, "web", undefined, undefined, extras), /allocation failed/);
    assert.equal(live.size, 0);
    failAt = Infinity;
    assert.equal(bridge.render("<p>After failure</p>", normalizePage()).pageCount, 1);
    assert.equal(live.size, 0);
  } finally { bridge.dispose(); }
});
