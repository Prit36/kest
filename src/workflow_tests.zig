//! Regressions for the collection browser, request sections, close/save
//! safety and the command palette, using real CUI frames and the real store.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const state = @import("app/state.zig");
const App = state.App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const tree = @import("app/tree_ops.zig");
const cs = @import("storage/collection_store.zig");
const col = @import("core/collection.zig");
const request_ui = @import("ui/request.zig");
const sidebar = @import("ui/sidebar.zig");

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Workflow regression at {s}:{d}\n", .{ src.file, src.line });
        return error.WorkflowRegression;
    }
}
fn tabRect(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn rowSlot(ui: *c.cui_ctx, app: *App, n: *col.Node) c.cui_rect {
    // Tree rows scope their cells by visible row index.
    var index: usize = 0;
    for (app.treeRows(), 0..) |r, i| if (r.node == n) {
        index = i;
    };
    c.cui_push_id_int(ui, @intCast(index));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, w.z(&n.id));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, "collection-item-actions"));
}
fn isOpen(app: *App, t: *tab.Tab) bool {
    return std.mem.indexOfScalar(*tab.Tab, app.tabs.items, t) != null;
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-workflow-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

/// The centre of a visible tree row (from its reserved actions slot).
fn rowPoint(ui: *c.cui_ctx, app: *App, n: *col.Node, fraction: f32) c.cui_vec2 {
    const slot = rowSlot(ui, app, n);
    // Rows are 30px tall and centre the 28px slot.
    return .{ .x = slot.x - 90, .y = slot.y + slot.h / 2 - 15 + 30 * fraction };
}
fn press(ui: *c.cui_ctx, app: *App, comptime frame: anytype, at: c.cui_vec2) void {
    c.cui_input_mouse_move(ui, at.x, at.y);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
}
fn dragTo(ui: *c.cui_ctx, app: *App, comptime frame: anytype, at: c.cui_vec2) void {
    c.cui_input_mouse_move(ui, at.x, at.y);
    for (0..2) |_| frame(ui, app);
}
fn release(ui: *c.cui_ctx, app: *App, comptime frame: anytype) void {
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    for (0..2) |_| frame(ui, app);
    c.cui_input_mouse_move(ui, -100, -100);
    for (0..2) |_| frame(ui, app);
}
fn childIndex(n: *col.Node) usize {
    return n.indexInParent() orelse std.math.maxInt(usize);
}

fn dragChecks(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, collection: *col.Node, folder: *col.Node, first: *col.Node, second: *col.Node) !void {
    // Order: Nested folder, First request, Second request.
    try check(@src(), childIndex(folder) == 0 and childIndex(first) == 1 and childIndex(second) == 2);

    // A click that wobbles less than the threshold never moves anything.
    const start = rowPoint(ui, app, second, 0.5);
    press(ui, app, frame, start);
    dragTo(ui, app, frame, .{ .x = start.x + 2, .y = start.y - 3 });
    try check(@src(), !sidebar.dragActive());
    release(ui, app, frame);
    try check(@src(), childIndex(second) == 2 and second.parent == collection);

    // Dragging Second onto the top of First shows an insertion line there
    // and drops it before First.
    press(ui, app, frame, rowPoint(ui, app, second, 0.5));
    dragTo(ui, app, frame, rowPoint(ui, app, first, 0.6));
    dragTo(ui, app, frame, rowPoint(ui, app, first, 0.15));
    try check(@src(), sidebar.dragActive());
    const d = sidebar.dropTarget() orelse return error.WorkflowRegression;
    try check(@src(), d.target == collection and d.index == 1 and d.where == 0);
    try check(@src(), c.kest_collection_drop_shown(ui));
    try capture(ui, sw, app, snapshot, "drag-reorder");
    release(ui, app, frame);
    try check(@src(), !sidebar.dragActive() and !c.kest_collection_drop_shown(ui));
    try check(@src(), childIndex(folder) == 0 and childIndex(second) == 1 and childIndex(first) == 2);

    // The middle of a folder row drops inside it; the folder opens.
    press(ui, app, frame, rowPoint(ui, app, first, 0.5));
    dragTo(ui, app, frame, rowPoint(ui, app, folder, 0.5));
    const into = sidebar.dropTarget() orelse return error.WorkflowRegression;
    try check(@src(), into.target == folder and into.where == 1);
    try capture(ui, sw, app, snapshot, "drag-into");
    release(ui, app, frame);
    try check(@src(), first.parent == folder and folder.expanded);

    // Escape cancels a drag; releasing afterwards changes nothing.
    press(ui, app, frame, rowPoint(ui, app, second, 0.5));
    dragTo(ui, app, frame, rowPoint(ui, app, folder, 0.5));
    try check(@src(), sidebar.dragActive());
    c.cui_input_key(ui, c.CUI_KEY_ESCAPE, true, 0);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_ESCAPE, false, 0);
    frame(ui, app);
    try check(@src(), !sidebar.dragActive());
    release(ui, app, frame);
    try check(@src(), second.parent == collection);

    // Holding a drag near an edge scrolls a long tree (the shared self-test
    // workspace holds over a thousand rows), and stops away from the edge.
    {
        c.cui_set_viewport(ui, 1282, 520, 1);
        for (0..4) |_| frame(ui, app);
        const before = sidebar.treeScroll();
        // Press wherever a folder or request row sits mid-tree.
        var y: f32 = 140;
        while (y < 490) : (y += 15) {
            press(ui, app, frame, .{ .x = 150, .y = y });
            if (sidebar.pressedNode() != null) break;
            release(ui, app, frame);
        }
        const grabbed = sidebar.pressedNode() orelse return error.WorkflowRegression;
        const parent = grabbed.parent;
        const position = childIndex(grabbed);
        dragTo(ui, app, frame, .{ .x = 150, .y = y - 30 });
        // Upward when already scrolled, otherwise toward the bottom edge.
        const up = before > 100;
        dragTo(ui, app, frame, .{ .x = 150, .y = if (up) 124 else 514 });
        for (0..10) |_| frame(ui, app);
        try check(@src(), sidebar.dragActive());
        const scrolled = sidebar.treeScroll();
        try check(@src(), if (up) scrolled < before - 20 else scrolled > before + 20);
        dragTo(ui, app, frame, .{ .x = 150, .y = 300 });
        const held = sidebar.treeScroll();
        for (0..4) |_| frame(ui, app);
        try check(@src(), sidebar.treeScroll() == held);
        // Cancel so this check moves nothing.
        c.cui_input_key(ui, c.CUI_KEY_ESCAPE, true, 0);
        frame(ui, app);
        c.cui_input_key(ui, c.CUI_KEY_ESCAPE, false, 0);
        release(ui, app, frame);
        try check(@src(), grabbed.parent == parent and childIndex(grabbed) == position);
        c.cui_set_viewport(ui, 1282, 832, 1);
        sidebar.reveal(app, second);
    }
    app.rows_dirty = true;
    for (0..3) |_| frame(ui, app);

    // Invalid and no-op targets: a folder never goes inside itself or its
    // own children, and dropping right beside the dragged item does nothing.
    try check(@src(), sidebar.dropFor(folder, folder, 0.5) == null);
    try check(@src(), sidebar.dropFor(folder, first, 0.5) == null);
    try check(@src(), sidebar.dropFor(first, first, 0.2) == null);

    // Restore the original order for the checks that follow.
    tree.moveAt(app, first, collection, 1);
    try check(@src(), childIndex(folder) == 0 and childIndex(first) == 1 and childIndex(second) == 2);
    folder.expanded = false;
    app.rows_dirty = true;
    app.store.sync();
    for (0..3) |_| frame(ui, app);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const original_tabs = app.tabs;
    const original_active = app.active;
    const original_prefs = app.prefs;
    const original_selected = app.selected;
    const original_mode = app.mode;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = original_tabs;
        app.active = original_active;
        app.prefs = original_prefs;
        app.selected = original_selected;
        app.mode = original_mode;
        app.filter.clear();
        app.rows_dirty = true;
        app.modal_open = false;
        app.modal = .none;
        app.pending = .none;
        app.palette_open = false;
        c.cui_input_mouse_move(ui, -100, -100);
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    app.prefs.log_open = false;
    app.prefs.sidebar_open = true;
    app.prefs.sidebar_width = 300;
    // Autosave writes linked requests as they change; the close prompt and
    // failed-write paths need edits that are only in memory.
    app.prefs.autosave = false;
    app.mode = .collections;
    c.cui_set_viewport(ui, 1282, 832, 1);

    const collection = tree.newCollection(app, "Workflow checks") orelse return error.AllocationFailed;
    defer tree.deleteNode(app, collection);
    collection.expanded = true;
    const folder = tree.newFolder(app, collection, "Nested folder") orelse return error.AllocationFailed;
    folder.expanded = false;
    const first = tree.addRequest(app, collection, .{ .name = "First request", .method = "GET", .url = "https://example.invalid/first" }) orelse return error.AllocationFailed;
    const second = tree.addRequest(app, collection, .{ .name = "Second request", .method = "PROPFIND", .url = "https://example.invalid/second" }) orelse return error.AllocationFailed;
    _ = tree.addRequest(app, folder, .{ .name = "Inside folder", .method = "POST", .url = "https://example.invalid/inside" }) orelse return error.AllocationFailed;
    app.store.sync();
    app.rows_dirty = true;

    // Row actions: only the selected or hovered row shows its menu button,
    // while every row keeps the same reserved slot so names never shift.
    @import("ui/sidebar.zig").reveal(app, first);
    c.cui_input_mouse_move(ui, -100, -100);
    for (0..6) |_| frame(ui, app);
    try check(@src(), app.selected == first);
    try check(@src(), sidebar.rowActionsShown(first));
    try check(@src(), !sidebar.rowActionsShown(second));
    const slot = rowSlot(ui, app, second);
    try check(@src(), slot.w == 28 and slot.h == 28);
    // Hovering the other row reveals its actions too.
    c.cui_input_mouse_move(ui, slot.x - 80, slot.y + slot.h / 2);
    for (0..12) |_| frame(ui, app);
    try check(@src(), sidebar.rowActionsShown(second));
    try capture(ui, sw, app, snapshot, "sidebar-hover");
    c.cui_input_mouse_move(ui, -100, -100);
    for (0..12) |_| frame(ui, app);
    try check(@src(), !sidebar.rowActionsShown(second));

    try dragChecks(ui, app, sw, snapshot, frame, collection, folder, first, second);

    // Search: a matching folder lists its contents even when collapsed, and
    // Escape in the field clears the filter without leaving the sidebar.
    app.filter.set("nested folder");
    app.rows_dirty = true;
    for (0..3) |_| frame(ui, app);
    var found_inside = false;
    for (app.treeRows()) |r| {
        if (std.mem.eql(u8, r.node.name, "Inside folder")) found_inside = true;
    }
    try check(@src(), found_inside);
    // The matched folder name is tinted; its unmatched children are not.
    try check(@src(), sidebar.highlightedRows() == 1);
    try capture(ui, sw, app, snapshot, "sidebar-search");
    c.kest_focus(ui, "collection-filter");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), app.filter.len == 0);
    for (0..3) |_| frame(ui, app);
    try check(@src(), rowSlot(ui, app, first).w == 28);

    // Settings is a labeled request section; a custom option is marked.
    commands.openRequest(app, first);
    const t = app.current().?;
    for (0..3) |_| frame(ui, app);
    try check(@src(), tabRect(ui, t, "request-options").w == 0);
    try check(@src(), tabRect(ui, t, "toggle-details").w == 0);
    const settings_tab = tabRect(ui, t, "pane-settings");
    try check(@src(), settings_tab.w > 0);
    click(ui, app, settings_tab.x + settings_tab.w / 2, settings_tab.y + settings_tab.h / 2);
    try check(@src(), t.pane == .settings and !t.dirty);
    try check(@src(), !request_ui.customSettings(t));
    t.settings.verify_tls = false;
    try check(@src(), request_ui.customSettings(t));
    t.settings.verify_tls = true;
    // Layout > Focus response hides the editor; any section brings it back.
    t.details_collapsed = true;
    frame(ui, app);
    const params_tab = tabRect(ui, t, "pane-params");
    click(ui, app, params_tab.x + params_tab.w / 2, params_tab.y + params_tab.h / 2);
    try check(@src(), !t.details_collapsed and t.pane == .params);

    // Closing a changed saved request offers Save; Save writes and closes.
    t.url.set("https://example.invalid/first-edited");
    t.syncParamsFromUrl();
    persist.touchTab(app, t);
    commands.requestClose(app, t);
    try check(@src(), app.modal_open and app.modal == .confirm and app.pending == .close_tab);
    for (0..3) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "close-prompt");
    app.modal_open = false;
    app.pending = .none;
    frame(ui, app);
    commands.saveAndClose(app, t);
    try check(@src(), !isOpen(app, t));
    app.store.sync();
    {
        var buf: [cs.path_len]u8 = undefined;
        const text = (try app.store.read(app.gpa, cs.requestPath(&buf, &collection.id, &first.id))) orelse return error.RequestMissing;
        defer app.gpa.free(text);
        try check(@src(), std.mem.indexOf(u8, text, "first-edited") != null);
    }

    // A failed write keeps the tab open and shows it as changed again.
    commands.openRequest(app, second);
    const t2 = app.current().?;
    for (0..2) |_| frame(ui, app);
    var path_buf: [cs.path_len]u8 = undefined;
    const second_path = cs.requestPath(&path_buf, &collection.id, &second.id);
    app.store.dir.deleteFile(app.io, second_path) catch {};
    try app.store.dir.createDirPath(app.io, second_path);
    t2.url.set("https://example.invalid/second-edited");
    t2.syncParamsFromUrl();
    persist.touchTab(app, t2);
    commands.saveAndClose(app, t2);
    try check(@src(), isOpen(app, t2) and app.current() == t2);
    for (0..2) |_| frame(ui, app);
    try check(@src(), t2.dirty);
    try check(@src(), app.store.takeFailedPath() == null);
    try app.store.dir.deleteDir(app.io, second_path);
    commands.save(app, t2);
    app.store.sync();
    frame(ui, app);
    try check(@src(), !t2.dirty);
    commands.requestClose(app, t2);
    try check(@src(), !isOpen(app, t2) and !app.modal_open);

    // Save as from the close prompt closes only after the save happens;
    // dismissing Save as keeps the unsaved request open.
    const draft = commands.newTab(app) orelse return error.AllocationFailed;
    draft.url.set("https://example.invalid/draft");
    draft.syncParamsFromUrl();
    persist.touchTab(app, draft);
    persist.flushTab(app, draft, false);
    commands.saveAndClose(app, draft);
    try check(@src(), app.modal == .save_as and app.modal_open and app.close_after_save == draft);
    app.modal_open = false;
    frame(ui, app);
    try check(@src(), app.close_after_save == null and isOpen(app, draft));
    commands.saveAndClose(app, draft);
    app.save_target = collection;
    app.save_name.set("Saved from close");
    app.modal_open = false;
    // Accept exactly as the dialog's primary button does.
    tree.saveTabAs(app, draft, collection, app.save_name.text());
    if (app.close_after_save == draft) {
        app.close_after_save = null;
        if (!draft.dirty and draft.link != null) commands.closeNow(app, draft);
    }
    try check(@src(), !isOpen(app, draft));

    // The palette lists grouped actions with shortcuts and runs layout ones.
    const focus_tab = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..2) |_| frame(ui, app);
    app.palette_open = true;
    frame(ui, app);
    try capture(ui, sw, app, snapshot, "palette");
    c.cui_input_text(ui, "Focus response");
    for (0..2) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), !app.palette_open);
    try check(@src(), focus_tab.details_collapsed and !focus_tab.response_collapsed);
    std.debug.print("CUI workflows: hover-only row actions, drag reorder/into folder/Escape/threshold, folder search/Escape, Settings section, Save/Discard close, failed-write dirty state, Save as close and palette layout actions passed\n", .{});
}
