//! Versioned support metadata for the HTML2RealPDF Web CSS Profile.
//!
//! Runtime behavior remains implemented in syntax, computed-style, layout, and
//! paint modules. This table is the machine-readable source for documentation
//! and compatibility tests.

pub const Stage = struct {
    parsed: bool = false,
    cascaded: bool = false,
    computed: bool = false,
    laid_out: bool = false,
    painted: bool = false,
    paginated: bool = false,
    tested: bool = false,
};

pub const PropertySupport = struct {
    name: []const u8,
    stage: Stage,
    notes: []const u8 = "",
};

pub const FeatureSupport = struct {
    name: []const u8,
    stage: Stage,
    notes: []const u8 = "",
};

const full = Stage{ .parsed = true, .cascaded = true, .computed = true, .laid_out = true, .painted = true, .paginated = true, .tested = true };
const layout = Stage{ .parsed = true, .cascaded = true, .computed = true, .laid_out = true, .paginated = true, .tested = true };
const computed_only = Stage{ .parsed = true, .cascaded = true, .computed = true, .tested = true };

pub const document_profile = [_]PropertySupport{
    .{ .name = "align-content", .stage = layout, .notes = "web and strict flex line alignment" },
    .{ .name = "align-items", .stage = layout, .notes = "web and strict flex cross-axis alignment" },
    .{ .name = "align-self", .stage = layout, .notes = "web and strict per-item flex alignment" },
    .{ .name = "aspect-ratio", .stage = layout, .notes = "preferred ratio, replaced intrinsic fallback, and Web non-replaced auto block sizing" },
    .{ .name = "background-color", .stage = full },
    .{ .name = "background-image", .stage = full, .notes = "web and strict multiple URL axial radial and conic layers; external URLs pass through the resource resolver" },
    .{ .name = "background-position", .stage = full, .notes = "per-layer keywords lengths and percentages" },
    .{ .name = "background-repeat", .stage = full, .notes = "per-layer repeat no-repeat repeat-x and repeat-y" },
    .{ .name = "background-size", .stage = full, .notes = "per-layer auto explicit length-percentage cover and contain" },
    .{ .name = "border", .stage = full, .notes = "physical sides plus per-corner elliptical radius paths" },
    .{ .name = "border-collapse", .stage = layout },
    .{ .name = "border-radius", .stage = full, .notes = "per-corner length-percentage ellipses and rounded overflow clipping" },
    .{ .name = "box-decoration-break", .stage = full, .notes = "web and strict slice or clone page-fragment borders and radius" },
    .{ .name = "box-shadow", .stage = full, .notes = "web and strict multiple outer and inset native vector falloff shadows" },
    .{ .name = "box-sizing", .stage = layout },
    .{ .name = "break-after", .stage = layout },
    .{ .name = "break-before", .stage = layout },
    .{ .name = "break-inside", .stage = layout },
    .{ .name = "caption-side", .stage = layout, .notes = "top and bottom table captions" },
    .{ .name = "clear", .stage = layout, .notes = "web and strict clear left right or both floats" },
    .{ .name = "color", .stage = full, .notes = "currentColor and native PDF alpha via ExtGState" },
    .{ .name = "column-gap", .stage = layout, .notes = "web and strict flex main or cross gap" },
    .{ .name = "direction", .stage = computed_only, .notes = "web and strict resolve full UAX 9 visual runs" },
    .{ .name = "display", .stage = layout, .notes = "block inline inline-block list-item flex inline-flex grid inline-grid and table roles" },
    .{ .name = "flex-basis", .stage = layout },
    .{ .name = "flex-direction", .stage = layout },
    .{ .name = "flex-grow", .stage = layout },
    .{ .name = "flex-shrink", .stage = layout },
    .{ .name = "flex-wrap", .stage = layout },
    .{ .name = "float", .stage = layout, .notes = "web and strict left/right exclusion bands; document rejects non-none" },
    .{ .name = "font-family", .stage = full },
    .{ .name = "font-size", .stage = full },
    .{ .name = "font-style", .stage = full },
    .{ .name = "font-weight", .stage = full },
    .{ .name = "gap", .stage = layout, .notes = "row and column shorthand for flex and grid" },
    .{ .name = "grid-auto-columns", .stage = layout, .notes = "web and strict implicit column track sizing" },
    .{ .name = "grid-auto-flow", .stage = layout, .notes = "row column and dense auto placement" },
    .{ .name = "grid-auto-rows", .stage = layout, .notes = "web and strict implicit row track sizing" },
    .{ .name = "grid-column", .stage = layout, .notes = "numeric named and span placement" },
    .{ .name = "grid-row", .stage = layout, .notes = "numeric named and span placement" },
    .{ .name = "grid-template-areas", .stage = layout, .notes = "rectangular named areas" },
    .{ .name = "grid-template-columns", .stage = layout, .notes = "fixed percentage intrinsic flexible repeat and minmax tracks" },
    .{ .name = "grid-template-rows", .stage = layout, .notes = "fixed percentage intrinsic flexible repeat and minmax tracks" },
    .{ .name = "height", .stage = layout },
    .{ .name = "inset", .stage = layout, .notes = "web and strict physical and logical positioned offsets" },
    .{ .name = "justify-content", .stage = layout, .notes = "web and strict flex main-axis distribution" },
    .{ .name = "justify-items", .stage = layout, .notes = "web and strict Grid inline-axis item alignment" },
    .{ .name = "justify-self", .stage = layout, .notes = "web and strict per-item Grid inline-axis alignment" },
    .{ .name = "letter-spacing", .stage = full },
    .{ .name = "line-height", .stage = full },
    .{ .name = "list-style-position", .stage = full, .notes = "inside and inline-start outside marker placement" },
    .{ .name = "list-style-type", .stage = full, .notes = "common bullets decimal alphabetic and Roman counters" },
    .{ .name = "margin", .stage = layout, .notes = "web and strict sibling parent-child empty-block and negative collapse groups" },
    .{ .name = "max-height", .stage = layout },
    .{ .name = "max-width", .stage = layout },
    .{ .name = "min-height", .stage = layout },
    .{ .name = "min-width", .stage = layout },
    .{ .name = "object-fit", .stage = full, .notes = "fill contain cover none and scale-down with PDF clipping" },
    .{ .name = "object-position", .stage = full, .notes = "one- and two-value keyword or length-percentage positions" },
    .{ .name = "opacity", .stage = full, .notes = "web and strict nested isolated PDF transparency Form XObjects" },
    .{ .name = "order", .stage = layout, .notes = "stable visual ordering of flex and Grid items" },
    .{ .name = "orphans", .stage = layout },
    .{ .name = "overflow", .stage = full, .notes = "rectangular or rounded descendant clipping; auto and scroll omit interactive scrollbars" },
    .{ .name = "overflow-wrap", .stage = full, .notes = "normal break-word and anywhere at extended grapheme boundaries" },
    .{ .name = "padding", .stage = full },
    .{ .name = "position", .stage = layout, .notes = "web and strict relative absolute sticky print flow and repeated fixed page boxes; document rejects non-static" },
    .{ .name = "row-gap", .stage = layout, .notes = "web and strict flex main or cross gap" },
    .{ .name = "text-align", .stage = full },
    .{ .name = "text-decoration", .stage = full, .notes = "combined lines color thickness and vector styles" },
    .{ .name = "text-indent", .stage = full, .notes = "length and percentage on first formatted line" },
    .{ .name = "text-overflow", .stage = full, .notes = "selectable ellipsis for clipped single-line text" },
    .{ .name = "text-shadow", .stage = full, .notes = "web and strict multiple native PDF text shadows marked as non-content artifacts" },
    .{ .name = "text-transform", .stage = full, .notes = "Unicode 17 full mappings and SpecialCasing language rules" },
    .{ .name = "transform", .stage = full, .notes = "web and strict matrix translate scale rotate and skew as native PDF cm operators" },
    .{ .name = "transform-origin", .stage = full, .notes = "web and strict length-percentage origin on the border box" },
    .{ .name = "vertical-align", .stage = full, .notes = "text baselines; web/strict add replaced and inline-block baselines" },
    .{ .name = "white-space", .stage = layout },
    .{ .name = "widows", .stage = layout },
    .{ .name = "width", .stage = layout, .notes = "typed calc/min/max/clamp, min-content/max-content/fit-content, and viewport units" },
    .{ .name = "word-break", .stage = full, .notes = "UAX #14 normal, break-all, and CJK keep-all with extended grapheme boundaries" },
    .{ .name = "word-spacing", .stage = full, .notes = "PDF Type 0 TJ adjustments" },
    .{ .name = "z-index", .stage = full, .notes = "tree-derived negative normal auto-zero and positive stacking order" },
};

pub const web_foundations = [_]FeatureSupport{
    .{ .name = "2d-transforms", .stage = full, .notes = "typed transform lists cumulative descendant matrices transformed clips and link bounds" },
    .{ .name = "background-layers", .stage = full, .notes = "multiple images axial radial and conic gradients with per-layer size position and repeat" },
    .{ .name = "bidirectional-text", .stage = full, .notes = "SheenBidi UAX 9 paragraph levels and L2 line reordering" },
    .{ .name = "browser-media-snapshot", .stage = computed_only, .notes = "deterministic viewport and screen/print selection" },
    .{ .name = "css-identifier-escapes", .stage = computed_only, .notes = "simple and hexadecimal escapes" },
    .{ .name = "css-wide-keywords", .stage = computed_only, .notes = "initial inherit unset revert" },
    .{ .name = "custom-properties", .stage = computed_only, .notes = "var fallback inheritance and cycle detection" },
    .{ .name = "grid-layout", .stage = full, .notes = "explicit and implicit tracks placement sizing alignment nesting and row fragmentation" },
    .{ .name = "logical-box-properties", .stage = full, .notes = "horizontal-tb size margin padding and border groups with final-direction cascade mapping" },
    .{ .name = "math-functions", .stage = layout, .notes = "calc min max clamp with contextual percentages" },
    .{ .name = "opacity-groups", .stage = full, .notes = "nested isolated PDF transparency groups preserve overlap compositing" },
    .{ .name = "paged-media-default-page", .stage = full, .notes = "browser CSSOM default page size orientation and margins with API override priority" },
    .{ .name = "per-glyph-font-fallback", .stage = full, .notes = "registered unicode-range faces split into measured PDF text runs" },
    .{ .name = "pseudo-elements", .stage = full, .notes = "browser ::before/::after strings attr and nested counters" },
    .{ .name = "shadow-dom", .stage = full, .notes = "opt-in open shadow root and slot flattening" },
    .{ .name = "shadow-effects", .stage = full, .notes = "multiple outer inset and text shadows remain native PDF paint" },
    .{ .name = "shorthand-expansion", .stage = computed_only, .notes = "supported shorthands become physical longhands before computed values" },
    .{ .name = "stacking-contexts", .stage = full, .notes = "positioned and opacity contexts retain atomic tree-derived paint order" },
    .{ .name = "svg-vector-resources", .stage = full, .notes = "validated shapes paths arcs groups and affine transforms become PDF Form XObjects with diagnostic scoped fallback" },
    .{ .name = "unicode-line-breaking", .stage = full, .notes = "libunibreak UAX 14 opportunities plus CSS emergency wrapping" },
};

test "document profile entries are sorted and uniquely named" {
    const std = @import("std");
    for (document_profile[1..], document_profile[0 .. document_profile.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous.name, current.name) == .lt);
    }
}

test "web foundation entries are sorted and uniquely named" {
    const std = @import("std");
    for (web_foundations[1..], web_foundations[0 .. web_foundations.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(u8, previous.name, current.name) == .lt);
    }
}
