/**
 * Renderer factories, execution backends, and per-render pipeline ownership.
 *
 * @packageDocumentation
 */

import { UnsupportedEnvironmentError, WasmRenderError } from "./errors.js";
import { normalizePage, type NormalizedPage } from "./page.js";
import { PdfDocument } from "./pdf-document.js";
import { snapshotSource, type SnapshotOptions, type SnapshotPageMarginBox, type SnapshotPageRule } from "./snapshot.js";
import type { CssProfile, FontRegistration, HtmlSource, PageBreakRules, PdfMetadata, RendererInit, RenderOptions } from "./types.js";
import { WasmBridge, type WasmRenderResult } from "./wasm.js";

/** Common ownership boundary for main-thread and Worker WASM contexts. */
interface Backend {
  render(html: string, page: NormalizedPage, metadata?: PdfMetadata, cssProfile?: CssProfile, marginBoxes?: readonly SnapshotPageMarginBox[], pageRules?: readonly SnapshotPageRule[], signal?: AbortSignal): Promise<WasmRenderResult>;
  dispose(): void;
}

/** Executes the synchronous bridge on the caller's browser thread. */
class MainThreadBackend implements Backend {
  constructor(private readonly bridge: WasmBridge) {}

  render(html: string, page: NormalizedPage, metadata?: PdfMetadata, cssProfile?: CssProfile, marginBoxes?: readonly SnapshotPageMarginBox[], pageRules?: readonly SnapshotPageRule[], signal?: AbortSignal): Promise<WasmRenderResult> {
    if (signal?.aborted) return Promise.reject(abortReason(signal));
    return Promise.resolve(this.bridge.render(html, page, metadata, cssProfile, marginBoxes, pageRules));
  }

  dispose(): void {
    this.bridge.dispose();
  }
}

/** Caller state retained while a Worker render is in flight. */
interface PendingRender {
  resolve: (result: WasmRenderResult) => void;
  reject: (error: unknown) => void;
  removeAbort?: () => void;
}

/** Owns a module Worker and routes concurrent results by request identifier. */
class WorkerBackend implements Backend {
  private readonly worker: Worker;
  private readonly pending = new Map<number, PendingRender>();
  private readonly ready: Promise<void>;
  private nextId = 1;
  private disposed = false;

  constructor(wasmUrl: string, fonts: readonly FontRegistration[]) {
    this.worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module", name: "html2realpdf" });
    this.ready = new Promise<void>((resolve, reject) => {
      const onError = (event: ErrorEvent) => {
        this.worker.removeEventListener("message", onMessage);
        reject(new WasmRenderError(event.message || "PDF Worker initialization failed", -20));
      };
      const onMessage = (event: MessageEvent) => {
        if (event.data?.type === "ready") {
          this.worker.removeEventListener("message", onMessage);
          this.worker.removeEventListener("error", onError);
          resolve();
        } else if (event.data?.type === "init-error") {
          this.worker.removeEventListener("message", onMessage);
          this.worker.removeEventListener("error", onError);
          reject(new WasmRenderError(event.data.error, -20));
        }
      };
      this.worker.addEventListener("message", onMessage);
      this.worker.addEventListener("error", onError, { once: true });
    });
    this.worker.addEventListener("message", (event) => this.handleMessage(event));
    this.worker.addEventListener("error", (event) => {
      const error = new WasmRenderError(event.message || "PDF Worker failed", -22);
      for (const pending of this.pending.values()) {
        pending.removeAbort?.();
        pending.reject(error);
      }
      this.pending.clear();
    });
    this.worker.postMessage({ type: "init", wasmUrl, fonts });
  }

  async render(html: string, page: NormalizedPage, metadata?: PdfMetadata, cssProfile?: CssProfile, marginBoxes?: readonly SnapshotPageMarginBox[], pageRules?: readonly SnapshotPageRule[], signal?: AbortSignal): Promise<WasmRenderResult> {
    if (this.disposed) throw new Error("Renderer has been disposed");
    if (signal?.aborted) throw abortReason(signal);
    await this.ready;

    const id = this.nextId++;
    return new Promise<WasmRenderResult>((resolve, reject) => {
      const pending: PendingRender = { resolve, reject };
      if (signal) {
        const onAbort = () => {
          this.pending.delete(id);
          reject(abortReason(signal));
        };
        signal.addEventListener("abort", onAbort, { once: true });
        pending.removeAbort = () => signal.removeEventListener("abort", onAbort);
      }
      this.pending.set(id, pending);
      this.worker.postMessage({ type: "render", id, html, page, metadata, cssProfile, marginBoxes, pageRules });
    });
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.worker.terminate();
    for (const pending of this.pending.values()) {
      pending.removeAbort?.();
      pending.reject(new Error("Renderer was disposed"));
    }
    this.pending.clear();
  }

  private handleMessage(event: MessageEvent): void {
    const message = event.data;
    if (message?.type !== "render-result" && message?.type !== "render-error") return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    pending.removeAbort?.();

    if (message.type === "render-error") {
      pending.reject(new WasmRenderError(message.error, -21));
    } else {
      pending.resolve({
        bytes: new Uint8Array(message.bytes),
        pageCount: message.pageCount,
        diagnostics: Array.isArray(message.diagnostics) ? message.diagnostics : [],
      });
    }
  }
}

/**
 * Reusable renderer backed by one Worker or main-thread WASM context.
 *
 * @remarks
 * Create instances with `createRenderer`. Fonts and execution mode belong to
 * the renderer lifetime; each returned `PdfDocument` has its own shorter
 * lifetime. Call `dispose` when the renderer is no longer needed.
 */
export class Html2RealPdf {
  private disposed = false;

  private constructor(private readonly backend: Backend) {}

  /** @internal */
  static create(backend: Backend): Html2RealPdf {
    return new Html2RealPdf(backend);
  }

  /**
   * Snapshots browser state and renders one PDF.
   *
   * @throws {@link InvalidSourceError} when a ref is null or the source shape is invalid.
   * @throws {@link UnsupportedCssError} when strict CSS or fallback policy rejects input.
   * @throws {@link ResourceLoadError} when required resources cannot be materialized.
   */
  async render(source: HtmlSource, options: RenderOptions = {}): Promise<PdfDocument> {
    if (this.disposed) throw new Error("Renderer has been disposed");
    if (options.signal?.aborted) throw abortReason(options.signal);
    options.onProgress?.({ phase: "snapshot", completed: 0, total: 1 });
    const snapshotOptions: SnapshotOptions = {
      resourcePolicy: options.resourcePolicy ?? "error",
      cssProfile: options.cssProfile ?? "document",
      // Preserve the historical browser snapshot behavior unless callers
      // explicitly request print media. The web-profile example in the public
      // API opts into print rather than silently changing existing documents.
      mediaType: options.mediaType ?? "screen",
      unsupportedCss: options.unsupportedCss ?? (options.cssProfile === "strict" || options.strict ? "error" : "warn"),
      // Raster fallback is deliberately opt-in. A caller must acknowledge the
      // loss of native PDF primitives for the affected subtree explicitly.
      fallback: options.fallback ?? "error",
    };
    if (options.baseUrl !== undefined) snapshotOptions.baseUrl = options.baseUrl;
    if (options.resourceResolver !== undefined) snapshotOptions.resourceResolver = options.resourceResolver;
    if (options.strict !== undefined) snapshotOptions.strict = options.strict;
    if (options.enableLinks !== undefined) snapshotOptions.enableLinks = options.enableLinks;
    if (options.viewport !== undefined) snapshotOptions.viewport = options.viewport;
    if (options.includeShadowDom !== undefined) snapshotOptions.includeShadowDom = options.includeShadowDom;
    if (options.canvasToSvg !== undefined) snapshotOptions.canvasToSvg = options.canvasToSvg;
    if (options.canvasFallback !== undefined) snapshotOptions.canvasFallback = options.canvasFallback;
    const snapshot = await snapshotSource(source, snapshotOptions);
    if (options.signal?.aborted) throw abortReason(options.signal);
    options.onProgress?.({ phase: "snapshot", completed: 1, total: 1 });

    options.onProgress?.({ phase: "wasm", completed: 0, total: 1 });
    const page = options.page !== undefined ? normalizePage(options.page) : snapshot.page ?? normalizePage();
    const rendered = await this.backend.render(
      applyPageBreakRules(snapshot.html, options.pageBreak),
      page,
      options.metadata,
      options.cssProfile ?? "document",
      snapshot.pageMarginBoxes,
      options.page === undefined ? snapshot.pageRules : undefined,
      options.signal,
    );
    options.onProgress?.({ phase: "wasm", completed: 1, total: 1 });
    options.onProgress?.({ phase: "complete", completed: 1, total: 1 });
    return PdfDocument.create(rendered.bytes, rendered.pageCount, [...snapshot.diagnostics, ...rendered.diagnostics]);
  }

  /** Terminates the owned backend and rejects future renders. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.backend.dispose();
  }
}

/**
 * Creates a reusable renderer with explicit backend and font ownership.
 *
 * @example
 * ```ts
 * const renderer = await createRenderer({ fonts });
 * try {
 *   const pdf = await renderer.render(element);
 *   try { pdf.download("report.pdf"); } finally { pdf.dispose(); }
 * } finally {
 *   renderer.dispose();
 * }
 * ```
 *
 * @throws {@link UnsupportedEnvironmentError} outside a browser or when the
 * requested execution backend is unavailable.
 */
export async function createRenderer(init: RendererInit = {}): Promise<Html2RealPdf> {
  if (typeof window === "undefined") throw new UnsupportedEnvironmentError();
  if (init.execution !== "main" && typeof Worker === "undefined") {
    throw new UnsupportedEnvironmentError("html2realpdf Worker execution is unavailable; use execution: 'main' as a fallback");
  }
  const wasmUrl = new URL(init.wasmUrl ?? new URL("./libhtml2realpdf.wasm", import.meta.url), window.location.href).href;
  const backend: Backend = init.execution === "main"
    ? new MainThreadBackend(await WasmBridge.create(wasmUrl, init.fonts ?? []))
    : new WorkerBackend(wasmUrl, init.fonts ?? []);
  return Html2RealPdf.create(backend);
}

let defaultRenderer: Promise<Html2RealPdf> | undefined;

/**
 * Renders with a lazily created package-default Worker renderer.
 *
 * @remarks
 * The default renderer is cached for the application lifetime and cannot be
 * configured with custom fonts. Use `createRenderer` when deterministic
 * backend disposal or renderer-level configuration is required. The returned
 * document must still be disposed by the caller.
 *
 * @example
 * ```ts
 * const pdf = await renderPdf(document.querySelector("#invoice")!);
 * try { pdf.download("invoice.pdf"); } finally { pdf.dispose(); }
 * ```
 */
export async function renderPdf(source: HtmlSource, options: RenderOptions = {}): Promise<PdfDocument> {
  defaultRenderer ??= createRenderer().catch((error: unknown) => {
    defaultRenderer = undefined;
    throw error;
  });
  return (await defaultRenderer).render(source, options);
}

function applyPageBreakRules(html: string, rules?: PageBreakRules): string {
  if (!rules) return html;
  const declarations: string[] = [];
  // DOM snapshots carry computed break properties as inline declarations.
  // Option-driven rules therefore need author importance to override the
  // snapshot's inline `auto` value while still yielding to inline !important.
  appendSelectorRule(declarations, rules.before, "break-before:page!important");
  appendSelectorRule(declarations, rules.after, "break-after:page!important");
  appendSelectorRule(declarations, rules.avoid, "break-inside:avoid!important");
  if (rules.legacy) declarations.push(".html2pdf__page-break{break-before:page!important}");
  if (rules.avoidAll) declarations.push("body *{break-inside:avoid!important}");
  return declarations.length === 0 ? html : `<style data-html2realpdf-pagebreak>${declarations.join("")}</style>${html}`;
}

function appendSelectorRule(output: string[], input: string | readonly string[] | undefined, declaration: string): void {
  const selectors = typeof input === "string" ? [input] : input ?? [];
  const safe = selectors.map((selector) => selector.trim()).filter((selector) => selector && !/[{};]/.test(selector));
  if (safe.length > 0) output.push(`${safe.join(",")}{${declaration}}`);
}

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("The operation was aborted", "AbortError");
}
