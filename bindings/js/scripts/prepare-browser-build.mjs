import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";

const dist = new URL("../dist/", import.meta.url);
const browserRoot = new URL("../.browser-build/", import.meta.url);
const entries = await readdir(dist, { withFileTypes: true });
const runtimeFiles = entries
  .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
  .map((entry) => entry.name)
  .sort();
const hashedFiles = [...runtimeFiles, "libhtml2realpdf.wasm", "vendor/pdf.min.mjs", "vendor/pdf.worker.min.mjs"];
const hash = createHash("sha256");

for (const filename of hashedFiles) {
  hash.update(filename);
  hash.update(await readFile(new URL(filename, dist)));
}

const buildId = hash.digest("hex").slice(0, 16);
await rm(browserRoot, { recursive: true, force: true });
const browserBuild = new URL(`${buildId}/`, browserRoot);
await mkdir(new URL("vendor/", browserBuild), { recursive: true });

for (const filename of runtimeFiles) {
  await copyFile(new URL(filename, dist), new URL(filename, browserBuild));
}
await copyFile(new URL("libhtml2realpdf.wasm", dist), new URL("libhtml2realpdf.wasm", browserBuild));
await copyFile(new URL("vendor/pdf.min.mjs", dist), new URL("vendor/pdf.min.mjs", browserBuild));
await copyFile(new URL("vendor/pdf.worker.min.mjs", dist), new URL("vendor/pdf.worker.min.mjs", browserBuild));

await writeFile(
  new URL("manifest.json", browserRoot),
  `${JSON.stringify({
    buildId,
    entry: `${buildId}/index.js`,
    wasm: `${buildId}/libhtml2realpdf.wasm`,
  }, null, 2)}\n`,
);

console.log(`Prepared cache-safe browser build ${buildId}`);
