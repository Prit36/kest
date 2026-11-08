//! Read-only initial-send header details, derived from current request data.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const Tab = @import("../app/tab.zig").Tab;
const variables = @import("../core/variables.zig");
const transport = @import("../network/transport.zig");

pub fn configured(t: *const Tab, name: []const u8, vars: []const variables.Var) bool {
    for (t.headers.rows.items) |row| {
        if (!row.enabled or row.key.len == 0) continue;
        const key = if (std.mem.indexOf(u8, row.key.text(), "{{") != null) variables.resolve(w.arena.allocator(), row.key.text(), vars) catch continue else row.key.text();
        if (std.ascii.eqlIgnoreCase(key, name)) return true;
    }
    return false;
}

fn field(ui: *c.cui_ctx, name: []const u8, value: []const u8) void {
    w.column(ui, .{ .width = w.fill, .gap = 2, .pad_bottom = 8 });
    w.text(ui, name, .{ .size = 12, .font = c.CUI_FONT_MEDIUM });
    w.text(ui, value, .{ .width = w.fill, .size = 12, .font = c.CUI_FONT_MONO, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
}

pub fn view(ui: *c.cui_ctx, t: *const Tab, vars: []const variables.Var) void {
    w.text(ui, "Automatic request headers", .{ .size = 13, .font = c.CUI_FONT_MEDIUM });
    c.kest_document_list_begin(ui, "automatic-header-content", @min(240, c.cui_viewport_size(ui).y - 160));
    if (!configured(t, "Host", vars)) {
        const resolved = variables.resolve(w.arena.allocator(), t.url.text(), vars) catch "";
        if (@import("../utils/url.zig").parse(resolved)) |parts| field(ui, "Host", parts.authority) else |_| field(ui, "Host", "Unresolved");
    }
    for (transport.default_headers) |header| if (!configured(t, header.name, vars)) field(ui, header.name, header.value);
    if (!configured(t, "Content-Type", vars)) {
        if (t.body_kind.contentType()) |content_type| field(ui, "Content-Type", content_type) else if (t.body_kind == .multipart) field(ui, "Content-Type", "multipart/form-data; boundary generated on send") else if (t.body_kind == .file) {
            const path = @import("upload.zig").resolve(w.arena.allocator(), t.file_path.text(), vars);
            field(ui, "Content-Type", if (path.problem == null) @import("../network/prepare.zig").guessType(path.resolved) else "From file name");
        }
    }
    field(ui, "Content-Length", if (t.body_kind == .none) "Omitted" else "Calculated on send");
    c.cui_scroll_end(ui);
    _ = w.menuItem(ui, "Close");
}
