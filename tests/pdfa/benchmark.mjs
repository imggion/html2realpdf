import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { createBridge, materializeFixtureSvg } from "./helpers.mjs";
import { thirtyPageStressReportHtml } from "../benchmark/stress-report.js";
import { preparePdfExtras } from "../../bindings/js/dist/attachments.js";
import { normalizePage } from "../../bindings/js/dist/page.js";

const scenario = process.argv[2];
if (scenario) {
  const bridge = await createBridge();
  const html = materializeFixtureSvg(thirtyPageStressReportHtml);
  const page = normalizePage({ format: "a4", margin: 28, unit: "pt" });
  const options = {
    ...(scenario.startsWith("pdfa") ? { conformance: "pdfa-3u" } : {}),
    ...(scenario.endsWith("attached") ? { attachments: [{ name: "source.bin", data: new Uint8Array(1024 * 1024) }] } : {}),
  };
  const durations = [];
  let bytes = 0;
  try {
    for (let index = 0; index < 6; index++) {
      global.gc?.();
      const start = performance.now();
      const extras = preparePdfExtras(options);
      const result = bridge.render(html, page, undefined, "web", undefined, undefined, extras);
      const duration = performance.now() - start;
      assert.equal(result.pageCount, 30, "The shared stress report must contain exactly 30 pages");
      bytes = result.bytes.length;
      if (index > 0) durations.push(duration);
      if (index === 5 && scenario.startsWith("pdfa")) await writeFile(`tmp/pdfa/stress-${scenario}.pdf`, result.bytes);
    }
    durations.sort((a, b) => a - b);
    console.log(JSON.stringify({ scenario, medianMs: durations[2], outputBytes: bytes, wasmLinearMemoryBytes: bridge.exports.memory.buffer.byteLength, processMaxRssKiB: process.resourceUsage().maxRSS }));
  } finally { bridge.dispose(); }
} else {
  // Fresh processes isolate high-water memory figures between configurations.
  const results = ["ordinary", "pdfa", "ordinary-attached", "pdfa-attached"].map((value) => JSON.parse(execFileSync(process.execPath, ["--expose-gc", fileURLToPath(import.meta.url), value], { encoding: "utf8" })));
  await writeFile("tmp/pdfa/benchmark.json", `${JSON.stringify({ boundary: "attachment copy through final WASM output copy; one warm-up and five measured renders", memory: "WASM linear-memory capacity and isolated process peak RSS (includes instantiation)", results }, null, 2)}\n`);
  console.table(results);
  const { validateFiles } = await import("./verapdf.mjs");
  await validateFiles(["tmp/pdfa/stress-pdfa.pdf", "tmp/pdfa/stress-pdfa-attached.pdf"], "stress-validation.json");
}
