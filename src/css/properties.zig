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
    .{ .name = "background-color", .stage = full },
    .{ .name = "border", .stage = full, .notes = "uniform radius only" },
    .{ .name = "border-collapse", .stage = layout },
    .{ .name = "border-radius", .stage = full, .notes = "uniform circular radius" },
    .{ .name = "box-sizing", .stage = layout },
    .{ .name = "break-after", .stage = layout },
    .{ .name = "break-before", .stage = layout },
    .{ .name = "break-inside", .stage = layout },
    .{ .name = "color", .stage = full, .notes = "currentColor and native PDF alpha via ExtGState" },
    .{ .name = "display", .stage = layout, .notes = "block inline inline-block and table roles" },
    .{ .name = "float", .stage = computed_only, .notes = "non-none rejected by renderer" },
    .{ .name = "font-family", .stage = full },
    .{ .name = "font-size", .stage = full },
    .{ .name = "font-style", .stage = full },
    .{ .name = "font-weight", .stage = full },
    .{ .name = "height", .stage = layout },
    .{ .name = "letter-spacing", .stage = full },
    .{ .name = "line-height", .stage = full },
    .{ .name = "margin", .stage = layout, .notes = "adjacent block collapse supported" },
    .{ .name = "max-height", .stage = layout },
    .{ .name = "max-width", .stage = layout },
    .{ .name = "min-height", .stage = layout },
    .{ .name = "min-width", .stage = layout },
    .{ .name = "orphans", .stage = layout },
    .{ .name = "overflow", .stage = full, .notes = "rectangular descendant clipping; auto and scroll omit interactive scrollbars" },
    .{ .name = "overflow-wrap", .stage = full, .notes = "normal break-word and anywhere; Unicode segmentation pending" },
    .{ .name = "padding", .stage = full },
    .{ .name = "position", .stage = computed_only, .notes = "non-static rejected by renderer" },
    .{ .name = "text-align", .stage = full },
    .{ .name = "text-decoration", .stage = full, .notes = "combined lines color thickness and vector styles" },
    .{ .name = "text-indent", .stage = full, .notes = "length and percentage on first formatted line" },
    .{ .name = "text-overflow", .stage = full, .notes = "selectable ellipsis for clipped single-line text" },
    .{ .name = "text-transform", .stage = full, .notes = "locale-aware Unicode case mapping pending" },
    .{ .name = "vertical-align", .stage = full, .notes = "text baseline keywords and length-percentage offsets; replaced baselines pending" },
    .{ .name = "white-space", .stage = layout },
    .{ .name = "widows", .stage = layout },
    .{ .name = "width", .stage = layout, .notes = "typed calc/min/max/clamp and viewport units" },
    .{ .name = "word-break", .stage = full, .notes = "break-all with UTF-8 codepoint boundaries; Unicode segmentation pending" },
    .{ .name = "word-spacing", .stage = full, .notes = "PDF Type 0 TJ adjustments" },
};

pub const web_foundations = [_]FeatureSupport{
    .{ .name = "browser-media-snapshot", .stage = computed_only, .notes = "deterministic viewport and screen/print selection" },
    .{ .name = "css-identifier-escapes", .stage = computed_only, .notes = "simple and hexadecimal escapes" },
    .{ .name = "css-wide-keywords", .stage = computed_only, .notes = "initial inherit unset revert" },
    .{ .name = "custom-properties", .stage = computed_only, .notes = "var fallback inheritance and cycle detection" },
    .{ .name = "math-functions", .stage = layout, .notes = "calc min max clamp with contextual percentages" },
    .{ .name = "per-glyph-font-fallback", .stage = full, .notes = "registered unicode-range faces split into measured PDF text runs" },
    .{ .name = "pseudo-elements", .stage = full, .notes = "browser ::before/::after strings and attr; counters pending" },
    .{ .name = "shadow-dom", .stage = full, .notes = "opt-in open shadow root and slot flattening" },
    .{ .name = "shorthand-expansion", .stage = computed_only, .notes = "supported shorthands become physical longhands before computed values" },
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
