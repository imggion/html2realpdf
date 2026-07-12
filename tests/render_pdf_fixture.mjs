import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const outputPath = resolve(process.argv[2] ?? "tmp/pdfs/html2realpdf-fixture.pdf");
const wasmPath = new URL("../bindings/js/dist/libhtml2realpdf.wasm", import.meta.url);
const wasm = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(wasm, {});
const exports = instance.exports;
const html = `
  <article style="font-family: Noto Sans; color: #172033">
    <div style="position: fixed; left: 0; right: 0; top: 0; height: 8px; z-index: 50; background: #0f172a; opacity: .9"></div>
    <h1 style="color: #1d4ed8">Real PDF preview</h1>
    <p>This text is selectable: caffè, naïve, €uro.</p>
    <p style="text-transform: uppercase">Unicode transform: straße.</p>
    <p lang="tr" style="text-transform: uppercase">Türkçe transform: iyi.</p>
    <p lang="el" style="text-transform: lowercase">Greek final sigma: ΟΣ.</p>
    <p><strong>Bold</strong>, <em>italic</em>, vector background and border.</p>
    <p><a href="https://example.com/docs">Real PDF link annotation</a></p>
    <section style="width: 320px; padding: 12px; background: #f1f5f9">
      <div style="width: min-content; margin-bottom: 8px; padding: 6px; background: #fee2e2">alpha longestword beta</div>
      <div style="width: max-content; margin-bottom: 8px; padding: 6px; background: #dcfce7">alpha longestword beta</div>
      <div style="width: fit-content(140px); padding: 6px; background: #dbeafe">alpha longestword beta</div>
    </section>
    <table style="width: 400px; margin-top: 18px; border: 1px solid #334155; border-collapse: collapse">
      <caption style="padding: 6px; background: #e0e7ff; font-weight: bold">Intrinsic table tracks</caption>
      <colgroup><col style="width: 80px"><col style="width: 200px"><col style="width: 120px"></colgroup>
      <tr><th style="border: 1px solid #64748b; padding: 6px">Qty</th><th style="border: 1px solid #64748b; padding: 6px">Description</th><th style="border: 1px solid #64748b; padding: 6px">Total</th></tr>
      <tr><td rowspan="2" style="border: 1px solid #64748b; padding: 6px; vertical-align: middle">2</td><td style="border: 1px solid #64748b; padding: 6px">Layout engine</td><td style="border: 1px solid #64748b; padding: 6px">EUR 240</td></tr>
      <tr><td style="border: 1px solid #64748b; padding: 6px">Selectable PDF text</td><td style="border: 1px solid #64748b; padding: 6px">Included</td></tr>
      <caption style="caption-side: bottom; padding: 5px; color: #475569">Caption below the grid</caption>
    </table>
    <section style="width: 400px; margin-top: 16px; padding: 8px; border: 1px solid #94a3b8">
      <div style="box-sizing: border-box; width: 128px; aspect-ratio: 16/9; margin-bottom: 8px; padding: 8px; background: #fef3c7">16 / 9 card</div>
      <div style="float: left; width: 72px; height: 54px; margin-right: 10px; padding: 6px; background: #fee2e2">Left float</div>
      <div style="float: right; width: 66px; height: 42px; margin-left: 10px; padding: 6px; background: #dcfce7">Right float</div>
      <p style="margin: 0">Text occupies the live band between both floats while remaining native selectable PDF text.</p>
      <p style="clear: both; margin: 8px 0 0; padding: 4px; background: #f1f5f9">Cleared below both floats</p>
    </section>
    <section style="width: 400px; margin-top: 16px; padding: 8px; background: #f8fafc">
      <ol reversed start="5" style="margin: 0 0 8px; list-style: inside upper-roman">
        <li>Inside Roman five</li><li value="2">Explicit Roman two</li><li>Roman one</li>
      </ol>
      <ul style="margin: 0; list-style-type: square"><li>Outside square marker remains native text</li></ul>
    </section>
    <section style="page-break-before: always; width: 600px; margin-top: 18px; padding: 12px; background: #eff6ff">
      <div style="display: flex; height: 54px; align-items: center; padding: 0 12px; background: #1e3a8a; color: white">
        <strong>Flex dashboard</strong>
        <span style="margin-left: auto; padding: 6px 10px; background: #2563eb">Live vector KPI</span>
      </div>
      <div style="display: flex; flex-wrap: wrap; gap: 12px; margin-top: 12px">
        <div style="flex: 1 1 170px; min-width: 150px; height: 72px; padding: 10px; background: #dbeafe"><strong>Revenue</strong><br>EUR 128k</div>
        <div style="flex: 1 1 170px; min-width: 150px; height: 72px; padding: 10px; background: #dcfce7"><strong>Conversion</strong><br>8.4%</div>
        <div style="flex: 1 1 170px; min-width: 150px; height: 72px; padding: 10px; background: #fef3c7"><strong>Active users</strong><br>4,812</div>
        <div style="flex: 1 1 170px; min-width: 150px; height: 72px; padding: 10px; background: #fae8ff"><strong>Retention</strong><br>91%</div>
      </div>
    </section>
    <section style="page-break-before: always; position: relative; width: 540px; height: 240px; padding: 20px; background: #f8fafc">
      <h2 style="margin: 0; color: #0f172a">Positioned dashboard overlay</h2>
      <div style="position: relative; left: 14px; top: 9px; width: 180px; height: 44px; padding: 10px; background: #dbeafe">Relative card, normal flow preserved</div>
      <div style="position: absolute; right: 20px; top: 20px; width: 160px; height: 54px; padding: 10px; z-index: 2; background: #fef3c7">Absolute KPI badge</div>
      <div style="position: absolute; left: 240px; top: 110px; width: 170px; height: 72px; overflow: hidden; background: #e2e8f0">
        <div style="position: absolute; left: 110px; top: 12px; width: 100px; height: 48px; background: #16a34a"></div>
      </div>
      <div style="position: absolute; left: 40px; top: 135px; width: 145px; height: 70px; z-index: 1; background: #ea580c"></div>
      <div style="position: absolute; left: 70px; top: 150px; width: 145px; height: 70px; z-index: 3; opacity: .55; background: #2563eb"></div>
    </section>
    <section style="page-break-before: always; display: grid; width: 600px; grid-template-columns: repeat(3, minmax(0, 1fr)); grid-template-rows: 72px 110px; grid-template-areas: &quot;hero hero aside&quot; &quot;revenue users aside&quot;; gap: 14px; padding: 14px; background: #f8fafc">
      <div style="grid-area: hero; padding: 14px; background: #1e3a8a; color: white"><strong>Native CSS Grid dashboard</strong><br>Explicit named areas and flexible tracks</div>
      <div style="grid-area: revenue; padding: 14px; background: #dbeafe"><strong>Revenue</strong><br>EUR 128k</div>
      <div style="grid-area: users; padding: 14px; background: #dcfce7"><strong>Active users</strong><br>4,812</div>
      <div style="display: grid; grid-area: aside; grid-template-rows: 1fr 1fr; gap: 8px; padding: 10px; background: #fef3c7">
        <div style="padding: 10px; background: #fde68a"><strong>Nested Grid</strong></div>
        <div style="padding: 10px; background: #facc15">Vector cells</div>
      </div>
    </section>
    <section style="box-decoration-break: clone; width: 400px; height: 820px; margin-top: 18px; padding: 12px; border: 5px solid #7c3aed; border-radius: 10px; background: #f5f3ff">
      <h2 style="margin-top: 0; color: #6d28d9">Cloned page decoration</h2>
      <p>This tall native box crosses a page boundary. Its purple border and rounded corners must be painted on both fragments.</p>
    </section>
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
