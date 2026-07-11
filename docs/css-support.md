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
- **strict** is planned as a diagnostic policy, not a separate layout engine.

## Reading the matrix

`P` parsed, `C` cascaded, `V` computed value, `L` laid out, `Paint` emitted to
the display list/PDF, `Page` participates in pagination, and `T` has automated
coverage. A dash means the stage is not applicable or not implemented.

| Property or group | P | C | V | L | Paint | Page | T | Current limit |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| `display` | Y | Y | Y | Y | - | Y | Y | block, inline, inline-block, and table roles |
| width/height/min/max | Y | Y | Y | Y | - | Y | Y | px, %, absolute units, em/rem, auto |
| margin/padding | Y | Y | Y | Y | Y | Y | Y | four physical sides; adjacent block margin collapse |
| borders | Y | Y | Y | Y | Y | Y | Y | physical sides; solid, dashed, dotted |
| `border-radius` | Y | Y | Y | Y | Y | Y | Y | one uniform circular radius |
| color/background color | Y | Y | Y | Y | Y | Y | Y | named and hexadecimal colors; no alpha cascade yet |
| font family/size/weight/style | Y | Y | Y | Y | Y | Y | Y | built-in Noto Sans and registered TTF faces |
| line height/letter spacing | Y | Y | Y | Y | Y | Y | Y | no shaping, kerning, or per-glyph fallback yet |
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

The machine-readable property inventory lives in
`src/css/properties.zig`. Structural snapshots, Zig tests, Node ABI tests, and
Playwright E2E make the matrix verifiable.

## Explicitly unsupported in the current profile

- custom properties and `var()`;
- `calc()`, `min()`, `max()`, `clamp()`, viewport units, and typed alpha;
- pseudo-elements and generated content;
- Flexbox, Grid, floats, positioned/sticky layout, stacking contexts;
- multiple backgrounds, gradients, shadows, transforms, filters, and blend modes;
- complete Unicode shaping, bidi, ligatures, and per-glyph font fallback;
- CSS Fragmentation fragmentainers, `@page`, named pages, and margin boxes.

These features are not silently represented as screenshots. Canvas and SVG
resources are captured as scoped image resources; normal text, links, borders,
and fills remain native PDF content.

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

