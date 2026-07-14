# HTML2RealPDF CSS Support

This document is the public compatibility contract for the versioned
HTML2RealPDF CSS profiles. The target reference is the
[W3C CSS Snapshot 2024](https://www.w3.org/TR/css-2024/), but support is
declared module by module and property by property rather than as the ambiguous
label "CSS3".

## Profiles

- **document** is the current `0.1.x` profile for invoices, reports, tickets,
  letters, tables, and presentation-like pages. Unsupported layout-critical
  behavior fails instead of being silently painted incorrectly.
- **web** is the staged `0.2+` profile. It enables the Unicode typography,
  browser snapshot, normal-flow, table, float, Flexbox, positioned-layout, and
  Grid formatting contexts plus native 2D transforms, backgrounds, shadows,
  isolated opacity, and supported SVG vector paint.
- **strict** uses the same layout engine and turns unsupported CSS into an
  immediate error at the browser snapshot boundary.

## Reading the matrix

`P` parsed, `C` cascaded, `V` computed value, `L` laid out, `Paint` emitted to
the display list/PDF, `Page` participates in pagination, and `T` has automated
coverage. A dash means the stage is not applicable or not implemented.

| Property or group | P | C | V | L | Paint | Page | T | Current limit |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| `display` | Y | Y | Y | Y | - | Y | Y | block, inline, inline-block, list-item, flex, inline-flex, grid, inline-grid, and table roles |
| width/height/min/max | Y | Y | Y | Y | - | Y | Y | typed lengths, `calc()`/`min()`/`max()`/`clamp()`, `min-content`/`max-content`/`fit-content()`, viewport/font units; web/strict resolve block-axis percentages only through definite containing sizes |
| `aspect-ratio` | Y | Y | Y | Y | - | Y | Y | preferred ratio with intrinsic fallback for replaced elements; web/strict transfer the preferred ratio into auto block size for normal boxes |
| `object-fit` / `object-position` | Y | Y | Y | Y | Y | Y | Y | fill, contain, cover, none, scale-down; common one/two-value positions and native PDF clipping |
| inline/data URL SVG | Y | Y | Y | Y | Y | Y | Y | `path`, rect, circle/ellipse, line, polyline/polygon, nested groups, affine transforms, arcs, rounded rects, solid fill/stroke, dash/cap/join, selectable `text`/`tspan`, bounded linear/radial gradient fills, local `clipPath`, viewBox and preserveAspectRatio become clipped PDF Form XObjects; masks, filters, gradient stroke/text, inherited gradients and unsupported elements use a diagnostic scoped fallback |
| margin/padding | Y | Y | Y | Y | Y | Y | Y | four physical sides; web/strict collapse sibling, parent/child, empty-block, and mixed positive/negative margin groups across eligible block formatting contexts; flex items consume main/cross `auto` margins |
| logical sizing/margin/padding/border | Y | Y | Y | Y | Y | Y | Y | `*-block`/`*-inline` longhands and axis shorthands map with final `direction`, share cascade priority with physical peers, and preserve logical `inherit`; horizontal-tb writing mode |
| borders | Y | Y | Y | Y | Y | Y | Y | physical sides; solid, dashed, dotted |
| `border-radius` | Y | Y | Y | Y | Y | Y | Y | four independent length-percentage corners, elliptical slash syntax, overlap normalization, native PDF curves, and rounded overflow clipping |
| `box-decoration-break` | Y | Y | Y | Y | Y | Y | Y | web/strict support `slice` and `clone` across page fragments; document preserves its legacy repeated-border behavior |
| color/background color | Y | Y | Y | Y | Y | Y | Y | common named/hex/rgb(a) colors, `currentColor`, and native PDF alpha via ExtGState |
| multiple `background-image` layers | Y | Y | Y | Y | Y | Y | Y | URL images plus linear, radial, and conic gradients; CSS list matching preserves front-to-back layer order |
| `background-size` / `background-position` / `background-repeat` | Y | Y | Y | Y | Y | Y | Y | per-layer auto/length/percentage/cover/contain sizing, keyword or length-percentage placement, repeat/no-repeat/repeat-x/repeat-y tiling, and rounded border-box clipping |
| `box-shadow` / `text-shadow` | Y | Y | Y | Y | Y | Y | Y | multiple outer/inset box shadows use native vector falloff paths; text shadows remain font-backed PDF artifacts and do not replace selectable source text |
| font family/size/weight/style | Y | Y | Y | Y | Y | Y | Y | four Noto Sans Latin faces plus built-in Arabic/Hebrew fallbacks and registered TTF faces |
| line height/letter spacing | Y | Y | Y | Y | Y | Y | Y | web/strict use HarfBuzz OpenType shaping, kerning, ligatures, positioned clusters, and per-glyph fallback; document keeps its byte-stable identity shaper |
| `word-spacing` | Y | Y | Y | Y | Y | Y | Y | U+0020 spacing is measured in layout and emitted with Type 0 font `TJ` adjustments |
| `direction` / bidi | Y | Y | Y | Y | Y | Y | Y | web/strict use SheenBidi UAX #9 paragraph levels and L2 visual reordering; `ltr` and `rtl` base directions |
| `text-indent` | Y | Y | Y | Y | Y | Y | Y | lengths and percentages on the first formatted line |
| `text-transform` | Y | Y | Y | Y | Y | Y | Y | Unicode 17 full mappings for uppercase, lowercase, and capitalize; conditional Lithuanian, Turkish, and Azeri casing follows inherited `lang` |
| `word-break` / `overflow-wrap` | Y | Y | Y | Y | Y | Y | Y | UAX #14 legal opportunities, CJK keep-all, and extended-grapheme emergency wrapping for break-all, break-word, and anywhere |
| `overflow` / `text-overflow` | Y | Y | Y | Y | Y | Y | Y | visible plus padding-edge clipping, including border-radius curves, for hidden/clip/auto/scroll; selectable single-line ellipsis |
| `vertical-align` / inline baselines | Y | Y | Y | Y | Y | Y | Y | mixed text metrics, keywords, and length-percentage offsets; web/strict add replaced-element bottom-margin and inline-block last-line/bottom-margin baselines |
| `white-space` | Y | Y | Y | Y | Y | Y | Y | normal, nowrap, pre, pre-wrap, pre-line |
| `text-align` | Y | Y | Y | Y | Y | Y | Y | start/end resolved from direction, plus left, center, right, justify |
| `text-decoration` | Y | Y | Y | Y | Y | Y | Y | combined underline/overline/line-through, color, thickness, solid/double/dotted/dashed/wavy vector styles |
| `list-style-type` / `list-style-position` | Y | Y | Y | Y | Y | Y | Y | inherited common bullet, decimal, alphabetic and Roman markers; inside/outside placement, HTML start/reversed/value/type hints |
| `box-sizing` | Y | Y | Y | Y | - | Y | Y | content-box and border-box |
| `border-collapse` | Y | Y | Y | Y | Y | Y | Y | table collapsed-border approximation |
| `border-spacing` | Y | Y | Y | Y | Y | Y | Y | inherited one/two-value non-negative lengths; horizontal and vertical outer/inter-cell spacing applies only to separate-border tables |
| `caption-side` | Y | Y | Y | Y | Y | Y | Y | inherited `top` and `bottom` placement on table captions |
| table formatting | Y | Y | Y | Y | Y | Y | Y | intrinsic auto-layout tracks, percentage/column hints, rowspan/colspan, captions and column groups, repeated headers plus page-end footers with reserved body extent, avoid-linked row groups, and top/middle/bottom/baseline cell alignment including row spans |
| break before/after/inside | Y | Y | Y | Y | - | Y | Y | `always` alias plus `page`, `left`, `right`, `recto`, `verso`, `avoid`, and `avoid-page`; adjacent values arbitrate together, first/last block-child values propagate, forced values override avoid, and block/table/Flex/Grid page opportunities share one fragmentainer model |
| `orphans` / `widows` | Y | Y | Y | Y | - | Y | Y | paragraph line constraints |
| `page` | Y | Y | Y | Y | - | Y | Y | `auto` plus case-sensitive custom identifiers; used values resolve through the nearest named ancestor, first/last eligible children propagate page names, and name changes force class A page breaks in block/table/Flex/Grid flows |
| default `@page` size/margins | Y | Y | Y | Y | - | Y | Y | browser CSSOM cascade including `!important`; A3/A4/A5, Letter/Legal/Ledger/Tabloid, portrait/landscape, one/two absolute lengths, and physical margin longhands; explicit API page options override CSS |
| named and pseudo `@page` geometry | Y | Y | Y | Y | - | Y | Y | case-sensitive page names plus `:first`, `:left`, `:right`, and `:blank`; importance, page-selector specificity, and source order resolve per-page PDF geometry; the shared fragmentainer uses variable content heights, re-sizes auto-width initial-containing-block descendants, rewraps inline lines, and records forced facing-page gaps as blank pages |
| `@page` margin boxes | Y | Y | Y | Y | Y | Y | Y | default, named, and `:first`/`:left`/`:right`/`:blank` selection across all 16 standard positions; concatenated CSS strings plus decimal `counter(page)`/`counter(pages)`; font family/size/weight/style, color, and text alignment remain selectable native PDF text |
| `position` | Y | Y | Y | Y | Y | Y | Y | web/strict relative, absolute, fixed, and sticky; document rejects non-static; authored top/right/bottom/left anchors survive browser used-value capture, fixed headers/footers repeat at page-relative coordinates, auto-width fixed boxes follow each repeated page's inline extent, and sticky resolves as relative in paged media |
| physical/logical inset | Y | Y | Y | Y | - | Y | Y | top/right/bottom/left plus block/inline logical forms; auto sizing, opposing-inset stretch, auto margins, and nearest positioned padding containing block |
| `z-index` / stacking order | Y | Y | Y | Y | Y | Y | Y | negative, normal-flow, auto/zero, and positive positioned paint phases with atomic descendant traversal |
| `opacity` | Y | Y | Y | Y | Y | Y | Y | each opacity stacking context becomes a nested isolated PDF transparency Form XObject, so overlapping descendants are composited once |
| `transform` / `transform-origin` | Y | Y | Y | Y | Y | Y | Y | web/strict matrix, translate, scale, rotate, and skew; length-percentage origins, cumulative descendant transforms, transformed clips and link bounds; native PDF `cm`, no 3D transforms |
| `float` | Y | Y | Y | Y | Y | Y | Y | web/strict left and right exclusion bands with shrink-to-fit sizing; document rejects non-none |
| `clear` | Y | Y | Y | Y | - | Y | Y | none, left, right, and both within the current block formatting context |
| Flexbox container | Y | Y | Y | Y | Y | Y | Y | web/strict `flex` and `inline-flex`; row/column/reverse, wrap/wrap-reverse, gaps, justify/align items/content, baseline and RTL main-start |
| Flexbox items | Y | Y | Y | Y | Y | Y | Y | basis including percentages/content, grow/shrink with iterative min/max freezing, partial grow factors, order, auto margins, replaced elements, nested flex, intrinsic sizing, and atomic line/item page advancement |
| Grid container | Y | Y | Y | Y | Y | Y | Y | web/strict `grid` and `inline-grid`; explicit/implicit rows and columns, fixed/percentage/intrinsic/`fr` tracks, integer/auto `repeat()`, `minmax()`, gaps, nested grids, and row-aware pagination |
| Grid placement | Y | Y | Y | Y | Y | Y | Y | row/column auto-flow with dense packing, numeric and negative lines, spans, named lines, rectangular named areas, stable `order`, and replaced items |
| Grid alignment | Y | Y | Y | Y | Y | Y | Y | justify/align items, self, and content plus auto margins; horizontal-tb axes |
| selectors | Y | Y | - | - | - | - | Y | type, class, ID, universal, compound, descendant, child |
| `!important`, inheritance, source order | Y | Y | Y | - | - | - | Y | author origin and inline style ordering |
| supported shorthands | Y | Y | Y | - | - | - | Y | expanded to physical longhands before computed values |
| escaped CSS identifiers | Y | Y | Y | - | - | - | Y | simple and hexadecimal escapes, including leading-digit class names |
| CSS-wide keywords | Y | Y | Y | - | - | - | Y | `initial`, `inherit`, `unset`, `revert` |
| custom properties / `var()` | Y | Y | Y | - | - | - | Y | inherited scopes, nested fallback, cycle detection |
| browser pseudo-elements | Y | Y | Y | Y | Y | Y | Y | `::before`/`::after` strings, `attr()`, and nested `counter()`/`counters()` become synthetic nodes |
| browser media/viewport snapshot | Y | Y | Y | - | - | - | Y | deterministic viewport for strings, Elements, and refs; explicit `screen` or `print`; transitions/animations frozen |
| open Shadow DOM snapshot | Y | Y | Y | Y | Y | Y | Y | opt-in composed-tree flattening with slots |
| external stylesheet snapshot | Y | Y | Y | - | - | - | Y | HTML-string network access is mediated by `resourceResolver` and resource policy |

The machine-readable property inventory lives in
`src/css/properties.zig`. Structural snapshots, Zig tests, Node ABI tests, and
Playwright E2E make the matrix verifiable.

## Explicitly unsupported in the current profile

- blend/compositing modes beyond normal source-over remain pending;
- complex pseudo-element `content` values beyond strings, `attr()`, common quote keywords, and decimal/alphabetic/Roman counters;
- Grid `subgrid`, masonry, and experimental features; full Appendix E painting
  nuances beyond the supported positioned stacking phases;
- filters, 3D transforms, background origin/clip/attachment variants, and blend modes;
- vertical `writing-mode` values; logical box properties currently map within horizontal-tb;
- CSS `unicode-bidi` isolate/override modes and language-specific case tailoring beyond Unicode `SpecialCasing.txt`;
  Arabic and Hebrew have built-in shaped fallbacks, while emoji and other
  scripts require a registered embeddable TTF fallback;
  the package test suite registers a deterministic monochrome emoji fixture;
- multi-column fragmentation and non-text margin-box painting;
- rebuilding a non-auto Flex/Grid/table formatting context that has already
  started when a later pseudo-page changes its inline size mid-context;
  page fragmentainers already coordinate block, inline, table, Flex, and Grid
  placement, and named/pseudo rules already produce per-page PDF geometry.

These features are not silently represented as whole-page screenshots. Canvas
remains a scoped image resource unless `canvasToSvg` supplies a valid SVG
replacement; unsupported SVG subtrees also remain scoped. Supported SVG is a
native PDF Form XObject, while normal text, links, backgrounds, gradients,
shadows, borders, and fills remain native PDF content. `canvasFallback:
"rasterize"` emits `CANVAS_SUBTREE_RASTERIZED`; `canvasFallback: "error"`
rejects a missing, malformed, or unsupported adapter result.

Unsupported declarations found by the Zig/native path are returned through the
WASM result handle as owned structured diagnostics. Browser snapshots attach
the same diagnostic shape and honor `unsupportedCss: "warn" | "error" |
"ignore"`. Unsupported inline SVG emits `CSS_SUBTREE_RASTERIZED` with a
`nodePath`, `phase: "paint"`, and `fallback: "rasterized-subtree"`; callers can
opt into that scoped fallback with `fallback: "rasterize-subtree"`. The default
is `fallback: "error"`; whole-page rasterization is never used.

## Verification gates

- `make test-wpt` runs the revision-pinned renderer-native Flex, Grid, and
  pagination scenarios documented in `tests/wpt/README.md`.
- `make test-robustness` runs 512 deterministic malformed HTML/CSS mutations,
  an allocation-exhaustion error path, and a 30-plus-page native/selectable PDF
  gate under `ReleaseSafe`.
- `make test` runs focused Zig parser, cascade, layout, pagination, display-list,
  and PDF tests plus native linked HarfBuzz, SheenBidi, and libunibreak gates.
- `make test-web-snapshots` checks stable WASM structural output and a real PDF
  result handle in Node.
- `make test-browser` runs the browser harness and mounted React-ref preview on
  Chromium, Firefox, and WebKit, plus a Chromium differential gate that compares
  Web Flexbox, positioned-layout, and Grid vector geometry with live DOM
  rectangles within `0.75` CSS px; the positioned gate also verifies clipping,
  opacity, stacking order, fixed-page repetition, and absence of raster
  fallback. All three engines verify compiled CSS Modules, styled-components,
  and escaped Tailwind-style selectors as native selectable content. Chromium
  also verifies that supported SVG and `canvasToSvg` yield vector PDF paths and
  selectable text without image objects, while unsupported SVG and canvas
  fallback remain scoped and diagnostic.
- `make test-baseline` regenerates the versioned PDF fixtures in memory and
  compares their SHA-256 digests with the committed visual baseline manifest.
- `make test-release` runs all of the above plus package and React builds.
