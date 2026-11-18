import { expect, test } from "@playwright/test";

// Regressions reported from a Tailwind v4 invoice builder. Each test renders
// through the public browser API and inspects the real PDF with PDF.js.

/** Installs page helpers shared by every test in this file. */
async function installHelpers(page) {
  await page.goto("/tests/web/index.html");
  await page.evaluate(async () => {
    const manifest = await fetch("/bindings/js/.browser-build/manifest.json", { cache: "no-store" })
      .then((response) => response.json());
    const pkg = await import(`/bindings/js/.browser-build/${manifest.entry}`);
    const pdfjs = await import(`/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.min.mjs`);
    pdfjs.GlobalWorkerOptions.workerSrc = `/bindings/js/.browser-build/${manifest.buildId}/vendor/pdf.worker.min.mjs`;

    window.__regressions = {
      pkg,
      pdfjs,
      async render(html, options = {}, rendererOptions = {}) {
        const fixture = document.createElement("section");
        fixture.innerHTML = html;
        document.body.append(fixture);
        const renderer = await pkg.createRenderer({ execution: "main", ...rendererOptions });
        try {
          const pdf = await renderer.render(fixture.firstElementChild, {
            cssProfile: "web",
            page: { format: [400, 300], unit: "px", margin: 0 },
            viewport: { width: 400, height: 300 },
            ...options,
          });
          const bytes = pdf.toUint8Array();
          const diagnostics = pdf.diagnostics;
          pdf.dispose();
          return { bytes, diagnostics };
        } finally {
          renderer.dispose();
          fixture.remove();
        }
      },
      /** Rasterizes one page at one canvas pixel per CSS pixel. */
      async inspect(bytes, pageNumber = 1) {
        const handle = await pdfjs.getDocument({ data: bytes.slice() }).promise;
        const pdfPage = await handle.getPage(pageNumber);
        const viewport = pdfPage.getViewport({ scale: 4 / 3 });
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        const context = canvas.getContext("2d", { willReadFrequently: true });
        await pdfPage.render({ canvasContext: context, viewport }).promise;
        const pixels = context.getImageData(0, 0, canvas.width, canvas.height);
        const text = await pdfPage.getTextContent();
        const pageHeight = pdfPage.view[3];
        const items = text.items.filter((item) => item.str.trim()).map((item) => ({
          str: item.str,
          left: item.transform[4] * 4 / 3,
          right: (item.transform[4] + item.width) * 4 / 3,
          top: (pageHeight - item.transform[5]) * 4 / 3,
        }));
        const pageCount = handle.numPages;
        await handle.destroy();
        return {
          pageCount,
          items,
          pixel(x, y) {
            const offset = (Math.round(y) * pixels.width + Math.round(x)) * 4;
            return Array.from(pixels.data.slice(offset, offset + 3));
          },
          /** Leftmost pixel matching `predicate` within a horizontal band. */
          firstMatchingX(top, bottom, predicate) {
            let result = -1;
            for (let y = top; y < bottom; y += 1) {
              for (let x = 0; x < pixels.width; x += 1) {
                const offset = (y * pixels.width + x) * 4;
                if (!predicate(pixels.data[offset], pixels.data[offset + 1], pixels.data[offset + 2])) continue;
                if (result < 0 || x < result) result = x;
                break;
              }
            }
            return result;
          },
        };
      },
    };
  });
}

test("Tailwind v4 rounded-full, rounded images, and oklch/oklab colors paint natively", async ({ page }) => {
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const swatch = document.createElement("canvas");
    swatch.width = 60;
    swatch.height = 60;
    const swatchContext = swatch.getContext("2d");
    swatchContext.fillStyle = "#0000ff";
    swatchContext.fillRect(0, 0, 60, 60);

    const { bytes, diagnostics } = await helpers.render(`
      <div style="position:relative;width:400px;height:300px;background:#fff">
        <div id="pill" style="position:absolute;left:0;top:0;width:120px;height:40px;
          background:oklch(0.627955 0.257683 29.2339);border-radius:calc(infinity * 1px)"></div>
        <img id="avatar" src="${swatch.toDataURL("image/png")}" style="position:absolute;left:200px;top:0;
          width:60px;height:60px;object-fit:cover;border-radius:calc(infinity * 1px)">
        <div id="overlay" style="position:absolute;left:0;top:100px;width:60px;height:30px;background:oklab(0 0 0 / 0.4)"></div>
      </div>`);
    const view = await helpers.inspect(bytes);
    return {
      diagnostics,
      pillCenter: view.pixel(60, 20),
      pillCorner: view.pixel(2, 2),
      avatarCenter: view.pixel(230, 30),
      avatarCorner: view.pixel(203, 3),
      overlayCenter: view.pixel(30, 115),
    };
  });

  expect(result.diagnostics).toEqual([]);
  // Rounded corners stay white; rectangular painting would fill them.
  expect(result.pillCorner).toEqual([255, 255, 255]);
  expect(result.avatarCorner).toEqual([255, 255, 255]);
  // oklch(...) is sRGB red and the PNG content is blue.
  expect(result.pillCenter[0]).toBeGreaterThan(240);
  expect(result.pillCenter[1]).toBeLessThan(20);
  expect(result.avatarCenter[2]).toBeGreaterThan(240);
  expect(result.avatarCenter[0]).toBeLessThan(20);
  // 40% black over white.
  for (const channel of result.overlayCenter) expect(Math.abs(channel - 153)).toBeLessThanOrEqual(3);
});

test("a CSS drop-shadow on an outer SVG keeps the document rendering", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared SVG snapshot reference");
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const flag = `
      <div style="width:400px;height:300px">
        <p style="margin:0">Dear PROAI S.R.L.</p>
        <svg width="12" height="12" viewBox="0 0 3 2" style="filter:drop-shadow(0 0 1px #fff)">
          <rect width="1" height="2" fill="#009246"/><rect x="1" width="1" height="2" fill="#fff"/><rect x="2" width="1" height="2" fill="#ce2b37"/>
        </svg>
      </div>`;
    const vector = await helpers.render(flag);
    const source = new TextDecoder("latin1").decode(vector.bytes);
    const view = await helpers.inspect(vector.bytes);

    let strictError = null;
    try {
      await helpers.render(flag, { unsupportedCss: "error" });
    } catch (error) {
      strictError = error.name;
    }

    const raster = await helpers.render(flag, { fallback: "rasterize-subtree" });
    return {
      diagnostics: vector.diagnostics.map(({ code, property }) => ({ code, property })),
      text: view.items.map((item) => item.str).join(" "),
      hasForm: source.includes("/Subtype /Form"),
      hasImage: source.includes("/Subtype /Image"),
      strictError,
      rasterHasImage: new TextDecoder("latin1").decode(raster.bytes).includes("/Subtype /Image"),
      rasterDiagnostics: raster.diagnostics.map(({ code }) => code),
    };
  });

  expect(result.diagnostics).toEqual([{ code: "UNSUPPORTED_CSS_PROPERTY", property: "filter" }]);
  expect(result.text).toContain("Dear PROAI S.R.L.");
  expect(result.hasForm).toBe(true);
  expect(result.hasImage).toBe(false);
  // Strict CSS keeps failing loudly, and the explicit opt-in still rasterizes.
  expect(result.strictError).toBe("UnsupportedCssError");
  expect(result.rasterHasImage).toBe(true);
  expect(result.rasterDiagnostics).toContain("CSS_SUBTREE_RASTERIZED");
});

test("pseudo-element blend modes are reported instead of silently dropped", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared snapshot reference");
  await installHelpers(page);
  const diagnostics = await page.evaluate(async () => {
    // Like compiled Tailwind, the rule lives in a document stylesheet outside
    // the rendered element, so only the computed-style pass can see it.
    const sheet = document.createElement("style");
    sheet.textContent = ".avatar::after { content:''; position:absolute; inset:0; background:#000; mix-blend-mode:overlay; }";
    document.head.append(sheet);
    try {
      const { diagnostics } = await window.__regressions.render(`
        <div style="width:400px;height:300px">
          <div class="avatar" style="position:relative;width:40px;height:40px;background:#3b82f6">GA</div>
        </div>`);
      return diagnostics.map(({ code, property }) => ({ code, property }));
    } finally {
      sheet.remove();
    }
  });
  expect(diagnostics).toEqual([{ code: "UNSUPPORTED_CSS_PROPERTY", property: "mix-blend-mode" }]);
});

test("subgrid rows reuse the parent tracks instead of a zero-width column", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared PDF geometry reference");
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const { bytes, diagnostics } = await helpers.render(`
      <footer style="display:grid;grid-template-columns:80px 1fr;column-gap:16px;width:400px;font-size:12px;line-height:16px">
        <div style="grid-column:1 / -1;display:grid;grid-template-columns:subgrid">
          <span>From</span><span>NDRT S.R.L., Via Pasquale Ianniello 125</span>
        </div>
        <div style="grid-column:1 / -1;display:grid;grid-template-columns:subgrid">
          <span>To</span><span>PROAI S.R.L., Via Volga snc</span>
        </div>
      </footer>`);
    const view = await helpers.inspect(bytes);
    const words = (text) => view.items.filter((item) => text.includes(item.str.trim()));
    return {
      diagnostics,
      from: view.items.find((item) => item.str.trim() === "From"),
      to: view.items.find((item) => item.str.trim() === "To"),
      fromValue: words("NDRT S.R.L., Via Pasquale Ianniello 125"),
      toValue: words("PROAI S.R.L., Via Volga snc"),
    };
  });

  expect(result.diagnostics).toEqual([]);
  // Each value sits on one line in the second parent track (80px + 16px gap).
  const fromTops = new Set(result.fromValue.map((item) => Math.round(item.top)));
  expect(fromTops.size).toBe(1);
  expect(Math.min(...result.fromValue.map((item) => item.left))).toBeCloseTo(96, 0);
  expect(Math.min(...result.toValue.map((item) => item.left))).toBeCloseTo(96, 0);
  // Rows no longer overlap.
  expect(result.to.top).toBeGreaterThanOrEqual(result.from.top + 15);
});

test("page-sized sections authored in millimetres keep one PDF page each", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared PDF geometry reference");
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const { bytes } = await helpers.render(`
      <div style="width:210mm;margin:0;padding:0">
        <div style="height:297mm;margin:0;background:#eef2ff">Page one</div>
        <div style="height:297mm;margin:0;background:#eef2ff">Page two</div>
      </div>`, { page: { format: "a4", margin: 0 }, viewport: { width: 794, height: 1123 } });
    const view = await helpers.inspect(bytes);
    const probe = document.createElement("div");
    probe.style.height = "297mm";
    document.body.append(probe);
    const serialized = getComputedStyle(probe).height;
    probe.remove();
    return { pageCount: view.pageCount, serialized };
  });
  // Chromium rounds 297mm (1122.5197px) up to the serialized `1122.52px`.
  expect(result.serialized).toBe("1122.52px");
  expect(result.pageCount).toBe(2);
});

test("text followed by inline content does not overlap it", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Chromium is the declared PDF geometry reference");
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const red = (r, g, b) => r > 200 && g < 80 && b < 80;
    const kerned = await helpers.render(`
      <div style="width:400px;height:300px;font-size:24px;line-height:32px">
        <p style="margin:0">AVAWAY Tax Year A Total<span style="display:inline-block;width:30px;height:16px;background:#f00"></span></p>
      </div>`);
    const kernedView = await helpers.inspect(kerned.bytes);
    const kernedText = kernedView.items.filter((item) => item.top < 40);

    const nowrap = await helpers.render(`
      <div style="width:400px;height:300px;font-size:20px;line-height:28px">
        <span style="display:inline-block;white-space:nowrap">Document total <b>0,00 €</b></span><span style="display:inline-block;width:20px;height:14px;background:#f00"></span>
      </div>`);
    const nowrapView = await helpers.inspect(nowrap.bytes);
    return {
      kernedTextRight: Math.max(...kernedText.map((item) => item.right)),
      kernedBoxLeft: kernedView.firstMatchingX(0, 40, red),
      nowrapLines: new Set(nowrapView.items.map((item) => Math.round(item.top))).size,
      nowrapTextRight: Math.max(...nowrapView.items.map((item) => item.right)),
      nowrapBoxLeft: nowrapView.firstMatchingX(0, 40, red),
    };
  });

  expect(result.kernedBoxLeft).toBeGreaterThan(0);
  expect(result.kernedTextRight).toBeLessThanOrEqual(result.kernedBoxLeft + 0.5);
  expect(result.nowrapLines).toBe(1);
  expect(result.nowrapBoxLeft).toBeGreaterThan(0);
  expect(result.nowrapTextRight).toBeLessThanOrEqual(result.nowrapBoxLeft + 0.5);
});

test("registered Medium and SemiBold faces coexist with Regular", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "Font registration is engine-independent");
  await installHelpers(page);
  const result = await page.evaluate(async () => {
    const helpers = window.__regressions;
    const load = (name) => fetch(`/src/assets/fonts/${name}`).then((response) => response.arrayBuffer());
    const [regular, bold] = await Promise.all([load("NotoSans-Regular.ttf"), load("NotoSans-Bold.ttf")]);
    const { bytes } = await helpers.render(`
      <div style="width:400px;height:300px;font-family:Brand">
        <p>Regular</p><p style="font-weight:500">Medium</p><p style="font-weight:600">SemiBold</p>
      </div>`, {}, {
      fonts: [
        { family: "Brand", data: bold, weight: 500 },
        { family: "Brand", data: regular, weight: 400 },
        { family: "Brand", data: bold, weight: 600 },
      ],
    });
    const source = new TextDecoder("latin1").decode(bytes);

    let woff2Error = null;
    try {
      const packed = new Uint8Array(64);
      packed.set(new TextEncoder().encode("wOF2"));
      await helpers.render("<p>packed</p>", {}, { fonts: [{ family: "Packed", data: packed }] });
    } catch (error) {
      woff2Error = error.message;
    }
    return {
      fontNames: [...new Set(source.match(/\/BaseFont \/[A-Z]{6}\+Brand[\w-]*/g) ?? [])].map((name) => name.replace(/^.*\+/, "")).sort(),
      woff2Error,
    };
  });
  expect(result.fontNames).toEqual(["Brand", "Brand-W500", "Brand-W600"]);
  expect(result.woff2Error).toContain("WOFF2");
});
