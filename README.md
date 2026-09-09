<div align="center">
  <img src="https://raw.githubusercontent.com/imggion/html2realpdf/main/docs/assets/html2realpdf-logo.webp" alt="html2realpdf logo" width="180">
  <h1>html2realpdf</h1>
  <p><strong>A real PDF, not a screenshot.</strong></p>
  <p>
    <a href="https://www.npmjs.com/package/@imggion/html2realpdf">
      <img src="https://img.shields.io/npm/v/@imggion/html2realpdf.svg?style=flat-square" alt="npm version">
    </a>
    <a href="https://github.com/imggion/html2realpdf/releases/tag/v0.2.0">
      <img src="https://img.shields.io/badge/release-0.2.0-2ea44f?style=flat-square" alt="Latest release: 0.2.0">
    </a>
    <a href="#compliance">
      <img src="https://img.shields.io/badge/PDF%2FA--3u-2ea44f?style=flat-square" alt="PDF/A-3u">
    </a>
    <a href="#compliance">
      <img src="https://img.shields.io/badge/PDF%2FA--3b-2ea44f?style=flat-square" alt="PDF/A-3b">
    </a>
    <img src="https://img.shields.io/badge/-zig-f39b34?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig">
    <img src="https://img.shields.io/badge/-WASM-654ff0?style=flat-square&amp;logo=webassembly&amp;logoColor=white" alt="WebAssembly">
    <img src="https://img.shields.io/badge/-TypeScript-3178c6?style=flat-square&amp;logo=typescript&amp;logoColor=white" alt="TypeScript">
  </p>
  <p>
    Generate selectable, searchable, vector-based PDFs from HTML in the browser.<br>
    Written in Zig, compiled to WebAssembly, and packaged with a typed TypeScript API.
  </p>
</div>

## Contents

- [Why real PDFs](#why-real-pdfs)
- [Install](#install)
- [Quick start](#quick-start)
- [React](#react)
- [Vue](#vue)
- [Preview](#preview)
- [Page layouts](#page-layouts)
- [PDF/A and attachments](#pdfa-and-attachments)
- [Compliance](#compliance)
- [Benchmark](#benchmark)
- [Contributing](#contributing)
- [License](#license)

## Why real PDFs

Screenshot-based PDF tools turn a page into an image. `html2realpdf` keeps text
as text, links as PDF annotations, fonts as embedded subsets, and supported
graphics as vectors.

The text includes Unicode mappings, so people can select, copy, and search the
result. Tools and LLMs can read the document text without first running OCR.
Text-heavy documents are also often smaller and stay sharp at every zoom level.

Zig performs the layout and PDF writing, while WebAssembly brings the renderer
to the browser. The result is one portable pipeline for invoices, reports,
tickets, letters, slides, and other web-generated documents.

See the [CSS support matrix](docs/css-support.md) for the current layout and
rendering coverage. The current release provides machine-readable text and accessible
preview controls; it does not claim PDF/UA or fully tagged PDF compliance.

## Install

Install the stable release with your package manager:

```sh
npm install @imggion/html2realpdf
pnpm add @imggion/html2realpdf
yarn add @imggion/html2realpdf
bun add @imggion/html2realpdf
```

## Quick start

Render an HTML element, download the PDF, then release its resources:

```ts
import { renderPdf } from "@imggion/html2realpdf";

const invoice = document.querySelector<HTMLElement>("#invoice");
if (!invoice) throw new Error("Invoice not found");

const pdf = await renderPdf(invoice);
pdf.download("invoice.pdf");
pdf.dispose();
```

HTML strings are supported too:

```ts
const pdf = await renderPdf("<h1>Hello from a real PDF</h1>");
```

PDF link annotations keep absolute `http`, `https`, `mailto`, `tel`, and `ftp`
URLs. Browser snapshots resolve relative links against `baseUrl` and canonicalize
international URLs; direct native/WASM input must already use canonical ASCII.
Unresolved, active, or local values such as `javascript`, `data`, and `file` are
removed. Set `enableLinks: false` to remove every link annotation.

## React

Pass a ref to a mounted element. The package understands React-shaped refs
without depending on React itself.

```tsx
const reportRef = useRef<HTMLDivElement>(null);

async function downloadReport() {
  if (!reportRef.current) return;

  const pdf = await renderPdf(reportRef);
  pdf.download("report.pdf");
  pdf.dispose();
}

return <Report ref={reportRef} />;
```

`Report` can be a component that forwards its ref to its root element. Pass the
mounted ref, not an unmounted component definition.

## Vue

Pass the mounted DOM element behind a template ref. With Vue 3.5 or newer,
`useTemplateRef()` keeps the element typed without wrapping the renderer in a
Vue-specific adapter.

```vue
<script setup lang="ts">
import { useTemplateRef } from "vue";
import { renderPdf } from "@imggion/html2realpdf";

const report = useTemplateRef<HTMLElement>("report");

async function downloadReport() {
  if (!report.value) return;

  const pdf = await renderPdf(report.value);
  try {
    pdf.download("report.pdf");
  } finally {
    pdf.dispose();
  }
}
</script>

<template>
  <article ref="report">
    <h1>Quarterly report</h1>
    <p>This content stays selectable in the PDF.</p>
  </article>

  <button type="button" @click="downloadReport">Download PDF</button>
</template>
```

On Vue 3.4 or earlier, use
`const report = ref<HTMLElement | null>(null)` with the same template ref and
pass `report.value` to `renderPdf()`.

## Preview

The preview renders the actual generated PDF inside your page. It uses isolated
Shadow DOM and canvas pages instead of an iframe, browser PDF plugin, or fake
HTML copy.

```ts
const pdf = await renderPdf(invoice);
const previewTarget = document.querySelector<HTMLElement>("#pdf-preview");
if (!previewTarget) throw new Error("Preview target not found");
const previousButton = document.querySelector<HTMLButtonElement>("#previous-page")!;
const nextButton = document.querySelector<HTMLButtonElement>("#next-page")!;
const pageCounter = document.querySelector<HTMLOutputElement>("#page-counter")!;

const preview = await pdf.preview(previewTarget, {
  initialScale: "fit-width",
  onPageChange(currentPage, totalPages) {
    pageCounter.textContent = `Page ${currentPage} of ${totalPages}`;
    previousButton.disabled = currentPage === 1;
    nextButton.disabled = currentPage === totalPages;
  },
});

previousButton.addEventListener("click", () => preview.previousPage());
nextButton.addEventListener("click", () => preview.nextPage());
preview.goToPage(7); // Clamped to the first or last page when outside the document range.
console.log(preview.currentPage); // 1-based and synchronized with manual scrolling

// Later, when closing the preview:
preview.dispose();
pdf.dispose();
```

## Page layouts

Use the named `a4` and `letter` formats in portrait or landscape mode. A4
landscape works well for presentation decks:

```ts
const pdf = await renderPdf(slides, {
  page: {
    format: "a4",
    orientation: "landscape",
    unit: "mm",
    margin: [12, 12],
  },
});
```

For postcards or any other size, pass custom `[width, height]` dimensions:

```ts
const pdf = await renderPdf(postcard, {
  page: { format: [148, 105], unit: "mm", margin: 8 },
});
```

## PDF/A and attachments

Opt into PDF/A-3u independently of the CSS profile:

```ts
const pdf = await renderPdf(invoice, {
  conformance: "pdfa-3u",
  metadata: { title: "Invoice" },
  attachments: [{
    name: "invoice.xml",
    data: new TextEncoder().encode(xml),
    mimeType: "application/xml",
    relationship: "Data",
  }],
});
```

The writer embeds sRGB, synchronized XMP metadata and Unicode font mappings.
Incompatible resources produce an error; there is no fallback to ordinary PDF.
CMYK JPEGs, missing glyphs and fonts that forbid outline embedding are rejected.
Transparency and supported SVG remain native PDF graphics. This is PDF/A-3u,
not a claim of Tagged PDF, PDF/UA, digital signatures or Factur-X compliance.

Attachments also work without `conformance`. Their bytes are preserved, and
caller buffers stay usable in both Worker and main-thread execution. MIME type
defaults to `application/octet-stream` and relationship to `Unspecified`.
Optional `description` and `modifiedAt: Date` are supported; dates are never
invented. Empty/duplicate names, malformed MIME types and invalid dates fail.
The html2pdf.js adapter accepts the same options through `.set(...)`.

See [PDF/A implementation and validation](https://github.com/imggion/html2realpdf/blob/main/docs/pdfa.md)
for limits and the pinned veraPDF gate. Existing calls without these options
keep their ordinary PDF output.

## Compliance

`html2realpdf` supports **PDF/A-3 (ISO 19005-3)** through the opt-in
`conformance: "pdfa-3u"` option. Ordinary PDF output is the default.

| Profile | Coverage |
| --- | --- |
| **PDF/A-3u** | Archival PDF with Unicode mappings for text. This is the profile declared by the generated file and checked by the automated veraPDF gate. |
| **PDF/A-3b** | The base archival requirements, also satisfied by a conforming PDF/A-3u file. There is no separate `pdfa-3b` API option. |

[veraPDF's conformance rules](https://github.com/veraPDF/veraPDF-validation-profiles/wiki/PDFA-Parts-2-and-3-rules#rule-664-3)
confirm that level B requirements are a subset of level U and that level B
validation accepts files declaring U.

The validation report below shows **test.pdf** passing the **PDF/A-3u**
profile with **veraPDF 1.30.2**: **14,749 passed checks and zero failed checks**.
It records the result for that file; validate your own generated documents too.

<p align="center">
  <img src="https://raw.githubusercontent.com/imggion/html2realpdf/main/docs/assets/pdfa-3u-validation.png" alt="veraPDF 1.30.2 report for test.pdf: PDF/A-3u validation passed, with 14,749 passed checks and zero failed checks." width="600">
</p>

Try it yourself: render a document with `conformance: "pdfa-3u"`, download it,
and open it in [veraPDF](https://verapdf.org/), or check both profiles with its
[CLI](https://docs.verapdf.org/cli/validation/):

```sh
verapdf --flavour 3u --format text invoice.pdf
verapdf --flavour 3b --format text invoice.pdf
```

Both checks should report **PASS**. To reproduce the repository's PDF/A-3u
validation suite, run `make test-pdfa` after the
[contributor setup](#contributing). It covers native and WASM fixtures,
text extraction, embedded files, visual checks and a 30-page benchmark.

## Benchmark

One recorded run of the deterministic 30-page stress report produced:

| Engine | First PDF | Warm render | File size | Pages | Content model |
| --- | ---: | ---: | ---: | ---: | --- |
| `html2realpdf` | 1595.9 ms | 1451.2 ms | 441.1 kB | 30 | Native/selectable PDF |
| `html2pdf.js` | 2124.6 ms | 1952.4 ms | 3.11 MB | 30 | Raster image PDF |

**Main differences versus html2pdf.js**

- **33.1% faster first PDF**
- **34.5% faster warm render**
- **85.8% smaller file**
- and, of course, a REAL PDF 😏

## Contributing

You need Zig `0.16.0`, Node.js `20.16+`, npm, and Make. The PDF/A gate
also needs Java 17+, Poppler, curl and unzip. On a fresh checkout,
install the JavaScript dependencies once:

```sh
npm ci --prefix bindings/js
npm ci --prefix tests/react
npm ci --prefix tests/web
```

| Command | Purpose |
| --- | --- |
| `make test` | Run the Zig and renderer tests |
| `make release` | Build the native release binary |
| `make wasm` | Build the default `ReleaseFast` WebAssembly and browser package |
| `make wasm-small` | Build the optional size-oriented `ReleaseSmall` package asset |
| `make react` | Start the React integration app |
| `make test-pdfa` | Validate PDF/A-3u with veraPDF 1.30.2 and benchmark 30 pages |
| `make test-release` | Run the complete release gate |

To open the small browser test harness:

```sh
make wasm
python3 -m http.server 8765
```

Visit [http://localhost:8765/tests/web/index.html](http://localhost:8765/tests/web/index.html).

## License

The project code is released under the MIT License. See [LICENSE.md](LICENSE.md)
for the complete project and third-party license inventory.
