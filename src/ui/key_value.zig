//! Compact developer tables; request data and editor sessions have separate ids.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const tab = @import("../app/tab.zig");
const validation = @import("table_validation.zig");
const upload = @import("upload.zig");
const suggest = @import("suggest.zig");
const completion = @import("../core/completion.zig");
pub const Kind = validation.Kind;
pub const Options = struct {
    kind: Kind = .variables,
    vars: []const @import("../core/variables.zig").Var = &.{},
    request: ?*const tab.Tab = null,
    /// The selected environment's name, for hovers over unset variables.
    env_name: ?[]const u8 = null,
    app: ?*@import("../app/state.zig").App = null,
    /// Side inset; off where the container (a dialog) already provides it.
    inset: bool = true,
};

fn weighted(weight: f32) c.cui_size {
    return .{ .kind = c.CUI_SIZE_GROW, .value = weight };
}

/// The grip at a row's start: click to pick the row, drag to move it.
const grip_width = 14;

fn inside(r: c.cui_rect, m: c.cui_vec2) bool {
    return r.w > 0 and m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h;
}

/// Puts back what the last bulk change replaced, from its toast's Undo.
fn undoToast(ui: *c.cui_ctx, values: *tab.Table, title: [*:0]const u8) void {
    if (values.undo_toast != 0) c.cui_toast_dismiss(ui, values.undo_toast);
    values.undo_toast = c.cui_toast_ex(ui, title, &.{ .action = "Undo", .duration = 8, .show_timer = true });
}

/// Dragging the boundary between two headings (`key_id`, `value_id`, in
/// the current id scope) sets the first one's share; a double-click resets
/// it. Returns whether the pointer is on the boundary.
pub fn columnSplit(ui: *c.cui_ctx, area_id: [*:0]const u8, key_id: [*:0]const u8, value_id: [*:0]const u8, share: *f32, resizing: *bool, enabled: bool) bool {
    const mouse = c.cui_mouse_pos(ui);
    const key = c.cui_get_rect(ui, c.cui_make_id(ui, key_id));
    const value = c.cui_get_rect(ui, c.cui_make_id(ui, value_id));
    const boundary = key.x + key.w;
    const on = enabled and key.w > 0 and @abs(mouse.x - boundary) <= 4 and mouse.y >= key.y and mouse.y < key.y + key.h;
    if (on or resizing.*) c.kest_set_cursor(ui, c.CUI_CURSOR_RESIZE_EW);
    if (on) c.kest_tooltip_for(ui, c.cui_make_id(ui, key_id), "Drag to resize columns, double-click to reset");
    if (on and c.kest_left_pressed(ui)) {
        if (c.kest_click_count(ui) >= 2) share.* = tab.Table.default_share else resizing.* = true;
        c.kest_consume_click(ui);
    }
    if (resizing.*) {
        if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT)) resizing.* = false else if (key.w + value.w > 0) {
            share.* = std.math.clamp((mouse.x - key.x) / (key.w + value.w), 0.15, 0.85);
            c.cui_request_redraw(ui);
        }
    }
    // The boundary lights up over the heading and the rows below it.
    if ((on or resizing.*) and key.w > 0) {
        const area = c.cui_get_rect(ui, c.cui_make_id(ui, area_id));
        const bottom = if (area.h > 0) area.y + area.h else key.y + key.h;
        const x = if (resizing.*) key.x + share.* * (key.w + value.w) else boundary;
        c.kest_resize_guide(ui, x, key.y, bottom - key.y, resizing.*);
    }
    return on;
}

/// Keys for picked rows and pasted rows, before the cells see them.
/// Returns whether rows changed.
fn tableKeys(ui: *c.cui_ctx, values: *tab.Table, focused_row: ?usize, in_cell: bool) bool {
    const mods = c.cui_key_mods(ui);
    if (values.selected.items.len > 0 and !in_cell and values.drag == null) {
        if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
            c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
            values.clearSelection();
            return false;
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_C)) {
            c.kest_consume_key(ui, c.CUI_KEY_C);
            if (values.selectedTsv(w.arena.allocator())) |text| w.copy(ui, text) else |_| {}
            return false;
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_X)) {
            c.kest_consume_key(ui, c.CUI_KEY_X);
            if (values.selectedTsv(w.arena.allocator())) |text| w.copy(ui, text) else |_| {}
            return deleteSelected(ui, values);
        }
        if (mods == 0 and (c.cui_key_pressed(ui, c.CUI_KEY_DELETE) or c.cui_key_pressed(ui, c.CUI_KEY_BACKSPACE))) {
            c.kest_consume_key(ui, c.CUI_KEY_DELETE);
            c.kest_consume_key(ui, c.CUI_KEY_BACKSPACE);
            return deleteSelected(ui, values);
        }
    }
    // Several lines, or a tab: rows, not text for one cell.
    if ((in_cell or values.selected.items.len > 0) and c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_V)) {
        const clip = c.kest_clipboard(ui);
        if (clip == null) return false;
        const text = std.mem.trimEnd(u8, std.mem.span(clip), "\r\n");
        if (std.mem.indexOfAny(u8, text, "\t\n") == null) return false;
        c.kest_consume_key(ui, c.CUI_KEY_V);
        const at = if (focused_row) |i| i + 1 else if (lastSelected(values)) |i| i + 1 else values.rows.items.len;
        values.remember();
        const count = values.pasteTsv(text, at) catch 0;
        if (count == 0) return false;
        undoToast(ui, values, w.z(w.fmt("Pasted {d} {s}", .{ count, if (count == 1) "row" else "rows" })));
        c.kest_set_focus(ui, 0);
        return true;
    }
    return false;
}

fn lastSelected(values: *const tab.Table) ?usize {
    var last: ?usize = null;
    for (values.rows.items, 0..) |r, i| if (values.isSelected(r.uid)) {
        last = i;
    };
    return last;
}

fn deleteSelected(ui: *c.cui_ctx, values: *tab.Table) bool {
    values.remember();
    const count = values.removeSelected();
    if (count == 0) return false;
    undoToast(ui, values, w.z(w.fmt("Deleted {d} {s}", .{ count, if (count == 1) "row" else "rows" })));
    return true;
}

/// "3 selected", with what can be done to them.
fn selectionBar(ui: *c.cui_ctx, values: *tab.Table) bool {
    var changed = false;
    const n = values.selected.items.len;
    w.row(ui, .{ .id = "kv-selection", .width = w.fill, .height = w.px(c.KEST_TABLE_HEADER), .gap = 4, .@"align" = c.CUI_ALIGN_CENTER, .pad_left = 10, .pad_right = 2, .bg = w.tinted(ui, c.CUI_TOKEN_ACCENT, 0.12) });
    w.text(ui, w.fmt("{d} selected", .{n}), .{ .size = c.KEST_TEXT_SECONDARY, .font = c.CUI_FONT_MEDIUM, .width = w.fill, .nowrap = true });
    if (w.action(ui, "selection-enable", "Enable", null, false, 0, 24, 3)) changed = values.setEnabledSelected(true) > 0 or changed;
    if (w.action(ui, "selection-disable", "Disable", null, false, 0, 24, 3)) changed = values.setEnabledSelected(false) > 0 or changed;
    if (w.action(ui, "selection-copy", "Copy", null, false, 0, 24, 3)) {
        if (values.selectedTsv(w.arena.allocator())) |text| w.copy(ui, text) else |_| {}
    }
    if (w.action(ui, "selection-delete", "Delete", null, false, 0, 24, 3)) changed = deleteSelected(ui, values) or changed;
    if (w.action(ui, "selection-clear", "", c.CUI_ICON_X, false, 24, 24, 3)) values.clearSelection();
    c.kest_tooltip(ui, "Clear selection (Esc)");
    w.end(ui);
    return changed;
}

/// A sortable heading. Returns true when it was clicked.
fn sortHeading(ui: *c.cui_ctx, id: [*:0]const u8, label: []const u8, weight: f32, up: bool, down: bool, tip: [*:0]const u8) bool {
    const r = c.cui_get_rect(ui, c.cui_make_id(ui, id));
    const m = c.cui_mouse_pos(ui);
    const hovered = inside(r, m);
    w.row(ui, .{ .id = id, .width = weighted(weight), .height = w.fill, .pad_left = 10, .gap = 4, .@"align" = c.CUI_ALIGN_CENTER, .bg = if (hovered) w.color(c.CUI_TOKEN_HOVER) else .{} });
    w.text(ui, label, .{ .size = c.KEST_TEXT_CAPTION, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
    if (up or down) c.cui_icon(ui, if (up) c.CUI_ICON_ARROW_UP else c.CUI_ICON_ARROW_DOWN, 11, w.color(c.CUI_TOKEN_TEXT_SECONDARY));
    w.end(ui);
    if (hovered) {
        c.kest_set_cursor(ui, c.CUI_CURSOR_HAND);
        c.kest_tooltip_for(ui, c.cui_make_id(ui, id), tip);
    }
    return hovered and c.kest_left_pressed(ui);
}

fn field(ui: *c.cui_ctx, key: [*:0]const u8, buffer: *@import("model.zig").TextBuffer, placeholder: [*:0]const u8, weight: f32, hints: suggest.Context) bool {
    if (!buffer.reserve(@min(32 * 1024 * 1024, @max(4096, buffer.len + 4096)))) return false;
    const flags = c.kest_table_input(ui, key, buffer.data.ptr, buffer.data.len, &.{ .width = weighted(weight), .placeholder = placeholder, .autofocus = buffer.want_focus });
    buffer.want_focus = false;
    if (suggest.field(ui, key, buffer, flags, hints)) return true;
    if (flags & c.CUI_CHANGED == 0) return false;
    buffer.len = std.mem.indexOfScalar(u8, buffer.data, 0) orelse buffer.data.len - 1;
    return true;
}

pub fn view(ui: *c.cui_ctx, values: *tab.Table, files: bool, title: []const u8, opts: Options) bool {
    c.cui_push_id(ui, opts.kind.scope());
    defer c.cui_pop_id(ui);
    var changed = false;
    w.column(ui, .{ .id = "kv-editor", .width = w.fill, .height = w.fill, .pad_x = if (opts.inset) w.design.space.group else 0, .pad_top = w.design.space.tight, .pad_bottom = w.design.space.normal });
    defer w.end(ui);
    if (values.bulk != null) return bulk(ui, values, title);
    values.pruneSelection();
    if (values.undo_toast != 0 and c.cui_toast_action_clicked(ui, values.undo_toast)) {
        c.cui_toast_dismiss(ui, values.undo_toast);
        values.undo_toast = 0;
        if (values.restore()) |_| changed = true else |_| {}
    }
    // Which row holds the focused cell, if any.
    const focus = c.kest_get_focus(ui);
    var focused_row: ?usize = null;
    var in_cell = false;
    for (values.rows.items, 0..) |row, i| {
        c.cui_push_id_int(ui, @intCast(row.uid));
        if (focus == c.cui_make_id(ui, "key") or focus == c.cui_make_id(ui, "value")) focused_row = i;
        c.cui_pop_id(ui);
    }
    in_cell = focused_row != null;
    if (values.entry) |row| {
        c.cui_push_id_int(ui, @intCast(row.uid));
        if (focus == c.cui_make_id(ui, "key") or focus == c.cui_make_id(ui, "value")) in_cell = true;
        c.cui_pop_id(ui);
    }
    if (tableKeys(ui, values, focused_row, in_cell)) changed = true;
    const entry = values.insertion() catch null;
    const count = values.rows.items.len + @intFromBool(entry != null);
    const ids = w.arena.allocator().alloc(c_uint, count) catch return false;
    for (values.rows.items, 0..) |row, i| ids[i] = row.uid;
    if (entry) |row| ids[count - 1] = row.uid;
    _ = c.kest_table_navigation(ui, ids.ptr, @intCast(ids.len));
    const mouse = c.cui_mouse_pos(ui);
    const pressed = c.kest_left_pressed(ui);
    const held = c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT);
    const on_boundary = columnSplit(ui, "kv-grid", "kv-key-heading", "kv-value-heading", &values.key_share, &values.resizing, values.selected.items.len == 0);
    const key_weight = values.key_share * 10;
    const value_weight = (1 - values.key_share) * 10;
    // A grip let go: drop the rows being dragged, or settle the pick.
    if (values.drag) |drag| {
        if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
            c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
            values.drag = null;
        } else if (!held) {
            if (drag.moving) {
                if (values.moveRows(drag.uid, drag.target)) changed = true;
            } else if (c.cui_key_mods(ui) == 0 and values.selected.items.len > 1) values.selectOnly(drag.uid);
            values.drag = null;
        } else if (!drag.moving and @abs(mouse.y - drag.start_y) > 4) {
            values.drag.?.moving = true;
        }
        if (values.drag != null and values.drag.?.moving) c.kest_set_cursor(ui, c.CUI_CURSOR_MOVE);
    }
    const pixel = 1 / @max(1, c.cui_dpi_scale(ui));
    w.column(ui, .{ .id = "kv-grid", .height = w.fill, .max_height = c.KEST_TABLE_HEADER + pixel + @as(f32, @floatFromInt(count)) * c.KEST_TABLE_STRIDE, .width = w.fill, .clip = true });
    var add = false;
    var auto_headers = false;
    // Picked rows: their actions take the heading's place, so nothing moves.
    if (values.selected.items.len > 0) {
        changed = selectionBar(ui, values) or changed;
    } else {
        w.row(ui, .{ .id = "kv-heading", .height = w.px(c.KEST_TABLE_HEADER), .width = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED), .@"align" = c.CUI_ALIGN_CENTER });
        slot(ui, grip_width);
        w.end(ui);
        slot(ui, c.KEST_TABLE_ENABLED);
        c.cui_icon(ui, c.CUI_ICON_CHECK, 12, w.color(c.CUI_TOKEN_TEXT_SECONDARY));
        w.end(ui);
        // A heading cycles: A to Z, Z to A, then back to the original order.
        // The arrow shows the order, so no toast is needed.
        var sort: ?tab.Table.Sort = null;
        if (sortHeading(ui, "kv-key-heading", switch (opts.kind) {
            .params => "Parameter",
            .headers => "Header",
            .form => "Field",
            .variables => "Variable",
        }, key_weight, values.sort == .key_up, values.sort == .key_down, "Sort by name") and !on_boundary) sort = switch (values.sort) {
            .key_up => .key_down,
            .key_down => .none,
            else => .key_up,
        };
        if (sortHeading(ui, "kv-value-heading", "Value", value_weight, values.sort == .value_up, values.sort == .value_down, "Sort by value") and !on_boundary) sort = switch (values.sort) {
            .value_up => .value_down,
            .value_down => .none,
            else => .value_up,
        };
        if (sort) |order| if (values.rows.items.len > 1 or order == .none) {
            if (order == .none) values.unsort() else values.sortBy(order);
            changed = true;
        };
        if (files) {
            slot(ui, c.KEST_TABLE_PICKER);
            w.end(ui);
            w.text(ui, "Type", .{ .width = w.px(c.KEST_TABLE_TYPE), .size = c.KEST_TEXT_CAPTION, .@"align" = c.CUI_TEXT_CENTER, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        }
        if (c.kest_table_menu_begin(ui, "table-actions", false, if (values.bulk_problem.message.len > 0) w.z(values.bulk_problem.message) else null, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
            if (c.cui_menu_item_ex(ui, "Add row", &.{ .disabled = entry == null })) add = true;
            if (w.menuItem(ui, "Bulk edit")) openBulk(values);
            if (opts.kind == .headers and opts.request != null and w.menuItem(ui, "Automatic request headers")) auto_headers = true;
            c.cui_menu_end(ui);
        }
        w.end(ui);
    }
    w.separator(ui, "kv-heading-boundary");
    if (add and entry != null) c.kest_table_focus(ui, entry.?.uid, 0, @intCast(values.rows.items.len));
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "kv-rows", @intCast(count), c.KEST_TABLE_STRIDE, w.fill, &first, &last);
    // Where dragged rows would land: before the first shown row whose
    // middle is below the pointer.
    if (values.drag != null and values.drag.?.moving) {
        var target = values.rows.items.len;
        for (@as(usize, @intCast(first))..@min(@as(usize, @intCast(last)), values.rows.items.len)) |i| {
            c.cui_push_id_int(ui, @intCast(values.rows.items[i].uid));
            const r = c.cui_get_rect(ui, c.cui_make_id(ui, "kv-row"));
            c.cui_pop_id(ui);
            if (r.h > 0 and mouse.y < r.y + r.h / 2) {
                target = i;
                break;
            }
        }
        values.drag.?.target = target;
    }
    var remove: ?usize = null;
    var duplicate: ?usize = null;
    var move: ?struct { from: usize, to: usize } = null;
    var inspect_row = false;
    var commit = false;
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const insertion = i == values.rows.items.len;
        const row = if (insertion) entry.? else values.rows.items[i];
        c.cui_push_id_int(ui, @intCast(row.uid));
        var row_flags: c_int = 0;
        if (!insertion and values.isSelected(row.uid)) row_flags |= c.KEST_ROW_SELECTED;
        if (values.drag) |drag| if (drag.moving) {
            if (!insertion and drag.target == i) row_flags |= c.KEST_ROW_DROP_ABOVE;
            if (!insertion and drag.target == values.rows.items.len and i + 1 == values.rows.items.len) row_flags |= c.KEST_ROW_DROP_BELOW;
        };
        const row_hovered = c.kest_row_hovered(ui);
        c.kest_table_row_begin(ui, row_flags);
        // The grip: shown on hover or when picked.
        const grip = c.cui_get_rect(ui, c.cui_make_id(ui, "grip"));
        w.column(ui, .{ .id = "grip", .width = w.px(grip_width), .height = w.fill, .@"align" = c.CUI_ALIGN_CENTER, .justify = c.CUI_JUSTIFY_CENTER });
        if (!insertion and (row_hovered or values.isSelected(row.uid))) c.cui_icon(ui, c.CUI_ICON_GRIP_VERTICAL, 12, w.color(c.CUI_TOKEN_TEXT_MUTED));
        w.end(ui);
        if (!insertion and inside(grip, mouse)) {
            c.kest_set_cursor(ui, c.CUI_CURSOR_MOVE);
            c.kest_tooltip_for(ui, c.cui_make_id(ui, "grip"), "Click to select (Ctrl or Shift for more), drag to move");
            if (pressed and values.drag == null) {
                const mods = c.cui_key_mods(ui);
                if (mods & c.CUI_MOD_SHIFT != 0) values.selectTo(row.uid) else if (mods & c.CUI_MOD_PRIMARY != 0) values.toggleSelected(row.uid) else if (!values.isSelected(row.uid)) values.selectOnly(row.uid);
                values.drag = .{ .uid = row.uid, .start_y = mouse.y };
                c.kest_consume_click(ui);
                c.kest_set_focus(ui, 0);
            }
        }
        slot(ui, c.KEST_TABLE_ENABLED);
        if (!insertion) {
            changed = c.cui_checkbox_ex(ui, "###enabled", &row.enabled, &.{}) or changed;
            c.kest_tooltip(ui, "Include this row");
        }
        w.end(ui);
        const key_changed = field(ui, "key", &row.key, if (!insertion) "" else switch (opts.kind) {
            .params => "Add parameter",
            .headers => "Add header",
            .form => "Add field",
            .variables => "Add variable",
        }, key_weight, .{ .vars = opts.vars, .env_name = opts.env_name, .fallback = if (opts.kind == .headers) .{ .choices = &completion.header_names } else .none });
        const value_changed = field(ui, "value", &row.value, if (files and row.is_file) "File path" else "", value_weight, .{ .vars = opts.vars, .env_name = opts.env_name, .fallback = if (opts.kind == .headers) .{ .choices = completion.headerValues(row.key.text()) } else .none });
        if (value_changed) row.has_equals = true;
        if (insertion) commit = key_changed or value_changed else changed = changed or key_changed or value_changed;
        if (files) {
            slot(ui, c.KEST_TABLE_PICKER);
            if (row.is_file and opts.app != null) {
                if (w.action(ui, "choose-field-file", "", c.CUI_ICON_FOLDER_OPEN, false, 28, 28, 3) and upload.choose(opts.app.?, &row.value)) {
                    row.has_equals = true;
                    if (insertion) commit = true else changed = true;
                }
                c.kest_tooltip(ui, "Choose file");
            }
            w.end(ui);
            slot(ui, c.KEST_TABLE_TYPE);
            if (w.action(ui, "field-type", if (row.is_file) "File" else "Text", null, row.is_file, c.KEST_TABLE_TYPE, 28, 3)) {
                row.is_file = !row.is_file;
                if (!insertion) changed = true;
                c.cui_request_redraw(ui);
            }
            w.end(ui);
        }
        if (insertion) {
            slot(ui, c.KEST_TABLE_ACTIONS);
            w.end(ui);
        } else {
            const problem = rowProblem(row, files, opts);
            if (c.kest_table_menu_begin(ui, "row-actions", true, if (problem.message) |message| w.z(message) else null, w.color(if (problem.danger) c.CUI_TOKEN_DANGER else if (problem.message != null) c.CUI_TOKEN_WARNING else c.CUI_TOKEN_TEXT_SECONDARY))) {
                if (problem.message) |message| w.text(ui, message, .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(if (problem.danger) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_WARNING) });
                if (w.menuItem(ui, "Inspect row")) {
                    values.inspected_uid = row.uid;
                    inspect_row = true;
                }
                if (files and row.is_file and opts.app != null and w.menuItem(ui, "Choose file...")) {
                    if (upload.choose(opts.app.?, &row.value)) {
                        row.has_equals = true;
                        changed = true;
                    }
                }
                if (files and w.menuItem(ui, if (row.is_file) "Use text field" else "Use file field")) {
                    row.is_file = !row.is_file;
                    changed = true;
                }
                if (w.menuItem(ui, if (row.enabled) "Disable row" else "Enable row")) {
                    row.enabled = !row.enabled;
                    changed = true;
                }
                if (c.cui_menu_item_ex(ui, "Duplicate row", &.{ .disabled = entry == null })) duplicate = i;
                if (c.cui_menu_item_ex(ui, "Move up", &.{ .disabled = i == 0 })) move = .{ .from = i, .to = i -| 1 };
                if (c.cui_menu_item_ex(ui, "Move down", &.{ .disabled = i + 1 >= values.rows.items.len })) move = .{ .from = i, .to = i + 1 };
                if (w.menuItem(ui, "Delete row")) remove = i;
                if (values.selected.items.len > 1 and values.isSelected(row.uid)) {
                    c.cui_menu_separator(ui);
                    if (w.menuItem(ui, w.fmt("Copy {d} selected rows", .{values.selected.items.len}))) {
                        if (values.selectedTsv(w.arena.allocator())) |text| w.copy(ui, text) else |_| {}
                    }
                    if (w.menuItem(ui, w.fmt("Delete {d} selected rows", .{values.selected.items.len}))) changed = deleteSelected(ui, values) or changed;
                }
                c.cui_menu_end(ui);
            }
        }
        w.end(ui);
        c.cui_pop_id(ui);
    }
    c.cui_virtual_list_end(ui);
    w.end(ui);
    if (commit) {
        if (values.commitInsertion()) |_| {
            changed = true;
            values.bulk_problem = .{};
        } else |_| values.bulk_problem = .{ .message = "Couldn't add the row; text was kept" };
    }
    if (remove) |i| {
        values.removeAt(i);
        values.bulk_problem = .{};
        const next = if (i < values.rows.items.len) values.rows.items[i] else values.insertion() catch null;
        if (next) |row| c.kest_table_focus(ui, row.uid, 0, @intCast(@min(i, values.rows.items.len)));
        changed = true;
    } else if (duplicate) |i| {
        if (values.duplicateAt(i)) |_| {
            values.bulk_problem = .{};
            c.kest_table_focus(ui, values.rows.items[i + 1].uid, 0, @intCast(i + 1));
            changed = true;
        } else |_| values.bulk_problem = .{ .message = "Couldn't duplicate the row" };
    } else if (move) |target| {
        values.bulk_problem = .{};
        const row = values.rows.orderedRemove(target.from);
        values.rows.insertAssumeCapacity(target.to, row);
        c.kest_table_focus(ui, row.uid, 0, @intCast(target.to));
        changed = true;
    }
    if (inspect_row) c.cui_popover_open(ui, "row-inspector");
    inspect(ui, values, files, opts);
    if (auto_headers) c.cui_popover_open(ui, "automatic-headers");
    if (opts.request) |request| if (c.kest_table_details_begin(ui, "automatic-headers")) {
        @import("table_headers.zig").view(ui, request, opts.vars);
        c.cui_menu_end(ui);
    };
    return changed;
}

fn rowProblem(row: *const tab.Row, files: bool, opts: Options) validation.Problem {
    const problem = validation.check(w.arena.allocator(), opts.kind, row.key.text(), row.value.text(), opts.vars);
    if (problem.message != null) return problem;
    if (files and row.is_file) if (upload.resolve(w.arena.allocator(), row.value.text(), opts.vars).problem) |message| return .{ .message = message };
    return problem;
}

fn inspect(ui: *c.cui_ctx, values: *tab.Table, files: bool, opts: Options) void {
    const uid = values.inspected_uid orelse return;
    const row = for (values.rows.items) |candidate| {
        if (candidate.uid == uid) break candidate;
    } else {
        c.cui_popover_close(ui, "row-inspector");
        return;
    };
    if (!c.kest_table_details_begin(ui, "row-inspector")) return;
    w.text(ui, if (opts.kind == .headers) "Configured request header" else "Row details", .{ .font = c.CUI_FONT_MEDIUM, .size = c.KEST_TEXT_BODY });
    if (!row.enabled) w.muted(ui, "Disabled");
    if (opts.kind == .form) w.muted(ui, if (files and row.is_file) "File field" else "Text field");
    c.kest_document_list_begin(ui, "row-inspector-content", @min(220, c.cui_viewport_size(ui).y - 240));
    w.text(ui, row.key.text(), .{ .font = c.CUI_FONT_MONO, .size = c.KEST_TEXT_SECONDARY, .width = w.fill });
    w.text(ui, row.value.text(), .{ .font = c.CUI_FONT_MONO, .size = c.KEST_TEXT_SECONDARY, .width = w.fill });
    if (files and row.is_file and opts.app != null) upload.details(ui, opts.app.?, row.value.text(), opts.vars);
    c.cui_scroll_end(ui);
    const problem = rowProblem(row, files, opts);
    if (problem.message) |message| w.text(ui, message, .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(if (problem.danger) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_WARNING) });
    if (w.menuItem(ui, "Copy name")) w.copy(ui, row.key.text());
    if (w.menuItem(ui, "Copy value")) w.copy(ui, row.value.text());
}

fn bulk(ui: *c.cui_ctx, values: *tab.Table, title: []const u8) bool {
    var changed = false;
    w.row(ui, .{ .height = w.px(c.KEST_TABLE_HEADER), .width = w.fill });
    w.text(ui, if (values.bulk_problem.message.len > 0) w.fmt("{s}{s}", .{ values.bulk_problem.message, if (values.bulk_problem.line > 0) w.fmt(" (line {d})", .{values.bulk_problem.line}) else "" }) else title, .{ .size = c.KEST_TEXT_CAPTION, .color = w.color(if (values.bulk_problem.message.len > 0) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_TEXT_MUTED), .width = w.fill, .nowrap = true });
    if (w.action(ui, "apply-bulk", "Apply", null, false, 0, 26, 3)) {
        if (values.fromBulk(values.bulk.?.text())) |_| {
            values.bulk.?.deinit();
            values.bulk = null;
            changed = true;
        } else |_| c.cui_request_redraw(ui);
    }
    if (w.action(ui, "cancel-bulk", "Cancel", null, false, 0, 26, 3)) {
        if (values.bulk) |*buffer| buffer.deinit();
        values.bulk = null;
        values.bulk_problem = .{};
    }
    w.end(ui);
    if (values.bulk) |*buffer| {
        if (buffer.reserve(@min(32 * 1024 * 1024, @max(4096, buffer.len + 4096)))) {
            c.cui_push_id_int(ui, @bitCast(values.bulk_session));
            _ = c.kest_table_bulk_input(ui, buffer.data.ptr, buffer.data.len, buffer.want_focus);
            c.cui_pop_id(ui);
            buffer.want_focus = false;
            buffer.len = std.mem.indexOfScalar(u8, buffer.data, 0) orelse 0;
        }
    }
    return changed;
}

pub fn openBulk(values: *tab.Table) void {
    if (values.bulk != null) return;
    values.bulk_problem = .{};
    const text = values.toBulk(w.arena.allocator()) catch {
        values.bulk_problem = .{ .message = "Couldn't build bulk text; rows were kept" };
        return;
    };
    var buffer: @import("model.zig").TextBuffer = .{};
    if (!buffer.reserve(text.len)) {
        values.bulk_problem = .{ .message = "Bulk text is too large or memory is unavailable" };
        return;
    }
    buffer.set(text);
    values.bulk = buffer;
    values.bulk_session +%= 1;
    values.bulk.?.focus();
}

fn slot(ui: *c.cui_ctx, width: f32) void {
    w.column(ui, .{ .width = w.px(width), .height = w.fill, .@"align" = c.CUI_ALIGN_CENTER, .justify = c.CUI_JUSTIFY_CENTER });
}
