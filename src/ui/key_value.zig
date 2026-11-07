//! Compact developer tables; request data and editor sessions have separate ids.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const tab = @import("../app/tab.zig");
const validation = @import("table_validation.zig");
const upload = @import("upload.zig");
pub const Kind = validation.Kind;
pub const Options = struct {
    kind: Kind = .variables,
    vars: []const @import("../core/variables.zig").Var = &.{},
    request: ?*const tab.Tab = null,
    app: ?*@import("../app/state.zig").App = null,
};

fn weighted(weight: f32) c.cui_size {
    return .{ .kind = c.CUI_SIZE_GROW, .value = weight };
}

fn field(ui: *c.cui_ctx, key: [*:0]const u8, buffer: *@import("model.zig").TextBuffer, placeholder: [*:0]const u8, weight: f32) bool {
    if (!buffer.reserve(@min(32 * 1024 * 1024, @max(4096, buffer.len + 4096)))) return false;
    const flags = c.kest_table_input(ui, key, buffer.data.ptr, buffer.data.len, &.{ .width = weighted(weight), .placeholder = placeholder, .autofocus = buffer.want_focus });
    buffer.want_focus = false;
    if (flags & c.CUI_CHANGED == 0) return false;
    buffer.len = std.mem.indexOfScalar(u8, buffer.data, 0) orelse buffer.data.len - 1;
    return true;
}

pub fn view(ui: *c.cui_ctx, values: *tab.Table, files: bool, title: []const u8, opts: Options) bool {
    c.cui_push_id(ui, opts.kind.scope());
    defer c.cui_pop_id(ui);
    var changed = false;
    w.column(ui, .{ .id = "kv-editor", .width = w.fill, .height = w.fill, .pad_x = w.design.space.group, .pad_top = w.design.space.tight, .pad_bottom = w.design.space.normal });
    defer w.end(ui);
    if (values.bulk != null) return bulk(ui, values, title);
    const entry = values.insertion() catch null;
    const count = values.rows.items.len + @intFromBool(entry != null);
    const ids = w.arena.allocator().alloc(c_uint, count) catch return false;
    for (values.rows.items, 0..) |row, i| ids[i] = row.uid;
    if (entry) |row| ids[count - 1] = row.uid;
    _ = c.kest_table_navigation(ui, ids.ptr, @intCast(ids.len));
    const pixel = 1 / @max(1, c.cui_dpi_scale(ui));
    w.column(ui, .{ .id = "kv-grid", .height = w.fill, .max_height = c.KEST_TABLE_HEADER + pixel + @as(f32, @floatFromInt(count)) * c.KEST_TABLE_STRIDE, .width = w.fill, .clip = true });
    w.row(ui, .{ .id = "kv-heading", .height = w.px(c.KEST_TABLE_HEADER), .width = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED), .@"align" = c.CUI_ALIGN_CENTER });
    slot(ui, c.KEST_TABLE_ENABLED);
    c.cui_icon(ui, c.CUI_ICON_CHECK, 12, w.color(c.CUI_TOKEN_TEXT_SECONDARY));
    w.end(ui);
    heading(ui, switch (opts.kind) {
        .params => "Parameter",
        .headers => "Header",
        .form => "Field",
        .variables => "Variable",
    }, 2);
    heading(ui, "Value", 3);
    if (files) {
        slot(ui, c.KEST_TABLE_PICKER);
        w.end(ui);
        w.text(ui, "Type", .{ .width = w.px(c.KEST_TABLE_TYPE), .size = 11, .@"align" = c.CUI_TEXT_CENTER, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    }
    var add = false;
    var auto_headers = false;
    if (c.kest_table_menu_begin(ui, "table-actions", false, if (values.bulk_problem.message.len > 0) w.z(values.bulk_problem.message) else null, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        w.muted(ui, title);
        if (c.cui_menu_item_ex(ui, "Add row", &.{ .disabled = entry == null })) add = true;
        if (w.menuItem(ui, "Bulk edit")) openBulk(values);
        if (opts.kind == .headers and opts.request != null and w.menuItem(ui, "Automatic request headers")) auto_headers = true;
        c.cui_menu_separator(ui);
        w.text(ui, "Tab / Enter: next cell\nShift Tab: previous cell\nUp / Down: same column\nAlt Down: row actions", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        c.cui_menu_end(ui);
    }
    w.end(ui);
    w.separator(ui, "kv-heading-boundary");
    if (add and entry != null) c.kest_table_focus(ui, entry.?.uid, 0, @intCast(values.rows.items.len));
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "kv-rows", @intCast(count), c.KEST_TABLE_STRIDE, w.fill, &first, &last);
    var remove: ?usize = null;
    var duplicate: ?usize = null;
    var move: ?struct { from: usize, to: usize } = null;
    var inspect_row = false;
    var commit = false;
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const insertion = i == values.rows.items.len;
        const row = if (insertion) entry.? else values.rows.items[i];
        c.cui_push_id_int(ui, @intCast(row.uid));
        c.kest_table_row_begin(ui);
        slot(ui, c.KEST_TABLE_ENABLED);
        if (!insertion) {
            changed = c.cui_checkbox_ex(ui, "###enabled", &row.enabled, &.{}) or changed;
            c.cui_tooltip(ui, "Include this row");
        }
        w.end(ui);
        const key_changed = field(ui, "key", &row.key, switch (opts.kind) {
            .params => "e.g. limit",
            .headers => "e.g. Accept",
            .form => "e.g. name",
            .variables => "e.g. base_url",
        }, 2);
        const value_changed = field(ui, "value", &row.value, if (files and row.is_file) "File path" else switch (opts.kind) {
            .params => "e.g. 25",
            .headers => "e.g. application/json",
            .form => "Enter content",
            .variables => "Enter variable content",
        }, 3);
        if (value_changed) row.has_equals = true;
        if (insertion) commit = key_changed or value_changed else changed = changed or key_changed or value_changed;
        if (files) {
            slot(ui, c.KEST_TABLE_PICKER);
            if (row.is_file and opts.app != null) {
                if (w.action(ui, "choose-field-file", "", c.CUI_ICON_FOLDER_OPEN, false, 28, 28, 3) and upload.choose(opts.app.?, &row.value)) {
                    row.has_equals = true;
                    if (insertion) commit = true else changed = true;
                }
                c.cui_tooltip(ui, "Choose a file for this field");
            }
            w.end(ui);
            slot(ui, c.KEST_TABLE_TYPE);
            if (w.action(ui, "field-type", if (row.is_file) "File" else "Text", null, row.is_file, c.KEST_TABLE_TYPE, 28, 3)) {
                row.is_file = !row.is_file;
                if (!insertion) changed = true;
                c.cui_request_redraw(ui);
            }
            c.cui_tooltip(ui, if (row.is_file) "File field; switch to text without discarding the value" else "Text field; switch to a file path without discarding the value");
            w.end(ui);
        }
        if (insertion) {
            slot(ui, c.KEST_TABLE_ACTIONS);
            w.end(ui);
        } else {
            const problem = rowProblem(row, files, opts);
            if (c.kest_table_menu_begin(ui, "row-actions", true, if (problem.message) |message| w.z(message) else null, w.color(if (problem.danger) c.CUI_TOKEN_DANGER else if (problem.message != null) c.CUI_TOKEN_WARNING else c.CUI_TOKEN_TEXT_SECONDARY))) {
                if (problem.message) |message| w.text(ui, message, .{ .width = w.fill, .size = 12, .color = w.color(if (problem.danger) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_WARNING) });
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
    w.text(ui, if (opts.kind == .headers) "Configured request header" else "Row details", .{ .font = c.CUI_FONT_MEDIUM, .size = 13 });
    w.muted(ui, if (row.enabled) "Enabled" else "Disabled; not used when sending");
    if (opts.kind == .form) w.muted(ui, if (files and row.is_file) "File field" else if (!files and row.is_file) "Text field; file type retained for multipart" else "Text field");
    c.kest_document_list_begin(ui, "row-inspector-content", @min(220, c.cui_viewport_size(ui).y - 240));
    w.text(ui, row.key.text(), .{ .font = c.CUI_FONT_MONO, .size = 12, .width = w.fill });
    w.text(ui, row.value.text(), .{ .font = c.CUI_FONT_MONO, .size = 12, .width = w.fill });
    if (files and row.is_file and opts.app != null) upload.details(ui, opts.app.?, row.value.text(), opts.vars);
    c.cui_scroll_end(ui);
    const problem = rowProblem(row, files, opts);
    if (problem.message) |message| w.text(ui, message, .{ .width = w.fill, .size = 12, .color = w.color(if (problem.danger) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_WARNING) });
    if (w.menuItem(ui, "Copy name")) w.copy(ui, row.key.text());
    if (w.menuItem(ui, "Copy value")) w.copy(ui, row.value.text());
}

fn bulk(ui: *c.cui_ctx, values: *tab.Table, title: []const u8) bool {
    var changed = false;
    w.row(ui, .{ .height = w.px(c.KEST_TABLE_HEADER), .width = w.fill });
    w.text(ui, if (values.bulk_problem.message.len > 0) w.fmt("{s}{s}", .{ values.bulk_problem.message, if (values.bulk_problem.line > 0) w.fmt(" (line {d})", .{values.bulk_problem.line}) else "" }) else title, .{ .size = 11, .color = w.color(if (values.bulk_problem.message.len > 0) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_TEXT_MUTED), .width = w.fill, .nowrap = true });
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
fn heading(ui: *c.cui_ctx, label: []const u8, weight: f32) void {
    w.column(ui, .{ .width = weighted(weight), .pad_left = 10 });
    w.text(ui, label, .{ .size = 11, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
}
