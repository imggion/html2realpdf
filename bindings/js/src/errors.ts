/**
 * Stable error classes exposed by the package root.
 *
 * @packageDocumentation
 */

/** Base error carrying a machine-readable wrapper error code. */
export class Html2RealPdfError extends Error {
  constructor(
    message: string,
    /** Stable value suitable for control flow and telemetry. */
    readonly code: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "Html2RealPdfError";
  }
}

/** Rendering was requested where browser DOM APIs are unavailable. */
export class UnsupportedEnvironmentError extends Html2RealPdfError {
  constructor(message = "html2realpdf rendering requires a browser environment") {
    super(message, "UNSUPPORTED_ENVIRONMENT");
    this.name = "UnsupportedEnvironmentError";
  }
}

/** The source is not a string, mounted element, or non-null ref-like object. */
export class InvalidSourceError extends Html2RealPdfError {
  constructor(message: string) {
    super(message, "INVALID_SOURCE");
    this.name = "InvalidSourceError";
  }
}

/** Authored CSS or SVG cannot satisfy the selected strictness policy. */
export class UnsupportedCssError extends Html2RealPdfError {
  constructor(message: string) {
    super(message, "UNSUPPORTED_CSS");
    this.name = "UnsupportedCssError";
  }
}

/**
 * The WASM bridge or native renderer failed.
 *
 * @remarks
 * `status` preserves the native or bridge status code for logging and
 * operational classification.
 */
export class WasmRenderError extends Html2RealPdfError {
  constructor(
    message: string,
    /** Native renderer status or a negative bridge status. */
    readonly status: number,
    options?: ErrorOptions,
  ) {
    super(message, "WASM_RENDER_FAILED", options);
    this.name = "WasmRenderError";
  }
}

/** An image, stylesheet, canvas, or SVG resource could not be materialized. */
export class ResourceLoadError extends Html2RealPdfError {
  constructor(resource: string, options?: ErrorOptions) {
    super(`Could not load resource: ${resource}`, "RESOURCE_LOAD_FAILED", options);
    this.name = "ResourceLoadError";
  }
}

/** A canvas-to-SVG adapter threw or returned an invalid result. */
export class CanvasToSvgError extends Html2RealPdfError {
  constructor(
    message: string,
    /** Snapshot path of the canvas whose adapter failed. */
    readonly nodePath: string,
    options?: ErrorOptions,
  ) {
    super(`${message}: ${nodePath}`, "CANVAS_TO_SVG_FAILED", options);
    this.name = "CanvasToSvgError";
  }
}

/** A requested html2pdf.js stage belongs to its unsupported raster pipeline. */
export class UnsupportedCompatibilityFeatureError extends Html2RealPdfError {
  constructor(feature: string) {
    super(`${feature} belongs to the raster html2canvas/jsPDF pipeline and is not supported`, "UNSUPPORTED_COMPAT_FEATURE");
    this.name = "UnsupportedCompatibilityFeatureError";
  }
}
