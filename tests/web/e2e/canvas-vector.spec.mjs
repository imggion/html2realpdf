import { expect, test } from "@playwright/test";

test("canvasToSvg preserves a live canvas as native selectable PDF content", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const canvas = document.createElement("canvas");
    canvas.id = "live-vector-chart";
    canvas.width = 320;
    canvas.height = 160;
    canvas.style.cssText = "display:block;width:320px;height:160px";
    canvas.getContext("2d").fillRect(0, 0, 320, 160);
    document.body.append(canvas);

    const renderer = await pkg.createRenderer({ execution: "main" });
    let calls = 0;
    let receivedOriginal = false;
    const pdf = await renderer.render(canvas, {
      cssProfile: "web",
      mediaType: "print",
      viewport: { width: 480, height: 320 },
      page: { format: [360, 200], unit: "px", margin: 0 },
      fallback: "error",
      canvasFallback: "error",
      canvasToSvg: async (request) => {
        calls += 1;
        receivedOriginal = request.canvas === canvas;
        return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 160">
          <defs>
            <radialGradient id="area"><stop offset="0%" stop-color="#bfdbfe"/><stop offset="100%" stop-color="#2563eb" stop-opacity=".65"/></radialGradient>
            <clipPath id="plot"><rect x="8" y="8" width="304" height="144" rx="18"/></clipPath>
          </defs>
          <rect x="8" y="8" width="304" height="144" rx="18" fill="#eff6ff"/>
          <g clip-path="url(#plot)">
            <circle cx="78" cy="84" r="58" fill="url(#area)"/>
            <path d="M120 118 C165 22 220 142 292 42" fill="none" stroke="#7c3aed" stroke-width="10" stroke-linecap="round"/>
          </g>
          <text x="160" y="38" text-anchor="middle" font-size="18" fill="#172033">Live revenue <tspan dx="5" font-weight="bold">€128k</tspan></text>
        </svg>`;
      },
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    const source = new TextDecoder("latin1").decode(bytes);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const handle = await pdfjs.getDocument({ data: bytes }).promise;
    const pdfPage = await handle.getPage(1);
    const operators = await pdfPage.getOperatorList();
    const textContent = await pdfPage.getTextContent();
    const rasterImages = operators.fnArray.filter((operator) =>
      operator === pdfjs.OPS.paintImageXObject || operator === pdfjs.OPS.paintInlineImageXObject).length;
    const forms = operators.fnArray.filter((operator) => operator === pdfjs.OPS.paintFormXObjectBegin).length;
    await handle.destroy();
    pdf.dispose();
    renderer.dispose();
    canvas.remove();
    return {
      calls,
      receivedOriginal,
      diagnostics,
      hasImageObject: source.includes("/Subtype /Image"),
      forms,
      rasterImages,
      text: textContent.items.map((item) => item.str).join(" "),
    };
  });

  expect(result.calls).toBe(1);
  expect(result.receivedOriginal).toBe(true);
  expect(result.diagnostics).toEqual([]);
  expect(result.hasImageObject).toBe(false);
  expect(result.forms).toBeGreaterThanOrEqual(1);
  expect(result.rasterImages).toBe(0);
  expect(result.text).toContain("Live revenue");
  expect(result.text).toContain("€128k");
});

test("canvasToSvg fails strictly or uses an explicit scoped raster fallback", async ({ page }) => {
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const canvas = document.createElement("canvas");
    canvas.id = "optional-vector-chart";
    canvas.width = 80;
    canvas.height = 40;
    canvas.getContext("2d").fillRect(4, 4, 60, 28);
    document.body.append(canvas);
    const renderer = await pkg.createRenderer({ execution: "main" });

    let strictError = null;
    try {
      await renderer.render(canvas, { canvasToSvg: () => null });
    } catch (error) {
      strictError = { code: error?.code, message: error instanceof Error ? error.message : String(error) };
    }
    let malformedError = null;
    try {
      await renderer.render(canvas, { canvasToSvg: () => "<svg>" });
    } catch (error) {
      malformedError = { code: error?.code, message: error instanceof Error ? error.message : String(error) };
    }
    const fallbackPdf = await renderer.render(canvas, {
      canvasToSvg: () => null,
      canvasFallback: "rasterize",
    });
    const source = new TextDecoder("latin1").decode(fallbackPdf.toUint8Array());
    const diagnostics = fallbackPdf.diagnostics;
    fallbackPdf.dispose();
    renderer.dispose();
    canvas.remove();
    return { strictError, malformedError, diagnostics, hasImage: source.includes("/Subtype /Image") };
  });

  expect(result.strictError).toEqual(expect.objectContaining({ code: "CANVAS_TO_SVG_FAILED" }));
  expect(result.strictError.message).toContain("#optional-vector-chart");
  expect(result.malformedError).toEqual(expect.objectContaining({ code: "CANVAS_TO_SVG_FAILED" }));
  expect(result.hasImage).toBe(true);
  expect(result.diagnostics).toEqual([
    expect.objectContaining({
      code: "CANVAS_SUBTREE_RASTERIZED",
      severity: "warning",
      phase: "snapshot",
      fallback: "rasterized-subtree",
      nodePath: "#optional-vector-chart",
    }),
  ]);
});

test("raster canvas remains fully visible inside a nested clipped flex card", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared canvas geometry reference");
  await page.goto("/tests/web/index.html");
  const result = await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const fixture = document.createElement("div");
    fixture.style.cssText = "width:695.433px;background:#fff";
    fixture.innerHTML = `
      <div style="display:grid;grid-template-columns:322.281px 349.141px;grid-template-rows:441.141px;gap:24px;align-items:start">
        <div style="height:441.141px"></div>
        <section style="break-inside:avoid">
          <h2 style="margin:0 0 12px;font:800 20px/1.2 sans-serif;text-align:center">Competency Analysis</h2>
          <div style="max-width:309.921px;margin:8px auto 0">
            <div style="overflow:hidden">
              <div style="display:flex;flex-direction:column;overflow:hidden">
                <div style="display:none"></div>
                <div style="display:flex;flex-grow:1;justify-content:center;align-items:center">
                  <div style="display:flex;width:100%;height:260px;justify-content:center">
                    <div style="position:relative;width:100%;height:auto">
                      <canvas width="619" height="520" style="display:block;vertical-align:middle;box-sizing:border-box;width:309.9px;height:260px"></canvas>
                    </div>
                  </div>
                </div>
                <div style="display:none"></div>
              </div>
            </div>
          </div>
        </section>
      </div>
    `;
    document.body.append(fixture);
    const canvas = fixture.querySelector("canvas");
    const context = canvas.getContext("2d");
    context.fillStyle = "#ef4444";
    context.fillRect(0, 0, canvas.width, canvas.height / 2);
    context.fillStyle = "#2563eb";
    context.fillRect(0, canvas.height / 2, canvas.width, canvas.height / 2);
    const browserRect = canvas.getBoundingClientRect();

    const pdf = await pkg.renderPdf(fixture, {
      cssProfile: "web",
      page: { format: [695.433, 600], unit: "px", margin: 0 },
      viewport: { width: 1200, height: 800 },
      unsupportedCss: "error",
      execution: "main",
    });
    const bytes = pdf.toUint8Array();
    const diagnostics = pdf.diagnostics;
    pdf.dispose();
    fixture.remove();

    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;
    const handle = await pdfjs.getDocument({ data: bytes }).promise;
    const pdfPage = await handle.getPage(1);
    const viewport = pdfPage.getViewport({ scale: 4 / 3 });
    const rendered = document.createElement("canvas");
    rendered.width = Math.ceil(viewport.width);
    rendered.height = Math.ceil(viewport.height);
    const renderedContext = rendered.getContext("2d", { willReadFrequently: true });
    await pdfPage.render({ canvasContext: renderedContext, viewport }).promise;
    const pixels = renderedContext.getImageData(0, 0, rendered.width, rendered.height).data;
    let redPixels = 0;
    let bluePixels = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      if (red > 180 && green < 130 && blue < 130) redPixels += 1;
      if (blue > 140 && red < 120 && green < 160) bluePixels += 1;
    }
    await handle.destroy();
    return {
      browserHeight: browserRect.height,
      diagnostics,
      redPixels,
      bluePixels,
    };
  });

  expect(result.diagnostics).toEqual([]);
  expect(result.browserHeight).toBeCloseTo(260, 1);
  expect(result.redPixels).toBeGreaterThan(20_000);
  expect(result.bluePixels).toBeGreaterThan(20_000);
  expect(result.bluePixels / result.redPixels).toBeGreaterThan(0.9);
});
