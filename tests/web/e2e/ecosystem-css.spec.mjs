import { expect, test } from "@playwright/test";

test("compiled CSS ecosystems render as native selectable PDF content", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("section");
    fixture.innerHTML = `
      <style>
        .ReportCard_title__4f91b { color:#1d4ed8; font-size:24px; margin:0; }
        .sc-kpDqfm.hYpRjR { background:#f5f3ff; border:2px solid #7c3aed; border-radius:12px; padding:12px; }
        .tw-grid { display:grid; }
        .md\\:grid-cols-3 { grid-template-columns:repeat(3,minmax(0,1fr)); }
        .tw-gap-3 { gap:12px; }
        .tw-p-4 { padding:16px; }
        .tw-bg-white { background:#fff; }
        .tw-text-sm { font-size:14px; }
      </style>
      <article class="tw-grid md:grid-cols-3 tw-gap-3 tw-p-4 tw-bg-white" style="width:540px">
        <div>
          <h1 class="ReportCard_title__4f91b">CSS Modules compiled class</h1>
        </div>
        <div class="sc-kpDqfm hYpRjR tw-text-sm">styled-components generated classes</div>
        <div class="tw-text-sm">Tailwind utility selectors</div>
      </article>`;
    document.body.append(fixture);

    const article = fixture.querySelector("article");
    const title = fixture.querySelector("h1");
    const styled = fixture.querySelector(".sc-kpDqfm");
    const articleStyle = getComputedStyle(article);
    const browserStyles = {
      display: articleStyle.display,
      columnCount: articleStyle.gridTemplateColumns.split(" ").length,
      titleColor: getComputedStyle(title).color,
      styledBorderWidth: getComputedStyle(styled).borderTopWidth,
    };

    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(fixture, {
      cssProfile: "web",
      mediaType: "print",
      page: { format: [580, 220], unit: "px", margin: 0 },
      viewport: { width: 580, height: 220 },
      unsupportedCss: "error",
      fallback: "error",
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    pdf.dispose();
    renderer.dispose();
    fixture.remove();

    const pdfSource = new TextDecoder("latin1").decode(bytes);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const loadingTask = pdfjs.getDocument({ data: bytes });
    const documentHandle = await loadingTask.promise;
    const pdfPage = await documentHandle.getPage(1);
    const textContent = await pdfPage.getTextContent();
    const text = textContent.items.map((item) => item.str).join(" ").replace(/\s+/g, " ");
    await documentHandle.destroy();

    return {
      browserStyles,
      diagnostics,
      text,
      hasImageObject: pdfSource.includes("/Subtype /Image"),
      hasUnicodeMap: pdfSource.includes("/ToUnicode"),
    };
  });

  expect(result.browserStyles).toEqual({
    display: "grid",
    columnCount: 3,
    titleColor: "rgb(29, 78, 216)",
    styledBorderWidth: "2px",
  });
  expect(result.diagnostics).toEqual([]);
  expect(result.text).toContain("CSS Modules compiled class");
  expect(result.text).toContain("styled-components generated classes");
  expect(result.text).toContain("Tailwind utility selectors");
  expect(result.hasImageObject).toBe(false);
  expect(result.hasUnicodeMap).toBe(true);
});
