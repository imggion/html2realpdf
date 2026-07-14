# Agent Guide

This is the entry point for future coding agents working on `html2realpdf`.

Read these local docs before changing code:

- `agents-files/README.md` explains the agent documentation set.
- `agents-files/project-structure.md` describes the runtime flow, package layout, and core technologies.
- `agents-files/file-tree.md` gives a high-signal repository map.
- `agents-files/where-things-live.md` explains where new code should go.
- `agents-files/code-patterns.md` captures repo-specific coding patterns and maintainability rules.

## Repo Summary

- Zig/WebAssembly HTML-to-real-PDF renderer named `html2realpdf`; the pipeline now includes tokenizer, tolerant flat DOM, CSS cascade, flat Box Tree, HarfBuzz OpenType shaping, SheenBidi UAX #9, libunibreak UAX #14 for web/strict, layout, pagination, display list, TrueType font handling, image resources, PDF 1.7 output, and a typed npm wrapper.
- Zig version is `0.16.0`; use the 0.16 docs: https://ziglang.org/documentation/0.16.0/ and stdlib docs: https://ziglang.org/documentation/0.16.0/std/.
- Active renderer source lives in `src/`; the npm package lives in `bindings/js/`; browser and snapshot verification live in `tests/web/`; the real React-ref integration fixture lives in `tests/react/`.
- `build.zig` defines the native executable from `src/main.zig`, the package/root module from `src/root.zig`, and the wasm executable from `src/wasm.zig`; reusable parser/tree modules are exported from `src/root.zig`.
- `tests/web/` covers structural dumps plus real PDF generation, the embedded canvas viewer, complex invoice/report fixtures, download, DOM/ref rendering, SVG charts, transparent canvas resources, and the interactive `html2pdf.js` comparison.
- `tests/benchmark/` owns shared timing, download-artifact, and PDF.js content-classification helpers plus the deterministic 30-page mixed-content stress report used by both native HTML and React benchmark surfaces.
- `tests/web/e2e/` runs the browser harness and built React fixture through Playwright on Chromium, Firefox, and WebKit.
- `.github/workflows/ci.yml` only runs the complete release gate for pull requests into `main` and pushes to `main`; it never retains or uploads an npm release artifact and never publishes. `.github/workflows/prepare-npm-artifact.yml` manually builds and stores the tarball for an explicit release tag. `.github/workflows/publish-npm.yml` is a separate manual step that validates and publishes that prepared artifact. Tag pushes do not trigger any workflow.
- `src/wpt_subset_test.zig` adapts three pinned upstream Web Platform Test scenarios into renderer-native geometry assertions; `src/robustness_test.zig` owns deterministic malformed-input, allocation-exhaustion, and large-document gates.
- `docs/css-support.md` is the public, versioned CSS support contract; `src/css/properties.zig` is its machine-readable property inventory.
- `src/layout/page_geometry.zig` owns typed page boxes, page-selector cascade, and named-page sequences. `src/layout/fragmentation.zig` consumes those sequences for variable-height page boundaries, facing-page resolution, break arbitration, and block-child propagation. Block, inline, table, Flex, and Grid formatters must use that shared fragmentainer model instead of duplicating modulo arithmetic.
- `src/paged_media.zig` selects default/named/pseudo `@page` margin-box text only after pagination establishes page names, forced blank pages, and the final page count. Keep selector matching, page counters, margin-slot geometry, and generated text commands there; do not synthesize DOM boxes or consume content flow.
- Web table fragmentation measures `<tfoot>` groups before final placement, reserves their page-end extent, and repeats both `<thead>` and `<tfoot>` only on pages occupied by the table. Keep the rollback measurement scoped to table fragments, positioned descendants, and line identifiers.
- Browser snapshots must preserve which positioned inset sides were authored; computed `top`/`left` used values derived from `bottom`/`right` cannot be reinterpreted against PDF page geometry. Pagination copies fixed templates before appending repeats so array reallocation cannot drop later fixed furniture.
- `tests/baselines/0.1.0-alpha.0/` freezes deterministic PDFs, first-page Poppler PNGs, metrics, and digests from the document profile.
- Rounded box painting and clipping preserve independently resolved elliptical radii for every corner through layout, display-list commands, and native PDF Bézier paths.
- Preserve `clip_rect`, elliptical clip radii, and clip transforms through pagination and every display-list command, and isolate each PDF clip with `q`/`Q`.
- Replaced elements preserve browser-captured intrinsic dimensions. Resolve their used size from CSS width/height and `aspect-ratio`, then apply `object-fit`/`object-position` as a clipped native PDF image transform.
- Inline CSS Text support includes percentage `text-indent`, ASCII case transforms, emergency codepoint wrapping, mixed-font baseline alignment, `vertical-align`, and `word-spacing`; preserve word spacing through fragment/display-list state and PDF Type 0 `TJ` adjustments so geometry and selectable text remain aligned.
- Text decorations retain combined line flags, color, thickness, and style through layout; double and wavy decorations remain vector stroke commands rather than raster effects.
- The browser fixture set includes portrait reports and an A4 landscape presentation deck; keep both available from `tests/web/index.html` and in automated browser verification.
- Browser pseudo-element snapshots resolve nested CSS counters before emitting synthetic text nodes; keep counter scope traversal in `bindings/js/src/snapshot.ts` rather than teaching the PDF core browser-only generated-content state.
- `tests/react/` is an isolated Vite app that passes a mounted `forwardRef` report, controlled state, tables, SVG, and live canvas pixels through the public package API.
- The browser package is framework-agnostic; React refs are supported structurally without a React dependency.
- Supported inline SVG shapes/paths, selectable text/tspan, bounded linear and
  radial gradient fills, and local clip paths remain vector through
  `src/svg.zig` and PDF Form XObjects. The optional browser `canvasToSvg` bridge
  sends live canvas chart exports through the same validation boundary.
  Unsupported SVG is rejected by default and rasterizes only its subtree with a
  structured diagnostic after explicit `fallback: "rasterize-subtree"` opt-in;
  canvas adapter fallback likewise requires `canvasFallback: "rasterize"`.
- Browser rendering resolves default, named, and `:first`/`:left`/`:right`/`:blank`
  `@page` geometry through a typed page-rule cascade unless explicit API page
  options override it. Pagination, display-list commands, and PDF coordinate
  conversion carry a per-page `PageSpec`; layout fragmentainers consume the
  same sequence for variable-height boundaries, auto-width block sizing, and
  page-aware inline wrapping. Forced facing-page gaps are explicit blank pages,
  and generated margin text selects default/named/pseudo templates per page.
- Browser snapshots support deterministic screen/print media, explicit viewports, computed pseudo-elements, and opt-in open Shadow DOM flattening; native/WASM warnings use owned structured diagnostics.
- Browser snapshots may omit computed values only when they exactly match the native initial value for that element or a parent value that the native cascade inherits. Preserve browser resets that override renderer UA defaults, and keep resolved pagination values explicit because browser-only selectors can override an authored forced break.
- HTML-string stylesheets are inert and must resolve through `resourceResolver`; Element/ref alternate-media snapshots preserve ancestor selectors, live controls, canvas pixels, and open shadow roots.
- CSS rgba/hex-alpha colors remain native vectors and use PDF ExtGState rather than flattening; supported shorthands expand into physical longhands before computed-value application.
- Registered font families may declare Unicode ranges; inline layout resolves and measures fallback per codepoint, then emits distinct selectable PDF text runs for each resolved face.
- Web/strict typography carries HarfBuzz glyph advances, offsets, direction, and UTF-8 clusters through layout and PDF. Built-in Arabic and Hebrew fallback faces are available; the document profile retains identity shaping for byte-stable baselines.
- Web/strict inline layout resolves whole-line bidi levels with SheenBidi before L2 visual reordering and uses libunibreak opportunities before CSS emergency wrapping; keep measurement and the shaped PDF run on the same text slice.
- `tests/assets/fonts/Html2RealPdfEmojiFixture.ttf` is the registered-fallback canary; regenerate it only through `scripts/build_emoji_fixture.sh` so its source and output checksums remain reproducible.
- Keep project and bundled third-party license texts consolidated in
  `LICENSE.md`; the browser build must copy the same file to `dist/LICENSE.md`.

## Commands

- `zig build` builds the default native executable into `zig-out/bin/html2realpdf`.
- `zig build run` runs the native CLI target.
- `zig build wasm -Doptimize=ReleaseFast` builds the default performance-oriented WASM; `make wasm` additionally rebuilds the typed bindings and content-addressed browser runtime used by `tests/web/`. Use `make wasm-small` or `npm --prefix bindings/js run build:small` only for the optional size-oriented `ReleaseSmall` asset.
- `zig test src/html.zig` runs the current inline tokenizer tests.
- `zig test src/dom.zig` runs the current inline DOM parser tests.
- `zig test src/box.zig` runs the current inline Box Tree tests.
- `zig test src/paged_media.zig` verifies margin-box slot geometry and page-counter expansion.
- `zig test src/render.zig` runs the complete renderer/PDF pipeline tests.
- `zig test src/unicode_case.zig` verifies Unicode 17 full and language-sensitive case mappings.
- `make test-wpt` runs the pinned renderer-native WPT subset.
- `make test-robustness` runs the deterministic parser mutation corpus, allocation-exhaustion behavior, and a 30-plus-page native PDF gate in `ReleaseSafe`.
- `make test-verbose` runs `make test` with non-TTY output so direct Zig test
  invocations retain one `OK`, `SKIP`, or `FAIL` line per test; build-system
  test targets may still report aggregate results.
- `npm --prefix bindings/js test` builds the WASM/package and runs the Node package tests.
- `make test-package-consumer` packs and installs the npm artifact, type-checks
  Bundler/NodeNext consumers, Vite-builds it, and browser-smokes default assets.
- `node tests/web/verify_snapshots.mjs` verifies WASM structural snapshots and PDF handles.
- `make test-react` builds the React integration fixture; `make react` starts its Vite development server after rebuilding WASM and bindings.
- `make test-browser` runs the browser harness and mounted React-ref preview on Chromium, Firefox, and WebKit.
- The Chromium browser gate also benchmarks both engines from the native harness and mounted React ref, verifies native/selectable versus raster PDF classification, checks the shared stress report is exactly 30 pages, and checks automatic plus individual downloads without asserting machine-specific timings.
- `make baseline` intentionally regenerates versioned PDF/PNG baselines; `make test-baseline` checks current PDF bytes against their digests.
- `make test-release` runs Zig, package, React-build, snapshot, browser E2E, and PDF baseline suites.
- `NPM_TOKEN=... make deploy` is the explicit local npm publication fallback. It
  builds through the package `prepack` lifecycle, publishes prereleases with
  `next` and stable versions with `latest`, and disables provenance because the
  local shell does not provide GitHub Actions OIDC identity.
- `make test-harfbuzz` runs the native linked OpenType shaping gate; it is also part of `make test`.
- `make test-bidi` and `make test-line-break` run the linked Unicode engines and the production-mode inline-layout gate; both are part of `make test`.
- `zig fmt --check build.zig src/*.zig src/css/*.zig src/layout/*.zig src/paint/*.zig` checks Zig formatting.
- `make debug`, `make release`, `make deploy`, `make wasm`, `make wasm-small`, `make run`, `make react`, `make test`, `make test-verbose`, `make test-react`, and `make clean` wrap common commands.
- `make test-debug-tokenizer` prints a tokenizer dump through the debug-only tokenizer test.
- `make test-debug-dom` prints a DOM ASCII tree through the debug-only DOM test.
- `make test-debug-box` prints a Box Tree ASCII tree with styles through the debug-only Box Tree test.
- `make test-debug` runs all debug dump targets.
- `node --test .github/scripts/resolve-release-tag.test.mjs` verifies release-tag ordering and deploy guards.

## Style Rules

- Prefer small, explicit changes that fit the current Zig module layout.
- Keep tokenizer and parsing control flow readable; avoid nested ternaries, clever state shortcuts, and giant multi-purpose functions when a local helper or state branch would be clearer.
- Keep Box Tree construction in `src/box.zig`; use flat `BoxId` links like `dom.NodeId` instead of recursive owned child arrays.
- Keep continuous layout, pagination, display-list generation, and PDF serialization in their focused modules; do not merge phase ownership into `box.zig` or `wasm.zig`.
- Keep `src/css.zig` and `src/layout.zig` as stable facades. Parser/value/cascade work belongs under `src/css/`; block/inline/table/intrinsic algorithms belong under `src/layout/`.
- Keep paint command types and phase logic under `src/paint/`; `src/display_list.zig` coordinates stable document-order painting.
- Resolve table-cell percentage widths into column tracks before cell layout; once a track is assigned, the cell must fill it instead of resolving its percentage again inside that track.
- Keep `text-overflow: ellipsis` as a real U+2026 text fragment so it remains selectable and participates in registered-font fallback; do not paint it as a path or image.
- Preserve the result-handle/context ownership contract in `src/wasm.zig` and ABI version checks in `bindings/js/src/wasm.ts`.
- Keep PDF preview rendering in `bindings/js/src/preview.ts`; it must remain an in-page canvas component and must not fall back to iframe/object browser PDF plugins.
- Keep `bindings/js/.browser-build/manifest.json` content-addressed through `prepare-browser-build.mjs`; the test harness must not import mutable unversioned `dist/*.js` modules.
- Keep `skills/html2realpdf/` and `bindings/js/skills/html2realpdf/`
  byte-identical; the former is the repository skill and the latter ships in
  the npm tarball.
- Serve the built React fixture in Playwright. Vite dev mode exposes raw PDF.js worker modules and is not the release integration path.
- Use Zig doc comments deliberately: `//!` for module intent and `///` for exported types/functions or private helpers with non-obvious tradeoffs.
- Documentation should explain why a shape exists, ownership/lifetime constraints, or phase boundaries; do not restate obvious names like `toString` returning a string.
- Keep public TypeScript bindings documented with concise English TSDoc that records defaults, precedence, lifecycle, ownership, and fallback behavior; comment internal helpers only for non-obvious contracts.
- Cache identical browser-snapshot inline declaration blocks per render instead of reparsing them per node; cached declarations must borrow render-arena memory and preserve normal/important cascade ordering.
- Keep doc examples tiny and only when they make usage faster to understand.
- Use DRY deliberately; extract shared logic only when duplication is real and the abstraction improves readability.
- Preserve clear runtime boundaries between native CLI code, reusable tokenizer/library code, and WASM exports.
- Do not introduce frameworks, package managers, aliases, or custom patterns unless the repository has a concrete need for them.

## Maintenance Rule

Update this file and the relevant file under `agents-files/` whenever build steps, entrypoints, module boundaries, tests, or repository conventions change.
