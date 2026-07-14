/**
 * PDF-oriented html2pdf.js compatibility chain over the native renderer.
 *
 * @packageDocumentation
 */

import { UnsupportedCompatibilityFeatureError } from "./errors.js";
import { PdfDocument } from "./pdf-document.js";
import { renderPdf } from "./renderer.js";
import type { Html2PdfOptions, HtmlSource, PageOptions, PdfOutputType, RenderOptions } from "./types.js";

/**
 * Stateful, Promise-like compatibility chain.
 *
 * @remarks
 * The worker caches one `PdfDocument` until its source or options change.
 * Raster-only html2pdf.js stages fail explicitly rather than silently changing
 * the native PDF model.
 */
export class CompatWorker implements PromiseLike<PdfDocument> {
  private source?: HtmlSource;
  private options: Html2PdfOptions = {};
  private pdfPromise: Promise<PdfDocument> | undefined;
  private tail: Promise<unknown> = Promise.resolve();

  /** Sets the HTML source; canvas and image input stages are unsupported. */
  from(source: HtmlSource, type?: "string" | "element" | "canvas" | "img"): this {
    if (type === "canvas" || type === "img") {
      throw new UnsupportedCompatibilityFeatureError(`from(..., ${type})`);
    }
    this.source = source;
    this.pdfPromise = undefined;
    return this;
  }

  /** Shallow-merges supported compatibility options and invalidates cached output. */
  set(options: Html2PdfOptions): this {
    if (options.html2canvas !== undefined) {
      throw new UnsupportedCompatibilityFeatureError("html2canvas options");
    }
    if (options.image !== undefined) {
      throw new UnsupportedCompatibilityFeatureError("image options");
    }
    this.options = { ...this.options, ...options };
    this.pdfPromise = undefined;
    return this;
  }

  /** Alias for `set`, retained for html2pdf.js chain compatibility. */
  using(options: Html2PdfOptions): this {
    return this.set(options);
  }

  /**
   * Advances to PDF output for `pdf` or `container` targets.
   *
   * @remarks
   * The wrapper has no public intermediate container. A `container` target
   * therefore schedules the PDF directly; canvas and image targets throw.
   */
  to(target: "pdf" | "container" | "canvas" | "img"): this {
    if (target === "pdf" || target === "container") return this.toPdf();
    throw new UnsupportedCompatibilityFeatureError(`to(${target})`);
  }

  /** Schedules PDF rendering while preserving the fluent chain. */
  toPdf(): this {
    this.tail = this.ensurePdf();
    return this;
  }

  /** Compatibility no-op; no intermediate snapshot container is exposed. */
  toContainer(): this {
    return this;
  }

  /** Always throws because full-page canvas output is intentionally unsupported. */
  toCanvas(): never {
    throw new UnsupportedCompatibilityFeatureError("toCanvas");
  }

  /** Always throws because raster image output is intentionally unsupported. */
  toImg(): never {
    throw new UnsupportedCompatibilityFeatureError("toImg");
  }

  /** Schedules a browser download using the explicit or configured filename. */
  save(filename = this.options.filename ?? "file.pdf"): this {
    this.tail = this.ensurePdf().then((pdf) => pdf.download(filename));
    return this;
  }

  /** Alias for `save`. */
  saveAs(filename?: string): this {
    return this.save(filename);
  }

  /**
   * Resolves PDF output in a compatibility encoding.
   *
   * @remarks
   * Blob URL outputs remain owned by the cached `PdfDocument`. Obtain it with
   * `get("pdf")` to revoke the URL, or dispose the document when finished.
   */
  outputPdf(type?: "blob"): Promise<Blob>;
  outputPdf(type: "arraybuffer"): Promise<ArrayBuffer>;
  outputPdf(type: StringPdfOutputType): Promise<string>;
  outputPdf(type: PdfOutputType): Promise<ArrayBuffer | Blob | string>;
  async outputPdf(type: PdfOutputType = "blob"): Promise<ArrayBuffer | Blob | string> {
    const pdf = await this.ensurePdf();
    switch (type) {
      case "arraybuffer": return pdf.toArrayBuffer();
      case "blob": return pdf.toBlob();
      case "bloburl":
      case "bloburi": return pdf.createObjectURL();
      case "datauristring":
      case "dataurlstring": return blobToDataUrl(pdf.toBlob());
    }
  }

  /** Routes generic html2pdf.js output requests to PDF output. */
  output(type?: "blob", options?: unknown, source?: "pdf"): Promise<Blob>;
  output(type: "arraybuffer", options?: unknown, source?: "pdf"): Promise<ArrayBuffer>;
  output(type: StringPdfOutputType, options?: unknown, source?: "pdf"): Promise<string>;
  output(type: PdfOutputType | undefined, options: unknown, source: "img"): Promise<never>;
  output(type?: PdfOutputType, options?: unknown, source?: "pdf" | "img"): Promise<ArrayBuffer | Blob | string>;
  output(type?: PdfOutputType, _options?: unknown, source: "pdf" | "img" = "pdf"): Promise<ArrayBuffer | Blob | string> {
    if (source === "img") return Promise.reject(new UnsupportedCompatibilityFeatureError("outputImg"));
    return type === undefined ? this.outputPdf() : this.outputPdf(type);
  }

  /** Alias for `output`. */
  export(type?: "blob", options?: unknown, source?: "pdf"): Promise<Blob>;
  export(type: "arraybuffer", options?: unknown, source?: "pdf"): Promise<ArrayBuffer>;
  export(type: StringPdfOutputType, options?: unknown, source?: "pdf"): Promise<string>;
  export(type: PdfOutputType | undefined, options: unknown, source: "img"): Promise<never>;
  export(type?: PdfOutputType, options?: unknown, source?: "pdf" | "img"): Promise<ArrayBuffer | Blob | string>;
  export(type?: PdfOutputType, options?: unknown, source?: "pdf" | "img"): Promise<ArrayBuffer | Blob | string> {
    return this.output(type, options, source);
  }

  /** Returns a rejected promise because raster image output is unsupported. */
  outputImg(): Promise<never> {
    return Promise.reject(new UnsupportedCompatibilityFeatureError("outputImg"));
  }

  /**
   * Resolves the cached PDF for `pdf`, or a configured compatibility option for
   * any other key, then optionally invokes the legacy callback.
   */
  get(key: string, callback?: (value: unknown) => void): Promise<unknown> {
    const value = key === "pdf" ? this.ensurePdf() : Promise.resolve(this.options[key as keyof Html2PdfOptions]);
    return value.then((resolved) => {
      callback?.(resolved);
      return resolved;
    });
  }

  /** Interrupts a chain by throwing the supplied message as an `Error`. */
  error(message: string): never {
    throw new Error(message);
  }

  /** Makes the chain awaitable and resolves it to the cached `PdfDocument`. */
  then<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.tail.then(() => this.ensurePdf()).then(onFulfilled, onRejected);
  }

  /** Compatibility alias for `then`. */
  thenCore<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  /** Compatibility alias for `then`. */
  thenExternal<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  /** Compatibility alias for `then`. */
  run<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  /** Handles a failed chain while preserving `PdfDocument` as the success type. */
  catch<TResult = never>(onRejected?: ((reason: unknown) => TResult | PromiseLike<TResult>) | null): Promise<PdfDocument | TResult> {
    return this.then(undefined, onRejected);
  }

  /** Compatibility alias for `catch`. */
  catchExternal<TResult = never>(onRejected?: ((reason: unknown) => TResult | PromiseLike<TResult>) | null): Promise<PdfDocument | TResult> {
    return this.catch(onRejected);
  }

  private ensurePdf(): Promise<PdfDocument> {
    if (!this.source) return Promise.reject(new Error("No HTML source was provided"));
    this.pdfPromise ??= renderPdf(this.source, compatRenderOptions(this.options));
    return this.pdfPromise;
  }
}

/**
 * Creates an html2pdf.js-compatible PDF chain.
 *
 * @remarks
 * Passing a source directly preserves html2pdf.js shorthand behavior and also
 * schedules `save`. Call without a source when composing an explicit chain.
 *
 * @example
 * ```ts
 * await html2pdf()
 *   .set({ filename: "invoice.pdf", margin: [10, 12] })
 *   .from(element)
 *   .save();
 * ```
 */
export default function html2pdf(source?: HtmlSource, options?: Html2PdfOptions): CompatWorker {
  const worker = new CompatWorker();
  if (options) worker.set(options);
  if (source) worker.from(source).save();
  return worker;
}

html2pdf.Worker = CompatWorker;

function compatRenderOptions(options: Html2PdfOptions): RenderOptions {
  const page: PageOptions = { unit: options.jsPDF?.unit ?? "mm" };
  if (options.jsPDF?.format !== undefined) page.format = options.jsPDF.format;
  if (options.jsPDF?.orientation !== undefined) page.orientation = options.jsPDF.orientation;
  if (options.margin !== undefined) page.margin = options.margin;

  const renderOptions: RenderOptions = { page };
  if (options.enableLinks !== undefined) renderOptions.enableLinks = options.enableLinks;
  if (options.pagebreak) {
    const modes = typeof options.pagebreak.mode === "string"
      ? [options.pagebreak.mode]
      : options.pagebreak.mode ?? ["css", "legacy"];
    const pageBreak: NonNullable<RenderOptions["pageBreak"]> = {
      legacy: modes.includes("legacy"),
      avoidAll: modes.includes("avoid-all"),
    };
    if (options.pagebreak.before !== undefined) pageBreak.before = options.pagebreak.before;
    if (options.pagebreak.after !== undefined) pageBreak.after = options.pagebreak.after;
    if (options.pagebreak.avoid !== undefined) pageBreak.avoid = options.pagebreak.avoid;
    renderOptions.pageBreak = pageBreak;
  }
  return renderOptions;
}

type StringPdfOutputType = Exclude<PdfOutputType, "arraybuffer" | "blob">;

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => resolve(String(reader.result)), { once: true });
    reader.addEventListener("error", () => reject(reader.error), { once: true });
    reader.readAsDataURL(blob);
  });
}
