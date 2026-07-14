import { readFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";

function collectPageFailures(page) {
  const failures = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(message.text());
  });
  return failures;
}

async function expectPdfDownload(download, expectedFilename) {
  expect(download.suggestedFilename()).toBe(expectedFilename);
  const path = await download.path();
  expect(path).toBeTruthy();
  const bytes = await readFile(path);
  expect(bytes.subarray(0, 5).toString()).toBe("%PDF-");
}

async function expectBenchmarkRows(page, tableSelector) {
  const rows = page.locator(`${tableSelector} tbody tr`);
  await expect(rows).toHaveCount(2);

  const nativeRow = page.locator(`${tableSelector} tbody tr[data-engine="html2realpdf"]`);
  const rasterRow = page.locator(`${tableSelector} tbody tr[data-engine="html2pdfjs"]`);
  await expect(nativeRow).toHaveAttribute("data-classification", "Native/selectable PDF");
  await expect(rasterRow).toHaveAttribute("data-classification", "Raster image PDF");

  for (const row of [nativeRow, rasterRow]) {
    for (const metric of ["cold", "warm", "size", "pages"]) {
      const value = Number(await row.locator(`[data-metric="${metric}"]`).getAttribute("data-value"));
      expect(value, `${metric} should be a positive measured value`).toBeGreaterThan(0);
    }
  }
}

async function expectCompletedBenchmark(page, dataAttribute, statusSelector, message, timeout = 120_000) {
  await expect.poll(
    () => page.locator("html").getAttribute(dataAttribute),
    { timeout, message },
  ).toMatch(/complete|failed/);
  const status = await page.locator("html").getAttribute(dataAttribute);
  const detail = await page.locator(statusSelector).innerText();
  expect(status, detail).toBe("complete");
}

test("native harness benchmarks and downloads both engines from one fixture", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "The benchmark smoke runs once to keep the release gate fast");
  const failures = collectPageFailures(page);
  const automaticDownloads = [];
  page.on("download", (download) => automaticDownloads.push(download));

  await page.goto("/tests/web/index.html");
  await page.locator("#benchmark-document").selectOption("invoice");
  await page.getByRole("button", { name: "Benchmark docs" }).click();

  await expectCompletedBenchmark(page, "data-benchmark-status", "#benchmark-status", "native benchmark did not finish");
  await expect.poll(() => automaticDownloads.length).toBe(2);
  await expectBenchmarkRows(page, "#benchmark-results");

  const downloadsByName = new Map(automaticDownloads.map((download) => [download.suggestedFilename(), download]));
  await expectPdfDownload(downloadsByName.get("northstar-invoice-html2realpdf.pdf"), "northstar-invoice-html2realpdf.pdf");
  await expectPdfDownload(downloadsByName.get("northstar-invoice-html2pdfjs.pdf"), "northstar-invoice-html2pdfjs.pdf");

  const runId = await page.locator("#benchmark-results").getAttribute("data-run-id");
  const individualDownloadPromise = page.waitForEvent("download");
  await page.locator('#benchmark-results tr[data-engine="html2realpdf"]').getByRole("button", { name: "Download" }).click();
  await expectPdfDownload(await individualDownloadPromise, "northstar-invoice-html2realpdf.pdf");
  await expect(page.locator("#benchmark-results")).toHaveAttribute("data-run-id", runId);
  expect(failures, failures.join("\n")).toEqual([]);
});

test("native harness benchmarks an exact 30-page mixed-content report", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "The benchmark stress test runs once to keep the release gate fast");
  test.setTimeout(180_000);
  const failures = collectPageFailures(page);
  const automaticDownloads = [];
  page.on("download", (download) => automaticDownloads.push(download));

  await page.goto("/tests/web/index.html");
  await page.locator("#benchmark-document").selectOption("stress-30");
  await page.getByRole("button", { name: "Benchmark docs" }).click();

  await expectCompletedBenchmark(page, "data-benchmark-status", "#benchmark-status", "30-page native benchmark did not finish", 180_000);
  await expect.poll(() => automaticDownloads.length).toBe(2);
  await expectBenchmarkRows(page, "#benchmark-results");
  await expect(page.locator('#benchmark-results tr[data-engine="html2realpdf"] [data-metric="pages"]')).toHaveAttribute("data-value", "30");
  await expect(page.locator('#benchmark-results tr[data-engine="html2pdfjs"] [data-metric="pages"]')).toHaveAttribute("data-value", "30");

  const downloadsByName = new Map(automaticDownloads.map((download) => [download.suggestedFilename(), download]));
  await expectPdfDownload(downloadsByName.get("northstar-30-page-stress-report-html2realpdf.pdf"), "northstar-30-page-stress-report-html2realpdf.pdf");
  await expectPdfDownload(downloadsByName.get("northstar-30-page-stress-report-html2pdfjs.pdf"), "northstar-30-page-stress-report-html2pdfjs.pdf");
  expect(failures, failures.join("\n")).toEqual([]);
});

test("React harness benchmarks the same mounted ref with both engines", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "The benchmark smoke runs once to keep the release gate fast");
  test.setTimeout(180_000);
  const failures = collectPageFailures(page);
  const automaticDownloads = [];
  page.on("download", (download) => automaticDownloads.push(download));

  await page.goto("http://127.0.0.1:4174");
  await page.getByLabel("Rendered document").selectOption("stress");
  await expect(page.getByText("Mounted the 30-page stress report. Render or benchmark it when ready.")).toBeVisible();
  await page.getByRole("button", { name: "Benchmark docs" }).click();

  await expectCompletedBenchmark(page, "data-react-benchmark-status", ".benchmark-panel .status", "React benchmark did not finish", 180_000);
  await expect.poll(() => automaticDownloads.length).toBe(2);
  await expectBenchmarkRows(page, "#react-benchmark-results");
  await expect(page.locator('#react-benchmark-results tr[data-engine="html2realpdf"] [data-metric="pages"]')).toHaveAttribute("data-value", "30");
  await expect(page.locator('#react-benchmark-results tr[data-engine="html2pdfjs"] [data-metric="pages"]')).toHaveAttribute("data-value", "30");

  const downloadsByName = new Map(automaticDownloads.map((download) => [download.suggestedFilename(), download]));
  await expectPdfDownload(downloadsByName.get("northstar-30-page-stress-report-html2realpdf.pdf"), "northstar-30-page-stress-report-html2realpdf.pdf");
  await expectPdfDownload(downloadsByName.get("northstar-30-page-stress-report-html2pdfjs.pdf"), "northstar-30-page-stress-report-html2pdfjs.pdf");

  const warmBefore = await page.locator('#react-benchmark-results tr[data-engine="html2pdfjs"] [data-metric="warm"]').getAttribute("data-value");
  const individualDownloadPromise = page.waitForEvent("download");
  await page.locator('#react-benchmark-results tr[data-engine="html2pdfjs"]').getByRole("button", { name: "Download" }).click();
  await expectPdfDownload(await individualDownloadPromise, "northstar-30-page-stress-report-html2pdfjs.pdf");
  await expect(page.locator('#react-benchmark-results tr[data-engine="html2pdfjs"] [data-metric="warm"]')).toHaveAttribute("data-value", warmBefore);
  expect(failures, failures.join("\n")).toEqual([]);
});
