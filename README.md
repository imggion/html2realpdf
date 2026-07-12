# html2realpdf

`html2realpdf` is a Zig/WebAssembly renderer that converts HTML into real PDF
content. Text remains selectable and searchable, links become PDF annotations,
fonts are embedded as subset TrueType fonts, and shapes stay vector-based. It
does not capture the page as a bitmap.

The browser package is published as `@imggion/html2realpdf`.

## Current alpha capabilities

- tolerant HTML tokenizer and flat DOM/Box Trees;
- CSS cascade with specificity, source order, inheritance, inline styles, and
  `!important`;
- block and inline layout, wrapping, whitespace modes, alignment, margin
  collapse, padding, borders, and `border-box` sizing;
- tables with `colspan`, `rowspan`, collapsed borders, and repeated `<thead>`
  and page-end `<tfoot>` rows;
- Web/strict Flexbox with row/column/reverse flow, wrapping, grow/shrink,
  min/max constraints, gaps, alignment, auto margins, nested containers,
  replaced elements, and page-aware line/item placement;
- Web/strict relative, absolute, fixed, and sticky positioning with physical
  and logical insets, positioned containing blocks, `z-index` paint phases,
  overflow clipping, native opacity, and repeated fixed headers/footers anchored
  from either page edge;
- Web/strict CSS Grid with explicit and implicit tracks, `fr`, `repeat()`,
  `minmax()`, auto-placement, spans, named lines/areas, Box Alignment, nested
  grids, intrinsic sizing, replaced elements, and page-aware row placement;
- Web/strict 2D transforms with length-percentage origins, nested matrices,
  transformed overflow clips, text, images, vectors, and real link bounds;
- Web/strict multiple backgrounds with URL resources, per-layer sizing,
  positioning and repeat, native axial/radial PDF shadings, conic mesh
  shadings, and vector alpha-gradient bands;
- multiple outer/inset box shadows, artifact-marked text shadows, and nested
  isolated PDF transparency groups for correct element-opacity compositing;
- A4, Letter, landscape, custom page sizes, default `@page` size/orientation and
  margins, shared page-fragmentainer placement, propagated and adjacent break
  arbitration, `page`/`left`/`right`/`recto`/`verso`, `avoid`, orphans/widows,
  page-aware block, table, Flex, and Grid flows, and selectable text in all 16
  standard `@page` margin boxes with `counter(page)`/`counter(pages)`;
- selectable Unicode text with Noto Sans Latin/Arabic/Hebrew fallbacks or registered TTF fonts;
- HarfBuzz OpenType shaping, kerning, ligatures, and positioned RTL runs in the
  `web` and `strict` profiles while `document` remains byte-stable;
- JPEG pass-through, transparent PNG soft masks, supported SVG shape/path
  resources as native PDF Form XObjects, vector backgrounds/borders, and live
  link annotations;
- per-corner circular/elliptical `border-radius` fills, borders, and overflow clips emitted as native PDF Bézier paths;
- compressed PDF 1.7 streams, metadata, deterministic classic xref output;
- a versioned WASM ABI with independent result handles and structured errors;
- an ESM/TypeScript browser package with Worker execution, DOM/React-ref
  snapshotting, preview/download helpers, and an html2pdf.js-compatible facade.

The document profile remains aimed at invoices, reports, tickets, letters, and
similar documents. The Web profile additionally enables floats, Flexbox,
positioned layout, CSS Grid, 2D transforms, layered backgrounds, gradients,
shadows, and isolated opacity. Filters, blend modes, 3D transforms, and
arbitrary browser painting are still rejected or reported instead of silently
rasterizing the whole page. Canvas is captured as its own image resource.
Unsupported SVG paint is rejected by default and can rasterize only its own
subtree when callers explicitly opt into `fallback: "rasterize-subtree"`;
every fallback is exposed through structured diagnostics.

See [docs/css-support.md](docs/css-support.md) for the versioned property and
pipeline-stage support matrix.

## Browser package

```ts
import { renderPdf } from "@imggion/html2realpdf";

const pdf = await renderPdf(document.querySelector("#invoice")!, {
  cssProfile: "web",
  mediaType: "print",
  viewport: { width: 1440, height: 900 },
  unsupportedCss: "warn",
  fallback: "error",
  page: { format: "a4", margin: [15, 12], unit: "mm" },
  metadata: { title: "Invoice 2026-001", author: "Example Ltd" },
});

const preview = await pdf.preview(document.querySelector("#pdf-preview")!, {
  initialScale: "fit-width",
});
pdf.download("invoice.pdf");

preview.dispose();
pdf.dispose();
```

The preview is an in-page Shadow DOM component with responsive canvas pages,
HiDPI rendering, zoom controls, and fit-to-width behavior. It does not open an
iframe or delegate rendering to the browser's built-in PDF plugin.

React refs work without a React runtime dependency:

```ts
const pdf = await renderPdf(invoiceRef);
```

Register custom TTF faces when creating a renderer:

```ts
import { createRenderer } from "@imggion/html2realpdf";

const renderer = await createRenderer({
  fonts: [{
    family: "Inter",
    data: await (await fetch("/fonts/Inter-Regular.ttf")).arrayBuffer(),
    weight: 400,
  }],
});

const pdf = await renderer.render('<p style="font-family: Inter">Hello</p>');
```

Common html2pdf.js PDF workflows are available from the default export:

```ts
import html2pdf from "@imggion/html2realpdf";

await html2pdf()
  .set({
    filename: "invoice.pdf",
    pagebreak: { mode: ["css", "legacy"], avoid: ".line-item" },
    jsPDF: { format: "a4", unit: "mm" },
  })
  .from(document.querySelector("#invoice")!)
  .save();
```

Raster-only stages such as `toCanvas()`, `toImg()`, and html2canvas options
throw an explicit compatibility error.

## Requirements and build

- Zig `0.16.0`
- Node.js `20.16+` for the npm package and JavaScript tests
- `make` for convenience targets

```sh
zig build
zig build wasm -Doptimize=ReleaseSmall
npm --prefix bindings/js test
```

Run the complete local suite:

```sh
make test-release
```

Useful focused commands:

```sh
make test
make test-react
make test-web
make test-debug-tokenizer
make test-debug-dom
make test-debug-box
```

## Browser harness

Build the WASM artifact, serve the repository, and open
`tests/web/index.html`:

```sh
make wasm
python3 -m http.server 8765
```

`make wasm` also rebuilds the TypeScript bindings and writes a content-addressed
browser runtime manifest, so the harness cannot combine a new test script with
stale nested ESM modules from an earlier preview API.

The harness runs structural snapshots and exposes buttons for PDF generation,
in-page canvas preview, download, and the public DOM/ref package API. It also
generates a two-page colored invoice and a three-page analytics report with
charts, a two-page rounded-table operations report, and a four-page A4
landscape presentation deck. It verifies that canvas transparency survives as
a PDF soft mask and that the presentation uses landscape page geometry.

For a real React integration, install the isolated test app once and start it:

```sh
npm --prefix tests/react install
make react
```

`tests/react/` renders a mounted report component through `forwardRef`, updates
it with controlled React state, and shows the source DOM beside the generated
in-page PDF canvas. The fixture covers computed class styles, percentage table
cards, live canvas pixels, inline SVG, links, lists, and closed details state.

## Architecture

```text
HTML -> tokenizer -> flat DOM -> CSS cascade -> flat Box Tree
     -> font fallback/OpenType shaping -> block/inline/table layout -> pagination -> display list
     -> PDF writer -> WASM result handle -> Worker/TypeScript API
```

Core modules live under `src/`: `html.zig`, `dom.zig`, `css.zig`, `box.zig`,
`font.zig`, `harfbuzz.zig`, `unicode_case.zig`, `layout.zig`, `pagination.zig`, `display_list.zig`, `image.zig`,
`pdf.zig`, `render.zig`, and `wasm.zig`. The npm package lives in
`bindings/js/`; framework-agnostic browser verification lives in `tests/web/`
and the explicit React integration fixture lives in `tests/react/`.

## Licenses

Project code is MIT licensed. Bundled Noto Sans font software is distributed
under the SIL Open Font License 1.1; see `assets/fonts/OFL.txt` and the copy
included in the npm package. The vendored PDF.js display layer used only by the
optional in-page preview is distributed under Apache License 2.0; its license
is included in `dist/vendor/PDFJS-LICENSE.txt`. HarfBuzz is distributed under
its Old MIT license, included in `assets/harfbuzz/COPYING` and
`dist/vendor/HARFBUZZ-LICENSE.txt`. SheenBidi is distributed under Apache
License 2.0, included in `assets/sheenbidi/LICENSE` and
`dist/vendor/SHEENBIDI-LICENSE.txt`. libunibreak is distributed under the zlib
license, included in `assets/libunibreak/LICENCE` and
`dist/vendor/LIBUNIBREAK-LICENSE.txt`. Generated Unicode case-mapping data is
derived from Unicode 17.0.0 under Unicode License V3, included in
`assets/unicode/LICENSE.txt` and `dist/vendor/UNICODE-LICENSE.txt`.
