export class Html2RealPdfError extends Error {
  constructor(
    message: string,
    readonly code: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class UnsupportedEnvironmentError extends Html2RealPdfError {
  constructor(message = "html2realpdf rendering requires a browser environment") {
    super(message, "UNSUPPORTED_ENVIRONMENT");
  }
}

export class InvalidSourceError extends Html2RealPdfError {
  constructor(message: string) {
    super(message, "INVALID_SOURCE");
  }
}

export class UnsupportedCssError extends Html2RealPdfError {
  constructor(message: string) {
    super(message, "UNSUPPORTED_CSS");
  }
}

export class WasmRenderError extends Html2RealPdfError {
  constructor(message: string, readonly status: number, options?: ErrorOptions) {
    super(message, "WASM_RENDER_FAILED", options);
  }
}

export class ResourceLoadError extends Html2RealPdfError {
  constructor(resource: string, options?: ErrorOptions) {
    super(`Could not load resource: ${resource}`, "RESOURCE_LOAD_FAILED", options);
  }
}

export class UnsupportedCompatibilityFeatureError extends Html2RealPdfError {
  constructor(feature: string) {
    super(`${feature} belongs to the raster html2canvas/jsPDF pipeline and is not supported`, "UNSUPPORTED_COMPAT_FEATURE");
  }
}
