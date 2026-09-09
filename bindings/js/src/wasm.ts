/**
 * Typed ownership bridge for the renderer's handle-based WebAssembly ABI.
 *
 * @packageDocumentation
 */

import type { PdfExtras } from "./attachments.js";
import { WasmRenderError } from "./errors.js";
import type { NormalizedPage } from "./page.js";
import type { CssProfile, Diagnostic, FontRegistration, PdfMetadata } from "./types.js";
import type { SnapshotPageMarginBox, SnapshotPageRule } from "./snapshot.js";

const EXPECTED_ABI_VERSION = 2;

/** ABI surface implemented by `src/wasm.zig`. */
interface WasmExports {
  html2realpdf_abi_version(): number;
  pdf_context_create(): number;
  pdf_context_free(handle: number): void;
  pdf_context_register_font(
    handle: number,
    familyPointer: number,
    familyLength: number,
    dataPointer: number,
    dataLength: number,
    weight: number,
    style: number,
  ): number;
  memory: WebAssembly.Memory;
  alloc(length: number): number;
  free(pointer: number, length: number): void;
  render_html_to_pdf_with_options(
    pointer: number,
    length: number,
    pageWidthPoints: number,
    pageHeightPoints: number,
    marginTopPoints: number,
    marginRightPoints: number,
    marginBottomPoints: number,
    marginLeftPoints: number,
  ): number;
  render_html_to_pdf_with_json_options(pointer: number, length: number, optionsPointer: number, optionsLength: number): number;
  render_html_to_pdf_with_context_json_options(
    context: number,
    pointer: number,
    length: number,
    optionsPointer: number,
    optionsLength: number,
  ): number;
  pdf_result_status(handle: number): number;
  pdf_result_data_ptr(handle: number): number;
  pdf_result_data_len(handle: number): number;
  pdf_result_page_count(handle: number): number;
  pdf_result_error_ptr(handle: number): number;
  pdf_result_error_len(handle: number): number;
  pdf_result_diagnostics_ptr(handle: number): number;
  pdf_result_diagnostics_len(handle: number): number;
  pdf_result_free(handle: number): void;
}

/** Owned JavaScript result copied out of WASM memory. */
export interface WasmRenderResult {
  bytes: Uint8Array;
  pageCount: number;
  diagnostics: Diagnostic[];
}

/**
 * Owns one native PDF context and its registered fonts.
 *
 * @remarks
 * All temporary allocations and result handles are freed before `render`
 * returns. PDF bytes are copied first because freeing handles or growing WASM
 * memory invalidates borrowed views.
 */
export class WasmBridge {
  private readonly encoder = new TextEncoder();
  private disposed = false;

  private constructor(private readonly exports: WasmExports, private readonly context: number) {}

  /** Instantiates the expected ABI, creates a context, and registers its fonts. */
  static async create(wasmUrl: string | URL, fonts: readonly FontRegistration[] = []): Promise<WasmBridge> {
    const response = await fetch(wasmUrl);
    if (!response.ok) throw new WasmRenderError(`Could not load WASM: HTTP ${response.status}`, -10);

    let result: WebAssembly.WebAssemblyInstantiatedSource;
    try {
      result = await WebAssembly.instantiateStreaming(response.clone(), {});
    } catch {
      result = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    }

    const exports = result.instance.exports as unknown as WasmExports;
    const abiVersion = exports.html2realpdf_abi_version?.();
    if (abiVersion !== EXPECTED_ABI_VERSION) {
      throw new WasmRenderError(`Unsupported WASM ABI version ${String(abiVersion)}; expected ${EXPECTED_ABI_VERSION}`, -14);
    }
    const context = exports.pdf_context_create();
    if (context === 0) throw new WasmRenderError("WASM context allocation failed", -12);
    const bridge = new WasmBridge(exports, context);
    try {
      for (const registration of fonts) bridge.registerFont(registration);
      return bridge;
    } catch (error) {
      bridge.dispose();
      throw error;
    }
  }

  /** Serializes render options, invokes the native renderer, and returns owned output. */
  render(html: string, page: NormalizedPage, metadata?: PdfMetadata, cssProfile: CssProfile = "document", marginBoxes?: readonly SnapshotPageMarginBox[], pageRules?: readonly SnapshotPageRule[], extras?: PdfExtras): WasmRenderResult {
    if (this.disposed) throw new WasmRenderError("WASM bridge has been disposed", -15);
    const allocations: { pointer: number; length: number }[] = [];
    const copy = (bytes: Uint8Array): number => {
      const length = Math.max(bytes.length, 1);
      const pointer = this.exports.alloc(length);
      if (pointer === 0) throw new WasmRenderError("WASM input allocation failed", -11);
      allocations.push({ pointer, length });
      new Uint8Array(this.exports.memory.buffer, pointer, bytes.length).set(bytes);
      return pointer;
    };
    let resultHandle = 0;
    try {
      const attachments = extras?.attachments?.map(({ data, ...metadata }) => ({
        ...metadata, dataPointer: copy(data), dataLength: data.byteLength,
      }));
      const input = this.encoder.encode(html);
      const inputPointer = copy(input);
      const renderOptions = this.encoder.encode(JSON.stringify({
        pageWidthPoints: page.widthPoints,
        pageHeightPoints: page.heightPoints,
        marginTopPoints: page.marginTopPoints,
        marginRightPoints: page.marginRightPoints,
        marginBottomPoints: page.marginBottomPoints,
        marginLeftPoints: page.marginLeftPoints,
        cssProfile, marginBoxes, pageRules,
        conformance: extras?.conformance,
        attachments,
        metadata: metadata ? {
          ...metadata,
          keywords: Array.isArray(metadata.keywords) ? metadata.keywords.join(", ") : metadata.keywords,
        } : undefined,
      }));
      const optionsPointer = copy(renderOptions);
      resultHandle = this.exports.render_html_to_pdf_with_context_json_options(
        this.context,
        inputPointer,
        input.length,
        optionsPointer,
        renderOptions.length,
      );
      if (resultHandle === 0) throw new WasmRenderError("WASM result allocation failed", -12);

      const status = this.exports.pdf_result_status(resultHandle);
      if (status !== 0) {
        const detail = this.readResultString(resultHandle, "error");
        throw new WasmRenderError(detail || `WASM PDF rendering failed with status ${status}`, status);
      }

      const pointer = this.exports.pdf_result_data_ptr(resultHandle);
      const length = this.exports.pdf_result_data_len(resultHandle);
      if (pointer === 0 || length === 0) throw new WasmRenderError("WASM returned an empty PDF", -13);

      return {
        bytes: new Uint8Array(this.exports.memory.buffer, pointer, length).slice(),
        pageCount: this.exports.pdf_result_page_count(resultHandle),
        diagnostics: this.readDiagnostics(resultHandle),
      };
    } finally {
      if (resultHandle !== 0) this.exports.pdf_result_free(resultHandle);
      for (const { pointer, length } of allocations) this.exports.free(pointer, length);
    }
  }

  /** Frees the renderer context and every font copied into it. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.exports.pdf_context_free(this.context);
  }

  /** Copies one font registration across the ABI into context-owned storage. */
  private registerFont(registration: FontRegistration): void {
    const family = this.encoder.encode(registration.family.trim());
    const data = registration.data instanceof Uint8Array
      ? registration.data
      : new Uint8Array(registration.data);
    if (family.length === 0 || data.length === 0) throw new WasmRenderError("Font family and data must not be empty", -16);
    const familyPointer = this.exports.alloc(family.length);
    const dataPointer = this.exports.alloc(data.length);
    if (familyPointer === 0 || dataPointer === 0) {
      if (familyPointer !== 0) this.exports.free(familyPointer, family.length);
      if (dataPointer !== 0) this.exports.free(dataPointer, data.length);
      throw new WasmRenderError("WASM font allocation failed", -11);
    }
    try {
      new Uint8Array(this.exports.memory.buffer, familyPointer, family.length).set(family);
      new Uint8Array(this.exports.memory.buffer, dataPointer, data.length).set(data);
      const numericWeight = registration.weight === "bold" ? 700 : registration.weight === "normal" || registration.weight === undefined
        ? 400
        : registration.weight;
      const status = this.exports.pdf_context_register_font(
        this.context,
        familyPointer,
        family.length,
        dataPointer,
        data.length,
        numericWeight,
        registration.style === "italic" ? 1 : 0,
      );
      if (status !== 0) throw new WasmRenderError(`WASM font registration failed with status ${status}`, status);
    } finally {
      this.exports.free(familyPointer, family.length);
      this.exports.free(dataPointer, data.length);
    }
  }

  private readResultString(handle: number, kind: "error" | "diagnostics"): string {
    const pointer = kind === "error"
      ? this.exports.pdf_result_error_ptr(handle)
      : this.exports.pdf_result_diagnostics_ptr(handle);
    const length = kind === "error"
      ? this.exports.pdf_result_error_len(handle)
      : this.exports.pdf_result_diagnostics_len(handle);
    if (pointer === 0 || length === 0) return "";
    return new TextDecoder().decode(new Uint8Array(this.exports.memory.buffer, pointer, length));
  }

  private readDiagnostics(handle: number): Diagnostic[] {
    const serialized = this.readResultString(handle, "diagnostics");
    if (!serialized) return [];
    try {
      const parsed: unknown = JSON.parse(serialized);
      return Array.isArray(parsed) ? parsed as Diagnostic[] : [];
    } catch {
      return [{ code: "INVALID_WASM_DIAGNOSTICS", severity: "warning", message: "WASM returned malformed diagnostics" }];
    }
  }
}
