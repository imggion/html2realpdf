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
