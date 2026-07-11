import {
  analyticsReportHtml,
  complexInvoiceHtml,
  presentationDeckHtml,
  roundedOperationsReportHtml,
} from "./pdf-fixtures.js";

const WASM_URL = "../../zig-out/bin/libhtml2realpdf.wasm";

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
const generatePdfButton = document.querySelector("#generate-pdf");
const generateComplexInvoiceButton = document.querySelector("#generate-complex-invoice");
const generateReportButton = document.querySelector("#generate-report");
const generateRoundedReportButton = document.querySelector("#generate-rounded-report");
const generatePresentationButton = document.querySelector("#generate-presentation");
const previewPdfButton = document.querySelector("#preview-pdf");
const downloadPdfButton = document.querySelector("#download-pdf");
const pdfStatus = document.querySelector("#pdf-status");
const pdfPreview = document.querySelector("#pdf-preview");
const pdfExport = document.querySelector("#pdf-export");
const packageRenderButton = document.querySelector("#package-render");
const packagePreviewButton = document.querySelector("#package-preview");
const packageSource = document.querySelector("#package-source");
const packageCanvas = document.querySelector("#package-canvas");

const packageCanvasContext = packageCanvas.getContext("2d");
packageCanvasContext.fillStyle = "rgba(29, 78, 216, 0.45)";
packageCanvasContext.fillRect(2, 2, 20, 20);
const packageStatus = document.querySelector("#package-status");

const output = document.querySelector("#output");
const encoder = new TextEncoder();
const decoder = new TextDecoder();
let wasmInstancePromise;
let generatedPdf;
let selectedPdf;
let selectedPdfFilename = "html2realpdf-document.pdf";
let activePreview;
let packageBuildPromise;
let packageModulePromise;
let packageRendererPromise;
let packagePdf;

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

function generatePdf(instance, html) {
  const {
    alloc,
    free,
    memory,
    render_html_to_pdf: renderHtmlToPdf,
    pdf_result_status: resultStatus,
    pdf_result_data_ptr: resultDataPtr,
    pdf_result_data_len: resultDataLen,
    pdf_result_page_count: resultPageCount,
    pdf_result_free: resultFree,
    html2realpdf_abi_version: abiVersion,
  } = instance.exports;

  requireWasmExports(instance, [
    "alloc",
    "free",
    "memory",
    "render_html_to_pdf",
    "pdf_result_status",
    "pdf_result_data_ptr",
    "pdf_result_data_len",
    "pdf_result_page_count",
    "pdf_result_free",
    "html2realpdf_abi_version",
  ]);
  if (abiVersion() !== 1) throw new Error(`Unsupported WASM ABI version ${abiVersion()}`);

  const input = encoder.encode(html);
  const inputPtr = alloc(input.length);
  if (inputPtr === 0) throw new Error(`wasm alloc failed for ${input.length} bytes`);

  let resultHandle = 0;
  try {
    new Uint8Array(memory.buffer, inputPtr, input.length).set(input);
    resultHandle = renderHtmlToPdf(inputPtr, input.length);
    if (resultHandle === 0) throw new Error("WASM could not allocate a PDF result");

    const status = resultStatus(resultHandle);
    if (status !== 0) throw new Error(`PDF rendering failed with status ${status}`);

    const dataPtr = resultDataPtr(resultHandle);
    const dataLen = resultDataLen(resultHandle);
    if (dataPtr === 0 || dataLen === 0) throw new Error("PDF rendering returned no bytes");

    // Copy before freeing the WASM result. `memory.buffer` may also be replaced
    // by memory.grow during any future render call.
    const bytes = new Uint8Array(memory.buffer, dataPtr, dataLen).slice();
    return { bytes, pageCount: resultPageCount(resultHandle) };
  } finally {
    if (resultHandle !== 0) resultFree(resultHandle);
    free(inputPtr, input.length);
  }
}

async function ensureGeneratedPdf() {
  if (generatedPdf) return generatedPdf;
  const instance = await getWasmInstance();
  generatedPdf = generatePdf(instance, htmlInvoiceTable);
  pdfStatus.textContent = `Generated ${generatedPdf.bytes.length.toLocaleString()} bytes across ${generatedPdf.pageCount} page(s).`;
  return generatedPdf;
}

function getPackageBuild() {
  packageBuildPromise ??= fetch(`../../bindings/js/.browser-build/manifest.json?cache=${Date.now()}`, { cache: "no-store" })
    .then(async (response) => {
      if (!response.ok) throw new Error("Browser package build is missing; run `make wasm` before opening this page");
      const manifest = await response.json();
      if (!manifest.buildId || !manifest.entry || !manifest.wasm) throw new Error("Browser package manifest is invalid; run `make wasm` again");
      const distUrl = new URL("../../bindings/js/.browser-build/", window.location.href);
      return {
        buildId: manifest.buildId,
        distUrl,
        entryUrl: new URL(manifest.entry, distUrl),
        wasmUrl: new URL(manifest.wasm, distUrl),
      };
    })
    .catch((error) => {
      packageBuildPromise = undefined;
      throw error;
    });
  return packageBuildPromise;
}

function getPackageModule() {
  packageModulePromise ??= getPackageBuild()
    .then(({ entryUrl }) => import(entryUrl.href))
    .catch((error) => {
      packageModulePromise = undefined;
      throw error;
    });
  return packageModulePromise;
}

async function getPackageRenderer() {
  packageRendererPromise ??= Promise.all([getPackageModule(), getPackageBuild()])
    .then(([{ createRenderer }, { wasmUrl }]) => createRenderer({ wasmUrl }))
    .catch((error) => {
      packageRendererPromise = undefined;
      throw error;
    });
  return packageRendererPromise;
}

function disposeActivePreview() {
  const preview = activePreview;
  activePreview = undefined;
  if (typeof preview === "function") {
    preview();
    return;
  }
  preview?.dispose?.();
}

function requirePreviewController(preview) {
  if (!preview || typeof preview.dispose !== "function" || typeof preview.fitToWidth !== "function") {
    if (typeof preview === "function") preview();
    throw new Error("Preview API is stale; run `make wasm` and reload the page to use the current cache-safe browser build");
  }
  return preview;
}

async function selectRawPdf(rawPdf, filename, label) {
  const { PdfDocument } = await getPackageModule();
  selectPdfDocument(new PdfDocument(rawPdf.bytes, rawPdf.pageCount), filename, label);
}

function selectPdfDocument(pdf, filename, label) {
  disposeActivePreview();
  selectedPdf?.dispose();
  selectedPdf = pdf;
  selectedPdfFilename = filename;
  window.__html2realpdfLastPdf = pdf.toUint8Array();
  pdfExport.setAttribute("data-pdf", bytesToBase64(window.__html2realpdfLastPdf));
  pdfPreview.replaceChildren(createPreviewEmpty(`Preview ${label} to inspect every generated page.`));
  pdfStatus.textContent = `${label} generated: ${pdf.toUint8Array().length.toLocaleString()} bytes across ${pdf.pageCount} page(s).`;
}

function createPreviewEmpty(message) {
  const empty = document.createElement("div");
  empty.className = "preview-empty";
  empty.textContent = message;
  return empty;
}

function bytesToBase64(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 16_384) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 16_384, bytes.length)));
  }
  return btoa(binary);
}

async function renderFixture(html, metadata) {
  const renderer = await getPackageRenderer();
  return renderer.render(html, {
    page: { format: "a4", margin: [32, 36, 32, 36], unit: "pt" },
    metadata,
  });
}

async function renderComplexInvoice() {
  return renderFixture(complexInvoiceHtml, {
    title: "Northstar Studio Invoice NS-2026-041",
    author: "Northstar Studio",
    subject: "Production invoice fixture",
  });
}

async function renderAnalyticsReport() {
  return renderFixture(analyticsReportHtml, {
    title: "Northstar Commerce Analytics Q2 2026",
    author: "Northstar Commerce",
    subject: "Quarterly business review fixture",
    keywords: ["analytics", "revenue", "quarterly report"],
  });
}

async function renderRoundedOperationsReport() {
  return renderFixture(roundedOperationsReportHtml, {
    title: "Northstar Operations Service Delivery Health",
    author: "Northstar Operations",
    subject: "Rounded table and status surface fixture",
    keywords: ["operations", "rounded tables", "service health"],
  });
}

async function renderPresentationDeck() {
  const renderer = await getPackageRenderer();
  return renderer.render(presentationDeckHtml, {
    page: { format: "a4", orientation: "landscape", margin: [24, 24, 24, 24], unit: "pt" },
    metadata: {
      title: "Northstar Product Strategy Presentation",
      author: "Northstar Strategy",
      subject: "Landscape presentation-style PDF fixture",
      keywords: ["presentation", "strategy", "landscape"],
    },
  });
}

async function renderWithPackageApi() {
  packagePdf?.dispose();
  packagePdf = undefined;
  packageStatus.textContent = "Rendering DOM source through the npm package...";
  const renderer = await getPackageRenderer();
  packagePdf = await renderer.render(packageSource, {
    page: { format: "a4", margin: [36, 36, 36, 36], unit: "pt" },
    metadata: { title: "Browser package QA" },
  });
  const bytes = packagePdf.toUint8Array();
  if (decoder.decode(bytes.subarray(0, 8)) !== "%PDF-1.7") throw new Error("Package API returned an invalid PDF header");
  if (!decoder.decode(bytes).includes("/SMask")) throw new Error("Canvas transparency was not preserved as a PDF soft mask");
  if ((decoder.decode(bytes).match(/\/Subtype \/Image/g) ?? []).length < 4) throw new Error("Canvas or inline SVG snapshot was not embedded as a PDF image");
  if (!decoder.decode(bytes).includes("/Title (Browser package QA)")) throw new Error("Package metadata did not reach the PDF info dictionary");
  if (packagePdf.pageCount !== 1) throw new Error(`DOM snapshot produced ${packagePdf.pageCount} pages instead of 1`);
  // Keep a defensive copy available to automated browser QA. This never
  // participates in the package API or the preview lifecycle.
  window.__html2realpdfLastPdf = bytes.slice();
  packageStatus.textContent = `Package API generated ${bytes.length.toLocaleString()} bytes across ${packagePdf.pageCount} page(s).`;
  return packagePdf;
}

async function verifyDomSnapshotFidelity() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const fixture = document.createElement("section");
  fixture.style.backgroundColor = "rgb(15, 23, 42)";
  fixture.innerHTML = `
    <p style="word-spacing: 3px; text-indent: 12px; text-transform: uppercase; word-break: break-all; overflow-wrap: anywhere; vertical-align: super; text-decoration: underline overline wavy rgb(180, 20, 90) 2px">Transparent child</p>
    <ul><li>List item</li></ul>
    <label>Live value <input value="initial"></label>
    <button type="button">Action</button>
  `;
  document.body.append(fixture);
  const input = fixture.querySelector("input");
  input.value = "React state value";

  try {
    const snapshot = await snapshotSource({ current: fixture }, {
      resourcePolicy: "error",
      enableLinks: true,
    });
    const template = document.createElement("template");
    template.innerHTML = snapshot.html;
    const root = template.content.firstElementChild;
    const paragraph = root?.querySelector("p");
    const listItem = root?.querySelector("li");
    const control = root?.querySelector("label span");
    const button = root?.querySelector("span[type='button']");
    if (!root?.style.backgroundColor) throw new Error("root background was not materialized");
    if (paragraph?.style.backgroundColor) throw new Error("transparent child background was serialized");
    if (paragraph?.style.height) throw new Error("auto block height was frozen into the snapshot");
    if (paragraph?.style.wordSpacing !== "3px") throw new Error("computed word-spacing was not captured");
    if (paragraph?.style.textIndent !== "12px") throw new Error("computed text-indent was not captured");
    if (paragraph?.style.textTransform !== "uppercase") throw new Error("computed text-transform was not captured");
    if (paragraph?.style.wordBreak !== "break-all") throw new Error("computed word-break was not captured");
    if (paragraph?.style.overflowWrap !== "anywhere") throw new Error("computed overflow-wrap was not captured");
    if (paragraph?.style.verticalAlign !== "super") throw new Error("computed vertical-align was not captured");
    if (!paragraph?.style.textDecorationLine.includes("underline") || !paragraph.style.textDecorationLine.includes("overline")) throw new Error("computed text-decoration-line was not captured");
    if (paragraph?.style.textDecorationStyle !== "wavy") throw new Error("computed text-decoration-style was not captured");
    if (paragraph?.style.textDecorationColor !== "rgb(180, 20, 90)") throw new Error("computed text-decoration-color was not captured");
    if (paragraph?.style.textDecorationThickness !== "2px") throw new Error("computed text-decoration-thickness was not captured");
    if (listItem?.style.display !== "block") throw new Error("list-item display was not normalized");
    if (control?.textContent !== "React state value") throw new Error("live input value was not captured");
    if (control?.style.display !== "inline-block") throw new Error("form control geometry was not preserved");
    if (button?.textContent !== "Action") throw new Error("button content was not captured");
  } finally {
    fixture.remove();
  }
}

async function verifyComputedVariablesAndPseudoElements() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const style = document.createElement("style");
  style.textContent = `
    .computed-profile-fixture { --accent: rgb(14, 116, 144); --gutter: 20px; width: calc(240px - var(--gutter)); color: var(--accent); }
    .computed-profile-fixture::before { content: "Prefix " attr(data-code) " \\2192 "; font-weight: 700; color: var(--accent); }
    .computed-profile-fixture::after { content: " suffix"; }
  `;
  const fixture = document.createElement("div");
  fixture.className = "computed-profile-fixture";
  fixture.dataset.code = "A17";
  fixture.textContent = "content";
  document.head.append(style);
  document.body.append(fixture);

  try {
    const snapshot = await snapshotSource(fixture, { resourcePolicy: "error", enableLinks: true });
    const template = document.createElement("template");
    template.innerHTML = snapshot.html;
    const root = template.content.firstElementChild;
    const before = root?.querySelector("[data-html2realpdf-pseudo='before']");
    const after = root?.querySelector("[data-html2realpdf-pseudo='after']");
    if (root?.style.width !== "220px") throw new Error(`computed calc/var width was ${root?.style.width || "missing"}`);
    if (root?.style.color !== "rgb(14, 116, 144)") throw new Error("computed custom-property color was not canonicalized");
    if (before?.textContent !== "Prefix A17 →") throw new Error(`::before content was not materialized: ${before?.textContent}`);
    if (after?.textContent !== " suffix") throw new Error("::after content was not materialized");
    if ((before instanceof HTMLElement ? before.style.fontWeight : "") !== "700") throw new Error("::before computed style was not captured");
  } finally {
    fixture.remove();
    style.remove();
  }
}

async function verifyRequestedMediaAndViewport() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const source = `
    <style>
      .media-probe { color: rgb(10, 20, 30); width: 100px; transition: width 30s linear; }
      @media print { .media-probe { color: rgb(200, 10, 20); } }
      @media screen { .media-probe { color: rgb(10, 20, 30); } }
      @media (min-width: 900px) { .media-probe { width: 321px; } }
    </style>
    <div class="media-probe">media probe</div>
  `;

  const print = await snapshotSource(source, {
    resourcePolicy: "error",
    mediaType: "print",
    viewport: { width: 1000, height: 700 },
  });
  const screen = await snapshotSource(source, {
    resourcePolicy: "error",
    mediaType: "screen",
    viewport: { width: 800, height: 700 },
  });
  const printTemplate = document.createElement("template");
  const screenTemplate = document.createElement("template");
  printTemplate.innerHTML = print.html;
  screenTemplate.innerHTML = screen.html;
  const printProbe = printTemplate.content.querySelector(".media-probe");
  const screenProbe = screenTemplate.content.querySelector(".media-probe");
  if (printProbe?.style.color !== "rgb(200, 10, 20)") throw new Error(`print media was not selected: ${printProbe?.style.color}`);
  if (screenProbe?.style.color !== "rgb(10, 20, 30)") throw new Error(`screen media was not selected: ${screenProbe?.style.color}`);
  if (printProbe?.style.width !== "321px") throw new Error(`1000px viewport did not activate min-width query: ${printProbe?.style.width}`);
  if (screenProbe?.style.width !== "100px") throw new Error(`800px viewport unexpectedly activated min-width query: ${screenProbe?.style.width}`);
  if (printProbe?.style.transition) throw new Error("transition leaked into the immutable computed snapshot");

  const style = document.createElement("style");
  style.textContent = `
    .media-ancestor .dom-media-probe { color: rgb(20, 30, 40); width: 100px; }
    @media print { .media-ancestor .dom-media-probe { color: rgb(180, 20, 40); } }
    @media (min-width: 900px) { .media-ancestor .dom-media-probe { width: 345px; } }
  `;
  const ancestor = document.createElement("section");
  ancestor.className = "media-ancestor";
  ancestor.innerHTML = '<div class="dom-media-probe"><input value="initial"></div>';
  const liveInput = ancestor.querySelector("input");
  liveInput.value = "live environment value";
  document.head.append(style);
  document.body.append(ancestor);
  try {
    const domSnapshot = await snapshotSource(ancestor.querySelector(".dom-media-probe"), {
      resourcePolicy: "error",
      mediaType: "print",
      viewport: { width: 1000, height: 700 },
    });
    const domTemplate = document.createElement("template");
    domTemplate.innerHTML = domSnapshot.html;
    const domProbe = domTemplate.content.firstElementChild;
    if (domProbe?.style.color !== "rgb(180, 20, 40)" || domProbe?.style.width !== "345px") {
      throw new Error(`Element/ref environment was not deterministic: ${domProbe?.getAttribute("style")}`);
    }
    if (!domProbe?.textContent?.includes("live environment value")) throw new Error("Element/ref live control state was lost in isolated media snapshot");
  } finally {
    ancestor.remove();
    style.remove();
  }
}

async function verifyShadowDomOptIn() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const host = document.createElement("section");
  host.innerHTML = '<span slot="content">slotted value</span>';
  const shadow = host.attachShadow({ mode: "open" });
  shadow.innerHTML = `
    <style>
      .shadow-card { color: rgb(12, 74, 110); font-weight: 700; }
      @media (min-width: 900px) { .shadow-card { width: 222px; } }
    </style>
    <div class="shadow-card">shadow content: <slot name="content"></slot></div>
  `;
  document.body.append(host);

  try {
    const omitted = await snapshotSource(host, { resourcePolicy: "error", includeShadowDom: false });
    const included = await snapshotSource(host, { resourcePolicy: "error", includeShadowDom: true, viewport: { width: 1000, height: 700 } });
    if (omitted.html.includes("shadow content")) throw new Error("Shadow DOM was included without opt-in");
    const template = document.createElement("template");
    template.innerHTML = included.html;
    const root = template.content.firstElementChild;
    const card = root?.querySelector(".shadow-card");
    if (root?.getAttribute("data-html2realpdf-shadow-host") !== "open") throw new Error("Shadow host marker is missing");
    if (!card?.textContent?.includes("shadow content: slotted value")) throw new Error("composed Shadow DOM content was not flattened");
    if (card.style.color !== "rgb(12, 74, 110)") throw new Error("Shadow DOM computed style was not materialized");
    if (card.style.width !== "222px") throw new Error(`Shadow DOM did not use the requested isolated viewport: ${card.getAttribute("style")}`);
  } finally {
    host.remove();
  }
}

async function verifyControlledStylesheetResources() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const requests = [];
  const snapshot = await snapshotSource(`
    <link rel="stylesheet" href="/assets/report.css">
    <div class="resolved-sheet">resolved stylesheet</div>
  `, {
    baseUrl: "https://fixtures.example.test/reports/",
    resourcePolicy: "error",
    resourceResolver(request) {
      requests.push({ kind: request.kind, url: request.url.href });
      return ".resolved-sheet { color: rgb(8, 145, 178); width: 234px; }";
    },
  });
  const template = document.createElement("template");
  template.innerHTML = snapshot.html;
  const target = template.content.querySelector(".resolved-sheet");
  if (requests.length !== 1 || requests[0].kind !== "stylesheet") throw new Error("stylesheet did not pass through resourceResolver");
  if (requests[0].url !== "https://fixtures.example.test/assets/report.css") throw new Error(`stylesheet base URL was wrong: ${requests[0].url}`);
  if (target?.style.color !== "rgb(8, 145, 178)" || target?.style.width !== "234px") {
    throw new Error("resolved stylesheet did not participate in computed style");
  }

  const omitted = await snapshotSource('<link rel="stylesheet" href="/missing.css"><p>safe</p>', {
    baseUrl: "https://fixtures.example.test/",
    resourcePolicy: "omit",
  });
  if (!omitted.diagnostics.some((diagnostic) => diagnostic.code === "RESOURCE_OMITTED")) throw new Error("omitted stylesheet diagnostic is missing");
  if (omitted.html.includes("missing.css")) throw new Error("omitted stylesheet survived the inert snapshot");
}

async function verifyInertHtmlStringComputedSnapshot() {
  const { buildId, distUrl } = await getPackageBuild();
  const { snapshotSource } = await import(new URL(`${buildId}/snapshot.js`, distUrl).href);
  const snapshot = await snapshotSource(`
    <style>
      body { --page-width: 320px; }
      .string-card { width: calc(var(--page-width) - 32px); color: rgb(124, 58, 237); }
      .string-card::before { content: "String " attr(data-code) ": "; font-weight: 700; }
    </style>
    <div class="string-card" data-code="S1">safe body</div>
    <script>window.__html2realpdfScriptExecuted = true</script>
  `, { resourcePolicy: "error", enableLinks: true });
  const template = document.createElement("template");
  template.innerHTML = snapshot.html;
  const card = template.content.querySelector(".string-card");
  const before = card?.querySelector("[data-html2realpdf-pseudo='before']");
  if ((card instanceof HTMLElement ? card.style.width : "") !== "288px") throw new Error(`HTML string computed width was ${card instanceof HTMLElement ? card.style.width : "missing"}`);
  if (before?.textContent !== "String S1: ") throw new Error(`HTML string ::before was not materialized: ${before?.textContent}`);
  if (template.content.querySelector("script")) throw new Error("active script survived the inert snapshot");
  if (Reflect.get(window, "__html2realpdfScriptExecuted")) throw new Error("HTML string script executed during snapshot");
}

async function verifySelectorPageBreak() {
  const renderer = await getPackageRenderer();
  const pdf = await renderer.render("<main><p>First page</p><p id='second'>Second page</p></main>", {
    page: { format: "a4", margin: 36, unit: "pt" },
    pageBreak: { before: "#second" },
  });
  try {
    if (pdf.pageCount !== 2) throw new Error(`selector page break produced ${pdf.pageCount} pages instead of 2`);
  } finally {
    pdf.dispose();
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
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
    output.textContent = `Error: ${error instanceof Error ? error.message : String(error)}`;
  }
});

generatePdfButton.addEventListener("click", async () => {
  pdfStatus.textContent = "Generating PDF...";
  try {
    generatedPdf = undefined;
    const pdf = await ensureGeneratedPdf();
    await selectRawPdf(pdf, "html2realpdf-smoke-invoice.pdf", "Smoke invoice");
    showOutput("PDF", `Header: ${decoder.decode(pdf.bytes.subarray(0, 8))}\nPages: ${pdf.pageCount}\nBytes: ${pdf.bytes.length}`);
  } catch (error) {
    pdfStatus.textContent = `PDF generation failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

generateComplexInvoiceButton.addEventListener("click", async () => {
  pdfStatus.textContent = "Generating colored invoice...";
  try {
    const pdf = await renderComplexInvoice();
    selectPdfDocument(pdf, "northstar-invoice.pdf", "Colored invoice");
  } catch (error) {
    pdfStatus.textContent = `Invoice generation failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

generateReportButton.addEventListener("click", async () => {
  pdfStatus.textContent = "Generating analytics report...";
  try {
    const pdf = await renderAnalyticsReport();
    selectPdfDocument(pdf, "northstar-analytics-report.pdf", "Analytics report");
  } catch (error) {
    pdfStatus.textContent = `Report generation failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

generateRoundedReportButton.addEventListener("click", async () => {
  pdfStatus.textContent = "Generating rounded operations report...";
  try {
    const pdf = await renderRoundedOperationsReport();
    selectPdfDocument(pdf, "northstar-rounded-operations.pdf", "Rounded operations report");
  } catch (error) {
    pdfStatus.textContent = `Rounded report generation failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

generatePresentationButton.addEventListener("click", async () => {
  pdfStatus.textContent = "Generating landscape presentation deck...";
  try {
    const pdf = await renderPresentationDeck();
    selectPdfDocument(pdf, "northstar-strategy-deck.pdf", "Presentation deck");
  } catch (error) {
    pdfStatus.textContent = `Presentation generation failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

previewPdfButton.addEventListener("click", async () => {
  try {
    if (!selectedPdf) {
      const rawPdf = await ensureGeneratedPdf();
      await selectRawPdf(rawPdf, "html2realpdf-smoke-invoice.pdf", "Smoke invoice");
    }
    disposeActivePreview();
    activePreview = requirePreviewController(await selectedPdf.preview(pdfPreview, {
      initialScale: "fit-width",
      ariaLabel: `${selectedPdfFilename} integrated preview`,
    }));
    pdfStatus.textContent = `${selectedPdfFilename} is rendered inside the page at ${Math.round(activePreview.currentScale * 100)}% zoom.`;
  } catch (error) {
    pdfStatus.textContent = `PDF preview failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

downloadPdfButton.addEventListener("click", async () => {
  try {
    if (!selectedPdf) {
      const rawPdf = await ensureGeneratedPdf();
      await selectRawPdf(rawPdf, "html2realpdf-smoke-invoice.pdf", "Smoke invoice");
    }
    selectedPdf.download(selectedPdfFilename);
    pdfStatus.textContent = `Download triggered for ${selectedPdfFilename}.`;
  } catch (error) {
    pdfStatus.textContent = `PDF download failed: ${error instanceof Error ? error.message : String(error)}`;
  }
});

window.addEventListener("pagehide", () => {
  disposeActivePreview();
  selectedPdf?.dispose();
  packagePdf?.dispose();
  void packageRendererPromise?.then((renderer) => renderer.dispose());
});

packageRenderButton.addEventListener("click", () => {
  renderWithPackageApi().catch((error) => {
    packageStatus.textContent = `Package API render failed: ${error instanceof Error ? error.message : String(error)}`;
  });
});

packagePreviewButton.addEventListener("click", async () => {
  try {
    if (!packagePdf) await renderWithPackageApi();
    disposeActivePreview();
    activePreview = requirePreviewController(await packagePdf.preview(pdfPreview, {
      initialScale: "fit-width",
      ariaLabel: "DOM package PDF integrated preview",
    }));
    packageStatus.textContent = `Package PDF rendered as ${packagePdf.pageCount} in-page canvas page(s).`;
  } catch (error) {
    packageStatus.textContent = `Package preview failed: ${error instanceof Error ? error.message : String(error)}`;
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

function verifyPdf(instance) {
  const result = generatePdf(instance, htmlInvoiceTable);
  const text = decoder.decode(result.bytes);
  if (!text.startsWith("%PDF-1.7")) throw new Error("missing PDF 1.7 header");
  if (!text.includes("xref") || !text.endsWith("%%EOF\n")) throw new Error("missing PDF xref or trailer");
  if (text.includes("/Subtype /Image")) throw new Error("document was unexpectedly flattened into an image");
  if (result.pageCount < 1) throw new Error("invalid PDF page count");
  return result;
}

function verifyComplexDocument(pdf, expectedPages, options = {}) {
  const bytes = pdf.toUint8Array();
  const text = decoder.decode(bytes);
  if (!text.startsWith("%PDF-1.7")) throw new Error("missing PDF 1.7 header");
  if (pdf.pageCount !== expectedPages) throw new Error(`expected ${expectedPages} pages, received ${pdf.pageCount}`);
  if (bytes.length < (options.minimumBytes ?? 100_000)) throw new Error(`complex fixture is unexpectedly small at ${bytes.length} bytes`);
  if (options.minimumImages && (text.match(/\/Subtype \/Image/g) ?? []).length < options.minimumImages) {
    throw new Error("report chart images were not embedded");
  }
  return bytes.length;
}

async function verifyEmbeddedPreview(pdf) {
  disposeActivePreview();
  activePreview = requirePreviewController(await pdf.preview(pdfPreview, {
    initialScale: "fit-width",
    ariaLabel: "Automated integrated PDF preview",
  }));
  const host = pdfPreview.querySelector("[data-html2realpdf-preview]");
  const shadow = host?.shadowRoot;
  if (!shadow) throw new Error("preview did not create an integrated shadow-DOM viewer");
  if (pdfPreview.querySelector("iframe,object,embed")) throw new Error("preview delegated to the browser PDF plugin");
  const canvases = [...shadow.querySelectorAll("canvas")];
  if (canvases.length !== pdf.pageCount) throw new Error(`preview rendered ${canvases.length} canvases for ${pdf.pageCount} pages`);
  if (canvases.some((canvas) => canvas.width === 0 || canvas.height === 0)) throw new Error("preview contains an empty page canvas");
  if (!shadow.querySelector('button[aria-label="Zoom in"]')) throw new Error("preview zoom controls are missing");
  const initialScale = activePreview.currentScale;
  await activePreview.setScale(Math.min(initialScale + 0.25, 3));
  if (activePreview.currentScale <= initialScale) throw new Error("preview zoom API did not increase the scale");
  await activePreview.fitToWidth();
  return canvases.length;
}

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
  document.documentElement.dataset.testStatus = "running";
  testResults.textContent = "Loading snapshots...\n";

  const instance = await getWasmInstance();

  let snapshots;
  try {
    const response = await fetch("./snapshots.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    snapshots = await response.json();
  } catch (err) {
    testResults.textContent = `Failed to load snapshots.json: ${err.message}`;
    document.documentElement.dataset.testStatus = "failed";
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

  try {
    const pdf = verifyPdf(instance);
    passed++;
    testResults.textContent += `✓ PASS: real_pdf (${pdf.bytes.length} bytes, ${pdf.pageCount} page(s))\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: real_pdf — ${err.message}\n`;
  }

  try {
    await verifyDomSnapshotFidelity();
    passed++;
    testResults.textContent += "✓ PASS: dom_snapshot_fidelity\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: dom_snapshot_fidelity — ${err.message}\n`;
  }

  try {
    await verifySelectorPageBreak();
    passed++;
    testResults.textContent += "✓ PASS: selector_page_break (2 pages)\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: selector_page_break — ${err.message}\n`;
  }

  try {
    await verifyComputedVariablesAndPseudoElements();
    passed++;
    testResults.textContent += "✓ PASS: computed_variables_and_pseudo_elements\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: computed_variables_and_pseudo_elements — ${err.message}\n`;
  }

  try {
    await verifyInertHtmlStringComputedSnapshot();
    passed++;
    testResults.textContent += "✓ PASS: inert_html_string_computed_snapshot\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: inert_html_string_computed_snapshot — ${err.message}\n`;
  }

  try {
    await verifyRequestedMediaAndViewport();
    passed++;
    testResults.textContent += "✓ PASS: requested_media_and_viewport\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: requested_media_and_viewport — ${err.message}\n`;
  }

  try {
    await verifyShadowDomOptIn();
    passed++;
    testResults.textContent += "✓ PASS: shadow_dom_opt_in\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: shadow_dom_opt_in — ${err.message}\n`;
  }

  try {
    await verifyControlledStylesheetResources();
    passed++;
    testResults.textContent += "✓ PASS: controlled_stylesheet_resources\n";
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: controlled_stylesheet_resources — ${err.message}\n`;
  }

  try {
    const pdf = await renderWithPackageApi();
    passed++;
    testResults.textContent += `✓ PASS: npm_package_dom_api (${pdf.toUint8Array().length} bytes, ${pdf.pageCount} page(s))\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: npm_package_dom_api — ${err.message}\n`;
  }

  try {
    const pdf = await renderComplexInvoice();
    const size = verifyComplexDocument(pdf, 2, { minimumBytes: 100_000 });
    pdf.dispose();
    passed++;
    testResults.textContent += `✓ PASS: complex_colored_invoice (${size} bytes, 2 pages)\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: complex_colored_invoice — ${err.message}\n`;
  }

  try {
    const pdf = await renderAnalyticsReport();
    const size = verifyComplexDocument(pdf, 3, { minimumBytes: 120_000, minimumImages: 4 });
    pdf.dispose();
    passed++;
    testResults.textContent += `✓ PASS: analytics_report_with_charts (${size} bytes, 3 pages)\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: analytics_report_with_charts — ${err.message}\n`;
  }

  try {
    const pdf = await renderRoundedOperationsReport();
    const size = verifyComplexDocument(pdf, 2, { minimumBytes: 90_000 });
    pdf.dispose();
    passed++;
    testResults.textContent += `✓ PASS: rounded_operations_tables (${size} bytes, 2 pages)\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: rounded_operations_tables — ${err.message}\n`;
  }

  try {
    const pdf = await renderPresentationDeck();
    const size = verifyComplexDocument(pdf, 4, { minimumBytes: 100_000 });
    const text = decoder.decode(pdf.toUint8Array());
    if (!text.includes("/MediaBox [0 0 841.890 595.276]")) throw new Error("presentation pages are not A4 landscape");
    pdf.dispose();
    passed++;
    testResults.textContent += `✓ PASS: landscape_presentation_deck (${size} bytes, 4 pages)\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: landscape_presentation_deck — ${err.message}\n`;
  }

  try {
    if (!packagePdf) throw new Error("package PDF was not generated");
    const pageCount = await verifyEmbeddedPreview(packagePdf);
    passed++;
    testResults.textContent += `✓ PASS: embedded_canvas_preview (${pageCount} page canvas(es))\n`;
  } catch (err) {
    failed++;
    testResults.textContent += `✗ ERROR: embedded_canvas_preview — ${err.message}\n`;
  }

  testResults.textContent += `\n${passed} passed, ${failed} failed\n`;
  document.documentElement.dataset.testStatus = failed === 0 ? "passed" : "failed";

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
    document.documentElement.dataset.testStatus = "failed";
  });
});
