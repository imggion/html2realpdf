# File Tree

```text
.
├── AGENTS.md
├── README.md
├── LICENSE
├── Makefile
├── build.zig
├── build.zig.zon
├── assets/                       bundled font and Unicode-engine licenses
├── bindings/js/
│   ├── package.json
│   ├── README.md
│   ├── scripts/                 build/clean helpers
│   ├── src/                     typed API, Worker, snapshot, preview, compatibility
│   └── test/                    Node package and WASM ABI tests
├── scripts/fetch_fonts.sh       pinned, checksum-verified Noto fetch
├── src/
│   ├── assets/fonts/            Latin, Arabic, and Hebrew Noto Sans TTF faces
│   ├── html.zig                 tokenizer
│   ├── dom.zig                  flat tolerant DOM
│   ├── css.zig                  parser, selectors, cascade
│   ├── css/                     syntax, selectors, values, computed, cascade, support inventory
│   ├── box.zig                  styles and flat Box Tree
│   ├── geometry.zig             points, rectangles, colors, units
│   ├── font.zig                 TTF metrics, registry, subsetting
│   ├── bidi.zig                 SheenBidi UAX #9 bridge
│   ├── line_break.zig           libunibreak UAX #14 bridge
│   ├── unicode_case.zig         Unicode 17 full and language-sensitive case mapping
│   ├── unicode_case_data.zig    generated pinned Unicode case/property tables
│   ├── harfbuzz.zig/.cc         native/WASM shaping bridge and amalgamation wrapper
│   ├── harfbuzz_test.zig        linked OpenType shaping gate
│   ├── layout.zig               block/inline/table layout
│   ├── layout/                  formatting contexts, intrinsic sizing, fragmentation boundary
│   │   ├── page_geometry.zig    page boxes, selector cascade, and named-page sequences
│   ├── pagination.zig           page geometry and fragmentation
│   ├── paged_media.zig          @page margin-box counters and text commands
│   ├── display_list.zig         paint command boundary
│   ├── paint/                   command types, backgrounds, borders, effects, stacking boundary
│   ├── image.zig                JPEG/PNG and Flate helpers
│   ├── svg.zig                  validated SVG shape/path vector lowering
│   ├── pdf.zig                  PDF 1.7 writer
│   ├── render.zig               pipeline orchestration
│   ├── wpt_subset_test.zig      pinned renderer-native WPT adaptations
│   ├── robustness_test.zig      fuzz, OOM, and large-document gates
│   ├── wasm.zig                 ABI v1
│   ├── root.zig                 public Zig exports
│   └── main.zig                 native executable
└── tests/
    ├── baselines/               versioned PDFs, Poppler PNGs, metrics, digest verifier
    ├── render_pdf_fixture.mjs    Poppler/visual QA fixture generator
    ├── react/                    real React-ref integration app
    ├── wpt/                      upstream revision and selected-case provenance
    └── web/                      browser harness, complex fixtures, snapshots, Playwright E2E
```

Generated `zig-out/`, `.zig-cache/`, `bindings/js/dist/`, `node_modules/`, and
`tmp/` content must not be edited directly.
