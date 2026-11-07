//! Received order and duplicate names are preserved. Cells are selectable
//! read-only previews; full values require explicit inspection, never hover.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const Tab = @import("../app/tab.zig").Tab;
const Response = @import("../core/response.zig").Response;
const Header = @import("../core/response.zig").Header;
const text = @import("../core/header_text.zig");
pub const cell_limit = 512;
pub const inspector_limit = 16 * 1024;

fn weighted(weight: f32) c.cui_size {
    return .{ .kind = c.CUI_SIZE_GROW, .value = weight };
}
fn preview(source: []const u8, limit: usize) text.Display {
    return text.display(w.arena.allocator(), source, limit) catch .{ .text = @constCast("Preview unavailable"), .truncated = true, .escaped = false };
}
pub fn copy(ui: *c.cui_ctx, source: []const u8) void {
    const value = text.clipboardText(w.arena.allocator(), source) catch {
        _ = c.cui_toast_ex(ui, "Could not prepare header copy", &.{ .description = "Not enough memory to prepare clipboard text.", .tone = c.CUI_TONE_DANGER, .duration = 8 });
        return;
    };
    c.kest_copy(ui, value.ptr);
}
pub fn copyAll(ui: *c.cui_ctx, resp: *const Response) void {
    copy(ui, resp.raw_headers);
}
fn line(header: Header) []const u8 {
    return if (header.raw_line.len > 0) header.raw_line else w.fmt("{s}: {s}", .{ header.name, header.value });
}
fn cell(ui: *c.cui_ctx, id: [*:0]const u8, source: []const u8, weight: f32) bool {
    const display = preview(source, cell_limit);
    const buffer = w.z(display.text);
    const flags = c.kest_table_input(ui, id, @constCast(buffer.ptr), buffer.len + 1, &.{ .width = weighted(weight), .read_only = true, .placeholder = "(empty)" });
    c.cui_tooltip(ui, "Read-only preview. Enter inspects the full header; Alt Down opens row actions.");
    return flags & c.CUI_SUBMITTED != 0;
}
fn heading(ui: *c.cui_ctx, id: [*:0]const u8, label: []const u8, weight: f32) void {
    w.column(ui, .{ .id = id, .width = weighted(weight), .pad_x = 10 });
    w.text(ui, label, .{ .width = w.fill, .size = 11, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
    w.end(ui);
}

pub fn view(ui: *c.cui_ctx, t: *Tab, resp: *Response) void {
    c.kest_response_header_source(ui, resp, @intCast(resp.headers.items.len));
    w.column(ui, .{ .id = "received-headers", .width = w.fill, .height = w.fill, .pad_x = w.design.space.group, .pad_top = w.design.space.tight, .pad_bottom = w.design.space.normal });
    defer w.end(ui);
    if (resp.headers.items.len == 0) {
        w.text(ui, "No response headers were received.", .{ .width = w.fill, .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        return;
    }
    _ = c.kest_response_header_navigation(ui, @intCast(resp.headers.items.len));
    const pixel = 1 / @max(1, c.cui_dpi_scale(ui));
    w.column(ui, .{ .id = "response-header-grid", .width = w.fill, .height = w.fill, .max_height = c.KEST_TABLE_HEADER + pixel + @as(f32, @floatFromInt(resp.headers.items.len)) * c.KEST_TABLE_STRIDE, .clip = true });
    w.row(ui, .{ .id = "response-header-heading", .width = w.fill, .height = w.px(c.KEST_TABLE_HEADER), .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED), .@"align" = c.CUI_ALIGN_CENTER });
    heading(ui, "response-header-name-column", "Header", 2);
    heading(ui, "response-header-value-column", "Value", 3);
    if (c.kest_table_menu_begin(ui, "table-actions", false, null, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        if (w.menuItem(ui, if (text.clipboardSafe(resp.raw_headers)) "Copy response headers" else "Copy escaped response headers")) copyAll(ui, resp);
        c.cui_menu_separator(ui);
        w.text(ui, "Read-only received headers\nTab: next cell\nUp / Down: same column\nCtrl Home / End: first / last row\nEnter: inspect header", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        c.cui_menu_end(ui);
    }
    w.end(ui);
    w.separator(ui, "response-header-heading-boundary");
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "response-header-rows", @intCast(resp.headers.items.len), c.KEST_TABLE_STRIDE, w.fill, &first, &last);
    var inspect_row: ?usize = null;
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const header = resp.headers.items[i];
        c.cui_push_id_int(ui, @intCast(i));
        c.kest_table_row_begin(ui);
        const name_enter = cell(ui, "key", header.name, 2);
        const value_enter = cell(ui, "value", header.value, 3);
        if (name_enter or value_enter) inspect_row = i;
        if (c.kest_table_menu_begin(ui, "row-actions", true, null, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
            if (w.menuItem(ui, "Inspect header")) inspect_row = i;
            if (w.menuItem(ui, if (text.clipboardSafe(header.name)) "Copy name" else "Copy escaped name")) copy(ui, header.name);
            if (w.menuItem(ui, if (text.clipboardSafe(header.value)) "Copy value" else "Copy escaped value")) copy(ui, header.value);
            if (w.menuItem(ui, if (text.clipboardSafe(line(header))) "Copy header line" else "Copy escaped header line")) copy(ui, line(header));
            c.cui_menu_end(ui);
        }
        w.end(ui);
        c.cui_pop_id(ui);
    }
    c.cui_virtual_list_end(ui);
    w.end(ui);
    if (inspect_row) |i| {
        t.response.inspected_header = i;
        t.response.header_name_offset = 0;
        t.response.header_value_offset = 0;
        c.cui_popover_open(ui, "response-header-details");
    }
    inspector(ui, t, resp);
}

fn inspector(ui: *c.cui_ctx, t: *Tab, resp: *const Response) void {
    const index = t.response.inspected_header orelse return;
    if (index >= resp.headers.items.len) {
        c.cui_popover_close(ui, "response-header-details");
        t.response.inspected_header = null;
        return;
    }
    if (!c.kest_inspector_begin(ui, "response-header-details", "response-header-heading", 520)) return;
    const header = resp.headers.items[index];
    const name = preview(header.name[@min(t.response.header_name_offset, header.name.len)..], inspector_limit);
    const value = preview(header.value[@min(t.response.header_value_offset, header.value.len)..], inspector_limit);
    w.text(ui, "Received response header", .{ .font = c.CUI_FONT_MEDIUM, .size = 13 });
    c.kest_document_list_begin(ui, "response-header-inspection-content", @min(300, c.cui_viewport_size(ui).y - 168));
    fieldHeading(ui, "Name", "header-name", header.name, name, &t.response.header_name_offset);
    const name_buffer = w.z(name.text);
    _ = c.kest_table_input(ui, "inspected-name", @constCast(name_buffer.ptr), name_buffer.len + 1, &.{ .width = w.fill, .read_only = true });
    fieldHeading(ui, "Value", "header-value", header.value, value, &t.response.header_value_offset);
    const value_buffer = w.z(value.text);
    _ = c.cui_textarea_ex(ui, "inspected-value", @constCast(value_buffer.ptr), value_buffer.len + 1, &.{ .width = w.fill, .height = @min(180, @max(64, c.cui_viewport_size(ui).y - 270)), .read_only = true, .placeholder = "(empty)" });
    if (header.name.len > inspector_limit or header.value.len > inspector_limit) w.text(ui, "Large fields use 16 KiB pages. Copy actions below include the full field.", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    if (name.escaped or value.escaped) w.text(ui, "Control and non-UTF-8 bytes are escaped for display. Escaped copy actions are labeled explicitly.", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    c.cui_scroll_end(ui);
    w.row(ui, .{ .width = w.fill, .gap = 4 });
    if (w.action(ui, "copy-header-name", if (text.clipboardSafe(header.name)) "Copy name" else "Copy escaped name", null, false, 0, 28, 3)) copy(ui, header.name);
    if (w.action(ui, "copy-header-value", if (text.clipboardSafe(header.value)) "Copy value" else "Copy escaped value", null, false, 0, 28, 3)) copy(ui, header.value);
    if (w.action(ui, "copy-header-line", if (text.clipboardSafe(line(header))) "Copy line" else "Copy escaped line", null, false, 0, 28, 3)) copy(ui, line(header));
    w.end(ui);
    if (w.menuItem(ui, "Close")) t.response.inspected_header = null;
    c.cui_menu_end(ui);
}

fn fieldHeading(ui: *c.cui_ctx, label: []const u8, key: []const u8, source: []const u8, shown: text.Display, offset: *usize) void {
    if (source.len <= inspector_limit or shown.source_bytes == 0) {
        w.text(ui, label, .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        return;
    }
    w.row(ui, .{ .width = w.fill, .height = w.px(28), .gap = 4, .@"align" = c.CUI_ALIGN_CENTER });
    w.text(ui, w.fmt("{s} ({d}-{d} of {d} bytes)", .{ label, offset.* + 1, offset.* + shown.source_bytes, source.len }), .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
    if (w.button(ui, w.fmt("###{s}-previous", .{key}), .{ .icon = c.CUI_ICON_CHEVRON_LEFT, .disabled = offset.* == 0, .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_GHOST, .tooltip = "Previous field bytes" })) {
        offset.* -|= inspector_limit;
        var moved: usize = 0;
        while (offset.* > 0 and moved < 3 and source[offset.*] & 0xc0 == 0x80) : (moved += 1) offset.* -= 1;
    }
    if (w.button(ui, w.fmt("###{s}-next", .{key}), .{ .icon = c.CUI_ICON_CHEVRON_RIGHT, .disabled = offset.* + shown.source_bytes >= source.len or shown.source_bytes == 0, .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_GHOST, .tooltip = "Next field bytes" })) offset.* += shown.source_bytes;
    w.end(ui);
}
