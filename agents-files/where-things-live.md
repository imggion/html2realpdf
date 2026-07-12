# Where Things Live

- HTML token behavior belongs in `src/html.zig`; tolerant tree recovery and
  entity ownership belong in `src/dom.zig`.
- `src/css.zig` is the public facade. Syntax parsing belongs in
  `src/css/syntax.zig`, selector matching in `selectors.zig`, typed parsing in
  `values.zig`, flat math ASTs in `expressions.zig`, inherited custom-property
  scopes in `variables.zig`, pre-computed shorthand expansion in
  `shorthands.zig`, longhand application in `computed.zig`, and
  ordering/inheritance in `cascade.zig`.
- Structural box normalization and style inputs belong in `src/box.zig`.
- `src/layout.zig` coordinates render-scoped state. Formatting-context logic belongs in `src/layout/block.zig`, `inline.zig`, `table.zig`, `flex.zig`, `grid.zig`, and `positioned.zig`; shared measurement belongs in `intrinsic.zig`. Grid track parsing, placement, sizing, alignment, and row fragmentation belong in `grid.zig`. Repeated table header/footer measurement and page-end reservation belong in `table.zig` plus the shared fragmentainer. Out-of-flow collection, containing-block resolution, tree-derived paint order, and cumulative transform metadata belong in `positioned.zig`; fixed-page replication and page-local transform translation belong in `src/pagination.zig`. Do not put either into the Box Tree builder.
- Page selector matching, per-page geometry cascade, and named-page sequences
  belong in `src/layout/page_geometry.zig`; layout consumes their content
  extents through `src/layout/fragmentation.zig`, while `src/pagination.zig`
  maps continuous fragments into the same sequence. Default/named/pseudo
  `@page` margin-box selection, page counter expansion, and margin-slot text commands belong in `src/paged_media.zig`
  after pagination. Browser rule capture belongs in
  `bindings/js/src/snapshot.ts`, and the WASM JSON boundary must keep those
  page rules typed rather than serializing CSS text into the core.
- TTF parsing, embedding permission checks, resolution, metrics, and subsetting
  belong in `src/font.zig`; the minimal C ABI, custom freestanding allocator,
  cluster conversion, and HarfBuzz calls belong in `src/harfbuzz.zig`.
- UAX #9 paragraph/line ownership belongs in `src/bidi.zig`; UAX #14 break
  opportunities belong in `src/line_break.zig`. CSS line fitting and L2 fragment
  placement remain in `src/layout/inline.zig`.
- Unicode full case mapping and SpecialCasing context belong in
  `src/unicode_case.zig`; regenerate its pinned data only through
  `scripts/generate_unicode_case.py`.
- Backend-neutral paint phases belong under `src/paint/` and are coordinated by `src/display_list.zig`; layered background parsing/tiling belongs in `backgrounds.zig`, shadows and text effects belong in `effects.zig`, and affine transform primitives live in `src/geometry.zig`, while PDF syntax, shadings, transparency groups,
  object IDs, streams, xref, metadata, annotations, and font objects belong in
  `src/pdf.zig`.
- Rounded box intent starts as `border-radius` in `src/css.zig`, survives in
  layout fragments, becomes a rounded display-list command, and only then is
  serialized as a Bézier path by `src/pdf.zig`.
- JPEG/PNG decoding and reusable zlib helpers belong in `src/image.zig`.
  Independently validated SVG shape/path, text/tspan, gradient, clip-path, and
  arc lowering belong in `src/svg.zig`; PDF Form XObject serialization remains
  in `src/pdf.zig`. Browser canvas-to-SVG adapter orchestration belongs in
  `bindings/js/src/snapshot.ts`, never in the Zig image decoder.
- One-shot native orchestration belongs in `src/render.zig`; exported pointer,
  context, and result ownership belongs in `src/wasm.zig`.
- Cross-phase diagnostic shape and JSON serialization belong in
  `src/diagnostics.zig`; detection stays in the phase that owns the warning.
- Browser-facing types and API orchestration live in `bindings/js/src/types.ts`
  and `renderer.ts`; inert HTML, deterministic Element/ref environments,
  DOM/ref sanitization, Shadow DOM flattening, and resolver-controlled resources live in `snapshot.ts`;
  integrated PDF canvas preview lives in `preview.ts`; html2pdf.js compatibility
  lives in `compat.ts`; raw ABI glue lives in `wasm.ts` and `worker.ts`.
- Framework-agnostic interactive checks stay in `tests/web`; the real mounted
  React-ref fixture stays in `tests/react`; Node ABI/package tests stay in
  `bindings/js/test`; PDF render artifacts stay ignored under `tmp/pdfs`.
- Release browser checks live in `tests/web/e2e`; committed visual canaries and
  byte digests live under `tests/baselines/<version>/`.
- Renderer-native adaptations of pinned upstream WPT scenarios live in
  `src/wpt_subset_test.zig`, with revision and path provenance in
  `tests/wpt/README.md`. Cross-parser mutation, OOM, and large-document gates
  live in `src/robustness_test.zig`.
- The linked shaping gate lives in `src/harfbuzz_test.zig`; run it through
  `zig build test-harfbuzz` because direct `zig test` commands do not link C++
  objects. Bidi and line-break bridge gates live beside it and share the
  production-mode `src/bidi_integration.zig` layout gate.

There are no routes, application state stores, server services, or UI framework
components. Do not introduce such concepts for renderer-library work.
