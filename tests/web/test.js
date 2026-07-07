const WASM_URL = "../../zig-out/bin/html2realpdf.wasm";

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

const tokenizeButton = document.querySelector("#tokenize");
const domTreeButton = document.querySelector("#dom-tree");
const boxTreeButton = document.querySelector("#box-tree");
const cascadeTreeButton = document.querySelector("#cascade-tree");

const boxInvoiceButton = document.querySelector("#box-invoice");
const boxAnonRowButton = document.querySelector("#box-anon-row");
const boxInlineBlockButton = document.querySelector("#box-inline-block");
const cascadeInvoiceButton = document.querySelector("#cascade-invoice");

const output = document.querySelector("#output");
const encoder = new TextEncoder();
const decoder = new TextDecoder();
let wasmInstancePromise;

function showOutput(label, text) {
  output.textContent = `--- ${label} ---\n${text}`;
}

async function getWasmInstance() {
  wasmInstancePromise ??= fetch(WASM_URL, { cache: "no-store" }).then(async (response) => {
    if (!response.ok) {
      throw new Error(`Cannot load ${WASM_URL}: HTTP ${response.status}`);
    }

    const bytes = await response.arrayBuffer();
    return WebAssembly.instantiate(bytes, {});
  });

  const { instance } = await wasmInstancePromise;
  return instance;
}

function requireWasmExports(instance, names) {
  const missing = names.filter((name) => !instance.exports[name]);
  if (missing.length === 0) return;

  throw new Error(
    `Missing required wasm exports: ${missing.join(", ")}. Available: ${Object.keys(instance.exports)
      .sort()
      .join(", ")}`,
  );
}

function tokenizeHtml(instance, html) {
  const { alloc, free, memory, tokenize_html: tokenizeHtmlExport } = instance.exports;
  requireWasmExports(instance, ["alloc", "free", "memory", "tokenize_html"]);

  const bytes = encoder.encode(html);
  const ptr = alloc(bytes.length);
  if (ptr === 0) {
    throw new Error(`wasm alloc failed for ${bytes.length} bytes`);
  }

  try {
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    return tokenizeHtmlExport(ptr, bytes.length);
  } finally {
    free(ptr, bytes.length);
  }
}

function generateDomTree(instance, html) {
  const {
    alloc,
    free,
    memory,
    dom_tree_html: domTreeHtmlExport,
    dom_tree_output_len: domTreeOutputLenExport,
  } = instance.exports;

  requireWasmExports(instance, ["alloc", "free", "memory", "dom_tree_html", "dom_tree_output_len"]);

  const bytes = encoder.encode(html);
  const inputPtr = alloc(bytes.length);
  if (inputPtr === 0) {
    throw new Error(`wasm alloc failed for ${bytes.length} bytes`);
  }

  try {
    new Uint8Array(memory.buffer, inputPtr, bytes.length).set(bytes);

    const outputPtr = domTreeHtmlExport(inputPtr, bytes.length);
    const outputLen = domTreeOutputLenExport();
    if (outputPtr === 0 || outputLen === 0) {
      throw new Error("wasm DOM tree generation failed");
    }

    try {
      const outputBytes = new Uint8Array(memory.buffer, outputPtr, outputLen);
      return decoder.decode(outputBytes);
    } finally {
      free(outputPtr, outputLen);
    }
  } finally {
    free(inputPtr, bytes.length);
  }
}

function generateBoxTree(instance, html) {
  const {
    alloc,
    free,
    memory,
    box_tree_html: boxTreeHtmlExport,
    box_tree_output_len: boxTreeOutputLenExport,
  } = instance.exports;

  requireWasmExports(instance, ["alloc", "free", "memory", "box_tree_html", "box_tree_output_len"]);

  const bytes = encoder.encode(html);
  const inputPtr = alloc(bytes.length);
  if (inputPtr === 0) {
    throw new Error(`wasm alloc failed for ${bytes.length} bytes`);
  }

  try {
    new Uint8Array(memory.buffer, inputPtr, bytes.length).set(bytes);

    const outputPtr = boxTreeHtmlExport(inputPtr, bytes.length);
    const outputLen = boxTreeOutputLenExport();
    if (outputPtr === 0 || outputLen === 0) {
      throw new Error("wasm Box Tree generation failed");
    }

    try {
      const outputBytes = new Uint8Array(memory.buffer, outputPtr, outputLen);
      return decoder.decode(outputBytes);
    } finally {
      free(outputPtr, outputLen);
    }
  } finally {
    free(inputPtr, bytes.length);
  }
}

function generateCascadeTree(instance, html) {
  const {
    alloc,
    free,
    memory,
    cascade_tree_html: cascadeTreeHtmlExport,
    cascade_tree_output_len: cascadeTreeOutputLenExport,
  } = instance.exports;

  requireWasmExports(instance, ["alloc", "free", "memory", "cascade_tree_html", "cascade_tree_output_len"]);

  const bytes = encoder.encode(html);
  const inputPtr = alloc(bytes.length);
  if (inputPtr === 0) {
    throw new Error(`wasm alloc failed for ${bytes.length} bytes`);
  }

  try {
    new Uint8Array(memory.buffer, inputPtr, bytes.length).set(bytes);

    const outputPtr = cascadeTreeHtmlExport(inputPtr, bytes.length);
    const outputLen = cascadeTreeOutputLenExport();
    if (outputPtr === 0 || outputLen === 0) {
      throw new Error("wasm Cascade Tree generation failed");
    }

    try {
      const outputBytes = new Uint8Array(memory.buffer, outputPtr, outputLen);
      return decoder.decode(outputBytes);
    } finally {
      free(outputPtr, outputLen);
    }
  } finally {
    free(inputPtr, bytes.length);
  }
}

tokenizeButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const tokenCount = tokenizeHtml(instance, htmlHard);

    console.log("html_hard input:", htmlHard);
    console.log("wasm exports:", Object.keys(instance.exports));
    console.log("token count:", tokenCount);

    showOutput("tokenize", `Token count: ${tokenCount}`);
  } catch (error) {
    console.error("WASM tokenize failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

domTreeButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const domTree = generateDomTree(instance, htmlWithStyles);

    console.log("html_with_styles input:", htmlWithStyles);
    console.log("wasm exports:", Object.keys(instance.exports));
    console.log("DOM tree:\n", domTree);

    showOutput("DOM tree", domTree);
  } catch (error) {
    console.error("WASM DOM tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

boxTreeButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const boxTree = generateBoxTree(instance, htmlWithStyles);

    console.log("html_with_styles input:", htmlWithStyles);
    console.log("Box Tree:\n", boxTree);

    showOutput("Box Tree", boxTree);
  } catch (error) {
    console.error("WASM Box Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

cascadeTreeButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const cascadeTree = generateCascadeTree(instance, htmlWithStyles);

    console.log("html_with_styles input:", htmlWithStyles);
    console.log("Cascade Tree:\n", cascadeTree);

    showOutput("Cascade Tree", cascadeTree);
  } catch (error) {
    console.error("WASM Cascade Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

boxInvoiceButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const boxTree = generateBoxTree(instance, htmlInvoiceTable);

    console.log("Invoice table input:", htmlInvoiceTable);
    console.log("Box Tree:\n", boxTree);

    showOutput("Box Tree — invoice table", boxTree);
  } catch (error) {
    console.error("WASM Box Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

boxAnonRowButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const boxTree = generateBoxTree(instance, htmlAnonRow);

    console.log("Anonymous row input:", htmlAnonRow);
    console.log("Box Tree:\n", boxTree);

    showOutput("Box Tree — anonymous table-row", boxTree);
  } catch (error) {
    console.error("WASM Box Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

boxInlineBlockButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const boxTree = generateBoxTree(instance, htmlInlineBlock);

    console.log("Inline-block input:", htmlInlineBlock);
    console.log("Box Tree:\n", boxTree);

    showOutput("Box Tree — inline-block cards", boxTree);
  } catch (error) {
    console.error("WASM Box Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

cascadeInvoiceButton.addEventListener("click", async () => {
  output.textContent = "";

  try {
    const instance = await getWasmInstance();
    const cascadeTree = generateCascadeTree(instance, htmlInvoiceTable);

    console.log("Cascade invoice input:", htmlInvoiceTable);
    console.log("Cascade Tree:\n", cascadeTree);

    showOutput("Cascade Tree — invoice", cascadeTree);
  } catch (error) {
    console.error("WASM Cascade Tree generation failed:", error);
    output.textContent = `Errore: ${error instanceof Error ? error.message : String(error)}`;
  }
});

// ── Snapshot test runner ──────────────────────────────────────────

const runWasmTestsButton = document.querySelector("#run-wasm-tests");
const testResults = document.querySelector("#test-results");

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

function runPipeline(instance, html, pipeline) {
  switch (pipeline) {
    case "tokenize":
      return String(tokenizeHtml(instance, html));
    case "dom":
      return generateDomTree(instance, html);
    case "box":
      return generateBoxTree(instance, html);
    case "cascade":
      return generateCascadeTree(instance, html);
  }
}

function showDiff(name, expected, actual) {
  const expLines = expected.split("\n");
  const actLines = actual.split("\n");
  const maxLen = Math.max(expLines.length, actLines.length);
  let diffsShown = 0;
  let text = `\n${name}:\n`;
  for (let i = 0; i < maxLen && diffsShown < 5; i++) {
    const exp = i < expLines.length ? expLines[i] : "(missing)";
    const act = i < actLines.length ? actLines[i] : "(missing)";
    if (exp !== act) {
      text += `  line ${i + 1}:\n    expected: ${exp}\n    actual:   ${act}\n`;
      diffsShown++;
    }
  }
  if (diffsShown === 0 && expLines.length !== actLines.length) {
    text += `  Length mismatch: expected ${expLines.length} lines, got ${actLines.length}\n`;
  }
  return text;
}

async function runWasmTests() {
  testResults.textContent = "Loading snapshots...\n";

  const instance = await getWasmInstance();

  let snapshots;
  try {
    const response = await fetch("./snapshots.json");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    snapshots = await response.json();
  } catch (err) {
    testResults.textContent = `Failed to load snapshots.json: ${err.message}`;
    return;
  }

  testResults.textContent = "";
  let passed = 0;
  let failed = 0;
  const failures = [];

  for (const test of testCases) {
    const expected = snapshots[test.name];
    if (expected === undefined) {
      testResults.textContent += `✗ SKIP: ${test.name} — no snapshot\n`;
      continue;
    }

    try {
      const actual = runPipeline(instance, test.html, test.pipeline);
      if (actual === expected) {
        passed++;
        testResults.textContent += `✓ PASS: ${test.name}\n`;
      } else {
        failed++;
        testResults.textContent += `✗ FAIL: ${test.name}\n`;
        failures.push({ name: test.name, expected, actual });
      }
    } catch (err) {
      failed++;
      testResults.textContent += `✗ ERROR: ${test.name} — ${err.message}\n`;
    }
  }

  testResults.textContent += `\n${passed} passed, ${failed} failed\n`;

  if (failures.length > 0) {
    testResults.textContent += `\n--- Failure details ---`;
    for (const f of failures) {
      testResults.textContent += showDiff(f.name, f.expected, f.actual);
    }
  }
}

runWasmTestsButton.addEventListener("click", () => {
  runWasmTests().catch((err) => {
    testResults.textContent = `Internal error: ${err instanceof Error ? err.message : String(err)}`;
  });
});
