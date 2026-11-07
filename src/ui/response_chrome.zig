const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const Response = @import("../core/response.zig").Response;
const commands = @import("../app/commands.zig");

pub fn navigation(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    const resp: ?*Response = if (t.shown) |job| &job.resp else null;
    w.row(ui, .{ .id = "response-navigation", .height = w.px(36), .width = w.fill, .pad_left = 4, .pad_right = 6 });
    defer w.end(ui);
    if (w.action(ui, "response-body", "Response", null, t.response.pane == .pretty or t.response.pane == .raw, 0, 36, 2)) t.response.pane = .pretty;
    if (w.action(ui, "response-headers", "Headers", null, t.response.pane == .headers, 0, 36, 2)) t.response.pane = .headers;
    if (resp != null and (resp.?.class() == .image or resp.?.class() == .html)) {
        if (w.action(ui, "response-preview", "Preview", null, t.response.pane == .preview, 0, 36, 2)) t.response.pane = .preview;
    }
    c.cui_spacer(ui);
    if (resp) |r| {
        if ((t.response.pane == .pretty or t.response.pane == .raw) and r.class() != .image and r.class() != .html and w.menu(ui, if (t.response.pane == .raw) "Raw###response-format" else if (t.response.pretty_mode == .tree) "Tree###response-format" else if (r.class() == .json) "JSON###response-format" else "Text###response-format", 88, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
            if (r.class() == .json) {
                if (c.cui_menu_item_ex(ui, "Formatted JSON", &.{ .checked = t.response.pane == .pretty and t.response.pretty_mode == .text })) {
                    t.response.pane = .pretty;
                    t.response.pretty_mode = .text;
                }
                if (c.cui_menu_item_ex(ui, "JSON tree", &.{ .checked = t.response.pane == .pretty and t.response.pretty_mode == .tree })) {
                    t.response.pane = .pretty;
                    t.response.pretty_mode = .tree;
                }
                if (c.cui_menu_item_ex(ui, "Minified JSON", &.{ .checked = t.response.pane == .pretty and t.response.pretty_mode == .minified })) {
                    t.response.pane = .pretty;
                    t.response.pretty_mode = .minified;
                }
            }
            if (c.cui_menu_item_ex(ui, "Raw text", &.{ .checked = t.response.pane == .raw })) t.response.pane = .raw;
            if (w.menuItem(ui, "Preview")) t.response.pane = .preview;
            c.cui_menu_end(ui);
        }
        if (c.retort_dropdown_begin(ui, "Response actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
            if (w.menuItem(ui, "Raw text")) t.response.pane = .raw;
            if (w.menuItem(ui, "Preview")) t.response.pane = .preview;
            if (w.menuItem(ui, "Find in response")) find(t);
            if (w.menuItem(ui, "Copy response")) w.copy(ui, if (t.response.pane == .headers) r.raw_headers else r.preview.items);
            if (w.menuItem(ui, "Save response...")) @import("response.zig").save(app, r);
            if (t.response.pretty_mode == .tree) {
                if (w.menuItem(ui, "Expand all")) if (t.response.tree) |*tr| tr.setAll(app.gpa, false) catch {};
                if (w.menuItem(ui, "Collapse all")) if (t.response.tree) |*tr| tr.setAll(app.gpa, true) catch {};
            }
            c.cui_menu_separator(ui);
            if (w.menuItem(ui, "Clear response")) commands.clearResponse(t);
            c.cui_menu_end(ui);
        }
    }
}

pub fn footer(ui: *c.cui_ctx, app: *App, t: *tab.Tab, r: *Response) void {
    c.cui_separator(ui);
    w.row(ui, .{ .id = "response-summary", .width = w.fill, .height = w.px(30), .gap = 10, .pad_left = 12, .pad_right = 4, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED) });
    defer w.end(ui);
    w.text(ui, if (r.status == 0) "Failed" else w.fmt("{d} {s}", .{ r.status, r.reason }), .{ .size = 11, .font = c.CUI_FONT_MEDIUM, .color = w.color(if (r.status >= 200 and r.status < 300) c.CUI_TOKEN_SUCCESS else if (r.status >= 400 or r.status == 0) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_WARNING), .nowrap = true });
    w.text(ui, w.fmt("{d} ms", .{r.time_ms}), .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true });
    w.text(ui, w.bytes(r.total.load(.monotonic)), .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true });
    c.cui_spacer(ui);
    if (w.action(ui, "find-response", "", c.CUI_ICON_SEARCH, false, 26, 26, 3)) find(t);
    c.cui_tooltip(ui, "Find in response (Ctrl F)");
    if (w.action(ui, "copy-response", "", c.CUI_ICON_COPY, false, 26, 26, 3)) w.copy(ui, if (t.response.pane == .headers) r.raw_headers else r.preview.items);
    c.cui_tooltip(ui, "Copy response");
    if (w.action(ui, "save-response", "", c.CUI_ICON_DOWNLOAD, false, 26, 26, 3)) @import("response.zig").save(app, r);
    c.cui_tooltip(ui, "Save entire response");
}
fn find(t: *tab.Tab) void {
    t.response.code_raw.search_open = true;
    t.response.code_raw.query.focus();
    t.response.pane = .raw;
}
