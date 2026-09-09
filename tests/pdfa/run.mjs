import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { createBridge, materializeFixtureSvg } from "./helpers.mjs";
import { validateFiles } from "./verapdf.mjs";
import { preparePdfExtras } from "../../bindings/js/dist/attachments.js";
import { normalizePage } from "../../bindings/js/dist/page.js";
import { complexInvoiceHtml, analyticsReportHtml, presentationDeckHtml } from "../web/pdf-fixtures.js";
import { getDocument } from "../../bindings/js/node_modules/pdfjs-dist/legacy/build/pdf.mjs";

await mkdir("tmp/pdfa", { recursive: true });
const emoji = new Uint8Array(await readFile("tests/assets/fonts/Html2RealPdfEmojiFixture.ttf"));
const bridge = await createBridge([{ family: "Emoji Fixture", data: emoji }]);
const xml = new TextEncoder().encode('<invoice id="42">caffè</invoice>');
const binary = Uint8Array.from({ length: 4096 }, (_, i) => i % 256);
const attachments = [{ name: "fattura-è.xml", data: xml, mimeType: "application/xml", relationship: "Data", description: "Dati originali" }, { name: "binary.bin", data: binary, modifiedAt: new Date("2026-01-01T12:34:56Z") }];
const svg = `<svg viewBox="0 0 500 120"><defs><linearGradient id="g"><stop offset="0" stop-color="#1260aa"/><stop offset="1" stop-color="#aaffee"/></linearGradient><clipPath id="c"><rect width="490" height="115" rx="15"/></clipPath></defs><g clip-path="url(#c)"><rect width="500" height="120" fill="url(#g)"/><text x="20" y="50" font-size="20">SVG office q́ caffè</text></g></svg>`;
const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X1y8WQAAAABJRU5ErkJggg==";
const unicode = `<h1>Unicode archive</h1><img src="${png}" width="40" height="40"><p>office affinity caffè q́ á</p><p style="direction:rtl">مرحبا بالعالم</p><p style="direction:rtl">שלום עולם</p><p style="font-family:'Emoji Fixture'">😀</p><img style="width:500px;height:120px" src="data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}"><div style="opacity:.65;background:#bbccff;padding:10px">Transparent <strong>vector text</strong></div>`;
const cases = [
  { name: "invoice", html: complexInvoiceHtml, attachments: [attachments[0]] },
  { name: "report", html: analyticsReportHtml, attachments: [] },
  { name: "landscape", html: presentationDeckHtml, attachments, landscape: true },
  { name: "unicode", html: unicode, attachments },
];
const files = [resolve("tmp/pdfa/native-shaping.pdf")];
try {
  for (const fixture of cases) {
    const page = normalizePage({ format: "a4", orientation: fixture.landscape ? "landscape" : "portrait", margin: 32, unit: "pt" });
    const html = materializeFixtureSvg(fixture.html);
    const metadata = { title: `Archivio ${fixture.name}`, author: "Test & QA", subject: "PDF/A <3u>", keywords: ["archivio", "Unicode"], creator: "html2realpdf tests" };
    const marginBoxes = [{ name: "bottom_center", content: "Archivio office {{page}} / {{pages}}" }];
    const result = bridge.render(html, page, metadata, "web", marginBoxes, undefined, preparePdfExtras({ conformance: "pdfa-3u", attachments: fixture.attachments }));
    const path = resolve(`tmp/pdfa/${fixture.name}.pdf`);
    await writeFile(path, result.bytes);
    files.push(path);
    const plain = bridge.render(html, page, metadata, "web", marginBoxes);
    const plainPath = resolve(`tmp/pdfa/${fixture.name}-ordinary.pdf`);
    await writeFile(plainPath, plain.bytes);
    assert.equal(result.pageCount, plain.pageCount);
    const document = await getDocument({ data: result.bytes.slice(), useSystemFonts: false }).promise;
    try {
      assert.equal(document.numPages, result.pageCount);
      const embedded = Object.values(await document.getAttachments() ?? {});
      assert.equal(embedded.length, fixture.attachments.length);
      for (const original of fixture.attachments) {
        const retrieved = embedded.find((file) => file.filename === original.name);
        assert.ok(retrieved, original.name);
        assert.deepEqual(new Uint8Array(retrieved.content), original.data);
      }
      const text = (await (await document.getPage(1)).getTextContent()).items.map((item) => item.str).join(" ");
      assert.ok(text.length > 20, "PDF.js selectable text");
      if (fixture.name === "unicode") {
        for (const phrase of ["office", "caffè", "😀", "SVG"]) assert.ok(text.includes(phrase), `Missing PDF.js text: ${phrase}`);
        assert.equal((text.match(/q́/g) ?? []).length, 2, "ActualText must not duplicate combining clusters");
      }
    } finally { await document.destroy(); }
    const text = execFileSync("pdftotext", ["-enc", "UTF-8", path, "-"], { encoding: "utf8" });
    assert.ok(text.includes("Archivio"), "Poppler margin-box text");
    if (fixture.name === "unicode") for (const phrase of ["office", "caffè", "😀", "q́"]) assert.ok(text.includes(phrase), `Missing Poppler text: ${phrase}`);
    const fontReport = execFileSync("pdffonts", [path], { encoding: "utf8" });
    assert.ok(fontReport.includes("CID TrueType"));
    for (const line of fontReport.split("\n").slice(2).filter(Boolean)) assert.match(line, /yes\s+(yes|no)\s+yes\s+\d+\s+\d+\s*$/);
    // Pixel-identical first pages: PDF/A metadata and embedding must not move content.
    for (const [input, prefix] of [[path, `tmp/pdfa/${fixture.name}`], [plainPath, `tmp/pdfa/${fixture.name}-ordinary`]]) execFileSync("pdftoppm", ["-f", "1", "-singlefile", "-r", "72", input, prefix]);
    const archivalPixels = await readFile(`tmp/pdfa/${fixture.name}.ppm`);
    const ordinaryPixels = await readFile(`tmp/pdfa/${fixture.name}-ordinary.ppm`);
    assert.ok(archivalPixels.equals(ordinaryPixels), `${fixture.name} visual mismatch`);
    console.log(`${fixture.name}: ${result.pageCount} pages; text, fonts, attachments and pixels verified`);
  }
} finally { bridge.dispose(); }
// Exercise the full-embedding path against the external validator as well.
const fullFont = new Uint8Array(await readFile("src/assets/fonts/NotoSans-Regular.ttf"));
const fontView = new DataView(fullFont.buffer);
for (let i = 0; i < fontView.getUint16(4); i++) {
  const entry = 12 + i * 16;
  if (new TextDecoder().decode(fullFont.subarray(entry, entry + 4)) === "OS/2") fontView.setUint16(fontView.getUint32(entry + 8) + 8, 0x0100);
}
const fullBridge = await createBridge([{ family: "Full Font", data: fullFont }]);
try {
  const full = fullBridge.render("<p style='font-family:Full Font'>Full embedded font office</p>", normalizePage(), undefined, "web", undefined, undefined, { conformance: "pdfa-3u" });
  await writeFile("tmp/pdfa/full-font.pdf", full.bytes);
  files.push(resolve("tmp/pdfa/full-font.pdf"));
  const empty = fullBridge.render("", normalizePage(), undefined, "document", undefined, undefined, { conformance: "pdfa-3u" });
  await writeFile("tmp/pdfa/empty.pdf", empty.bytes);
  files.push(resolve("tmp/pdfa/empty.pdf"));
} finally { fullBridge.dispose(); }
const nativeText = execFileSync("pdftotext", ["tmp/pdfa/native-shaping.pdf", "-"], { encoding: "utf8" });
for (const text of ["office", "q́", "caffè", "Archivio"]) assert.ok(nativeText.includes(text), `Missing native text: ${text}`);
await validateFiles(files);
console.log(`veraPDF 1.30.2: all ${files.length} fixtures conform to PDF/A-3u`);
