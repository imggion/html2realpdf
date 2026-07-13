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
