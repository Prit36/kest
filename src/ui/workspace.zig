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
var revealed_tab_width: f32 = 0;

pub fn view(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .id = "main-workspace", .width = w.fill, .height = w.fill, .bg = w.color(c.CUI_TOKEN_SURFACE), .clip = true });
    defer w.end(ui);
    documents(ui, app);
    const t = app.current() orelse return;
    const bounds = c.cui_get_rect(ui, c.cui_make_id(ui, "main-workspace"));
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    if (c.cui_viewport_size(ui).y >= 600) context(ui, app, t);
    request.bar(ui, app, t);
    const size = c.cui_viewport_size(ui);
    const width = if (bounds.w > 0) bounds.w else size.x - (if (app.prefs.sidebar_open and size.x >= w.design.geometry.sidebar_sheet) app.prefs.sidebar_width else 0);
    const minimum_columns = if (layout == .columns) w.design.geometry.request_min + w.design.geometry.response_min + 1 else w.design.geometry.columns_min;
    const columns = width >= minimum_columns and layout != .stacked;
    if (t.response_collapsed) {
        request.view(ui, app, t);
    } else if (t.details_collapsed) {
        w.column(ui, .{ .height = w.px(w.design.control.tab_height + 1), .width = w.fill });
        request.view(ui, app, t);
        w.end(ui);
        response.view(ui, app, t);
    } else if (columns) {
        const before = column_ratio;
        c.cui_split_begin(ui, "editors-columns", &column_ratio, &.{ .min_first = w.design.geometry.request_min, .min_second = w.design.geometry.response_min, .width = w.fill, .height = w.fill });
        request.view(ui, app, t);
        c.kest_split_next(ui, "editors-columns", false);
        response.view(ui, app, t);
        c.cui_split_end(ui);
        if (before != column_ratio) {
            app.prefs.column_split = column_ratio;
            persist.prefsChanged(app);
        }
    } else {
        const before = app.prefs.split;
        // Minimums must fit the actual space after shell/composer/activity
        // chrome. Otherwise CUI grows the split beyond its available region.
        const composer = c.cui_get_rect(ui, c.cui_make_id(ui, "composer-area"));
        const log_height = if (app.prefs.log_open) @import("activity.zig").height(size.y) else 0;
        const available = @max(144, size.y - log_height - (if (composer.h > 0) composer.y + composer.h else 135));
        const request_min = @min(request.minimumHeight(t), @max(116, available - 102));
        const response_min = @min(128, @max(64, available - request_min - 6));
        c.cui_split_begin(ui, "request-response", &app.prefs.split, &.{ .vertical = true, .min_first = request_min, .min_second = response_min, .width = w.fill, .height = w.fill });
        request.view(ui, app, t);
        c.kest_split_next(ui, "request-response", true);
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
        c.cui_push_id(ui, "request-documents");
        const target = c.cui_make_id(ui, documentTitle(t));
        c.cui_pop_id(ui);
        const tab_width = c.cui_get_rect(ui, target).w;
        if (revealed_document != t.uid or @abs(revealed_width - width) > 1 or @abs(revealed_tab_width - tab_width) > 1) {
            if (c.kest_reveal(ui, strip, target, true)) {
                revealed_document = t.uid;
                revealed_width = width;
                revealed_tab_width = tab_width;
            }
        }
    }
    var tabs: [@import("../app/tab.zig").max_open_tabs]c.kest_doc_tab = undefined;
    for (app.tabs.items, 0..) |t, i| tabs[i] = .{
        .title = documentTitle(t),
        .label = w.z(t.name),
        .method = w.z(t.method.text()),
        .method_color = w.methodColor(t.method.text()),
        .tooltip = w.fmt("{s} {s}", .{ t.method.text(), t.name }),
        .dirty = t.dirty,
    };
    w.row(ui, .{ .id = "document-row", .height = w.px(w.design.control.document_strip), .width = w.fill, .bg = w.color(c.CUI_TOKEN_BACKGROUND), .gap = 0, .clip = true });
    var selected: c_int = @intCast(app.active);
    const result = c.kest_doc_tabs_ex(ui, "request-documents", &tabs, @intCast(app.tabs.items.len), &selected);
    // Close refers to the submitted order; capture the pointer before moving.
    const close = if (result.close >= 0) app.tabs.items[@intCast(result.close)] else null;
    if (result.move_from >= 0 and result.move_to >= 0) {
        commands.moveTab(app, @intCast(result.move_from), @intCast(result.move_to));
        revealed_document = 0;
    }
    if (selected >= 0) commands.activate(app, @intCast(selected));
    if (w.action(ui, "new-document", "", c.CUI_ICON_PLUS, false, 34, 34, 3)) _ = commands.newTab(app);
    c.kest_tooltip(ui, "New request (Ctrl N)");
    var chosen: ?usize = null;
    if (app.tabs.items.len > 1 and c.kest_menu_begin(ui, w.fmt("Tabs ({d})###open-requests", .{app.tabs.items.len}), &.{ .width = @min(520, c.cui_viewport_size(ui).x - 32), .placement = c.CUI_PLACE_BOTTOM_END }, 108, w.design.control.normal, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        c.kest_document_list_begin(ui, "open-requests-list", @min(320, c.cui_viewport_size(ui).y - 120));
        for (app.tabs.items, 0..) |t, i| {
            if (c.kest_document_menu_item(ui, documentTitle(t), w.fmt("{s}  {s}{s}", .{ t.method.text(), t.name, if (t.dirty) "  •" else "" }), app.active == i, "open-requests-list")) {
                chosen = i;
            }
        }
        c.cui_scroll_end(ui);
        c.cui_menu_end(ui);
    }
    if (chosen) |i| {
        commands.activate(app, i);
        c.cui_push_id(ui, "request-documents");
        c.kest_focus(ui, documentTitle(app.tabs.items[i]));
        c.cui_pop_id(ui);
    }
    if (w.menu(ui, "Layout###workspace-layout", 96, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        layoutMenu(ui, app);
        c.cui_menu_end(ui);
    }
    if (c.kest_dropdown_begin(ui, "Request actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (app.current()) |t| actions(ui, app, t);
        c.cui_menu_end(ui);
    }
    w.end(ui);
    w.separator(ui, "document-boundary");
    if (close) |t| commands.requestClose(app, t) else tabMenu(ui, app);
}

fn context(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    w.row(ui, .{ .id = "request-context", .height = w.px(w.design.control.small), .pad_x = w.design.space.normal, .width = w.fill });
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
    const path = c.kest_path_bar_ex(ui, "request-path", segments.items.ptr, @intCast(segments.items.len), &.{
        .icon = c.CUI_ICON_FOLDER,
        .size = c.CUI_SIZE_SM,
        .no_edit = true,
        .width = w.fill,
    });
    if (path.clicked >= 0) {
        const i: usize = @intCast(path.clicked);
        if (i < ancestors.items.len) revealNode(ui, app, ancestors.items[i]);
    }
    const paths = w.arena.allocator().alloc([]const u8, segments.items.len) catch return;
    for (segments.items, paths) |segment, *value| value.* = std.mem.span(segment);
    const full_path = std.mem.join(w.arena.allocator(), " / ", paths) catch return;
    c.kest_tooltip(ui, w.z(full_path));
}

fn layoutMenu(ui: *c.cui_ctx, app: *App) void {
    const t = app.current();
    const request_focus = if (t) |tab| tab.response_collapsed else false;
    const response_focus = if (t) |tab| tab.details_collapsed and !tab.response_collapsed else false;
    if (c.cui_menu_item_ex(ui, "Show both panes", &.{ .checked = !request_focus and !response_focus })) if (t) |tab| {
        tab.details_collapsed = false;
        tab.response_collapsed = false;
    };
    if (c.cui_menu_item_ex(ui, "Focus request", &.{ .checked = request_focus })) if (t) |tab| {
        tab.details_collapsed = false;
        tab.response_collapsed = true;
    };
    if (c.cui_menu_item_ex(ui, "Focus response", &.{ .checked = response_focus })) if (t) |tab| {
        tab.details_collapsed = true;
        tab.response_collapsed = false;
    };
    if (w.menuItem(ui, "Reset split to equal")) {
        column_ratio = 0.5;
        app.prefs.column_split = 0.5;
        app.prefs.split = 0.5;
        persist.prefsChanged(app);
    }
    c.cui_menu_separator(ui);
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

/// Shows `node` in the collection browser, opening the sidebar if needed.
fn revealNode(ui: *c.cui_ctx, app: *App, node: *@import("../core/collection.zig").Node) void {
    @import("sidebar.zig").reveal(app, node);
    app.mode = .collections;
    if (c.cui_viewport_size(ui).x < w.design.geometry.sidebar_sheet) @import("shell.zig").narrow_open = true else {
        app.prefs.sidebar_open = true;
        persist.prefsChanged(app);
    }
}

/// The saved request a tab edits, if it is still in a collection.
fn savedNode(app: *App, t: *const Tab) ?*@import("../core/collection.zig").Node {
    const link = t.link orelse return null;
    for (app.collections.items) |root| if (std.mem.eql(u8, &root.id, &link.collection)) return root.find(&link.request);
    return null;
}

/// The tab whose context menu is open, by uid: a closed tab never matches.
var menu_tab: u64 = 0;

/// Right-clicking a request tab opens its menu.
fn tabMenu(ui: *c.cui_ctx, app: *App) void {
    // The tabs' scope, as in kest_doc_tabs_ex; the menu's items are built in it.
    c.cui_push_id(ui, "request-documents");
    defer c.cui_pop_id(ui);
    for (app.tabs.items) |t| {
        if (c.kest_right_pressed(ui, c.cui_make_id(ui, documentTitle(t)))) menu_tab = t.uid;
    }
    var index: ?usize = null;
    for (app.tabs.items, 0..) |t, i| if (t.uid == menu_tab) {
        index = i;
    };
    const i = index orelse return;
    const t = app.tabs.items[i];
    if (!c.kest_context_menu_begin(ui, "tab-menu", c.cui_make_id(ui, documentTitle(t)))) return;
    const count = app.tabs.items.len;
    var close: enum { none, this, others, right } = .none;
    if (c.cui_menu_item_ex(ui, "Close", &.{ .shortcut = "Ctrl W" })) close = .this;
    if (c.cui_menu_item_ex(ui, "Close others", &.{ .disabled = count < 2 })) close = .others;
    if (c.cui_menu_item_ex(ui, "Close tabs to the right", &.{ .disabled = i + 1 >= count })) close = .right;
    c.cui_menu_separator(ui);
    if (c.cui_menu_item_ex(ui, "Save", &.{ .icon = c.CUI_ICON_SAVE, .shortcut = "Ctrl S" })) commands.save(app, t);
    if (c.cui_menu_item_ex(ui, "Duplicate", &.{ .icon = c.CUI_ICON_COPY, .shortcut = "Ctrl D" })) commands.duplicateTab(app, t);
    if (w.menuItem(ui, "Rename")) dialogs.askName(app, .{ .rename_tab = t }, t.name);
    if (w.menuItem(ui, "Copy as cURL")) {
        if (t.toRequest(w.arena.allocator()) catch null) |req| w.copy(ui, @import("../import_export/curl.zig").generate(w.arena.allocator(), req) catch "");
    }
    const node = savedNode(app, t);
    if (c.cui_menu_item_ex(ui, "Reveal in collection", &.{ .disabled = node == null })) if (node) |n| revealNode(ui, app, n);
    c.cui_context_menu_end(ui);
    switch (close) {
        .none => {},
        .this => commands.requestClose(app, t),
        .others, .right => {
            // Close from the end so earlier indexes stay valid; tabs with
            // edits stay open rather than asking once per tab.
            var kept: usize = 0;
            var k = app.tabs.items.len;
            while (k > 0) {
                k -= 1;
                const other = app.tabs.items[k];
                if (other == t or (close == .right and k <= i)) continue;
                if (!commands.closeIfSaved(app, other)) kept += 1;
            }
            if (kept > 0) app.toast(.info, "Unsaved tabs kept open", w.fmt("{d} tab{s} with unsaved changes stayed open. Close {s} to save or discard the changes.", .{ kept, if (kept == 1) "" else "s", if (kept == 1) "it" else "them" }));
        },
    }
}

// A stable ### identity keeps selection and drag state when a request is renamed.
pub fn documentTitle(t: *const Tab) [*:0]const u8 {
    return w.fmt("###request-{d}", .{t.uid});
}
