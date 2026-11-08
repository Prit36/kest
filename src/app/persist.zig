//! Loading the workspace, saving what changed, and noticing edits made to the
//! files by anyone else. All writes go through the store's background writer,
//! coalesced by a short debounce, so typing never waits on the disk.
const std = @import("std");
const state = @import("state.zig");
const tab_mod = @import("tab.zig");
const col = @import("../core/collection.zig");
const req = @import("../core/request.zig");
const environment = @import("../core/environment.zig");
const cs = @import("../storage/collection_store.zig");
const ws = @import("../storage/workspace_store.zig");
const App = state.App;
const Tab = tab_mod.Tab;
const Allocator = std.mem.Allocator;

/// How long edits wait, so a burst of typing is one write.
pub const debounce_ms = 700;
const max_restored_tabs = tab_mod.max_open_tabs;

pub fn hashOf(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6272, text);
}

/// Reads everything. What can't be read is left on disk, and reported.
pub fn load(app: *App) !void {
    const gpa = app.gpa;
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    if (app.store.read(a, "workspace.json") catch null) |text| {
        app.prefs = ws.parsePrefs(a, text) catch blk: {
            app.toast(.warning, "Preferences couldn't be read", "workspace.json isn't valid. Using defaults; the file was left as it is until the next change.");
            break :blk .{};
        };
    }
    app.history.setRetention(app.prefs.retention);

    var problems: std.ArrayList(cs.Problem) = .empty;
    defer {
        for (problems.items) |p| gpa.free(p.name);
        problems.deinit(gpa);
    }
    try cs.loadAll(app.store, gpa, &app.collections, &problems);
    for (problems.items) |p| {
        var buf: [160]u8 = undefined;
        app.toast(.warning, "A collection couldn't be opened", std.fmt.bufPrint(&buf, "{s}: {s}. The folder was left as it is.", .{ p.name, p.message }) catch p.message);
    }
    sortCollections(app);
    for (app.collections.items) |c| rememberTree(app, c);

    try loadEnvs(app, a);
    if (app.prefs.active_env) |id| for (app.envs.items) |e| {
        if (std.mem.eql(u8, &e.id, &id)) app.active_env = e;
    };

    if (app.store.read(a, ws.history_file) catch null) |text| {
        const skipped = try app.history.loadLines(text);
        if (skipped > 0) app.log.add(app.nowMs(), .warn, "Some history lines couldn't be read and were dropped");
    }
    restoreTabs(app);
}

fn sortCollections(app: *App) void {
    std.mem.sort(*col.Node, app.collections.items, {}, struct {
        fn lt(_: void, x: *col.Node, y: *col.Node) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
}

fn loadEnvs(app: *App, a: Allocator) !void {
    var files: std.ArrayList(ws.IdFile) = .empty;
    _ = try ws.readAllIn(app.store, a, "environments", &files);
    for (files.items) |f| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, f.text, .{}) catch {
            app.toast(.warning, "An environment couldn't be read", "Its file isn't valid JSON, and was left as it is.");
            continue;
        };
        const env = environment.Environment.parse(a, v) catch {
            app.toast(.warning, "An environment couldn't be read", "Its file isn't an environment, and was left as it is.");
            continue;
        };
        _ = try addEnv(app, f.id, env);
    }
    std.mem.sort(*state.Env, app.envs.items, {}, struct {
        fn lt(_: void, x: *state.Env, y: *state.Env) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
}

pub fn addEnv(app: *App, id: col.Id, env: environment.Environment) !*state.Env {
    const e = try app.gpa.create(state.Env);
    e.* = .{ .id = id, .name = try app.gpa.dupe(u8, env.name), .table = .init(app.gpa) };
    for (env.vars) |v| _ = try e.table.add(.{ .key = v.key, .value = v.value, .enabled = v.enabled });
    try app.envs.append(app.gpa, e);
    return e;
}

pub fn envAsData(a: Allocator, e: *const state.Env) !environment.Environment {
    var vars: std.ArrayList(environment.Var) = .empty;
    for (e.table.rows.items) |r| {
        if (r.key.text().len == 0) continue;
        try vars.append(a, .{ .key = try a.dupe(u8, r.key.text()), .value = try a.dupe(u8, r.value.text()), .enabled = r.enabled });
    }
    return .{ .name = try a.dupe(u8, e.name), .vars = vars.items };
}

pub fn saveEnv(app: *App, e: *const state.Env) void {
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const data = envAsData(ar.allocator(), e) catch return;
    const text = data.toJson(app.gpa) catch return;
    var buf: [ws.path_len]u8 = undefined;
    app.store.writeOwned(ws.envPath(&buf, &e.id), text);
}

fn restoreTabs(app: *App) void {
    var restored: usize = 0;
    for (app.prefs.open_tabs, 0..) |o, i| {
        if (restored == max_restored_tabs) break;
        // Parsed requests and serialized hashes are temporary. Release them
        // per tab instead of holding every large body until startup ends.
        var scratch = std.heap.ArenaAllocator.init(app.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const t = restoreTab(app, a, o) catch null orelse continue;
        app.tabs.append(app.gpa, t) catch {
            t.destroy();
            continue;
        };
        if (i == app.prefs.active_tab) app.active = restored;
        restored += 1;
    }
    if (app.active >= app.tabs.items.len) app.active = 0;
}

fn restoreTab(app: *App, a: Allocator, o: ws.OpenTab) !?*Tab {
    // Resolve missing links before allocating a tab (a null result is not an
    // error and would bypass the allocation's errdefer).
    const collection = if (o.collection) |id| findCollection(app, &id) else null;
    const node = if (o.collection != null and o.request != null)
        (collection orelse return null).find(&o.request.?) orelse return null
    else
        null;
    const id = o.draft orelse col.newId(app.io);
    const t = try Tab.create(app.gpa, id, app.next_tab_uid);
    app.next_tab_uid += 1;
    t.pinned = o.pinned;
    errdefer t.destroy();
    // Apply after both saved and draft loads, including fallback returns.
    defer if (o.request_pane) |pane| {
        t.pane = pane;
        t.pane_chosen = true;
    };
    var saved_text: ?[]const u8 = null;
    if (o.collection != null and o.request != null) {
        const c = collection.?;
        const n = node.?;
        const r = try cs.loadRequest(app.store, a, &c.id, &n.id);
        try t.fromRequest(r);
        t.link = .{ .collection = c.id, .request = n.id };
        saved_text = try r.toJson(a);
        t.saved_hash = hashOf(saved_text.?);
        var pbuf: [cs.path_len]u8 = undefined;
        t.file_mtime = app.store.mtime(cs.requestPath(&pbuf, &c.id, &n.id));
    }
    if (o.draft) |d| {
        var buf: [ws.path_len]u8 = undefined;
        const path = ws.draftPath(&buf, &d);
        const text = (app.store.read(a, path) catch null) orelse return if (t.link != null) t else error.NoDraft;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return if (t.link != null) t else error.NoDraft;
        const r = req.Request.parse(a, v) catch return if (t.link != null) t else error.NoDraft;
        try t.fromRequest(r);
        t.has_draft = true;
        t.dirty = true;
        if (t.link == null) t.saved_hash = emptyHash(a);
    } else if (t.link == null) {
        t.saved_hash = emptyHash(a);
    }
    return t;
}

/// A new tab's hash: closing one left untouched asks nothing.
pub fn emptyHash(a: Allocator) u64 {
    const r: req.Request = .{};
    const text = r.toJson(a) catch return 0;
    defer a.free(text);
    return hashOf(text);
}

pub fn findCollection(app: *App, id: []const u8) ?*col.Node {
    for (app.collections.items) |c| if (std.mem.eql(u8, &c.id, id)) return c;
    return null;
}

fn rememberTree(app: *App, c: *const col.Node) void {
    const text = cs.treeJson(app.gpa, c) catch return;
    defer app.gpa.free(text);
    app.tree_hashes.put(app.gpa, c.id, hashOf(text)) catch {};
}

/// The tree changed: to disk, and to the sidebar.
pub fn saveTree(app: *App, c: *const col.Node) void {
    const text = cs.treeJson(app.gpa, c) catch {
        app.toast(.danger, "Couldn't save", "Out of memory");
        return;
    };
    app.tree_hashes.put(app.gpa, c.id, hashOf(text)) catch {};
    var buf: [cs.path_len]u8 = undefined;
    app.store.writeOwned(cs.treePath(&buf, &c.id), text);
    app.rows_dirty = true;
}

/// Something changed: save it soon.
pub fn scheduleFlush(app: *App) void {
    if (app.flush_scheduled) return;
    app.flush_scheduled = true;
    app.schedule_fn(app, debounce_ms);
}

pub fn touchTab(app: *App, t: *Tab) void {
    t.touched = true;
    t.dirty = true;
    scheduleFlush(app);
}

pub fn prefsChanged(app: *App) void {
    app.prefs_dirty = true;
    scheduleFlush(app);
}

/// Saves everything pending.
pub fn flush(app: *App) void {
    app.flush_scheduled = false;
    for (app.tabs.items) |t| flushTab(app, t, false);
    if (app.history_dirty) {
        app.history_dirty = false;
        if (app.history.toLines(app.gpa)) |text| {
            app.store.writeOwned(ws.history_file, text);
        } else |_| {}
    }
    if (app.prefs_dirty) {
        app.prefs_dirty = false;
        savePrefs(app);
    }
    if (app.store.takeFailure()) |text| {
        defer app.gpa.free(text);
        app.toast(.danger, "Saving failed", text);
        app.log.add(app.nowMs(), .err, text);
    }
}

pub fn flushTab(app: *App, t: *Tab, force: bool) void {
    if (!t.touched and !force) return;
    t.touched = false;
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const r = t.toRequest(a) catch return;
    const text = r.toJson(a) catch return;
    const h = hashOf(text);
    if (t.link) |link| if (force or app.prefs.autosave) {
        if (h != t.saved_hash or force) writeLinked(app, t, link, text, h, r);
        t.dirty = false;
        dropDraft(app, t);
        return;
    };
    t.dirty = h != t.saved_hash;
    if (t.dirty) {
        var buf: [ws.path_len]u8 = undefined;
        app.store.write(ws.draftPath(&buf, &t.id), text);
        if (!t.has_draft) {
            t.has_draft = true;
            app.prefs_dirty = true;
        }
    } else dropDraft(app, t);
}

fn writeLinked(app: *App, t: *Tab, link: tab_mod.Link, text: []const u8, h: u64, r: req.Request) void {
    var buf: [cs.path_len]u8 = undefined;
    const path = cs.requestPath(&buf, &link.collection, &link.request);
    app.store.write(path, text);
    t.saved_hash = h;
    // The file's time changes when the write lands: until the next look,
    // its hash says it's ours.
    t.file_mtime = null;
    // The tree shows the method and name.
    const c = findCollection(app, &link.collection) orelse return;
    const n = c.find(&link.request) orelse return;
    if (!std.mem.eql(u8, n.method, r.method) or !std.mem.eql(u8, n.name, r.name)) {
        col.setString(app.gpa, &n.method, r.method) catch return;
        col.setString(app.gpa, &n.name, r.name) catch return;
        saveTree(app, c);
    }
}

fn dropDraft(app: *App, t: *Tab) void {
    if (!t.has_draft) return;
    t.has_draft = false;
    var buf: [ws.path_len]u8 = undefined;
    app.store.delete(ws.draftPath(&buf, &t.id));
    app.prefs_dirty = true;
}

pub fn savePrefs(app: *App) void {
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var open: std.ArrayList(ws.OpenTab) = .empty;
    var active: usize = 0;
    for (app.tabs.items, 0..) |t, i| {
        var o: ws.OpenTab = .{ .request_pane = t.pane, .pinned = t.pinned };
        if (t.link) |l| {
            o.collection = l.collection;
            o.request = l.request;
        }
        if (t.has_draft) o.draft = t.id;
        // A blank tab with nothing in it isn't worth bringing back.
        if (o.collection == null and o.draft == null) continue;
        if (i <= app.active) active = open.items.len;
        open.append(a, o) catch return;
    }
    var p = app.prefs;
    p.open_tabs = open.items;
    p.active_tab = active;
    p.active_env = if (app.active_env) |e| e.id else null;
    const text = ws.prefsJson(app.gpa, p) catch return;
    app.store.writeOwned("workspace.json", text);
}

/// The app came to the front: has anyone edited our files? Looks at times
/// first, so a large workspace costs a stat per open thing, and reads only
/// what moved. Nothing watches between activations; nothing polls.
pub fn refreshFromDisk(app: *App) void {
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    app.store.sync();
    refreshTrees(app, a);
    for (app.tabs.items) |t| refreshTab(app, t, a);
}

fn refreshTrees(app: *App, a: Allocator) void {
    // A dialog or a menu may be holding a node: this can wait for next time.
    if (app.modal_open or app.tree_menu_open) return;
    var i: usize = 0;
    while (i < app.collections.items.len) : (i += 1) {
        const c = app.collections.items[i];
        var buf: [cs.path_len]u8 = undefined;
        const path = cs.treePath(&buf, &c.id);
        const m = app.store.mtime(path) orelse continue;
        const seen = app.tree_mtimes.getOrPut(app.gpa, c.id) catch continue;
        if (seen.found_existing and seen.value_ptr.* == m) continue;
        seen.value_ptr.* = m;
        const text = (app.store.read(a, path) catch continue) orelse continue;
        const h = hashOf(text);
        if (app.tree_hashes.get(c.id) == h) continue;
        const fresh = cs.parseTree(app.gpa, text) catch {
            app.toast(.warning, "A collection changed on disk", "Its file isn't valid now. Keeping what's in memory; nothing was overwritten.");
            app.tree_hashes.put(app.gpa, c.id, h) catch {};
            continue;
        };
        fresh.id = c.id;
        app.collections.items[i] = fresh;
        if (app.selected) |s| if (c.contains(s)) {
            app.selected = null;
        };
        app.selection.clearRetainingCapacity();
        app.selection_anchor = null;
        app.rename_action = null;
        // Undo records can reference parents in the tree being replaced.
        @import("tree_ops.zig").finishDelete(app);
        col.destroy(app.gpa, c);
        app.tree_hashes.put(app.gpa, fresh.id, h) catch {};
        app.rows_dirty = true;
        var msg: [200]u8 = undefined;
        app.toast(.info, "Reloaded from disk", std.fmt.bufPrint(&msg, "\"{s}\" was changed by another program.", .{fresh.name}) catch "A collection was changed by another program.");
    }
}

fn refreshTab(app: *App, t: *Tab, a: Allocator) void {
    const link = t.link orelse return;
    var buf: [cs.path_len]u8 = undefined;
    const path = cs.requestPath(&buf, &link.collection, &link.request);
    const m = app.store.mtime(path) orelse return;
    if (t.file_mtime == m) return;
    defer t.file_mtime = m;
    const text = (app.store.read(a, path) catch return) orelse return;
    const h = hashOf(text);
    if (h == t.saved_hash) return;
    if (t.dirty or t.touched) {
        app.toast(.warning, "Changed on disk", "This request's file was edited elsewhere while you have unsaved changes here. Saving will overwrite it.");
        return;
    }
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return;
    const r = req.Request.parse(a, v) catch return;
    const pane = t.pane;
    const pane_chosen = t.pane_chosen;
    t.fromRequest(r) catch return;
    t.pane = pane;
    t.pane_chosen = pane_chosen;
    t.saved_hash = h;
    app.toast(.info, "Reloaded from disk", "A request's file was changed by another program.");
}

/// A background write of `path` failed. A linked request saved to that file is
/// no longer clean: show it as changed so the edits are not taken as saved.
pub fn writeFailed(app: *App, path: []const u8) void {
    for (app.tabs.items) |t| {
        const link = t.link orelse continue;
        var buf: [cs.path_len]u8 = undefined;
        if (!std.mem.eql(u8, cs.requestPath(&buf, &link.collection, &link.request), path)) continue;
        t.dirty = true;
        // No hash matches, so the next save writes again. Not "touched":
        // autosave would otherwise retry a failing disk on every debounce.
        t.saved_hash = 0;
    }
}
