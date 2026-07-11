import { UnsupportedCompatibilityFeatureError } from "./errors.js";
import { PdfDocument } from "./pdf-document.js";
import { renderPdf } from "./renderer.js";
import type { Html2PdfOptions, HtmlSource, PageOptions, PdfOutputType, RenderOptions } from "./types.js";

export class CompatWorker implements PromiseLike<PdfDocument> {
  private source?: HtmlSource;
  private options: Html2PdfOptions = {};
  private pdfPromise: Promise<PdfDocument> | undefined;
  private tail: Promise<unknown> = Promise.resolve();

  from(source: HtmlSource, type?: "string" | "element" | "canvas" | "img"): this {
    if (type === "canvas" || type === "img") {
      throw new UnsupportedCompatibilityFeatureError(`from(..., ${type})`);
    }
    this.source = source;
    this.pdfPromise = undefined;
    return this;
  }

  set(options: Html2PdfOptions): this {
    if (options.html2canvas && Object.keys(options.html2canvas).length > 0) {
      throw new UnsupportedCompatibilityFeatureError("html2canvas options");
    }
    this.options = { ...this.options, ...options };
    this.pdfPromise = undefined;
    return this;
  }

  using(options: Html2PdfOptions): this {
    return this.set(options);
  }

  to(target: "pdf" | "container" | "canvas" | "img"): this {
    if (target === "pdf" || target === "container") return this.toPdf();
    throw new UnsupportedCompatibilityFeatureError(`to(${target})`);
  }

  toPdf(): this {
    this.tail = this.ensurePdf();
    return this;
  }

  toContainer(): this {
    return this;
  }

  toCanvas(): never {
    throw new UnsupportedCompatibilityFeatureError("toCanvas");
  }

  toImg(): never {
    throw new UnsupportedCompatibilityFeatureError("toImg");
  }

  save(filename = this.options.filename ?? "file.pdf"): this {
    this.tail = this.ensurePdf().then((pdf) => pdf.download(filename));
    return this;
  }

  saveAs(filename?: string): this {
    return this.save(filename);
  }

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

  output(type?: PdfOutputType, _options?: unknown, source: "pdf" | "img" = "pdf"): Promise<ArrayBuffer | Blob | string> {
    if (source === "img") return Promise.reject(new UnsupportedCompatibilityFeatureError("outputImg"));
    return this.outputPdf(type);
  }

  export(type?: PdfOutputType, options?: unknown, source?: "pdf" | "img"): Promise<ArrayBuffer | Blob | string> {
    return this.output(type, options, source);
  }

  outputImg(): Promise<never> {
    return Promise.reject(new UnsupportedCompatibilityFeatureError("outputImg"));
  }

  get(key: string, callback?: (value: unknown) => void): Promise<unknown> {
    const value = key === "pdf" ? this.ensurePdf() : Promise.resolve(this.options[key as keyof Html2PdfOptions]);
    return value.then((resolved) => {
      callback?.(resolved);
      return resolved;
    });
  }

  error(message: string): never {
    throw new Error(message);
  }

  then<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.tail.then(() => this.ensurePdf()).then(onFulfilled, onRejected);
  }

  thenCore<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  thenExternal<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  run<TResult1 = PdfDocument, TResult2 = never>(
    onFulfilled?: ((value: PdfDocument) => TResult1 | PromiseLike<TResult1>) | null,
    onRejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.then(onFulfilled, onRejected);
  }

  catch<TResult = never>(onRejected?: ((reason: unknown) => TResult | PromiseLike<TResult>) | null): Promise<PdfDocument | TResult> {
    return this.then(undefined, onRejected);
  }

  catchExternal<TResult = never>(onRejected?: ((reason: unknown) => TResult | PromiseLike<TResult>) | null): Promise<PdfDocument | TResult> {
    return this.catch(onRejected);
  }

  private ensurePdf(): Promise<PdfDocument> {
    if (!this.source) return Promise.reject(new Error("No HTML source was provided"));
    this.pdfPromise ??= renderPdf(this.source, compatRenderOptions(this.options));
    return this.pdfPromise;
  }
}

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
  if (options.filename !== undefined) renderOptions.filename = options.filename;
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

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => resolve(String(reader.result)), { once: true });
    reader.addEventListener("error", () => reject(reader.error), { once: true });
    reader.readAsDataURL(blob);
  });
}
