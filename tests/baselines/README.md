# Renderer baselines

`0.1.0-alpha.0/` freezes the document-profile output before the Web CSS
refactor. Each fixture stores the complete deterministic PDF plus a Poppler
render of page 1 at 96 DPI. `manifest.json` records page count, PDF/WASM size,
SHA-256, render time, and WASM linear-memory observations from the capture run.

Regenerate intentionally with `make baseline` after reviewing every PNG. The
normal release gate uses `make test-baseline`, which renders the same inputs in
memory and rejects page-count or PDF-byte changes. A deliberate renderer change
therefore requires an explicit visual review and baseline update.

