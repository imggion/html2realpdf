# Agent Guide

This is the entry point for future coding agents working on `html2realpdf`.

Read these local docs before changing code:

- `agents-files/README.md` explains the agent documentation set.
- `agents-files/project-structure.md` describes the runtime flow, package layout, and core technologies.
- `agents-files/file-tree.md` gives a high-signal repository map.
- `agents-files/where-things-live.md` explains where new code should go.
- `agents-files/code-patterns.md` captures repo-specific coding patterns and maintainability rules.

## Repo Summary

- Early-stage Zig package named `html2realpdf`; current implemented behavior is an HTML tokenizer, a tolerant DOM tree builder, and a first Box Tree builder, with native CLI and WebAssembly entrypoints.
- Zig version is `0.16.0`; use the 0.16 docs: https://ziglang.org/documentation/0.16.0/ and stdlib docs: https://ziglang.org/documentation/0.16.0/std/.
- Active source lives in `src/`; browser WASM smoke-test files live in `tests/web/`.
- `build.zig` defines the native executable from `src/main.zig`, the package/root module from `src/root.zig`, and the wasm executable from `src/wasm.zig`; reusable parser/tree modules are exported from `src/root.zig`.
- `tests/web/` can call WASM exports for token count, DOM ASCII tree, and Box Tree ASCII tree with styles.
- There is no app framework, routing layer, styling system, persistent state layer, or external package dependency currently configured.

## Commands

- `zig build` builds the default native executable into `zig-out/bin/html2realpdf`.
- `zig build run` runs the native CLI target.
- `zig build wasm -Doptimize=ReleaseSmall` builds `zig-out/bin/libhtml2realpdf.wasm`.
- `zig test src/html.zig` runs the current inline tokenizer tests.
- `zig test src/dom.zig` runs the current inline DOM parser tests.
- `zig test src/box.zig` runs the current inline Box Tree tests.
- `zig fmt --check build.zig src/*.zig` checks Zig formatting.
- `make debug`, `make release`, `make wasm`, `make run`, `make test`, and `make clean` wrap common commands.
- `make test-debug-tokenizer` prints a tokenizer dump through the debug-only tokenizer test.
- `make test-debug-dom` prints a DOM ASCII tree through the debug-only DOM test.
- `make test-debug-box` prints a Box Tree ASCII tree with styles through the debug-only Box Tree test.
- `make test-debug` runs all debug dump targets.

## Style Rules

- Prefer small, explicit changes that fit the current Zig module layout.
- Keep tokenizer and parsing control flow readable; avoid nested ternaries, clever state shortcuts, and giant multi-purpose functions when a local helper or state branch would be clearer.
- Keep Box Tree construction in `src/box.zig`; use flat `BoxId` links like `dom.NodeId` instead of recursive owned child arrays.
- Use Zig doc comments deliberately: `//!` for module intent and `///` for exported types/functions or private helpers with non-obvious tradeoffs.
- Documentation should explain why a shape exists, ownership/lifetime constraints, or phase boundaries; do not restate obvious names like `toString` returning a string.
- Keep doc examples tiny and only when they make usage faster to understand.
- Use DRY deliberately; extract shared logic only when duplication is real and the abstraction improves readability.
- Preserve clear runtime boundaries between native CLI code, reusable tokenizer/library code, and WASM exports.
- Do not introduce frameworks, package managers, aliases, or custom patterns unless the repository has a concrete need for them.

## Maintenance Rule

Update this file and the relevant file under `agents-files/` whenever build steps, entrypoints, module boundaries, tests, or repository conventions change.
