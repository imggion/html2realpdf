.PHONY: debug release wasm run react test test-js test-react test-web test-release test-debug test-debug-tokenizer test-debug-dom test-debug-box help

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

test:
	zig test src/html.zig
	zig test src/dom.zig
	zig test src/box.zig
	zig test src/css.zig
	zig test src/geometry.zig
	zig test src/image.zig
	zig test src/font.zig
	zig test src/layout.zig
	zig test src/pagination.zig
	zig test src/display_list.zig
	zig test src/pdf.zig
	zig test src/render.zig

test-js:
	npm --prefix bindings/js test

test-react: wasm
	npm --prefix tests/react run build

test-web: wasm
	node tests/web/verify_snapshots.mjs

test-release: test test-js test-react test-web

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
	@echo "  make test     Run tests"
	@echo "  make test-react"
	@echo "                Build the React ref integration app"
	@echo "  make test-js  Build and test the npm package"
	@echo "  make test-web Verify WASM browser snapshots in Node"
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
