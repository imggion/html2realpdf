const WASM_URL = "../../zig-out/bin/html2realpdf.wasm";

const htmlHard = ` <!DOCTYPE html>
 <html lang="it">
 <head>
     <meta charset="UTF-8">
     <title>Test Tokenizer</title>
 </head>
 <body>
     <!-- Questo è un commento -->
     <h1 class="title" id="main-title">Titolo Principale</h1>

     <div class="container" data-info="esempio">
         <p>Paragrafo con <strong>testo in grassetto</strong> e <em>corsivo</em>.</p>

         <table border="1">
             <tr>
                 <th>Nome</th>
                 <th>Età</th>
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

         <img src="/image.jpg" alt="Immagine" width="100" height="auto">
         <br/>
         <input type="text" name="username" placeholder="Inserisci nome">
     </div>

     <footer>
         <p>Footer &copy; 2024</p>
     </footer>
 </body>
 </html>`;

const tokenizeButton = document.querySelector("#tokenize");
const domTreeButton = document.querySelector("#dom-tree");
const output = document.querySelector("#output");
const encoder = new TextEncoder();
const decoder = new TextDecoder();
let wasmInstancePromise;

function showOutput(text) {
  output.textContent = text;
}

async function getWasmInstance() {
  wasmInstancePromise ??= fetch(WASM_URL).then(async (response) => {
    if (!response.ok) {
      throw new Error(`Cannot load ${WASM_URL}: HTTP ${response.status}`);
    }

    const bytes = await response.arrayBuffer();
    return WebAssembly.instantiate(bytes, {});
  });

  const { instance } = await wasmInstancePromise;
  return instance;
}

function tokenizeHtml(instance, html) {
  const { alloc, free, memory, tokenize_html: tokenizeHtmlExport } = instance.exports;
  if (!alloc || !free || !memory || !tokenizeHtmlExport) {
    throw new Error("Missing required wasm exports: alloc, free, memory, tokenize_html");
  }

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

  if (!alloc || !free || !memory || !domTreeHtmlExport || !domTreeOutputLenExport) {
    throw new Error(
      "Missing required wasm exports: alloc, free, memory, dom_tree_html, dom_tree_output_len",
    );
  }

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

tokenizeButton.addEventListener("click", async () => {
  showOutput("");

  try {
    const instance = await getWasmInstance();
    const tokenCount = tokenizeHtml(instance, htmlHard);

    console.log("html_hard input:", htmlHard);
    console.log("wasm exports:", Object.keys(instance.exports));
    console.log("token count:", tokenCount);

    showOutput(`Token count: ${tokenCount}`);
  } catch (error) {
    console.error("WASM tokenize failed:", error);
    showOutput(`Errore: ${error instanceof Error ? error.message : String(error)}`);
  }
});

domTreeButton.addEventListener("click", async () => {
  showOutput("");

  try {
    const instance = await getWasmInstance();
    const domTree = generateDomTree(instance, htmlHard);

    console.log("html_hard input:", htmlHard);
    console.log("wasm exports:", Object.keys(instance.exports));
    console.log("DOM tree:\n", domTree);

    showOutput(domTree);
  } catch (error) {
    console.error("WASM DOM tree generation failed:", error);
    showOutput(`Errore: ${error instanceof Error ? error.message : String(error)}`);
  }
});
