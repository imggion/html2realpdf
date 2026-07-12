# @imggion/html2realpdf

Browser-first HTML to real, selectable PDF rendering powered by Zig and
WebAssembly. Pages are composed from PDF text, vectors, links, and image
objects—not full-page screenshots.

## Modern API

```ts
import { renderPdf } from "@imggion/html2realpdf";

const pdf = await renderPdf(document.querySelector("#invoice")!, {
  page: { format: "a4", orientation: "portrait", margin: [15, 12], unit: "mm" },
  metadata: { title: "Invoice 2026-001", keywords: ["invoice", "customer"] },
  resourcePolicy: "error",
});

pdf.download("invoice.pdf");
const preview = await pdf.preview(document.querySelector("#pdf-preview")!, {
  initialScale: "fit-width",
});

preview.dispose();
pdf.dispose();
```

`preview()` renders every PDF page into a self-contained Shadow DOM viewer with
canvas pages, HiDPI output, zoom controls, fit-to-width behavior, keyboard focus
states, and touch-sized controls. It never uses an iframe, object element, or
the browser's built-in PDF viewer.

`renderPdf` accepts an HTML string, an `Element`, or a ref-shaped object such
as a React `RefObject<Element>`. DOM/ref input is cloned, computed styles and
live form values are materialized, canvas content becomes a transparent PNG,
and supported SVG shapes and paths remain native vector Form XObjects. An
unsupported SVG rasterizes only that SVG, emits `CSS_SUBTREE_RASTERIZED`, and
can instead fail with `fallback: "error"`; active elements and event attributes
are removed.

For DOM/ref input, transparent descendant backgrounds remain transparent,
normal-flow dimensions are allowed to reflow unless explicitly authored, and
live controls, buttons, canvas pixels, lists, and open/closed details state are
captured from the mounted browser tree. React itself is not a package runtime
dependency; the integration fixture under `tests/react/` verifies the boundary
with a real React application.

For repeated renders or custom fonts, create and dispose an explicit renderer:

```ts
import { createRenderer } from "@imggion/html2realpdf";

const renderer = await createRenderer({
  execution: "worker",
  fonts: [{
    family: "Inter",
    data: await (await fetch("/Inter-Regular.ttf")).arrayBuffer(),
    weight: 400,
    style: "normal",
  }],
});

const pdf = await renderer.render('<p style="font-family: Inter">Hello</p>');
renderer.dispose();
```

Other render options include `strict`, `baseUrl`, `resourceResolver`,
`resourcePolicy`, `enableLinks`, selector-based `pageBreak` rules,
`AbortSignal`, and progress callbacks. All public signatures are available in
the generated `index.d.ts`.

## html2pdf.js compatibility

The default export preserves common PDF-oriented chains:

```ts
import html2pdf from "@imggion/html2realpdf";

await html2pdf()
  .set({
    filename: "invoice.pdf",
    margin: [10, 12],
    pagebreak: { mode: ["css", "legacy"], avoid: ".line-item" },
    jsPDF: { format: "a4", unit: "mm", orientation: "portrait" },
  })
  .from(document.querySelector("#invoice")!)
  .save();
```

`outputPdf`/`output`, Blob, ArrayBuffer, Blob URL, data URL, `save`, `saveAs`,
`get`, and Promise-like chaining are supported. Raster pipeline stages
(`toCanvas`, `toImg`, `outputImg`, html2canvas options, or image input stages)
throw `UnsupportedCompatibilityFeatureError` because they conflict with the
real-PDF rendering model.

## Layout profile

The alpha supports report-oriented block/inline/table layout, common CSS box
model properties, A4/Letter/custom pages, pagination controls, links, JPEG,
transparent PNG, per-corner elliptical rounded fills/borders and rounded
overflow clipping, Noto Sans Latin/Arabic/Hebrew, and registered embeddable TTF
fonts. A default `@page` rule can set CSS absolute page size/orientation and
margins when the API does not provide `page`; explicit API page options win.
The Web profile also supports Flexbox, Grid, floats, positioned layout,
native 2D transforms, layered URL/gradient backgrounds, shadows, and isolated
opacity groups, plus vector-preserved SVG `path`, `rect`, circle/ellipse, line,
polyline, polygon, group transform, solid fill/stroke, and dash paint. Filters,
blend modes, 3D transforms, SVG text/paint servers/masks, and arbitrary browser
painting remain outside the current native profile. Layout-critical unsupported
CSS is rejected; cosmetic omissions and scoped raster fallbacks are available
through `pdf.diagnostics` and can be promoted to errors with `strict: true` or
`fallback: "error"`.

## Runtime and licensing

- ESM package; Node.js `20.16+` is required for build tooling.
- Rendering requires a browser with WebAssembly, Worker, Blob, and DOM APIs.
- Project code is MIT licensed.
- Bundled Noto Sans font software is licensed under SIL OFL 1.1; the license is
  included as `dist/NotoSans-OFL.txt`.
- HarfBuzz is licensed under the Old MIT license; the license is included as
  `dist/vendor/HARFBUZZ-LICENSE.txt`.
- SheenBidi is licensed under Apache License 2.0; the license is included as
  `dist/vendor/SHEENBIDI-LICENSE.txt`.
- libunibreak is licensed under the zlib license; the license is included as
  `dist/vendor/LIBUNIBREAK-LICENSE.txt`.
- The dynamically loaded PDF.js display layer used by `preview()` is licensed
  under Apache License 2.0; its license is included in
  `dist/vendor/PDFJS-LICENSE.txt`.
