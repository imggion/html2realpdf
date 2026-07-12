import { expect, test } from "@playwright/test";

test("supported inline SVG remains vector PDF geometry", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared SVG snapshot reference");
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "width:240px;height:140px";
    fixture.innerHTML = `
      <svg id="vector-chart" width="220" height="120" viewBox="0 0 220 120" aria-label="Vector chart">
        <rect x="4" y="4" width="212" height="112" rx="18" fill="#eff6ff" stroke="#2563eb" stroke-width="4"/>
        <g transform="translate(20 15)">
          <circle cx="42" cy="45" r="28" fill="#16a34a"/>
          <path d="M85 75 C110 15 145 95 180 30" fill="none" stroke="#7c3aed" stroke-width="8" stroke-linecap="round"/>
        </g>
      </svg>
      <div id="vector-background" style="width:160px;height:24px;margin-top:4px;background-size:40px 20px;background-repeat:repeat-x"></div>
      <img id="external-vector" src="https://assets.example/vector.svg" width="40" height="20" style="display:block;width:40px;height:20px">`;
    const backgroundSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"><polygon points="0,20 20,0 40,20" fill="#f59e0b"/></svg>`;
    fixture.querySelector("#vector-background").style.backgroundImage = `url("data:image/svg+xml;base64,${btoa(backgroundSvg)}")`;
    document.body.append(fixture);
    const renderer = await pkg.createRenderer({ execution: "main" });
    let resolverCalls = 0;
    const pdf = await renderer.render(fixture, {
      cssProfile: "web",
      page: { format: [260, 160], unit: "px", margin: 0 },
      viewport: { width: 260, height: 160 },
      fallback: "error",
      unsupportedCss: "error",
      resourceResolver: ({ kind, url }) => {
        if (url.protocol === "data:") return null;
        resolverCalls += 1;
        if (kind !== "image" || url.href !== "https://assets.example/vector.svg") throw new Error("Unexpected SVG resource request");
        return new Blob([backgroundSvg], { type: "image/svg+xml" });
      },
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    pdf.dispose();
    renderer.dispose();
    fixture.remove();

    const source = new TextDecoder("latin1").decode(bytes);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const loadingTask = pdfjs.getDocument({ data: bytes });
    const documentHandle = await loadingTask.promise;
    const pdfPage = await documentHandle.getPage(1);
    const operators = await pdfPage.getOperatorList();
    const count = (operator) => operators.fnArray.filter((candidate) => candidate === operator).length;
    const summary = {
      diagnostics,
      resolverCalls,
      hasFormObject: source.includes("/Subtype /Form"),
      hasImageObject: source.includes("/Subtype /Image"),
      forms: count(pdfjs.OPS.paintFormXObjectBegin),
      rasterImages: count(pdfjs.OPS.paintImageXObject) + count(pdfjs.OPS.paintInlineImageXObject),
      paths: count(pdfjs.OPS.constructPath),
    };
    await documentHandle.destroy();
    return summary;
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.resolverCalls).toBe(1);
  expect(result.hasFormObject).toBe(true);
  expect(result.hasImageObject).toBe(false);
  expect(result.forms).toBeGreaterThanOrEqual(3);
  expect(result.rasterImages).toBe(0);
  expect(result.paths).toBeGreaterThanOrEqual(4);
});

test("unsupported SVG rasterizes only its subtree and reports the fallback", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared SVG snapshot reference");
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.innerHTML = `
      <p>Selectable sibling</p>
      <svg id="fallback-chart" width="160" height="70" viewBox="0 0 160 70">
        <rect width="160" height="70" rx="12" fill="#111827"/>
        <text x="18" y="42" fill="white" font-size="24">Raster-only SVG text</text>
      </svg>`;
    document.body.append(fixture);
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(fixture, {
      cssProfile: "web",
      page: { format: [240, 160], unit: "px", margin: 0 },
      viewport: { width: 240, height: 160 },
      fallback: "rasterize-subtree",
      unsupportedCss: "error",
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    pdf.dispose();

    let explicitError = "";
    try {
      await renderer.render(fixture, {
        cssProfile: "web",
        page: { format: [240, 160], unit: "px", margin: 0 },
        viewport: { width: 240, height: 160 },
        fallback: "error",
        unsupportedCss: "error",
      });
    } catch (error) {
      explicitError = error instanceof Error ? error.message : String(error);
    }
    let defaultError = "";
    try {
      await renderer.render(fixture, {
        cssProfile: "web",
        page: { format: [240, 160], unit: "px", margin: 0 },
        viewport: { width: 240, height: 160 },
        unsupportedCss: "error",
      });
    } catch (error) {
      defaultError = error instanceof Error ? error.message : String(error);
    }
    renderer.dispose();
    fixture.remove();
    const source = new TextDecoder("latin1").decode(bytes);
    return {
      diagnostics,
      explicitError,
      defaultError,
      imageObjects: (source.match(/\/Subtype \/Image/g) ?? []).length,
      hasSelectableSibling: source.includes("/ToUnicode"),
    };
  });

  expect(result.imageObjects).toBeGreaterThanOrEqual(1);
  expect(result.hasSelectableSibling).toBe(true);
  expect(result.diagnostics).toEqual([
    expect.objectContaining({
      code: "CSS_SUBTREE_RASTERIZED",
      severity: "warning",
      phase: "paint",
      fallback: "rasterized-subtree",
      nodePath: "#fallback-chart",
    }),
  ]);
  expect(result.explicitError).toContain("Inline SVG requires subtree rasterization");
  expect(result.explicitError).toContain("<text>");
  expect(result.defaultError).toContain("Inline SVG requires subtree rasterization");
  expect(result.defaultError).toContain("<text>");
});
