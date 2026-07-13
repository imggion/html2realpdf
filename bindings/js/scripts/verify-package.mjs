import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const packageRoot = fileURLToPath(new URL("..", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../..", import.meta.url));
const typesOnly = process.argv.includes("--types-only");

async function main() {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "html2realpdf-consumer-"));
  try {
    verifySkillCopies();
    verifySelfContainedMaps();

    const pack = run("npm", [
      "pack",
      "--ignore-scripts",
      "--json",
      "--pack-destination",
      temporaryRoot,
    ], packageRoot, true);
    const [artifact] = JSON.parse(pack.stdout);
    assert.equal(artifact.name, "@imggion/html2realpdf");
    assert.equal(artifact.version, "0.1.0-rc1");
    verifyTarballFiles(artifact.files.map((file) => file.path));

    const consumerRoot = join(temporaryRoot, "consumer");
    await createConsumer(consumerRoot);
    run("npm", [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--no-package-lock",
      "--no-save",
      join(temporaryRoot, artifact.filename),
    ], consumerRoot);

    const tsc = join(packageRoot, "node_modules", "typescript", "bin", "tsc");
    run(process.execPath, [tsc, "-p", "tsconfig.bundler.json"], consumerRoot);
    run(process.execPath, [tsc, "-p", "tsconfig.nodenext.json"], consumerRoot);

    if (!typesOnly) {
      const vite = join(repositoryRoot, "tests", "react", "node_modules", "vite", "bin", "vite.js");
      run(process.execPath, [vite, "build"], consumerRoot);
      await verifyBrowserBundle(consumerRoot);
    }

    console.log(typesOnly
      ? "Verified packed TypeScript consumer (Bundler + NodeNext)"
      : "Verified packed TypeScript/Vite consumer and browser runtime");
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
}

function verifySkillCopies() {
  const rootSkill = resolve(repositoryRoot, "skills/html2realpdf");
  const packageSkill = resolve(packageRoot, "skills/html2realpdf");
  for (const relative of ["SKILL.md", "agents/openai.yaml"]) {
    const root = run("cmp", ["-s", join(rootSkill, relative), join(packageSkill, relative)], repositoryRoot, false);
    assert.equal(root.status, 0, `Package skill differs from root skill: ${relative}`);
  }
}

function verifySelfContainedMaps() {
  for (const relative of ["dist/index.js.map"]) {
    const map = JSON.parse(run("node", ["-e", `process.stdout.write(require('node:fs').readFileSync(${JSON.stringify(join(packageRoot, relative))}, 'utf8'))`], packageRoot, true).stdout);
    assert.ok(Array.isArray(map.sourcesContent) && map.sourcesContent.every(Boolean), `${relative} must embed its sources`);
  }
}

function verifyTarballFiles(files) {
  const required = [
    "README.md",
    "dist/LICENSE.md",
    "dist/index.d.ts",
    "dist/index.js",
    "dist/libhtml2realpdf.wasm",
    "dist/worker.js",
    "dist/vendor/pdf.min.mjs",
    "dist/vendor/pdf.worker.min.mjs",
    "package.json",
    "skills/html2realpdf/SKILL.md",
    "skills/html2realpdf/agents/openai.yaml",
  ];
  for (const path of required) assert.ok(files.includes(path), `Missing tarball file: ${path}`);
  assert.ok(files.every((path) => !path.startsWith("src/")), "Source implementation must not leak into the tarball");
  assert.ok(files.every((path) => !path.startsWith("scripts/")), "Build scripts must not leak into the tarball");
  assert.ok(!files.includes("package-lock.json"), "The library lockfile must not be published");
}

async function createConsumer(root) {
  await mkdir(join(root, "src"), { recursive: true });
  await Promise.all([
    writeFile(join(root, "package.json"), `${JSON.stringify({ private: true, type: "module" }, null, 2)}\n`),
    writeFile(join(root, "index.html"), `<!doctype html>
<html><body>
  <main id="source"><h1>Packed consumer</h1><p>Selectable PDF text</p></main>
  <section id="preview"></section>
  <script type="module" src="/src/main.ts"></script>
</body></html>\n`),
    writeFile(join(root, "tsconfig.bundler.json"), tsconfig("ESNext", "Bundler")),
    writeFile(join(root, "tsconfig.nodenext.json"), tsconfig("NodeNext", "NodeNext")),
    writeFile(join(root, "src", "typecheck.ts"), typecheckSource),
    writeFile(join(root, "src", "main.ts"), browserSource),
  ]);
}

function tsconfig(module, moduleResolution) {
  return `${JSON.stringify({
    compilerOptions: {
      target: "ES2022",
      module,
      moduleResolution,
      lib: ["ES2022", "DOM", "DOM.Iterable"],
      strict: true,
      noEmit: true,
      skipLibCheck: false,
    },
    include: ["src/**/*.ts"],
  }, null, 2)}\n`;
}

const typecheckSource = `import html2pdf, {
  Html2RealPdf,
  PdfDocument,
  PdfPreview,
  createRenderer,
  renderPdf,
  type Html2PdfOptions,
  type RenderOptions,
  type ResourceRequest,
} from "@imggion/html2realpdf";

const element = document.createElement("main");
const ref = { current: element };
const options: RenderOptions = { page: { format: "a4", margin: [10, 12] } };
void renderPdf(ref, options);

async function renderBatch() {
  const renderer = await createRenderer();
  const pdf = await renderer.render(element);
  pdf.dispose();
  renderer.dispose();
}
void renderBatch;

const worker = html2pdf().from(element);
const blob: Promise<Blob> = worker.outputPdf("blob");
const buffer: Promise<ArrayBuffer> = worker.outputPdf("arraybuffer");
const url: Promise<string> = worker.outputPdf("bloburl");
void [blob, buffer, url];

// @ts-expect-error Construct renderers through createRenderer().
new Html2RealPdf();
// @ts-expect-error PdfDocument instances are renderer-owned results.
new PdfDocument(new Uint8Array(), 1);
// @ts-expect-error PdfPreview.open is an internal factory.
PdfPreview.open(element, new Uint8Array(), 1);
const invalidRenderOptions: RenderOptions = {
  // @ts-expect-error Filenames belong to download() or compatibility save().
  filename: "report.pdf",
};
const invalidCompatOptions: Html2PdfOptions = {
  // @ts-expect-error Raster image options are unsupported.
  image: { type: "jpeg" },
};
// @ts-expect-error Fonts are registered through createRenderer().
const invalidResourceKind: ResourceRequest["kind"] = "font";
void [invalidRenderOptions, invalidCompatOptions, invalidResourceKind];
`;

const browserSource = `import { renderPdf } from "@imggion/html2realpdf";

declare global {
  interface Window {
    __html2realpdfConsumer?: { pageCount?: number; blobType?: string; previewPages?: number; error?: string };
  }
}

async function run() {
  const source = document.querySelector("#source");
  const target = document.querySelector("#preview");
  if (!(source instanceof HTMLElement) || !(target instanceof HTMLElement)) throw new Error("Missing fixture elements");
  const pdf = await renderPdf(source, { cssProfile: "web", fallback: "error" });
  try {
    const preview = await pdf.preview(target, { initialScale: 0.5 });
    try {
      window.__html2realpdfConsumer = {
        pageCount: pdf.pageCount,
        blobType: pdf.toBlob().type,
        previewPages: target.querySelector<HTMLElement>("[data-html2realpdf-preview]")?.shadowRoot?.querySelectorAll("canvas").length ?? 0,
      };
    } finally {
      preview.dispose();
    }
  } finally {
    pdf.dispose();
  }
}

run().catch((error: unknown) => {
  window.__html2realpdfConsumer = { error: error instanceof Error ? error.message : String(error) };
});
`;

async function verifyBrowserBundle(consumerRoot) {
  const dist = join(consumerRoot, "dist");
  const server = createServer(async (request, response) => {
    try {
      const pathname = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
      const relative = pathname === "/" ? "index.html" : pathname.slice(1);
      const path = resolve(dist, relative);
      if (!path.startsWith(`${resolve(dist)}/`) && path !== resolve(dist, "index.html")) {
        response.writeHead(403).end();
        return;
      }
      const data = await readFile(path);
      response.setHeader("Content-Type", mime(path));
      response.end(data);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolveListen);
  });

  try {
    const address = server.address();
    assert.ok(address && typeof address === "object");
    const playwrightUrl = pathToFileURL(join(repositoryRoot, "tests/web/node_modules/playwright/index.mjs")).href;
    const { chromium } = await import(playwrightUrl);
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.goto(`http://127.0.0.1:${address.port}/`);
      await page.waitForFunction(() => window.__html2realpdfConsumer !== undefined);
      const result = await page.evaluate(() => window.__html2realpdfConsumer);
      assert.equal(result?.error, undefined);
      assert.equal(result?.pageCount, 1);
      assert.equal(result?.blobType, "application/pdf");
      assert.ok((result?.previewPages ?? 0) >= 1);
    } finally {
      await browser.close();
    }
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}

function run(command, args, cwd, capture = false) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !capture) throw new Error(`${command} failed with status ${result.status}`);
  if (result.status !== 0 && capture) throw new Error(`${command} failed with status ${result.status}`);
  return result;
}

function mime(path) {
  if (path.endsWith(".html")) return "text/html; charset=utf-8";
  if (path.endsWith(".js") || path.endsWith(".mjs")) return "text/javascript; charset=utf-8";
  if (path.endsWith(".css")) return "text/css; charset=utf-8";
  if (path.endsWith(".wasm")) return "application/wasm";
  return "application/octet-stream";
}

await main();
