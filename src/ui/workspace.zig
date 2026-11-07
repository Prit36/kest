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
pub const Layout = @import("../storage/workspace_store.zig").EditorLayout;
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
        const before = column_ratio;
        c.cui_split_begin(ui, "editors-columns", &column_ratio, &.{ .min_first = 320, .min_second = 360, .width = w.fill, .height = w.fill });
        request.view(ui, app, t);
        c.cui_split_next(ui);
        response.view(ui, app, t);
        c.cui_split_end(ui);
        if (before != column_ratio) {
            app.prefs.column_split = column_ratio;
            persist.prefsChanged(app);
        }
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
    // CUI 1.1 sees a just-added tab before it has geometry; retry revealing
    // on the following frame, and when the strip changes width.
    const strip = c.cui_make_id(ui, "request-documents") ^ 0xd0c7;
    const width = c.cui_get_rect(ui, strip).w;
    if (app.current()) |t| {
        if (revealed_document != t.uid or @abs(revealed_width - width) > 1) {
            c.cui_push_id(ui, "request-documents");
            const target = c.cui_make_id(ui, documentTitle(t));
            c.cui_pop_id(ui);
            if (c.retort_reveal(ui, strip, target, true)) {
                revealed_document = t.uid;
                revealed_width = width;
            }
        }
    }
    var tabs: [64]c.cui_doc_tab = undefined;
    for (app.tabs.items, 0..) |t, i| tabs[i] = .{
        .title = documentTitle(t),
        .tooltip = w.z(if (t.url.len > 0) t.url.text() else t.name),
        .dirty = t.dirty,
    };
    w.row(ui, .{ .height = w.px(40), .width = w.fill, .bg = w.color(c.CUI_TOKEN_BACKGROUND), .gap = 0, .clip = true });
    var selected: c_int = @intCast(app.active);
    const result = c.cui_doc_tabs_ex(ui, "request-documents", &tabs, @intCast(app.tabs.items.len), &selected, &.{});
    // Close refers to the submitted order; capture the pointer before moving.
    const close = if (result.close >= 0) app.tabs.items[@intCast(result.close)] else null;
    if (result.move_from >= 0 and result.move_to >= 0) {
        commands.moveTab(app, @intCast(result.move_from), @intCast(result.move_to));
        revealed_document = 0;
    }
    if (selected >= 0) commands.activate(app, @intCast(selected));
    if (w.action(ui, "new-document", "", c.CUI_ICON_PLUS, false, 34, 34, 3)) _ = commands.newTab(app);
    c.cui_tooltip(ui, "New request (Ctrl N)");
    if (c.retort_dropdown_begin(ui, "Request actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (app.current()) |t| actions(ui, app, t);
        c.cui_menu_separator(ui);
        layoutMenu(ui, app);
        c.cui_menu_end(ui);
    }
    w.end(ui);
    c.cui_separator(ui);
    if (close) |t| commands.requestClose(app, t);
}

fn context(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    w.row(ui, .{ .height = w.px(34), .pad_x = 14, .gap = 8, .width = w.fill });
    defer w.end(ui);
    const col = @import("../core/collection.zig");
    var ancestors: std.ArrayList(*col.Node) = .empty;
    if (t.link) |link| for (app.collections.items) |root| {
        if (std.mem.eql(u8, &root.id, &link.collection)) {
            var node = root.find(&link.request);
            while (node) |n| : (node = n.parent) ancestors.append(w.arena.allocator(), n) catch break;
            break;
        }
    };
    std.mem.reverse(*col.Node, ancestors.items);
    var segments: std.ArrayList([*:0]const u8) = .empty;
    for (ancestors.items) |n| segments.append(w.arena.allocator(), w.z(n.name)) catch return;
    if (segments.items.len == 0) {
        segments.appendSlice(w.arena.allocator(), &.{ "Unsaved requests", w.z(t.name) }) catch return;
    }
    const path = c.cui_path_bar_ex(ui, "request-path", segments.items.ptr, @intCast(segments.items.len), &.{
        .icon = c.CUI_ICON_FOLDER,
        .size = c.CUI_SIZE_SM,
        .no_edit = true,
    });
    if (path.clicked >= 0) {
        const i: usize = @intCast(path.clicked);
        if (i < ancestors.items.len) {
            @import("sidebar.zig").reveal(app, ancestors.items[i]);
            app.mode = .collections;
            if (c.cui_viewport_size(ui).x < 840) @import("shell.zig").narrow_open = true else {
                app.prefs.sidebar_open = true;
                persist.prefsChanged(app);
            }
        }
    }
    if (w.action(ui, "rename-request", "", c.CUI_ICON_PENCIL, false, 26, 26, 3)) dialogs.askName(app, .{ .rename_tab = t }, t.name);
    c.cui_tooltip(ui, "Rename request");
    c.cui_spacer(ui);
    if (t.dirty) w.text(ui, "Unsaved", .{ .size = 11, .color = w.color(c.CUI_TOKEN_ACCENT) });
    if (w.menu(ui, "Layout", 96, w.color(c.CUI_TOKEN_TEXT_MUTED))) {
        layoutMenu(ui, app);
        c.cui_menu_end(ui);
    }
}

fn layoutMenu(ui: *c.cui_ctx, app: *App) void {
    inline for (.{ .{ "Automatic layout", Layout.auto }, .{ "Side by side", Layout.columns }, .{ "Stacked", Layout.stacked } }) |choice| {
        if (c.cui_menu_item_ex(ui, choice[0], &.{ .checked = layout == choice[1] })) {
            layout = choice[1];
            app.prefs.editor_layout = layout;
            persist.prefsChanged(app);
        }
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

// A stable ### identity keeps selection and drag state when a request is renamed.
pub fn documentTitle(t: *const Tab) [*:0]const u8 {
    return w.fmt("{s}  {s}###request-{d}", .{ t.method.text(), t.name, t.uid });
}
