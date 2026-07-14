---
name: html2realpdf
description: Integrate and troubleshoot @imggion/html2realpdf in browser TypeScript or JavaScript projects. Use when rendering HTML strings, DOM elements, or React-compatible refs to selectable PDFs; configuring pages, resources, fonts, SVG or canvas output; previewing, downloading, or exporting PDFs; inspecting diagnostics; or migrating supported html2pdf.js chains.
---

# Use html2realpdf

Install the ESM package and import only from its public root:

```sh
npm install @imggion/html2realpdf
```

The module is safe to import during SSR, but call rendering APIs only in a
browser. Do not deep-import `dist` files or construct exported result classes.

## Choose the API

- Use `renderPdf` for convenient page-lifetime rendering.
- Use `createRenderer` for repeated renders, custom fonts, explicit Worker
  selection, or deterministic disposal.
- Use the default export only when adapting a supported html2pdf.js chain.
- Prefer a mounted `Element` or ref-shaped `{ current }` value when computed
  styles, form state, pseudo-elements, canvas pixels, or Shadow DOM matter.

```ts
import { renderPdf, type RenderOptions } from "@imggion/html2realpdf";

const options: RenderOptions = {
  page: { format: "a4", unit: "mm", margin: [15, 12] },
  cssProfile: "web",
  mediaType: "print",
  fallback: "error",
};

const pdf = await renderPdf(document.querySelector("#invoice")!, options);
try {
  pdf.download("invoice.pdf");
  console.table(pdf.diagnostics);
} finally {
  pdf.dispose();
}
```

Treat four-value margins as `[top, left, bottom, right]`, matching the
html2pdf.js compatibility API rather than CSS shorthand order.

## Configuration reference

Use these tables as the quick option reference. Treat the package's generated
TypeScript declarations as authoritative when the installed version differs.

### Renderer lifetime

Pass only renderer-owned resources and execution settings to `createRenderer`:

| Option | Values and default | Use |
| --- | --- | --- |
| `execution` | `"worker"` (default) or `"main"` | Keep synchronous WASM work off the UI thread unless Worker execution is unavailable. |
| `wasmUrl` | `string \| URL`; package-relative WASM by default | Override only when deployment cannot serve the bundled asset. |
| `fonts` | `FontRegistration[]`; none by default | Register reusable TrueType faces once for every render owned by this renderer. |

Configure each font registration with `family`, binary `data`, optional
`weight` (`400` by default, or `"normal"`/`"bold"`), and optional `style`
(`"normal"` by default or `"italic"`).

### Per-render options

Pass these options to `renderPdf` or `renderer.render`:

| Option | Values and default | Use |
| --- | --- | --- |
| `page` | Captured `@page`, otherwise A4 portrait with zero margins | Override captured page geometry explicitly. See page settings below. |
| `cssProfile` | `"document"` (default), `"web"`, or `"strict"` | Select stable report layout, broader browser layout, or broader layout with rejection defaults. |
| `strict` | `false` | Promote unsupported snapshot CSS to errors without selecting the web profile. Explicit `unsupportedCss` wins. |
| `mediaType` | `"screen"` (default) or `"print"` | Select the media environment used for computed styles and media queries. |
| `layoutContext` | `"source"` (default) or `"page"` | Preserve the mounted root width or reflow an implicit root width and auto inline margins against the PDF content box. |
| `viewport` | `{ width, height }`; source environment by default | Make responsive layout deterministic in CSS pixels. |
| `unsupportedCss` | `"warn"` (default), `"error"`, or `"ignore"`; strict modes default to `"error"` | Choose whether unsupported CSS records diagnostics, rejects, or is omitted silently. |
| `fallback` | `"error"` (default) or `"rasterize-subtree"` | Keep unsupported SVG native-only or allow explicit scoped rasterization. |
| `canvasToSvg` | Adapter function; none by default | Convert live canvas charts to validated SVG through the source library's exporter. |
| `canvasFallback` | `"error"` (default) or `"rasterize"` | Handle an intentional `null` result from `canvasToSvg`; thrown or malformed output still rejects. |
| `includeShadowDom` | `false` | Flatten open Shadow DOM into the snapshot; closed roots remain inaccessible. |
| `baseUrl` | `string \| URL`; source document URL by default | Resolve relative image and stylesheet URLs. |
| `resourcePolicy` | `"error"` (default) or `"omit"` | Reject failed resources or omit them with diagnostics. |
| `resourceResolver` | Resolver function; none by default | Supply protected or virtual images and stylesheets. Register fonts on the renderer instead. |
| `pageBreak` | `PageBreakRules`; none by default | Add selector-driven pagination overrides while retaining authored CSS breaks. |
| `metadata` | `PdfMetadata`; none by default | Write `title`, `author`, `subject`, `keywords`, and `creator` into the PDF information dictionary. |
| `enableLinks` | `true` | Preserve PDF link annotations; set `false` to remove captured link targets. |
| `signal` | `AbortSignal`; none by default | Cancel at snapshot and render boundaries; synchronous WASM already in progress cannot be preempted. |
| `onProgress` | Callback; none by default | Receive coarse `snapshot`, `wasm`, and `complete` phase updates, not per-page progress. |

Configure explicit `page` geometry with:

| Page option | Values and default |
| --- | --- |
| `format` | `"a4"` (default), `"letter"`, or custom `[width, height]` |
| `orientation` | `"portrait"` (default) or `"landscape"` |
| `unit` | `"pt"` (default), `"px"`, `"mm"`, `"cm"`, or `"in"` |
| `margin` | One number, `[vertical, horizontal]`, or `[top, left, bottom, right]`; zero by default |

Named formats retain their physical dimensions regardless of `unit`; custom
dimensions and margins use the selected unit. Reject margins that leave no
positive content area.

Configure `pageBreak` with selector strings or arrays in `before`, `after`, and
`avoid`. Set `avoidAll: true` to apply `break-inside: avoid` globally. Set
`legacy: true` to honor `.html2pdf__page-break`. Authored inline `!important`
break declarations retain precedence.

### Preview options

Pass these options to `PdfDocument.preview`:

| Option | Values and default |
| --- | --- |
| `initialScale` | `"fit-width"` (default) or a numeric scale |
| `minScale` | `0.25` by default, clamped to at least `0.1` |
| `maxScale` | `3` by default, clamped to at least `minScale` |
| `zoomStep` | `0.25` by default, clamped to at least `0.05` |
| `maxPixelRatio` | `2` by default; caps page-canvas device pixel ratio |
| `ariaLabel` | `"PDF preview"` by default |
| `onProgress` | Callback after each page canvas completes |

### html2pdf.js compatibility options

Use the default export only for this supported PDF-oriented option subset:

| Option | Values and default | Compatibility |
| --- | --- | --- |
| `margin` | Same one-, two-, or four-value forms as modern `page.margin` | Supported |
| `filename` | `"file.pdf"` | Used by `save` when no method argument is supplied. |
| `enableLinks` | `true` | Supported |
| `pagebreak.mode` | `"css"`, `"legacy"`, `"avoid-all"`, or an array; `css` and `legacy` when the `pagebreak` object omits `mode` | Supported; authored CSS breaks remain native. |
| `pagebreak.before` / `after` / `avoid` | Selector string or array | Supported |
| `jsPDF.unit` | `"mm"` by compatibility default; modern supported units only | Supported |
| `jsPDF.format` | `"a4"`, `"letter"`, or custom dimensions | Supported |
| `jsPDF.orientation` | `"portrait"` or `"landscape"` | Supported |
| `html2canvas` | No supported value | Reject explicitly; there is no full-page canvas pipeline. |
| `image` | No supported value | Reject explicitly; PDF pages are not encoded as raster images. |

## Reuse a renderer

Register embeddable TrueType fonts during renderer creation. Keep the renderer
for a batch of documents, then dispose it.

```ts
import { createRenderer } from "@imggion/html2realpdf";

const renderer = await createRenderer({
  execution: "worker",
  fonts: [{
    family: "Inter",
    data: await (await fetch("/fonts/Inter-Regular.ttf")).arrayBuffer(),
    weight: 400,
    style: "normal",
  }],
});

try {
  const pdf = await renderer.render(
    '<p style="font-family: Inter">Selectable text</p>',
  );
  try {
    const blob = pdf.toBlob();
    // Store or upload blob.
  } finally {
    pdf.dispose();
  }
} finally {
  renderer.dispose();
}
```

Use `execution: "main"` only when Worker execution is unavailable. Override
`wasmUrl` only for a deployment that cannot serve package-relative assets.

## Preview and export

Use `toBlob`, `toArrayBuffer`, or `toUint8Array` for application-owned output.
Use `createObjectURL` with `revokeObjectURL` when managing a URL manually.
Dispose previews before their document, or let `PdfDocument.dispose()` dispose
all previews it owns.

```ts
const preview = await pdf.preview(document.querySelector("#preview")!, {
  initialScale: "fit-width",
});

preview.dispose();
pdf.dispose();
```

## Resolve resources and browser state

- Set `baseUrl` for relative URLs.
- Use `resourceResolver` for images and stylesheets that cannot be fetched
  directly. Register fonts through `createRenderer`, not the resolver.
- Remember that stylesheets in HTML-string input are inert unless the resolver
  supplies them.
- Inspect `pdf.diagnostics`; use `strict`, `unsupportedCss`, and
  `fallback: "error"` when unsupported output must fail.
- Opt into `fallback: "rasterize-subtree"` only for the affected unsupported
  SVG subtree. Never describe the result as fully vector after fallback.
- Check an `AbortSignal` result normally, but do not assume an already-running
  synchronous WASM render can be preempted.

For a live canvas chart, prefer the chart library's SVG exporter:

```ts
const pdf = await renderer.render(dashboardElement, {
  canvasToSvg: ({ canvas, cssWidth, cssHeight }) =>
    chartFor(canvas).toSvg({ width: cssWidth, height: cssHeight }),
  canvasFallback: "error",
  fallback: "error",
});
```

## Use React refs

Keep the package framework-agnostic. Call it from client-side code after the
ref is mounted; do not add React as a wrapper dependency.

```tsx
const reportRef = useRef<HTMLDivElement>(null);

async function downloadReport() {
  if (!reportRef.current) return;
  const pdf = await renderPdf(reportRef, { cssProfile: "web" });
  try {
    pdf.download("report.pdf");
  } finally {
    pdf.dispose();
  }
}
```

## Migrate html2pdf.js chains

Use only PDF-oriented compatibility stages:

```ts
import html2pdf from "@imggion/html2realpdf";

await html2pdf()
  .set({
    filename: "invoice.pdf",
    margin: [10, 12],
    jsPDF: { format: "a4", unit: "mm", orientation: "portrait" },
  })
  .from(document.querySelector("#invoice")!)
  .save();
```

Do not use `toCanvas`, `toImg`, `outputImg`, canvas/image input stages,
`html2canvas` options, or raster `image` options. They throw
`UnsupportedCompatibilityFeatureError` by design.

Use the package's generated declarations as the complete option and return-type
reference. Keep examples aligned with public root exports.
