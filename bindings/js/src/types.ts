export type RefLike<T> = { readonly current: T | null };

export type HtmlSource = string | Element | RefLike<Element>;

export type LengthUnit = "pt" | "px" | "mm" | "cm" | "in";
export type PageFormat = "a4" | "letter" | readonly [width: number, height: number];
export type PageOrientation = "portrait" | "landscape";
export type CssProfile = "document" | "web" | "strict";
export type MediaType = "screen" | "print";
export type UnsupportedCssPolicy = "warn" | "error" | "ignore";
export type FallbackPolicy = "error" | "rasterize-subtree";
export type CanvasFallbackPolicy = "error" | "rasterize";

export type CanvasSvgSource = string | Blob | SVGSVGElement;

export interface CanvasToSvgRequest {
  canvas: HTMLCanvasElement;
  nodePath: string;
  cssWidth: number;
  cssHeight: number;
  bitmapWidth: number;
  bitmapHeight: number;
}

export type CanvasToSvg = (
  request: CanvasToSvgRequest,
) => CanvasSvgSource | null | Promise<CanvasSvgSource | null>;

export interface ViewportOptions {
  width: number;
  height: number;
}
export type Margin = number | readonly [vertical: number, horizontal: number] | readonly [top: number, left: number, bottom: number, right: number];

export interface PageOptions {
  format?: PageFormat;
  orientation?: PageOrientation;
  unit?: LengthUnit;
  margin?: Margin;
}

export type RenderPhase = "snapshot" | "wasm" | "complete";

export interface RenderProgress {
  phase: RenderPhase;
  completed: number;
  total: number;
}

export interface Diagnostic {
  code: string;
  severity: "warning" | "error";
  message: string;
  property?: string;
  nodePath?: string;
  phase?: "snapshot" | "parse" | "cascade" | "computed" | "layout" | "fragmentation" | "paint" | "pdf";
  fallback?: string;
}

export interface ResourceRequest {
  kind: "image" | "stylesheet" | "font";
  url: URL;
}

export type ResourceResolver = (request: ResourceRequest) => Blob | string | null | Promise<Blob | string | null>;

export interface PageBreakRules {
  before?: string | readonly string[];
  after?: string | readonly string[];
  avoid?: string | readonly string[];
  avoidAll?: boolean;
  legacy?: boolean;
}

export interface PdfMetadata {
  title?: string;
  author?: string;
  subject?: string;
  keywords?: string | readonly string[];
  creator?: string;
}

export interface RenderOptions {
  page?: PageOptions;
  filename?: string;
  strict?: boolean;
  cssProfile?: CssProfile;
  mediaType?: MediaType;
  viewport?: ViewportOptions;
  unsupportedCss?: UnsupportedCssPolicy;
  fallback?: FallbackPolicy;
  canvasToSvg?: CanvasToSvg;
  canvasFallback?: CanvasFallbackPolicy;
  includeShadowDom?: boolean;
  baseUrl?: string | URL;
  resourcePolicy?: "error" | "omit";
  resourceResolver?: ResourceResolver;
  pageBreak?: PageBreakRules;
  metadata?: PdfMetadata;
  enableLinks?: boolean;
  signal?: AbortSignal;
  onProgress?: (progress: RenderProgress) => void;
}

export interface RendererInit {
  execution?: "worker" | "main";
  wasmUrl?: string | URL;
  fonts?: readonly FontRegistration[];
}

export interface FontRegistration {
  family: string;
  data: ArrayBuffer | Uint8Array;
  weight?: number | "normal" | "bold";
  style?: "normal" | "italic";
}

export interface CompatJsPdfOptions {
  unit?: LengthUnit;
  format?: PageFormat;
  orientation?: PageOrientation;
}

export interface CompatPageBreakOptions {
  mode?: "css" | "legacy" | "avoid-all" | readonly ("css" | "legacy" | "avoid-all")[];
  before?: string | readonly string[];
  after?: string | readonly string[];
  avoid?: string | readonly string[];
}

export interface Html2PdfOptions {
  margin?: Margin;
  filename?: string;
  enableLinks?: boolean;
  pagebreak?: CompatPageBreakOptions;
  jsPDF?: CompatJsPdfOptions;
  html2canvas?: object;
  image?: { type?: "jpeg" | "png" | "webp"; quality?: number };
}

export type PdfOutputType =
  | "arraybuffer"
  | "blob"
  | "bloburl"
  | "bloburi"
  | "datauristring"
  | "dataurlstring";
