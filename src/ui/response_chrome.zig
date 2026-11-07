const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const Response = @import("../core/response.zig").Response;
const commands = @import("../app/commands.zig");

pub fn navigation(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    const resp: ?*Response = if (t.shown) |job| &job.resp else null;
    // Previous-frame width decides how much of the summary and toolbar fits.
    const panel = c.cui_get_rect(ui, c.cui_make_id(ui, "response-panel")).w;
    const width = if (panel > 0) panel else 600;
    w.row(ui, .{ .id = "response-navigation", .height = w.px(36), .width = w.fill, .pad_left = 4, .pad_right = 6, .gap = 2 });
    defer w.end(ui);
    if (w.action(ui, "response-body", "Response", null, t.response.pane == .pretty or t.response.pane == .raw, 0, 36, 2)) t.response.pane = .pretty;
    const header_label = if (resp) |r| (if (r.headers.items.len > 0) w.fmt("Headers {d}", .{r.headers.items.len}) else "Headers") else "Headers";
    if (w.action(ui, "response-headers", header_label, null, t.response.pane == .headers, 0, 36, 2)) t.response.pane = .headers;
    if (resp != null and (resp.?.class() == .image or resp.?.class() == .html or @import("response.zig").isMarkdown(resp.?))) {
        if (w.action(ui, "response-preview", "Preview", null, t.response.pane == .preview, 0, 36, 2)) t.response.pane = .preview;
    }
    c.cui_spacer(ui);
    const r = resp orelse return;
    summary(ui, r, width);
    if ((t.response.pane == .pretty or t.response.pane == .raw) and r.class() != .image and r.class() != .html and w.menu(ui, if (t.response.pane == .raw) "Raw###response-format" else if (t.response.pretty_mode == .tree) "Tree###response-format" else if (r.class() == .json) "JSON###response-format" else "Text###response-format", 84, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
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
    if (width >= 620) {
        if (w.action(ui, "find-response", "", c.CUI_ICON_SEARCH, false, 28, 28, 3)) find(t);
        c.cui_tooltip(ui, "Find in response (Ctrl+F)");
        if (w.action(ui, "copy-response", "", c.CUI_ICON_COPY, false, 28, 28, 3)) w.copy(ui, if (t.response.pane == .headers) r.raw_headers else r.preview.items);
        c.cui_tooltip(ui, "Copy response");
        if (w.action(ui, "save-response", "", c.CUI_ICON_DOWNLOAD, false, 28, 28, 3)) @import("response.zig").save(app, r);
        c.cui_tooltip(ui, "Save entire response");
    }
    if (c.kest_dropdown_begin(ui, "Response actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (w.menuItem(ui, "Raw text")) t.response.pane = .raw;
        if (w.menuItem(ui, "Preview")) t.response.pane = .preview;
        if (c.cui_menu_item_ex(ui, "Find in response", &.{ .icon = c.CUI_ICON_SEARCH, .shortcut = "Ctrl+F" })) find(t);
        if (c.cui_menu_item_ex(ui, "Copy response", &.{ .icon = c.CUI_ICON_COPY })) w.copy(ui, if (t.response.pane == .headers) r.raw_headers else r.preview.items);
        if (c.cui_menu_item_ex(ui, "Save response...", &.{ .icon = c.CUI_ICON_DOWNLOAD })) @import("response.zig").save(app, r);
        if (t.response.pretty_mode == .tree) {
            if (w.menuItem(ui, "Expand all")) if (t.response.tree) |*tr| tr.setAll(app.gpa, false) catch {};
            if (w.menuItem(ui, "Collapse all")) if (t.response.tree) |*tr| tr.setAll(app.gpa, true) catch {};
        }
        c.cui_menu_separator(ui);
        if (w.menuItem(ui, "Clear response")) commands.clearResponse(t);
        c.cui_menu_end(ui);
    }
}

// Status, duration and size sit beside the response tabs, where they are
// read first. Narrow panels keep the status code and duration.
fn summary(ui: *c.cui_ctx, r: *Response, width: f32) void {
    w.row(ui, .{ .id = "response-summary", .gap = 10, .pad_right = 8 });
    defer w.end(ui);
    const status = if (r.status == 0) "Failed" else if (width >= 520 and r.reason.len > 0 and r.reason.len <= 24) w.fmt("{d} {s}", .{ r.status, r.reason }) else w.fmt("{d}", .{r.status});
    w.text(ui, status, .{ .size = 12, .font = c.CUI_FONT_MEDIUM, .color = w.statusColor(r.status), .nowrap = true });
    w.text(ui, w.fmt("{d} ms", .{r.time_ms}), .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
    if (width >= 440) w.text(ui, w.bytes(r.total.load(.monotonic)), .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
}

fn find(t: *tab.Tab) void {
    t.response.code_raw.search_open = true;
    t.response.code_raw.query.focus();
    t.response.pane = .raw;
}
