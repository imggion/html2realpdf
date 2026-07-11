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
- **web** is the staged `0.2+` profile. Its foundations exist as separate CSS
  and formatting-context modules, but Flexbox, Grid, positioned layout, floats,
  and web effects are not enabled yet.
- **strict** uses the same layout engine and turns unsupported CSS into an
  immediate error at the browser snapshot boundary.

## Reading the matrix

`P` parsed, `C` cascaded, `V` computed value, `L` laid out, `Paint` emitted to
the display list/PDF, `Page` participates in pagination, and `T` has automated
coverage. A dash means the stage is not applicable or not implemented.

| Property or group | P | C | V | L | Paint | Page | T | Current limit |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| `display` | Y | Y | Y | Y | - | Y | Y | block, inline, inline-block, and table roles |
| width/height/min/max | Y | Y | Y | Y | - | Y | Y | typed lengths, percentages, `calc()`, `min()`, `max()`, `clamp()`, viewport and font-relative units |
| margin/padding | Y | Y | Y | Y | Y | Y | Y | four physical sides; adjacent block margin collapse |
| borders | Y | Y | Y | Y | Y | Y | Y | physical sides; solid, dashed, dotted |
| `border-radius` | Y | Y | Y | Y | Y | Y | Y | one uniform circular radius |
| color/background color | Y | Y | Y | Y | Y | Y | Y | common named/hex/rgb(a) colors, `currentColor`, and native PDF alpha via ExtGState |
| font family/size/weight/style | Y | Y | Y | Y | Y | Y | Y | built-in Noto Sans and registered TTF faces |
| line height/letter spacing | Y | Y | Y | Y | Y | Y | Y | per-glyph registered font fallback and multi-font runs; shaping and kerning pending |
| `word-spacing` | Y | Y | Y | Y | Y | Y | Y | U+0020 spacing is measured in layout and emitted with Type 0 font `TJ` adjustments |
| `text-indent` | Y | Y | Y | Y | Y | Y | Y | lengths and percentages on the first formatted line |
| `text-transform` | Y | Y | Y | Y | Y | Y | Y | none, uppercase, lowercase, capitalize; locale-aware Unicode case mapping pending |
| `word-break` / `overflow-wrap` | Y | Y | Y | Y | Y | Y | Y | emergency UTF-8 codepoint wrapping for break-all, break-word, and anywhere; Unicode line segmentation pending |
| `white-space` | Y | Y | Y | Y | Y | Y | Y | normal, nowrap, pre, pre-wrap, pre-line |
| `text-align` | Y | Y | Y | Y | Y | Y | Y | left, center, right, justify |
| `text-decoration` | Y | Y | Y | Y | Y | Y | Y | underline and line-through |
| `box-sizing` | Y | Y | Y | Y | - | Y | Y | content-box and border-box |
| `border-collapse` | Y | Y | Y | Y | Y | Y | Y | table collapsed-border approximation |
| break before/after/inside | Y | Y | Y | Y | - | Y | Y | page/always/avoid aliases |
| `orphans` / `widows` | Y | Y | Y | Y | - | Y | Y | paragraph line constraints |
| `position` | Y | Y | Y | - | - | - | Y | only static renders; others fail clearly |
| `float` | Y | Y | Y | - | - | - | Y | only none renders; others fail clearly |
| selectors | Y | Y | - | - | - | - | Y | type, class, ID, universal, compound, descendant, child |
| `!important`, inheritance, source order | Y | Y | Y | - | - | - | Y | author origin and inline style ordering |
| supported shorthands | Y | Y | Y | - | - | - | Y | expanded to physical longhands before computed values |
| escaped CSS identifiers | Y | Y | Y | - | - | - | Y | simple and hexadecimal escapes, including leading-digit class names |
| CSS-wide keywords | Y | Y | Y | - | - | - | Y | `initial`, `inherit`, `unset`, `revert` |
| custom properties / `var()` | Y | Y | Y | - | - | - | Y | inherited scopes, nested fallback, cycle detection |
| browser pseudo-elements | Y | Y | Y | Y | Y | Y | Y | `::before`/`::after` strings and `attr()` become synthetic nodes; counters pending |
| browser media/viewport snapshot | Y | Y | Y | - | - | - | Y | deterministic viewport for strings, Elements, and refs; explicit `screen` or `print`; transitions/animations frozen |
| open Shadow DOM snapshot | Y | Y | Y | Y | Y | Y | Y | opt-in composed-tree flattening with slots |
| external stylesheet snapshot | Y | Y | Y | - | - | - | Y | HTML-string network access is mediated by `resourceResolver` and resource policy |

The machine-readable property inventory lives in
`src/css/properties.zig`. Structural snapshots, Zig tests, Node ABI tests, and
Playwright E2E make the matrix verifiable.

## Explicitly unsupported in the current profile

- non-color typed values such as angles, transforms, and images; group opacity
  and blend/compositing modes remain pending;
- generated counters and complex pseudo-element `content` values;
- Flexbox, Grid, floats, positioned/sticky layout, stacking contexts;
- multiple backgrounds, gradients, shadows, transforms, filters, and blend modes;
- complete Unicode shaping, bidi, ligatures, kerning, locale-aware case
  conversion, and Unicode line segmentation; fallback faces must currently be
  registered in the CSS family chain with their covered ranges;
- CSS Fragmentation fragmentainers, `@page`, named pages, and margin boxes.

These features are not silently represented as screenshots. Canvas and SVG
resources are captured as scoped image resources; normal text, links, borders,
and fills remain native PDF content.

Unsupported declarations found by the Zig/native path are returned through the
WASM result handle as owned structured diagnostics. Browser snapshots attach
the same diagnostic shape and honor `unsupportedCss: "warn" | "error" |
"ignore"`; subtree raster fallback is not enabled yet.

## Verification gates

- `make test` runs focused Zig parser, cascade, layout, pagination, display-list,
  and PDF tests.
- `make test-web-snapshots` checks stable WASM structural output and a real PDF
  result handle in Node.
- `make test-browser` runs the browser harness and mounted React-ref preview on
  Chromium, Firefox, and WebKit.
- `make test-baseline` regenerates the versioned PDF fixtures in memory and
  compares their SHA-256 digests with the committed visual baseline manifest.
- `make test-release` runs all of the above plus package and React builds.
