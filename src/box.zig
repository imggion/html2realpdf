//! Box Tree construction for the rendering pipeline.
//!
//! The tree is intentionally stored flat, like `dom.Document`: IDs are cheap to
//! copy, stable enough for sibling links, and avoid recursive ownership problems
//! while `ArrayList` grows.

// TOOD: separate responsibilities
// In this file we have a function `getAttributeValue`, but this function
// seems be part of the `html.zig` responsibilities.
//
// So we should divide better the responsibilities of some helpers, functions etc.

const std = @import("std");
const dom = @import("dom.zig");
const html = @import("html.zig");
const geometry = @import("geometry.zig");
const expressions = @import("css/expressions.zig");

/// Stable index into `BoxTree.boxes`.
///
/// A Box Tree is rewritten during anonymous-box normalization, so links use IDs
/// instead of pointers or child arrays owned by each box.
pub const BoxId = usize;

/// The formatting role a box plays before layout assigns geometry.
///
/// `anonymousBlock` exists because CSS block containers cannot freely mix block
/// children with inline runs. `replaced` keeps intrinsic dimensions near the
/// DOM node that owns them. `lineBreak` gives `<br>` a visible layout signal.
pub const BoxType = enum {
    block,
    listItem,
    inlineBox,
    inlineBlock,
    text,
    anonymousBlock,
    anonymousInline,
    anonymousTableRow,
    table,
    tableRow,
    tableCell,
    tableRowGroup,
    tableCaption,
    tableColumn,
    tableColumnGroup,
    replaced,
    lineBreak,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .block => "block",
            .listItem => "list-item",
            .inlineBox => "inline",
            .inlineBlock => "inline-block",
            .text => "text",
            .anonymousBlock => "anonymous-block",
            .anonymousInline => "anonymous-inline",
            .anonymousTableRow => "anonymous-table-row",
            .table => "table",
            .tableRow => "table-row",
            .tableCell => "table-cell",
            .tableRowGroup => "table-row-group",
            .tableCaption => "table-caption",
            .tableColumn => "table-column",
            .tableColumnGroup => "table-column-group",
            .replaced => "replaced",
            .lineBreak => "line-break",
        };
    }
};

/// The display values this first Box Tree builder needs to decide box creation.
///
/// Richer CSS display modes should only be added when the layout stage can make
/// a useful distinction between them.
pub const Display = enum {
    none,
    block,
    listItem,
    inlineBox,
    inlineBlock,
    flex,
    inlineFlex,
    grid,
    inlineGrid,
    table,
    tableRow,
    tableCell,
    tableRowGroup,
    tableCaption,
    tableColumn,
    tableColumnGroup,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .block => "block",
            .listItem => "list-item",
            .inlineBox => "inline",
            .inlineBlock => "inline-block",
            .flex => "flex",
            .inlineFlex => "inline-flex",
            .grid => "grid",
            .inlineGrid => "inline-grid",
            .table => "table",
            .tableRow => "table-row",
            .tableCell => "table-cell",
            .tableRowGroup => "table-row-group",
            .tableCaption => "table-caption",
            .tableColumn => "table-column",
            .tableColumnGroup => "table-column-group",
        };
    }
};

/// Position participates in Box Tree construction only as an early layout flag.
pub const Position = enum {
    static,
    relative,
    absolute,
    sticky,
    fixed,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .static => "static",
            .relative => "relative",
            .absolute => "absolute",
            .sticky => "sticky",
            .fixed => "fixed",
        };
    }
};

/// Float is tracked here so block layout can later remove it from normal flow.
pub const Float = enum {
    none,
    left,
    right,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .left => "left",
            .right => "right",
        };
    }
};

pub const Clear = enum {
    none,
    left,
    right,
    both,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .left => "left",
            .right => "right",
            .both => "both",
        };
    }
};

pub const CaptionSide = enum {
    top,
    bottom,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .top => "top",
            .bottom => "bottom",
        };
    }
};

pub const BoxDecorationBreak = enum {
    slice,
    clone,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .slice => "slice",
            .clone => "clone",
        };
    }
};

pub const ListStyleType = enum {
    none,
    disc,
    circle,
    square,
    decimal,
    decimalLeadingZero,
    lowerAlpha,
    upperAlpha,
    lowerRoman,
    upperRoman,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .disc => "disc",
            .circle => "circle",
            .square => "square",
            .decimal => "decimal",
            .decimalLeadingZero => "decimal-leading-zero",
            .lowerAlpha => "lower-alpha",
            .upperAlpha => "upper-alpha",
            .lowerRoman => "lower-roman",
            .upperRoman => "upper-roman",
        };
    }
};

pub const ListStylePosition = enum {
    outside,
    inside,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .outside => "outside",
            .inside => "inside",
        };
    }
};

pub const FlexDirection = enum {
    row,
    rowReverse,
    column,
    columnReverse,

    pub fn isRow(self: @This()) bool {
        return self == .row or self == .rowReverse;
    }

    pub fn isReverse(self: @This()) bool {
        return self == .rowReverse or self == .columnReverse;
    }
};

pub const FlexWrap = enum { nowrap, wrap, wrapReverse };

pub const JustifyContent = enum { normal, flexStart, flexEnd, center, spaceBetween, spaceAround, spaceEvenly };

pub const AlignItems = enum { stretch, flexStart, flexEnd, center, baseline };

pub const AlignSelf = enum { auto, stretch, flexStart, flexEnd, center, baseline };

pub const AlignContent = enum { stretch, flexStart, flexEnd, center, spaceBetween, spaceAround, spaceEvenly };

/// Text whitespace mode needed before line breaking can make final decisions.
pub const WhiteSpace = enum {
    normal,
    nowrap,
    pre,
    preWrap,
    preLine,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .nowrap => "nowrap",
            .pre => "pre",
            .preWrap => "pre-wrap",
            .preLine => "pre-line",
        };
    }
};

pub const FontWeight = enum {
    normal,
    bold,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .bold => "bold",
        };
    }
};

pub const FontStyle = enum {
    normal,
    italic,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .italic => "italic",
        };
    }
};

/// Horizontal text alignment within a block container.
pub const TextAlign = enum {
    start,
    end,
    left,
    center,
    right,
    justify,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .start => "start",
            .end => "end",
            .left => "left",
            .center => "center",
            .right => "right",
            .justify => "justify",
        };
    }
};

/// Base inline direction inherited by descendants and used by the Unicode
/// Bidirectional Algorithm for each formatted paragraph.
pub const Direction = enum {
    ltr,
    rtl,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .ltr => "ltr",
            .rtl => "rtl",
        };
    }
};

/// Case conversion requested by CSS Text. The inline formatter applies the
/// conversion before measuring so PDF glyph advances and layout stay equal.
pub const TextTransform = enum {
    none,
    uppercase,
    lowercase,
    capitalize,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .uppercase => "uppercase",
            .lowercase => "lowercase",
            .capitalize => "capitalize",
        };
    }
};

pub const WordBreak = enum {
    normal,
    breakAll,
    keepAll,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .breakAll => "break-all",
            .keepAll => "keep-all",
        };
    }
};

pub const OverflowWrap = enum {
    normal,
    breakWord,
    anywhere,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .breakWord => "break-word",
            .anywhere => "anywhere",
        };
    }
};

pub const Overflow = enum {
    visible,
    hidden,
    clip,
    auto,
    scroll,

    pub fn clips(self: @This()) bool {
        return self != .visible;
    }

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .visible => "visible",
            .hidden => "hidden",
            .clip => "clip",
            .auto => "auto",
            .scroll => "scroll",
        };
    }
};

pub const TextOverflow = enum {
    clip,
    ellipsis,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .clip => "clip",
            .ellipsis => "ellipsis",
        };
    }
};

pub const AspectRatio = struct {
    ratio: ?f32 = null,
    use_intrinsic: bool = true,

    pub fn resolve(self: AspectRatio, intrinsic: ?f32) ?f32 {
        if (self.use_intrinsic and intrinsic != null) return intrinsic;
        return self.ratio orelse intrinsic;
    }
};

pub const ObjectFit = enum {
    fill,
    contain,
    cover,
    none,
    scaleDown,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .fill => "fill",
            .contain => "contain",
            .cover => "cover",
            .none => "none",
            .scaleDown => "scale-down",
        };
    }
};

pub const ObjectPosition = struct {
    x: Length = .{ .percent = 0.5 },
    y: Length = .{ .percent = 0.5 },
};

pub const TransformOperation = union(enum) {
    matrix: geometry.AffineTransform,
    translate: struct { x: Length = .{ .px = 0 }, y: Length = .{ .px = 0 } },
    scale: struct { x: f32 = 1, y: f32 = 1 },
    rotate: f32,
    skew: struct { x: f32 = 0, y: f32 = 0 },
};

pub const OpacityGroupPath = struct {
    ids: [32]BoxId = @splat(0),
    values: [32]f32 = @splat(1),
    len: u8 = 0,

    pub fn append(self: *@This(), id: BoxId, opacity: f32) void {
        if (self.len < self.ids.len) {
            self.ids[self.len] = id;
            self.values[self.len] = opacity;
            self.len += 1;
        } else {
            self.values[self.values.len - 1] *= opacity;
        }
    }
};

pub fn resolveTransform(operations: []const TransformOperation, width: f32, height: f32) geometry.AffineTransform {
    var result = geometry.AffineTransform.identity;
    for (operations) |operation| {
        const matrix = switch (operation) {
            .matrix => |value| value,
            .translate => |value| geometry.AffineTransform.translation(
                value.x.resolve(width) orelse 0,
                value.y.resolve(height) orelse 0,
            ),
            .scale => |value| geometry.AffineTransform.scaling(value.x, value.y),
            .rotate => |radians| geometry.AffineTransform.rotation(radians),
            .skew => |value| geometry.AffineTransform.skewing(value.x, value.y),
        };
        result = result.multiply(matrix);
    }
    return result;
}

pub const VerticalAlign = union(enum) {
    baseline,
    sub,
    super,
    textTop,
    textBottom,
    middle,
    top,
    bottom,
    offset: Length,
};

pub const TextDecoration = enum {
    none,
    underline,
    overline,
    lineThrough,
    underlineOverline,
    underlineLineThrough,
    overlineLineThrough,
    all,

    pub fn hasUnderline(self: @This()) bool {
        return self == .underline or self == .underlineOverline or self == .underlineLineThrough or self == .all;
    }

    pub fn hasOverline(self: @This()) bool {
        return self == .overline or self == .underlineOverline or self == .overlineLineThrough or self == .all;
    }

    pub fn hasLineThrough(self: @This()) bool {
        return self == .lineThrough or self == .underlineLineThrough or self == .overlineLineThrough or self == .all;
    }

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .underline => "underline",
            .overline => "overline",
            .lineThrough => "line-through",
            .underlineOverline => "underline overline",
            .underlineLineThrough => "underline line-through",
            .overlineLineThrough => "overline line-through",
            .all => "underline overline line-through",
        };
    }
};

pub const TextDecorationStyle = enum {
    solid,
    double,
    dotted,
    dashed,
    wavy,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .solid => "solid",
            .double => "double",
            .dotted => "dotted",
            .dashed => "dashed",
            .wavy => "wavy",
        };
    }
};

pub const TextDecorationThickness = union(enum) {
    auto,
    fromFont,
    length: Length,
};

/// Box sizing model: content-box or border-box.
pub const BoxSizing = enum {
    contentBox,
    borderBox,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .contentBox => "content-box",
            .borderBox => "border-box",
        };
    }
};

pub const BorderCollapse = enum {
    separate,
    collapse,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .separate => "separate",
            .collapse => "collapse",
        };
    }
};

/// Controls page fragmentation before, after, or inside a box.
pub const PageBreak = enum {
    auto,
    avoid,
    page,
    left,
    right,
    recto,
    verso,

    pub fn isForced(self: @This()) bool {
        return switch (self) {
            .page, .left, .right, .recto, .verso => true,
            .auto, .avoid => false,
        };
    }

    pub fn isAvoid(self: @This()) bool {
        return self == .avoid;
    }

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .auto => "auto",
            .avoid => "avoid",
            .page => "page",
            .left => "left",
            .right => "right",
            .recto => "recto",
            .verso => "verso",
        };
    }
};

/// Border line style.
pub const BorderStyle = enum {
    none,
    solid,
    dashed,
    dotted,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .solid => "solid",
            .dashed => "dashed",
            .dotted => "dotted",
        };
    }
};

/// CSS property names used by debug output and future style parsing.
pub const StyleProperty = enum {
    fontSize,
    fontFamily,
    color,
    background,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .fontSize => "font-size",
            .fontFamily => "font-family",
            .color => "color",
            .background => "background",
        };
    }
};

/// Logical box-model edges in CSS order.
pub const EdgeSizes = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

/// A layout dimension that must retain its percentage until a containing size
/// is known. Absolute CSS units are normalized to CSS pixels by the cascade.
pub const FitContentLimit = union(enum) {
    px: f32,
    percent: f32,
    expression: expressions.Reference,

    pub fn resolve(self: FitContentLimit, reference: f32) ?f32 {
        return switch (self) {
            .px => |value| value,
            .percent => |ratio| reference * ratio,
            .expression => |value| value.resolve(reference),
        };
    }

    pub fn dependsOnPercentage(self: FitContentLimit) bool {
        return switch (self) {
            .px => false,
            .percent => true,
            .expression => |value| value.dependsOnPercentage(),
        };
    }
};

pub const Length = union(enum) {
    auto,
    px: f32,
    percent: f32,
    expression: expressions.Reference,
    minContent,
    maxContent,
    fitContent: ?FitContentLimit,

    pub fn resolve(self: Length, reference: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |value| value,
            .percent => |ratio| reference * ratio,
            .expression => |value| value.resolve(reference),
            .minContent, .maxContent, .fitContent => null,
        };
    }

    pub fn usesIntrinsicSizing(self: Length) bool {
        return switch (self) {
            .minContent, .maxContent, .fitContent => true,
            else => false,
        };
    }

    pub fn isAuto(self: Length) bool {
        return self == .auto;
    }
};

/// Tracks the CSS `auto` state separately from resolved numeric margins.
/// Normal flow keeps using `EdgeSizes`; flex layout consumes these flags when
/// distributing free space on the main and cross axes.
pub const AutoEdges = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

pub const Insets = struct {
    top: Length = .auto,
    right: Length = .auto,
    bottom: Length = .auto,
    left: Length = .auto,
};

pub const CornerRadius = struct {
    x: Length = .{ .px = 0 },
    y: Length = .{ .px = 0 },
};

pub const ResolvedCornerRadius = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const ResolvedBorderRadii = struct {
    top_left: ResolvedCornerRadius = .{},
    top_right: ResolvedCornerRadius = .{},
    bottom_right: ResolvedCornerRadius = .{},
    bottom_left: ResolvedCornerRadius = .{},

    pub fn hasRadius(self: @This()) bool {
        return self.top_left.x > 0 or self.top_left.y > 0 or self.top_right.x > 0 or self.top_right.y > 0 or
            self.bottom_right.x > 0 or self.bottom_right.y > 0 or self.bottom_left.x > 0 or self.bottom_left.y > 0;
    }

    pub fn uniform(radius: f32) @This() {
        const corner = ResolvedCornerRadius{ .x = radius, .y = radius };
        return .{ .top_left = corner, .top_right = corner, .bottom_right = corner, .bottom_left = corner };
    }

    pub fn inset(self: @This(), edges: EdgeSizes) @This() {
        return .{
            .top_left = .{ .x = @max(self.top_left.x - edges.left, 0), .y = @max(self.top_left.y - edges.top, 0) },
            .top_right = .{ .x = @max(self.top_right.x - edges.right, 0), .y = @max(self.top_right.y - edges.top, 0) },
            .bottom_right = .{ .x = @max(self.bottom_right.x - edges.right, 0), .y = @max(self.bottom_right.y - edges.bottom, 0) },
            .bottom_left = .{ .x = @max(self.bottom_left.x - edges.left, 0), .y = @max(self.bottom_left.y - edges.bottom, 0) },
        };
    }
};

pub const BorderRadii = struct {
    top_left: CornerRadius = .{},
    top_right: CornerRadius = .{},
    bottom_right: CornerRadius = .{},
    bottom_left: CornerRadius = .{},

    pub fn resolve(self: @This(), width: f32, height: f32) ResolvedBorderRadii {
        var result = ResolvedBorderRadii{
            .top_left = resolveCorner(self.top_left, width, height),
            .top_right = resolveCorner(self.top_right, width, height),
            .bottom_right = resolveCorner(self.bottom_right, width, height),
            .bottom_left = resolveCorner(self.bottom_left, width, height),
        };
        const horizontal_scale = @min(@min(scaleForPair(width, result.top_left.x, result.top_right.x), scaleForPair(width, result.bottom_left.x, result.bottom_right.x)), 1);
        const vertical_scale = @min(@min(scaleForPair(height, result.top_left.y, result.bottom_left.y), scaleForPair(height, result.top_right.y, result.bottom_right.y)), 1);
        const scale = @min(horizontal_scale, vertical_scale);
        if (scale < 1) {
            inline for (.{ &result.top_left, &result.top_right, &result.bottom_right, &result.bottom_left }) |corner| {
                corner.x *= scale;
                corner.y *= scale;
            }
        }
        return result;
    }

    fn resolveCorner(corner: CornerRadius, width: f32, height: f32) ResolvedCornerRadius {
        return .{
            .x = @max(corner.x.resolve(width) orelse 0, 0),
            .y = @max(corner.y.resolve(height) orelse 0, 0),
        };
    }

    fn scaleForPair(available: f32, first: f32, second: f32) f32 {
        const total = first + second;
        return if (total > 0) available / total else 1;
    }
};

pub const GridAutoFlow = enum {
    row,
    column,
    rowDense,
    columnDense,
};

pub const GridLine = union(enum) {
    auto,
    line: i32,
    span: u16,
    named: []const u8,
    namedSpan: struct { name: []const u8, count: u16 = 1 },
};

/// Style data resolved enough for Box Tree construction.
///
/// This is not the CSS parser format. The builder only needs properties that
/// decide whether a box exists, which kind it is, and which flags/layout inputs
/// must survive into later phases.
pub const Style = struct {
    layout_supported: bool = true,
    display: Display = .inlineBox,
    position: Position = .static,
    insets: Insets = .{},
    z_index: ?i32 = null,
    opacity: f32 = 1,
    transform: []const TransformOperation = &.{},
    transform_origin: ObjectPosition = .{},
    float_direction: Float = .none,
    clear_direction: Clear = .none,
    white_space: WhiteSpace = .normal,
    direction: Direction = .ltr,

    font_size: f32 = 16,
    font_family: []const u8 = "serif",
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    color: []const u8 = "black",
    background: ?[]const u8 = null,
    background_image: []const u8 = "none",
    background_position: []const u8 = "0% 0%",
    background_size: []const u8 = "auto",
    background_repeat: []const u8 = "repeat",
    box_shadow: []const u8 = "none",
    text_shadow: []const u8 = "none",

    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .auto,
    max_width: Length = .auto,
    min_height: Length = .auto,
    max_height: Length = .auto,

    line_height: f32 = 18,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    text_indent: Length = .{ .px = 0 },
    text_align: TextAlign = .start,
    text_transform: TextTransform = .none,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    overflow: Overflow = .visible,
    text_overflow: TextOverflow = .clip,
    aspect_ratio: AspectRatio = .{},
    object_fit: ObjectFit = .fill,
    object_position: ObjectPosition = .{},
    vertical_align: VerticalAlign = .baseline,
    text_decoration: TextDecoration = .none,
    text_decoration_style: TextDecorationStyle = .solid,
    text_decoration_color: ?[]const u8 = null,
    text_decoration_thickness: TextDecorationThickness = .auto,

    box_sizing: BoxSizing = .contentBox,
    box_decoration_break: BoxDecorationBreak = .slice,
    list_style_type: ListStyleType = .disc,
    list_style_position: ListStylePosition = .outside,
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Length = .auto,
    order: i32 = 0,
    row_gap: Length = .{ .px = 0 },
    column_gap: Length = .{ .px = 0 },
    justify_content: JustifyContent = .normal,
    align_items: AlignItems = .stretch,
    align_self: AlignSelf = .auto,
    align_content: AlignContent = .stretch,
    justify_items: AlignItems = .stretch,
    justify_self: AlignSelf = .auto,
    grid_template_columns: []const u8 = "none",
    grid_template_rows: []const u8 = "none",
    grid_template_areas: []const u8 = "none",
    grid_auto_columns: []const u8 = "auto",
    grid_auto_rows: []const u8 = "auto",
    grid_auto_flow: GridAutoFlow = .row,
    grid_column_start: GridLine = .auto,
    grid_column_end: GridLine = .auto,
    grid_row_start: GridLine = .auto,
    grid_row_end: GridLine = .auto,
    border_collapse: BorderCollapse = .separate,
    caption_side: CaptionSide = .top,
    border_radius: f32 = 0,
    border_radii: BorderRadii = .{},

    page_break_before: PageBreak = .auto,
    page_break_after: PageBreak = .auto,
    page_break_inside: PageBreak = .auto,
    page_name: []const u8 = "auto",
    orphans: u32 = 2,
    widows: u32 = 2,

    margin: EdgeSizes = .{},
    margin_auto: AutoEdges = .{},
    border: EdgeSizes = .{},
    padding: EdgeSizes = .{},

    border_top_style: BorderStyle = .none,
    border_right_style: BorderStyle = .none,
    border_bottom_style: BorderStyle = .none,
    border_left_style: BorderStyle = .none,
    border_top_color: []const u8 = "black",
    border_right_color: []const u8 = "black",
    border_bottom_color: []const u8 = "black",
    border_left_color: []const u8 = "black",
};

/// Renderable unit produced from the DOM.
///
/// Geometry starts nullable because this phase describes structure, not layout.
/// The original `dom.NodeId` is kept for text, attributes, and debugging; boxes
/// created by normalization have no DOM node.
pub const Box = struct {
    kind: BoxType,
    node: ?dom.NodeId = null,
    language: []const u8 = "",

    parent: ?BoxId = null,
    first_child: ?BoxId = null,
    last_child: ?BoxId = null,
    next_sibling: ?BoxId = null,
    prev_sibling: ?BoxId = null,

    content_width: ?f32 = null,
    content_height: ?f32 = null,
    x: f32 = 0,
    y: f32 = 0,

    margin: EdgeSizes = .{},
    border: EdgeSizes = .{},
    padding: EdgeSizes = .{},

    style: Style = .{},
    text: ?[]const u8 = null,

    intrinsic_width: ?f32 = null,
    intrinsic_height: ?f32 = null,
    intrinsic_ratio: ?f32 = null,

    is_floating: bool = false,
    is_positioned: bool = false,
    is_out_of_flow: bool = false,
};

/// Owns all boxes for one rendered subtree.
///
/// The caller owns the allocator lifetime. Text slices and DOM references point
/// back into the parsed document, so the document must outlive the tree.
pub const BoxTree = struct {
    boxes: std.ArrayList(Box),
    root: BoxId,

    /// Releases only Box Tree storage; DOM source slices are owned elsewhere.
    pub fn deinit(self: *BoxTree, allocator: std.mem.Allocator) void {
        self.boxes.deinit(allocator);
    }

    /// Compact structural dump for tests that should not care about style noise.
    pub fn dump(self: *const BoxTree, document: *const dom.Document, writer: *std.Io.Writer) !void {
        try dumpBox(self, document, self.root, 0, writer);
    }

    /// Debug dump for inspecting which style inputs reached each box.
    pub fn dumpWithStyles(self: *const BoxTree, document: *const dom.Document, writer: *std.Io.Writer) !void {
        try dumpBoxWithStyles(self, document, self.root, 0, writer);
    }
};

/// Errors that describe a structurally impossible Box Tree result.
pub const BuildError = error{
    RootDoesNotGenerateBox,
};

/// Converts a DOM subtree into the intermediate tree consumed by layout.
pub const Builder = struct {
    /// Builds raw boxes, then normalizes anonymous block boxes.
    ///
    /// `styles` is indexed by `dom.NodeId`. Missing entries fall back to
    /// `defaultStyleForNode`, which keeps this module usable before a real CSS
    /// cascade module is wired in.
    pub fn build(
        allocator: std.mem.Allocator,
        document: *const dom.Document,
        styles: []const Style,
        root_node: dom.NodeId,
    ) !BoxTree {
        var state = BuildState{
            .allocator = allocator,
            .document = document,
            .styles = styles,
            .boxes = try std.ArrayList(Box).initCapacity(allocator, 0),
        };
        errdefer state.boxes.deinit(allocator);

        const root = (try state.buildNode(root_node, null)) orelse return BuildError.RootDoesNotGenerateBox;

        var tree = BoxTree{
            .boxes = state.boxes,
            .root = root,
        };
        errdefer tree.deinit(allocator);

        try normalizeAnonymousFlexItems(&tree, allocator, tree.root);
        try normalizeAnonymousBlocks(&tree, allocator, tree.root);
        try normalizeAnonymousTables(&tree, allocator, tree.root);
        return tree;
    }
};

/// Mutable state for a single build call.
///
/// Keeping it private lets `Builder.build` expose a small API while the recursive
/// walk can still share allocator, DOM, styles, and partially built boxes.
const BuildState = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    styles: []const Style,
    boxes: std.ArrayList(Box),

    /// Walks DOM nodes and emits the raw box tree before CSS anonymous boxes.
    ///
    /// The DOM document node becomes an anonymous block so callers can build from
    /// either a document root or a concrete renderable element.
    fn buildNode(self: *BuildState, node_id: dom.NodeId, parent_box: ?BoxId) !?BoxId {
        const node = self.document.nodes.items[node_id];

        switch (node.kind) {
            .document => {
                const root_box = try self.appendBox(.{
                    .kind = .anonymousBlock,
                    .style = defaultStyleForNode(self.document, node_id),
                }, parent_box);

                var child = node.first_child;
                while (child) |child_id| {
                    _ = try self.buildNode(child_id, root_box);
                    child = self.document.nodes.items[child_id].next_sibling;
                }

                return root_box;
            },
            .text => |text| return try self.buildTextBox(node_id, text, parent_box),
            .element => |element| {
                if (isNonRenderingElement(element.name)) return null;

                const style = self.styleForNode(node_id);
                if (style.display == .none) return null;

                if (element.tag == .br) {
                    return try self.appendBox(.{
                        .kind = .lineBreak,
                        .node = node_id,
                        .language = self.languageForElement(element, parent_box),
                        .style = style,
                    }, parent_box);
                }

                var box = Box{
                    .kind = boxTypeForElement(element, style),
                    .node = node_id,
                    .language = self.languageForElement(element, parent_box),
                    .style = style,
                    .margin = style.margin,
                    .border = style.border,
                    .padding = style.padding,
                    .is_floating = style.float_direction != .none,
                    .is_positioned = style.position != .static,
                    .is_out_of_flow = style.position == .absolute or style.position == .fixed,
                };

                if (box.kind == .replaced) {
                    fillIntrinsicSize(&box, element);
                }

                const box_id = try self.appendBox(box, parent_box);

                var child = node.first_child;
                while (child) |child_id| {
                    _ = try self.buildNode(child_id, box_id);
                    child = self.document.nodes.items[child_id].next_sibling;
                }

                return box_id;
            },
        }
    }

    /// Text boxes inherit text-facing style but stay inline participants.
    ///
    /// Inheriting `display` or box-model edges from a block parent would turn text
    /// into block layout input, which is not how CSS inline content behaves.
    fn buildTextBox(self: *BuildState, node_id: dom.NodeId, text: []const u8, parent_box: ?BoxId) !?BoxId {
        const style = self.inheritedTextStyle(parent_box);

        if (collapsesWhitespace(style.white_space) and isOnlyHtmlWhitespace(text)) {
            return null;
        }

        return try self.appendBox(.{
            .kind = .text,
            .node = node_id,
            .language = if (parent_box) |box_id| self.boxes.items[box_id].language else "",
            .style = style,
            .text = text,
        }, parent_box);
    }

    fn languageForElement(self: *const BuildState, element: dom.Element, parent_box: ?BoxId) []const u8 {
        return getAttributeValue(element.attributes, "lang") orelse
            if (parent_box) |box_id| self.boxes.items[box_id].language else "";
    }

    /// Accepts sparse style arrays while CSS cascade is still a separate concern.
    fn styleForNode(self: *const BuildState, node_id: dom.NodeId) Style {
        if (node_id < self.styles.len) return self.styles[node_id];
        return defaultStyleForNode(self.document, node_id);
    }

    /// Preserves inherited typography and whitespace without copying layout-only
    /// properties that belong to the parent element's own box.
    fn inheritedTextStyle(self: *const BuildState, parent_box: ?BoxId) Style {
        var style: Style = if (parent_box) |box_id| self.boxes.items[box_id].style else .{};

        style.display = .inlineBox;
        style.position = .static;
        style.insets = .{};
        style.z_index = null;
        style.opacity = 1;
        style.transform = &.{};
        style.transform_origin = .{};
        style.float_direction = .none;
        style.clear_direction = .none;
        style.background = null;
        style.background_image = "none";
        style.background_position = "0% 0%";
        style.background_size = "auto";
        style.background_repeat = "repeat";
        style.box_shadow = "none";
        style.width = .auto;
        style.height = .auto;
        style.min_width = .auto;
        style.max_width = .auto;
        style.min_height = .auto;
        style.max_height = .auto;
        style.margin = .{};
        style.margin_auto = .{};
        style.border = .{};
        style.padding = .{};
        style.border_top_style = .none;
        style.border_right_style = .none;
        style.border_bottom_style = .none;
        style.border_left_style = .none;
        style.border_radius = 0;
        style.border_radii = .{};
        style.border_top_color = "black";
        style.border_right_color = "black";
        style.border_bottom_color = "black";
        style.border_left_color = "black";
        style.page_break_before = .auto;
        style.page_break_after = .auto;
        style.page_break_inside = .auto;
        style.vertical_align = .baseline;
        style.overflow = .visible;
        style.text_overflow = .clip;
        style.aspect_ratio = .{};
        style.object_fit = .fill;
        style.object_position = .{};
        style.box_decoration_break = .slice;
        style.flex_direction = .row;
        style.flex_wrap = .nowrap;
        style.flex_grow = 0;
        style.flex_shrink = 1;
        style.flex_basis = .auto;
        style.order = 0;
        style.row_gap = .{ .px = 0 };
        style.column_gap = .{ .px = 0 };
        style.justify_content = .normal;
        style.align_items = .stretch;
        style.align_self = .auto;
        style.align_content = .stretch;
        style.justify_items = .stretch;
        style.justify_self = .auto;
        style.grid_template_columns = "none";
        style.grid_template_rows = "none";
        style.grid_template_areas = "none";
        style.grid_auto_columns = "auto";
        style.grid_auto_rows = "auto";
        style.grid_auto_flow = .row;
        style.grid_column_start = .auto;
        style.grid_column_end = .auto;
        style.grid_row_start = .auto;
        style.grid_row_end = .auto;

        return style;
    }

    /// Appends a box and wires sibling links immediately.
    ///
    /// All tree rewrites later reuse the same link shape, so there is one boring
    /// place responsible for parent/child bookkeeping during initial construction.
    fn appendBox(self: *BuildState, box: Box, parent_box: ?BoxId) !BoxId {
        const box_id = self.boxes.items.len;
        var next_box = box;
        next_box.parent = parent_box;
        try self.boxes.append(self.allocator, next_box);

        if (parent_box) |parent_id| {
            appendExistingChild(&self.boxes, parent_id, box_id);
        }

        return box_id;
    }
};

/// Temporary UA-style fallback used until CSS cascade produces every `Style`.
///
/// Keeping this here makes Box Tree tests independent from the future CSS parser
/// while still preserving the browser-default block/inline split.
pub fn defaultStyleForNode(document: *const dom.Document, node_id: dom.NodeId) Style {
    const node = document.nodes.items[node_id];

    return switch (node.kind) {
        .document => .{ .display = .block },
        .text => .{ .display = .inlineBox },
        .element => |element| {
            if (isNonRenderingElement(element.name)) return .{ .display = .none };

            const display = determineElementDisplay(element);
            var style = Style{ .display = display };
            if (uaListStyleTypeForNode(document, node_id)) |list_style_type| {
                style.list_style_type = list_style_type;
            }

            const heading_defaults = .{
                .{ dom.Tag.h1, 32, 21.44, 21.44 },
                .{ dom.Tag.h2, 24, 19.92, 19.92 },
                .{ dom.Tag.h3, 18.72, 18.72, 18.72 },
                .{ dom.Tag.h4, 16, 21.28, 21.28 },
                .{ dom.Tag.h5, 13.28, 22.177, 22.177 },
                .{ dom.Tag.h6, 10.72, 24.977, 24.977 },
            };
            inline for (heading_defaults) |h| {
                if (element.tag == h[0]) {
                    style.font_size = h[1];
                    style.margin = .{ .top = h[2], .bottom = h[3] };
                    break;
                }
            } else {
                switch (element.tag) {
                    .p => {
                        style.margin = .{ .top = 16, .bottom = 16 };
                    },
                    .ul, .ol => {
                        style.margin = .{ .top = 16, .bottom = 16 };
                        style.padding = .{ .left = 40 };
                    },
                    .strong => style.font_weight = .bold,
                    .em => style.font_style = .italic,
                    .a => {
                        style.color = "#0000ee";
                        style.text_decoration = .underline;
                    },
                    else => {},
                }
            }
            return style;
        },
    };
}

/// Maps an element to its display type using tag enum first, then name strings.
fn determineElementDisplay(element: dom.Element) Display {
    return switch (element.tag) {
        .h1, .h2, .h3, .h4, .h5, .h6, .p, .div, .ul, .ol, .html, .body => .block,
        .li => .listItem,
        .table => .table,
        .tr => .tableRow,
        .td, .th => .tableCell,
        else => determineElementDisplayByName(element.name),
    };
}

/// Returns the HTML presentational hint that acts like a user-agent list rule.
pub fn uaListStyleTypeForNode(document: *const dom.Document, node_id: dom.NodeId) ?ListStyleType {
    const element = switch (document.nodes.items[node_id].kind) {
        .element => |value| value,
        else => return null,
    };
    if (element.tag != .ul and element.tag != .ol and element.tag != .li) return null;

    for (element.attributes) |attribute| {
        if (!std.ascii.eqlIgnoreCase(attribute.name, "type")) continue;
        const value = attribute.value orelse break;
        if (std.mem.eql(u8, value, "1")) return .decimal;
        if (std.mem.eql(u8, value, "a")) return .lowerAlpha;
        if (std.mem.eql(u8, value, "A")) return .upperAlpha;
        if (std.mem.eql(u8, value, "i")) return .lowerRoman;
        if (std.mem.eql(u8, value, "I")) return .upperRoman;
        if (std.ascii.eqlIgnoreCase(value, "disc")) return .disc;
        if (std.ascii.eqlIgnoreCase(value, "circle")) return .circle;
        if (std.ascii.eqlIgnoreCase(value, "square")) return .square;
        break;
    }

    return switch (element.tag) {
        .ul => .disc,
        .ol => .decimal,
        else => null,
    };
}

fn determineElementDisplayByName(name: []const u8) Display {
    if (std.ascii.eqlIgnoreCase(name, "article") or
        std.ascii.eqlIgnoreCase(name, "aside") or
        std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "header") or
        std.ascii.eqlIgnoreCase(name, "main") or
        std.ascii.eqlIgnoreCase(name, "nav") or
        std.ascii.eqlIgnoreCase(name, "section"))
        return .block;
    if (std.ascii.eqlIgnoreCase(name, "thead") or
        std.ascii.eqlIgnoreCase(name, "tbody") or
        std.ascii.eqlIgnoreCase(name, "tfoot"))
        return .tableRowGroup;
    if (std.ascii.eqlIgnoreCase(name, "caption")) return .tableCaption;
    if (std.ascii.eqlIgnoreCase(name, "col")) return .tableColumn;
    if (std.ascii.eqlIgnoreCase(name, "colgroup")) return .tableColumnGroup;
    return .inlineBox;
}

/// Moves an already allocated box under a parent.
///
/// Normalization reuses boxes instead of cloning them, preserving `BoxId` values
/// that tests or later phases may already hold.
fn appendExistingChild(boxes: *std.ArrayList(Box), parent_id: BoxId, child_id: BoxId) void {
    const last_child = boxes.items[parent_id].last_child;

    boxes.items[child_id].parent = parent_id;
    boxes.items[child_id].prev_sibling = last_child;
    boxes.items[child_id].next_sibling = null;

    if (last_child) |last_child_id| {
        boxes.items[last_child_id].next_sibling = child_id;
    } else {
        boxes.items[parent_id].first_child = child_id;
    }

    boxes.items[parent_id].last_child = child_id;
}

/// Allocates boxes introduced by normalization, not by DOM nodes.
fn appendDetachedBox(tree: *BoxTree, allocator: std.mem.Allocator, box: Box) !BoxId {
    const box_id = tree.boxes.items.len;
    try tree.boxes.append(allocator, box);
    return box_id;
}

/// Runs after raw construction so DOM walking stays simple.
///
/// This pass is where CSS structural rules reshape the tree without mixing those
/// rules into tag handling or text handling.
fn normalizeAnonymousBlocks(tree: *BoxTree, allocator: std.mem.Allocator, box_id: BoxId) !void {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;
        try normalizeAnonymousBlocks(tree, allocator, child_id);
        child = next;
    }

    if (!isBlockContainer(tree.boxes.items[box_id].kind)) return;
    try wrapInlineRuns(tree, allocator, box_id);
}

/// Wraps consecutive inline participants when they share a block container with
/// real block children.
///
/// Pure-inline containers are left alone; wrapping them early would create extra
/// boxes the inline layout stage does not need.
fn wrapInlineRuns(tree: *BoxTree, allocator: std.mem.Allocator, parent_id: BoxId) !void {
    var has_inline = false;
    var has_block = false;

    var child = tree.boxes.items[parent_id].first_child;
    while (child) |child_id| {
        if (isInlineLevelBox(tree.boxes.items[child_id])) {
            has_inline = true;
        } else {
            has_block = true;
        }
        child = tree.boxes.items[child_id].next_sibling;
    }

    if (!has_inline or !has_block) return;
    try wrapChildRuns(tree, allocator, parent_id, .anonymousBlock, isInlineLevelBox, anonymousStyle);
}

/// CSS turns direct text children of flex containers into anonymous flex items.
/// Grouping consecutive text boxes here lets the normal block and inline
/// formatters preserve selectable text without teaching flex layout about DOM
/// text nodes.
fn normalizeAnonymousFlexItems(tree: *BoxTree, allocator: std.mem.Allocator, box_id: BoxId) !void {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;
        try normalizeAnonymousFlexItems(tree, allocator, child_id);
        child = next;
    }

    const display = tree.boxes.items[box_id].style.display;
    if (display != .flex and display != .inlineFlex) return;
    try wrapChildRuns(tree, allocator, box_id, .anonymousBlock, isTextBox, anonymousFlexItemStyle);
}

/// Runs after anonymous-block normalization, wrapping orphan table cells in
/// anonymous table-row boxes.
///
/// Orphan rows remain direct table children because layout intentionally accepts
/// both direct rows and row groups.
fn wrapTableCellRuns(tree: *BoxTree, allocator: std.mem.Allocator, parent_id: BoxId) !void {
    try wrapChildRuns(tree, allocator, parent_id, .anonymousTableRow, isTableWrappableBox, anonymousStyle);
}

/// Common rebuild loop for anonymous box normalization.
/// Scans children, groups consecutive wrappable boxes under a new anonymous
/// box of the given kind, and leaves non-wrappable boxes in place.
fn wrapChildRuns(
    tree: *BoxTree,
    allocator: std.mem.Allocator,
    parent_id: BoxId,
    anon_kind: BoxType,
    shouldWrap: fn (Box) bool,
    makeStyle: fn (Style) Style,
) !void {
    const old_first = tree.boxes.items[parent_id].first_child;
    var new_first: ?BoxId = null;
    var new_last: ?BoxId = null;
    var current_run: ?BoxId = null;

    tree.boxes.items[parent_id].first_child = null;
    tree.boxes.items[parent_id].last_child = null;

    var child = old_first;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;

        if (shouldWrap(tree.boxes.items[child_id])) {
            if (current_run == null) {
                const anonymous_id = try appendDetachedBox(tree, allocator, .{
                    .kind = anon_kind,
                    .style = makeStyle(tree.boxes.items[parent_id].style),
                });
                appendToRebuiltChildList(tree, parent_id, anonymous_id, &new_first, &new_last);
                current_run = anonymous_id;
            }
            appendExistingChild(&tree.boxes, current_run.?, child_id);
        } else {
            current_run = null;
            appendToRebuiltChildList(tree, parent_id, child_id, &new_first, &new_last);
        }

        child = next;
    }

    tree.boxes.items[parent_id].first_child = new_first;
    tree.boxes.items[parent_id].last_child = new_last;
}

fn isTableWrappableBox(box: Box) bool {
    return box.kind == .tableCell or isInlineLevelBox(box);
}

fn isTextBox(source: Box) bool {
    return source.kind == .text;
}

fn anonymousFlexItemStyle(parent: Style) Style {
    var style = anonymousStyle(parent);
    style.display = .block;
    return style;
}

fn anonymousStyle(parent: Style) Style {
    var style = parent;
    style.position = .static;
    style.insets = .{};
    style.z_index = null;
    style.opacity = 1;
    style.transform = &.{};
    style.transform_origin = .{};
    style.float_direction = .none;
    style.clear_direction = .none;
    style.background = null;
    style.background_image = "none";
    style.background_position = "0% 0%";
    style.background_size = "auto";
    style.background_repeat = "repeat";
    style.box_shadow = "none";
    style.width = .auto;
    style.height = .auto;
    style.min_width = .auto;
    style.max_width = .auto;
    style.min_height = .auto;
    style.max_height = .auto;
    style.margin = .{};
    style.margin_auto = .{};
    style.border = .{};
    style.padding = .{};
    style.border_top_style = .none;
    style.border_right_style = .none;
    style.border_bottom_style = .none;
    style.border_left_style = .none;
    style.border_radius = 0;
    style.border_radii = .{};
    style.page_break_before = .auto;
    style.page_break_after = .auto;
    style.page_break_inside = .auto;
    style.box_decoration_break = .slice;
    style.flex_direction = .row;
    style.flex_wrap = .nowrap;
    style.flex_grow = 0;
    style.flex_shrink = 1;
    style.flex_basis = .auto;
    style.order = 0;
    style.row_gap = .{ .px = 0 };
    style.column_gap = .{ .px = 0 };
    style.justify_content = .normal;
    style.align_items = .stretch;
    style.align_self = .auto;
    style.align_content = .stretch;
    style.justify_items = .stretch;
    style.justify_self = .auto;
    style.grid_template_columns = "none";
    style.grid_template_rows = "none";
    style.grid_template_areas = "none";
    style.grid_auto_columns = "auto";
    style.grid_auto_rows = "auto";
    style.grid_auto_flow = .row;
    style.grid_column_start = .auto;
    style.grid_column_end = .auto;
    style.grid_row_start = .auto;
    style.grid_row_end = .auto;
    return style;
}

/// Rebuilds one parent's child list without reallocating existing boxes.
fn appendToRebuiltChildList(
    tree: *BoxTree,
    parent_id: BoxId,
    child_id: BoxId,
    first_child: *?BoxId,
    last_child: *?BoxId,
) void {
    tree.boxes.items[child_id].parent = parent_id;
    tree.boxes.items[child_id].prev_sibling = last_child.*;
    tree.boxes.items[child_id].next_sibling = null;

    if (last_child.*) |last_child_id| {
        tree.boxes.items[last_child_id].next_sibling = child_id;
    } else {
        first_child.* = child_id;
    }

    last_child.* = child_id;
}

fn normalizeAnonymousTables(tree: *BoxTree, allocator: std.mem.Allocator, box_id: BoxId) !void {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;
        try normalizeAnonymousTables(tree, allocator, child_id);
        child = next;
    }

    if (tree.boxes.items[box_id].kind == .table or tree.boxes.items[box_id].kind == .tableRowGroup) {
        try wrapTableCellRuns(tree, allocator, box_id);
    }
}

fn isBlockContainer(kind: BoxType) bool {
    return kind == .block or kind == .listItem or kind == .anonymousBlock or kind == .inlineBlock or kind == .tableCell or kind == .tableCaption;
}

/// Classifies the external block formatting role of a normalized box.
///
/// Replaced elements retain their own box kind, so their computed `display`
/// value must participate in the decision instead of relying on kind alone.
pub fn isBlockLevelBox(source: Box) bool {
    return switch (source.kind) {
        .block, .listItem, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .tableCaption, .anonymousTableRow => true,
        .replaced => source.style.display == .block,
        else => false,
    };
}

/// Classifies the external formatting role used by anonymous-box normalization.
fn isInlineLevelBox(box: Box) bool {
    return switch (box.kind) {
        .inlineBox, .inlineBlock, .text, .anonymousInline, .lineBreak => true,
        .replaced => box.style.display != .block,
        else => false,
    };
}

/// Maps style display and replaced-element status to the initial box kind.
fn boxTypeForElement(element: dom.Element, style: Style) BoxType {
    if (isReplacedElement(element.tag)) return .replaced;

    return switch (style.display) {
        .block => .block,
        .listItem => .listItem,
        .inlineBox => .inlineBox,
        .inlineBlock => .inlineBlock,
        .flex => .block,
        .inlineFlex => .inlineBlock,
        .grid => .block,
        .inlineGrid => .inlineBlock,
        .table => .table,
        .tableRow => .tableRow,
        .tableCell => .tableCell,
        .tableRowGroup => .tableRowGroup,
        .tableCaption => .tableCaption,
        .tableColumn => .tableColumn,
        .tableColumnGroup => .tableColumnGroup,
        .none => unreachable,
    };
}

fn isReplacedElement(tag: dom.Tag) bool {
    return switch (tag) {
        .img => true,
        else => false,
    };
}

/// Elements whose contents are parser data or metadata, not PDF layout input.
fn isNonRenderingElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "head") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "title") or
        std.ascii.eqlIgnoreCase(name, "meta") or
        std.ascii.eqlIgnoreCase(name, "link");
}

/// Captures cheap intrinsic data available from attributes.
///
/// Reading actual image headers belongs in a later resource loader; the Box Tree
/// should not perform filesystem or network work.
fn fillIntrinsicSize(box: *Box, element: dom.Element) void {
    box.intrinsic_width = parsePositiveFloat(getAttributeValue(element.attributes, "data-html2realpdf-intrinsic-width")) orelse
        parsePositiveFloat(getAttributeValue(element.attributes, "width"));
    box.intrinsic_height = parsePositiveFloat(getAttributeValue(element.attributes, "data-html2realpdf-intrinsic-height")) orelse
        parsePositiveFloat(getAttributeValue(element.attributes, "height"));

    if (box.intrinsic_width) |width| {
        if (box.intrinsic_height) |height| {
            if (height > 0) box.intrinsic_ratio = width / height;
        }
    }
}

fn getAttributeValue(attributes: []const html.Attribute, name: []const u8) ?[]const u8 {
    // Attribute lists are normally tiny. A linear lookup keeps ownership simple
    // and avoids allocating a map for every DOM element.
    for (attributes) |attribute| {
        if (std.ascii.eqlIgnoreCase(attribute.name, name)) return attribute.value;
    }

    return null;
}

fn parsePositiveFloat(value: ?[]const u8) ?f32 {
    const text = value orelse return null;
    const parsed = std.fmt.parseFloat(f32, text) catch return null;
    if (parsed <= 0) return null;
    return parsed;
}

fn collapsesWhitespace(white_space: WhiteSpace) bool {
    return white_space == .normal or white_space == .nowrap or white_space == .preLine;
}

fn isOnlyHtmlWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (!(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C)) return false;
    }

    return true;
}

fn dumpBox(tree: *const BoxTree, document: *const dom.Document, box_id: BoxId, depth: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const box = tree.boxes.items[box_id];
    try writeBoxLabel(box, document, writer);
    try writer.writeAll("\n");

    var child = box.first_child;
    while (child) |child_id| {
        try dumpBox(tree, document, child_id, depth + 1, writer);
        child = tree.boxes.items[child_id].next_sibling;
    }
}

/// Verbose dump used when inspecting style propagation and layout flags.
fn dumpBoxWithStyles(tree: *const BoxTree, document: *const dom.Document, box_id: BoxId, depth: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const box = tree.boxes.items[box_id];
    try writeBoxLabel(box, document, writer);
    try writeBoxStyleDebug(box, writer);
    try writer.writeAll("\n");

    var child = box.first_child;
    while (child) |child_id| {
        try dumpBoxWithStyles(tree, document, child_id, depth + 1, writer);
        child = tree.boxes.items[child_id].next_sibling;
    }
}

fn writeBoxLabel(box: Box, document: *const dom.Document, writer: *std.Io.Writer) !void {
    try writer.writeAll(box.kind.toString());

    if (box.node) |node_id| {
        switch (document.nodes.items[node_id].kind) {
            .element => |element| try writer.print(" {s}", .{element.name}),
            .text => |text| try writer.print(" \"{s}\"", .{text}),
            .document => {},
        }
    }
}

/// Keeps debug output compact by printing only layout-relevant style state.
fn writeBoxStyleDebug(box: Box, writer: *std.Io.Writer) !void {
    const style = box.style;

    try writer.print(
        " [display={s} position={s} float={s} white-space={s} font-size={d:.2} font-family=\"{s}\" color={s}",
        .{
            style.display.toString(),
            style.position.toString(),
            style.float_direction.toString(),
            style.white_space.toString(),
            style.font_size,
            style.font_family,
            style.color,
        },
    );

    if (style.background) |background| {
        try writer.print(" background={s}", .{background});
    }
    if (style.clear_direction != .none) try writer.print(" clear={s}", .{style.clear_direction.toString()});
    if (style.font_weight != .normal) try writer.print(" font-weight={s}", .{style.font_weight.toString()});
    if (style.font_style != .normal) try writer.print(" font-style={s}", .{style.font_style.toString()});
    if (style.text_decoration != .none) try writer.print(" text-decoration={s}", .{style.text_decoration.toString()});
    if (style.text_decoration_style != .solid) try writer.print(" text-decoration-style={s}", .{style.text_decoration_style.toString()});
    if (style.text_decoration_color) |color| try writer.print(" text-decoration-color={s}", .{color});
    switch (style.text_decoration_thickness) {
        .auto => {},
        .fromFont => try writer.writeAll(" text-decoration-thickness=from-font"),
        .length => |length| try writeLengthDebug("text-decoration-thickness", length, writer),
    }
    try writeLengthDebug("width", style.width, writer);
    try writeLengthDebug("height", style.height, writer);
    try writeLengthDebug("min-width", style.min_width, writer);
    try writeLengthDebug("max-width", style.max_width, writer);
    if (style.line_height != 18) try writer.print(" line-height={d:.2}", .{style.line_height});
    if (style.letter_spacing != 0) try writer.print(" letter-spacing={d:.2}", .{style.letter_spacing});
    if (style.word_spacing != 0) try writer.print(" word-spacing={d:.2}", .{style.word_spacing});
    switch (style.text_indent) {
        .px => |value| if (value != 0) try writer.print(" text-indent={d:.2}", .{value}),
        else => try writeLengthDebug("text-indent", style.text_indent, writer),
    }
    if (style.text_align != .start) try writer.print(" text-align={s}", .{style.text_align.toString()});
    if (style.text_transform != .none) try writer.print(" text-transform={s}", .{style.text_transform.toString()});
    if (style.word_break != .normal) try writer.print(" word-break={s}", .{style.word_break.toString()});
    if (style.overflow_wrap != .normal) try writer.print(" overflow-wrap={s}", .{style.overflow_wrap.toString()});
    if (style.overflow != .visible) try writer.print(" overflow={s}", .{style.overflow.toString()});
    if (style.text_overflow != .clip) try writer.print(" text-overflow={s}", .{style.text_overflow.toString()});
    switch (style.vertical_align) {
        .baseline => {},
        .sub => try writer.writeAll(" vertical-align=sub"),
        .super => try writer.writeAll(" vertical-align=super"),
        .textTop => try writer.writeAll(" vertical-align=text-top"),
        .textBottom => try writer.writeAll(" vertical-align=text-bottom"),
        .middle => try writer.writeAll(" vertical-align=middle"),
        .top => try writer.writeAll(" vertical-align=top"),
        .bottom => try writer.writeAll(" vertical-align=bottom"),
        .offset => |offset| try writeLengthDebug("vertical-align", offset, writer),
    }
    if (style.box_sizing != .contentBox) try writer.print(" box-sizing={s}", .{style.box_sizing.toString()});
    if (style.border_collapse != .separate) try writer.print(" border-collapse={s}", .{style.border_collapse.toString()});
    if (style.page_break_before != .auto) try writer.print(" page-break-before={s}", .{style.page_break_before.toString()});
    if (style.page_break_after != .auto) try writer.print(" page-break-after={s}", .{style.page_break_after.toString()});
    if (style.page_break_inside != .auto) try writer.print(" page-break-inside={s}", .{style.page_break_inside.toString()});
    if (style.orphans != 2) try writer.print(" orphans={d}", .{style.orphans});
    if (style.widows != 2) try writer.print(" widows={d}", .{style.widows});
    if (style.border_top_style != .none) try writer.print(" border-top-style={s}", .{style.border_top_style.toString()});
    if (style.border_right_style != .none) try writer.print(" border-right-style={s}", .{style.border_right_style.toString()});
    if (style.border_bottom_style != .none) try writer.print(" border-bottom-style={s}", .{style.border_bottom_style.toString()});
    if (style.border_left_style != .none) try writer.print(" border-left-style={s}", .{style.border_left_style.toString()});

    try writeEdgeDebug("margin", box.margin, writer);
    try writeEdgeDebug("border", box.border, writer);
    try writeEdgeDebug("padding", box.padding, writer);

    if (box.is_out_of_flow) try writer.writeAll(" out-of-flow=true");
    if (box.is_positioned) try writer.writeAll(" positioned=true");
    if (box.is_floating) try writer.writeAll(" floating=true");

    if (box.intrinsic_width != null or box.intrinsic_height != null) {
        try writer.writeAll(" intrinsic=");
        if (box.intrinsic_width) |width| {
            try writer.print("{d:.2}", .{width});
        } else {
            try writer.writeAll("auto");
        }

        try writer.writeAll("x");

        if (box.intrinsic_height) |height| {
            try writer.print("{d:.2}", .{height});
        } else {
            try writer.writeAll("auto");
        }
    }

    if (box.intrinsic_ratio) |ratio| {
        try writer.print(" ratio={d:.2}", .{ratio});
    }

    try writer.writeAll("]");
}

fn writeLengthDebug(name: []const u8, length: Length, writer: *std.Io.Writer) !void {
    switch (length) {
        .auto => {},
        .px => |value| try writer.print(" {s}={d:.2}", .{ name, value }),
        .percent => |ratio| try writer.print(" {s}={d:.2}%", .{ name, ratio * 100 }),
        .expression => try writer.print(" {s}=<calc>", .{name}),
        .minContent => try writer.print(" {s}=min-content", .{name}),
        .maxContent => try writer.print(" {s}=max-content", .{name}),
        .fitContent => try writer.print(" {s}=fit-content", .{name}),
    }
}

fn writeEdgeDebug(name: []const u8, edge: EdgeSizes, writer: *std.Io.Writer) !void {
    if (edgeIsZero(edge)) return;

    try writer.print(
        " {s}={d:.2},{d:.2},{d:.2},{d:.2}",
        .{ name, edge.top, edge.right, edge.bottom, edge.left },
    );
}

fn edgeIsZero(edge: EdgeSizes) bool {
    return edge.top == 0 and edge.right == 0 and edge.bottom == 0 and edge.left == 0;
}

fn deinitTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(html.Token)) void {
    for (tokens.items) |token| {
        switch (token) {
            .tag_open => |open_tag| allocator.free(open_tag.attributes),
            else => {},
        }
    }

    tokens.deinit(allocator);
}

test "build block and inline boxes from DOM" {
    const allocator = std.testing.allocator;
    const source = "<div><p>Hello <strong>world</strong></p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  block p
        \\    text "Hello "
        \\    inline strong
        \\      text "world"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "wrap mixed block and inline children in anonymous blocks" {
    const allocator = std.testing.allocator;
    const source = "<div>before<p>block</p><span>after</span></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  anonymous-block
        \\    text "before"
        \\  block p
        \\    text "block"
        \\  anonymous-block
        \\    inline span
        \\      text "after"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "wrap direct flex text in blockified anonymous items" {
    const allocator = std.testing.allocator;
    const source = "<span>N.R.<b>label</b>tail</span>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const span_id = document.nodes.items[document.root].first_child.?;
    const styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| style.* = defaultStyleForNode(&document, node_id);
    styles[span_id].display = .inlineFlex;
    styles[span_id].font_size = 18;
    styles[span_id].font_style = .italic;
    styles[span_id].flex_grow = 3;

    var tree = try Builder.build(allocator, &document, styles, span_id);
    defer tree.deinit(allocator);

    const first_item_id = tree.boxes.items[tree.root].first_child.?;
    const first_item = tree.boxes.items[first_item_id];
    try std.testing.expectEqual(BoxType.anonymousBlock, first_item.kind);
    try std.testing.expectEqual(Display.block, first_item.style.display);
    try std.testing.expectEqual(FontStyle.italic, first_item.style.font_style);
    try std.testing.expectApproxEqAbs(@as(f32, 18), first_item.style.font_size, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first_item.style.flex_grow, 0.01);

    const label_id = first_item.next_sibling.?;
    const last_item_id = tree.boxes.items[label_id].next_sibling.?;
    try std.testing.expectEqual(BoxType.anonymousBlock, tree.boxes.items[last_item_id].kind);
    try std.testing.expect(tree.boxes.items[last_item_id].next_sibling == null);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);
    const expected =
        \\inline-block span
        \\  anonymous-block
        \\    text "N.R."
        \\  anonymous-block
        \\    inline b
        \\      text "label"
        \\  anonymous-block
        \\    text "tail"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "create line break and replaced boxes" {
    const allocator = std.testing.allocator;
    const source = "<div>a<br><img width=100 height=50>b</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  text "a"
        \\  line-break br
        \\  replaced img
        \\  text "b"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());

    const a_id = tree.boxes.items[tree.root].first_child.?;
    const br_id = tree.boxes.items[a_id].next_sibling.?;
    const img_id = tree.boxes.items[br_id].next_sibling.?;
    try std.testing.expectEqual(BoxType.lineBreak, tree.boxes.items[br_id].kind);
    try std.testing.expectEqual(BoxType.replaced, tree.boxes.items[img_id].kind);
    try std.testing.expectEqual(@as(?f32, 100), tree.boxes.items[img_id].intrinsic_width);
    try std.testing.expectEqual(@as(?f32, 50), tree.boxes.items[img_id].intrinsic_height);
    try std.testing.expectEqual(@as(?f32, 2), tree.boxes.items[img_id].intrinsic_ratio);
}

test "skip display none subtree" {
    const allocator = std.testing.allocator;
    const source = "<div><p>gone</p><span>kept</span></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].display = .none;

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  inline span
        \\    text "kept"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "dump Box Tree with styles" {
    const allocator = std.testing.allocator;
    const source = "<div><p>x</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].font_size = 18.5;
    styles[p_id].color = "red";
    styles[p_id].margin.top = 4;
    styles[p_id].margin.bottom = 0;

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dumpWithStyles(&document, &writer);

    const dumped = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, dumped, "block p [display=block") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "font-size=18.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "color=red") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "margin=4.00,0.00,0.00,0.00") != null);
}

test "debug dump Box Tree" {
    if (!std.testing.environ.containsUnemptyConstant("HTML2REALPDF_DEBUG_BOX")) return;

    const allocator = std.testing.allocator;
    const source = "<div>a<br><img width=100 height=50><p>Hello <strong>world</strong></p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].last_child.?;
    const hello_id = document.nodes.items[p_id].first_child.?;
    const strong_id = document.nodes.items[hello_id].next_sibling.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].font_size = 18;
    styles[p_id].color = "red";
    styles[p_id].margin.top = 12;
    styles[strong_id].font_size = 18;
    styles[strong_id].color = "blue";
    styles[strong_id].background = "#eeeeee";

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dumpWithStyles(&document, &writer);

    std.debug.print("\n{s}", .{writer.buffered()});
}

test "build table tree from DOM" {
    const allocator = std.testing.allocator;
    const source = "<table><tr><td>cell</td></tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const table_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, table_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\table table
        \\  table-row tr
        \\    table-cell td
        \\      text "cell"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "preserve captions and column groups as table roles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<table><caption>Summary</caption><colgroup><col span='2'></colgroup><tr><td>A</td><td>B</td></tr></table>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const table_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, table_id);
    defer tree.deinit(allocator);

    const caption_id = tree.boxes.items[tree.root].first_child.?;
    const group_id = tree.boxes.items[caption_id].next_sibling.?;
    const column_id = tree.boxes.items[group_id].first_child.?;
    try std.testing.expectEqual(BoxType.tableCaption, tree.boxes.items[caption_id].kind);
    try std.testing.expectEqual(BoxType.tableColumnGroup, tree.boxes.items[group_id].kind);
    try std.testing.expectEqual(BoxType.tableColumn, tree.boxes.items[column_id].kind);
}

test "wrap orphan table cell in anonymous table row" {
    const allocator = std.testing.allocator;
    const source = "<table><td>cell</td></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const table_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, table_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\table table
        \\  anonymous-table-row
        \\    table-cell td
        \\      text "cell"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "inline-block box type distinct from inline" {
    const allocator = std.testing.allocator;
    const source = "<span>inline</span>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const span_id = document.nodes.items[document.root].first_child.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*s, node_id| {
        s.* = defaultStyleForNode(&document, node_id);
    }
    styles[span_id].display = .inlineBlock;

    var tree = try Builder.build(allocator, &document, styles, span_id);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(BoxType.inlineBlock, tree.boxes.items[tree.root].kind);
}

test "UA defaults set heading font-size and paragraph margins" {
    const allocator = std.testing.allocator;
    const source = "<h1>Title</h1><p>Text</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const root_id = document.root;

    var tree = try Builder.build(allocator, &document, &.{}, root_id);
    defer tree.deinit(allocator);

    const h1_box = tree.boxes.items[tree.boxes.items[tree.root].first_child.?];
    const p_box = tree.boxes.items[h1_box.next_sibling.?];

    try std.testing.expectEqual(@as(f32, 32), h1_box.style.font_size);
    try std.testing.expectEqual(@as(f32, 21.44), h1_box.style.margin.top);
    try std.testing.expectEqual(@as(f32, 16), p_box.style.margin.top);
    try std.testing.expectEqual(@as(f32, 16), p_box.style.margin.bottom);
}

test "text boxes do not inherit vertical-align from table cells" {
    const allocator = std.testing.allocator;
    const source = "<table><tr><td style='vertical-align:middle'>cell</td></tr></table>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (document.nodes.items, 0..) |node, node_id| {
        styles[node_id] = defaultStyleForNode(&document, node_id);
        if (node.kind == .element and node.kind.element.tag == .td) styles[node_id].vertical_align = .middle;
    }
    var tree = try Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);

    for (tree.boxes.items) |candidate| {
        if (candidate.kind != .text) continue;
        try std.testing.expect(candidate.style.vertical_align == .baseline);
        return;
    }
    return error.TestExpectedEqual;
}

test "text boxes inherit the nearest HTML language" {
    const allocator = std.testing.allocator;
    const source = "<div lang='tr'><span>iyi</span></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    var tree = try Builder.build(allocator, &document, &.{}, document.root);
    defer tree.deinit(allocator);

    for (tree.boxes.items) |candidate| {
        if (candidate.kind != .text) continue;
        try std.testing.expectEqualStrings("tr", candidate.language);
        return;
    }
    return error.TestExpectedEqual;
}

test "resolve and proportionally normalize elliptical border radii" {
    const radii = BorderRadii{
        .top_left = .{ .x = .{ .percent = 0.8 }, .y = .{ .px = 30 } },
        .top_right = .{ .x = .{ .percent = 0.8 }, .y = .{ .px = 20 } },
        .bottom_right = .{ .x = .{ .px = 20 }, .y = .{ .percent = 0.75 } },
        .bottom_left = .{ .x = .{ .px = 10 }, .y = .{ .percent = 0.75 } },
    };
    const resolved = radii.resolve(100, 40);

    try std.testing.expectApproxEqAbs(@as(f32, 50), resolved.top_left.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), resolved.top_right.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18.75), resolved.top_left.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), resolved.top_right.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18.75), resolved.bottom_right.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18.75), resolved.bottom_left.y, 0.001);
}
