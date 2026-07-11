import { InvalidSourceError, ResourceLoadError, UnsupportedCssError, UnsupportedEnvironmentError } from "./errors.js";
import type { CssProfile, Diagnostic, HtmlSource, MediaType, ResourceResolver, UnsupportedCssPolicy, ViewportOptions } from "./types.js";

export interface SnapshotOptions {
  baseUrl?: string | URL;
  resourcePolicy: "error" | "omit";
  resourceResolver?: ResourceResolver;
  strict?: boolean;
  cssProfile?: CssProfile;
  mediaType?: MediaType;
  viewport?: ViewportOptions;
  unsupportedCss?: UnsupportedCssPolicy;
  includeShadowDom?: boolean;
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

  const { clone, diagnostics } = await snapshotElement(element, options);
  return { html: clone.outerHTML, diagnostics };
}

async function snapshotElement(element: Element, options: SnapshotOptions): Promise<{ clone: Element; diagnostics: Diagnostic[] }> {
  const diagnostics: Diagnostic[] = [];
  const clone = cloneSnapshotElement(element, options, diagnostics, true);

  for (const active of clone.matches(ACTIVE_ELEMENTS) ? [clone] : clone.querySelectorAll(ACTIVE_ELEMENTS)) {
    active.remove();
  }
  if (options.enableLinks === false) for (const anchor of clone.querySelectorAll("a[href]")) anchor.removeAttribute("href");

  await materializeInlineSvgs(clone, options, diagnostics);
  inspectAuthoredCss(clone, options, diagnostics);
  await materializeImages(clone, options, diagnostics);
  return { clone, diagnostics };
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

  const iframe = document.createElement("iframe");
  const viewport = options.viewport ?? { width: 1280, height: 720 };
  const viewportWidth = Math.max(viewport.width, 1);
  const viewportHeight = Math.max(viewport.height, 1);
  iframe.width = String(viewportWidth);
  iframe.height = String(viewportHeight);
  iframe.style.cssText = `position:fixed;left:-100000px;top:0;width:${viewportWidth}px;height:${viewportHeight}px;min-width:${viewportWidth}px;max-width:${viewportWidth}px;min-height:${viewportHeight}px;max-height:${viewportHeight}px;border:0;visibility:hidden`;
  const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:";
  iframe.srcdoc = `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${csp}"></head><body>${template.innerHTML}</body></html>`;
  document.body.append(iframe);

  try {
    await new Promise<void>((resolve, reject) => {
      iframe.addEventListener("load", () => resolve(), { once: true });
      iframe.addEventListener("error", () => reject(new InvalidSourceError("Could not create the inert HTML snapshot document")), { once: true });
    });
    const body = iframe.contentDocument?.body;
    if (!body) throw new InvalidSourceError("The inert HTML snapshot document has no body");
    forceRequestedMedia(body.ownerDocument, options.mediaType ?? "screen");
    const { clone, diagnostics } = await snapshotElement(body, options);
    return { html: clone.innerHTML, diagnostics };
  } finally {
    iframe.remove();
  }
}

function cloneSnapshotElement(
  original: Element,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  isSnapshotRoot: boolean,
): Element {
  const target = original.cloneNode(false) as Element;
  materializeComputedStyle(original, target, options, diagnostics, isSnapshotRoot);

  const childRoot = options.includeShadowDom && original.shadowRoot ? original.shadowRoot : original;
  for (const child of childRoot.childNodes) appendSnapshotNode(target, child, options, diagnostics);

  materializePseudoElements(original, target, options, diagnostics);
  const materialized = materializeLiveState(original, target);
  removeEventHandlers(materialized);
  if (childRoot !== original) materialized.setAttribute("data-html2realpdf-shadow-host", "open");
  return materialized;
}

function appendSnapshotNode(
  parent: Element,
  source: Node,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): void {
  if (source.nodeType === Node.TEXT_NODE) {
    parent.append(parent.ownerDocument.createTextNode(source.textContent ?? ""));
    return;
  }
  if (source.nodeType !== Node.ELEMENT_NODE) return;

  const element = source as Element;
  if (options.includeShadowDom && element.localName === "slot") {
    const slot = element as HTMLSlotElement;
    const assigned = slot.assignedNodes({ flatten: true });
    const nodes = assigned.length > 0 ? assigned : [...slot.childNodes];
    for (const node of nodes) appendSnapshotNode(parent, node, options, diagnostics);
    return;
  }
  parent.append(cloneSnapshotElement(element, options, diagnostics, false));
}

function forceRequestedMedia(document: Document, mediaType: MediaType): void {
  const view = document.defaultView ?? window;
  for (const stylesheet of document.styleSheets) {
    try {
      forceMediaRules(stylesheet.cssRules, mediaType, view);
    } catch {
      // CSP prevents remote stylesheets in inert snapshots. If a browser still
      // exposes a cross-origin sheet, computed styles remain available for the
      // declarations the browser was allowed to load.
    }
  }
}

function forceMediaRules(rules: CSSRuleList, mediaType: MediaType, view: Window): void {
  // CSSRuleList is live. Firefox can skip a following @media rule when the
  // current MediaList is mutated during iteration, so walk a stable snapshot.
  for (const rule of [...rules]) {
    if ("media" in rule && "conditionText" in rule) {
      const mediaRule = rule as CSSMediaRule;
      const matches = matchesRequestedMedia(String(mediaRule.conditionText), mediaType, view);
      mediaRule.media.mediaText = matches ? "all" : "not all";
      if (matches) forceMediaRules(mediaRule.cssRules, mediaType, view);
      continue;
    }
    if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) {
      forceMediaRules((rule as CSSGroupingRule).cssRules, mediaType, view);
    }
  }
}

function matchesRequestedMedia(queryList: string, mediaType: MediaType, view: Window): boolean {
  return splitMediaQueries(queryList).some((query) => matchesSingleMediaQuery(query, mediaType, view));
}

function splitMediaQueries(input: string): string[] {
  const queries: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < input.length; index += 1) {
    if (input[index] === "(") depth += 1;
    else if (input[index] === ")") depth = Math.max(depth - 1, 0);
    else if (input[index] === "," && depth === 0) {
      queries.push(input.slice(start, index));
      start = index + 1;
    }
  }
  queries.push(input.slice(start));
  return queries;
}

function matchesSingleMediaQuery(input: string, mediaType: MediaType, view: Window): boolean {
  let query = input.trim().toLowerCase();
  if (!query) return false;
  let negate = false;
  if (query.startsWith("not ")) {
    negate = true;
    query = query.slice(4).trim();
  } else if (query.startsWith("only ")) {
    query = query.slice(5).trim();
  }

  const typeMatch = query.match(/^(all|screen|print)\b/);
  if (!typeMatch) return view.matchMedia(input).matches;
  const requestedTypeMatches = typeMatch[1] === "all" || typeMatch[1] === mediaType;
  let remainder = query.slice(typeMatch[0].length).trim();
  if (remainder.startsWith("and ")) remainder = remainder.slice(4).trim();
  const featureMatches = !remainder || view.matchMedia(remainder).matches;
  const matches = requestedTypeMatches && featureMatches;
  return negate ? !matches : matches;
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
  computedStyle?: CSSStyleDeclaration,
): void {
  const view = original.ownerDocument.defaultView ?? window;
  const computed = computedStyle ?? view.getComputedStyle(original);
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

  if (!isSvgElement(original)) {
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
  const properties = isSvgElement(original)
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

function materializePseudoElements(
  original: Element,
  target: Element,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): void {
  if (isReplacedOrControl(original)) return;
  materializePseudoElement(original, target, "::before", options, diagnostics);
  materializePseudoElement(original, target, "::after", options, diagnostics);
}

function materializePseudoElement(
  original: Element,
  target: Element,
  pseudo: "::before" | "::after",
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): void {
  const computed = (original.ownerDocument.defaultView ?? window).getComputedStyle(original, pseudo);
  const rawContent = computed.getPropertyValue("content").trim();
  if (!rawContent || rawContent === "none" || rawContent === "normal") return;
  const content = resolveGeneratedContent(rawContent, original);
  if (content === null) {
    reportUnsupportedCss(`content:${rawContent}`, options, diagnostics);
    return;
  }

  const synthetic = target.ownerDocument.createElement("span");
  synthetic.dataset.html2realpdfPseudo = pseudo.slice(2);
  synthetic.textContent = content;
  materializeComputedStyle(original, synthetic, options, diagnostics, false, computed);
  if (pseudo === "::before") target.prepend(synthetic);
  else target.append(synthetic);
}

function resolveGeneratedContent(value: string, original: Element): string | null {
  let output = "";
  let index = 0;
  while (index < value.length) {
    while (/\s/.test(value[index] ?? "")) index += 1;
    if (index >= value.length) break;
    const quote = value[index];
    if (quote === '"' || quote === "'") {
      const parsed = consumeCssString(value, index, quote);
      if (!parsed) return null;
      output += parsed.value;
      index = parsed.next;
      continue;
    }
    if (value.startsWith("attr(", index)) {
      const close = value.indexOf(")", index + 5);
      if (close < 0) return null;
      const name = value.slice(index + 5, close).trim().split(/\s+/)[0];
      if (!name) return null;
      output += original.getAttribute(name) ?? "";
      index = close + 1;
      continue;
    }
    if (value.startsWith("open-quote", index) || value.startsWith("close-quote", index)) {
      output += value.startsWith("open-quote", index) ? "\u201c" : "\u201d";
      index += value.startsWith("open-quote", index) ? 10 : 11;
      continue;
    }
    if (value.startsWith("no-open-quote", index)) {
      index += 13;
      continue;
    }
    if (value.startsWith("no-close-quote", index)) {
      index += 14;
      continue;
    }
    return null;
  }
  return output;
}

function consumeCssString(source: string, start: number, quote: string): { value: string; next: number } | null {
  let value = "";
  let index = start + 1;
  while (index < source.length) {
    const character = source[index];
    if (character === quote) return { value, next: index + 1 };
    if (character !== "\\") {
      value += character;
      index += 1;
      continue;
    }
    index += 1;
    const hex = source.slice(index).match(/^[0-9a-fA-F]{1,6}/)?.[0];
    if (hex) {
      value += String.fromCodePoint(Number.parseInt(hex, 16));
      index += hex.length;
      if (/\s/.test(source[index] ?? "")) index += 1;
    } else if (index < source.length) {
      value += source[index];
      index += 1;
    }
  }
  return null;
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
  return isSvgElement(original) || new Set([
    "img", "canvas", "input", "textarea", "select", "button", "progress", "meter",
  ]).has(original.localName);
}

function hasAuthoredProperty(element: Element, property: string): boolean {
  const inlineStyle = (element as HTMLElement).style;
  if (inlineStyle?.getPropertyValue(property)) return true;

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
    if ("selectorText" in rule && "style" in rule) {
      const styleRule = rule as CSSStyleRule;
      try {
        if (styleRule.style.getPropertyValue(property) && element.matches(styleRule.selectorText)) return true;
      } catch {
        // Ignore selectors that Element.matches cannot evaluate in this context.
      }
      continue;
    }
    if ("cssRules" in rule && rule.cssRules) {
      const nestedRules = (rule as CSSGroupingRule).cssRules;
      const condition = "conditionText" in rule ? String(rule.conditionText) : "";
      const view = element.ownerDocument.defaultView ?? window;
      if (condition && !view.matchMedia(condition).matches) continue;
      if (rulesAuthorProperty(nestedRules, element, property)) return true;
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
      return original.localName === "button" ? "inline-block" : "block";
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
  if (root.nodeType === Node.ELEMENT_NODE && isSvgElement(root as Element) && (root as Element).localName === "svg") {
    svgs.unshift(root as SVGSVGElement);
  }
  for (const svg of svgs) {
    if (!svg.isConnected && !svg.parentNode && svg !== root) continue;
    try {
      if (!svg.hasAttribute("xmlns")) svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
      const source = new XMLSerializer().serializeToString(svg);
      const replacement = svg.ownerDocument.createElement("img");
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

function materializeLiveState(original: Element, target: Element): Element {
  if (original.localName === "input" && target.localName === "input") {
    const input = original as HTMLInputElement;
    const text = input.type === "checkbox" || input.type === "radio"
      ? input.checked ? "☑" : "☐"
      : input.type === "password" ? "•".repeat(input.value.length) : input.value;
    return replaceFormControl(target, text);
  } else if (original.localName === "textarea" && target.localName === "textarea") {
    return replaceFormControl(target, (original as HTMLTextAreaElement).value, true);
  } else if (original.localName === "select" && target.localName === "select") {
    return replaceFormControl(target, [...(original as HTMLSelectElement).selectedOptions].map((option) => option.text).join(", "));
  } else if (original.localName === "button" && target.localName === "button") {
    return replaceFormControl(target, (original as HTMLElement).innerText);
  } else if (original.localName === "progress" && target.localName === "progress") {
    return replaceFormControl(target, `${Math.round((original as HTMLProgressElement).position * 100)}%`);
  } else if (original.localName === "meter" && target.localName === "meter") {
    return replaceFormControl(target, String((original as HTMLMeterElement).value));
  } else if (original.localName === "details" && target.localName === "details" && !(original as HTMLDetailsElement).open) {
    for (const child of [...target.children]) {
      if (child.localName !== "summary") child.remove();
    }
  } else if (original.localName === "img" && target.localName === "img") {
    const source = original as HTMLImageElement;
    if (source.currentSrc) (target as HTMLImageElement).src = source.currentSrc;
  } else if (original.localName === "canvas" && target.localName === "canvas") {
    const canvas = original as HTMLCanvasElement;
    const replacement = target.ownerDocument.createElement("img");
    for (const attribute of target.attributes) replacement.setAttribute(attribute.name, attribute.value);
    replacement.src = canvasToPng(canvas);
    replacement.width = canvas.width;
    replacement.height = canvas.height;
    target.replaceWith(replacement);
    return replacement;
  }
  return target;
}

function replaceFormControl(target: Element, text: string, preserveWhitespace = false): HTMLElement {
  const replacement = target.ownerDocument.createElement("span");
  for (const attribute of target.attributes) replacement.setAttribute(attribute.name, attribute.value);
  if (!replacement.style.display) replacement.style.display = "inline-block";
  if (preserveWhitespace) replacement.style.whiteSpace = "pre-wrap";
  replacement.textContent = text;
  target.replaceWith(replacement);
  return replacement;
}

async function materializeImages(
  root: ParentNode,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): Promise<void> {
  const images = [...root.querySelectorAll("img")];
  for (const image of images) {
    const source = (image as HTMLImageElement).currentSrc || image.getAttribute("src") || "";
    if (!source || source.startsWith("data:image/jpeg") || source.startsWith("data:image/jpg") || source.startsWith("data:image/png")) continue;

    try {
      const url = new URL(source, options.baseUrl ?? document.baseURI);
      const resolved = await options.resourceResolver?.({ kind: "image", url });
      if (typeof resolved === "string" && /^data:image\/(?:jpeg|jpg|png);/i.test(resolved)) {
        (image as HTMLImageElement).src = resolved;
        continue;
      }
      const blob = resolved instanceof Blob ? resolved : await fetchImageBlob(
        typeof resolved === "string" ? new URL(resolved, url) : url,
      );
      (image as HTMLImageElement).src = blob.type === "image/jpeg" ? await blobToDataUrl(blob) : await rasterizeBlobToPng(blob);
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
  const policy = options.unsupportedCss ?? (options.strict || options.cssProfile === "strict" ? "error" : "warn");
  if (policy === "error") throw new UnsupportedCssError(`${property} is outside the ${options.cssProfile ?? "document"} CSS profile`);
  if (policy === "ignore") return;
  if (diagnostics.some((diagnostic) => diagnostic.code === "UNSUPPORTED_CSS_PROPERTY" && diagnostic.message.includes(property))) return;
  diagnostics.push({
    code: "UNSUPPORTED_CSS_PROPERTY",
    severity: "warning",
    message: `Unsupported CSS property was omitted: ${property}`,
    property,
    phase: "snapshot",
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

function isSvgElement(element: Element): boolean {
  return element.namespaceURI === "http://www.w3.org/2000/svg";
}
