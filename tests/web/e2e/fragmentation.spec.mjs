import { expect, test } from "@playwright/test";

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
