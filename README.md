# html2realpdf

Early-stage Zig project for converting HTML toward a real PDF rendering pipeline.

The current implementation focuses on two foundations:

- an HTML tokenizer;
- a tolerant DOM tree builder built from tokenizer output.

PDF generation is not implemented yet.

## Requirements

- Zig `0.16.0`
- `make` for convenience commands

## Build

```sh
zig build
```

Or with Make:

```sh
make debug
make release
```

## Run

```sh
zig build run
```

Or:

```sh
make run
```

## Test

```sh
make test
```

Direct commands:

```sh
zig test src/html.zig
zig test src/dom.zig
```

Debug dump helpers:

```sh
make test-debug-tokenizer
make test-debug-dom
make test-debug-box
make test-debug
```

## WebAssembly Smoke Test

Build the WASM target:

```sh
make wasm
```

Then serve the repository locally and open:

```text
tests/web/index.html
```

The page can:

- tokenize the sample HTML and show the token count;
- generate an ASCII DOM tree from the same HTML through the WASM module;
- generate an ASCII Box Tree with styles through the WASM module.

## Project Layout

```text
src/html.zig      HTML tokenizer and token debug dump
src/dom.zig       tolerant DOM parser and ASCII tree dump
src/box.zig       Box Tree builder and style-aware tree dump
src/wasm.zig      WebAssembly exports
src/main.zig      native CLI entrypoint
src/root.zig      package root exports
tests/web/        manual browser smoke test
```

## Current Scope

The parser is intentionally small and pragmatic. It supports an MVP subset useful for future PDF rendering work, including headings, paragraphs, inline emphasis, lists, tables, images, line breaks, and generic containers.

The DOM parser is tolerant but not a full HTML5 tree-construction implementation.
