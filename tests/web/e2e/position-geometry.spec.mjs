import { expect, test } from "@playwright/test";

const CSS_PX_TO_PDF_PT = 0.75;
const PAGE_WIDTH_CSS_PX = 600;
const PAGE_HEIGHT_CSS_PX = 400;
const GEOMETRY_TOLERANCE_CSS_PX = 0.75;

test("Web positioned geometry, stacking, clipping, and fixed repetition match Chromium", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential geometry reference");
  await page.setViewportSize({ width: PAGE_WIDTH_CSS_PX, height: PAGE_HEIGHT_CSS_PX });
  await page.goto("/tests/web/index.html");

  const comparison = await page.evaluate(async ({ cssPxToPdfPt, pageWidthCssPx, pageHeightCssPx }) => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "position:relative;width:600px;min-height:850px;background:#fff";
    fixture.innerHTML = `
      <div data-geometry data-color="#dc2626" style="position:relative;left:14px;top:9px;width:80px;height:30px;background:#dc2626"></div>
      <div data-geometry data-color="#0891b2" style="width:40px;height:20px;background:#0891b2"></div>
      <div style="position:relative;width:300px;height:140px;padding:20px;background:#f1f5f9">
        <div data-geometry data-color="#7c3aed" style="position:absolute;left:15px;right:25px;top:18px;height:30px;background:#7c3aed"></div>
        <div data-geometry data-color="#ea580c" style="position:absolute;left:20px;right:20px;top:60px;width:100px;height:28px;margin-left:auto;margin-right:auto;background:#ea580c"></div>
      </div>
      <div style="position:relative;width:160px;height:45px;overflow:hidden;background:#e2e8f0">
        <div data-geometry data-color="#16a34a" style="position:absolute;left:120px;top:8px;width:80px;height:28px;background:#16a34a"></div>
      </div>
      <div style="position:absolute;left:390px;top:70px;width:110px;height:80px">
        <div data-stack="lower" data-color="#ca8a04" style="position:absolute;inset:0;z-index:1;background:#ca8a04"></div>
        <div data-stack="upper" data-color="#2563eb" style="position:absolute;left:15px;top:15px;width:80px;height:50px;z-index:5;opacity:.55;background:#2563eb"></div>
      </div>
      <div data-fixed data-color="#db2777" style="position:fixed;right:10px;top:8px;width:90px;height:22px;z-index:20;background:#db2777"></div>
      <div style="height:160px;background:#f8fafc"></div>
      <div style="break-before:page;height:120px;background:#f8fafc"></div>
      <div style="break-before:page;height:120px;background:#f8fafc"></div>
    `;
    document.body.append(fixture);
    fixture.scrollIntoView({ block: "start" });
    const rootRect = fixture.getBoundingClientRect();
    const browserRects = [...fixture.querySelectorAll("[data-geometry]")].map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        color: element.dataset.color,
        x: rect.x - rootRect.x,
        y: rect.y - rootRect.y,
        width: rect.width,
        height: rect.height,
      };
    });
    const fixedRect = fixture.querySelector("[data-fixed]").getBoundingClientRect();
    const browserFixedRect = {
      color: fixture.querySelector("[data-fixed]").dataset.color,
      x: fixedRect.x,
      y: fixedRect.y,
      width: fixedRect.width,
      height: fixedRect.height,
    };
    const overlapPoint = {
      x: rootRect.x + 390 + 50,
      y: rootRect.y + 70 + 40,
    };
    const browserTopLayer = document.elementFromPoint(overlapPoint.x, overlapPoint.y)?.dataset.stack;

    const pdf = await pkg.renderPdf(fixture, {
      cssProfile: "web",
      page: { format: [pageWidthCssPx, pageHeightCssPx], unit: "px", margin: 0 },
      viewport: { width: pageWidthCssPx, height: pageHeightCssPx },
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
    const targetColors = new Set([
      ...browserRects.map((rect) => rect.color),
      browserFixedRect.color,
      "#ca8a04",
      "#2563eb",
    ]);
    const pages = [];
    let containsRasterImage = false;
    let opacityStateCount = 0;
    let clipCount = 0;
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const pdfPage = await documentHandle.getPage(pageNumber);
      const operatorList = await pdfPage.getOperatorList();
      const rectangles = [];
      let fillColor = null;
      for (let index = 0; index < operatorList.fnArray.length; index += 1) {
        const operator = operatorList.fnArray[index];
        const args = operatorList.argsArray[index];
        if (operator === pdfjs.OPS.setFillRGBColor) fillColor = args[0];
        if (operator === pdfjs.OPS.paintImageXObject || operator === pdfjs.OPS.paintInlineImageXObject) containsRasterImage = true;
        if (operator === pdfjs.OPS.setGState) opacityStateCount += 1;
        if (operator === pdfjs.OPS.clip || operator === pdfjs.OPS.eoClip) clipCount += 1;
        if (operator !== pdfjs.OPS.constructPath || !targetColors.has(fillColor)) continue;
        const [left, bottom, right, top] = Array.from(args[2]);
        rectangles.push({
          color: fillColor,
          x: left / cssPxToPdfPt,
          y: pageHeightCssPx - top / cssPxToPdfPt,
          width: (right - left) / cssPxToPdfPt,
          height: (top - bottom) / cssPxToPdfPt,
        });
      }
      pages.push(rectangles);
    }
    await documentHandle.destroy();
    return {
      browserRects,
      browserFixedRect,
      browserTopLayer,
      pages,
      containsRasterImage,
      opacityStateCount,
      clipCount,
    };
  }, {
    cssPxToPdfPt: CSS_PX_TO_PDF_PT,
    pageWidthCssPx: PAGE_WIDTH_CSS_PX,
    pageHeightCssPx: PAGE_HEIGHT_CSS_PX,
  });

  expect(comparison.containsRasterImage).toBe(false);
  expect(comparison.browserTopLayer).toBe("upper");
  expect(comparison.pages.length).toBeGreaterThanOrEqual(2);
  expect(comparison.opacityStateCount).toBeGreaterThan(0);
  expect(comparison.clipCount).toBeGreaterThan(0);

  for (const browserRect of comparison.browserRects) {
    const pdfRect = comparison.pages[0].find((candidate) => candidate.color === browserRect.color);
    expect(pdfRect, `missing PDF vector rectangle ${browserRect.color}`).toBeTruthy();
    for (const field of ["x", "y", "width", "height"]) {
      expect(Math.abs(pdfRect[field] - browserRect[field]), `${browserRect.color} ${field}`).toBeLessThanOrEqual(GEOMETRY_TOLERANCE_CSS_PX);
    }
  }

  for (const pageRects of comparison.pages) {
    const fixedRect = pageRects.find((candidate) => candidate.color === comparison.browserFixedRect.color);
    expect(fixedRect, "fixed vector rectangle must be repeated on every PDF page").toBeTruthy();
    for (const field of ["x", "y", "width", "height"]) {
      expect(Math.abs(fixedRect[field] - comparison.browserFixedRect[field]), `fixed ${field}`).toBeLessThanOrEqual(GEOMETRY_TOLERANCE_CSS_PX);
    }
  }

  const firstPageStackOrder = comparison.pages[0]
    .filter((rect) => rect.color === "#ca8a04" || rect.color === "#2563eb")
    .map((rect) => rect.color);
  expect(firstPageStackOrder).toEqual(["#ca8a04", "#2563eb"]);
});
