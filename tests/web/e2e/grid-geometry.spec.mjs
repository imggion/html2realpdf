import { expect, test } from "@playwright/test";

const CSS_PX_TO_PDF_PT = 0.75;
const PAGE_HEIGHT_CSS_PX = 400;
const GEOMETRY_TOLERANCE_CSS_PX = 0.75;

test("Web Grid geometry matches Chromium and remains vector PDF content", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential geometry reference");
  await page.goto("/tests/web/index.html");

  const comparison = await page.evaluate(async ({ cssPxToPdfPt, pageHeightCssPx }) => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "width:600px;background:#fff";
    fixture.innerHTML = `
      <section style="display:grid;width:600px;grid-template-columns:repeat(3,minmax(0,1fr));grid-template-rows:70px 90px;grid-template-areas:'hero hero kpi' 'side main main';gap:12px 18px">
        <div data-color="#dc2626" style="grid-area:hero;background:#dc2626"></div>
        <div data-color="#7c3aed" style="grid-area:kpi;justify-self:end;width:120px;background:#7c3aed"></div>
        <div data-color="#0891b2" style="grid-area:side;align-self:center;height:44px;background:#0891b2"></div>
        <div data-color="#16a34a" style="display:grid;grid-area:main;grid-template-columns:1fr 1fr;gap:6px;padding:6px;background:#16a34a">
          <div data-color="#ea580c" style="background:#ea580c"></div>
          <div data-color="#2563eb" style="background:#2563eb"></div>
        </div>
      </section>
      <section style="display:grid;width:600px;grid-template-columns:repeat(4,1fr);grid-auto-rows:55px;grid-auto-flow:row dense;gap:10px;margin-top:20px">
        <div data-color="#ca8a04" style="grid-column:span 2;background:#ca8a04"></div>
        <div data-color="#db2777" style="background:#db2777"></div>
        <div data-color="#475569" style="background:#475569"></div>
        <div data-color="#0d9488" style="grid-column:span 3;background:#0d9488"></div>
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
