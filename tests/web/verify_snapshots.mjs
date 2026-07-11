import { readFileSync } from "fs";

const WASM_PATH = "zig-out/bin/libhtml2realpdf.wasm";
const SNAPSHOTS_PATH = "tests/web/snapshots.json";

// Replicate the same HTML inputs and WASM glue from test.js
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const htmlHard = ` <!DOCTYPE html>
 <html lang="it">
 <head>
     <meta charset="UTF-8">
     <title>Test Tokenizer</title>
 </head>
 <body>
      <!-- This is a comment -->
      <h1 class="title" id="main-title">Main Title</h1>

      <div class="container" data-info="example">
          <p>Paragraph with <strong>bold text</strong> and <em>italic</em>.</p>

          <table border="1">
              <tr>
                  <th>Name</th>
                  <th>Age</th>
              </tr>
              <tr>
                  <td>Mario</td>
                  <td>25</td>
              </tr>
              <tr>
                  <td>Luigi</td>
                  <td>30</td>
              </tr>
          </table>

          <img src="/image.jpg" alt="Image" width="100" height="auto">
          <br/>
          <input type="text" name="username" placeholder="Enter name">
      </div>

     <footer>
         <p>Footer &copy; 2024</p>
     </footer>
 </body>
 </html>`;

const htmlWithStyles = `<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <title>DOM con CSS</title>
  <style>
    body > main { font-family: serif; color: #222; }
    .invoice-title { color: #1d4ed8; margin-bottom: 12px; }
    #total { font-weight: bold; border-top: 1px solid #111; }
    .note::before { content: "<nota> "; }
  </style>
</head>
<body>
  <main class="invoice">
    <h1 class="invoice-title">Invoice demo</h1>
    <p class="note">This text verifies style raw text and DOM tree.</p>
    <table>
      <tr><th>Item</th><th>Price</th></tr>
      <tr><td>Consulting</td><td>100</td></tr>
      <tr id="total"><td>Total</td><td>100</td></tr>
    </table>
  </main>
</body>
</html>`;

const htmlInvoiceTable = `<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <style>
    body { font-family: sans-serif; }
    .invoice { width: 600px; }
    .invoice-title { font-size: 24px; color: #1d4ed8; text-align: center; }
    .invoice-table { border: 1px solid #333; width: 100%; }
    .invoice-table th { border-bottom: 2px solid #333; text-align: left; }
    .invoice-table td { border-bottom-style: dashed; }
    .invoice-table td { border-bottom-color: #ccc; }
    #total td { border-top-style: solid; page-break-before: avoid; }
    .footer { text-align: right; orphans: 3; }
  </style>
</head>
<body class="invoice">
  <h1 class="invoice-title">INVOICE</h1>
  <table class="invoice-table">
    <tr><th>Item</th><th>Price</th></tr>
    <tr><td>Consulting</td><td>$100</td></tr>
    <tr><td>Development</td><td>$250</td></tr>
    <tr id="total"><td><strong>Total</strong></td><td>$350</td></tr>
  </table>
  <p class="footer">Thank you for your business</p>
</body>
</html>`;

const htmlAnonRow = `<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <style>
    .bare-table { border: 1px solid red; }
    .bare-table td { border-style: dashed; }
  </style>
</head>
<body>
  <table class="bare-table">
    <td>cell without row</td>
  </table>
</body>
</html>`;

const htmlInlineBlock = `<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <style>
    .card { display: inline-block; width: 200px; border: 1px solid #ccc; padding: 10px; }
    .card-title { font-size: 16px; }
  </style>
</head>
<body>
  <div>
    <p>Before the cards</p>
    <span class="card">
      <span class="card-title">Card 1</span>
      <span>content</span>
    </span>
    <span class="card">
      <span class="card-title">Card 2</span>
      <span>content</span>
    </span>
    <p>After the cards</p>
  </div>
</body>
</html>`;

const wasmBytes = readFileSync(WASM_PATH);
const snapshots = JSON.parse(readFileSync(SNAPSHOTS_PATH, "utf-8"));

const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const {
  alloc,
  free,
  memory,
  tokenize_html,
  dom_tree_html,
  dom_tree_output_len,
  box_tree_html,
  box_tree_output_len,
  cascade_tree_html,
  cascade_tree_output_len,
  render_html_to_pdf,
  pdf_result_status,
  pdf_result_data_ptr,
  pdf_result_data_len,
  pdf_result_page_count,
  pdf_result_free,
} = instance.exports;

function stringToWasm(str) {
  const bytes = encoder.encode(str);
  const ptr = alloc(bytes.length);
  if (ptr === 0) throw new Error("alloc failed");
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function runStringPipeline(fn, outputLength, html) {
  const [ptr, len] = stringToWasm(html);
  try {
    const outPtr = fn(ptr, len);
    const outLen = outputLength();
    const bytes = new Uint8Array(memory.buffer, outPtr, outLen);
    const str = decoder.decode(bytes);
    free(outPtr, outLen);
    return str;
  } finally {
    free(ptr, len);
  }
}

const testCases = [
  { name: "tokenize_htmlHard", html: htmlHard, pipeline: "tokenize" },
  { name: "dom_htmlWithStyles", html: htmlWithStyles, pipeline: "dom" },
  { name: "box_htmlWithStyles", html: htmlWithStyles, pipeline: "box" },
  { name: "cascade_htmlWithStyles", html: htmlWithStyles, pipeline: "cascade" },
  { name: "box_htmlInvoiceTable", html: htmlInvoiceTable, pipeline: "box" },
  { name: "cascade_htmlInvoiceTable", html: htmlInvoiceTable, pipeline: "cascade" },
  { name: "box_htmlAnonRow", html: htmlAnonRow, pipeline: "box" },
  { name: "box_htmlInlineBlock", html: htmlInlineBlock, pipeline: "box" },
];

let passed = 0;
let failed = 0;

for (const test of testCases) {
  const expected = snapshots[test.name];
  if (expected === undefined) {
    console.log(`SKIP: ${test.name} — no snapshot`);
    continue;
  }

  let actual;
  switch (test.pipeline) {
    case "tokenize": {
      const [ptr, len] = stringToWasm(test.html);
      actual = String(tokenize_html(ptr, len));
      free(ptr, len);
      break;
    }
    case "dom":
      actual = runStringPipeline(dom_tree_html, dom_tree_output_len, test.html);
      break;
    case "box":
      actual = runStringPipeline(box_tree_html, box_tree_output_len, test.html);
      break;
    case "cascade":
      actual = runStringPipeline(cascade_tree_html, cascade_tree_output_len, test.html);
      break;
  }

  if (actual === expected) {
    passed++;
    console.log(`PASS: ${test.name}`);
  } else {
    failed++;
    console.log(`FAIL: ${test.name}`);

    const expLines = expected.split("\n");
    const actLines = actual.split("\n");
    const maxLen = Math.max(expLines.length, actLines.length);
    let diffsShown = 0;
    for (let i = 0; i < maxLen && diffsShown < 5; i++) {
      const exp = i < expLines.length ? expLines[i] : "(missing)";
      const act = i < actLines.length ? actLines[i] : "(missing)";
      if (exp !== act) {
        console.log(`  line ${i + 1}:`);
        console.log(`    expected: ${JSON.stringify(exp)}`);
        console.log(`    actual:   ${JSON.stringify(act)}`);
        diffsShown++;
      }
    }
    if (diffsShown === 0 && expLines.length !== actLines.length) {
      console.log(`  Length mismatch: expected ${expLines.length} lines, got ${actLines.length}`);
    }
  }
}

{
  const [ptr, len] = stringToWasm(htmlInvoiceTable);
  let result = 0;
  try {
    result = render_html_to_pdf(ptr, len);
    if (result === 0) throw new Error("render_html_to_pdf returned no result");
    if (pdf_result_status(result) !== 0) throw new Error(`PDF status ${pdf_result_status(result)}`);

    const dataPtr = pdf_result_data_ptr(result);
    const dataLen = pdf_result_data_len(result);
    const bytes = new Uint8Array(memory.buffer, dataPtr, dataLen).slice();
    const pdfText = decoder.decode(bytes);

    if (!pdfText.startsWith("%PDF-1.7") || !pdfText.endsWith("%%EOF\n")) {
      throw new Error("invalid PDF header or trailer");
    }
    if (pdfText.includes("/Subtype /Image")) {
      throw new Error("document was flattened into a full-page image");
    }
    if (pdf_result_page_count(result) < 1) throw new Error("invalid PDF page count");

    passed++;
    console.log(`PASS: real_pdf (${dataLen} bytes, ${pdf_result_page_count(result)} page(s))`);
  } catch (error) {
    failed++;
    console.log(`FAIL: real_pdf — ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    if (result !== 0) pdf_result_free(result);
    free(ptr, len);
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
