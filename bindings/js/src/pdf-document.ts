import type { Diagnostic } from "./types.js";
import { PdfPreview, type PdfPreviewOptions } from "./preview.js";

export class PdfDocument {
  readonly diagnostics: readonly Diagnostic[];
  private readonly objectUrls = new Set<string>();
  private readonly previews = new Set<PdfPreview>();
  private disposed = false;

  private constructor(
    private readonly data: Uint8Array,
    readonly pageCount: number,
    diagnostics: readonly Diagnostic[] = [],
  ) {
    this.diagnostics = Object.freeze([...diagnostics]);
  }

  /** @internal */
  static create(data: Uint8Array, pageCount: number, diagnostics: readonly Diagnostic[] = []): PdfDocument {
    return new PdfDocument(data, pageCount, diagnostics);
  }

  toUint8Array(): Uint8Array {
    this.assertActive();
    return this.data.slice();
  }

  toArrayBuffer(): ArrayBuffer {
    return this.toUint8Array().buffer as ArrayBuffer;
  }

  toBlob(): Blob {
    this.assertActive();
    return new Blob([this.toArrayBuffer()], { type: "application/pdf" });
  }

  createObjectURL(): string {
    const url = URL.createObjectURL(this.toBlob());
    this.objectUrls.add(url);
    return url;
  }

  revokeObjectURL(url: string): void {
    if (!this.objectUrls.delete(url)) return;
    URL.revokeObjectURL(url);
  }

  async preview(target: HTMLElement, options: PdfPreviewOptions = {}): Promise<PdfPreview> {
    this.assertActive();
    let preview: PdfPreview | undefined;
    preview = await PdfPreview.open(target, this.data, this.pageCount, options, () => {
      if (preview) this.previews.delete(preview);
    });
    this.previews.add(preview);
    return preview;
  }

  download(filename = "file.pdf"): void {
    const url = this.createObjectURL();
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    queueMicrotask(() => this.revokeObjectURL(url));
  }

  dispose(): void {
    if (this.disposed) return;
    for (const preview of this.previews) preview.dispose();
    this.previews.clear();
    for (const url of this.objectUrls) URL.revokeObjectURL(url);
    this.objectUrls.clear();
    this.disposed = true;
  }

  private assertActive(): void {
    if (this.disposed) throw new Error("PdfDocument has been disposed");
  }
}
