import { expect, test } from "@playwright/test";

test("invoice summary values remain inside the PDF content box", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared PDF geometry reference");
  await page.goto("/tests/web/index.html");
  await page.click("#generate-complex-invoice");
  await page.waitForFunction(() => document.querySelector("#pdf-status")?.textContent?.includes("Colored invoice generated:"));

  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const bytes = window.__html2realpdfLastPdf.slice();
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const documentHandle = await pdfjs.getDocument({ data: bytes }).promise;
    const pdfPage = await documentHandle.getPage(1);
    const text = await pdfPage.getTextContent();
    const summary = text.items
      .filter((item) => ["Subtotal", "€30,600", "Service credit", "- €1,500", "VAT 20%", "€5,820", "Total due", "€34,920"].includes(item.str))
      .map((item) => ({ text: item.str, left: item.transform[4], right: item.transform[4] + item.width }));
    const pageRight = pdfPage.view[2];
    await documentHandle.destroy();
    return { summary, pageRight };
  });

  expect(result.summary.map((item) => item.text)).toEqual([
    "Subtotal", "€30,600", "Service credit", "- €1,500", "VAT 20%", "€5,820", "Total due", "€34,920",
  ]);
  for (const item of result.summary) expect(item.right).toBeLessThanOrEqual(result.pageRight - 36 + 0.5);
  for (let index = 0; index < result.summary.length; index += 2) {
    expect(result.summary[index + 1].left).toBeGreaterThan(result.summary[index].right);
  }
});
