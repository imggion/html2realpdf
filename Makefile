.PHONY: debug release wasm run clean test help

debug:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

wasm:
	zig build wasm -Doptimize=ReleaseSmall

run:
	zig build run

test:
	zig build test

clean:
	rm -rf zig-out zig-cache .zig-cache

help:
	@echo "Available commands:"
	@echo "  make debug    Build in Debug mode"
	@echo "  make release  Build in ReleaseFast mode"
	@echo "  make wasm     Build WASM module in ReleaseSmall mode"
	@echo "  make run      Run the native CLI app"
	@echo "  make test     Run tests"
	@echo "  make clean    Remove Zig build artifacts"