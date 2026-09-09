import assert from "node:assert/strict";
import test from "node:test";
import { resolve } from "node:path";
import { assertValidationReport } from "./verapdf.mjs";

test("the veraPDF gate rejects missing, partial, wrong-version and noncompliant reports", () => {
  const files = [resolve("tmp/pdfa/expected.pdf")];
  const valid = { report: {
    buildInformation: { releaseDetails: [{ id: "core", version: "1.30.2" }] },
    jobs: [{ itemDetails: { name: files[0] }, validationResult: [{ profileName: "PDF/A-3u validation profile", jobEndStatus: "normal", compliant: true, details: { failedChecks: 0 } }] }],
    batchSummary: { totalJobs: 1, outOfMemory: 0, veraExceptions: 0, failedEncryptedJobs: 0, failedParsingJobs: 0, validationSummary: { failedJobCount: 0, compliantPdfaCount: 1 } },
  } };
  assertValidationReport(valid, files);
  assert.throws(() => assertValidationReport({}, files));
  for (const mutate of [
    (r) => { r.jobs = []; },
    (r) => { r.jobs[0].itemDetails.name = "unexpected.pdf"; },
    (r) => { r.jobs[0].validationResult = []; },
    (r) => { r.jobs[0].validationResult[0].compliant = false; },
    (r) => { r.jobs[0].validationResult[0].profileName = "PDF/A-3b validation profile"; },
    (r) => { r.batchSummary.veraExceptions = 1; },
    (r) => { r.buildInformation.releaseDetails[0].version = "1.28.0"; },
  ]) {
    const copy = structuredClone(valid);
    mutate(copy.report);
    assert.throws(() => assertValidationReport(copy, files));
  }
});
