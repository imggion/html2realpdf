# Agent Guide

This is the entry point for future coding agents working on `html2realpdf`.

Read these local docs before changing code:

- `agents-files/README.md` explains the agent documentation set.
- `agents-files/project-structure.md` describes the runtime flow, package layout, and core technologies.
- `agents-files/file-tree.md` gives a high-signal repository map.
- `agents-files/where-things-live.md` explains where new code should go.
- `agents-files/code-patterns.md` captures repo-specific coding patterns and maintainability rules.

## Repo Summary

- Zig/WebAssembly HTML-to-real-PDF renderer named `html2realpdf`; the pipeline now includes tokenizer, tolerant flat DOM, CSS cascade, flat Box Tree, layout, pagination, display list, TrueType font handling, image resources, PDF 1.7 output, and a typed npm wrapper.
- Zig version is `0.16.0`; use the 0.16 docs: https://ziglang.org/documentation/0.16.0/ and stdlib docs: https://ziglang.org/documentation/0.16.0/std/.
- Active renderer source lives in `src/`; the npm package lives in `bindings/js/`; browser and snapshot verification live in `tests/web/`; the real React-ref integration fixture lives in `tests/react/`.
- `build.zig` defines the native executable from `src/main.zig`, the package/root module from `src/root.zig`, and the wasm executable from `src/wasm.zig`; reusable parser/tree modules are exported from `src/root.zig`.
- `tests/web/` covers structural dumps plus real PDF generation, the embedded canvas viewer, complex invoice/report fixtures, download, DOM/ref rendering, SVG charts, and transparent canvas resources.
- `tests/web/e2e/` runs the browser harness and built React fixture through Playwright on Chromium, Firefox, and WebKit.
- `docs/css-support.md` is the public, versioned CSS support contract; `src/css/properties.zig` is its machine-readable property inventory.
- `tests/baselines/0.1.0-alpha.0/` freezes deterministic PDFs, first-page Poppler PNGs, metrics, and digests from the document profile.
- Rounded box painting uses a uniform `border-radius` propagated through layout and display-list commands into native PDF Bézier paths; keep per-corner and clipping behavior out until tested explicitly.
- Overflow clipping is rectangular at the padding edge. Preserve `clip_rect` through pagination and every display-list command, and isolate each PDF clip with `q`/`Q`; rounded clipping remains pending.
- Replaced elements preserve browser-captured intrinsic dimensions. Resolve their used size from CSS width/height and `aspect-ratio`, then apply `object-fit`/`object-position` as a clipped native PDF image transform.
- Inline CSS Text support includes percentage `text-indent`, ASCII case transforms, emergency codepoint wrapping, mixed-font baseline alignment, `vertical-align`, and `word-spacing`; preserve word spacing through fragment/display-list state and PDF Type 0 `TJ` adjustments so geometry and selectable text remain aligned.
- Text decorations retain combined line flags, color, thickness, and style through layout; double and wavy decorations remain vector stroke commands rather than raster effects.
- The browser fixture set includes portrait reports and an A4 landscape presentation deck; keep both available from `tests/web/index.html` and in automated browser verification.
- Browser pseudo-element snapshots resolve nested CSS counters before emitting synthetic text nodes; keep counter scope traversal in `bindings/js/src/snapshot.ts` rather than teaching the PDF core browser-only generated-content state.
- `tests/react/` is an isolated Vite app that passes a mounted `forwardRef` report, controlled state, tables, SVG, and live canvas pixels through the public package API.
- The browser package is framework-agnostic; React refs are supported structurally without a React dependency.
- Browser snapshots support deterministic screen/print media, explicit viewports, computed pseudo-elements, and opt-in open Shadow DOM flattening; native/WASM warnings use owned structured diagnostics.
- HTML-string stylesheets are inert and must resolve through `resourceResolver`; Element/ref alternate-media snapshots preserve ancestor selectors, live controls, canvas pixels, and open shadow roots.
- CSS rgba/hex-alpha colors remain native vectors and use PDF ExtGState rather than flattening; supported shorthands expand into physical longhands before computed-value application.
- Registered font families may declare Unicode ranges; inline layout resolves and measures fallback per codepoint, then emits distinct selectable PDF text runs for each resolved face.

## Commands

- `zig build` builds the default native executable into `zig-out/bin/html2realpdf`.
- `zig build run` runs the native CLI target.
- `zig build wasm -Doptimize=ReleaseSmall` builds only `zig-out/bin/libhtml2realpdf.wasm`; `make wasm` additionally rebuilds the typed bindings and content-addressed browser runtime used by `tests/web/`.
- `zig test src/html.zig` runs the current inline tokenizer tests.
- `zig test src/dom.zig` runs the current inline DOM parser tests.
- `zig test src/box.zig` runs the current inline Box Tree tests.
- `zig test src/render.zig` runs the complete renderer/PDF pipeline tests.
- `npm --prefix bindings/js test` builds the WASM/package and runs the Node package tests.
- `node tests/web/verify_snapshots.mjs` verifies WASM structural snapshots and PDF handles.
- `make test-react` builds the React integration fixture; `make react` starts its Vite development server after rebuilding WASM and bindings.
- `make test-browser` runs the browser harness and mounted React-ref preview on Chromium, Firefox, and WebKit.
- `make baseline` intentionally regenerates versioned PDF/PNG baselines; `make test-baseline` checks current PDF bytes against their digests.
- `make test-release` runs Zig, package, React-build, snapshot, browser E2E, and PDF baseline suites.
- `zig fmt --check build.zig src/*.zig src/css/*.zig src/layout/*.zig src/paint/*.zig` checks Zig formatting.
- `make debug`, `make release`, `make wasm`, `make run`, `make react`, `make test`, `make test-react`, and `make clean` wrap common commands.
- `make test-debug-tokenizer` prints a tokenizer dump through the debug-only tokenizer test.
- `make test-debug-dom` prints a DOM ASCII tree through the debug-only DOM test.
- `make test-debug-box` prints a Box Tree ASCII tree with styles through the debug-only Box Tree test.
- `make test-debug` runs all debug dump targets.

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
- Serve the built React fixture in Playwright. Vite dev mode exposes raw PDF.js worker modules and is not the release integration path.
- Use Zig doc comments deliberately: `//!` for module intent and `///` for exported types/functions or private helpers with non-obvious tradeoffs.
- Documentation should explain why a shape exists, ownership/lifetime constraints, or phase boundaries; do not restate obvious names like `toString` returning a string.
- Keep doc examples tiny and only when they make usage faster to understand.
- Use DRY deliberately; extract shared logic only when duplication is real and the abstraction improves readability.
- Preserve clear runtime boundaries between native CLI code, reusable tokenizer/library code, and WASM exports.
- Do not introduce frameworks, package managers, aliases, or custom patterns unless the repository has a concrete need for them.

## Maintenance Rule

Update this file and the relevant file under `agents-files/` whenever build steps, entrypoints, module boundaries, tests, or repository conventions change.
