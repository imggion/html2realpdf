import { expect, test } from "@playwright/test";

const CSS_PX_TO_PDF_PT = 0.75;
const PAGE_HEIGHT_CSS_PX = 400;
const GEOMETRY_TOLERANCE_CSS_PX = 0.75;

test("Web flex geometry matches Chromium and remains vector PDF content", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential geometry reference");
  await page.goto("/tests/web/index.html");

  const comparison = await page.evaluate(async ({ cssPxToPdfPt, pageHeightCssPx }) => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "width:600px;background:#fff";
    fixture.innerHTML = `
      <nav style="display:flex;width:600px;height:60px;align-items:center">
        <div data-color="#e11d48" style="width:100px;height:30px;background:#e11d48"></div>
        <div data-color="#0891b2" style="width:80px;height:24px;margin-left:auto;background:#0891b2"></div>
      </nav>
      <section style="display:flex;flex-wrap:wrap;width:600px;gap:12px 18px;margin-top:20px;align-content:flex-start">
        <div data-color="#7c3aed" style="flex:1 1 180px;height:70px;background:#7c3aed"></div>
        <div data-color="#ea580c" style="flex:1 1 180px;height:70px;background:#ea580c"></div>
        <div data-color="#16a34a" style="flex:1 1 180px;height:70px;background:#16a34a"></div>
        <div data-color="#2563eb" style="flex:1 1 180px;height:70px;background:#2563eb"></div>
        <div data-color="#ca8a04" style="flex:1 1 180px;height:70px;background:#ca8a04"></div>
      </section>
    `;
    document.body.append(fixture);
    const rootRect = fixture.getBoundingClientRect();
    const browserRects = [...fixture.querySelectorAll("[data-color]")].map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        color: element.dataset.color,
        x: rect.x - rootRect.x,
        y: rect.y - rootRect.y,
        width: rect.width,
        height: rect.height,
      };
    });

    const pdf = await pkg.renderPdf(fixture, {
      cssProfile: "web",
      page: { format: [600, pageHeightCssPx], unit: "px", margin: 0 },
      viewport: { width: 600, height: pageHeightCssPx },
      unsupportedCss: "error",
      execution: "main",
    });
    const bytes = pdf.toUint8Array();
    pdf.dispose();
    fixture.remove();

    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const loadingTask = pdfjs.getDocument({ data: bytes });
    const documentHandle = await loadingTask.promise;
    const pdfPage = await documentHandle.getPage(1);
    const operatorList = await pdfPage.getOperatorList();
    const targetColors = new Set(browserRects.map((rect) => rect.color));
    const pdfRects = [];
    let fillColor = null;
    let containsRasterImage = false;
    for (let index = 0; index < operatorList.fnArray.length; index += 1) {
      const operator = operatorList.fnArray[index];
      const args = operatorList.argsArray[index];
      if (operator === pdfjs.OPS.setFillRGBColor) fillColor = args[0];
      if (operator === pdfjs.OPS.paintImageXObject || operator === pdfjs.OPS.paintInlineImageXObject) containsRasterImage = true;
      if (operator !== pdfjs.OPS.constructPath || !targetColors.has(fillColor)) continue;
      const [left, bottom, right, top] = Array.from(args[2]);
      pdfRects.push({
        color: fillColor,
        x: left / cssPxToPdfPt,
        y: pageHeightCssPx - top / cssPxToPdfPt,
        width: (right - left) / cssPxToPdfPt,
        height: (top - bottom) / cssPxToPdfPt,
      });
    }
    await documentHandle.destroy();
    return { browserRects, pdfRects, containsRasterImage };
  }, { cssPxToPdfPt: CSS_PX_TO_PDF_PT, pageHeightCssPx: PAGE_HEIGHT_CSS_PX });

  expect(comparison.containsRasterImage).toBe(false);
  expect(comparison.pdfRects).toHaveLength(comparison.browserRects.length);
  for (const browserRect of comparison.browserRects) {
    const pdfRect = comparison.pdfRects.find((candidate) => candidate.color === browserRect.color);
    expect(pdfRect, `missing PDF vector rectangle ${browserRect.color}`).toBeTruthy();
    for (const field of ["x", "y", "width", "height"]) {
      expect(Math.abs(pdfRect[field] - browserRect[field]), `${browserRect.color} ${field}`).toBeLessThanOrEqual(GEOMETRY_TOLERANCE_CSS_PX);
    }
  }
});
