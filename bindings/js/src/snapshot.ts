import { InvalidSourceError, ResourceLoadError, UnsupportedCssError, UnsupportedEnvironmentError } from "./errors.js";
import type { CssProfile, Diagnostic, FallbackPolicy, HtmlSource, MediaType, ResourceResolver, UnsupportedCssPolicy, ViewportOptions } from "./types.js";
import type { NormalizedPage } from "./page.js";

export interface SnapshotOptions {
  baseUrl?: string | URL;
  resourcePolicy: "error" | "omit";
  resourceResolver?: ResourceResolver;
  strict?: boolean;
  cssProfile?: CssProfile;
  mediaType?: MediaType;
  viewport?: ViewportOptions;
  unsupportedCss?: UnsupportedCssPolicy;
  fallback?: FallbackPolicy;
  includeShadowDom?: boolean;
  enableLinks?: boolean;
}

export interface SnapshotResult {
  html: string;
  diagnostics: Diagnostic[];
  page?: NormalizedPage;
  pageMarginBoxes?: readonly SnapshotPageMarginBox[];
}

export type SnapshotPageMarginBoxName =
  | "top_left_corner" | "top_left" | "top_center" | "top_right" | "top_right_corner"
  | "right_top" | "right_middle" | "right_bottom"
  | "bottom_right_corner" | "bottom_right" | "bottom_center" | "bottom_left" | "bottom_left_corner"
  | "left_bottom" | "left_middle" | "left_top";

export interface SnapshotPageMarginBox {
  name: SnapshotPageMarginBoxName;
  content: string;
  fontFamily: string;
  fontSize: number;
  fontWeight: "normal" | "bold";
  fontStyle: "normal" | "italic";
  color: string;
  textAlign?: "start" | "end" | "left" | "center" | "right" | "justify";
}

const SUPPORTED_COMPUTED_PROPERTIES = [
  "display",
  "position",
  "top",
  "right",
  "bottom",
  "left",
  "z-index",
  "opacity",
  "transform",
  "transform-origin",
  "float",
  "clear",
  "flex-direction",
  "flex-wrap",
  "flex-grow",
  "flex-shrink",
  "flex-basis",
  "order",
  "row-gap",
  "column-gap",
  "justify-content",
  "align-items",
  "align-self",
  "align-content",
  "justify-items",
  "justify-self",
  "grid-template-columns",
  "grid-template-rows",
  "grid-template-areas",
  "grid-auto-columns",
  "grid-auto-rows",
  "grid-auto-flow",
  "grid-column-start",
  "grid-column-end",
  "grid-row-start",
  "grid-row-end",
  "width",
  "height",
  "min-width",
  "max-width",
  "min-height",
  "max-height",
  "aspect-ratio",
  "object-fit",
  "object-position",
  "box-sizing",
  "box-decoration-break",
  "list-style-type",
  "list-style-position",
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
  "caption-side",
  "border-top-left-radius",
  "border-top-right-radius",
  "border-bottom-right-radius",
  "border-bottom-left-radius",
  "background-color",
  "background-image",
  "background-position",
  "background-size",
  "background-repeat",
  "box-shadow",
  "color",
  "direction",
  "font-family",
  "font-size",
  "font-style",
  "font-weight",
  "line-height",
  "letter-spacing",
  "word-spacing",
  "text-indent",
  "text-align",
  "text-transform",
  "word-break",
  "overflow-wrap",
  "overflow",
  "text-overflow",
  "text-shadow",
  "vertical-align",
  "text-decoration-line",
  "text-decoration-style",
  "text-decoration-color",
  "text-decoration-thickness",
  "white-space",
  "break-before",
  "break-after",
  "break-inside",
] as const;

const SVG_COMPUTED_PROPERTIES = [
  "clip-path",
  "filter",
  "fill",
  "fill-opacity",
  "fill-rule",
  "marker-end",
  "marker-mid",
  "marker-start",
  "mask-image",
  "mix-blend-mode",
  "paint-order",
  "stroke",
  "stroke-dasharray",
  "stroke-dashoffset",
  "stroke-linecap",
  "stroke-linejoin",
  "stroke-miterlimit",
  "stroke-opacity",
  "stroke-width",
  "vector-effect",
  "visibility",
] as const;

const SUPPORTED_DISPLAY = new Set([
  "none",
  "block",
  "list-item",
  "inline",
  "inline-block",
  "flex",
  "inline-flex",
  "grid",
  "inline-grid",
  "table",
  "table-row-group",
  "table-header-group",
  "table-footer-group",
  "table-row",
  "table-cell",
  "table-caption",
  "table-column",
  "table-column-group",
]);

const ACTIVE_ELEMENTS = "script,iframe,object,embed";
const VECTOR_SVG_ELEMENTS = new Set(["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "title", "desc"]);
const VECTOR_SVG_UNSUPPORTED_PROPERTIES = [
  "filter",
  "mix-blend-mode",
  "clip-path",
  "mask",
  "mask-image",
  "marker-start",
  "marker-mid",
  "marker-end",
  "vector-effect",
  "paint-order",
] as const;
const SUPPORTED_CSS_PROPERTIES = new Set<string>([
  ...SUPPORTED_COMPUTED_PROPERTIES,
  "margin", "padding", "border", "border-top", "border-right", "border-bottom", "border-left", "border-radius",
  "border-width", "border-style", "border-color", "background", "page-break-before", "page-break-after",
  "page-break-inside", "list-style", "flex", "flex-flow", "gap", "inset", "inset-block", "inset-inline",
  "inset-block-start", "inset-block-end", "inset-inline-start", "inset-inline-end", "orphans", "widows",
  "grid", "grid-template", "grid-column", "grid-row", "grid-area",
  "place-content", "place-items", "place-self",
]);

export async function snapshotSource(source: HtmlSource, options: SnapshotOptions): Promise<SnapshotResult> {
  if (typeof window === "undefined" || typeof Element === "undefined") throw new UnsupportedEnvironmentError();
  if (typeof source === "string") return snapshotHtmlString(source, options);

  const element = isRefLike(source) ? source.current : source;
  if (!element) throw new InvalidSourceError("The supplied ref is null; render after the element has mounted");
  if (!(element instanceof Element)) throw new InvalidSourceError("Expected an HTML string, Element, or ref-like object");
  if (options.viewport !== undefined || options.mediaType === "print") return snapshotElementInEnvironment(element, options);

  const { clone, diagnostics, page, pageMarginBoxes } = await snapshotElement(element, options);
  return { html: clone.outerHTML, diagnostics, ...(page ? { page } : {}), ...(pageMarginBoxes ? { pageMarginBoxes } : {}) };
}

async function snapshotElementInEnvironment(element: Element, options: SnapshotOptions): Promise<SnapshotResult> {
  const viewport = options.viewport ?? { width: window.innerWidth || 1280, height: window.innerHeight || 720 };
  const iframe = createSnapshotFrame(viewport);
  const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:";
  iframe.srcdoc = `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${csp}"></head><body></body></html>`;
  document.body.append(iframe);

  try {
    await waitForSnapshotFrame(iframe);
    const targetDocument = iframe.contentDocument;
    if (!targetDocument) throw new InvalidSourceError("The isolated element snapshot document is unavailable");
    copySafeAttributes(element.ownerDocument.documentElement, targetDocument.documentElement);
    if (element.ownerDocument.body) copySafeAttributes(element.ownerDocument.body, targetDocument.body);
    const base = targetDocument.createElement("base");
    base.href = options.baseUrl?.toString() ?? element.ownerDocument.baseURI;
    targetDocument.head.append(base);
    const stylesheet = targetDocument.createElement("style");
    stylesheet.textContent = serializeAccessibleStylesheets(element.ownerDocument);
    targetDocument.head.append(stylesheet);

    const target = cloneEnvironmentNode(element, targetDocument) as Element;
    let mounted: Element = target;
    for (let ancestor = element.parentElement; ancestor && ancestor.localName !== "body" && ancestor.localName !== "html"; ancestor = ancestor.parentElement) {
      const wrapper = targetDocument.importNode(ancestor.cloneNode(false), false) as Element;
      removeEventHandlers(wrapper);
      wrapper.append(mounted);
      mounted = wrapper;
    }
    targetDocument.body.append(mounted);
    freezeDynamicStyles(targetDocument);
    await waitForStyleResolution(targetDocument.defaultView);
    forceRequestedMedia(targetDocument, options.mediaType ?? "screen", viewport);
    forceShadowMediaRules(target, options.mediaType ?? "screen", viewport);
    const snapshot = await snapshotElement(target, options);
    return {
      html: snapshot.clone.outerHTML,
      diagnostics: snapshot.diagnostics,
      ...(snapshot.page ? { page: snapshot.page } : {}),
      ...(snapshot.pageMarginBoxes ? { pageMarginBoxes: snapshot.pageMarginBoxes } : {}),
    };
  } finally {
    iframe.remove();
  }
}

function createSnapshotFrame(viewport: ViewportOptions): HTMLIFrameElement {
  const iframe = document.createElement("iframe");
  const viewportWidth = Math.max(viewport.width, 1);
  const viewportHeight = Math.max(viewport.height, 1);
  iframe.width = String(viewportWidth);
  iframe.height = String(viewportHeight);
  iframe.style.cssText = `position:fixed;left:-100000px;top:0;width:${viewportWidth}px;height:${viewportHeight}px;min-width:${viewportWidth}px;max-width:${viewportWidth}px;min-height:${viewportHeight}px;max-height:${viewportHeight}px;border:0;visibility:hidden`;
  return iframe;
}

function waitForSnapshotFrame(iframe: HTMLIFrameElement): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    iframe.addEventListener("load", () => resolve(), { once: true });
    iframe.addEventListener("error", () => reject(new InvalidSourceError("Could not create the inert HTML snapshot document")), { once: true });
  });
}

function waitForStyleResolution(view: Window | null): Promise<void> {
  if (!view) return Promise.resolve();
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    view.requestAnimationFrame(finish);
    window.setTimeout(finish, 50);
  });
}

type CascadedPageValue = { value: string; important: boolean };
type PageCascade = Partial<Record<"size" | "margin-top" | "margin-right" | "margin-bottom" | "margin-left", CascadedPageValue>>;
type MarginBoxProperty = "content" | "font-family" | "font-size" | "font-weight" | "font-style" | "color" | "text-align";
type MarginBoxCascade = Partial<Record<MarginBoxProperty, CascadedPageValue>>;

interface PageStyleResult {
  page?: NormalizedPage;
  marginBoxes: SnapshotPageMarginBox[];
}

const CSS_PAGE_RULE = 6;
const CSS_STYLE_RULE = 1;
const CSS_MEDIA_RULE = 4;
const CSS_SUPPORTS_RULE = 12;
const DEFAULT_PAGE_SIZE_POINTS = [595.2756, 841.8898] as const;
const CSS_PAGE_SIZES_POINTS: Record<string, readonly [number, number]> = {
  a3: [841.8898, 1190.5512],
  a4: DEFAULT_PAGE_SIZE_POINTS,
  a5: [419.5276, 595.2756],
  letter: [612, 792],
  legal: [612, 1008],
  ledger: [1224, 792],
  tabloid: [792, 1224],
};
const PAGE_MARGIN_BOX_NAMES = new Map<string, SnapshotPageMarginBoxName>([
  ["top-left-corner", "top_left_corner"], ["top-left", "top_left"], ["top-center", "top_center"],
  ["top-right", "top_right"], ["top-right-corner", "top_right_corner"], ["right-top", "right_top"],
  ["right-middle", "right_middle"], ["right-bottom", "right_bottom"],
  ["bottom-right-corner", "bottom_right_corner"], ["bottom-right", "bottom_right"],
  ["bottom-center", "bottom_center"], ["bottom-left", "bottom_left"],
  ["bottom-left-corner", "bottom_left_corner"], ["left-bottom", "left_bottom"],
  ["left-middle", "left_middle"], ["left-top", "left_top"],
]);

function readDefaultPageStyle(document: Document, options: SnapshotOptions, diagnostics: Diagnostic[]): PageStyleResult {
  const cascade: PageCascade = {};
  const marginCascades = new Map<SnapshotPageMarginBoxName, MarginBoxCascade>();
  let found = false;
  const view = document.defaultView ?? window;
  const stylesheets = [...document.styleSheets, ...(document.adoptedStyleSheets ?? [])];
  for (const stylesheet of stylesheets) {
    try {
      found = collectDefaultPageRules(stylesheet.cssRules, view, document, cascade, marginCascades, options, diagnostics) || found;
    } catch (error) {
      if (error instanceof UnsupportedCssError) throw error;
      // Cross-origin stylesheets cannot expose cssRules. Their normal computed
      // declarations remain usable, but paged-media metadata is unavailable.
    }
  }
  if (marginCascades.size === 0) {
    for (const style of document.querySelectorAll("style")) {
      collectAuthoredPageMarginRules(style.textContent ?? "", document, view, marginCascades, options, diagnostics);
    }
  }
  const marginBoxes = materializePageMarginBoxes(marginCascades, options, diagnostics);
  if (!found) return { marginBoxes };

  const size = parseCssPageSize(cascade.size?.value ?? "auto");
  if (!size) {
    reportUnsupportedPageValue("size", cascade.size?.value ?? "", options, diagnostics);
    return { marginBoxes };
  }
  const margins = ["margin-top", "margin-right", "margin-bottom", "margin-left"].map((property) => {
    const raw = cascade[property as keyof PageCascade]?.value ?? "0";
    const value = parseCssPageLength(raw, true);
    if (value === null) reportUnsupportedPageValue(property, raw, options, diagnostics);
    return value ?? 0;
  }) as [number, number, number, number];
  if (margins[0] + margins[2] >= size[1] || margins[1] + margins[3] >= size[0]) {
    reportUnsupportedPageValue("margin", "page margins leave no content area", options, diagnostics);
    return { marginBoxes };
  }
  return {
    page: {
      widthPoints: size[0],
      heightPoints: size[1],
      marginTopPoints: margins[0],
      marginRightPoints: margins[1],
      marginBottomPoints: margins[2],
      marginLeftPoints: margins[3],
    },
    marginBoxes,
  };
}

function collectDefaultPageRules(
  rules: CSSRuleList,
  view: Window,
  document: Document,
  cascade: PageCascade,
  marginCascades: Map<SnapshotPageMarginBoxName, MarginBoxCascade>,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): boolean {
  let found = false;
  for (const rule of [...rules]) {
    if (rule.type === CSS_PAGE_RULE && "style" in rule) {
      const pageRule = rule as CSSPageRule;
      const selector = pageRule.selectorText.trim();
      if (selector) {
        reportUnsupportedPageValue("@page selector", selector, options, diagnostics);
        continue;
      }
      found = true;
      const pageStyle = pageRule.style as unknown as CSSStyleDeclaration;
      cascadePageDeclaration(cascade, pageStyle, "size");
      cascadePageDeclaration(cascade, pageStyle, "margin-top");
      cascadePageDeclaration(cascade, pageStyle, "margin-right");
      cascadePageDeclaration(cascade, pageStyle, "margin-bottom");
      cascadePageDeclaration(cascade, pageStyle, "margin-left");
      collectPageMarginRules(pageRule.cssText, document, marginCascades, options, diagnostics);
      continue;
    }
    if (!("cssRules" in rule) || !(rule as CSSGroupingRule).cssRules) continue;
    if (rule.type === CSS_MEDIA_RULE && "conditionText" in rule && !view.matchMedia(String(rule.conditionText)).matches) continue;
    if (rule.type === CSS_SUPPORTS_RULE && "conditionText" in rule && !CSS.supports(String(rule.conditionText))) continue;
    found = collectDefaultPageRules((rule as CSSGroupingRule).cssRules, view, document, cascade, marginCascades, options, diagnostics) || found;
  }
  return found;
}

function cascadePageDeclaration(cascade: PageCascade, style: CSSStyleDeclaration, property: keyof PageCascade): void {
  const value = style.getPropertyValue(property).trim();
  if (!value) return;
  const important = style.getPropertyPriority(property) === "important";
  const previous = cascade[property];
  if (previous?.important && !important) return;
  cascade[property] = { value, important };
}

function collectPageMarginRules(
  cssText: string,
  document: Document,
  cascades: Map<SnapshotPageMarginBoxName, MarginBoxCascade>,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): void {
  const outerOpen = cssText.indexOf("{");
  if (outerOpen < 0) return;
  const outerClose = matchingCssBrace(cssText, outerOpen);
  if (outerClose < 0) return;
  const body = cssText.slice(outerOpen + 1, outerClose);
  let cursor = 0;
  while (cursor < body.length) {
    const at = nextCssAtRule(body, cursor);
    if (at < 0) break;
    const match = body.slice(at + 1).match(/^([\w-]+)/);
    if (!match) {
      cursor = at + 1;
      continue;
    }
    const rawName = match[1]!.toLowerCase();
    let open = at + 1 + match[0].length;
    while (/\s/.test(body[open] ?? "")) open += 1;
    if (body[open] !== "{") {
      cursor = open + 1;
      continue;
    }
    const close = matchingCssBrace(body, open);
    if (close < 0) break;
    const name = PAGE_MARGIN_BOX_NAMES.get(rawName);
    if (!name) {
      reportUnsupportedPageValue("@page margin box", `@${rawName}`, options, diagnostics);
      cursor = close + 1;
      continue;
    }
    const style = document.createElement("div").style;
    style.cssText = body.slice(open + 1, close);
    const cascade = cascades.get(name) ?? {};
    for (const property of ["content", "font-family", "font-size", "font-weight", "font-style", "color", "text-align"] as const) {
      cascadeMarginDeclaration(cascade, style, property);
    }
    cascades.set(name, cascade);
    cursor = close + 1;
  }
}

function collectAuthoredPageMarginRules(
  cssText: string,
  document: Document,
  view: Window,
  cascades: Map<SnapshotPageMarginBoxName, MarginBoxCascade>,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): void {
  let cursor = 0;
  while (cursor < cssText.length) {
    const at = nextCssAtRule(cssText, cursor);
    if (at < 0) break;
    const nameMatch = cssText.slice(at + 1).match(/^([\w-]+)/);
    if (!nameMatch) {
      cursor = at + 1;
      continue;
    }
    let open = at + 1 + nameMatch[0].length;
    while (open < cssText.length && cssText[open] !== "{" && cssText[open] !== ";") open += 1;
    if (cssText[open] !== "{") {
      cursor = open + 1;
      continue;
    }
    const close = matchingCssBrace(cssText, open);
    if (close < 0) break;
    const atRuleName = nameMatch[1]!.toLowerCase();
    const prelude = cssText.slice(at + 1 + nameMatch[0].length, open).trim();
    const nested = cssText.slice(open + 1, close);
    if (atRuleName === "page") {
      if (!prelude) {
        collectPageMarginRules(`@page {${nested}}`, document, cascades, options, diagnostics);
      }
    } else if (atRuleName === "media") {
      const viewport = options.viewport ?? { width: 1280, height: 720 };
      if (matchesRequestedMedia(prelude, options.mediaType ?? "screen", viewport, view)) {
        collectAuthoredPageMarginRules(nested, document, view, cascades, options, diagnostics);
      }
    } else if (atRuleName === "supports") {
      if (CSS.supports(prelude)) collectAuthoredPageMarginRules(nested, document, view, cascades, options, diagnostics);
    } else if (atRuleName === "layer") {
      collectAuthoredPageMarginRules(nested, document, view, cascades, options, diagnostics);
    }
    // Unknown grouping conditions stay opaque: applying a raw @page from an
    // inactive container/scope would be worse than omission.
    cursor = close + 1;
  }
}

function cascadeMarginDeclaration(cascade: MarginBoxCascade, style: CSSStyleDeclaration, property: MarginBoxProperty): void {
  const value = style.getPropertyValue(property).trim();
  if (!value) return;
  const important = style.getPropertyPriority(property) === "important";
  const previous = cascade[property];
  if (previous?.important && !important) return;
  cascade[property] = { value, important };
}

function materializePageMarginBoxes(
  cascades: Map<SnapshotPageMarginBoxName, MarginBoxCascade>,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): SnapshotPageMarginBox[] {
  const result: SnapshotPageMarginBox[] = [];
  for (const [name, cascade] of cascades) {
    const rawContent = cascade.content?.value ?? "normal";
    const content = parsePageMarginContent(rawContent);
    if (content === null) {
      reportUnsupportedPageValue(`@${name.replaceAll("_", "-")} content`, rawContent, options, diagnostics);
      continue;
    }
    if (!content) continue;
    const rawSize = cascade["font-size"]?.value ?? "12px";
    const fontSizePoints = parseCssPageLength(rawSize, false);
    if (fontSizePoints === null) {
      reportUnsupportedPageValue(`@${name.replaceAll("_", "-")} font-size`, rawSize, options, diagnostics);
      continue;
    }
    const rawWeight = (cascade["font-weight"]?.value ?? "normal").toLowerCase();
    const numericWeight = Number.parseInt(rawWeight, 10);
    const fontWeight: "normal" | "bold" = rawWeight === "bold" || rawWeight === "bolder" || (Number.isFinite(numericWeight) && numericWeight >= 600)
      ? "bold"
      : "normal";
    const rawStyle = (cascade["font-style"]?.value ?? "normal").toLowerCase();
    const fontStyle: "normal" | "italic" = rawStyle === "italic" || rawStyle.startsWith("oblique") ? "italic" : "normal";
    const rawAlign = (cascade["text-align"]?.value ?? "").toLowerCase();
    const textAlign = ["start", "end", "left", "center", "right", "justify"].includes(rawAlign)
      ? rawAlign as SnapshotPageMarginBox["textAlign"]
      : undefined;
    result.push({
      name,
      content,
      fontFamily: cascade["font-family"]?.value ?? "Noto Sans",
      fontSize: fontSizePoints / 0.75,
      fontWeight,
      fontStyle,
      color: cascade.color?.value ?? "black",
      ...(textAlign ? { textAlign } : {}),
    });
  }
  return result;
}

function parsePageMarginContent(raw: string): string | null {
  const input = raw.trim();
  if (!input || input === "normal" || input === "none") return "";
  let output = "";
  let cursor = 0;
  while (cursor < input.length) {
    while (/\s/.test(input[cursor] ?? "")) cursor += 1;
    if (cursor >= input.length) break;
    const character = input[cursor]!;
    if (character === '"' || character === "'") {
      const parsed = parseCssStringToken(input, cursor);
      if (!parsed) return null;
      output += parsed.value;
      cursor = parsed.end;
      continue;
    }
    const counter = input.slice(cursor).match(/^counter\(\s*(page|pages)\s*(?:,\s*([\w-]+)\s*)?\)/i);
    if (!counter) return null;
    if (counter[2] && counter[2].toLowerCase() !== "decimal") return null;
    output += counter[1]!.toLowerCase() === "pages" ? "{{pages}}" : "{{page}}";
    cursor += counter[0].length;
  }
  return output;
}

function parseCssStringToken(input: string, start: number): { value: string; end: number } | null {
  const quote = input[start]!;
  let value = "";
  let cursor = start + 1;
  while (cursor < input.length) {
    const character = input[cursor]!;
    if (character === quote) return { value, end: cursor + 1 };
    if (character !== "\\") {
      value += character;
      cursor += 1;
      continue;
    }
    cursor += 1;
    if (cursor >= input.length) return null;
    if (input[cursor] === "\n" || input[cursor] === "\f") {
      cursor += 1;
      continue;
    }
    if (input[cursor] === "\r") {
      cursor += input[cursor + 1] === "\n" ? 2 : 1;
      continue;
    }
    const hex = input.slice(cursor).match(/^[0-9a-fA-F]{1,6}/)?.[0];
    if (hex) {
      const codepoint = Number.parseInt(hex, 16);
      value += String.fromCodePoint(codepoint === 0 || codepoint > 0x10FFFF ? 0xFFFD : codepoint);
      cursor += hex.length;
      if (/\s/.test(input[cursor] ?? "")) cursor += 1;
      continue;
    }
    value += input[cursor]!;
    cursor += 1;
  }
  return null;
}

function nextCssAtRule(input: string, start: number): number {
  let quote = "";
  let comment = false;
  for (let index = start; index < input.length; index += 1) {
    const character = input[index]!;
    if (comment) {
      if (character === "*" && input[index + 1] === "/") {
        comment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (character === "\\") index += 1;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === "/" && input[index + 1] === "*") {
      comment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "@") return index;
  }
  return -1;
}

function matchingCssBrace(input: string, open: number): number {
  let depth = 0;
  let quote = "";
  let comment = false;
  for (let index = open; index < input.length; index += 1) {
    const character = input[index]!;
    if (comment) {
      if (character === "*" && input[index + 1] === "/") {
        comment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (character === "\\") index += 1;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === "/" && input[index + 1] === "*") {
      comment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}" && --depth === 0) return index;
  }
  return -1;
}

function parseCssPageSize(raw: string): [number, number] | null {
  const tokens = raw.trim().toLowerCase().split(/\s+/).filter(Boolean);
  let orientation: "auto" | "portrait" | "landscape" = "auto";
  const dimensions: string[] = [];
  for (const token of tokens) {
    if (token === "portrait" || token === "landscape") {
      orientation = token;
      continue;
    }
    if (token !== "auto") dimensions.push(token);
  }
  let size: [number, number];
  if (dimensions.length === 0) {
    size = [...DEFAULT_PAGE_SIZE_POINTS];
  } else if (dimensions.length === 1 && CSS_PAGE_SIZES_POINTS[dimensions[0]!]) {
    size = [...CSS_PAGE_SIZES_POINTS[dimensions[0]!]!];
  } else if (dimensions.length === 1) {
    const edge = parseCssPageLength(dimensions[0]!, false);
    if (edge === null || edge <= 0) return null;
    size = [edge, edge];
  } else if (dimensions.length === 2) {
    const width = parseCssPageLength(dimensions[0]!, false);
    const height = parseCssPageLength(dimensions[1]!, false);
    if (width === null || height === null || width <= 0 || height <= 0) return null;
    size = [width, height];
  } else {
    return null;
  }
  if (orientation === "landscape" && size[0] < size[1]) [size[0], size[1]] = [size[1], size[0]];
  if (orientation === "portrait" && size[0] > size[1]) [size[0], size[1]] = [size[1], size[0]];
  return size;
}

function parseCssPageLength(raw: string, allowNegative: boolean): number | null {
  const value = raw.trim().toLowerCase();
  if (value === "auto" || value === "0") return 0;
  const match = value.match(/^([+-]?(?:\d+\.?\d*|\.\d+))(px|pt|pc|in|cm|mm|q)$/);
  if (!match) return null;
  const number = Number.parseFloat(match[1]!);
  if (!Number.isFinite(number) || (!allowNegative && number <= 0)) return null;
  const scale = {
    px: 0.75,
    pt: 1,
    pc: 12,
    in: 72,
    cm: 72 / 2.54,
    mm: 72 / 25.4,
    q: 72 / 101.6,
  }[match[2]!]!;
  return number * scale;
}

function reportUnsupportedPageValue(property: string, value: string, options: SnapshotOptions, diagnostics: Diagnostic[]): void {
  const policy = options.unsupportedCss ?? (options.strict || options.cssProfile === "strict" ? "error" : "warn");
  if (policy === "error") throw new UnsupportedCssError(`${property}:${value} is outside the supported paged-media profile`);
  if (policy === "ignore") return;
  if (diagnostics.some((diagnostic) => diagnostic.code === "UNSUPPORTED_PAGED_MEDIA" && diagnostic.property === property)) return;
  diagnostics.push({
    code: "UNSUPPORTED_PAGED_MEDIA",
    severity: "warning",
    message: `Unsupported paged-media value was ignored: ${property}: ${value}`,
    property,
    phase: "fragmentation",
  });
}

function freezeDynamicStyles(document: Document): void {
  const style = document.createElement("style");
  style.dataset.html2realpdfFreeze = "";
  style.textContent = "*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important}";
  document.documentElement.append(style);
}

function copySafeAttributes(source: Element, target: Element): void {
  for (const attribute of [...target.attributes]) target.removeAttribute(attribute.name);
  for (const attribute of source.attributes) {
    if (!attribute.name.toLowerCase().startsWith("on")) target.setAttribute(attribute.name, attribute.value);
  }
}

function serializeAccessibleStylesheets(source: Document): string {
  const output: string[] = [];
  const sheets = [...source.styleSheets, ...(source.adoptedStyleSheets ?? [])];
  for (const sheet of sheets) {
    try {
      output.push([...sheet.cssRules].map((rule) => rule.cssText).join("\n"));
    } catch {
      // Cross-origin stylesheets cannot expose CSSOM. Callers that need a
      // deterministic alternate environment should provide those resources
      // through an HTML-string snapshot and resourceResolver.
    }
  }
  return output.join("\n");
}

function cloneEnvironmentNode(source: Node, targetDocument: Document): Node {
  if (source.nodeType === Node.TEXT_NODE) return targetDocument.createTextNode(source.textContent ?? "");
  if (source.nodeType !== Node.ELEMENT_NODE) return targetDocument.createDocumentFragment();
  const original = source as Element;
  const clone = targetDocument.importNode(original.cloneNode(false), false) as Element;
  removeEventHandlers(clone);

  for (const child of original.childNodes) clone.append(cloneEnvironmentNode(child, targetDocument));
  if (original.shadowRoot && "attachShadow" in clone) {
    const shadow = (clone as HTMLElement).attachShadow({ mode: "open" });
    for (const child of original.shadowRoot.childNodes) shadow.append(cloneEnvironmentNode(child, targetDocument));
  }
  synchronizeEnvironmentState(original, clone);
  return clone;
}

function synchronizeEnvironmentState(original: Element, clone: Element): void {
  if (original.localName === "input") {
    (clone as HTMLInputElement).value = (original as HTMLInputElement).value;
    (clone as HTMLInputElement).checked = (original as HTMLInputElement).checked;
  } else if (original.localName === "textarea") {
    (clone as HTMLTextAreaElement).value = (original as HTMLTextAreaElement).value;
  } else if (original.localName === "select") {
    (clone as HTMLSelectElement).selectedIndex = (original as HTMLSelectElement).selectedIndex;
  } else if (original.localName === "details") {
    (clone as HTMLDetailsElement).open = (original as HTMLDetailsElement).open;
  } else if (original.localName === "canvas") {
    const sourceCanvas = original as HTMLCanvasElement;
    const targetCanvas = clone as HTMLCanvasElement;
    targetCanvas.width = sourceCanvas.width;
    targetCanvas.height = sourceCanvas.height;
    targetCanvas.getContext("2d")?.drawImage(sourceCanvas, 0, 0);
  } else if (original.localName === "img" && (original as HTMLImageElement).currentSrc) {
    (clone as HTMLImageElement).src = (original as HTMLImageElement).currentSrc;
  }
}

async function snapshotElement(element: Element, options: SnapshotOptions): Promise<{
  clone: Element;
  diagnostics: Diagnostic[];
  page?: NormalizedPage;
  pageMarginBoxes?: readonly SnapshotPageMarginBox[];
}> {
  const diagnostics: Diagnostic[] = [];
  const counters = CounterState.forSnapshotRoot(element, options.includeShadowDom === true);
  const clone = cloneSnapshotElement(element, options, diagnostics, true, counters);

  for (const active of clone.matches(ACTIVE_ELEMENTS) ? [clone] : clone.querySelectorAll(ACTIVE_ELEMENTS)) {
    active.remove();
  }
  if (options.enableLinks === false) for (const anchor of clone.querySelectorAll("a[href]")) anchor.removeAttribute("href");

  await materializeInlineSvgs(clone, options, diagnostics);
  inspectAuthoredCss(clone, options, diagnostics);
  await materializeBackgroundImages(clone, options, diagnostics);
  await materializeImages(clone, options, diagnostics);
  const pageStyle = readDefaultPageStyle(element.ownerDocument, options, diagnostics);
  return {
    clone,
    diagnostics,
    ...(pageStyle.page ? { page: pageStyle.page } : {}),
    ...(pageStyle.marginBoxes.length > 0 ? { pageMarginBoxes: pageStyle.marginBoxes } : {}),
  };
}

async function snapshotHtmlString(source: string, options: SnapshotOptions): Promise<SnapshotResult> {
  const template = document.createElement("template");
  template.innerHTML = source;
  const diagnostics: Diagnostic[] = [];
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
  for (const refresh of template.content.querySelectorAll('meta[http-equiv="refresh" i]')) refresh.remove();
  for (const element of template.content.querySelectorAll("*")) removeEventHandlers(element);
  if (options.enableLinks === false) for (const anchor of template.content.querySelectorAll("a[href]")) anchor.removeAttribute("href");
  await materializeExternalStylesheets(template.content, options, diagnostics);

  const viewport = options.viewport ?? { width: 1280, height: 720 };
  const iframe = createSnapshotFrame(viewport);
  const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:";
  iframe.srcdoc = `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${csp}"></head><body>${template.innerHTML}</body></html>`;
  document.body.append(iframe);

  try {
    await waitForSnapshotFrame(iframe);
    const body = iframe.contentDocument?.body;
    if (!body) throw new InvalidSourceError("The inert HTML snapshot document has no body");
    freezeDynamicStyles(body.ownerDocument);
    await waitForStyleResolution(body.ownerDocument.defaultView);
    forceRequestedMedia(body.ownerDocument, options.mediaType ?? "screen", viewport);
    const snapshot = await snapshotElement(body, options);
    return {
      html: snapshot.clone.innerHTML,
      diagnostics: [...diagnostics, ...snapshot.diagnostics],
      ...(snapshot.page ? { page: snapshot.page } : {}),
      ...(snapshot.pageMarginBoxes ? { pageMarginBoxes: snapshot.pageMarginBoxes } : {}),
    };
  } finally {
    iframe.remove();
  }
}

async function materializeExternalStylesheets(
  root: ParentNode,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): Promise<void> {
  for (const link of root.querySelectorAll('link[rel~="stylesheet" i][href]')) {
    const source = link.getAttribute("href") ?? "";
    try {
      const url = new URL(source, options.baseUrl ?? document.baseURI);
      const resolved = await options.resourceResolver?.({ kind: "stylesheet", url });
      if (resolved === null || resolved === undefined) throw new Error("No stylesheet resource was returned by resourceResolver");
      const css = resolved instanceof Blob ? await resolved.text() : resolved;
      const style = link.ownerDocument.createElement("style");
      style.dataset.html2realpdfResolvedFrom = url.href;
      style.textContent = css;
      link.replaceWith(style);
    } catch (error) {
      if (options.resourcePolicy === "error") throw new ResourceLoadError(source, { cause: error });
      link.remove();
      diagnostics.push({
        code: "RESOURCE_OMITTED",
        severity: "warning",
        message: `Stylesheet resource was omitted: ${source}`,
        phase: "snapshot",
      });
    }
  }
}

function cloneSnapshotElement(
  original: Element,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  isSnapshotRoot: boolean,
  counters: CounterState,
): Element {
  const leaveCounterScope = counters.enter(original);
  const target = original.cloneNode(false) as Element;
  try {
    materializeComputedStyle(original, target, options, diagnostics, isSnapshotRoot);
    materializePseudoElement(original, target, "::before", options, diagnostics, counters);

    const childRoot = options.includeShadowDom && original.shadowRoot ? original.shadowRoot : original;
    for (const child of childRoot.childNodes) appendSnapshotNode(target, child, options, diagnostics, counters);

    materializePseudoElement(original, target, "::after", options, diagnostics, counters);
    const materialized = materializeLiveState(original, target);
    removeEventHandlers(materialized);
    if (childRoot !== original) materialized.setAttribute("data-html2realpdf-shadow-host", "open");
    return materialized;
  } finally {
    leaveCounterScope();
  }
}

function appendSnapshotNode(
  parent: Element,
  source: Node,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  counters: CounterState,
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
    for (const node of nodes) appendSnapshotNode(parent, node, options, diagnostics, counters);
    return;
  }
  parent.append(cloneSnapshotElement(element, options, diagnostics, false, counters));
}

function forceRequestedMedia(document: Document, mediaType: MediaType, viewport: ViewportOptions): void {
  const view = document.defaultView ?? window;
  for (const stylesheet of document.styleSheets) {
    try {
      forceMediaRules(stylesheet.cssRules, mediaType, viewport, view);
    } catch {
      // CSP prevents remote stylesheets in inert snapshots. If a browser still
      // exposes a cross-origin sheet, computed styles remain available for the
      // declarations the browser was allowed to load.
    }
  }
}

function forceShadowMediaRules(root: Element, mediaType: MediaType, viewport: ViewportOptions): void {
  const visit = (element: Element): void => {
    const shadow = element.shadowRoot;
    if (shadow) {
      const view = shadow.ownerDocument.defaultView ?? window;
      for (const style of shadow.querySelectorAll("style")) {
        if (style.sheet) forceMediaRules(style.sheet.cssRules, mediaType, viewport, view);
      }
      for (const sheet of shadow.adoptedStyleSheets ?? []) forceMediaRules(sheet.cssRules, mediaType, viewport, view);
      for (const child of shadow.children) visit(child);
    }
    for (const child of element.children) visit(child);
  };
  visit(root);
}

function forceMediaRules(rules: CSSRuleList, mediaType: MediaType, viewport: ViewportOptions, view: Window): void {
  // CSSRuleList is live. Firefox can skip a following @media rule when the
  // current MediaList is mutated during iteration, so walk a stable snapshot.
  for (const rule of [...rules]) {
    if ("media" in rule && "conditionText" in rule) {
      const mediaRule = rule as CSSMediaRule;
      const matches = matchesRequestedMedia(String(mediaRule.conditionText), mediaType, viewport, view);
      mediaRule.media.mediaText = matches ? "all" : "not all";
      if (matches) forceMediaRules(mediaRule.cssRules, mediaType, viewport, view);
      continue;
    }
    if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) {
      forceMediaRules((rule as CSSGroupingRule).cssRules, mediaType, viewport, view);
    }
  }
}

function matchesRequestedMedia(queryList: string, mediaType: MediaType, viewport: ViewportOptions, view: Window): boolean {
  return splitMediaQueries(queryList).some((query) => matchesSingleMediaQuery(query, mediaType, viewport, view));
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

function matchesSingleMediaQuery(input: string, mediaType: MediaType, viewport: ViewportOptions, view: Window): boolean {
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
  if (!typeMatch) return matchesViewportMediaFeatures(input, viewport) ?? view.matchMedia(input).matches;
  const requestedTypeMatches = typeMatch[1] === "all" || typeMatch[1] === mediaType;
  let remainder = query.slice(typeMatch[0].length).trim();
  if (remainder.startsWith("and ")) remainder = remainder.slice(4).trim();
  const featureMatches = !remainder || (matchesViewportMediaFeatures(remainder, viewport) ?? view.matchMedia(remainder).matches);
  const matches = requestedTypeMatches && featureMatches;
  return negate ? !matches : matches;
}

function matchesViewportMediaFeatures(input: string, viewport: ViewportOptions): boolean | null {
  const conditions = input.toLowerCase().split(/\s+and\s+/).map((condition) => condition.trim()).filter(Boolean);
  if (conditions.length === 0) return true;
  for (const condition of conditions) {
    const dimension = condition.match(/^\((min|max)-(width|height)\s*:\s*([+-]?(?:\d+\.?\d*|\.\d+))(px|em|rem)\)$/);
    if (dimension) {
      const factor = dimension[4] === "px" ? 1 : 16;
      const expected = Number.parseFloat(dimension[3] ?? "0") * factor;
      const actual = dimension[2] === "width" ? viewport.width : viewport.height;
      if (dimension[1] === "min" ? actual < expected : actual > expected) return false;
      continue;
    }
    const orientation = condition.match(/^\(orientation\s*:\s*(portrait|landscape)\)$/);
    if (orientation) {
      const actual = viewport.width > viewport.height ? "landscape" : "portrait";
      if (actual !== orientation[1]) return false;
      continue;
    }
    return null;
  }
  return true;
}

function isRefLike(source: Exclude<HtmlSource, string>): source is { readonly current: Element | null } {
  return !(source instanceof Element) && "current" in source;
}

interface CounterOperation {
  name: string;
  value: number;
}

interface CounterInstance {
  name: string;
  creator: CounterNode;
  value: number;
}

interface CounterNode {
  parent: CounterNode | null;
  previousSibling: CounterNode | null;
  counters: CounterInstance[];
}

class CounterState {
  readonly #elements = new Map<Element, CounterNode>();
  readonly #pseudos = new Map<Element, Partial<Record<"::before" | "::after", CounterNode>>>();
  #active: readonly CounterInstance[] = [];
  #lastNode: CounterNode | null = null;

  static forSnapshotRoot(root: Element, includeShadowDom: boolean): CounterState {
    const state = new CounterState();
    const treeRoot = root.ownerDocument.documentElement;
    if (treeRoot?.contains(root)) state.buildElement(treeRoot, null, null, includeShadowDom, false);
    else state.buildElement(root, null, null, includeShadowDom, false);
    return state;
  }

  enter(element: Element): () => void {
    const previous = this.#active;
    this.#active = this.#elements.get(element)?.counters ?? [];
    return () => {
      this.#active = previous;
    };
  }

  enterPseudo(element: Element, pseudo: "::before" | "::after"): () => void {
    const previous = this.#active;
    this.#active = this.#pseudos.get(element)?.[pseudo]?.counters ?? previous;
    return () => {
      this.#active = previous;
    };
  }

  current(name: string): number {
    return findInnermostCounter(this.#active, name)?.value ?? 0;
  }

  values(name: string): readonly number[] {
    const values = this.#active.filter((counter) => counter.name === name).map((counter) => counter.value);
    return values.length ? values : [0];
  }

  private buildElement(
    element: Element,
    parent: CounterNode | null,
    previousSibling: CounterNode | null,
    includeShadowDom: boolean,
    suppressed: boolean,
  ): CounterNode {
    const node = this.createNode(parent, previousSibling);
    this.#elements.set(element, node);
    const view = element.ownerDocument.defaultView ?? window;
    const computed = view.getComputedStyle(element);
    const hidden = suppressed || computed.getPropertyValue("display") === "none";
    if (!hidden) applyCounterProperties(node, computed);
    this.#lastNode = node;

    let childSibling: CounterNode | null = null;
    const before = this.buildPseudo(element, "::before", node, childSibling, hidden);
    if (before) childSibling = before;
    for (const child of counterChildren(element, includeShadowDom)) {
      childSibling = this.buildElement(child, node, childSibling, includeShadowDom, hidden);
    }
    this.buildPseudo(element, "::after", node, childSibling, hidden);
    return node;
  }

  private buildPseudo(
    element: Element,
    pseudo: "::before" | "::after",
    parent: CounterNode,
    previousSibling: CounterNode | null,
    suppressed: boolean,
  ): CounterNode | null {
    if (suppressed || isReplacedOrControl(element)) return null;
    const view = element.ownerDocument.defaultView ?? window;
    const computed = view.getComputedStyle(element, pseudo);
    const content = computed.getPropertyValue("content").trim();
    if (!content || content === "none" || content === "normal" || computed.getPropertyValue("display") === "none") return null;
    const node = this.createNode(parent, previousSibling);
    applyCounterProperties(node, computed);
    const pseudos = this.#pseudos.get(element) ?? {};
    pseudos[pseudo] = node;
    this.#pseudos.set(element, pseudos);
    this.#lastNode = node;
    return node;
  }

  private createNode(parent: CounterNode | null, previousSibling: CounterNode | null): CounterNode {
    const counters = parent ? cloneCounters(parent.counters) : [];
    if (previousSibling) {
      for (const counter of previousSibling.counters) {
        if (!counters.some((candidate) => candidate.name === counter.name)) counters.push({ ...counter });
      }
    }
    if (this.#lastNode) {
      for (const source of this.#lastNode.counters) {
        const target = counters.find((candidate) => candidate.name === source.name && candidate.creator === source.creator);
        if (target) target.value = source.value;
      }
    }
    return { parent, previousSibling, counters };
  }
}

function counterChildren(element: Element, includeShadowDom: boolean): Element[] {
  if (includeShadowDom && element.localName === "slot") {
    const assigned = (element as HTMLSlotElement).assignedElements({ flatten: true });
    return assigned.length ? assigned : [...element.children];
  }
  if (includeShadowDom && element.shadowRoot) return [...element.shadowRoot.children];
  return [...element.children];
}

function cloneCounters(counters: readonly CounterInstance[]): CounterInstance[] {
  return counters.map((counter) => ({ ...counter }));
}

function findInnermostCounter(counters: readonly CounterInstance[], name: string): CounterInstance | undefined {
  for (let index = counters.length - 1; index >= 0; index -= 1) {
    if (counters[index]?.name === name) return counters[index];
  }
  return undefined;
}

function applyCounterProperties(node: CounterNode, computed: CSSStyleDeclaration): void {
  const resets = parseCounterOperations(computed.getPropertyValue("counter-reset"), 0);
  for (let index = 0; index < resets.length; index += 1) {
    const operation = resets[index];
    if (!operation || resets.slice(index + 1).some((candidate) => candidate.name === operation.name)) continue;
    instantiateCounter(node, operation.name, operation.value);
  }
  for (const operation of parseCounterOperations(computed.getPropertyValue("counter-increment"), 1)) {
    const counter = findInnermostCounter(node.counters, operation.name) ?? instantiateCounter(node, operation.name, 0);
    counter.value += operation.value;
  }
  for (const operation of parseCounterOperations(computed.getPropertyValue("counter-set"), 0)) {
    const counter = findInnermostCounter(node.counters, operation.name) ?? instantiateCounter(node, operation.name, 0);
    counter.value = operation.value;
  }
}

function instantiateCounter(node: CounterNode, name: string, value: number): CounterInstance {
  const innermost = findInnermostCounter(node.counters, name);
  if (innermost && (innermost.creator === node || innermost.creator.parent === node.parent)) {
    node.counters.splice(node.counters.indexOf(innermost), 1);
  }
  const counter = { name, creator: node, value };
  node.counters.push(counter);
  return counter;
}

function parseCounterOperations(value: string, defaultValue: number): CounterOperation[] {
  const normalized = value.trim();
  if (!normalized || normalized === "none") return [];
  const tokens = normalized.split(/\s+/);
  const operations: CounterOperation[] = [];
  for (let index = 0; index < tokens.length;) {
    const name = tokens[index++];
    if (!name || name.startsWith("reversed(") || name === "none") return [];
    let counterValue = defaultValue;
    const explicitValue = tokens[index];
    if (explicitValue && /^[+-]?\d+$/.test(explicitValue)) {
      counterValue = Number.parseInt(explicitValue, 10);
      index += 1;
    }
    operations.push({ name, value: counterValue });
  }
  return operations;
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

  if (!SUPPORTED_DISPLAY.has(display) || (["flex", "inline-flex", "grid", "inline-grid"].includes(display) && !usesWebLayout(options))) {
    throw new UnsupportedCssError(`display:${display} is outside the document/report layout profile`);
  }
  if (position !== "static" && !usesWebLayout(options)) {
    throw new UnsupportedCssError(`position:${position} is outside the document/report layout profile`);
  }
  if (floatValue !== "none" && !usesWebLayout(options)) {
    throw new UnsupportedCssError(`float:${floatValue} is outside the document/report layout profile`);
  }
  const transformValue = computed.getPropertyValue("transform");
  if (transformValue && transformValue !== "none" && !usesWebLayout(options)) {
    reportUnsupportedCss("transform", options, diagnostics);
  } else if (transformValue.startsWith("matrix3d(")) {
    reportUnsupportedCss("transform", options, diagnostics);
  }

  if (!isSvgElement(original)) {
    const unsupportedComputed = [
      ["filter", computed.getPropertyValue("filter"), "none", false],
      ["background-image", computed.getPropertyValue("background-image"), "none", true],
      ["box-shadow", computed.getPropertyValue("box-shadow"), "none", true],
      ["text-shadow", computed.getPropertyValue("text-shadow"), "none", true],
    ] as const;
    for (const [property, value, initial, webSupported] of unsupportedComputed) {
      if (value && value !== initial && (!webSupported || !usesWebLayout(options)) && !/^0px(?: 0px){0,3}$/.test(value)) {
        reportUnsupportedCss(property, options, diagnostics);
      }
    }
  }

  const declarations: string[] = [];
  const authoredInsets = computedStyle === undefined && position !== "static"
    ? authoredInsetOverrides(original, computed, view)
    : undefined;
  const properties = isSvgElement(original)
    ? [...SUPPORTED_COMPUTED_PROPERTIES, ...SVG_COMPUTED_PROPERTIES]
    : SUPPORTED_COMPUTED_PROPERTIES;
  for (const property of properties) {
    const value = property === "display"
      ? display
      : authoredInsets && property in authoredInsets
        ? authoredInsets[property as keyof typeof authoredInsets]!
        : computed.getPropertyValue(property);
    if (isFlowDimension(property) && !shouldMaterializeFlowDimension(original, property, isSnapshotRoot)) continue;
    // A fully transparent background has no paint effect. Omitting it keeps
    // the display list compact while semi-transparent colors retain real PDF
    // alpha through ExtGState.
    if (property === "background-color" && isFullyTransparentColor(value)) continue;
    if (value) declarations.push(`${property}:${value}`);
  }
  target.setAttribute("style", declarations.join(";"));
}

type InsetProperty = "top" | "right" | "bottom" | "left";

function authoredInsetOverrides(
  element: Element,
  computed: CSSStyleDeclaration,
  view: Window,
): Partial<Record<InsetProperty, string>> | undefined {
  const authored = new Set<InsetProperty>();
  if ("style" in element) collectInsetDeclarations((element as HTMLElement | SVGElement).style, authored);

  const stylesheets = [...element.ownerDocument.styleSheets, ...(element.ownerDocument.adoptedStyleSheets ?? [])];
  for (const stylesheet of stylesheets) {
    try {
      collectMatchedInsetRules(element, stylesheet.cssRules, view, authored);
    } catch {
      // Cross-origin sheets do not expose their rules. The computed fallback
      // remains available, but authored-side recovery cannot inspect them.
    }
  }

  const result: Partial<Record<"top" | "right" | "bottom" | "left", string>> = {};
  if (authored.has("top") || authored.has("bottom")) {
    result.top = authored.has("top") ? computed.getPropertyValue("top") : "auto";
    result.bottom = authored.has("bottom") ? computed.getPropertyValue("bottom") : "auto";
  }
  if (authored.has("left") || authored.has("right")) {
    result.left = authored.has("left") ? computed.getPropertyValue("left") : "auto";
    result.right = authored.has("right") ? computed.getPropertyValue("right") : "auto";
  }
  return Object.keys(result).length > 0 ? result : undefined;
}

function collectMatchedInsetRules(
  element: Element,
  rules: CSSRuleList,
  view: Window,
  authored: Set<InsetProperty>,
): void {
  for (const rule of [...rules]) {
    if (rule.type === CSS_STYLE_RULE && "selectorText" in rule && "style" in rule) {
      try {
        if (element.matches(String(rule.selectorText))) {
          collectInsetDeclarations((rule as CSSStyleRule).style, authored);
        }
      } catch {
        // A selector unsupported by Element.matches cannot contribute to the
        // browser's matched rule set for this snapshot element.
      }
      continue;
    }
    if (!("cssRules" in rule) || !(rule as CSSGroupingRule).cssRules) continue;
    if (rule.type === CSS_MEDIA_RULE && "conditionText" in rule && !view.matchMedia(String(rule.conditionText)).matches) continue;
    if (rule.type === CSS_SUPPORTS_RULE && "conditionText" in rule && !CSS.supports(String(rule.conditionText))) continue;
    collectMatchedInsetRules(element, (rule as CSSGroupingRule).cssRules, view, authored);
  }
}

function collectInsetDeclarations(style: CSSStyleDeclaration, authored: Set<InsetProperty>): void {
  for (const property of ["top", "right", "bottom", "left"] as const) {
    if (style.getPropertyValue(property).trim()) authored.add(property);
  }
}

function materializePseudoElement(
  original: Element,
  target: Element,
  pseudo: "::before" | "::after",
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  counters: CounterState,
): void {
  if (isReplacedOrControl(original)) return;
  const computed = (original.ownerDocument.defaultView ?? window).getComputedStyle(original, pseudo);
  const rawContent = computed.getPropertyValue("content").trim();
  if (!rawContent || rawContent === "none" || rawContent === "normal") return;
  const leaveCounterScope = counters.enterPseudo(original, pseudo);
  try {
    const content = resolveGeneratedContent(rawContent, original, counters);
    if (content === null) {
      reportUnsupportedCss(`content:${rawContent}`, options, diagnostics);
      return;
    }

    const synthetic = target.ownerDocument.createElement("span");
    synthetic.dataset.html2realpdfPseudo = pseudo.slice(2);
    synthetic.textContent = content;
    materializeComputedStyle(original, synthetic, options, diagnostics, false, computed);
    target.append(synthetic);
  } finally {
    leaveCounterScope();
  }
}

function resolveGeneratedContent(value: string, original: Element, counters: CounterState): string | null {
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
      const parsed = consumeCssFunction(value, index, "attr");
      if (!parsed) return null;
      const name = parsed.value.trim().split(/\s+/)[0];
      if (!name) return null;
      output += original.getAttribute(name) ?? "";
      index = parsed.next;
      continue;
    }
    if (value.startsWith("counter(", index) || value.startsWith("counters(", index)) {
      const plural = value.startsWith("counters(", index);
      const parsed = consumeCssFunction(value, index, plural ? "counters" : "counter");
      if (!parsed) return null;
      const formatted = resolveCounterFunction(parsed.value, plural, counters);
      if (formatted === null) return null;
      output += formatted;
      index = parsed.next;
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

function consumeCssFunction(source: string, start: number, name: string): { value: string; next: number } | null {
  const prefix = `${name}(`;
  if (!source.startsWith(prefix, start)) return null;
  const valueStart = start + prefix.length;
  let depth = 1;
  let index = valueStart;
  while (index < source.length) {
    const character = source[index];
    if (character === '"' || character === "'") {
      const parsed = consumeCssString(source, index, character);
      if (!parsed) return null;
      index = parsed.next;
      continue;
    }
    if (character === "\\") {
      index = Math.min(index + 2, source.length);
      continue;
    }
    if (character === "(") depth += 1;
    else if (character === ")") {
      depth -= 1;
      if (depth === 0) return { value: source.slice(valueStart, index), next: index + 1 };
    }
    index += 1;
  }
  return null;
}

function resolveCounterFunction(value: string, plural: boolean, counters: CounterState): string | null {
  const argumentsList = splitCssFunctionArguments(value);
  const name = argumentsList[0]?.trim();
  if (!name) return null;
  const separator = plural ? parseCssStringArgument(argumentsList[1] ?? "") : "";
  if (plural && separator === null) return null;
  const styleIndex = plural ? 2 : 1;
  const style = argumentsList[styleIndex]?.trim() || "decimal";
  const values = plural ? counters.values(name) : [counters.current(name)];
  const formatted = values.map((counterValue) => formatCounterValue(counterValue, style));
  if (formatted.some((counterValue) => counterValue === null)) return null;
  return formatted.join(separator ?? "");
}

function splitCssFunctionArguments(value: string): string[] {
  const argumentsList: string[] = [];
  let depth = 0;
  let start = 0;
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (character === '"' || character === "'") {
      const parsed = consumeCssString(value, index, character);
      if (!parsed) return [];
      index = parsed.next;
      continue;
    }
    if (character === "(") depth += 1;
    else if (character === ")") depth = Math.max(depth - 1, 0);
    else if (character === "," && depth === 0) {
      argumentsList.push(value.slice(start, index));
      start = index + 1;
    }
    index += 1;
  }
  argumentsList.push(value.slice(start));
  return argumentsList;
}

function parseCssStringArgument(value: string): string | null {
  const normalized = value.trim();
  const quote = normalized[0];
  if (quote !== '"' && quote !== "'") return null;
  const parsed = consumeCssString(normalized, 0, quote);
  return parsed && normalized.slice(parsed.next).trim() === "" ? parsed.value : null;
}

function formatCounterValue(value: number, style: string): string | null {
  switch (style.toLowerCase()) {
    case "decimal":
      return String(value);
    case "decimal-leading-zero": {
      const sign = value < 0 ? "-" : "";
      return `${sign}${String(Math.abs(value)).padStart(2, "0")}`;
    }
    case "lower-alpha":
    case "lower-latin":
      return formatAlphabeticCounter(value, false);
    case "upper-alpha":
    case "upper-latin":
      return formatAlphabeticCounter(value, true);
    case "lower-roman":
      return formatRomanCounter(value, false);
    case "upper-roman":
      return formatRomanCounter(value, true);
    default:
      return null;
  }
}

function formatAlphabeticCounter(value: number, uppercase: boolean): string {
  if (value <= 0) return String(value);
  let output = "";
  let remaining = value;
  while (remaining > 0) {
    remaining -= 1;
    output = String.fromCharCode((uppercase ? 65 : 97) + remaining % 26) + output;
    remaining = Math.floor(remaining / 26);
  }
  return output;
}

function formatRomanCounter(value: number, uppercase: boolean): string {
  if (value <= 0 || value >= 4000) return String(value);
  const symbols: readonly [number, string][] = [
    [1000, "M"], [900, "CM"], [500, "D"], [400, "CD"], [100, "C"], [90, "XC"], [50, "L"],
    [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"],
  ];
  let output = "";
  let remaining = value;
  for (const [amount, symbol] of symbols) {
    while (remaining >= amount) {
      output += symbol;
      remaining -= amount;
    }
  }
  return uppercase ? output : output.toLowerCase();
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

  const root = element.getRootNode();
  if (root.nodeType === Node.DOCUMENT_FRAGMENT_NODE && "host" in root) {
    const shadowRoot = root as ShadowRoot;
    for (const style of shadowRoot.querySelectorAll("style")) {
      try {
        if (style.sheet && rulesAuthorProperty(style.sheet.cssRules, element, property)) return true;
      } catch {
        // A malformed shadow stylesheet does not invalidate the snapshot.
      }
    }
    for (const sheet of shadowRoot.adoptedStyleSheets ?? []) {
      try {
        if (rulesAuthorProperty(sheet.cssRules, element, property)) return true;
      } catch {
        // Keep inspecting other authored sources.
      }
    }
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
      const unsupportedReason = vectorSvgUnsupportedReason(svg);
      const source = new XMLSerializer().serializeToString(svg);
      const replacement = svg.ownerDocument.createElement("img");
      for (const attribute of svg.attributes) {
        if (attribute.name === "style") {
          replacement.setAttribute("style", stripStyleProperties(attribute.value, SVG_COMPUTED_PROPERTIES));
        } else if (attribute.name !== "xmlns") {
          replacement.setAttribute(attribute.name, attribute.value);
        }
      }
      setSvgIntrinsicSize(svg, replacement);
      if (unsupportedReason === null) {
        replacement.src = await blobToDataUrl(new Blob([source], { type: "image/svg+xml" }));
      } else {
        if (options.fallback === "error") {
          throw new UnsupportedCssError(`Inline SVG requires subtree rasterization: ${unsupportedReason}`);
        }
        replacement.src = await rasterizeBlobToPng(new Blob([source], { type: "image/svg+xml" }));
        diagnostics.push({
          code: "CSS_SUBTREE_RASTERIZED",
          severity: "warning",
          message: `Inline SVG was rasterized because native vector paint does not support ${unsupportedReason}`,
          nodePath: snapshotNodePath(svg, root),
          phase: "paint",
          fallback: "rasterized-subtree",
        });
      }
      replacement.alt = svg.getAttribute("aria-label") ?? "";
      svg.replaceWith(replacement);
    } catch (error) {
      if (error instanceof UnsupportedCssError) throw error;
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

function stripStyleProperties(style: string, properties: readonly string[]): string {
  const omitted = new Set(properties);
  return style.split(";").filter((declaration) => {
    const colon = declaration.indexOf(":");
    return colon < 0 || !omitted.has(declaration.slice(0, colon).trim().toLowerCase());
  }).join(";");
}

function vectorSvgUnsupportedReason(svg: SVGSVGElement): string | null {
  const elements = [svg, ...svg.querySelectorAll("*")];
  for (const element of elements) {
    if (!isSvgElement(element) || !VECTOR_SVG_ELEMENTS.has(element.localName)) return `<${element.localName}>`;
    if (element !== svg && element.localName === "svg") return "nested <svg> viewport";
    if (element.localName === "title" || element.localName === "desc") continue;
    const style = (element as SVGElement).style;
    for (const property of VECTOR_SVG_UNSUPPORTED_PROPERTIES) {
      const authored = element.getAttribute(property);
      const computed = style.getPropertyValue(property);
      if ((authored && svgUnsupportedPropertyIsActive(property, authored)) || (computed && svgUnsupportedPropertyIsActive(property, computed))) return property;
    }
    for (const property of ["fill", "stroke"] as const) {
      const paint = style.getPropertyValue(property) || element.getAttribute(property) || "";
      if (/url\s*\(/i.test(paint)) return `${property} paint server`;
      if (svgPaintIsTranslucent(paint)) return `${property} opacity`;
    }
    for (const property of ["opacity", "fill-opacity", "stroke-opacity"] as const) {
      const raw = style.getPropertyValue(property) || element.getAttribute(property) || "1";
      const value = Number.parseFloat(raw);
      if (!Number.isFinite(value) || value < 0.9999) return property;
    }
    const transform = style.getPropertyValue("transform");
    if (transform.startsWith("matrix3d(")) return "3D transform";
    const transformOrigin = style.getPropertyValue("transform-origin");
    if (element !== svg && transform && transform !== "none" && transformOrigin && !isZeroSvgTransformOrigin(transformOrigin)) return "transform-origin";
  }
  return null;
}

function svgUnsupportedPropertyIsActive(property: string, raw: string): boolean {
  const value = raw.trim().toLowerCase();
  if (!value || value === "none" || value === "auto") return false;
  if ((property === "mix-blend-mode" || property === "paint-order") && value === "normal") return false;
  return true;
}

function svgPaintIsTranslucent(raw: string): boolean {
  const value = raw.trim().toLowerCase();
  if (!value || value === "none") return false;
  if (value === "transparent") return true;
  const hex = value.match(/^#(?:[0-9a-f]{4}|[0-9a-f]{8})$/i);
  if (hex) return value.length === 5 ? value[4] !== "f" : value.slice(7, 9) !== "ff";
  const commaAlpha = value.match(/^rgba\([^)]*,\s*([+-]?(?:\d+\.?\d*|\.\d+)%?)\s*\)$/);
  if (commaAlpha) return cssAlphaValue(commaAlpha[1]!) < 0.9999;
  const slashAlpha = value.match(/\/\s*([+-]?(?:\d+\.?\d*|\.\d+)%?)\s*\)$/);
  return slashAlpha ? cssAlphaValue(slashAlpha[1]!) < 0.9999 : false;
}

function cssAlphaValue(raw: string): number {
  const value = Number.parseFloat(raw);
  return raw.endsWith("%") ? value / 100 : value;
}

function isZeroSvgTransformOrigin(raw: string): boolean {
  const tokens = raw.trim().split(/\s+/);
  return tokens.length >= 2 && tokens.every((token) => /^0(?:px)?$/i.test(token));
}

function setSvgIntrinsicSize(svg: SVGSVGElement, replacement: HTMLImageElement): void {
  const viewBox = parseSvgViewBox(svg.getAttribute("viewBox"));
  let width = parseSvgPixelLength(svg.getAttribute("width")) ?? parseSvgPixelLength(svg.style.width);
  let height = parseSvgPixelLength(svg.getAttribute("height")) ?? parseSvgPixelLength(svg.style.height);
  if (viewBox && width === null && height === null) {
    width = viewBox.width;
    height = viewBox.height;
  } else if (viewBox && width !== null && height === null && viewBox.width > 0) {
    height = width * viewBox.height / viewBox.width;
  } else if (viewBox && height !== null && width === null && viewBox.height > 0) {
    width = height * viewBox.width / viewBox.height;
  }
  if (width !== null && width > 0) replacement.dataset.html2realpdfIntrinsicWidth = String(width);
  if (height !== null && height > 0) replacement.dataset.html2realpdfIntrinsicHeight = String(height);
}

function parseSvgViewBox(raw: string | null): { width: number; height: number } | null {
  if (!raw) return null;
  const values = raw.trim().split(/[\s,]+/).map(Number);
  if (values.length !== 4 || values.some((value) => !Number.isFinite(value)) || values[2]! <= 0 || values[3]! <= 0) return null;
  return { width: values[2]!, height: values[3]! };
}

function parseSvgPixelLength(raw: string | null): number | null {
  if (!raw) return null;
  const match = raw.trim().match(/^([+-]?(?:\d+\.?\d*|\.\d+))(?:px)?$/i);
  if (!match) return null;
  const value = Number.parseFloat(match[1]!);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function snapshotNodePath(element: Element, root: ParentNode): string {
  const parts: string[] = [];
  let current: Element | null = element;
  while (current) {
    if (current.id) {
      parts.unshift(`#${CSS.escape(current.id)}`);
      break;
    }
    let part = current.localName;
    const classes = [...current.classList].slice(0, 2);
    if (classes.length > 0) part += classes.map((name) => `.${CSS.escape(name)}`).join("");
    if (current.parentElement) {
      const siblings = [...current.parentElement.children].filter((candidate) => candidate.localName === current!.localName);
      if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
    }
    parts.unshift(part);
    if (current === root || current.parentNode === root) break;
    current = current.parentElement;
  }
  return parts.join(" > ");
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
    const image = target as HTMLImageElement;
    if (source.currentSrc) image.src = source.currentSrc;
    if (source.naturalWidth > 0 && source.naturalHeight > 0) {
      image.dataset.html2realpdfIntrinsicWidth = String(source.naturalWidth);
      image.dataset.html2realpdfIntrinsicHeight = String(source.naturalHeight);
    }
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
  if (root.nodeType === Node.ELEMENT_NODE && (root as Element).localName === "img") images.unshift(root as HTMLImageElement);
  for (const image of images) {
    const source = (image as HTMLImageElement).currentSrc || image.getAttribute("src") || "";
    if (!source) continue;
    if (/^data:image\/svg\+xml;/i.test(source)) {
      try {
        const response = await fetch(source);
        await materializeSvgImageBlob(image as HTMLImageElement, await response.blob(), options, diagnostics, root);
      } catch (error) {
        if (error instanceof UnsupportedCssError) throw error;
        if (options.resourcePolicy === "error") throw new ResourceLoadError(source, { cause: error });
        image.remove();
        diagnostics.push({
          code: "RESOURCE_OMITTED",
          severity: "warning",
          message: "SVG image resource was omitted",
          phase: "snapshot",
        });
      }
      continue;
    }
    if (/^data:image\/(?:jpeg|jpg|png);/i.test(source)) continue;

    try {
      const url = new URL(source, options.baseUrl ?? image.ownerDocument.baseURI);
      const resolved = await options.resourceResolver?.({ kind: "image", url });
      if (typeof resolved === "string" && /^data:image\/(?:jpeg|jpg|png);/i.test(resolved)) {
        (image as HTMLImageElement).src = resolved;
        continue;
      }
      const blob = resolved instanceof Blob ? resolved : await fetchImageBlob(
        typeof resolved === "string" ? new URL(resolved, url) : url,
      );
      if (blob.type === "image/svg+xml") {
        await materializeSvgImageBlob(image as HTMLImageElement, blob, options, diagnostics, root);
        continue;
      }
      (image as HTMLImageElement).src = blob.type === "image/jpeg" ? await blobToDataUrl(blob) : await rasterizeBlobToPng(blob);
    } catch (error) {
      if (error instanceof UnsupportedCssError) throw error;
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

async function materializeSvgImageBlob(
  image: HTMLImageElement,
  blob: Blob,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  snapshotRoot: ParentNode,
): Promise<void> {
  image.src = await materializeSvgResourceBlob(blob, options, diagnostics, image, snapshotRoot, "SVG image");
}

async function materializeSvgResourceBlob(
  blob: Blob,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
  target: Element,
  snapshotRoot: ParentNode,
  label: string,
): Promise<string> {
  const source = await blob.text();
  const parsed = new DOMParser().parseFromString(source, "image/svg+xml");
  if (parsed.querySelector("parsererror") || !isSvgElement(parsed.documentElement) || parsed.documentElement.localName !== "svg") {
    throw new Error("Invalid SVG image resource");
  }
  const svg = parsed.documentElement as unknown as SVGSVGElement;
  if (!svg.hasAttribute("xmlns")) svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
  const normalized = new XMLSerializer().serializeToString(svg);
  const normalizedBlob = new Blob([normalized], { type: "image/svg+xml" });
  const unsupportedReason = vectorSvgUnsupportedReason(svg);
  if (unsupportedReason === null) {
    return blobToDataUrl(normalizedBlob);
  }
  if (options.fallback === "error") {
    throw new UnsupportedCssError(`${label} requires subtree rasterization: ${unsupportedReason}`);
  }
  diagnostics.push({
    code: "CSS_SUBTREE_RASTERIZED",
    severity: "warning",
    message: `${label} was rasterized because native vector paint does not support ${unsupportedReason}`,
    nodePath: snapshotNodePath(target, snapshotRoot),
    phase: "paint",
    fallback: "rasterized-subtree",
  });
  return rasterizeBlobToPng(normalizedBlob);
}

async function materializeBackgroundImages(
  root: ParentNode,
  options: SnapshotOptions,
  diagnostics: Diagnostic[],
): Promise<void> {
  const elements: Element[] = [...root.querySelectorAll<HTMLElement>("[style]")];
  if (root.nodeType === Node.ELEMENT_NODE && (root as Element).hasAttribute("style")) elements.unshift(root as Element);
  for (const element of elements) {
    const backgroundImage = (element as HTMLElement).style.getPropertyValue("background-image");
    if (!backgroundImage || backgroundImage === "none") continue;
    let materialized = backgroundImage;
    const matches = [...backgroundImage.matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/gi)];
    for (const match of matches) {
      const source = (match[1] ?? match[2] ?? match[3] ?? "").trim();
      if (!source || /^data:image\/(?:jpeg|jpg|png);/i.test(source)) continue;
      try {
        const url = new URL(source, options.baseUrl ?? element.ownerDocument.baseURI);
        const resolved = await options.resourceResolver?.({ kind: "image", url });
        let dataUrl: string;
        if (typeof resolved === "string" && /^data:image\/(?:jpeg|jpg|png);/i.test(resolved)) {
          dataUrl = resolved;
        } else {
          const blob = resolved instanceof Blob ? resolved : await fetchImageBlob(
            typeof resolved === "string" ? new URL(resolved, url) : url,
          );
          dataUrl = blob.type === "image/svg+xml"
            ? await materializeSvgResourceBlob(blob, options, diagnostics, element, root, "Background SVG")
            : blob.type === "image/jpeg" ? await blobToDataUrl(blob) : await rasterizeBlobToPng(blob);
        }
        materialized = materialized.replace(match[0], `url("${dataUrl}")`);
      } catch (error) {
        if (error instanceof UnsupportedCssError) throw error;
        if (options.resourcePolicy === "error") throw new ResourceLoadError(source, { cause: error });
        materialized = materialized.replace(match[0], "none");
        diagnostics.push({
          code: "RESOURCE_OMITTED",
          severity: "warning",
          message: `Background image resource was omitted: ${source}`,
          phase: "snapshot",
        });
      }
    }
    (element as HTMLElement).style.setProperty("background-image", materialized);
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
    const css = element.localName === "style" ? stripPageRuleBlocks(element.textContent ?? "") : element.getAttribute("style") ?? "";
    for (const match of css.matchAll(/(?:^|[;{])\s*([\w-]+)\s*:\s*([^;}]+)/g)) {
      const property = match[1]?.toLowerCase();
      const value = (match[2]?.trim().toLowerCase() ?? "").replace(/\s*!important\s*$/, "");
      if (!property || property.startsWith("--")) continue;
      validateAuthoredLayout(property, value, options);
      if (property === "background" && !usesWebLayout(options) && /(?:url|(?:repeating-)?(?:linear|radial|conic)-gradient)\s*\(/.test(value)) {
        reportUnsupportedCss("background-image", options, diagnostics);
      }
      if (SUPPORTED_CSS_PROPERTIES.has(property)) continue;
      reportUnsupportedCss(property, options, diagnostics);
    }
  }
}

function stripPageRuleBlocks(css: string): string {
  const lower = css.toLowerCase();
  let output = "";
  let cursor = 0;
  while (cursor < css.length) {
    const start = lower.indexOf("@page", cursor);
    if (start < 0) return output + css.slice(cursor);
    const boundary = lower[start + 5];
    if (boundary && /[\w-]/.test(boundary)) {
      output += css.slice(cursor, start + 5);
      cursor = start + 5;
      continue;
    }
    const open = css.indexOf("{", start + 5);
    if (open < 0) return output + css.slice(cursor, start);
    output += css.slice(cursor, start);
    let depth = 1;
    let quote = "";
    let index = open + 1;
    while (index < css.length && depth > 0) {
      const character = css[index]!;
      if (quote) {
        if (character === "\\") index += 1;
        else if (character === quote) quote = "";
      } else if (character === '"' || character === "'") {
        quote = character;
      } else if (character === "/" && css[index + 1] === "*") {
        const commentEnd = css.indexOf("*/", index + 2);
        index = commentEnd < 0 ? css.length : commentEnd + 1;
      } else if (character === "{") {
        depth += 1;
      } else if (character === "}") {
        depth -= 1;
      }
      index += 1;
    }
    cursor = index;
  }
  return output;
}

function validateAuthoredLayout(property: string, value: string, options: SnapshotOptions): void {
  if (property === "display" && (!SUPPORTED_DISPLAY.has(value) || (["flex", "inline-flex", "grid", "inline-grid"].includes(value) && !usesWebLayout(options)))) {
    throw new UnsupportedCssError(`display:${value} is outside the document/report layout profile`);
  }
  if (property === "position" && value !== "static" && !usesWebLayout(options)) {
    throw new UnsupportedCssError(`position:${value} is outside the document/report layout profile`);
  }
  if (property === "float" && value !== "none" && !usesWebLayout(options)) {
    throw new UnsupportedCssError(`float:${value} is outside the document/report layout profile`);
  }
}

function usesWebLayout(options: SnapshotOptions): boolean {
  return options.cssProfile === "web" || options.cssProfile === "strict";
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
