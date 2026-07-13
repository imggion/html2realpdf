.PHONY: debug release wasm run react baseline test test-wpt test-robustness test-harfbuzz test-bidi test-line-break test-format test-js test-react test-package-consumer test-web test-web-snapshots test-browser test-baseline test-release test-debug test-debug-tokenizer test-debug-dom test-debug-box help

debug:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

wasm:
	zig build wasm -Doptimize=ReleaseSmall
	npm --prefix bindings/js run build:bindings

wasm-list-exports:
	node -e "const fs=require('fs'); WebAssembly.instantiate(fs.readFileSync('zig-out/bin/libhtml2realpdf.wasm'), {}).then(({instance}) => console.log(Object.keys(instance.exports).sort().join('\n')));"

run:
	zig build run

react: wasm
	npm --prefix tests/react run dev

baseline: wasm
	node tests/baselines/generate.mjs

test: test-wpt test-robustness
	zig test src/html.zig
	zig test src/dom.zig
	zig test src/box.zig
	zig test src/css.zig
	zig test src/geometry.zig
	zig test src/image.zig
	zig test src/font.zig
	zig test src/unicode_case.zig
	zig test src/layout.zig
	zig test src/pagination.zig
	zig test src/paged_media.zig
	zig test src/display_list.zig
	zig test src/pdf.zig
	zig test src/render.zig
	zig test src/css/properties.zig
	zig test src/layout/fragmentation.zig
	zig build test-harfbuzz
	zig build test-bidi
	zig build test-bidi-integration
	zig build test-line-break

test-wpt:
	zig test src/wpt_subset_test.zig --test-filter "WPT subset"

test-robustness:
	zig test src/robustness_test.zig -O ReleaseSafe --test-filter "robustness:"

test-harfbuzz:
	zig build test-harfbuzz

test-bidi:
	zig build test-bidi
	zig build test-bidi-integration

test-line-break:
	zig build test-line-break
	zig build test-bidi-integration

test-format:
	zig fmt --check build.zig src/*.zig src/css/*.zig src/layout/*.zig src/paint/*.zig

test-js:
	npm --prefix bindings/js test

test-react: wasm
	npm --prefix tests/react run build

test-package-consumer: test-react
	npm --prefix bindings/js run test:consumer

test-web-snapshots: wasm
	node tests/web/verify_snapshots.mjs

test-browser: wasm test-react
	npm --prefix tests/web test

test-baseline: wasm
	node tests/baselines/verify.mjs

test-web: test-web-snapshots test-browser

test-release: test-format test test-js test-react test-package-consumer test-web test-baseline

test-debug: test-debug-tokenizer test-debug-dom test-debug-box

test-debug-tokenizer:
	HTML2REALPDF_DEBUG_TOKENIZER=1 zig test src/html.zig --test-filter "debug dump tokenizer tokens"

test-debug-dom:
	HTML2REALPDF_DEBUG_DOM=1 zig test src/dom.zig --test-filter "debug dump DOM tree"

test-debug-box:
	HTML2REALPDF_DEBUG_BOX=1 zig test src/box.zig --test-filter "debug dump Box Tree"

clean:
	rm -rf zig-out zig-cache .zig-cache

help:
	@echo "Available commands:"
	@echo "  make debug    Build in Debug mode"
	@echo "  make release  Build in ReleaseFast mode"
	@echo "  make wasm     Build WASM and cache-safe browser package runtime"
	@echo "  make wasm-list-exports"
	@echo "                Print all WASM ABI exports"
	@echo "  make run      Run the native CLI app"
	@echo "  make react    Start the React ref integration app"
	@echo "  make baseline Capture versioned PDF and PNG baselines"
	@echo "  make test     Run tests"
	@echo "  make test-wpt Run the pinned renderer-native WPT subset"
	@echo "  make test-robustness"
	@echo "                Run parser fuzz, allocation, and large-document gates"
	@echo "  make test-harfbuzz"
	@echo "                Run the linked native OpenType shaping gate"
	@echo "  make test-bidi"
	@echo "                Run Unicode bidi resolution and production layout gates"
	@echo "  make test-line-break"
	@echo "                Run Unicode line-breaking and production layout gates"
	@echo "  make test-format"
	@echo "                Check all Zig facade and phase-module formatting"
	@echo "  make test-react"
	@echo "                Build the React ref integration app"
	@echo "  make test-package-consumer"
	@echo "                Pack, install, type-check, bundle, and browser-smoke the npm artifact"
	@echo "  make test-js  Build and test the npm package"
	@echo "  make test-web-snapshots"
	@echo "                Verify WASM structural snapshots in Node"
	@echo "  make test-browser"
	@echo "                Run Chromium, Firefox, and WebKit browser E2E"
	@echo "  make test-web Run snapshot and browser E2E suites"
	@echo "  make test-baseline"
	@echo "                Verify PDFs against committed SHA-256 baselines"
	@echo "  make test-release"
	@echo "                Run the complete release validation suite"
	@echo "  make test-debug-tokenizer"
	@echo "                Print tokenizer debug dump"
	@echo "  make test-debug-dom"
	@echo "                Print DOM tree debug dump"
	@echo "  make test-debug-box"
	@echo "                Print Box Tree debug dump with styles"
	@echo "  make test-debug"
	@echo "                Print tokenizer, DOM, and Box Tree debug dumps"
	@echo "  make clean    Remove Zig build artifacts"
