import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile, access } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, join } from "node:path";
import { execFileSync } from "node:child_process";

export const version = "1.30.2";
export const installerSha256 = "6cc6341cb1af644044054b81f00a6590a7918abb18f762243de115258bcad838";
const root = fileURLToPath(new URL("../../tmp/pdfa", import.meta.url));

export async function ensureVeraPdf() {
  await mkdir(root, { recursive: true });
  const archive = join(root, `verapdf-greenfield-${version}-installer.zip`);
  try { await access(archive); } catch {
    execFileSync("curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", `https://software.verapdf.org/releases/1.30/verapdf-greenfield-${version}-installer.zip`, "--output", archive], { stdio: "inherit" });
  }
  assert.equal(createHash("sha256").update(await readFile(archive)).digest("hex"), installerSha256, "veraPDF installer checksum mismatch");
  const target = join(root, "verapdf");
  const jar = join(target, "bin", `cli-${version}.jar`);
  try { await access(jar); } catch {
    execFileSync("unzip", ["-qo", archive, "-d", root]);
    const config = join(root, "install.xml");
    const escaped = target.replaceAll("&", "&amp;").replaceAll("<", "&lt;");
    await writeFile(config, `<AutomatedInstallation langpack="eng">
      <com.izforge.izpack.panels.htmlhello.HTMLHelloPanel id="welcome"/>
      <com.izforge.izpack.panels.target.TargetPanel id="install_dir"><installpath>${escaped}</installpath></com.izforge.izpack.panels.target.TargetPanel>
      <com.izforge.izpack.panels.packs.PacksPanel id="sdk_pack_select">
        <pack index="0" name="veraPDF GUI" selected="true"/>
        <pack index="1" name="veraPDF Mac and *nix Scripts" selected="true"/>
        <pack index="2" name="veraPDF Validation model" selected="false"/>
        <pack index="3" name="veraPDF Documentation" selected="false"/>
        <pack index="4" name="veraPDF Sample Plugins" selected="false"/>
      </com.izforge.izpack.panels.packs.PacksPanel>
      <com.izforge.izpack.panels.install.InstallPanel id="install"/>
      <com.izforge.izpack.panels.finish.FinishPanel id="finish"/>
    </AutomatedInstallation>`);
    execFileSync("java", ["-jar", join(root, `verapdf-greenfield-${version}`, `verapdf-izpack-installer-${version}.jar`), config], { stdio: "inherit" });
  }
  assert.match(execFileSync("java", ["-jar", jar, "--version"], { encoding: "utf8" }), /^veraPDF 1\.30\.2\b/);
  return jar;
}

/** Fail closed on execution errors, absent reports, unexpected files or partial batches. */
export function assertValidationReport(report, files) {
  const expected = files.map((file) => resolve(file)).sort();
  assert.ok(report?.report, "Missing veraPDF report");
  const { jobs, batchSummary, buildInformation } = report.report;
  assert.equal(buildInformation.releaseDetails.find((item) => item.id === "core")?.version, version);
  assert.deepEqual(jobs.map((job) => resolve(job.itemDetails.name)).sort(), expected);
  assert.equal(batchSummary.totalJobs, expected.length);
  for (const key of ["outOfMemory", "veraExceptions", "failedEncryptedJobs", "failedParsingJobs"]) assert.equal(batchSummary[key], 0, key);
  assert.equal(batchSummary.validationSummary.failedJobCount, 0);
  assert.equal(batchSummary.validationSummary.compliantPdfaCount, expected.length);
  for (const job of jobs) {
    assert.equal(job.validationResult?.length, 1, job.itemDetails.name);
    const result = job.validationResult[0];
    assert.equal(result.profileName, "PDF/A-3u validation profile");
    assert.equal(result.jobEndStatus, "normal");
    assert.equal(result.compliant, true, `${job.itemDetails.name}: ${JSON.stringify(result.details.ruleSummaries)}`);
    assert.equal(result.details.failedChecks, 0);
  }
}

export async function validateFiles(files, reportName = "validation.json") {
  const jar = await ensureVeraPdf();
  const output = execFileSync("java", ["-Xmx1g", "-jar", jar, "--flavour", "3u", "--format", "json", ...files.map((file) => resolve(file))], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  await writeFile(join(root, reportName), output);
  assertValidationReport(JSON.parse(output), files);
}
