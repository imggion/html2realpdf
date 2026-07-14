import { expect, test } from "@playwright/test";
import {
  REPORT360_FRAGMENTATION_FIXTURE_HTML,
  REPORT360_FRAGMENTATION_PAGE,
} from "../report360-fragmentation-fixture.js";

const CSS_PX_TO_PDF_PT = 0.75;

test("CSS fragmentation reaches real PDF page assignments", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });

    const inspect = async (html) => {
      const pdf = await renderer.render(html, {
        cssProfile: "web",
        mediaType: "print",
        unsupportedCss: "error",
      });
      const diagnostics = pdf.diagnostics;
      const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
      const pages = [];
      for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
        const current = await documentHandle.getPage(pageNumber);
        const text = await current.getTextContent();
        pages.push(text.items.flatMap((item) => "str" in item ? [item.str] : []));
      }
      const summary = { diagnostics, pageCount: documentHandle.numPages, pages };
      await documentHandle.destroy();
      pdf.dispose();
      return summary;
    };

    const ltr = await inspect(`
      <style>
        @page { size: 200px 100px; margin: 0; }
        html, body { margin: 0; }
      </style>
      <div style="height:70px"></div>
      <div style="height:20px;break-after:avoid;background:#fee2e2">KEEP-A</div>
      <div style="height:20px;background:#dbeafe">KEEP-B</div>
      <div style="height:20px;break-before:right;background:#dcfce7">RIGHT-PAGE</div>
      <div style="height:20px;break-before:left;background:#fef3c7">LEFT-PAGE</div>`);

    const rtl = await inspect(`
      <style>
        @page { size: 200px 100px; margin: 0; }
        html, body { margin: 0; direction: rtl; }
      </style>
      <div style="height:10px"></div>
      <div style="height:20px;break-before:left">LEFT-PAGE</div>
      <div style="height:20px;break-before:right">RIGHT-PAGE</div>`);

    renderer.dispose();
    return { ltr, rtl };
  });

  expect(result.ltr.diagnostics).toEqual([]);
  expect(result.ltr.pageCount).toBe(4);
  expect(result.ltr.pages[0]).toEqual([]);
  expect(result.ltr.pages[1].join("").replaceAll(" ", "")).toContain("KEEP-A");
  expect(result.ltr.pages[1].join("").replaceAll(" ", "")).toContain("KEEP-B");
  expect(result.ltr.pages[2].join("").replaceAll(" ", "")).toContain("RIGHT-PAGE");
  expect(result.ltr.pages[3].join("").replaceAll(" ", "")).toContain("LEFT-PAGE");

  expect(result.rtl.diagnostics).toEqual([]);
  expect(result.rtl.pageCount).toBe(3);
  expect(result.rtl.pages[1].join("").replaceAll(" ", "")).toContain("LEFT-PAGE");
  expect(result.rtl.pages[2].join("").replaceAll(" ", "")).toContain("RIGHT-PAGE");
});

test("table header and footer groups repeat in the real PDF", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(`
      <style>
        @page { size: 200px 100px; margin: 0; }
        html, body { margin: 0; }
        table { width: 200px; border-collapse: collapse; font-family: Noto Sans; font-size: 10px; line-height: 10px; }
        th, td { padding: 0; }
        thead tr, tfoot tr { height: 20px; }
        tbody tr { height: 30px; }
      </style>
      <table>
        <thead><tr><th>HEAD</th></tr></thead>
        <tfoot><tr><td>FOOT</td></tr></tfoot>
        <tbody><tr><td>ONE</td></tr><tr><td>TWO</td></tr><tr><td>THREE</td></tr></tbody>
      </table>`, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
    });
    const diagnostics = pdf.diagnostics;
    const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const text = await current.getTextContent();
      pages.push(text.items.flatMap((item) => "str" in item ? [item.str] : []).join("").replaceAll(" ", ""));
    }
    const summary = { diagnostics, pageCount: documentHandle.numPages, pages };
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return summary;
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pageCount).toBe(2);
  expect(result.pages[0]).toContain("HEAD");
  expect(result.pages[0]).toContain("FOOT");
  expect(result.pages[0]).toContain("ONE");
  expect(result.pages[0]).toContain("TWO");
  expect(result.pages[1]).toContain("HEAD");
  expect(result.pages[1]).toContain("FOOT");
  expect(result.pages[1]).toContain("THREE");
});

test("Report 360 legend and auto-height table rows fragment without duplicate content", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async ({ fixtureHtml, pageSize, cssPxToPdfPt }) => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;

    const fixture = document.createElement("section");
    fixture.className = "report360-regression";
    fixture.innerHTML = fixtureHtml;
    document.body.append(fixture);
    const pdf = await pkg.renderPdf(fixture, {
      cssProfile: "web",
      mediaType: "print",
      page: { format: [pageSize.width, pageSize.height], unit: "px", margin: 0 },
      viewport: { width: pageSize.width, height: pageSize.height },
      unsupportedCss: "error",
      execution: "main",
    });
    const diagnostics = pdf.diagnostics;
    const bytes = pdf.toUint8Array();
    pdf.dispose();
    fixture.remove();

    const documentHandle = await pdfjs.getDocument({ data: bytes }).promise;
    const pages = [];
    const trackedColors = new Set(["#47775c", "#e8eef5", "#f4eadf", "#e7f4ec", "#20c56a", "#f0b400"]);
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const textContent = await current.getTextContent();
      const operators = await current.getOperatorList();
      const text = textContent.items.flatMap((item) => {
        if (!("str" in item) || !item.str.trim()) return [];
        const height = item.height / cssPxToPdfPt;
        return [{
          value: item.str.trim(),
          x: item.transform[4] / cssPxToPdfPt,
          y: pageSize.height - (item.transform[5] + item.height) / cssPxToPdfPt,
          width: item.width / cssPxToPdfPt,
          height,
        }];
      });
      const paths = [];
      let fillColor = null;
      let clipCount = 0;
      let containsRasterImage = false;
      for (let index = 0; index < operators.fnArray.length; index += 1) {
        const operator = operators.fnArray[index];
        const args = operators.argsArray[index];
        if (operator === pdfjs.OPS.setFillRGBColor) fillColor = args[0];
        if (operator === pdfjs.OPS.clip || operator === pdfjs.OPS.eoClip) clipCount += 1;
        if (operator === pdfjs.OPS.paintImageXObject || operator === pdfjs.OPS.paintInlineImageXObject) containsRasterImage = true;
        if (operator !== pdfjs.OPS.constructPath || !trackedColors.has(fillColor)) continue;
        const [left, bottom, right, top] = Array.from(args[2]);
        paths.push({
          color: fillColor,
          x: left / cssPxToPdfPt,
          y: pageSize.height - top / cssPxToPdfPt,
          width: (right - left) / cssPxToPdfPt,
          height: (top - bottom) / cssPxToPdfPt,
        });
      }
      pages.push({ text, paths, clipCount, containsRasterImage });
    }
    await documentHandle.destroy();
    return { diagnostics, pageCount: pages.length, pages };
  }, {
    fixtureHtml: REPORT360_FRAGMENTATION_FIXTURE_HTML,
    pageSize: REPORT360_FRAGMENTATION_PAGE,
    cssPxToPdfPt: CSS_PX_TO_PDF_PT,
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pageCount).toBe(2);
  expect(result.pages.every((pdfPage) => !pdfPage.containsRasterImage)).toBe(true);
  expect(result.pages.reduce((total, pdfPage) => total + pdfPage.clipCount, 0)).toBeGreaterThanOrEqual(2);

  const occurrences = (value) => result.pages.flatMap((pdfPage, pageIndex) =>
    pdfPage.text.filter((item) => item.value === value).map((item) => ({ ...item, pageIndex })));
  expect(occurrences("SUBDIMENSION")).toHaveLength(2);
  expect(occurrences("SUBDIMENSION").map((item) => item.pageIndex)).toEqual([0, 1]);
  expect(occurrences("LEGEND")).toHaveLength(1);
  expect(occurrences("LEGEND")[0].pageIndex).toBe(0);
  expect(occurrences("ROW-1")).toHaveLength(1);
  expect(occurrences("ROW-1")[0].pageIndex).toBe(0);
  expect(occurrences("ROW-2")).toHaveLength(1);
  expect(occurrences("ROW-2")[0].pageIndex).toBe(1);
  expect(occurrences("ROW-3")).toHaveLength(1);
  expect(occurrences("ROW-3")[0].pageIndex).toBe(1);
  expect(occurrences("N.R.")).toHaveLength(2);
  expect(occurrences("N.R.").map((item) => item.pageIndex)).toEqual([0, 1]);

  const pageTwoHeader = occurrences("SUBDIMENSION")[1];
  const rowTwoText = occurrences("ROW-2")[0];
  const rowThreeText = occurrences("ROW-3")[0];
  expect(pageTwoHeader.y).toBeLessThan(rowTwoText.y);
  expect(rowTwoText.y).toBeLessThan(rowThreeText.y);

  const rowColors = new Map([
    ["ROW-1", "#e8eef5"],
    ["ROW-2", "#f4eadf"],
    ["ROW-3", "#e7f4ec"],
  ]);
  for (const [label, color] of rowColors) {
    const item = occurrences(label)[0];
    const rowRect = result.pages[item.pageIndex].paths.find((path) => path.color === color);
    expect(rowRect, `missing vector row rectangle for ${label}`).toBeTruthy();
    expect(item.y).toBeGreaterThanOrEqual(rowRect.y - 1);
    expect(item.y + item.height).toBeLessThanOrEqual(rowRect.y + rowRect.height + 1);
    expect(rowRect.y).toBeGreaterThanOrEqual(0);
    expect(rowRect.y + rowRect.height).toBeLessThanOrEqual(REPORT360_FRAGMENTATION_PAGE.height + 1);
  }

  const rowTwoStatus = occurrences("N.R.").find((item) => item.pageIndex === 1);
  const rowTwoRect = result.pages[1].paths.find((path) => path.color === "#f4eadf");
  expect(rowTwoStatus.y).toBeGreaterThanOrEqual(rowTwoRect.y - 1);
  expect(rowTwoStatus.y + rowTwoStatus.height).toBeLessThanOrEqual(rowTwoRect.y + rowTwoRect.height + 1);
  expect(result.pages.flatMap((pdfPage) => pdfPage.paths).filter((path) => path.color === "#20c56a")).toHaveLength(2);
  expect(result.pages.flatMap((pdfPage) => pdfPage.paths).filter((path) => path.color === "#f0b400")).toHaveLength(1);
});

test("fixed page furniture repeats at both page edges", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(`
      <style>
        @page { size: 200px 100px; margin: 0; }
        html, body { margin: 0; }
        .fixed-head, .fixed-foot { position: fixed; left: 0; height: 20px; font-size: 10px; line-height: 10px; }
        .fixed-head { top: 0; }
        .fixed-foot { bottom: 20px; }
      </style>
      <div class="fixed-head">FIXED-HEAD</div>
      <div class="fixed-foot">FIXED-FOOT</div>
      <div style="height:80px">PAGE-ONE</div><div style="height:80px;break-before:page">PAGE-TWO</div>`, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
    });
    const diagnostics = pdf.diagnostics;
    const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const text = await current.getTextContent();
      pages.push(text.items.flatMap((item) => "str" in item ? [item.str] : []).join("").replaceAll(" ", ""));
    }
    const summary = { diagnostics, pageCount: documentHandle.numPages, pages };
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return summary;
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pageCount).toBe(2);
  for (const pageText of result.pages) {
    expect(pageText).toContain("FIXED-HEAD");
    expect(pageText).toContain("FIXED-FOOT");
  }
});
