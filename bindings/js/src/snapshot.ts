import { InvalidSourceError, ResourceLoadError, UnsupportedCssError, UnsupportedEnvironmentError } from "./errors.js";
import type { Diagnostic, HtmlSource, ResourceResolver } from "./types.js";

export interface SnapshotOptions {
  baseUrl?: string | URL;
  resourcePolicy: "error" | "omit";
  resourceResolver?: ResourceResolver;
  strict?: boolean;
  enableLinks?: boolean;
}

export interface SnapshotResult {
  html: string;
  diagnostics: Diagnostic[];
}

const SUPPORTED_COMPUTED_PROPERTIES = [
  "display",
  "width",
  "height",
  "min-width",
  "max-width",
  "min-height",
  "max-height",
  "box-sizing",
  "margin-top",
  "margin-right",
  "margin-bottom",
  "margin-left",
  "padding-top",
  "padding-right",
  "padding-bottom",
  "padding-left",
  "border-top-width",
  "border-right-width",
  "border-bottom-width",
  "border-left-width",
  "border-top-style",
  "border-right-style",
  "border-bottom-style",
  "border-left-style",
  "border-top-color",
  "border-right-color",
  "border-bottom-color",
  "border-left-color",
  "border-collapse",
  "border-radius",
  "background-color",
  "color",
  "font-family",
  "font-size",
  "font-style",
  "font-weight",
  "line-height",
  "letter-spacing",
  "text-align",
  "text-decoration-line",
  "white-space",
  "break-before",
  "break-after",
  "break-inside",
] as const;

const SVG_COMPUTED_PROPERTIES = [
  "fill",
  "fill-opacity",
  "fill-rule",
  "stroke",
  "stroke-dasharray",
  "stroke-dashoffset",
  "stroke-linecap",
  "stroke-linejoin",
  "stroke-opacity",
  "stroke-width",
] as const;

const SUPPORTED_DISPLAY = new Set([
  "none",
  "block",
  "inline",
  "inline-block",
  "table",
  "table-row-group",
  "table-header-group",
  "table-footer-group",
  "table-row",
  "table-cell",
]);

const ACTIVE_ELEMENTS = "script,iframe,object,embed";
const SUPPORTED_CSS_PROPERTIES = new Set<string>([
  ...SUPPORTED_COMPUTED_PROPERTIES,
  "margin", "padding", "border", "border-top", "border-right", "border-bottom", "border-left",
  "border-width", "border-style", "border-color", "background", "page-break-before", "page-break-after",
  "page-break-inside", "orphans", "widows",
]);

export async function snapshotSource(source: HtmlSource, options: SnapshotOptions): Promise<SnapshotResult> {
  if (typeof window === "undefined" || typeof Element === "undefined") throw new UnsupportedEnvironmentError();
  if (typeof source === "string") return snapshotHtmlString(source, options);

  const element = isRefLike(source) ? source.current : source;
  if (!element) throw new InvalidSourceError("The supplied ref is null; render after the element has mounted");
  if (!(element instanceof Element)) throw new InvalidSourceError("Expected an HTML string, Element, or ref-like object");

  const clone = element.cloneNode(true) as Element;
  const originals = [element, ...element.querySelectorAll("*")];
  const clones = [clone, ...clone.querySelectorAll("*")];
  if (originals.length !== clones.length) throw new InvalidSourceError("Could not create a stable DOM snapshot");
  const diagnostics: Diagnostic[] = [];

  for (let index = 0; index < originals.length; index += 1) {
    const original = originals[index];
    const target = clones[index];
    if (!original || !target) continue;

    materializeComputedStyle(original, target, options, diagnostics, index === 0);
    materializeLiveState(original, target);
    removeEventHandlers(target);
  }

  for (const active of clone.matches(ACTIVE_ELEMENTS) ? [clone] : clone.querySelectorAll(ACTIVE_ELEMENTS)) {
    active.remove();
  }
  if (options.enableLinks === false) for (const anchor of clone.querySelectorAll("a[href]")) anchor.removeAttribute("href");

  await materializeInlineSvgs(clone, options, diagnostics);
  inspectAuthoredCss(clone, options, diagnostics);
  await materializeImages(clone, options, diagnostics);
  return { html: clone.outerHTML, diagnostics };
}

async function snapshotHtmlString(source: string, options: SnapshotOptions): Promise<SnapshotResult> {
  const template = document.createElement("template");
  template.innerHTML = source;
  for (const input of template.content.querySelectorAll("input")) {
    const text = input.type === "checkbox" || input.type === "radio"
      ? input.checked ? "☑" : "☐"
      : input.type === "password" ? "•".repeat(input.value.length) : input.value;
    replaceFormControl(input, text);
  }
  for (const textarea of template.content.querySelectorAll("textarea")) replaceFormControl(textarea, textarea.value, true);
  for (const select of template.content.querySelectorAll("select")) {
    replaceFormControl(select, [...select.selectedOptions].map((option) => option.text).join(", "));
  }
  for (const active of template.content.querySelectorAll(ACTIVE_ELEMENTS)) active.remove();
  for (const element of template.content.querySelectorAll("*")) removeEventHandlers(element);
  if (options.enableLinks === false) for (const anchor of template.content.querySelectorAll("a[href]")) anchor.removeAttribute("href");

  const diagnostics: Diagnostic[] = [];
  await materializeInlineSvgs(template.content, options, diagnostics);
  inspectAuthoredCss(template.content, options, diagnostics);
  await materializeImages(template.content, options, diagnostics);
  return { html: template.innerHTML, diagnostics };
}

function isRefLike(source: Exclude<HtmlSource, string>): source is { readonly current: Element | null } {
  return !(source instanceof Element) && "current" in source;
}

function materializeComputedStyle(
  original: Element,
  target: Element,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  isSnapshotRoot: boolean,
): void {
  const computed = window.getComputedStyle(original);
  const display = normalizeComputedDisplay(original, computed.getPropertyValue("display"));
  const position = computed.getPropertyValue("position");
  const floatValue = computed.getPropertyValue("float");

  if (!SUPPORTED_DISPLAY.has(display)) {
    throw new UnsupportedCssError(`display:${display} is outside the document/report layout profile`);
  }
  if (position !== "static") {
    throw new UnsupportedCssError(`position:${position} is outside the document/report layout profile`);
  }
  if (floatValue !== "none") {
    throw new UnsupportedCssError(`float:${floatValue} is outside the document/report layout profile`);
  }

  if (!(original instanceof SVGElement)) {
    const unsupportedComputed = [
      ["background-image", computed.getPropertyValue("background-image"), "none"],
      ["box-shadow", computed.getPropertyValue("box-shadow"), "none"],
      ["opacity", computed.getPropertyValue("opacity"), "1"],
      ["transform", computed.getPropertyValue("transform"), "none"],
      ["filter", computed.getPropertyValue("filter"), "none"],
    ] as const;
    for (const [property, value, initial] of unsupportedComputed) {
      if (value && value !== initial && !/^0px(?: 0px){0,3}$/.test(value)) {
        reportUnsupportedCss(property, options, diagnostics);
      }
    }
  }

  const declarations: string[] = [];
  const properties = original instanceof SVGElement
    ? [...SUPPORTED_COMPUTED_PROPERTIES, ...SVG_COMPUTED_PROPERTIES]
    : SUPPORTED_COMPUTED_PROPERTIES;
  for (const property of properties) {
    const value = property === "display" ? display : computed.getPropertyValue(property);
    if (isFlowDimension(property) && !shouldMaterializeFlowDimension(original, property, isSnapshotRoot)) continue;
    // The Zig color parser currently flattens alpha over white. Serializing a
    // transparent background for every descendant would therefore paint white
    // boxes over a colored ancestor instead of preserving browser compositing.
    if (property === "background-color" && isFullyTransparentColor(value)) continue;
    if (value) declarations.push(`${property}:${value}`);
  }
  target.setAttribute("style", declarations.join(";"));
}

function isFlowDimension(property: string): boolean {
  return property === "width" || property === "height" || property === "min-width" || property === "max-width" ||
    property === "min-height" || property === "max-height";
}

function shouldMaterializeFlowDimension(original: Element, property: string, isSnapshotRoot: boolean): boolean {
  if (property === "width" && isSnapshotRoot) return true;
  if (isReplacedOrControl(original)) return true;
  return hasAuthoredProperty(original, property);
}

function isReplacedOrControl(original: Element): boolean {
  return original instanceof HTMLImageElement || original instanceof HTMLCanvasElement || original instanceof SVGElement ||
    original instanceof HTMLInputElement || original instanceof HTMLTextAreaElement || original instanceof HTMLSelectElement ||
    original instanceof HTMLButtonElement || original instanceof HTMLProgressElement || original instanceof HTMLMeterElement;
}

function hasAuthoredProperty(element: Element, property: string): boolean {
  if (element instanceof HTMLElement || element instanceof SVGElement) {
    if (element.style.getPropertyValue(property)) return true;
  }

  for (const sheet of element.ownerDocument.styleSheets) {
    try {
      if (rulesAuthorProperty(sheet.cssRules, element, property)) return true;
    } catch {
      // Cross-origin stylesheets cannot expose cssRules. The computed snapshot
      // remains usable; only an authored fixed flow dimension may be omitted.
    }
  }
  return false;
}

function rulesAuthorProperty(rules: CSSRuleList, element: Element, property: string): boolean {
  for (const rule of rules) {
    if (rule instanceof CSSStyleRule) {
      try {
        if (rule.style.getPropertyValue(property) && element.matches(rule.selectorText)) return true;
      } catch {
        // Ignore selectors that Element.matches cannot evaluate in this context.
      }
      continue;
    }
    if ("cssRules" in rule && rule.cssRules instanceof CSSRuleList) {
      if (rule instanceof CSSMediaRule && !window.matchMedia(rule.conditionText).matches) continue;
      if (rulesAuthorProperty(rule.cssRules, element, property)) return true;
    }
  }
  return false;
}

function normalizeComputedDisplay(original: Element, display: string): string {
  switch (display) {
    case "list-item":
    case "table-caption":
      return "block";
    case "flow-root":
      return original instanceof HTMLButtonElement ? "inline-block" : "block";
    default:
      return display;
  }
}

function isFullyTransparentColor(value: string): boolean {
  const normalized = value.replace(/\s+/g, "").toLowerCase();
  return normalized === "transparent" || /^rgba\([^,]+,[^,]+,[^,]+,0(?:\.0+)?\)$/.test(normalized);
}

async function materializeInlineSvgs(
  root: ParentNode,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): Promise<void> {
  const svgs = [...root.querySelectorAll("svg")];
  if (root instanceof SVGSVGElement) svgs.unshift(root);
  for (const svg of svgs) {
    if (!svg.isConnected && !svg.parentNode && svg !== root) continue;
    try {
      if (!svg.hasAttribute("xmlns")) svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      const source = new XMLSerializer().serializeToString(svg);
      const replacement = document.createElement("img");
      for (const attribute of svg.attributes) {
        if (attribute.name !== "xmlns") replacement.setAttribute(attribute.name, attribute.value);
      }
      replacement.src = await rasterizeBlobToPng(new Blob([source], { type: "image/svg+xml" }));
      replacement.alt = svg.getAttribute("aria-label") ?? "";
      svg.replaceWith(replacement);
    } catch (error) {
      if (options.resourcePolicy === "error") throw new ResourceLoadError("inline SVG", { cause: error });
      svg.remove();
      diagnostics.push({
        code: "RESOURCE_OMITTED",
        severity: "warning",
        message: "Inline SVG resource was omitted",
      });
    }
  }
}

function materializeLiveState(original: Element, target: Element): void {
  if (original instanceof HTMLInputElement && target instanceof HTMLInputElement) {
    const text = original.type === "checkbox" || original.type === "radio"
      ? original.checked ? "☑" : "☐"
      : original.type === "password" ? "•".repeat(original.value.length) : original.value;
    replaceFormControl(target, text);
  } else if (original instanceof HTMLTextAreaElement && target instanceof HTMLTextAreaElement) {
    replaceFormControl(target, original.value, true);
  } else if (original instanceof HTMLSelectElement && target instanceof HTMLSelectElement) {
    replaceFormControl(target, [...original.selectedOptions].map((option) => option.text).join(", "));
  } else if (original instanceof HTMLButtonElement && target instanceof HTMLButtonElement) {
    replaceFormControl(target, original.innerText);
  } else if (original instanceof HTMLProgressElement && target instanceof HTMLProgressElement) {
    replaceFormControl(target, `${Math.round(original.position * 100)}%`);
  } else if (original instanceof HTMLMeterElement && target instanceof HTMLMeterElement) {
    replaceFormControl(target, String(original.value));
  } else if (original instanceof HTMLDetailsElement && target instanceof HTMLDetailsElement && !original.open) {
    for (const child of [...target.children]) {
      if (!(child instanceof HTMLElement) || child.localName !== "summary") child.remove();
    }
  } else if (original instanceof HTMLImageElement && target instanceof HTMLImageElement) {
    if (original.currentSrc) target.src = original.currentSrc;
  } else if (original instanceof HTMLCanvasElement && target instanceof HTMLCanvasElement) {
    const replacement = document.createElement("img");
    for (const attribute of target.attributes) replacement.setAttribute(attribute.name, attribute.value);
    replacement.src = canvasToPng(original);
    replacement.width = original.width;
    replacement.height = original.height;
    target.replaceWith(replacement);
  }
}

function replaceFormControl(target: HTMLElement, text: string, preserveWhitespace = false): void {
  const replacement = document.createElement("span");
  for (const attribute of target.attributes) replacement.setAttribute(attribute.name, attribute.value);
  if (!replacement.style.display) replacement.style.display = "inline-block";
  if (preserveWhitespace) replacement.style.whiteSpace = "pre-wrap";
  replacement.textContent = text;
  target.replaceWith(replacement);
}

async function materializeImages(
  root: ParentNode,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): Promise<void> {
  const images = [...root.querySelectorAll("img")];
  for (const image of images) {
    const source = image.currentSrc || image.getAttribute("src") || "";
    if (!source || source.startsWith("data:image/jpeg") || source.startsWith("data:image/jpg") || source.startsWith("data:image/png")) continue;

    try {
      const url = new URL(source, options.baseUrl ?? document.baseURI);
      const resolved = await options.resourceResolver?.({ kind: "image", url });
      if (typeof resolved === "string" && /^data:image\/(?:jpeg|jpg|png);/i.test(resolved)) {
        image.src = resolved;
        continue;
      }
      const blob = resolved instanceof Blob ? resolved : await fetchImageBlob(
        typeof resolved === "string" ? new URL(resolved, url) : url,
      );
      image.src = blob.type === "image/jpeg" ? await blobToDataUrl(blob) : await rasterizeBlobToPng(blob);
    } catch (error) {
      if (options.resourcePolicy === "error") throw new ResourceLoadError(source, { cause: error });
      image.remove();
      diagnostics.push({
        code: "RESOURCE_OMITTED",
        severity: "warning",
        message: `Image resource was omitted: ${source}`,
      });
    }
  }
}

async function fetchImageBlob(url: URL): Promise<Blob> {
  const response = await fetch(url, { mode: "cors" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.blob();
}

function inspectAuthoredCss(root: ParentNode, options: SnapshotOptions, diagnostics: Diagnostic[]): void {
  const elements = [...root.querySelectorAll("[style],style")];
  if (root instanceof Element && (root.hasAttribute("style") || root.localName === "style")) elements.unshift(root);
  for (const element of elements) {
    const css = element.localName === "style" ? element.textContent ?? "" : element.getAttribute("style") ?? "";
    for (const match of css.matchAll(/(?:^|[;{])\s*([\w-]+)\s*:\s*([^;}]+)/g)) {
      const property = match[1]?.toLowerCase();
      const value = (match[2]?.trim().toLowerCase() ?? "").replace(/\s*!important\s*$/, "");
      if (!property || property.startsWith("--")) continue;
      validateAuthoredLayout(property, value);
      if (property === "background" && /(?:url|(?:repeating-)?(?:linear|radial|conic)-gradient)\s*\(/.test(value)) {
        reportUnsupportedCss("background-image", options, diagnostics);
      }
      if (SUPPORTED_CSS_PROPERTIES.has(property)) continue;
      reportUnsupportedCss(property, options, diagnostics);
    }
  }
}

function validateAuthoredLayout(property: string, value: string): void {
  if (property === "display" && !SUPPORTED_DISPLAY.has(value)) {
    throw new UnsupportedCssError(`display:${value} is outside the document/report layout profile`);
  }
  if (property === "position" && value !== "static") {
    throw new UnsupportedCssError(`position:${value} is outside the document/report layout profile`);
  }
  if (property === "float" && value !== "none") {
    throw new UnsupportedCssError(`float:${value} is outside the document/report layout profile`);
  }
}

function reportUnsupportedCss(property: string, options: SnapshotOptions, diagnostics: Diagnostic[]): void {
  if (options.strict) throw new UnsupportedCssError(`${property} is outside the document/report layout profile`);
  if (diagnostics.some((diagnostic) => diagnostic.code === "UNSUPPORTED_CSS_PROPERTY" && diagnostic.message.includes(property))) return;
  diagnostics.push({
    code: "UNSUPPORTED_CSS_PROPERTY",
    severity: "warning",
    message: `Unsupported CSS property was omitted: ${property}`,
  });
}

function canvasToPng(source: HTMLCanvasElement): string {
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(source.width, 1);
  canvas.height = Math.max(source.height, 1);
  const context = canvas.getContext("2d");
  if (!context) throw new ResourceLoadError("canvas");
  context.drawImage(source, 0, 0);
  return canvas.toDataURL("image/png");
}

async function rasterizeBlobToPng(blob: Blob): Promise<string> {
  const objectUrl = URL.createObjectURL(blob);
  try {
    const image = new Image();
    image.src = objectUrl;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(image.naturalWidth, 1);
    canvas.height = Math.max(image.naturalHeight, 1);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Canvas 2D context is unavailable");
    context.drawImage(image, 0, 0);
    return canvas.toDataURL("image/png");
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => resolve(String(reader.result)), { once: true });
    reader.addEventListener("error", () => reject(reader.error), { once: true });
    reader.readAsDataURL(blob);
  });
}

function removeEventHandlers(element: Element): void {
  for (const attribute of [...element.attributes]) {
    if (attribute.name.toLowerCase().startsWith("on")) element.removeAttribute(attribute.name);
  }
}
