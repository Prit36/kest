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
/// The revealed row still needs scrolling into view (kept until the tree has
/// been laid out, which can be a frame after the sidebar first appears).
var scroll_pending = false;
const row_height = 30;
var actions_open: ?*col.Node = null;
/// Rows that drew their actions button in the last frame (hovered,
/// selected, menu open); at most a few at once.
var actions_shown: [4]?*col.Node = @splat(null);

/// Drag reordering in the collection tree. A press on a folder or request row
/// becomes a drag only after the pointer travels a few pixels, so ordinary
/// clicks never move anything; Escape cancels until the button is released.
pub const Drop = struct { target: *col.Node, index: usize, where: c_int };
var press: ?struct { node: *col.Node, x: f32, y: f32 } = null;
var dragging = false;
var drag_cancelled = false;
var was_down = false;
var drop: ?Drop = null;
const drag_threshold = 5;
pub fn pressedNode() ?*col.Node {
    return if (press) |p| p.node else null;
}
pub fn dragActive() bool {
    return dragging;
}
pub fn dropTarget() ?Drop {
    return drop;
}
var tree_scroll: f32 = 0;
/// The collection tree's scroll offset in the last frame (for tests).
pub fn treeScroll() f32 {
    return tree_scroll;
}

/// Where `dragged` would land when released over `row` at `fraction` of its
/// height (0 top, 1 bottom); null for a drop that is invalid or a no-op.
pub fn dropFor(dragged: *col.Node, row: *col.Node, fraction: f32) ?Drop {
    if (row == dragged or dragged.contains(row)) return null;
    const open_container = row.kind != .request and row.expanded and row.children.items.len > 0;
    const result: Drop = switch (row.kind) {
        // Collections are roots: everything dropped on one goes inside it.
        .collection => if (open_container and fraction > 0.5)
            .{ .target = row, .index = 0, .where = 2 }
        else
            .{ .target = row, .index = row.children.items.len, .where = 1 },
        .folder => if (fraction < 0.25)
            beside(row, 0)
        else if (fraction > 0.75 and open_container)
            .{ .target = row, .index = 0, .where = 2 }
        else if (fraction > 0.75)
            beside(row, 1)
        else
            .{ .target = row, .index = row.children.items.len, .where = 1 },
        .request => beside(row, if (fraction < 0.5) 0 else 1),
    };
    if (result.target.kind == .request or dragged.contains(result.target)) return null;
    if (dragged.parent == result.target) if (dragged.indexInParent()) |at| {
        if (result.index == at or result.index == at + 1) return null;
    };
    return result;
}
fn beside(row: *col.Node, after: usize) Drop {
    const parent = row.parent.?;
    const at = row.indexInParent() orelse 0;
    return .{ .target = parent, .index = at + after, .where = if (after == 0) 0 else 2 };
}

/// Rows whose names showed a tinted search match in the last frame.
var highlighted: usize = 0;
pub fn highlightedRows() usize {
    return highlighted;
}

pub fn rowActionsShown(n: *const col.Node) bool {
    for (actions_shown) |shown| if (shown == n) return true;
    return false;
}

pub fn reveal(app: *App, node: *col.Node) void {
    app.filter.clear();
    app.selected = node;
    var ancestor: ?*col.Node = node;
    while (ancestor) |n| : (ancestor = n.parent) n.expanded = true;
    app.rows_dirty = true;
    revealed_link = node.id;
    revealed_request = if (app.current()) |t| t.uid else 0;
    reveal_pending = true;
    scroll_pending = true;
}

pub fn view(ui: *c.cui_ctx, app: *App) void {
    const size = c.cui_viewport_size(ui);
    w.column(ui, .{ .id = "collection-browser", .width = w.fill, .height = if (size.x < w.design.geometry.sidebar_sheet) w.px(@max(200, size.y - 120)) else w.fill, .bg = @import("design.zig").sidebar(), .clip = true });
    defer w.end(ui);
    w.row(ui, .{ .id = "sidebar-toolbar", .height = w.px(38), .pad_left = 4, .pad_right = 6, .width = w.fill });
    const titles = [_][]const u8{ "Collections", "History", "Environments" };
    if (w.menu(ui, w.fmt("{s}###sidebar-navigation", .{titles[@intCast(@backingInt(app.mode))]}), 0, w.color(c.CUI_TOKEN_FOREGROUND))) {
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
        c.cui_menu_end(ui);
    }
    w.end(ui);
    w.separator(ui, "sidebar-toolbar-boundary");
    switch (app.mode) {
        .collections => collections(ui, app),
        .history => history(ui, app),
        .environments => environments(ui, app),
    }
}

fn collections(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .pad_x = 10, .pad_y = 8 });
    var filter_changed = w.field(ui, "collection-filter", &app.filter, .{ .placeholder = "Search requests", .icon = c.CUI_ICON_SEARCH, .size = c.CUI_SIZE_SM });
    c.cui_tooltip(ui, "Filter by request, folder or collection name (Esc clears)");
    // Escape clears an active search while the field keeps focus.
    if (app.filter.len > 0 and c.kest_focus_within(ui, "collection-filter") and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        app.filter.clear();
        filter_changed = true;
    }
    if (filter_changed) {
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
                    scroll_pending = true;
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
    var reveal_index: c_int = -1;
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
        if (scroll_pending and std.mem.eql(u8, &r.node.id, &revealed_link)) reveal_index = @intCast(i);
        if (reveal_pending and std.mem.eql(u8, &r.node.id, &revealed_link)) {
            cursor = @intCast(i);
            app.selected = r.node;
            nodes[i].flags |= c.CUI_TREE_SELECTED;
        }
    }
    // A revealed request (breadcrumb, switching tabs) is scrolled into view;
    // CUI only follows cursor changes it already knew about.
    if (scroll_pending and c.kest_collection_reveal(ui, "collection-rows", reveal_index, row_height)) scroll_pending = false;
    const columns = [_]c.cui_grid_column{
        // One flexible column avoids CUI caching the first frame's sidebar
        // width and assigning spare space to the actions column on resize.
        .{ .title = "Collection / request", .width = 1, .fixed = true },
    };
    c.cui_tree_table_begin_ex(ui, "collection-rows", &columns, columns.len, nodes.ptr, @intCast(nodes.len), &.{
        .height = w.fill,
        .width = w.fill,
        .row_height = row_height,
        .guides = true,
        .cursor = &cursor,
    });
    c.kest_collection_style(ui, "collection-rows", @import("design.zig").sidebar());
    // Row actions appear for the hovered or selected row, and stay while that
    // row's menu is open. Right-click works on every row.
    const menu_owner = actions_open;
    actions_open = null;
    actions_shown = @splat(null);
    highlighted = 0;
    const query = std.mem.trim(u8, app.filter.text(), " ");
    // Drag state: reordering is off while filtering (rows then hide parts
    // of the hierarchy) and while a dialog or popup owns the pointer.
    const mouse = c.cui_mouse_pos(ui);
    const down = c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT);
    const pressed = down and !was_down;
    was_down = down;
    const can_drag = app.filter.len == 0 and !app.modal_open and !app.palette_open and menu_owner == null;
    if (!down) {
        if (dragging and !drag_cancelled) if (press) |p| if (drop) |d| {
            tree.moveAt(app, p.node, d.target, d.index);
            app.rows_dirty = true;
        };
        press = null;
        dragging = false;
        drag_cancelled = false;
    } else if (press) |p| {
        if (!can_drag or drag_cancelled) {
            dragging = false;
        } else if (!dragging and (@abs(mouse.x - p.x) > drag_threshold or @abs(mouse.y - p.y) > drag_threshold)) {
            dragging = true;
        }
    }
    if (dragging and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        dragging = false;
        drag_cancelled = true;
    }
    drop = null;
    c.kest_collection_drop_clear();
    var shown_count: usize = 0;
    while (true) {
        const index = c.cui_tree_table_row(ui);
        if (index < 0) break;
        const n = rows[@intCast(index)].node;
        const icon = if (n.kind == .request) c.CUI_ICON_FILE else if (n.kind == .collection) c.CUI_ICON_BOX else c.CUI_ICON_FOLDER;
        // Tint the matched part of the name while searching (case-insensitive,
        // like the filter itself); method-only matches leave the name plain.
        const match: ?usize = if (query.len > 0) std.ascii.findIgnoreCase(n.name, query) else null;
        c.kest_collection_name(ui, w.z(n.name), if (n.kind == .request) w.z(n.method) else null, icon, w.methodColor(n.method), if (match) |m| @intCast(m) else -1, if (match != null) @intCast(query.len) else 0);
        if (match != null and c.kest_collection_name_marked(ui)) highlighted += 1;
        const rect = c.kest_collection_row_rect(ui);
        const over = rect.h > 0 and mouse.x >= rect.x and mouse.x < rect.x + rect.w and mouse.y >= rect.y and mouse.y < rect.y + rect.h;
        // A press on the actions button opens its menu instead of dragging.
        if (over and pressed and can_drag and n.kind != .collection and mouse.x < rect.x + rect.w - 34)
            press = .{ .node = n, .x = mouse.x, .y = mouse.y };
        if (over and dragging) if (press) |p| {
            drop = dropFor(p.node, n, (mouse.y - rect.y) / rect.h);
            if (drop) |d| c.kest_collection_drop(ui, d.where);
        };
        c.cui_tooltip(ui, if (n.kind == .request) w.fmt("{s} {s}", .{ n.method, n.name }) else w.z(n.name));
        const hot = c.kest_collection_row_hot(ui) or app.selected == n or menu_owner == n;
        c.cui_push_id(ui, w.z(&n.id));
        if (c.cui_context_menu_begin(ui, "node-menu")) {
            nodeMenu(ui, app, n);
            c.cui_context_menu_end(ui);
        }
        // The slot is reserved on every row so names never shift on hover.
        w.column(ui, .{ .id = "collection-item-actions", .width = w.px(28), .height = w.px(28) });
        if (hot and shown_count < actions_shown.len) {
            actions_shown[shown_count] = n;
            shown_count += 1;
        }
        if (hot and c.kest_dropdown_begin(ui, "Item actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .variant = c.CUI_BUTTON_GHOST, .placement = c.CUI_PLACE_BOTTOM_END })) {
            actions_open = n;
            nodeMenu(ui, app, n);
            c.cui_menu_end(ui);
        }
        w.end(ui);
        c.cui_pop_id(ui);
    }
    const events = c.cui_tree_table_end(ui);
    reveal_pending = false;
    // Autoscroll while dragging near the top or bottom edge, faster nearer it.
    if (dragging) {
        const area = c.cui_get_rect(ui, c.cui_make_id(ui, "collection-rows"));
        const edge: f32 = 32;
        const top = area.y + edge - mouse.y;
        const bottom = mouse.y - (area.y + area.h - edge);
        if (area.h > edge * 2 and mouse.x >= area.x and mouse.x < area.x + area.w) {
            if (top > 0) c.kest_collection_scroll_by(ui, "collection-rows", -@min(top, edge) / 2);
            if (bottom > 0) c.kest_collection_scroll_by(ui, "collection-rows", @min(bottom, edge) / 2);
        }
    }
    tree_scroll = c.kest_collection_scroll_y(ui, "collection-rows");
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
