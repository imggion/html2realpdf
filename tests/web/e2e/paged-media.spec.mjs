import { expect, test } from "@playwright/test";

test("default @page size orientation and margins reach PDF geometry", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await pkg.createRenderer({ execution: "main" });
    const html = `
      <style>
        @page { size: A5 landscape; margin: 10mm !important; }
        @page { margin: 20mm; margin-left: 15mm !important; }
      </style>
      <p style="margin:0;font:16px/20px Noto Sans">CSS paged media</p>`;

    const inspect = async (pdf) => {
      const bytes = pdf.toUint8Array();
      const diagnostics = pdf.diagnostics;
      const source = new TextDecoder("latin1").decode(bytes);
      const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
      pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
      const loadingTask = pdfjs.getDocument({ data: bytes });
      const documentHandle = await loadingTask.promise;
      const firstPage = await documentHandle.getPage(1);
      const viewport = firstPage.getViewport({ scale: 1 });
      const text = await firstPage.getTextContent();
      const item = text.items.find((candidate) => "str" in candidate && candidate.str.includes("CSS paged media"));
      const summary = {
        diagnostics,
        mediaBox: source.match(/\/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]/)?.slice(1).map(Number) ?? [],
        viewport: [viewport.width, viewport.height],
        textX: item && "transform" in item ? item.transform[4] : null,
      };
      await documentHandle.destroy();
      pdf.dispose();
      return summary;
    };

    const cssPage = await inspect(await renderer.render(html, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
    }));
    const apiPage = await inspect(await renderer.render(html, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
      page: { format: [400, 500], unit: "px", margin: 0 },
    }));
    renderer.dispose();
    return { cssPage, apiPage };
  });

  expect(result.cssPage.diagnostics).toEqual([]);
  expect(result.cssPage.mediaBox[0]).toBeCloseTo(595.2756, 2);
  expect(result.cssPage.mediaBox[1]).toBeCloseTo(419.5276, 2);
  expect(result.cssPage.viewport[0]).toBeCloseTo(595.2756, 2);
  expect(result.cssPage.viewport[1]).toBeCloseTo(419.5276, 2);
  expect(result.cssPage.textX).toBeCloseTo(15 * 72 / 25.4, 2);

  expect(result.apiPage.diagnostics).toEqual([]);
  expect(result.apiPage.mediaBox[0]).toBeCloseTo(300, 3);
  expect(result.apiPage.mediaBox[1]).toBeCloseTo(375, 3);
  expect(result.apiPage.textX).toBeCloseTo(0, 3);
});

test("@page margin boxes render selectable page counters", async ({ page }) => {
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
        @media print {
          @page {
            size: 200px 100px;
            margin: 12px 10px;
            @top-center { content: "Quarterly report"; font-family: Noto Sans; font-size: 8px; font-weight: bold; }
            @bottom-center { content: "Page " counter(page) " of " counter(pages); font-family: Noto Sans; font-size: 8px; color: #334155; }
          }
        }
        html, body { margin: 0; }
      </style>
      <div style="height:30px">FIRST</div>
      <div style="height:30px;break-before:page">SECOND</div>`, {
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
  expect(result.pages[0]).toContain("Quarterlyreport");
  expect(result.pages[0]).toContain("Page1of2");
  expect(result.pages[0]).toContain("FIRST");
  expect(result.pages[1]).toContain("Quarterlyreport");
  expect(result.pages[1]).toContain("Page2of2");
  expect(result.pages[1]).toContain("SECOND");
});

test("unsupported margin-box content follows warn and strict policy", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await pkg.createRenderer({ execution: "main" });
    const html = `<style>@page { margin: 20px; @top-center { content: attr(data-title); } }</style><p>Safe body</p>`;
    const pdf = await renderer.render(html, { cssProfile: "web", mediaType: "print", unsupportedCss: "warn" });
    const diagnostics = pdf.diagnostics;
    pdf.dispose();
    let strictError = "";
    try {
      await renderer.render(html, { cssProfile: "strict", mediaType: "print" });
    } catch (error) {
      strictError = error instanceof Error ? error.message : String(error);
    }
    renderer.dispose();
    return { diagnostics, strictError };
  });

  expect(result.diagnostics).toEqual([
    expect.objectContaining({
      code: "UNSUPPORTED_PAGED_MEDIA",
      property: "@top-center content",
      phase: "fragmentation",
      severity: "warning",
    }),
  ]);
  expect(result.strictError).toContain("@top-center content:attr(data-title)");
});

test("named @page selectors drive per-page PDF geometry and margins", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const html = `<style>
      @page { size: 200px 100px; margin: 0; }
      @page Report { size: 200px 100px; margin-left: 10px; }
      @page Summary { size: 300px 160px; margin-left: 20px; }
      html, body { margin: 0; }
      .report { page: Report; height: 20px; }
      .summary { page: Summary; }
      .summary-item { height: 70px; break-inside: avoid; }
    </style><div class="report">REPORT</div><section class="summary">
      <div class="summary-item">SUMMARY ONE</div>
      <div class="summary-item">SUMMARY TWO</div>
      <div class="summary-item">SUMMARY THREE</div>
    </section>`;
    const pdf = await renderer.render(html, { cssProfile: "web", mediaType: "print", unsupportedCss: "error" });
    const diagnostics = pdf.diagnostics;
    const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const viewport = current.getViewport({ scale: 1 });
      const text = await current.getTextContent();
      const items = text.items.filter((candidate) => "str" in candidate && (candidate.str.includes("REPORT") || candidate.str.includes("SUMMARY")));
      const item = items[0];
      pages.push({
        viewport: [viewport.width, viewport.height],
        text: items.flatMap((candidate) => "str" in candidate ? [candidate.str] : []).join(" "),
        x: item && "transform" in item ? item.transform[4] : null,
      });
    }
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return { diagnostics, pages };
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pages).toHaveLength(3);
  expect(result.pages[0].viewport[0]).toBeCloseTo(150, 2);
  expect(result.pages[0].viewport[1]).toBeCloseTo(75, 2);
  expect(result.pages[0].text).toContain("REPORT");
  expect(result.pages[0].x).toBeCloseTo(7.5, 2);
  expect(result.pages[1].viewport[0]).toBeCloseTo(225, 2);
  expect(result.pages[1].viewport[1]).toBeCloseTo(120, 2);
  expect(result.pages[1].text).toContain("SUMMARY ONE");
  expect(result.pages[1].text).toContain("SUMMARY TWO");
  expect(result.pages[1].x).toBeCloseTo(15, 2);
  expect(result.pages[2].viewport[0]).toBeCloseTo(225, 2);
  expect(result.pages[2].viewport[1]).toBeCloseTo(120, 2);
  expect(result.pages[2].text).toContain("SUMMARY THREE");
  expect(result.pages[2].x).toBeCloseTo(15, 2);
});

test("pseudo page width reflows selectable inline text", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(`<style>
      @page { size: 100px 40px; margin: 0; }
      @page :left { size: 200px 40px; }
      html, body, p { margin: 0; }
      p { font-size: 16px; line-height: 20px; }
    </style><p>MMMMMM MMMMMM MMMMMM MMMMMM MMMMMM MMMMMM</p>`, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
    });
    const diagnostics = pdf.diagnostics;
    const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const viewport = current.getViewport({ scale: 1 });
      const text = await current.getTextContent();
      const joined = text.items.flatMap((item) => "str" in item ? [item.str] : []).join(" ");
      pages.push({
        viewport: [viewport.width, viewport.height],
        words: joined.match(/MMMMMM/g)?.length ?? 0,
      });
    }
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return { diagnostics, pages };
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pages).toEqual([
    { viewport: [75, 30], words: 2 },
    { viewport: [150, 30], words: 4 },
  ]);
});

test(":blank page geometry applies to forced facing-page gaps", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(`<style>
      @page { size: 100px 100px; margin: 0; }
      @page :blank { size: 200px 150px; }
      html, body { margin: 0; }
    </style><div style="height:20px">FIRST</div><div style="height:20px;break-before:right">THIRD</div>`, {
      cssProfile: "web",
      mediaType: "print",
      unsupportedCss: "error",
    });
    const diagnostics = pdf.diagnostics;
    const documentHandle = await pdfjs.getDocument({ data: pdf.toUint8Array() }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= documentHandle.numPages; pageNumber += 1) {
      const current = await documentHandle.getPage(pageNumber);
      const viewport = current.getViewport({ scale: 1 });
      const text = await current.getTextContent();
      pages.push({
        viewport: [viewport.width, viewport.height],
        text: text.items.flatMap((item) => "str" in item ? [item.str] : []).join(" "),
      });
    }
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return { diagnostics, pages };
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pages).toHaveLength(3);
  expect(result.pages[0].viewport).toEqual([75, 75]);
  expect(result.pages[0].text).toContain("FIRST");
  expect(result.pages[1].viewport).toEqual([150, 112.5]);
  expect(result.pages[1].text).toBe("");
  expect(result.pages[2].viewport).toEqual([75, 75]);
  expect(result.pages[2].text).toContain("THIRD");
});

test("named and blank @page margin boxes select per page", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(`<style>
      @page { size: 160px 100px; margin: 12px; @top-center { content: "DEFAULT"; font-size: 8px; } }
      @page Report { @top-center { content: "REPORT HEAD"; font-size: 8px; } }
      @page Report:blank { @top-center { content: "BLANK HEAD"; font-size: 8px; } }
      @page Summary { @top-center { content: "SUMMARY HEAD"; font-size: 8px; } }
      html, body { margin: 0; }
    </style><div style="height:20px;page:Report">REPORT BODY</div>
    <div style="height:20px;page:Summary;break-before:right">SUMMARY BODY</div>`, {
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
      pages.push(text.items.flatMap((item) => "str" in item ? [item.str] : []).join(" "));
    }
    await documentHandle.destroy();
    pdf.dispose();
    renderer.dispose();
    return { diagnostics, pages };
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.pages).toHaveLength(3);
  expect(result.pages[0]).toContain("REPORT HEAD");
  expect(result.pages[0]).toContain("REPORT BODY");
  expect(result.pages[1]).toContain("BLANK HEAD");
  expect(result.pages[1]).not.toContain("BODY");
  expect(result.pages[2]).toContain("SUMMARY HEAD");
  expect(result.pages[2]).toContain("SUMMARY BODY");
});
