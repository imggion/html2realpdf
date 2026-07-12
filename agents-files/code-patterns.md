# Code Patterns

## Structure and readability

- Prefer explicit Zig state transitions and small phase-specific helpers.
- Preserve flat `NodeId`, `BoxId`, and fragment arrays; do not introduce
  recursively owned child arrays.
- Keep continuous layout separate from pagination and painting.
- Keep facade imports stable: add CSS behavior to the owning `src/css/` phase,
  layout algorithms to the owning `src/layout/` formatting context, and paint
  behavior to `src/paint/`.
- Use `//!` for module intent and `///` for ownership, lifetime, phase, or
  non-obvious compatibility contracts. Do not narrate obvious function names.
- Extract shared code only when it removes real duplication and keeps control
  flow easier to read.

## Allocation and ownership

- Pass allocators explicitly. Use one render-scoped arena for intermediary
  trees/fragments and duplicate only final PDF bytes into the output allocator.
- TTF registrations in a WASM context must copy family, PostScript name, and
  font data and release them in `pdf_context_free`.
- Every nonzero PDF result handle must remain inspectable, including failures,
  and must release bytes/error text in `pdf_result_free`.
- JavaScript must copy `memory.buffer` slices before freeing handles or making
  calls that may grow WASM memory.

## Renderer behavior

- CSS layout-critical features outside the report profile should fail clearly;
  cosmetic omissions should produce diagnostics and respect strict mode.
- Use the same resolved TTF metrics for line layout and PDF glyph encoding.
- Keep shaped glyph IDs, font-unit advances/offsets, direction, and UTF-8
  cluster ranges intact from inline layout through PDF output. Complex runs use
  explicit PDF positioning plus `ActualText`; conflicting glyph/Unicode pairs
  receive custom CIDs and a `CIDToGIDMap` instead of corrupting `ToUnicode`.
- Apply CSS case conversion before measurement with the generated Unicode 17
  full mappings. Preserve inherited HTML `lang` on boxes so Lithuanian and
  Turkic `SpecialCasing.txt` rules remain deterministic in native and WASM runs.
- Preserve identity shaping for the document profile and enable HarfBuzz for
  web/strict only. Resolve SheenBidi levels for the whole formatted line before
  applying L2, then use libunibreak UAX #14 opportunities and extended grapheme
  boundaries before CSS emergency wrapping so combining and ZWJ sequences stay
  intact. Keep these Unicode engines in web/strict so legacy PDF baselines
  remain byte-stable.
- Keep `word-spacing` in fragment/display-list text state and emit it as `TJ`
  adjustments. PDF `Tw` does not reliably match U+0020 in two-byte Type 0 fonts.
- Finalize clipping at the block-layout boundary after the used height is known.
  Clip descendants at the padding edge, intersect nested `clip_rect` values,
  translate them during pagination, and attach them to every paint command.
- Wrap each clipped PDF command in its own `q`/`Q` graphics state so a clip cannot
  leak into sibling content. Keep an ellipsis as selectable U+2026 text.
- Reset non-inherited `vertical-align` when creating text boxes; the inline
  cursor propagates an inline ancestor's alignment deliberately, while table
  cell vertical alignment belongs to the table formatting context.
- Treat replaced elements and inline-blocks as atomic baseline groups. Shift
  every descendant fragment together and preserve image/clip insets whenever
  horizontal or vertical line alignment moves the group.
- Preserve text as CID TrueType text with `ToUnicode`; never replace a page with
  a screenshot.
- Keep images as separate XObjects. JPEG stays pass-through; PNG alpha uses an
  `/SMask`.
- Preserve intrinsic image dimensions across the browser snapshot boundary.
  Replaced-element sizing belongs in `layout/intrinsic.zig`; object fitting is
  a clipped display/PDF image transform, not a pre-rasterized canvas rewrite.
- Preserve supported SVG as a base64 SVG resource and validate it again in
  `src/svg.zig`; emit a unit-square PDF Form XObject so normal replaced-element
  sizing and clipping still apply. Unsupported SVG is rejected by default; an
  explicit `rasterize-subtree` policy may rasterize only that SVG and must
  carry a structured fallback diagnostic.
- Keep page-break compatibility as injected CSS rules, not DOM-position hacks.
- Resolve table column and cell width hints plus min/max-content contributions
  before cell layout. Percentage widths are relative to the table, and cells
  fill the final track or colspan width exactly. Captions remain separate table
  roles and row-spanning vertical alignment waits for the final spanned height.
- Measure Web `<tfoot>` rows in a rollback-only table pass, reserve that extent
  through the real page fragmentainer, and clone header/footer fragments with
  their clip and image geometry. Do not shorten the fragmentainer cadence to
  simulate a footer.
- Keep flex item measurement, line construction, flexible-length freezing,
  Box Alignment, auto-margin distribution, and page-boundary advancement in
  `layout/flex.zig`. Block layout may assign the flex container's content box,
  but must not absorb flex-axis algorithms.
- Keep Grid templates as computed-style inputs and parse them into render-local
  flat tracks in `layout/grid.zig`. Placement must complete before intrinsic and
  `fr` sizing; row fragmentation may shift track positions but must not rebuild
  the Box Tree or convert cells into recursive owned arrays.
- Keep float exclusion and `clear` geometry in `layout/floats.zig`; block layout
  owns sibling traversal, shrink-to-fit calls, and fragment placement. Document
  profile still rejects non-none floats so its baselines remain stable.
- Keep absolute and fixed descendants out of normal-flow cursor advancement.
  Queue them during their owning formatting context, then resolve containing
  blocks, insets, and tree-derived paint phases in `layout/positioned.zig`;
  repeat fixed fragments only when continuous fragments are mapped to pages.
- Preserve authored inset sides when freezing browser computed styles. Browser
  used values may synthesize `top` from an authored `bottom` (or `left` from
  `right`), and those viewport-relative values must not reach page layout.
- Keep CSS transforms paint-only: layout and pagination opportunities use the
  untransformed box geometry, `positioned.zig` composes ancestor matrices, and
  the PDF backend performs the CSS-downward-Y to PDF-upward-Y conjugation.
  Track an ancestor overflow clip's matrix separately from a transformed
  descendant's content matrix so child transforms never distort the parent clip.
- Keep element opacity as an explicit box-ID path through layout and display
  commands. The PDF backend must composite each path component once as an
  isolated transparency Form XObject; multiplying alpha into every descendant
  changes overlap colors and is not CSS opacity.
- Paint CSS background layers back-to-front, cycle shorter size/position/repeat
  lists per CSS list matching, and clip every layer to the rounded border box.
  Opaque gradients use PDF shadings; varying-alpha gradients remain native
  non-overlapping vector bands rather than rasterizing the subtree.

## JavaScript package

- Imports must remain SSR-safe; browser requirements are checked when creating
  a renderer or rendering.
- Worker execution is the default. Main-thread execution is an explicit option.
- DOM/ref snapshots must not mutate the source element, must remove active
  content/event attributes, and must materialize computed styles, form state,
  canvas, and async resources.
- Resolve CSS counter scopes while traversing the live browser tree and emit
  `counter()`/`counters()` output as synthetic selectable text. Do not carry
  browser-only generated-content state into Zig layout or PDF painting.
- Keep `box-decoration-break` intent on layout fragments and let pagination
  decide which block-start/block-end borders survive. Web/strict distinguish
  `slice` from `clone`; document keeps its byte-compatible repeated borders.
- Route all page boundary, remaining-extent, facing-page, forced/avoid, and
  propagation decisions through `layout/fragmentation.zig`. Formatting
  contexts expose their real break opportunities but do not duplicate page
  modulo arithmetic.
- Resolve Web vertical margins as positive/negative struts before placing block
  geometry. Empty blocks may propagate a strut; padding, borders, clearance,
  overflow BFCs, floats, and positioned boxes terminate the eligible group.
- Preview pages must render inside the target element as isolated canvas pages;
  do not reintroduce iframe, object, embed, or browser-plugin preview paths.
- The browser harness must resolve the package through the generated hashed
  runtime manifest so nested ESM modules cannot survive a rebuild from cache.
- `PdfDocument.dispose()` owns previews created from that document. Preview
  controls must retain keyboard focus states and 44px touch targets.
- The default export should preserve common html2pdf.js PDF chains while
  rejecting raster-only stages explicitly.

## Validation

- `zig fmt --check build.zig src/*.zig`
- `make test-wpt`
- `make test-robustness`
- `make test`
- `npm --prefix bindings/js test`
- `node tests/web/verify_snapshots.mjs`
- Browser harness checks pass, including complex fixtures and embedded preview,
  and download is wired.
- `make test-browser` passes native layout, diagnostics, CSS ecosystem, and
  React-ref slices on Chromium, Firefox, and WebKit.
- `make test-baseline` preserves page counts and deterministic PDF SHA-256 values.
- For PDF changes, run `tests/render_pdf_fixture.mjs`, `pdfinfo`, `pdffonts`,
  `pdftotext`, Poppler rendering, and visually inspect the page PNG.
