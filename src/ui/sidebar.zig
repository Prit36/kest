const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const state = @import("../app/state.zig");
const App = state.App;
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const tree = @import("../app/tree_ops.zig");
const imports = @import("../app/import_ops.zig");
const col = @import("../core/collection.zig");
const dialogs = @import("dialogs.zig");
var revealed_request: u64 = 0;
var revealed_link: col.Id = @splat(0);
var active_link: col.Id = @splat(0);
var reveal_pending = false;

pub fn reveal(app: *App, node: *col.Node) void {
    app.filter.clear();
    app.selected = node;
    var ancestor: ?*col.Node = node;
    while (ancestor) |n| : (ancestor = n.parent) n.expanded = true;
    app.rows_dirty = true;
    revealed_link = node.id;
    revealed_request = if (app.current()) |t| t.uid else 0;
    reveal_pending = true;
}

pub fn view(ui: *c.cui_ctx, app: *App) void {
    const size = c.cui_viewport_size(ui);
    w.column(ui, .{ .id = "collection-browser", .width = w.fill, .height = if (size.x < 840) w.px(@max(200, size.y - 120)) else w.fill, .bg = @import("design.zig").sidebar(app.prefs.dark), .clip = true });
    defer w.end(ui);
    w.row(ui, .{ .height = w.px(38), .pad_left = 4, .pad_right = 6, .width = w.fill });
    const titles = [_][]const u8{ "Collections", "History", "Environments" };
    if (w.menu(ui, titles[@intCast(@backingInt(app.mode))], 0, w.color(c.CUI_TOKEN_FOREGROUND))) {
        for (titles, 0..) |title, i| {
            if (c.cui_menu_item_ex(ui, w.z(title), &.{ .checked = @backingInt(app.mode) == i })) app.mode = @fromBackingInt(@intCast(i));
        }
        c.cui_menu_end(ui);
    }
    c.cui_spacer(ui);
    if (c.kest_dropdown_begin(ui, "Create", &.{ .icon = c.CUI_ICON_PLUS, .icon_only = true })) {
        if (w.menuItem(ui, "New request")) _ = commands.newTab(app);
        if (w.menuItem(ui, "New collection")) dialogs.askName(app, .new_collection, "");
        if (w.menuItem(ui, "New environment")) dialogs.askName(app, .new_env, "");
        c.cui_menu_end(ui);
    }
    if (c.kest_dropdown_begin(ui, "Collection actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (w.menuItem(ui, "Import file...")) imports.chooseFile(app);
        if (w.menuItem(ui, "Import cURL...")) {
            app.modal = .import_curl;
            app.modal_open = true;
        }
        if (w.menuItem(ui, "New collection")) dialogs.askName(app, .new_collection, "");
        c.cui_menu_end(ui);
    }
    w.end(ui);
    c.cui_separator(ui);
    switch (app.mode) {
        .collections => collections(ui, app),
        .history => history(ui, app),
        .environments => environments(ui, app),
    }
    c.cui_separator(ui);
    w.row(ui, .{ .height = w.px(34), .width = w.fill, .pad_x = 6 });
    if (w.action(ui, "browse-collections", "", c.CUI_ICON_FOLDER, app.mode == .collections, 26, 28, 3)) app.mode = .collections;
    c.cui_tooltip(ui, "Collections");
    if (w.action(ui, "browse-history", "", c.CUI_ICON_HISTORY, app.mode == .history, 26, 28, 3)) app.mode = .history;
    c.cui_tooltip(ui, "Request history");
    if (w.action(ui, "browse-environments", "", c.CUI_ICON_DATABASE, app.mode == .environments, 26, 28, 3)) app.mode = .environments;
    c.cui_tooltip(ui, "Environments");
    c.cui_spacer(ui);
    if (c.kest_dropdown_begin(ui, "Import", &.{ .icon = c.CUI_ICON_DOWNLOAD, .variant = c.CUI_BUTTON_GHOST, .placement = c.CUI_PLACE_TOP_END })) {
        if (w.menuItem(ui, "Import file...")) imports.chooseFile(app);
        if (w.menuItem(ui, "Import cURL...")) {
            app.modal = .import_curl;
            app.modal_open = true;
        }
        c.cui_menu_end(ui);
    }
    w.end(ui);
}

fn collections(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .pad_x = 10, .pad_y = 8 });
    if (w.field(ui, "collection-filter", &app.filter, .{ .placeholder = "Find a request...", .icon = c.CUI_ICON_SEARCH, .size = c.CUI_SIZE_SM })) {
        app.rows_dirty = true;
        c.kest_collection_top(ui, "collection-rows");
        if (app.filter.len == 0) revealed_request = 0;
    }
    w.end(ui);
    if (app.current()) |t| {
        const link_changed = if (t.link) |link| !std.mem.eql(u8, &active_link, &link.request) else false;
        if ((revealed_request != t.uid or link_changed) and app.filter.len == 0) {
            revealed_request = t.uid;
            if (t.link) |link| for (app.collections.items) |root| {
                if (root.find(&link.request)) |node| {
                    var ancestor = node.parent;
                    while (ancestor) |parent| : (ancestor = parent.parent) parent.expanded = true;
                    app.rows_dirty = true;
                    active_link = link.request;
                    revealed_link = link.request;
                    reveal_pending = true;
                    break;
                }
            };
        }
    }
    const rows = app.treeRows();
    if (rows.len == 0) {
        emptyState(ui, "collections-empty", if (app.filter.len > 0) "No matching requests" else "No collections yet", if (app.filter.len > 0) "Try a different search." else "Save requests together in a collection.");
        if (app.filter.len == 0 and w.button(ui, "New collection", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_SECONDARY, .icon = c.CUI_ICON_PLUS })) dialogs.askName(app, .new_collection, "");
        emptyEnd(ui);
        return;
    }
    // Project the existing filtered/expanded rows into CUI's tree model.
    // Collapsed children load from the cached collection model on the next frame.
    const allocator = w.arena.allocator();
    const nodes = allocator.alloc(c.cui_tree_node, rows.len) catch return;
    const stack = allocator.alloc(c_int, rows.len + 1) catch return;
    @memset(stack, -1);
    var cursor: c_int = -1;
    for (rows, 0..) |r, i| {
        const depth: usize = @min(r.depth, rows.len);
        const parent = if (depth > 0) stack[depth - 1] else -1;
        nodes[i] = .{ .parent = parent, .first_child = -1, .next_sibling = -1, .flags = 0 };
        if (r.node.children.items.len > 0) nodes[i].flags |= c.CUI_TREE_HAS_CHILDREN;
        if (r.node.expanded or app.filter.len > 0) nodes[i].flags |= c.CUI_TREE_OPEN;
        if (app.selected == r.node) {
            nodes[i].flags |= c.CUI_TREE_SELECTED;
            cursor = @intCast(i);
        }
        if (stack[depth] >= 0 and nodes[@intCast(stack[depth])].parent == parent)
            nodes[@intCast(stack[depth])].next_sibling = @intCast(i);
        if (parent >= 0 and nodes[@intCast(parent)].first_child < 0)
            nodes[@intCast(parent)].first_child = @intCast(i);
        stack[depth] = @intCast(i);
        if (depth + 1 < stack.len) stack[depth + 1] = -1;
        if (reveal_pending and std.mem.eql(u8, &r.node.id, &revealed_link)) {
            cursor = @intCast(i);
            app.selected = r.node;
            nodes[i].flags |= c.CUI_TREE_SELECTED;
        }
    }
    const columns = [_]c.cui_grid_column{
        // One flexible column avoids CUI caching the first frame's sidebar
        // width and assigning spare space to the actions column on resize.
        .{ .title = "Collection / request", .width = 1, .fixed = true },
    };
    c.cui_tree_table_begin_ex(ui, "collection-rows", &columns, columns.len, nodes.ptr, @intCast(nodes.len), &.{
        .height = w.fill,
        .width = w.fill,
        .row_height = 30,
        .guides = true,
        .cursor = &cursor,
    });
    c.kest_collection_style(ui, "collection-rows", @import("design.zig").sidebar(app.prefs.dark));
    while (true) {
        const index = c.cui_tree_table_row(ui);
        if (index < 0) break;
        const n = rows[@intCast(index)].node;
        const icon = if (n.kind == .request) c.CUI_ICON_FILE else if (n.kind == .collection) c.CUI_ICON_BOX else c.CUI_ICON_FOLDER;
        c.kest_collection_name(ui, w.z(n.name), if (n.kind == .request) w.z(n.method) else null, icon, w.methodColor(n.method));
        c.cui_push_id(ui, w.z(&n.id));
        if (c.cui_context_menu_begin(ui, "node-menu")) {
            nodeMenu(ui, app, n);
            c.cui_context_menu_end(ui);
        }
        w.column(ui, .{ .id = "collection-item-actions", .width = w.px(28), .height = w.px(28) });
        if (c.kest_dropdown_begin(ui, "Item actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .variant = c.CUI_BUTTON_GHOST, .placement = c.CUI_PLACE_BOTTOM_END })) {
            nodeMenu(ui, app, n);
            c.cui_menu_end(ui);
        }
        w.end(ui);
        c.cui_pop_id(ui);
    }
    const events = c.cui_tree_table_end(ui);
    reveal_pending = false;
    for (rows, nodes) |r, node| {
        if (app.filter.len == 0 and r.node.expanded != (node.flags & c.CUI_TREE_OPEN != 0)) {
            r.node.expanded = node.flags & c.CUI_TREE_OPEN != 0;
            app.rows_dirty = true;
        }
    }
    if (events.selection_changed and cursor >= 0) {
        app.selected = rows[@intCast(cursor)].node;
        if (app.selected.?.kind == .request) commands.openRequest(app, app.selected.?);
    }
    if (events.activated >= 0) commands.openRequest(app, rows[@intCast(events.activated)].node);
    if (app.rows_dirty) c.cui_request_redraw(ui);
}

fn collectionLabel(raw: ?*anyopaque, index: c_int) callconv(.c) [*c]const u8 {
    const rows: [*]const col.Row = @ptrCast(@alignCast(raw.?));
    return w.z(rows[@intCast(index)].node.name);
}

fn nodeMenu(ui: *c.cui_ctx, app: *App, n: *col.Node) void {
    if (w.menuItem(ui, "New request")) dialogs.askName(app, .{ .new_request = tree.containerOf(n) }, "");
    if (w.menuItem(ui, "New folder")) dialogs.askName(app, .{ .new_folder = tree.containerOf(n) }, "");
    if (w.menuItem(ui, "Rename")) dialogs.askName(app, .{ .rename_node = n }, n.name);
    if (w.menuItem(ui, "Description")) dialogs.askName(app, .{ .describe_node = n }, n.description);
    if (w.menuItem(ui, "Duplicate")) tree.duplicate(app, n);
    if (n.kind != .collection) {
        if (w.menuItem(ui, "Move up")) tree.reorder(app, n, -1);
        if (w.menuItem(ui, "Move down")) tree.reorder(app, n, 1);
        if (w.menuItem(ui, "Move to...")) {
            app.move_node = n;
            tree.collectTargets(app, n);
            app.modal = .move_to;
            app.modal_open = true;
        }
    }
    c.cui_menu_separator(ui);
    if (w.menuItem(ui, "Export Postman")) imports.exportCollection(app, n, .postman);
    if (w.menuItem(ui, "Export Kest")) imports.exportCollection(app, n, .native);
    if (c.cui_menu_item_ex(ui, "Delete", &.{ .danger = true })) commands.confirm(app, .{ .delete_node = n }, "Delete permanently?", n.name, "Delete");
}

fn history(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .id = "history-filters", .width = w.fill, .pad = 10, .gap = 8 });
    _ = w.field(ui, "history-filter", &app.history_query, .{ .placeholder = "Search history", .size = c.CUI_SIZE_SM });
    var method: c_int = @intCast(app.history_method orelse 0);
    var status: c_int = @intCast(app.history_status orelse 0);
    w.row(ui, .{ .gap = 6, .width = w.fill });
    _ = w.select(ui, "history-method", &.{ "Method", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }, &method, w.px(100));
    _ = w.select(ui, "history-status", &.{ "Status", "2xx", "3xx", "4xx", "5xx", "Failed" }, &status, w.fill);
    w.end(ui);
    w.end(ui);
    app.history_method = @intCast(method);
    app.history_status = @intCast(status);
    const methods = [_][]const u8{ "", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    const filter: @import("../core/history.zig").Filter = .{ .query = app.history_query.text(), .method = if (method == 0) null else methods[@intCast(method)], .status = @fromBackingInt(@intCast(status)) };
    app.history_visible.clearRetainingCapacity();
    var n = app.history.entries.items.len;
    while (n > 0) {
        n -= 1;
        if (filter.accepts(&app.history.entries.items[n])) app.history_visible.append(app.gpa, @intCast(n)) catch {};
    }
    if (app.history_visible.items.len == 0) {
        const filtered = app.history_query.len > 0 or method != 0 or status != 0;
        emptyState(ui, "history-empty", if (filtered) "No matching requests" else "No requests yet", if (filtered) "Change your search or reset the filters." else "Send a request to start your history.");
        if (filtered and w.button(ui, "Reset filters###reset-history-filters", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_OUTLINE })) {
            app.history_query.clear();
            app.history_method = 0;
            app.history_status = 0;
            c.cui_request_redraw(ui);
        }
        emptyEnd(ui);
        return;
    }
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "history-rows", @intCast(app.history_visible.items.len), 58, w.fill, &first, &last);
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const index = app.history_visible.items[i];
        const e = app.history.entries.items[index];
        c.cui_push_id_int(ui, @intCast(index));
        const clicked = c.kest_control_begin(ui, "history-entry", false, -1, 54, 0);
        w.column(ui, .{ .width = w.fill, .gap = 4, .pad_x = 4 });
        w.row(ui, .{ .width = w.fill, .gap = 8 });
        w.text(ui, e.method, .{ .width = w.px(36), .size = 10, .font = c.CUI_FONT_MONO, .nowrap = true, .color = w.methodColor(e.method) });
        w.text(ui, displayUrl(e.url), .{ .size = 12, .nowrap = true, .width = w.fill });
        w.end(ui);
        w.row(ui, .{ .width = w.fill, .gap = 6, .pad_left = 44 });
        w.text(ui, if (e.status == 0) "Failed" else w.fmt("{d}", .{e.status}), .{ .size = 11, .font = c.CUI_FONT_MEDIUM, .nowrap = true, .color = w.statusColor(e.status) });
        w.text(ui, w.fmt("{d} ms", .{e.time_ms}), .{ .size = 11, .nowrap = true, .color = w.color(c.CUI_TOKEN_TEXT_MUTED) });
        w.end(ui);
        w.end(ui);
        c.kest_item_end(ui);
        c.cui_tooltip(ui, w.z(e.url));
        if (clicked) _ = commands.openHistory(app, index);
        if (c.cui_context_menu_begin(ui, "history-menu")) {
            if (w.menuItem(ui, "Send again")) {
                if (commands.openHistory(app, index)) |t| commands.send(app, t);
            }
            if (w.menuItem(ui, "Save to collection")) {
                if (commands.openHistory(app, index)) |t| commands.beginSaveAs(app, t);
            }
            if (w.menuItem(ui, "Delete entry")) commands.deleteHistory(app, index);
            c.cui_context_menu_end(ui);
        }
        c.cui_pop_id(ui);
    }
    c.cui_virtual_list_end(ui);
    c.cui_separator(ui);
    w.row(ui, .{ .width = w.fill, .pad_left = 10, .pad_right = 6, .pad_y = 6 });
    w.muted(ui, w.fmt("{d} of {d} requests", .{ app.history_visible.items.len, app.history.entries.items.len }));
    c.cui_spacer(ui);
    if (w.button(ui, "Clear", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_GHOST, .icon = c.CUI_ICON_TRASH_2, .tooltip = "Clear request history" })) commands.confirm(app, .clear_history, "Clear history?", "Request history will be deleted.", "Clear");
    w.end(ui);
}

// History rows already show the method; drop the scheme so the host and path fit.
fn displayUrl(value: []const u8) []const u8 {
    inline for (.{ "https://", "http://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(value, scheme)) return value[scheme.len..];
    }
    return value;
}

fn environments(ui: *c.cui_ctx, app: *App) void {
    if (app.envs.items.len == 0) {
        emptyState(ui, "environments-empty", "No environments yet", "Keep base URLs and variables in an environment.");
        if (w.button(ui, "New environment", .{ .icon = c.CUI_ICON_PLUS, .size = c.CUI_SIZE_SM })) dialogs.askName(app, .new_env, "");
        emptyEnd(ui);
        return;
    }
    c.cui_scroll_begin(ui, &.{ .id = "environments", .height = w.fill, .pad = 10, .gap = 4 });
    for (app.envs.items) |e| {
        c.cui_push_id(ui, w.z(&e.id));
        const clicked = c.kest_control_begin(ui, "environment-entry", e == app.active_env, -1, 54, 0);
        c.cui_icon(ui, c.CUI_ICON_DATABASE, 15, w.color(if (e == app.active_env) c.CUI_TOKEN_ACCENT else c.CUI_TOKEN_TEXT_MUTED));
        w.column(ui, .{ .width = w.fill, .gap = 4 });
        w.text(ui, e.name, .{ .size = 12, .font = if (e == app.active_env) c.CUI_FONT_MEDIUM else c.CUI_FONT_BODY, .nowrap = true, .width = w.fill });
        w.text(ui, w.fmt("{d} variable{s}", .{ e.table.rows.items.len, if (e.table.rows.items.len == 1) "" else "s" }), .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED) });
        w.end(ui);
        if (e == app.active_env) w.text(ui, "Active", .{ .size = 11, .font = c.CUI_FONT_MEDIUM, .nowrap = true, .color = w.color(c.CUI_TOKEN_SUCCESS) });
        c.kest_item_end(ui);
        if (clicked) {
            app.editing_env = e;
            app.modal = .environment;
            app.modal_open = true;
        }
        if (c.cui_context_menu_begin(ui, "environment-menu")) {
            if (w.menuItem(ui, "Use environment")) commands.setActiveEnv(app, e);
            if (w.menuItem(ui, "Rename")) dialogs.askName(app, .{ .rename_env = e }, e.name);
            if (w.menuItem(ui, "Export Postman")) imports.exportEnvironment(app, e, .postman);
            if (w.menuItem(ui, "Export Kest")) imports.exportEnvironment(app, e, .native);
            if (w.menuItem(ui, "Delete")) commands.confirm(app, .{ .delete_env = e }, "Delete environment?", e.name, "Delete");
            c.cui_context_menu_end(ui);
        }
        c.cui_pop_id(ui);
    }
    c.cui_scroll_end(ui);
    c.cui_separator(ui);
    w.row(ui, .{ .width = w.fill, .pad_left = 10, .pad_right = 6, .pad_y = 6 });
    w.muted(ui, w.fmt("{d} environment{s}", .{ app.envs.items.len, if (app.envs.items.len == 1) "" else "s" }));
    c.cui_spacer(ui);
    if (w.button(ui, "New", .{ .icon = c.CUI_ICON_PLUS, .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_GHOST, .tooltip = "New environment" })) dialogs.askName(app, .new_env, "");
    w.end(ui);
}

// Caller may append a real action, then closes the content with emptyEnd.
// The empty view owns the remaining space; text wraps inside a fixed inset.
fn emptyState(ui: *c.cui_ctx, id: [*:0]const u8, title: []const u8, detail: []const u8) void {
    c.cui_scroll_begin(ui, &.{ .id = id, .width = w.fill, .height = w.fill });
    w.column(ui, .{ .id = w.fmt("{s}-content", .{std.mem.span(id)}), .width = w.fill, .pad_x = 14, .pad_top = 14, .pad_bottom = 10, .gap = 6 });
    w.column(ui, .{ .id = w.fmt("{s}-title", .{std.mem.span(id)}), .width = w.fill });
    w.text(ui, title, .{ .width = w.fill, .size = 13, .font = c.CUI_FONT_MEDIUM });
    w.end(ui);
    w.column(ui, .{ .id = w.fmt("{s}-detail", .{std.mem.span(id)}), .width = w.fill });
    w.text(ui, detail, .{ .width = w.fill, .size = 12, .line_height = 1.5, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
    // Close the scroll scope after its content is finished, including actions.
}
fn emptyEnd(ui: *c.cui_ctx) void {
    w.end(ui);
    c.cui_scroll_end(ui);
}
