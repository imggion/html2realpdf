/**
 * Browser-first HTML-to-PDF rendering with selectable text, native vectors,
 * typed configuration, and an html2pdf.js compatibility layer.
 *
 * @packageDocumentation
 */
import html2pdf from "./compat.js";

export default html2pdf;
export { CompatWorker } from "./compat.js";
export * from "./errors.js";
export { PdfDocument } from "./pdf-document.js";
export { PdfPreview, type PdfPreviewOptions, type PdfPreviewTheme } from "./preview.js";
export { createRenderer, Html2RealPdf, renderPdf } from "./renderer.js";
export type * from "./types.js";
