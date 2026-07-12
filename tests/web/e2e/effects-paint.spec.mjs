import { expect, test } from "@playwright/test";

test("Web backgrounds shadows and opacity remain native PDF paint", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential paint reference");
  await page.setViewportSize({ width: 640, height: 420 });
  await page.goto("/tests/web/index.html");

  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("section");
    fixture.style.cssText = "position:relative;width:600px;height:360px;padding:20px;background:linear-gradient(125deg,#eff6ff,#ede9fe 55%,#fdf2f8);box-shadow:0 12px 28px rgba(15,23,42,.28)";
    fixture.innerHTML = `
      <h2 style="margin:0;text-shadow:2px 3px 5px rgba(49,46,129,.35)">Native effects</h2>
      <div style="position:absolute;left:20px;top:80px;width:150px;height:90px;border-radius:18px;background:radial-gradient(circle at 30% 25%,#fff,#93c5fd 45%,#2563eb);box-shadow:0 8px 18px rgba(37,99,235,.35)"></div>
      <div style="position:absolute;left:200px;top:80px;width:150px;height:90px;border-radius:18px;background:conic-gradient(from 35deg,#7c3aed,#db2777 33%,#f59e0b 66%,#7c3aed);box-shadow:inset 0 0 10px rgba(255,255,255,.5)"></div>
      <div style="position:absolute;left:380px;top:80px;width:150px;height:90px;border-radius:18px;background:linear-gradient(90deg,rgba(14,165,233,0),rgba(14,165,233,.9));box-shadow:0 8px 18px rgba(14,165,233,.3)"></div>
      <div style="position:absolute;left:80px;top:220px;width:360px;height:80px;opacity:.62;background:#f8fafc;border-radius:16px">
        <div style="position:absolute;left:25px;top:15px;width:170px;height:50px;background:#ef4444;border-radius:12px"></div>
        <div style="position:absolute;left:115px;top:15px;width:170px;height:50px;background:#2563eb;border-radius:12px"></div>
        <strong style="position:absolute;right:15px;top:28px;opacity:.7">isolated</strong>
      </div>
    `;
    document.body.append(fixture);
    const pdf = await pkg.renderPdf(fixture, {
      cssProfile: "web",
      page: { format: [640, 420], unit: "px", margin: 0 },
      viewport: { width: 640, height: 420 },
      unsupportedCss: "error",
      execution: "main",
    });
    const bytes = pdf.toUint8Array();
    pdf.dispose();
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
      rasterImages: count(pdfjs.OPS.paintImageXObject) + count(pdfjs.OPS.paintInlineImageXObject),
      shadings: count(pdfjs.OPS.shadingFill),
      forms: count(pdfjs.OPS.paintFormXObjectBegin),
      paths: count(pdfjs.OPS.constructPath),
      graphicsStates: count(pdfjs.OPS.setGState),
      hasAxial: source.includes("/ShadingType 2"),
      hasRadial: source.includes("/ShadingType 3"),
      hasMesh: source.includes("/ShadingType 4"),
      hasIsolatedGroup: source.includes("/Group << /S /Transparency /I true"),
      hasRasterObject: source.includes("/Subtype /Image"),
    };
    await documentHandle.destroy();
    return summary;
  });

  expect(result.hasRasterObject).toBe(false);
  expect(result.rasterImages).toBe(0);
  expect(result.hasAxial).toBe(true);
  expect(result.hasRadial).toBe(true);
  expect(result.hasMesh).toBe(true);
  expect(result.hasIsolatedGroup).toBe(true);
  expect(result.shadings).toBeGreaterThanOrEqual(3);
  expect(result.forms).toBeGreaterThanOrEqual(2);
  expect(result.paths).toBeGreaterThan(20);
  expect(result.graphicsStates).toBeGreaterThan(2);
});

test("background URL resources are scoped resolved sized positioned and repeated", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared differential paint reference");
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "width:120px;height:70px;background-image:url('https://assets.example/tile.png');background-size:20px 20px;background-position:right 10px bottom 5px;background-repeat:space round";
    document.body.append(fixture);
    let resolverCalls = 0;
    const resolver = async ({ kind, url }) => {
      resolverCalls += 1;
      if (kind !== "image" || url.href !== "https://assets.example/tile.png") throw new Error("unexpected resource");
      return "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X1y8WQAAAABJRU5ErkJggg==";
    };
    const renderer = await pkg.createRenderer({ execution: "main" });
    const pdf = await renderer.render(fixture, {
      cssProfile: "web",
      page: { format: [160, 100], unit: "px", margin: 0 },
      viewport: { width: 160, height: 100 },
      unsupportedCss: "error",
      execution: "main",
      resourceResolver: resolver,
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    pdf.dispose();
    renderer.dispose();
    fixture.remove();
    const source = new TextDecoder("latin1").decode(bytes);
    return {
      resolverCalls,
      diagnostics,
      imageObjects: (source.match(/\/Subtype \/Image/g) ?? []).length,
    };
  });
  expect(result.resolverCalls).toBe(1);
  expect(result.diagnostics).toEqual([]);
  expect(result.imageObjects).toBeGreaterThan(2);
});
