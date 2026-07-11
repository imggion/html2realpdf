import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const outputPath = resolve(process.argv[2] ?? "tmp/pdfs/html2realpdf-fixture.pdf");
const wasmPath = new URL("../bindings/js/dist/libhtml2realpdf.wasm", import.meta.url);
const wasm = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(wasm, {});
const exports = instance.exports;
const html = `
  <article style="font-family: Noto Sans; color: #172033">
    <h1 style="color: #1d4ed8">Real PDF preview</h1>
    <p>This text is selectable: caffè, naïve, €uro.</p>
    <p style="text-transform: uppercase">Unicode transform: straße.</p>
    <p lang="tr" style="text-transform: uppercase">Türkçe transform: iyi.</p>
    <p lang="el" style="text-transform: lowercase">Greek final sigma: ΟΣ.</p>
    <p><strong>Bold</strong>, <em>italic</em>, vector background and border.</p>
    <p><a href="https://example.com/docs">Real PDF link annotation</a></p>
  </article>
`;
const input = new TextEncoder().encode(html);
const options = new TextEncoder().encode(JSON.stringify({
  pageWidthPoints: 595.2756,
  pageHeightPoints: 841.8898,
  marginTopPoints: 36,
  marginRightPoints: 36,
  marginBottomPoints: 36,
  marginLeftPoints: 36,
  cssProfile: "web",
}));
const inputPointer = exports.alloc(input.length);
const optionsPointer = exports.alloc(options.length);
if (inputPointer === 0) throw new Error("Could not allocate the WASM input");
if (optionsPointer === 0) throw new Error("Could not allocate the WASM options");

let handle = 0;
try {
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  new Uint8Array(exports.memory.buffer, optionsPointer, options.length).set(options);
  handle = exports.render_html_to_pdf_with_json_options(inputPointer, input.length, optionsPointer, options.length);
  if (handle === 0 || exports.pdf_result_status(handle) !== 0) throw new Error("PDF rendering failed");
  const pointer = exports.pdf_result_data_ptr(handle);
  const length = exports.pdf_result_data_len(handle);
  const bytes = new Uint8Array(exports.memory.buffer, pointer, length).slice();
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, bytes);
  console.log(`${outputPath} (${length} bytes, ${exports.pdf_result_page_count(handle)} page)`);
} finally {
  if (handle !== 0) exports.pdf_result_free(handle);
  exports.free(inputPointer, input.length);
  exports.free(optionsPointer, options.length);
}
