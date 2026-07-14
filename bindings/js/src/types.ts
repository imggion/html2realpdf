/**
 * Public configuration and callback contracts for the browser wrapper.
 *
 * @packageDocumentation
 */

/** A structural ref accepted without making React a runtime dependency. */
export type RefLike<T> = { readonly current: T | null };

/**
 * Input accepted by the snapshot boundary.
 *
 * @remarks
 * Mounted elements and refs preserve computed styles and live browser state;
 * strings are evaluated in an inert document.
 */
export type HtmlSource = string | Element | RefLike<Element>;

/** Units used for custom page dimensions and margins. */
export type LengthUnit = "pt" | "px" | "mm" | "cm" | "in";

/** Named physical page sizes or a custom `[width, height]` in the selected unit. */
export type PageFormat = "a4" | "letter" | readonly [width: number, height: number];

/** Orientation applied after resolving the page format. */
export type PageOrientation = "portrait" | "landscape";

/**
 * Layout and CSS support profile.
 *
 * @remarks
 * `document` favors stable paged reports. `web` enables the broader browser
 * layout profile. `strict` uses that broader profile and rejects unsupported
 * CSS by default.
 */
export type CssProfile = "document" | "web" | "strict";

/** Media environment used while resolving styles and media queries. */
export type MediaType = "screen" | "print";

/** Containing block used for the snapshotted root element. */
export type LayoutContext = "source" | "page";

/** Action taken when an authored CSS property is outside the selected profile. */
export type UnsupportedCssPolicy = "warn" | "error" | "ignore";

/** Policy for SVG subtrees that cannot remain native PDF vectors. */
export type FallbackPolicy = "error" | "rasterize-subtree";

/** Policy used when a canvas-to-SVG adapter intentionally returns `null`. */
export type CanvasFallbackPolicy = "error" | "rasterize";

/** Complete SVG returned by a canvas adapter. */
export type CanvasSvgSource = string | Blob | SVGSVGElement;

/** Context passed to a canvas-to-SVG adapter. */
export interface CanvasToSvgRequest {
  /** Original live canvas, suitable for chart-library export APIs. */
  canvas: HTMLCanvasElement;
  /** Stable snapshot path used to identify failures and fallbacks. */
  nodePath: string;
  /** Rendered canvas width in CSS pixels. */
  cssWidth: number;
  /** Rendered canvas height in CSS pixels. */
  cssHeight: number;
  /** Backing bitmap width. */
  bitmapWidth: number;
  /** Backing bitmap height. */
  bitmapHeight: number;
}

/**
 * Replaces a live canvas with vector SVG when the source library can export it.
 *
 * @remarks
 * Returning `null` delegates to `canvasFallback`. Throwing or returning
 * malformed SVG produces `CanvasToSvgError`.
 */
export type CanvasToSvg = (
  request: CanvasToSvgRequest,
) => CanvasSvgSource | null | Promise<CanvasSvgSource | null>;

/** Deterministic viewport used for responsive layout and media queries. */
export interface ViewportOptions {
  /** Viewport width in CSS pixels. Values below one are clamped. */
  width: number;
  /** Viewport height in CSS pixels. Values below one are clamped. */
  height: number;
}

/**
 * Page margins in the selected page unit.
 *
 * @remarks
 * Four values use html2pdf.js order `[top, left, bottom, right]`, not CSS
 * shorthand order. Two values mean `[vertical, horizontal]`.
 */
export type Margin =
  | number
  | readonly [vertical: number, horizontal: number]
  | readonly [top: number, left: number, bottom: number, right: number];

/** Explicit page geometry. Supplying this overrides captured `@page` geometry. */
export interface PageOptions {
  /** Page size. Defaults to `a4`. */
  format?: PageFormat;
  /** Page orientation. Defaults to `portrait`. */
  orientation?: PageOrientation;
  /** Unit for custom dimensions and margins. Defaults to `pt`. */
  unit?: LengthUnit;
  /** Page margins. Defaults to zero on every edge. */
  margin?: Margin;
}

/** Coarse rendering phases reported at stable cancellation boundaries. */
export type RenderPhase = "snapshot" | "wasm" | "complete";

/** Progress notification for a rendering phase. */
export interface RenderProgress {
  /** Phase producing this notification. */
  phase: RenderPhase;
  /** Completed work units within the phase. */
  completed: number;
  /** Total work units within the phase. */
  total: number;
}

/** Structured warning or error produced without losing successful PDF output. */
export interface Diagnostic {
  /** Stable machine-readable identifier. */
  code: string;
  /** Diagnostic severity assigned by the snapshot or native renderer. */
  severity: "warning" | "error";
  /** Human-readable explanation. */
  message: string;
  /** CSS property associated with the diagnostic, when applicable. */
  property?: string;
  /** Stable snapshot path to the affected node, when available. */
  nodePath?: string;
  /** Pipeline phase that produced the diagnostic. */
  phase?: "snapshot" | "parse" | "cascade" | "computed" | "layout" | "fragmentation" | "paint" | "pdf";
  /** Fallback that preserved output despite the unsupported input. */
  fallback?: string;
}

/** Resource requested while materializing a self-contained snapshot. */
export interface ResourceRequest {
  /** Resource class. Fonts are registered on `createRenderer` instead. */
  kind: "image" | "stylesheet";
  /** Absolute URL resolved against `baseUrl` or the source document. */
  url: URL;
}

/**
 * Resolves resources that cannot be fetched directly by the browser snapshot.
 *
 * @remarks
 * For stylesheets, a string is CSS source. For images, a string is a data URL
 * or replacement URL. `null` leaves the request unresolved and applies
 * `resourcePolicy`.
 */
export type ResourceResolver = (request: ResourceRequest) => Blob | string | null | Promise<Blob | string | null>;

/** Selector-driven pagination overrides compatible with html2pdf.js workflows. */
export interface PageBreakRules {
  /** Selectors forced to begin on a new page. */
  before?: string | readonly string[];
  /** Selectors forced to end the current page. */
  after?: string | readonly string[];
  /** Selectors whose contents should avoid internal fragmentation. */
  avoid?: string | readonly string[];
  /** Applies `break-inside: avoid` to every element. */
  avoidAll?: boolean;
  /** Honors the legacy `.html2pdf__page-break` marker. */
  legacy?: boolean;
}

/** PDF information dictionary fields written by the native renderer. */
export interface PdfMetadata {
  /** Document title. */
  title?: string;
  /** Document author. */
  author?: string;
  /** Document subject. */
  subject?: string;
  /** Search keywords, joined when supplied as an array. */
  keywords?: string | readonly string[];
  /** Application or service that created the document. */
  creator?: string;
}

/** Options applied to one HTML snapshot and PDF render. */
export interface RenderOptions {
  /** Explicit page geometry; captured `@page` rules are used when omitted. */
  page?: PageOptions;
  /**
   * Promotes unsupported snapshot CSS to errors without selecting the `web`
   * layout profile. An explicit `unsupportedCss` policy takes precedence.
   */
  strict?: boolean;
  /** Layout profile. Defaults to `document`. */
  cssProfile?: CssProfile;
  /** Media environment used for style resolution. Defaults to `screen`. */
  mediaType?: MediaType;
  /**
   * Root layout context. `source` preserves the mounted browser width;
   * `page` resolves an implicit root width and auto inline margins against the
   * PDF content box. Defaults to `source`.
   */
  layoutContext?: LayoutContext;
  /** Isolated viewport used for media queries and responsive layout. */
  viewport?: ViewportOptions;
  /** Unsupported-CSS policy; defaults to `error` for strict mode and `warn` otherwise. */
  unsupportedCss?: UnsupportedCssPolicy;
  /** Unsupported SVG policy. Defaults to `error`. */
  fallback?: FallbackPolicy;
  /** Optional bridge from live canvas content to validated SVG. */
  canvasToSvg?: CanvasToSvg;
  /** Fallback when `canvasToSvg` returns `null`. Defaults to `error`. */
  canvasFallback?: CanvasFallbackPolicy;
  /** Flattens open Shadow DOM into the snapshot. Defaults to `false`. */
  includeShadowDom?: boolean;
  /** Base URL for relative resources. Defaults to the source document URL. */
  baseUrl?: string | URL;
  /** Failed-resource policy. Defaults to `error`. */
  resourcePolicy?: "error" | "omit";
  /** Resolver for protected, virtual, or otherwise unavailable resources. */
  resourceResolver?: ResourceResolver;
  /** Selector-driven page-break overrides. */
  pageBreak?: PageBreakRules;
  /** PDF information dictionary fields. */
  metadata?: PdfMetadata;
  /** Preserves PDF link annotations unless explicitly set to `false`. */
  enableLinks?: boolean;
  /**
   * Rejects the caller at snapshot and render boundaries when aborted.
   * An already-running synchronous WASM render cannot be preempted.
   */
  signal?: AbortSignal;
  /** Receives coarse phase-boundary progress, not per-page render progress. */
  onProgress?: (progress: RenderProgress) => void;
}

/** Configuration whose lifetime matches an explicit renderer instance. */
export interface RendererInit {
  /** Execution backend. Defaults to `worker`. */
  execution?: "worker" | "main";
  /** WASM asset override for deployments that cannot serve package-relative assets. */
  wasmUrl?: string | URL;
  /** Embeddable TrueType fonts registered once for every render. */
  fonts?: readonly FontRegistration[];
}

/** Embeddable TrueType font registered in a renderer-owned WASM context. */
export interface FontRegistration {
  /** CSS family name used during font resolution. */
  family: string;
  /** Complete TrueType font bytes, copied into the native context. */
  data: ArrayBuffer | Uint8Array;
  /** CSS font weight. Defaults to `400`. */
  weight?: number | "normal" | "bold";
  /** CSS font style. Defaults to `normal`. */
  style?: "normal" | "italic";
}

/** Page settings accepted through the html2pdf.js-compatible `jsPDF` option. */
export interface CompatJsPdfOptions {
  /** Unit shared by custom page geometry and margins. */
  unit?: LengthUnit;
  /** Named or custom page format forwarded to the modern page contract. */
  format?: PageFormat;
  /** Page orientation forwarded to the modern page contract. */
  orientation?: PageOrientation;
}

/** Page-break settings accepted by the html2pdf.js compatibility layer. */
export interface CompatPageBreakOptions {
  /** Compatibility modes. Defaults to `css` and `legacy`. */
  mode?: "css" | "legacy" | "avoid-all" | readonly ("css" | "legacy" | "avoid-all")[];
  /** Selectors forced to begin on a new page. */
  before?: string | readonly string[];
  /** Selectors forced to end the current page. */
  after?: string | readonly string[];
  /** Selectors whose contents should avoid internal fragmentation. */
  avoid?: string | readonly string[];
}

/** Options supported by the PDF-oriented html2pdf.js compatibility layer. */
export interface Html2PdfOptions {
  /** Page margins in html2pdf.js order. */
  margin?: Margin;
  /** Filename used by `save` when no method argument is supplied. */
  filename?: string;
  /** Preserves links unless explicitly disabled. */
  enableLinks?: boolean;
  /** Compatibility pagination rules. */
  pagebreak?: CompatPageBreakOptions;
  /** Compatibility page geometry. */
  jsPDF?: CompatJsPdfOptions;
  /** Unsupported because this renderer does not use an html2canvas pipeline. */
  html2canvas?: never;
  /** Unsupported because PDF pages are not encoded as raster images. */
  image?: never;
}

/** Output encodings supported by compatibility `output` methods. */
export type PdfOutputType =
  | "arraybuffer"
  | "blob"
  | "bloburl"
  | "bloburi"
  | "datauristring"
  | "dataurlstring";
