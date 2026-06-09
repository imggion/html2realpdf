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

const button = document.querySelector("#tokenize");
const output = document.querySelector("#output");
let wasmInstancePromise;

function appendLine(text) {
  const line = document.createElement("p");
  line.textContent = text;
  output.append(line);
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

  const bytes = new TextEncoder().encode(html);
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

button.addEventListener("click", async () => {
  output.replaceChildren();

  try {
    const instance = await getWasmInstance();
    const tokenCount = tokenizeHtml(instance, htmlHard);

    console.log("html_hard input:", htmlHard);
    console.log("wasm exports:", Object.keys(instance.exports));
    console.log("token count:", tokenCount);

    appendLine(`Token count: ${tokenCount}`);
  } catch (error) {
    console.error("WASM tokenize failed:", error);
    appendLine(`Errore: ${error instanceof Error ? error.message : String(error)}`);
  }
});
