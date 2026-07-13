# @imggion/html2realpdf

Browser-first HTML-to-PDF rendering powered by Zig and WebAssembly. Text,
vectors, links, and images are emitted as native PDF objects instead of a
full-page screenshot.

## Install

```sh
npm install @imggion/html2realpdf@next
```

The package is ESM and includes TypeScript declarations, its Worker, WASM, and
PDF.js preview assets. Imports are SSR-safe; rendering requires browser DOM APIs.
Import values and types only from `@imggion/html2realpdf`.

## Choose an API

| Need | API | Lifetime |
| --- | --- | --- |
| Default rendering with minimal setup | `renderPdf` | Cached package Worker for the application lifetime |
| Repeated renders, custom fonts, or explicit cleanup | `createRenderer` | Caller-owned renderer |
| Migration from supported html2pdf.js chains | Default `html2pdf` export | Compatibility worker with a cached PDF |

Use the modern API for new integrations. The compatibility API deliberately
rejects stages that depend on html2canvas or rasterized PDF pages.

## Sources

`renderPdf` and `renderer.render` accept:

```ts
type HtmlSource = string | Element | { readonly current: Element | null };
```

- A mounted `Element` preserves computed styles, pseudo-elements, live form
  state, canvas pixels, and other browser state.
- A ref-shaped object supports React refs without adding React as a dependency.
- An HTML string runs in an inert, CSP-restricted document. Scripts, event
  handlers, refresh directives, and active elements are removed.

Prefer a mounted source when output must match live UI state. Render refs only
after they are mounted; a null ref produces `InvalidSourceError`.

## Render once

```ts
import { renderPdf, type RenderOptions } from "@imggion/html2realpdf";

const options: RenderOptions = {
  page: { format: "a4", unit: "mm", margin: [15, 12] },
  cssProfile: "web",
  mediaType: "print",
  fallback: "error",
  metadata: { title: "Invoice 2026-001" },
};

const pdf = await renderPdf(document.querySelector("#invoice")!, options);
try {
  pdf.download("invoice.pdf");
} finally {
  pdf.dispose();
}
```

`renderPdf` lazily creates and caches a default Worker renderer. Use an explicit
renderer when the backend must be disposed, configured with fonts, or forced to
the main thread.

## Reuse a renderer

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
    // Store or upload the Blob.
  } finally {
    pdf.dispose();
  }
} finally {
  renderer.dispose();
}
```

Worker execution is the default because synchronous WASM work would otherwise
occupy the UI thread. Use `execution: "main"` only when Workers are unavailable
or a controlled environment requires it. Override `wasmUrl` only when a deploy
cannot serve package-relative assets. The published default asset is built with
`ReleaseFast`. Repository consumers that prioritize transfer size can build the
same ABI with `npm run build:small` and serve that asset through `wasmUrl`.

## Render options

### Page and CSS

| Option | Default | Contract |
| --- | --- | --- |
| `page` | Captured `@page`, then A4 portrait with zero margins | Explicit API geometry wins over captured page geometry. Custom dimensions and margins use `page.unit`. |
| `cssProfile` | `"document"` | `document` favors paged reports; `web` adds broader browser layout; `strict` uses web layout and rejects unsupported CSS by default. |
| `unsupportedCss` | `"error"` in strict mode, otherwise `"warn"` | `warn` records diagnostics, `error` rejects, and `ignore` omits silently. |
| `strict` | `false` | Promotes unsupported snapshot CSS to errors but does not select the `web` layout profile. Explicit `unsupportedCss` wins. |
| `mediaType` | `"screen"` | Selects the media environment used during style resolution. |
| `viewport` | Source environment | Makes responsive layout and media queries deterministic. |

Named page formats retain their physical dimensions regardless of `unit`.
Custom `[width, height]` formats use that unit. Four-value margins follow
html2pdf.js order `[top, left, bottom, right]`, not CSS shorthand order.

### Resources and browser state

| Option | Default | Contract |
| --- | --- | --- |
| `baseUrl` | Source document URL | Resolves relative stylesheets and images. |
| `resourcePolicy` | `"error"` | `omit` removes failed resources and records `RESOURCE_OMITTED`. |
| `resourceResolver` | None | Resolves protected or virtual images and stylesheets. Fonts are renderer registrations. |
| `includeShadowDom` | `false` | Flattens open Shadow DOM only. Closed roots are inaccessible. |
| `enableLinks` | `true` | Set to `false` to remove link targets before rendering. |

The resolver receives `{ kind: "image" | "stylesheet", url }`. For a
stylesheet, a returned string is CSS source. For an image, a string is a
supported data URL or replacement URL. Returning `null` applies
`resourcePolicy`.

External stylesheets in HTML-string input are inert and must be supplied by the
resolver. Mounted DOM input can use stylesheets already accessible through the
browser CSSOM.

### SVG and canvas

| Option | Default | Contract |
| --- | --- | --- |
| `fallback` | `"error"` | Unsupported SVG fails unless `"rasterize-subtree"` explicitly permits scoped rasterization. |
| `canvasToSvg` | None | Converts live canvases through a chart library's SVG exporter. Without it, canvases become transparent PNG images. |
| `canvasFallback` | `"error"` | `"rasterize"` applies only when the adapter returns `null`. |

```ts
const pdf = await renderer.render(dashboardElement, {
  canvasToSvg: ({ canvas, cssWidth, cssHeight }) =>
    chartFor(canvas).toSvg({ width: cssWidth, height: cssHeight }),
  canvasFallback: "error",
  fallback: "error",
});
```

The adapter may return a complete SVG string, an `image/svg+xml` Blob, an
`SVGSVGElement`, or a promise. A thrown error or malformed SVG produces
`CanvasToSvgError`; it does not activate `canvasFallback`. A valid SVG that uses
unsupported vector features follows the separate `fallback` policy.

Scoped rasterization records `CSS_SUBTREE_RASTERIZED` or
`CANVAS_SUBTREE_RASTERIZED`. Inspect diagnostics before describing output as
fully vector.

### Pagination, metadata, cancellation, and progress

`pageBreak.before`, `after`, and `avoid` accept selectors or selector arrays.
`legacy` honors `.html2pdf__page-break`; `avoidAll` applies
`break-inside: avoid` globally. These rules override computed snapshot defaults
without overriding authored inline `!important` declarations.

`metadata` accepts `title`, `author`, `subject`, `keywords`, and `creator`.
`keywords` may be a string or an array.

`signal` rejects at snapshot and render boundaries. It cannot preempt a
synchronous WASM render already running. `onProgress` reports the coarse phases
`snapshot`, `wasm`, and `complete`; it is not per-page progress.

## PDF output and preview

`PdfDocument` exposes immutable output through:

- `toUint8Array()`, `toArrayBuffer()`, and `toBlob()`;
- `download(filename)`;
- `createObjectURL()` and `revokeObjectURL(url)`;
- `preview(target, options)`;
- `pageCount` and `diagnostics`.

Byte methods return defensive copies. `PdfDocument.dispose()` disposes every
preview it owns, revokes tracked object URLs, and invalidates future exports.
Manually revoke long-lived object URLs earlier when possible.

```ts
const preview = await pdf.preview(document.querySelector("#preview")!, {
  initialScale: "fit-width",
  minScale: 0.25,
  maxScale: 3,
  zoomStep: 0.25,
  maxPixelRatio: 2,
  onProgress: (completed, total) => updatePreviewProgress(completed, total),
});

await preview.setScale(1.25);
await preview.fitToWidth();
preview.dispose();
```

The preview renders every page into an isolated Shadow DOM canvas viewer. It
does not use iframe, object, embed, or the browser PDF plugin.

## Diagnostics and errors

Successful documents may contain structured diagnostics with a stable `code`,
`severity`, and `message`, plus optional `property`, `nodePath`, `phase`, and
`fallback`. Use `unsupportedCss: "error"`, `fallback: "error"`, and
`resourcePolicy: "error"` when omissions must reject the operation.

The package exports these error classes:

- `Html2RealPdfError`, the base class with a machine-readable `code`;
- `UnsupportedEnvironmentError`;
- `InvalidSourceError`;
- `UnsupportedCssError`;
- `WasmRenderError`, including a native or bridge `status`;
- `ResourceLoadError`;
- `CanvasToSvgError`, including `nodePath`;
- `UnsupportedCompatibilityFeatureError`.

Cancellation normally rejects with `AbortError`. Invalid page margins produce a
`RangeError`; lifecycle misuse after disposal produces a regular `Error`.

## html2pdf.js compatibility

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

| Compatibility surface | Status |
| --- | --- |
| `from(string | Element | ref)` | Supported |
| `set`, `using` | Supported for typed PDF options |
| `toPdf`, `save`, `saveAs` | Supported |
| `outputPdf`, `output`, `export` | Blob, ArrayBuffer, Blob URL, and data URL supported |
| `get`, Promise-like chaining | Supported |
| `toContainer` | Chain-preserving no-op; no intermediate container is exposed |
| `to("container")` | Schedules PDF output directly |
| Canvas or image input stages | Unsupported |
| `toCanvas`, `toImg`, `outputImg` | Throw `UnsupportedCompatibilityFeatureError` |
| `html2canvas` and raster `image` options | Rejected explicitly |

Passing a source directly to `html2pdf(source, options)` also schedules `save`,
matching the shorthand compatibility behavior.

Blob URL outputs remain owned by the cached `PdfDocument`. Retrieve it with
`await worker.get("pdf")` to revoke an individual URL or dispose the document.

## Runtime and licensing

- Rendering requires a browser with DOM, WebAssembly, Worker, and Blob support.
- Node.js `20.16+` is required for package build tooling, not browser rendering.
- Project code is MIT licensed. `dist/LICENSE.md` contains the consolidated
  project and third-party license inventory.

## Share without the npm registry

Run `npm pack` from this package directory and send the generated
`imggion-html2realpdf-0.1.0-rc2.tgz` file. A consumer can install it with:

```sh
npm install ./imggion-html2realpdf-0.1.0-rc2.tgz
# or
pnpm add ./imggion-html2realpdf-0.1.0-rc2.tgz
# or
yarn add file:./imggion-html2realpdf-0.1.0-rc2.tgz
```

The packaged model instructions live at `skills/html2realpdf/SKILL.md`.
