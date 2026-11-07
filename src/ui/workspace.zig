//! Request-oriented workspace: shared composer, adaptive editors, flat documents.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const Tab = @import("../app/tab.zig").Tab;
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const dialogs = @import("dialogs.zig");
const request = @import("request.zig");
const response = @import("response.zig");
pub const Layout = enum { auto, columns, stacked };
pub var layout: Layout = .auto;
pub var column_ratio: f32 = 0.42;
var revealed_document: u64 = 0;
var revealed_width: f32 = 0;

pub fn view(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .id = "main-workspace", .width = w.fill, .height = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE), .clip = true });
    defer w.end(ui);
    documents(ui, app);
    const t = app.current() orelse return;
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    if (c.cui_viewport_size(ui).y >= 600) context(ui, app, t);
    request.bar(ui, app, t);
    const bounds = c.cui_get_rect(ui, c.cui_make_id(ui, "request-composer"));
    const width = if (bounds.w > 0) bounds.w else c.cui_viewport_size(ui).x - 280;
    const columns = width >= 730 and layout != .stacked and (layout == .columns or c.cui_viewport_size(ui).x >= 1100);
    if (t.details_collapsed) {
        w.column(ui, .{ .height = w.px(37), .width = w.fill });
        request.view(ui, app, t);
        w.end(ui);
        response.view(ui, app, t);
    } else if (columns) {
        c.cui_split_begin(ui, "editors-columns", &column_ratio, &.{ .min_first = 320, .min_second = 360, .width = w.fill, .height = w.fill });
        request.view(ui, app, t);
        c.cui_split_next(ui);
        response.view(ui, app, t);
        c.cui_split_end(ui);
    } else {
        const before = app.prefs.split;
        c.cui_split_begin(ui, "request-response", &app.prefs.split, &.{ .vertical = true, .min_first = request.minimumHeight(t), .min_second = 128, .width = w.fill, .height = w.fill });
        request.view(ui, app, t);
        c.cui_split_next(ui);
        response.view(ui, app, t);
        c.cui_split_end(ui);
        if (before != app.prefs.split) persist.prefsChanged(app);
    }
}

fn documents(ui: *c.cui_ctx, app: *App) void {
    const viewport_width = c.cui_get_rect(ui, c.cui_make_id(ui, "main-workspace")).w;
    if (app.current()) |t| {
        if (revealed_document != t.uid or @abs(revealed_width - viewport_width) > 1) {
            c.cui_push_id_int(ui, @intCast(t.uid));
            const target = c.cui_make_id(ui, "document-tab");
            c.cui_pop_id(ui);
            if (c.retort_reveal(ui, "document-scroll", target, true)) {
                revealed_document = t.uid;
                revealed_width = viewport_width;
            }
        }
    }
    w.row(ui, .{ .height = w.px(36), .width = w.fill, .bg = w.color(c.CUI_TOKEN_BACKGROUND), .gap = 0, .clip = true });
    c.cui_scroll_begin(ui, &.{ .id = "document-scroll", .horizontal = true, .height = w.px(36), .width = w.fill });
    w.row(ui, .{ .height = w.px(36) });
    var close: ?*Tab = null;
    for (app.tabs.items, 0..) |t, i| {
        c.cui_push_id_int(ui, @intCast(t.uid));
        const clicked = c.retort_control_begin(ui, "document-tab", i == app.active, 174, 36, 1);
        w.text(ui, t.method.text(), .{ .font = c.CUI_FONT_MONO, .size = 10, .color = w.methodColor(t.method.text()), .nowrap = true });
        w.text(ui, t.name, .{ .size = 12, .width = w.fill, .nowrap = true, .font = if (i == app.active) c.CUI_FONT_MEDIUM else c.CUI_FONT_BODY, .color = w.color(if (i == app.active) c.CUI_TOKEN_FOREGROUND else c.CUI_TOKEN_TEXT_SECONDARY) });
        if (t.dirty) w.text(ui, "*", .{ .size = 12, .color = w.color(c.CUI_TOKEN_ACCENT) });
        if (w.action(ui, "close-document", "", c.CUI_ICON_X, false, 20, 24, 3)) close = t;
        c.retort_item_end(ui);
        c.cui_tooltip(ui, w.z(if (t.url.len > 0) t.url.text() else t.name));
        if (clicked) commands.activate(app, i);
        c.cui_pop_id(ui);
    }
    w.end(ui);
    c.cui_scroll_end(ui);
    if (w.action(ui, "new-document", "", c.CUI_ICON_PLUS, false, 34, 34, 3)) _ = commands.newTab(app);
    c.cui_tooltip(ui, "New request (Ctrl N)");
    if (c.retort_dropdown_begin(ui, "Request actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (app.current()) |t| actions(ui, app, t);
        c.cui_menu_separator(ui);
        layoutMenu(ui);
        c.cui_menu_end(ui);
    }
    w.end(ui);
    c.cui_separator(ui);
    if (close) |t| commands.requestClose(app, t);
}

fn context(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    w.row(ui, .{ .height = w.px(34), .pad_x = 14, .gap = 8, .width = w.fill });
    defer w.end(ui);
    c.cui_icon(ui, c.CUI_ICON_FOLDER, 13, w.color(c.CUI_TOKEN_TEXT_MUTED));
    var location: []const u8 = "Unsaved requests";
    if (t.link) |link| for (app.collections.items) |root| {
        if (std.mem.eql(u8, &root.id, &link.collection)) {
            location = root.name;
            break;
        }
    };
    w.text(ui, location, .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true });
    w.muted(ui, "/");
    if (w.action(ui, "rename-request", t.name, null, false, 0, 26, 3)) dialogs.askName(app, .{ .rename_tab = t }, t.name);
    c.cui_tooltip(ui, "Rename request");
    c.cui_spacer(ui);
    if (t.dirty) w.text(ui, "Unsaved", .{ .size = 11, .color = w.color(c.CUI_TOKEN_ACCENT) });
    if (w.menu(ui, "Layout", 96, w.color(c.CUI_TOKEN_TEXT_MUTED))) {
        layoutMenu(ui);
        c.cui_menu_end(ui);
    }
}

fn layoutMenu(ui: *c.cui_ctx) void {
    inline for (.{ .{ "Automatic layout", Layout.auto }, .{ "Side by side", Layout.columns }, .{ "Stacked", Layout.stacked } }) |choice| {
        if (c.cui_menu_item_ex(ui, choice[0], &.{ .checked = layout == choice[1] })) layout = choice[1];
    }
}

fn actions(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    if (w.menuItem(ui, "Rename")) dialogs.askName(app, .{ .rename_tab = t }, t.name);
    if (c.cui_menu_item_ex(ui, "Save", &.{ .icon = c.CUI_ICON_SAVE, .shortcut = "Ctrl S" })) commands.save(app, t);
    if (w.menuItem(ui, "Save as...")) commands.beginSaveAs(app, t);
    if (c.cui_menu_item_ex(ui, "Duplicate", &.{ .icon = c.CUI_ICON_COPY, .shortcut = "Ctrl D" })) commands.duplicateTab(app, t);
    if (w.menuItem(ui, "Copy as cURL")) {
        if (t.toRequest(w.arena.allocator()) catch null) |req| w.copy(ui, @import("../import_export/curl.zig").generate(w.arena.allocator(), req) catch "");
    }
    if (w.menuItem(ui, "Encode URL")) commands.encodeUrl(app, t);
    if (w.menuItem(ui, "Decode URL")) commands.decodeUrl(app, t);
}
