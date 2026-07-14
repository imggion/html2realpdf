import { expect, test } from "@playwright/test";

const CSS_PX_TO_PDF_PT = 0.75;
const PAGE_WIDTH_CSS_PX = 600;
const PAGE_HEIGHT_CSS_PX = 400;
const GEOMETRY_TOLERANCE_CSS_PX = 0.9;
const LINK_TEXT_TOLERANCE_CSS_PX = 1.25;

test("Web 2D transforms, origins, clipping, and link bounds match Chromium", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential geometry reference");
  await page.setViewportSize({ width: PAGE_WIDTH_CSS_PX, height: PAGE_HEIGHT_CSS_PX });
  await page.goto("/tests/web/index.html");

  const comparison = await page.evaluate(async ({ cssPxToPdfPt, pageWidthCssPx, pageHeightCssPx }) => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "position:relative;width:600px;height:360px;background:#fff";
    fixture.innerHTML = `
      <div data-color="#dc2626" style="position:absolute;left:30px;top:25px;width:120px;height:60px;transform:translate(18px,12px) rotate(15deg);transform-origin:0 0;background:#dc2626"></div>
      <div style="position:absolute;left:240px;top:35px;width:180px;height:100px;overflow:hidden;transform:rotate(-8deg);transform-origin:50% 50%;background:#e2e8f0">
        <div data-color="#16a34a" style="position:absolute;left:120px;top:18px;width:110px;height:58px;transform:scale(1.15,.8);transform-origin:0 0;background:#16a34a"></div>
      </div>
      <a data-link href="https://example.com/transformed" style="position:absolute;left:80px;top:190px;display:block;width:150px;height:36px;font-family:'Noto Sans',sans-serif;font-size:16px;line-height:18px;transform:skewX(12deg) translateX(24px);transform-origin:left top;background:#2563eb;color:#fff"><span data-link-text>X</span></a>
      <div data-color="#7c3aed" style="position:absolute;left:340px;top:210px;width:90px;height:50px;transform:matrix(1,.18,-.12,1,16,-8);transform-origin:20px 10px;background:#7c3aed"></div>
    `;
    document.body.append(fixture);
    fixture.scrollIntoView({ block: "start" });
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
    const linkRect = fixture.querySelector("[data-link-text]").getBoundingClientRect();
    const browserLink = {
      x: linkRect.x - rootRect.x,
      y: linkRect.y - rootRect.y,
      width: linkRect.width,
      height: linkRect.height,
    };

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
    const pdfPage = await documentHandle.getPage(1);
    const operatorList = await pdfPage.getOperatorList();
    const targetColors = new Set(browserRects.map((rect) => rect.color));
    const pdfRects = [];
    const stack = [];
    let matrix = [1, 0, 0, 1, 0, 0];
    let fillColor = null;
    let containsRasterImage = false;
    let clipCount = 0;
    for (let index = 0; index < operatorList.fnArray.length; index += 1) {
      const operator = operatorList.fnArray[index];
      const args = operatorList.argsArray[index];
      if (operator === pdfjs.OPS.save) stack.push([...matrix]);
      if (operator === pdfjs.OPS.restore) matrix = stack.pop() ?? [1, 0, 0, 1, 0, 0];
      if (operator === pdfjs.OPS.transform) matrix = Array.from(args);
      if (operator === pdfjs.OPS.setFillRGBColor) fillColor = args[0];
      if (operator === pdfjs.OPS.paintImageXObject || operator === pdfjs.OPS.paintInlineImageXObject) containsRasterImage = true;
      if (operator === pdfjs.OPS.clip || operator === pdfjs.OPS.eoClip) clipCount += 1;
      if (operator !== pdfjs.OPS.constructPath || !targetColors.has(fillColor)) continue;
      const [left, bottom, right, top] = Array.from(args[2]);
      const points = [[left, bottom], [right, bottom], [right, top], [left, top]].map(([x, y]) => ({
        x: matrix[0] * x + matrix[2] * y + matrix[4],
        y: matrix[1] * x + matrix[3] * y + matrix[5],
      }));
      const minX = Math.min(...points.map((point) => point.x));
      const maxX = Math.max(...points.map((point) => point.x));
      const minY = Math.min(...points.map((point) => point.y));
      const maxY = Math.max(...points.map((point) => point.y));
      pdfRects.push({
        color: fillColor,
        x: minX / cssPxToPdfPt,
        y: pageHeightCssPx - maxY / cssPxToPdfPt,
        width: (maxX - minX) / cssPxToPdfPt,
        height: (maxY - minY) / cssPxToPdfPt,
      });
    }
    const annotations = await pdfPage.getAnnotations();
    const linkRects = annotations.map((annotation) => annotation.rect);
    const pdfLink = linkRects.length > 0 ? (() => {
      const left = Math.min(...linkRects.map((rect) => rect[0]));
      const bottom = Math.min(...linkRects.map((rect) => rect[1]));
      const right = Math.max(...linkRects.map((rect) => rect[2]));
      const top = Math.max(...linkRects.map((rect) => rect[3]));
      return {
        x: left / cssPxToPdfPt,
        y: pageHeightCssPx - top / cssPxToPdfPt,
        width: (right - left) / cssPxToPdfPt,
        height: (top - bottom) / cssPxToPdfPt,
      };
    })() : null;
    await documentHandle.destroy();
    return {
      browserRects,
      browserLink,
      pdfRects,
      pdfLink,
      annotationSummary: annotations.map((annotation) => ({ subtype: annotation.subtype, url: annotation.url, rect: annotation.rect })),
      containsRasterImage,
      clipCount,
    };
  }, { cssPxToPdfPt: CSS_PX_TO_PDF_PT, pageWidthCssPx: PAGE_WIDTH_CSS_PX, pageHeightCssPx: PAGE_HEIGHT_CSS_PX });

  expect(comparison.containsRasterImage).toBe(false);
  expect(comparison.clipCount).toBeGreaterThan(0);
  for (const browserRect of comparison.browserRects) {
    const pdfRect = comparison.pdfRects.find((candidate) => candidate.color === browserRect.color);
    expect(pdfRect, `missing transformed PDF vector ${browserRect.color}`).toBeTruthy();
    for (const field of ["x", "y", "width", "height"]) {
      expect(Math.abs(pdfRect[field] - browserRect[field]), `${browserRect.color} ${field}`).toBeLessThanOrEqual(GEOMETRY_TOLERANCE_CSS_PX);
    }
  }
  expect(comparison.pdfLink, JSON.stringify(comparison.annotationSummary)).toBeTruthy();
  for (const field of ["x", "y", "width", "height"]) {
    expect(Math.abs(comparison.pdfLink[field] - comparison.browserLink[field]), `link ${field}`).toBeLessThanOrEqual(LINK_TEXT_TOLERANCE_CSS_PX);
  }
});
