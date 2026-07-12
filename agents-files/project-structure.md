# Project Structure

## Product and stack

`html2realpdf` is a report-oriented HTML-to-PDF engine written in Zig `0.16.0`
and compiled to native code and `wasm32-freestanding`. The public browser
package is ESM TypeScript under `bindings/js/`; it has no runtime dependency or
framework dependency.

## Runtime pipeline

1. `src/html.zig` tokenizes borrowed HTML bytes.
2. `src/dom.zig` builds a tolerant flat DOM and owns decoded entities.
3. `src/css.zig` is the stable facade over syntax, selector, typed value,
   expression, custom-property, shorthand-expansion, computed-style, cascade,
   and property-inventory modules in `src/css/`.
4. `src/box.zig` creates and normalizes a flat Box Tree.
5. `src/font.zig` resolves TTF faces per codepoint (including built-in
   Arabic/Hebrew and registered Unicode-range fallback), reads metrics, and
   subsets glyphs; `src/harfbuzz.zig` shapes web/strict text through the pinned
   backend shared by native and freestanding WASM.
6. `src/bidi.zig`, `src/line_break.zig`, and `src/unicode_case.zig` expose renderer-owned UAX #9 levels, UAX #14/UAX #29 boundaries, and generated Unicode 17 full case mappings.
7. `src/layout.zig` coordinates continuous fragments while `src/layout/` owns block, inline, table, float, flex, grid, positioned, intrinsic, and fragmentation algorithms plus explicit future formatting-context boundaries. `layout/page_geometry.zig` owns typed page boxes, page-selector cascade, named-page sequences, and explicit forced-blank indices; `layout/fragmentation.zig` consumes those sequences as the shared variable-height page-fragmentainer model for boundary geometry, page sides, adjacent break arbitration, propagation, atomic placement, page-aware inline extents, and page-end reservations. Auto-width initial-containing-block descendants retain physical page insets on flat fragments so pagination can resolve every split box against its own page width, while inline cursors rewrap at page-specific widths. Block, inline, table, Flex, and Grid call the shared context instead of owning page modulo arithmetic. `layout/intrinsic.zig` exposes min/max-content measurement before containing-block assignment; table auto layout consumes those contributions together with column groups and cell hints before laying out captions, rows, and spanning cells, and its rollback measurement reserves repeated `<tfoot>` groups while `<thead>` remains repeated at page starts. `layout/floats.zig` owns side exclusion bands and clearance geometry for Web/strict block formatting contexts. `layout/flex.zig` owns order-modified items, line construction, flexible-length resolution, Box Alignment, auto margins, and fragmentainer-aware break opportunities. `layout/grid.zig` parses render-local track definitions, resolves explicit/implicit placement and intrinsic/flexible track sizes, applies Grid alignment, and fragments intact rows through the shared context. `layout/positioned.zig` collects out-of-flow descendants, resolves positioned padding containing blocks and insets, and derives tree-based paint metadata including cumulative 2D transforms, ancestor clip transform spaces, and nested opacity-group paths; `pagination.zig` snapshots fixed templates before repeating them and translates affine coordinate systems into page-local space. Web/strict block layout propagates an optional definite containing height separately from rectangular geometry so content-sized axes cannot be mistaken for a real zero height.
8. `src/pagination.zig` maps fragments to coordinates in the per-page `PageSpec` sequence shared with layout and consumed by the display list and PDF backend. `src/paged_media.zig` selects default/named/pseudo `@page` margin templates after page names, blank state, and final page count are known, then appends selectable counter text without changing content flow.
9. `src/display_list.zig` coordinates backend-neutral paint commands implemented under `src/paint/`; `backgrounds.zig` resolves layered image/gradient tiles and `effects.zig` owns shadow paint.
10. `src/svg.zig` independently validates and lowers the browser-approved SVG
    subset, including shapes/paths, selectable text/tspan, bounded linear and
    radial gradient fills, local clip paths, path arcs, and affine transforms.
11. `src/pdf.zig` writes compressed PDF 1.7 objects and xref data, including affine `cm` operators, axial/radial/mesh shadings, vector alpha-gradient bands, SVG and isolated-transparency Form XObjects, transformed clip paths, and transformed link bounds.
12. `src/render.zig` owns one complete native render lifetime.
13. `src/diagnostics.zig` defines structured phase-aware diagnostics shared by
    the native renderer and ABI.
14. `src/wasm.zig` exposes ABI v1 contexts and independent result handles.
15. `bindings/js/src/` snapshots browser input in an inert, deterministic
    media/viewport environment (with resolver-controlled stylesheets), resolves
    default and selected `@page` geometry into typed rules, and runs WASM in a
    Worker by default, returning `PdfDocument`. Its optional `canvasToSvg`
    bridge materializes live canvases in DOM order before SVG validation.

The local browser harness loads the package through a generated content-addressed
runtime under `bindings/js/.browser-build/`; `manifest.json` binds one JS module
graph to the exact WASM bytes produced by the same build.

`build.zig` creates the native executable and WASM artifact and compiles pinned
HarfBuzz `HB_TINY`, SheenBidi, and libunibreak objects for both targets. Noto
Sans TTF assets are embedded from `src/assets/fonts`.
Project and third-party license notices are consolidated in `LICENSE.md`; the
browser package build copies that file to `dist/LICENSE.md`.

## Ownership boundaries

- Token slices normally borrow the input; DOM-decoded entities are documented
  owned strings.
- Box/layout/display objects live for one render arena.
- Returned PDF bytes use the caller/output allocator.
- WASM contexts own registered fonts. Each PDF result owns bytes, error text,
  and serialized diagnostics until `pdf_result_free`; JavaScript copies them
  before freeing the handle.
- `PdfDocument.dispose()` revokes all object URLs; renderer disposal terminates
  the Worker or releases the main-thread WASM context.

## Tests

- `make test` runs every focused Zig module test, the pinned renderer-native WPT subset, deterministic parser/resource/large-document robustness gates, Unicode case mapping, and linked HarfBuzz, bidi, and line-break gates.
- `make test-wpt` isolates the three upstream scenarios documented in
  `tests/wpt/README.md`; `make test-robustness` runs its 512-case mutation corpus
  and resource gates in `ReleaseSafe`.
- `make test-harfbuzz` isolates the native OpenType shaping test.
- `npm --prefix bindings/js test` rebuilds WASM, type-checks TypeScript, and
  runs package/ABI tests including custom TTF registration.
- `node tests/web/verify_snapshots.mjs` verifies structural dumps and real PDF
  output in Node.
- `tests/web/index.html` is the interactive browser harness for snapshots,
  complex invoice/report generation, embedded canvas preview, download,
  DOM/ref rendering, deterministic media/viewport selection, open Shadow DOM,
  pseudo-elements, SVG charts, canvas-to-SVG charts, canvas alpha, rounded tables, and A4 landscape
  presentation-style PDFs.
- `tests/react/` is an isolated Vite/React application that exercises a mounted
  component ref, controlled state, computed styles, tables, SVG, and canvas.
- `make test-react` builds the React fixture; `make test-release` runs the full
  Zig, package, snapshot, cross-browser, React, and PDF baseline gate.
- `make test-browser` runs the browser harness and built React-ref fixture in
  Chromium, Firefox, and WebKit, including compiled CSS Modules,
  styled-components, and Tailwind-style selector fixtures.
- `make baseline` captures the document-profile PDFs and first-page Poppler
  images; `make test-baseline` rejects byte-level renderer regressions.
