//! Actual response headers in a compact table, with copy on each row.
const w = @import("widgets.zig");
const c = w.c;
const Response = @import("../core/response.zig").Response;

pub fn view(ui: *c.cui_ctx, resp: *Response) void {
    w.column(ui, .{ .width = w.fill, .height = w.fill, .pad = 12, .gap = 8 });
    defer w.end(ui);
    w.muted(ui, w.fmt("{d} response headers", .{resp.headers.items.len}));
    w.column(ui, .{ .width = w.fill, .height = w.fill, .max_height = 29 + @as(f32, @floatFromInt(resp.headers.items.len)) * 34, .border = 1, .border_color = w.color(c.CUI_TOKEN_BORDER), .radius = 4, .clip = true });
    defer w.end(ui);
    w.row(ui, .{ .height = w.px(28), .width = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED) });
    cell(ui, "Name", true);
    c.cui_separator(ui);
    cell(ui, "Value", true);
    w.column(ui, .{ .width = w.px(28) });
    w.end(ui);
    w.end(ui);
    c.cui_separator(ui);
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "response-header-rows", @intCast(resp.headers.items.len), 34, w.fill, &first, &last);
    defer c.cui_virtual_list_end(ui);
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const h = resp.headers.items[i];
        c.cui_push_id_int(ui, @intCast(i));
        w.row(ui, .{ .height = w.px(33), .width = w.fill });
        cell(ui, h.name, false);
        c.cui_separator(ui);
        cell(ui, h.value, false);
        if (w.action(ui, "copy-header", "", c.CUI_ICON_COPY, false, 28, 28, 3)) w.copy(ui, w.fmt("{s}: {s}", .{ h.name, h.value }));
        c.cui_tooltip(ui, w.z(w.fmt("Copy {s}", .{h.name})));
        w.end(ui);
        c.cui_separator(ui);
        c.cui_pop_id(ui);
    }
}
fn cell(ui: *c.cui_ctx, text: []const u8, heading: bool) void {
    w.column(ui, .{ .width = w.fill, .pad_x = 10, .clip = true });
    w.text(ui, text, .{ .width = w.fill, .size = if (heading) 11 else 12, .font = if (heading) c.CUI_FONT_MEDIUM else c.CUI_FONT_BODY, .color = w.color(if (heading) c.CUI_TOKEN_TEXT_SECONDARY else c.CUI_TOKEN_FOREGROUND), .nowrap = true });
    w.end(ui);
    if (!heading) c.cui_tooltip(ui, w.z(text));
}
