import { readFileSync, writeFileSync } from "fs";

const WASM_PATH = "zig-out/bin/libhtml2realpdf.wasm";
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
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const { alloc, free, memory, tokenize_html, dom_tree_html, dom_tree_output_len, box_tree_html, box_tree_output_len, cascade_tree_html, cascade_tree_output_len } = instance.exports;

function stringToWasm(str) {
  const bytes = encoder.encode(str);
  const ptr = alloc(bytes.length);
  if (ptr === 0) throw new Error("alloc failed");
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function runPipeline(fn, html) {
  const [ptr, len] = stringToWasm(html);
  try {
    const outPtr = fn(ptr, len);
    const outLen = dom_tree_output_len();
    const bytes = new Uint8Array(memory.buffer, outPtr, outLen);
    const str = decoder.decode(bytes);
    free(outPtr, outLen);
    return str;
  } finally {
    free(ptr, len);
  }
}

const snapshots = {};

// tokenize returns a number, not a string
{
  const [ptr, len] = stringToWasm(htmlHard);
  snapshots["tokenize_htmlHard"] = String(tokenize_html(ptr, len));
  free(ptr, len);
}

snapshots["dom_htmlWithStyles"] = runPipeline(dom_tree_html, htmlWithStyles);
snapshots["box_htmlWithStyles"] = runPipeline(box_tree_html, htmlWithStyles);
snapshots["cascade_htmlWithStyles"] = runPipeline(cascade_tree_html, htmlWithStyles);
snapshots["box_htmlInvoiceTable"] = runPipeline(box_tree_html, htmlInvoiceTable);
snapshots["cascade_htmlInvoiceTable"] = runPipeline(cascade_tree_html, htmlInvoiceTable);
snapshots["box_htmlAnonRow"] = runPipeline(box_tree_html, htmlAnonRow);
snapshots["box_htmlInlineBlock"] = runPipeline(box_tree_html, htmlInlineBlock);

writeFileSync("tests/web/snapshots.json", JSON.stringify(snapshots, null, 2));
console.log("Snapshots written to tests/web/snapshots.json");
