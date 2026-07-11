import html2pdf from "./compat.js";

export default html2pdf;
export { CompatWorker } from "./compat.js";
export * from "./errors.js";
export { PdfDocument } from "./pdf-document.js";
export { PdfPreview, type PdfPreviewOptions } from "./preview.js";
export { createRenderer, Html2RealPdf, renderPdf } from "./renderer.js";
export type * from "./types.js";
