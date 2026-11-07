const std = @import("std");
pub const c = @import("c.zig").c;
const model = @import("model.zig");
pub var arena: std.heap.ArenaAllocator = undefined;
pub fn z(value: []const u8) [:0]const u8 {
    return arena.allocator().dupeSentinel(u8, value, 0) catch unreachable;
}
pub fn fmt(comptime pattern: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(arena.allocator(), pattern, args, 0) catch unreachable;
}
pub const fill: c.cui_size = .{ .kind = c.CUI_SIZE_GROW, .value = 1 };
pub fn px(n: f32) c.cui_size {
    return .{ .kind = c.CUI_SIZE_FIXED, .value = n };
}
pub fn color(token: c_int) c.cui_color {
    return .{ .r = @intCast(token), .g = 0xc5, .b = 0x1d, .a = 0 };
}
pub fn row(ui: *c.cui_ctx, opts: c.cui_box) void {
    _ = c.cui_row_begin(ui, &opts);
}
pub fn column(ui: *c.cui_ctx, opts: c.cui_box) void {
    _ = c.cui_column_begin(ui, &opts);
}
pub fn end(ui: *c.cui_ctx) void {
    c.cui_box_end(ui);
}
pub fn button(ui: *c.cui_ctx, label: []const u8, opts: c.cui_button_opts) bool {
    return c.kest_button_ex(ui, z(label), &opts);
}
pub fn icon(ui: *c.cui_ctx, glyph: [*:0]const u8, hint: [*:0]const u8) bool {
    return c.cui_icon_button_ex(ui, glyph, &.{ .tooltip = hint, .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_GHOST, .color = color(c.CUI_TOKEN_TEXT_SECONDARY) });
}
pub fn text(ui: *c.cui_ctx, value: []const u8, opts: c.cui_text_opts) void {
    c.cui_text_ex(ui, z(value), &opts);
}
pub fn muted(ui: *c.cui_ctx, value: []const u8) void {
    text(ui, value, .{ .size = 12, .color = color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true });
}
pub fn field(ui: *c.cui_ctx, id: [*:0]const u8, buffer: *model.TextBuffer, opts_in: c.cui_input_opts) bool {
    if (!buffer.reserve(@max(4096, buffer.len + 4096))) return false;
    var opts = opts_in;
    if (buffer.want_focus) {
        opts.autofocus = true;
        c.kest_focus(ui, id);
    }
    buffer.want_focus = false;
    const flags = c.cui_input_ex(ui, id, buffer.data.ptr, buffer.data.len, &opts);
    if (flags & c.CUI_CHANGED != 0) {
        buffer.len = std.mem.indexOfScalar(u8, buffer.data, 0) orelse buffer.data.len - 1;
        return true;
    }
    return false;
}
pub fn flatField(ui: *c.cui_ctx, id: [*:0]const u8, buffer: *model.TextBuffer, opts_in: c.cui_input_opts, cell: bool) bool {
    if (!buffer.reserve(@max(4096, buffer.len + 4096))) return false;
    var opts = opts_in;
    opts.autofocus = buffer.want_focus;
    buffer.want_focus = false;
    const flags = c.kest_flat_input(ui, id, buffer.data.ptr, buffer.data.len, &opts, cell);
    if (flags & c.CUI_CHANGED == 0) return false;
    buffer.len = std.mem.indexOfScalar(u8, buffer.data, 0) orelse buffer.data.len - 1;
    return true;
}
pub fn action(ui: *c.cui_ctx, id: [*:0]const u8, label: []const u8, glyph: ?[*:0]const u8, selected: bool, width: f32, height: f32, kind: c_int) bool {
    const clicked = c.kest_control_begin(ui, id, selected, width, height, kind);
    if (glyph) |g| c.cui_icon(ui, g, 14, color(if (selected) c.CUI_TOKEN_FOREGROUND else c.CUI_TOKEN_TEXT_SECONDARY));
    if (label.len > 0) text(ui, label, .{ .size = 12, .font = if (selected) c.CUI_FONT_MEDIUM else c.CUI_FONT_BODY, .nowrap = true, .color = color(if (selected) c.CUI_TOKEN_FOREGROUND else c.CUI_TOKEN_TEXT_SECONDARY) });
    c.kest_item_end(ui);
    return clicked;
}
pub fn menu(ui: *c.cui_ctx, label: []const u8, width: f32, tint: c.cui_color) bool {
    return c.kest_menu_begin(ui, z(label), &.{ .variant = c.CUI_BUTTON_GHOST, .width = 180 }, width, tint);
}
pub fn select(ui: *c.cui_ctx, id: [*:0]const u8, items: []const []const u8, index: *c_int, width: c.cui_size) bool {
    const labels = arena.allocator().alloc([*:0]const u8, items.len) catch unreachable;
    for (items, labels) |label, *dest| dest.* = z(label);
    return c.kest_select_ex(ui, id, labels.ptr, @intCast(items.len), index, &.{ .width = width });
}
pub fn tabs(ui: *c.cui_ctx, id: [*:0]const u8, items: []const []const u8, index: *c_int) bool {
    const labels = arena.allocator().alloc([*:0]const u8, items.len) catch unreachable;
    for (items, labels) |label, *dest| dest.* = z(label);
    return c.cui_tabs_ex(ui, id, labels.ptr, @intCast(items.len), index, &.{});
}
pub fn menuItem(ui: *c.cui_ctx, label: []const u8) bool {
    return c.cui_menu_item_ex(ui, z(label), &.{});
}
pub fn empty(ui: *c.cui_ctx, title: [*:0]const u8, detail: [*:0]const u8) void {
    c.cui_spacer(ui);
    column(ui, .{ .width = fill, .pad_x = 20, .gap = 6, .@"align" = c.CUI_ALIGN_CENTER });
    text(ui, std.mem.span(title), .{ .width = fill, .font = c.CUI_FONT_MEDIUM, .size = 14, .@"align" = c.CUI_TEXT_CENTER });
    if (c.cui_viewport_size(ui).y >= 600) text(ui, std.mem.span(detail), .{ .width = fill, .size = 12, .color = color(c.CUI_TOKEN_TEXT_MUTED), .@"align" = c.CUI_TEXT_CENTER });
    end(ui);
    c.cui_spacer(ui);
}
pub fn methodColor(method: []const u8) c.cui_color {
    return color(if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) c.CUI_TOKEN_SUCCESS else if (std.mem.eql(u8, method, "POST")) c.CUI_TOKEN_WARNING else if (std.mem.eql(u8, method, "DELETE")) c.CUI_TOKEN_DANGER else if (std.mem.eql(u8, method, "PUT")) c.CUI_TOKEN_INFO else c.CUI_TOKEN_TEXT_SECONDARY);
}
pub fn bytes(value: u64) [:0]const u8 {
    if (value < 1024) return fmt("{d} B", .{value});
    if (value < 1024 * 1024) return fmt("{d:.1} KB", .{@as(f64, @floatFromInt(value)) / 1024});
    return fmt("{d:.1} MB", .{@as(f64, @floatFromInt(value)) / (1024 * 1024)});
}
pub fn copy(ui: *c.cui_ctx, value: []const u8) void {
    if (!@import("platform.zig").headless) c.kest_copy(ui, z(value));
}
