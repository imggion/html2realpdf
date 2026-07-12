import { copyFile, mkdir, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("..", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../..", import.meta.url));
const dist = new URL("../dist/", import.meta.url);
const vendor = new URL("../dist/vendor/", import.meta.url);

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
await mkdir(vendor, { recursive: true });

if (!process.argv.includes("--skip-wasm-build")) {
  const build = spawnSync("zig", ["build", "wasm", "-Doptimize=ReleaseSmall"], {
    cwd: repositoryRoot,
    stdio: "inherit",
  });
  if (build.status !== 0) process.exit(build.status ?? 1);
}

await copyFile(
  new URL("../../../zig-out/bin/libhtml2realpdf.wasm", import.meta.url),
  new URL("../dist/libhtml2realpdf.wasm", import.meta.url),
);
await copyFile(
  new URL("../../../LICENSE.md", import.meta.url),
  new URL("../dist/LICENSE.md", import.meta.url),
);
await copyFile(
  new URL("../node_modules/pdfjs-dist/build/pdf.min.mjs", import.meta.url),
  new URL("../dist/vendor/pdf.min.mjs", import.meta.url),
);
await copyFile(
  new URL("../node_modules/pdfjs-dist/build/pdf.worker.min.mjs", import.meta.url),
  new URL("../dist/vendor/pdf.worker.min.mjs", import.meta.url),
);
console.log(`Prepared WASM assets for ${packageRoot}`);
