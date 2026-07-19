/**
 * Shadow-DOM PDF preview backed by package-relative PDF.js assets.
 *
 * @packageDocumentation
 */

/** Color theme used by the integrated PDF preview controls. */
export type PdfPreviewTheme = "system" | "light" | "dark";

/** Display and rendering limits for `PdfDocument.preview`. */
export interface PdfPreviewOptions {
  /** Whether to show the page summary and zoom toolbar. Defaults to `true`. */
  showToolbar?: boolean;
  /** Padding around the rendered pages in CSS pixels. Defaults to `28`, or `16` on narrow screens. */
  padding?: number;
  /** Initial zoom or automatic fit. Defaults to `fit-width`. */
  initialScale?: number | "fit-width";
  /** Lowest permitted zoom. Defaults to `0.25` and is never below `0.1`. */
  minScale?: number;
  /** Highest permitted zoom. Defaults to `3` and is never below `minScale`. */
  maxScale?: number;
  /** Zoom-button increment. Defaults to `0.25` and is never below `0.05`. */
  zoomStep?: number;
  /** Device-pixel-ratio cap used for page canvases. Defaults to `2`. */
  maxPixelRatio?: number;
  /** Accessible label for the preview region. Defaults to `PDF preview`. */
  ariaLabel?: string;
  /** Preview-control theme. Defaults to `system` and follows the browser preference. */
  theme?: PdfPreviewTheme;
  /** Called after each page canvas completes rendering. */
  onProgress?: (completedPages: number, totalPages: number) => void;
}

interface PdfJsViewport {
  readonly width: number;
  readonly height: number;
}

interface PdfJsRenderTask {
  readonly promise: Promise<void>;
  cancel(): void;
}

interface PdfJsPage {
  getViewport(options: { scale: number }): PdfJsViewport;
  render(options: {
    canvas: HTMLCanvasElement;
    viewport: PdfJsViewport;
    transform?: readonly [number, number, number, number, number, number];
  }): PdfJsRenderTask;
  cleanup(): void;
}

interface PdfJsDocument {
  readonly numPages: number;
  getPage(pageNumber: number): Promise<PdfJsPage>;
  destroy(): Promise<void>;
}

interface PdfJsLoadingTask {
  readonly promise: Promise<PdfJsDocument>;
  destroy(): Promise<void>;
}

interface PdfJsModule {
  readonly GlobalWorkerOptions: { workerSrc: string };
  getDocument(options: { data: Uint8Array }): PdfJsLoadingTask;
}

const VIEWER_STYLES = `
  :host {
    --preview-scale: #33404d;
    --preview-summary: #52606d;
    --preview-focus: #111;
    --preview-toolbar: rgba(255, 255, 255, 0.96);
    --preview-toolbar-line: rgba(24, 32, 42, 0.10);
    --preview-zoom: #fff;
    --preview-zoom-hover: #f5f7fa;
    --preview-zoom-ink: #18202a;
    --preview-zoom-line: rgba(24, 32, 42, 0.16);
    color: #18202a;
    color-scheme: light dark;
    display: block;
    font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  *, *::before, *::after { box-sizing: border-box; }
  button { font: inherit; touch-action: manipulation; }
  .viewer {
    background: #e9edf2;
    border-radius: 14px;
    box-shadow: 0 0 0 1px rgba(24, 32, 42, 0.12), 0 18px 50px rgba(24, 32, 42, 0.10);
    display: grid;
    grid-template-rows: auto minmax(320px, 1fr);
    isolation: isolate;
    min-height: 520px;
    overflow: hidden;
  }
  .viewer.toolbar-hidden { grid-template-rows: minmax(320px, 1fr); }
  .toolbar {
    align-items: center;
    background: var(--preview-toolbar);
    box-shadow: 0 1px 0 var(--preview-toolbar-line);
    display: flex;
    gap: 8px;
    justify-content: space-between;
    min-height: 60px;
    padding: 8px 12px;
  }
  .toolbar[hidden] { display: none; }
  .summary {
    color: var(--preview-summary);
    font-size: 13px;
    font-variant-numeric: tabular-nums;
    min-width: 9rem;
  }
  .controls { align-items: center; display: flex; gap: 6px; }
  .zoom {
    background: var(--preview-zoom);
    border: 0;
    border-radius: 9px;
    box-shadow: 0 0 0 1px var(--preview-zoom-line);
    color: var(--preview-zoom-ink);
    cursor: pointer;
    min-height: 44px;
    min-width: 44px;
    padding: 0 12px;
  }
  .zoom:focus-visible { outline: 2px solid var(--preview-focus); outline-offset: 2px; }
  .zoom:disabled { cursor: not-allowed; opacity: 0.42; }
  .scale {
    color: var(--preview-scale);
    font-size: 13px;
    font-variant-numeric: tabular-nums;
    min-width: 3.75rem;
    text-align: center;
  }
  .pages {
    align-items: center;
    display: flex;
    flex-direction: column;
    gap: 24px;
    overflow: auto;
    overscroll-behavior: contain;
    padding: 28px;
  }
  .page {
    background: #fff;
    box-shadow: 0 0 0 1px rgba(24, 32, 42, 0.10), 0 10px 30px rgba(24, 32, 42, 0.14);
    flex: 0 0 auto;
    line-height: 0;
  }
  canvas { display: block; }
  .error {
    align-self: center;
    color: #9f1239;
    font-size: 14px;
    line-height: 1.5;
    margin: auto;
    max-width: 36rem;
    padding: 32px;
    text-align: center;
  }
  @media (hover: hover) and (pointer: fine) {
    .zoom:not(:disabled):hover { background: var(--preview-zoom-hover); }
  }
  @media (prefers-color-scheme: dark) {
    :host {
      --preview-scale: #d7dee7;
      --preview-summary: #b7c0ca;
      --preview-focus: #fff;
      --preview-toolbar: rgba(24, 32, 42, 0.96);
      --preview-toolbar-line: rgba(255, 255, 255, 0.12);
      --preview-zoom: #26313c;
      --preview-zoom-hover: #303c48;
      --preview-zoom-ink: #f8fafc;
      --preview-zoom-line: rgba(255, 255, 255, 0.18);
    }
  }
  :host([data-theme="light"]) {
    --preview-scale: #33404d;
    --preview-summary: #52606d;
    --preview-focus: #111;
    --preview-toolbar: rgba(255, 255, 255, 0.96);
    --preview-toolbar-line: rgba(24, 32, 42, 0.10);
    --preview-zoom: #fff;
    --preview-zoom-hover: #f5f7fa;
    --preview-zoom-ink: #18202a;
    --preview-zoom-line: rgba(24, 32, 42, 0.16);
    color-scheme: light;
  }
  :host([data-theme="dark"]) {
    --preview-scale: #d7dee7;
    --preview-summary: #b7c0ca;
    --preview-focus: #fff;
    --preview-toolbar: rgba(24, 32, 42, 0.96);
    --preview-toolbar-line: rgba(255, 255, 255, 0.12);
    --preview-zoom: #26313c;
    --preview-zoom-hover: #303c48;
    --preview-zoom-ink: #f8fafc;
    --preview-zoom-line: rgba(255, 255, 255, 0.18);
    color-scheme: dark;
  }
  @media (max-width: 560px) {
    .viewer { border-radius: 10px; min-height: 440px; }
    .toolbar { align-items: flex-start; flex-direction: column; }
    .controls { width: 100%; }
    .controls .zoom:last-child { margin-left: auto; }
    .pages { gap: 16px; padding: 16px; }
  }
`;

let pdfJsModule: Promise<PdfJsModule> | undefined;

/** Lazily loads one shared PDF.js module while keeping preview assets relocatable. */
async function loadPdfJs(): Promise<PdfJsModule> {
  pdfJsModule ??= import(/* @vite-ignore */ new URL("./vendor/pdf.min.mjs", import.meta.url).href)
    .then((module: unknown) => {
      const pdfJs = module as PdfJsModule;
      pdfJs.GlobalWorkerOptions.workerSrc = new URL("./vendor/pdf.worker.min.mjs", import.meta.url).href;
      return pdfJs;
    })
    .catch((error: unknown) => {
      pdfJsModule = undefined;
      throw error;
    });
  return pdfJsModule;
}

/**
 * Interactive canvas preview created and owned by a `PdfDocument`.
 *
 * @remarks
 * The viewer replaces the target's children with one isolated Shadow DOM
 * subtree. Dispose it to cancel rendering, destroy PDF.js state, and clear the
 * target. Construct previews through `PdfDocument.preview`.
 */
export class PdfPreview {
  /** Host element inserted into the preview target. */
  readonly element: HTMLElement;

  private readonly shadow: ShadowRoot;
  private readonly pagesElement: HTMLElement;
  private readonly summaryElement: HTMLElement;
  private readonly scaleElement: HTMLOutputElement;
  private readonly zoomOutButton: HTMLButtonElement;
  private readonly zoomInButton: HTMLButtonElement;
  private readonly minScale: number;
  private readonly maxScale: number;
  private readonly zoomStep: number;
  private readonly pixelRatio: number;
  private readonly onProgress: ((completedPages: number, totalPages: number) => void) | undefined;
  private loadingTask: PdfJsLoadingTask | undefined;
  private document: PdfJsDocument | undefined;
  private renderTask: PdfJsRenderTask | undefined;
  private scale = 1;
  private renderVersion = 0;
  private disposed = false;

  private constructor(
    private readonly target: HTMLElement,
    private readonly bytes: Uint8Array,
    private readonly expectedPageCount: number,
    options: PdfPreviewOptions,
    private readonly onDispose?: () => void,
  ) {
    this.minScale = Math.max(options.minScale ?? 0.25, 0.1);
    this.maxScale = Math.max(options.maxScale ?? 3, this.minScale);
    this.zoomStep = Math.max(options.zoomStep ?? 0.25, 0.05);
    this.pixelRatio = Math.min(Math.max(window.devicePixelRatio || 1, 1), options.maxPixelRatio ?? 2);
    this.onProgress = options.onProgress;

    this.element = document.createElement("div");
    this.element.dataset.html2realpdfPreview = "";
    this.setTheme(options.theme ?? "system");
    this.shadow = this.element.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = VIEWER_STYLES;
    const viewer = document.createElement("section");
    viewer.className = "viewer";
    viewer.setAttribute("role", "region");
    viewer.setAttribute("aria-label", options.ariaLabel ?? "PDF preview");

    const toolbar = document.createElement("div");
    toolbar.className = "toolbar";
    toolbar.hidden = options.showToolbar === false;
    if (toolbar.hidden) viewer.classList.add("toolbar-hidden");
    this.summaryElement = document.createElement("div");
    this.summaryElement.className = "summary";
    this.summaryElement.setAttribute("aria-live", "polite");
    this.summaryElement.textContent = "Loading PDF preview...";

    const controls = document.createElement("div");
    controls.className = "controls";
    this.zoomOutButton = createButton("-", "Zoom out");
    this.scaleElement = document.createElement("output");
    this.scaleElement.className = "scale";
    this.scaleElement.setAttribute("aria-label", "Preview zoom");
    this.zoomInButton = createButton("+", "Zoom in");
    const fitButton = createButton("Fit", "Fit pages to preview width");
    controls.append(this.zoomOutButton, this.scaleElement, this.zoomInButton, fitButton);
    toolbar.append(this.summaryElement, controls);

    this.pagesElement = document.createElement("div");
    this.pagesElement.className = "pages";
    if (options.padding !== undefined && Number.isFinite(options.padding)) {
      this.pagesElement.style.padding = `${Math.max(options.padding, 0)}px`;
    }
    this.pagesElement.tabIndex = 0;
    this.pagesElement.setAttribute("aria-label", "PDF pages");
    viewer.append(toolbar, this.pagesElement);
    this.shadow.append(style, viewer);
    this.target.replaceChildren(this.element);

    this.zoomOutButton.addEventListener("click", () => {
      void this.setScale(this.scale - this.zoomStep).catch((error: unknown) => this.showError(error));
    });
    this.zoomInButton.addEventListener("click", () => {
      void this.setScale(this.scale + this.zoomStep).catch((error: unknown) => this.showError(error));
    });
    fitButton.addEventListener("click", () => {
      void this.fitToWidth().catch((error: unknown) => this.showError(error));
    });
  }

  /** @internal */
  static async open(
    target: HTMLElement,
    bytes: Uint8Array,
    pageCount: number,
    options: PdfPreviewOptions = {},
    onDispose?: () => void,
  ): Promise<PdfPreview> {
    if (!(target instanceof HTMLElement)) throw new TypeError("PDF preview target must be an HTMLElement");
    const preview = new PdfPreview(target, bytes.slice(), pageCount, options, onDispose);
    try {
      await preview.load(options.initialScale ?? "fit-width");
      return preview;
    } catch (error) {
      preview.releaseDocument();
      preview.showError(error);
      throw error;
    }
  }

  /** Current logical PDF.js scale after option clamping. */
  get currentScale(): number {
    return this.scale;
  }

  /** Current preview-control theme, including the default `system` mode. */
  get currentTheme(): PdfPreviewTheme {
    return this.element.dataset.theme as PdfPreviewTheme;
  }

  /** Updates the preview-control theme without rerendering the PDF pages. */
  setTheme(theme: PdfPreviewTheme): void {
    this.assertActive();
    if (theme !== "system" && theme !== "light" && theme !== "dark") {
      throw new TypeError(`Unsupported PDF preview theme: ${String(theme)}`);
    }
    this.element.dataset.theme = theme;
  }

  /** Sets a clamped scale and rerenders every page canvas. */
  async setScale(value: number): Promise<void> {
    this.assertActive();
    const next = clamp(value, this.minScale, this.maxScale);
    if (Math.abs(next - this.scale) < 0.001) return;
    this.scale = next;
    await this.renderPages();
  }

  /** Fits the first page to the available viewer width and rerenders all pages. */
  async fitToWidth(): Promise<void> {
    this.assertActive();
    const pdf = this.document;
    if (!pdf) return;
    const firstPage = await pdf.getPage(1);
    const viewport = firstPage.getViewport({ scale: 1 });
    firstPage.cleanup();
    this.scale = clamp(this.availablePageWidth() / viewport.width, this.minScale, this.maxScale);
    await this.renderPages();
  }

  /** Cancels active work, destroys PDF.js state, and clears the target. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.renderVersion += 1;
    this.renderTask?.cancel();
    this.renderTask = undefined;
    this.releaseDocument();
    if (this.element.parentNode === this.target) this.target.replaceChildren();
    this.onDispose?.();
  }

  private async load(initialScale: number | "fit-width"): Promise<void> {
    const pdfJs = await loadPdfJs();
    this.assertActive();
    this.loadingTask = pdfJs.getDocument({ data: this.bytes });
    this.document = await this.loadingTask.promise;
    this.assertActive();
    if (this.document.numPages !== this.expectedPageCount) {
      throw new Error(`Preview loaded ${this.document.numPages} pages; renderer reported ${this.expectedPageCount}`);
    }
    if (initialScale === "fit-width") {
      const firstPage = await this.document.getPage(1);
      const viewport = firstPage.getViewport({ scale: 1 });
      firstPage.cleanup();
      this.scale = clamp(this.availablePageWidth() / viewport.width, this.minScale, this.maxScale);
    } else {
      this.scale = clamp(initialScale, this.minScale, this.maxScale);
    }
    await this.renderPages();
  }

  /**
   * Renders pages serially so progress, cancellation, and memory use remain
   * deterministic across browsers.
   */
  private async renderPages(): Promise<void> {
    const pdf = this.document;
    if (!pdf) return;
    const version = ++this.renderVersion;
    this.renderTask?.cancel();
    this.renderTask = undefined;
    this.pagesElement.replaceChildren();
    this.updateControls();

    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber += 1) {
      if (this.disposed || version !== this.renderVersion) return;
      this.summaryElement.textContent = `Rendering page ${pageNumber} of ${pdf.numPages}`;
      const page = await pdf.getPage(pageNumber);
      const viewport = page.getViewport({ scale: this.scale });
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(Math.floor(viewport.width * this.pixelRatio), 1);
      canvas.height = Math.max(Math.floor(viewport.height * this.pixelRatio), 1);
      canvas.style.width = `${Math.floor(viewport.width)}px`;
      canvas.style.height = `${Math.floor(viewport.height)}px`;
      canvas.setAttribute("role", "img");
      canvas.setAttribute("aria-label", `PDF page ${pageNumber} of ${pdf.numPages}`);

      const pageElement = document.createElement("article");
      pageElement.className = "page";
      pageElement.dataset.pageNumber = String(pageNumber);
      pageElement.append(canvas);
      this.pagesElement.append(pageElement);

      const renderOptions: Parameters<PdfJsPage["render"]>[0] = { canvas, viewport };
      if (this.pixelRatio !== 1) renderOptions.transform = [this.pixelRatio, 0, 0, this.pixelRatio, 0, 0];
      const renderTask = page.render(renderOptions);
      this.renderTask = renderTask;
      try {
        await renderTask.promise;
      } catch (error) {
        if (this.disposed || version !== this.renderVersion) return;
        throw error;
      } finally {
        if (this.renderTask === renderTask) this.renderTask = undefined;
        page.cleanup();
      }
      this.onProgress?.(pageNumber, pdf.numPages);
    }

    if (version === this.renderVersion) {
      this.summaryElement.textContent = `${pdf.numPages} ${pdf.numPages === 1 ? "page" : "pages"}`;
      this.updateControls();
    }
  }

  private updateControls(): void {
    this.scaleElement.value = `${Math.round(this.scale * 100)}%`;
    this.zoomOutButton.disabled = this.scale <= this.minScale + 0.001;
    this.zoomInButton.disabled = this.scale >= this.maxScale - 0.001;
  }

  private availablePageWidth(): number {
    const style = getComputedStyle(this.pagesElement);
    const horizontalPadding = Number.parseFloat(style.paddingLeft) + Number.parseFloat(style.paddingRight);
    return Math.max(this.pagesElement.clientWidth - horizontalPadding, 120);
  }

  private showError(error: unknown): void {
    if (this.disposed) return;
    this.pagesElement.replaceChildren();
    const message = document.createElement("p");
    message.className = "error";
    message.setAttribute("role", "alert");
    message.textContent = `PDF preview failed: ${error instanceof Error ? error.message : String(error)}`;
    this.pagesElement.append(message);
    this.summaryElement.textContent = "Preview unavailable";
  }

  private releaseDocument(): void {
    if (this.document) void this.document.destroy();
    else if (this.loadingTask) void this.loadingTask.destroy();
    this.document = undefined;
    this.loadingTask = undefined;
  }

  private assertActive(): void {
    if (this.disposed) throw new Error("PdfPreview has been disposed");
  }
}

function createButton(label: string, ariaLabel: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.className = "zoom";
  button.type = "button";
  button.textContent = label;
  button.setAttribute("aria-label", ariaLabel);
  return button;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}
