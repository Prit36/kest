//! Spreadsheet-like cells: typing into the final row inserts real request data.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const tab = @import("../app/tab.zig");

pub fn view(ui: *c.cui_ctx, values: *tab.Table, files: bool, title: []const u8) bool {
    var changed = false;
    const compact = c.cui_viewport_size(ui).y < 600;
    w.column(ui, .{ .width = w.fill, .height = w.fill, .pad_x = 12, .pad_top = if (compact) 4 else 10, .pad_bottom = 8, .gap = 0 });
    defer w.end(ui);
    if (!compact or values.bulk != null) {
        w.row(ui, .{ .height = w.px(28), .width = w.fill });
        w.text(ui, title, .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .width = w.fill });
        if (values.bulk != null) {
            if (w.action(ui, "apply-bulk", "Apply", null, false, 0, 26, 3)) {
                values.fromBulk(values.bulk.?.text()) catch {};
                values.bulk.?.deinit();
                values.bulk = null;
                changed = true;
            }
            if (w.action(ui, "cancel-bulk", "Cancel", null, false, 0, 26, 3)) {
                values.bulk.?.deinit();
                values.bulk = null;
            }
        } else if (w.action(ui, "open-bulk", "Bulk edit", null, false, 0, 26, 3)) openBulk(values);
        w.end(ui);
    }
    if (values.bulk) |*bulk| {
        if (bulk.reserve(@max(4096, bulk.len + 4096))) {
            _ = c.cui_textarea_ex(ui, "bulk", bulk.data.ptr, bulk.data.len, &.{ .height = -1, .placeholder = "Name: value\n# Disabled-name: value", .autofocus = bulk.want_focus });
            bulk.want_focus = false;
            bulk.len = std.mem.indexOfScalar(u8, bulk.data, 0) orelse 0;
        }
        return changed;
    }
    const entry = values.insertion() catch null;
    const count = values.rows.items.len + @intFromBool(entry != null);
    w.column(ui, .{ .id = "kv-grid", .height = w.fill, .max_height = 29 + @as(f32, @floatFromInt(count)) * 33, .width = w.fill, .border = 1, .border_color = w.color(c.CUI_TOKEN_BORDER), .radius = 4, .clip = true });
    w.row(ui, .{ .height = w.px(28), .width = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED) });
    slot(ui, 30);
    c.cui_separator(ui);
    heading(ui, "Name");
    c.cui_separator(ui);
    heading(ui, "Value");
    if (files) {
        c.cui_separator(ui);
        w.text(ui, "File", .{ .width = w.px(44), .size = 11, .@"align" = c.CUI_TEXT_CENTER, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    }
    c.cui_separator(ui);
    if (compact) {
        if (w.action(ui, "compact-bulk", "", c.CUI_ICON_CODE, false, 30, 28, 3)) openBulk(values);
        c.cui_tooltip(ui, "Bulk edit");
    } else slot(ui, 30);
    w.end(ui);
    c.cui_separator(ui);
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "kv-rows", @intCast(count), 33, w.fill, &first, &last);
    var remove: ?usize = null;
    var duplicate: ?usize = null;
    var commit = false;
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const insertion = i == values.rows.items.len;
        const r = if (insertion) entry.? else values.rows.items[i];
        c.cui_push_id_int(ui, @intCast(r.uid));
        w.row(ui, .{ .height = w.px(32), .width = w.fill });
        w.column(ui, .{ .width = w.px(30), .height = w.fill, .@"align" = c.CUI_ALIGN_CENTER, .justify = c.CUI_JUSTIFY_CENTER });
        if (insertion) c.cui_icon(ui, c.CUI_ICON_PLUS, 12, w.color(c.CUI_TOKEN_TEXT_MUTED)) else changed = c.cui_checkbox_ex(ui, "##enabled", &r.enabled, &.{}) or changed;
        w.end(ui);
        c.cui_separator(ui);
        const key_changed = w.flatField(ui, "key", &r.key, .{ .placeholder = "Name", .width = w.fill }, true);
        c.cui_separator(ui);
        const value_changed = w.flatField(ui, "value", &r.value, .{ .placeholder = if (r.is_file) "File path" else "Value", .width = w.fill }, true);
        if (insertion) commit = key_changed or value_changed else changed = changed or key_changed or value_changed;
        if (files) {
            c.cui_separator(ui);
            w.column(ui, .{ .width = w.px(44), .height = w.fill, .@"align" = c.CUI_ALIGN_CENTER, .justify = c.CUI_JUSTIFY_CENTER });
            changed = c.cui_checkbox_ex(ui, "##file", &r.is_file, &.{}) or changed;
            c.cui_tooltip(ui, "Upload value as a file");
            w.end(ui);
        }
        c.cui_separator(ui);
        if (insertion) slot(ui, 30) else {
            if (w.action(ui, "remove-row", "", c.CUI_ICON_TRASH_2, false, 30, 30, 3)) remove = i;
            c.cui_tooltip(ui, "Delete row");
            if (c.cui_context_menu_begin(ui, "row-actions")) {
                if (w.menuItem(ui, "Duplicate row")) duplicate = i;
                if (w.menuItem(ui, "Delete row")) remove = i;
                c.cui_context_menu_end(ui);
            }
        }
        w.end(ui);
        c.cui_separator(ui);
        c.cui_pop_id(ui);
    }
    c.cui_virtual_list_end(ui);
    w.end(ui);
    if (commit) {
        values.commitInsertion() catch {};
        changed = true;
    }
    if (remove) |i| {
        values.removeAt(i);
        changed = true;
    } else if (duplicate) |i| {
        values.duplicateAt(i) catch {};
        changed = true;
    }
    return changed;
}

pub fn openBulk(values: *tab.Table) void {
    if (values.bulk != null) return;
    values.bulk = .{};
    values.bulk.?.set(values.toBulk(w.arena.allocator(), ": ") catch "");
    values.bulk.?.focus();
}
fn slot(ui: *c.cui_ctx, width: f32) void {
    w.column(ui, .{ .width = w.px(width) });
    w.end(ui);
}
fn heading(ui: *c.cui_ctx, label: []const u8) void {
    w.column(ui, .{ .width = w.fill, .pad_left = 10 });
    w.text(ui, label, .{ .size = 11, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
}
