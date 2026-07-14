import { appendFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";
import { execFileSync } from "node:child_process";

const requiredPaths = [
  "package/package.json",
  "package/README.md",
  "package/dist/LICENSE.md",
  "package/dist/index.d.ts",
  "package/dist/index.js",
  "package/dist/libhtml2realpdf.wasm",
  "package/dist/worker.js",
  "package/dist/vendor/pdf.min.mjs",
  "package/dist/vendor/pdf.worker.min.mjs",
  "package/skills/html2realpdf/SKILL.md",
  "package/skills/html2realpdf/agents/openai.yaml",
];

function fail(message) {
  throw new Error(message);
}

const artifactDirectory = process.env.ARTIFACT_DIRECTORY;
const expectedVersion = process.env.EXPECTED_VERSION;
if (!artifactDirectory) fail("ARTIFACT_DIRECTORY is required");
if (!expectedVersion) fail("EXPECTED_VERSION is required");

const tarballs = readdirSync(artifactDirectory)
  .filter((entry) => entry.endsWith(".tgz"))
  .map((entry) => join(artifactDirectory, entry));
if (tarballs.length !== 1) {
  fail(`Expected exactly one npm tarball, found ${tarballs.length}`);
}

const [tarball] = tarballs;
if (/\r|\n/.test(basename(tarball))) fail("Tarball filename contains a newline");

const contents = execFileSync("tar", ["-tzf", tarball], { encoding: "utf8" })
  .split("\n")
  .filter(Boolean);
const paths = new Set(contents);
for (const requiredPath of requiredPaths) {
  if (!paths.has(requiredPath)) fail(`Package tarball is missing ${requiredPath}`);
}
if (contents.some((entry) => /^package\/(src|scripts)\//.test(entry))) {
  fail("Package tarball contains private implementation sources");
}
if (paths.has("package/package-lock.json")) {
  fail("Package tarball must not contain package-lock.json");
}

const packageJson = JSON.parse(execFileSync(
  "tar",
  ["-xOzf", tarball, "package/package.json"],
  { encoding: "utf8" },
));
if (packageJson.name !== "@imggion/html2realpdf") {
  fail(`Unexpected package name: ${packageJson.name}`);
}
if (packageJson.version !== expectedVersion) {
  fail(`Expected version ${expectedVersion}, got ${packageJson.version}`);
}
if (packageJson.publishConfig?.access !== "public") {
  fail("Package publishConfig.access must be public");
}
if (packageJson.publishConfig?.provenance !== true) {
  fail("Package publishConfig.provenance must be true");
}

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `tarball=${tarball}\n`);
}
process.stdout.write(`Validated ${basename(tarball)} for ${packageJson.name}@${packageJson.version}\n`);
