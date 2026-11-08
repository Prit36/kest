//! Regressions for the state-machine bugs in docs/state-machines.md: each
//! drives the real commands (and, for the history menu, real CUI frames)
//! through the transition that used to reach an invalid state.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const tree = @import("app/tree_ops.zig");
const col = @import("core/collection.zig");
const cs = @import("storage/collection_store.zig");
const history = @import("core/history.zig");
const sidebar = @import("ui/sidebar.zig");
const shell = @import("ui/shell.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("State machine regression at {s}:{d}\n", .{ src.file, src.line });
        return error.StateMachineRegression;
    }
}
fn isOpen(app: *App, t: *tab.Tab) bool {
    return std.mem.indexOfScalar(*tab.Tab, app.tabs.items, t) != null;
}
fn isClosed(app: *App, t: *tab.Tab) bool {
    return std.mem.indexOfScalar(*tab.Tab, app.closed_tabs.items, t) != null;
}
fn linksTo(t: *const tab.Tab, n: *col.Node) bool {
    const link = t.link orelse return false;
    return std.mem.eql(u8, &link.request, &n.id) and std.mem.eql(u8, &link.collection, &n.root().id);
}
fn tabsLinkedTo(app: *App, n: *col.Node) usize {
    var count: usize = 0;
    for (app.tabs.items) |t| {
        if (linksTo(t, n)) count += 1;
    }
    return count;
}
fn child(parent: *col.Node, name: []const u8) ?*col.Node {
    for (parent.children.items) |n| if (std.mem.eql(u8, n.name, name)) return n;
    return null;
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype) !void {
    try saveAsFromBackgroundClose(ui, app, frame);
    try reopenKeepsOneTabPerRequest(app);
    try undoRelinksTabs(app);
    try expiredEnvironmentStaysDeleted(app);
    try historyMenuFollowsItsEntry(ui, app, frame, click);
    std.debug.print("State machines: background Save as close, one tab per reopened request, draft flag on close, Undo relinks tabs, expired environment delete, history menu across retention trim passed\n", .{});
}

/// Closing a background draft and choosing "Save as..." saves that draft,
/// not the tab in front, and closes it.
fn saveAsFromBackgroundClose(ui: *c.cui_ctx, app: *App, comptime frame: anytype) !void {
    const collection = tree.newCollection(app, "State machine save as") orelse return error.AllocationFailed;
    const saved = tree.addRequest(app, collection, .{ .name = "Front request", .url = "https://example.invalid/front" }) orelse return error.AllocationFailed;
    app.store.sync();
    const draft = commands.newTab(app) orelse return error.AllocationFailed;
    draft.url.set("https://example.invalid/background-draft");
    draft.syncParamsFromUrl();
    persist.touchTab(app, draft);
    persist.flushTab(app, draft, false);
    commands.openRequest(app, saved);
    const front = app.current().?;
    try check(@src(), front != draft and linksTo(front, saved));
    for (0..2) |_| frame(ui, app);

    // The draft's tab is closed from its X or its menu while another is in front.
    commands.requestClose(app, draft);
    try check(@src(), app.modal_open and app.modal == .confirm and app.pending == .close_tab);
    // The prompt's "Save as..." button.
    app.modal_open = false;
    app.pending = .none;
    commands.saveAndClose(app, draft);
    try check(@src(), app.modal == .save_as and app.modal_open and app.current() == front);
    app.save_target = collection;
    app.save_name.set("Saved from background close");
    // The Save as dialog's primary button.
    app.modal_open = false;
    commands.acceptSaveAs(app);

    try check(@src(), !isOpen(app, draft) and isClosed(app, draft));
    try check(@src(), isOpen(app, front) and linksTo(front, saved) and std.mem.eql(u8, front.name, "Front request"));
    const copy = child(collection, "Saved from background close") orelse return error.StateMachineRegression;
    try check(@src(), linksTo(draft, copy));
    app.store.sync();
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const stored = try cs.loadRequest(app.store, ar.allocator(), &collection.id, &copy.id);
    try check(@src(), std.mem.eql(u8, stored.url, "https://example.invalid/background-draft"));
    frame(ui, app);
    try check(@src(), app.save_tab == 0 and app.close_after_save == null);
    commands.requestClose(app, front);
}

/// Reopening a closed tab whose request is open again goes to that tab
/// rather than making a second editor of the same file; closing a draft
/// clears the flag that says its file exists.
fn reopenKeepsOneTabPerRequest(app: *App) !void {
    const collection = tree.newCollection(app, "State machine reopen") orelse return error.AllocationFailed;
    const n = tree.addRequest(app, collection, .{ .name = "Reopened", .url = "https://example.invalid/reopen" }) orelse return error.AllocationFailed;
    app.store.sync();
    commands.openRequest(app, n);
    const first = app.current().?;
    commands.requestClose(app, first);
    try check(@src(), !isOpen(app, first) and isClosed(app, first));
    commands.openRequest(app, n);
    const second = app.current().?;
    try check(@src(), second != first and tabsLinkedTo(app, n) == 1);
    const open_count = app.tabs.items.len;
    commands.reopenClosed(app);
    try check(@src(), tabsLinkedTo(app, n) == 1);
    try check(@src(), app.tabs.items.len == open_count and app.current() == second);
    // The stale copy is gone, so a second Reopen can't bring it back either.
    try check(@src(), !isClosed(app, first));
    commands.requestClose(app, second);

    const draft = commands.newTab(app) orelse return error.AllocationFailed;
    draft.url.set("https://example.invalid/discarded-draft");
    draft.syncParamsFromUrl();
    persist.touchTab(app, draft);
    persist.flushTab(app, draft, false);
    try check(@src(), draft.has_draft);
    commands.requestClose(app, draft);
    try check(@src(), app.modal_open and app.pending == .close_tab);
    app.modal_open = false;
    commands.acceptPending(app); // Discard
    try check(@src(), isClosed(app, draft) and !draft.has_draft);
    commands.reopenClosed(app);
    try check(@src(), app.current() == draft);
    persist.flush(app);
    try check(@src(), draft.has_draft and draft.dirty);
    commands.closeNow(app, draft);
}

/// Undo of a delete gives the open (and recently closed) tabs of the
/// restored requests their links back.
fn undoRelinksTabs(app: *App) !void {
    tree.finishDelete(app);
    const collection = tree.newCollection(app, "State machine undo") orelse return error.AllocationFailed;
    const folder = tree.newFolder(app, collection, "Deleted folder") orelse return error.AllocationFailed;
    const kept = tree.addRequest(app, folder, .{ .name = "Open request", .url = "https://example.invalid/open" }) orelse return error.AllocationFailed;
    const shut = tree.addRequest(app, folder, .{ .name = "Closed request", .url = "https://example.invalid/closed" }) orelse return error.AllocationFailed;
    app.store.sync();
    commands.openRequest(app, shut);
    const shut_tab = app.current().?;
    commands.requestClose(app, shut_tab);
    commands.openRequest(app, kept);
    const open_tab = app.current().?;
    try check(@src(), isClosed(app, shut_tab) and linksTo(shut_tab, shut) and linksTo(open_tab, kept));

    tree.deleteNode(app, folder);
    try check(@src(), open_tab.link == null and shut_tab.link == null);
    persist.flush(app);
    tree.undoDelete(app);
    try check(@src(), folder.parent == collection);
    try check(@src(), linksTo(open_tab, kept) and linksTo(shut_tab, shut));
    persist.flush(app);
    try check(@src(), !open_tab.dirty and !open_tab.has_draft);
    // The restored request's row goes to its tab instead of opening another.
    const count = app.tabs.items.len;
    commands.openRequest(app, kept);
    try check(@src(), app.tabs.items.len == count and app.current() == open_tab);
    commands.requestClose(app, open_tab);
    try check(@src(), !isOpen(app, open_tab));
}

/// An environment delete whose Undo window ran out with no frame to finish it
/// stays deleted when a later node delete is undone.
fn expiredEnvironmentStaysDeleted(app: *App) !void {
    tree.finishDelete(app);
    const env = tree.addEnvironment(app, "State machine expired environment") orelse return error.AllocationFailed;
    const before = app.envs.items.len;
    const id = env.id;
    tree.deleteEnv(app, env);
    try check(@src(), app.envs.items.len == before - 1);
    // The window passes while the app is in the background: no frame runs.
    app.undo_until = app.nowMs() - 1;
    const collection = tree.newCollection(app, "State machine expiry") orelse return error.AllocationFailed;
    const folder = tree.newFolder(app, collection, "Deleted later") orelse return error.AllocationFailed;
    tree.deleteNode(app, folder);
    tree.undoDelete(app);
    try check(@src(), folder.parent == collection);
    try check(@src(), app.envs.items.len == before - 1);
    for (app.envs.items) |e| try check(@src(), !std.mem.eql(u8, &e.id, &id));
}

fn historyRow(ui: *c.cui_ctx, e: *const history.Entry, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, sidebar.historyRowKey(e));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn historyMenuItem(ui: *c.cui_ctx, e: *const history.Entry, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, sidebar.historyRowKey(e));
    defer c.cui_pop_id(ui);
    const menu = c.cui_make_id(ui, "history-menu") ^ 0xC7C;
    c.cui_push_id_int(ui, @bitCast(menu));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}

/// With history at its retention limit, a request that finishes while an
/// entry's menu is open trims the oldest entry and shifts every index. The
/// menu stays with the entry it was opened for: Delete removes that entry.
fn historyMenuFollowsItsEntry(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype) !void {
    const saved_history = app.history;
    app.history = .init(app.gpa);
    defer {
        app.history.deinit();
        app.history = saved_history;
    }
    const old_mode = app.mode;
    const old_sidebar = app.prefs.sidebar_open;
    const old_narrow = shell.narrow_open;
    defer {
        app.mode = old_mode;
        app.prefs.sidebar_open = old_sidebar;
        shell.narrow_open = old_narrow;
    }
    app.history.retention = 3;
    for ([_][]const u8{ "https://history.invalid/a", "https://history.invalid/b", "https://history.invalid/c" }) |url|
        try app.history.add(.{ .method = "GET", .url = url, .timestamp_ms = 0, .status = 200, .time_ms = 1 });
    app.mode = .history;
    app.prefs.sidebar_open = true;
    shell.narrow_open = false;
    app.history_query.clear();
    app.history_method = 0;
    app.history_status = 0;
    c.cui_set_viewport(ui, 1180, 800, 1);
    for (0..4) |_| frame(ui, app);

    const b = app.history.entries.items[1];
    try check(@src(), std.mem.eql(u8, b.url, "https://history.invalid/b"));
    const row = historyRow(ui, &b, "history-entry");
    try check(@src(), row.w > 0 and row.h > 0);
    c.cui_input_mouse_move(ui, row.x + row.w / 2, row.y + row.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, false);
    for (0..2) |_| frame(ui, app);
    try check(@src(), historyMenuItem(ui, &b, "Delete entry").h > 0);

    // A request in another tab finishes: the oldest entry is trimmed.
    try app.history.add(.{ .method = "GET", .url = "https://history.invalid/d", .timestamp_ms = 0, .status = 200, .time_ms = 1 });
    for (0..2) |_| frame(ui, app);
    try check(@src(), std.mem.eql(u8, app.history.entries.items[1].url, "https://history.invalid/c"));
    const delete = historyMenuItem(ui, &b, "Delete entry");
    try check(@src(), delete.w > 0 and delete.h > 0);
    click(ui, app, delete.x + delete.w / 2, delete.y + delete.h / 2);
    frame(ui, app);
    try check(@src(), app.history.indexOf(b.id) == null);
    try check(@src(), app.history.entries.items.len == 2);
    try check(@src(), std.mem.eql(u8, app.history.entries.items[0].url, "https://history.invalid/c"));
    try check(@src(), std.mem.eql(u8, app.history.entries.items[1].url, "https://history.invalid/d"));
    c.cui_input_mouse_move(ui, -100, -100);
    for (0..2) |_| frame(ui, app);
}
