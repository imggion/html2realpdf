.PHONY: debug release wasm run clean test test-debug test-debug-tokenizer test-debug-dom test-debug-box help

debug:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

wasm:
	zig build wasm -Doptimize=ReleaseSmall

wasm-list-exports:
	node -e "const fs=require('fs'); WebAssembly.instantiate(fs.readFileSync('zig-out/bin/libhtml2realpdf.wasm'), {}).then(({instance}) => console.log(Object.keys(instance.exports).sort().join('\n')));"

run:
	zig build run

test:
	zig test src/html.zig
	zig test src/dom.zig
	zig test src/box.zig
	zig test src/css.zig

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
	@echo "  make wasm     Build WASM module in ReleaseSmall mode"
	@echo "  make wasm-list-exports"
	@echo "                Print all WASM FFP exports"
	@echo "  make run      Run the native CLI app"
	@echo "  make test     Run tests"
	@echo "  make test-debug-tokenizer"
	@echo "                Print tokenizer debug dump"
	@echo "  make test-debug-dom"
	@echo "                Print DOM tree debug dump"
	@echo "  make test-debug-box"
	@echo "                Print Box Tree debug dump with styles"
	@echo "  make test-debug"
	@echo "                Print tokenizer, DOM, and Box Tree debug dumps"
	@echo "  make clean    Remove Zig build artifacts"
