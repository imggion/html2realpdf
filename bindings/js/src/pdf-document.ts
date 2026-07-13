/**
 * Immutable PDF output and ownership of previews and object URLs derived from it.
 *
 * @packageDocumentation
 */

import type { Diagnostic } from "./types.js";
import { PdfPreview, type PdfPreviewOptions } from "./preview.js";

/**
 * Successful PDF output returned by the renderer.
 *
 * @remarks
 * Byte exports are defensive copies. The document owns previews and object URLs
 * created through it; `dispose` releases them and invalidates future exports.
 * Instances are renderer-owned results and cannot be constructed directly.
 */
export class PdfDocument {
  /** Diagnostics retained from both browser snapshotting and native rendering. */
  readonly diagnostics: readonly Diagnostic[];
  private readonly objectUrls = new Set<string>();
  private readonly previews = new Set<PdfPreview>();
  private disposed = false;

  private constructor(
    private readonly data: Uint8Array,
    /** Number of pages reported by the native renderer. */
    readonly pageCount: number,
    diagnostics: readonly Diagnostic[] = [],
  ) {
    this.diagnostics = Object.freeze([...diagnostics]);
  }

  /** @internal */
  static create(data: Uint8Array, pageCount: number, diagnostics: readonly Diagnostic[] = []): PdfDocument {
    return new PdfDocument(data, pageCount, diagnostics);
  }

  /** Returns a defensive copy of the PDF bytes. */
  toUint8Array(): Uint8Array {
    this.assertActive();
    return this.data.slice();
  }

  /** Returns a standalone copy suitable for storage or transfer APIs. */
  toArrayBuffer(): ArrayBuffer {
    return this.toUint8Array().buffer as ArrayBuffer;
  }

  /** Returns a new `application/pdf` Blob. */
  toBlob(): Blob {
    this.assertActive();
    return new Blob([this.toArrayBuffer()], { type: "application/pdf" });
  }

  /**
   * Creates an object URL tracked by this document.
   *
   * @remarks Revoke long-lived URLs explicitly or let `dispose` revoke them.
   */
  createObjectURL(): string {
    const url = URL.createObjectURL(this.toBlob());
    this.objectUrls.add(url);
    return url;
  }

  /** Revokes an object URL previously created by this document. */
  revokeObjectURL(url: string): void {
    if (!this.objectUrls.delete(url)) return;
    URL.revokeObjectURL(url);
  }

  /**
   * Replaces a target's contents with the package canvas preview.
   *
   * @remarks The returned preview is owned by this document until separately disposed.
   */
  async preview(target: HTMLElement, options: PdfPreviewOptions = {}): Promise<PdfPreview> {
    this.assertActive();
    let preview: PdfPreview | undefined;
    preview = await PdfPreview.open(target, this.data, this.pageCount, options, () => {
      if (preview) this.previews.delete(preview);
    });
    this.previews.add(preview);
    return preview;
  }

  /** Starts a browser download and revokes its temporary object URL. */
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

  /** Disposes owned previews, revokes object URLs, and invalidates byte exports. */
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
