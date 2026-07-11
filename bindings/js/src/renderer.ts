import { UnsupportedEnvironmentError, WasmRenderError } from "./errors.js";
import { normalizePage, type NormalizedPage } from "./page.js";
import { PdfDocument } from "./pdf-document.js";
import { snapshotSource, type SnapshotOptions } from "./snapshot.js";
import type { FontRegistration, HtmlSource, PageBreakRules, PdfMetadata, RendererInit, RenderOptions } from "./types.js";
import { WasmBridge, type WasmRenderResult } from "./wasm.js";

interface Backend {
  render(html: string, page: NormalizedPage, metadata?: PdfMetadata, signal?: AbortSignal): Promise<WasmRenderResult>;
  dispose(): void;
}

class MainThreadBackend implements Backend {
  constructor(private readonly bridge: WasmBridge) {}

  render(html: string, page: NormalizedPage, metadata?: PdfMetadata, signal?: AbortSignal): Promise<WasmRenderResult> {
    if (signal?.aborted) return Promise.reject(signal.reason);
    return Promise.resolve(this.bridge.render(html, page, metadata));
  }

  dispose(): void {
    this.bridge.dispose();
  }
}

interface PendingRender {
  resolve: (result: WasmRenderResult) => void;
  reject: (error: unknown) => void;
  removeAbort?: () => void;
}

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

  async render(html: string, page: NormalizedPage, metadata?: PdfMetadata, signal?: AbortSignal): Promise<WasmRenderResult> {
    if (this.disposed) throw new Error("Renderer has been disposed");
    if (signal?.aborted) throw signal.reason;
    await this.ready;

    const id = this.nextId++;
    return new Promise<WasmRenderResult>((resolve, reject) => {
      const pending: PendingRender = { resolve, reject };
      if (signal) {
        const onAbort = () => {
          this.pending.delete(id);
          reject(signal.reason);
        };
        signal.addEventListener("abort", onAbort, { once: true });
        pending.removeAbort = () => signal.removeEventListener("abort", onAbort);
      }
      this.pending.set(id, pending);
      this.worker.postMessage({ type: "render", id, html, page, metadata });
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

export class Html2RealPdf {
  private disposed = false;

  constructor(private readonly backend: Backend) {}

  async render(source: HtmlSource, options: RenderOptions = {}): Promise<PdfDocument> {
    if (this.disposed) throw new Error("Renderer has been disposed");
    options.onProgress?.({ phase: "snapshot", completed: 0, total: 1 });
    const snapshotOptions: SnapshotOptions = { resourcePolicy: options.resourcePolicy ?? "error" };
    if (options.baseUrl !== undefined) snapshotOptions.baseUrl = options.baseUrl;
    if (options.resourceResolver !== undefined) snapshotOptions.resourceResolver = options.resourceResolver;
    if (options.strict !== undefined) snapshotOptions.strict = options.strict;
    if (options.enableLinks !== undefined) snapshotOptions.enableLinks = options.enableLinks;
    const snapshot = await snapshotSource(source, snapshotOptions);
    options.onProgress?.({ phase: "snapshot", completed: 1, total: 1 });

    options.onProgress?.({ phase: "wasm", completed: 0, total: 1 });
    const rendered = await this.backend.render(
      applyPageBreakRules(snapshot.html, options.pageBreak),
      normalizePage(options.page),
      options.metadata,
      options.signal,
    );
    options.onProgress?.({ phase: "wasm", completed: 1, total: 1 });
    options.onProgress?.({ phase: "complete", completed: 1, total: 1 });
    return new PdfDocument(rendered.bytes, rendered.pageCount, [...snapshot.diagnostics, ...rendered.diagnostics]);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.backend.dispose();
  }
}

export async function createRenderer(init: RendererInit = {}): Promise<Html2RealPdf> {
  if (typeof window === "undefined") throw new UnsupportedEnvironmentError();
  if (init.execution !== "main" && typeof Worker === "undefined") {
    throw new UnsupportedEnvironmentError("html2realpdf Worker execution is unavailable; use execution: 'main' as a fallback");
  }
  const wasmUrl = new URL(init.wasmUrl ?? new URL("./libhtml2realpdf.wasm", import.meta.url), window.location.href).href;
  const backend: Backend = init.execution === "main"
    ? new MainThreadBackend(await WasmBridge.create(wasmUrl, init.fonts ?? []))
    : new WorkerBackend(wasmUrl, init.fonts ?? []);
  return new Html2RealPdf(backend);
}

let defaultRenderer: Promise<Html2RealPdf> | undefined;

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
