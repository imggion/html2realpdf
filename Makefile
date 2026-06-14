.PHONY: debug release wasm run clean test test-debug test-debug-tokenizer test-debug-dom help

debug:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

wasm:
	zig build wasm -Doptimize=ReleaseSmall

run:
	zig build run

test:
	zig test src/html.zig
	zig test src/dom.zig

test-debug: test-debug-tokenizer test-debug-dom

test-debug-tokenizer:
	HTML2REALPDF_DEBUG_TOKENIZER=1 zig test src/html.zig --test-filter "debug dump tokenizer tokens"

test-debug-dom:
	HTML2REALPDF_DEBUG_DOM=1 zig test src/dom.zig --test-filter "debug dump DOM tree"

clean:
	rm -rf zig-out zig-cache .zig-cache

help:
	@echo "Available commands:"
	@echo "  make debug    Build in Debug mode"
	@echo "  make release  Build in ReleaseFast mode"
	@echo "  make wasm     Build WASM module in ReleaseSmall mode"
	@echo "  make run      Run the native CLI app"
	@echo "  make test     Run tests"
	@echo "  make test-debug-tokenizer"
	@echo "                Print tokenizer debug dump"
	@echo "  make test-debug-dom"
	@echo "                Print DOM tree debug dump"
	@echo "  make test-debug"
	@echo "                Print tokenizer and DOM debug dumps"
	@echo "  make clean    Remove Zig build artifacts"
