//! Changes to the tree of collections and to environments. Each keeps the
//! files in step: a tree file for structure, one file per request.
const std = @import("std");
const state = @import("state.zig");
const persist = @import("persist.zig");
const commands = @import("commands.zig");
const tab_mod = @import("tab.zig");
const col = @import("../core/collection.zig");
const req = @import("../core/request.zig");
const cs = @import("../storage/collection_store.zig");
const ws = @import("../storage/workspace_store.zig");
const App = state.App;
const Node = col.Node;

pub fn newCollection(app: *App, name: []const u8) ?*Node {
    const n = col.create(app.gpa, col.newId(app.io), .collection, name, "") catch return null;
    n.expanded = true;
    app.collections.append(app.gpa, n) catch {
        col.destroy(app.gpa, n);
        return null;
    };
    persist.saveTree(app, n);
    return n;
}

/// Where something new goes when `at` is what's selected.
pub fn containerOf(n: *Node) *Node {
    return if (n.kind == .request) n.parent.? else n;
}

pub fn newFolder(app: *App, parent_in: *Node, name: []const u8) ?*Node {
    const parent = containerOf(parent_in);
    const n = col.create(app.gpa, col.newId(app.io), .folder, name, "") catch return null;
    col.append(app.gpa, parent, n) catch {
        col.destroy(app.gpa, n);
        return null;
    };
    n.expanded = true;
    parent.expanded = true;
    persist.saveTree(app, parent.root());
    return n;
}

pub fn addRequest(app: *App, parent_in: *Node, r: req.Request) ?*Node {
    const parent = containerOf(parent_in);
    const c = parent.root();
    const n = col.create(app.gpa, col.newId(app.io), .request, r.name, r.method) catch return null;
    cs.saveRequest(app.store, &c.id, &n.id, r) catch {
        col.destroy(app.gpa, n);
        return null;
    };
    col.append(app.gpa, parent, n) catch {
        col.destroy(app.gpa, n);
        return null;
    };
    parent.expanded = true;
    persist.saveTree(app, c);
    return n;
}

/// The tab has a home now.
pub fn saveTabAs(app: *App, t: *tab_mod.Tab, parent: *Node, name: []const u8) void {
    tab_mod.setOwned(app.gpa, &t.name, name) catch return;
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const r = t.toRequest(ar.allocator()) catch return;
    const n = addRequest(app, parent, r) orelse {
        app.toast(.danger, "Couldn't save", "Out of memory");
        return;
    };
    t.link = .{ .collection = n.root().id, .request = n.id };
    t.saved_hash = persist.hashOf(r.toJson(ar.allocator()) catch "");
    t.dirty = false;
    t.touched = false;
    if (t.has_draft) {
        t.has_draft = false;
        var buf: [ws.path_len]u8 = undefined;
        app.store.delete(ws.draftPath(&buf, &t.id));
    }
    app.selected = n;
    persist.prefsChanged(app);
    app.toast(.success, "Saved", name);
}

pub fn rename(app: *App, n: *Node, name: []const u8) void {
    col.setString(app.gpa, &n.name, name) catch return;
    if (n.kind == .request) {
        const c = n.root();
        if (tabOf(app, n)) |t| {
            tab_mod.setOwned(app.gpa, &t.name, name) catch return;
            persist.touchTab(app, t);
        } else {
            var ar = std.heap.ArenaAllocator.init(app.gpa);
            defer ar.deinit();
            const a = ar.allocator();
            if (cs.loadRequest(app.store, a, &c.id, &n.id)) |r_in| {
                var r = r_in;
                r.name = name;
                cs.saveRequest(app.store, &c.id, &n.id, r) catch {};
            } else |_| {}
        }
    }
    persist.saveTree(app, n.root());
}

fn tabOf(app: *const App, n: *const Node) ?*tab_mod.Tab {
    for (app.tabs.items) |t| if (t.link) |l| {
        if (std.mem.eql(u8, &l.request, &n.id)) return t;
    };
    return null;
}

/// A copy just after the original, with new files.
pub fn duplicate(app: *App, n: *Node) void {
    if (n.kind == .collection) return duplicateCollection(app, n);
    const parent = n.parent orelse return;
    const c = n.root();
    const copy = cloneInto(app, n, c, c) orelse return;
    parent.children.insert(app.gpa, n.indexInParent().? + 1, copy) catch {
        col.destroy(app.gpa, copy);
        return;
    };
    copy.parent = parent;
    // In its place first: a rename saves the tree it finds itself in.
    const named = std.fmt.allocPrint(app.gpa, "{s} copy", .{n.name}) catch "";
    defer if (named.len > 0) app.gpa.free(named);
    if (named.len > 0) rename(app, copy, named) else persist.saveTree(app, c);
    app.rows_dirty = true;
    app.selected = copy;
}

fn duplicateCollection(app: *App, n: *Node) void {
    const id = col.newId(app.io);
    const fresh = col.create(app.gpa, id, .collection, n.name, "") catch return;
    fresh.expanded = true;
    fresh.description = app.gpa.dupe(u8, n.description) catch &.{};
    for (n.children.items) |child| {
        const copy = cloneInto(app, child, n, fresh) orelse continue;
        col.append(app.gpa, fresh, copy) catch col.destroy(app.gpa, copy);
    }
    const named = std.fmt.allocPrint(app.gpa, "{s} copy", .{n.name}) catch return;
    defer app.gpa.free(named);
    col.setString(app.gpa, &fresh.name, named) catch {};
    app.collections.append(app.gpa, fresh) catch {
        col.destroy(app.gpa, fresh);
        return;
    };
    persist.saveTree(app, fresh);
}

const CopyCtx = struct { app: *App, from: *const Node, to: *const Node };

fn copyFile(ctx: CopyCtx, src: *const Node, dst: *const Node) void {
    const app = ctx.app;
    var a_buf: [cs.path_len]u8 = undefined;
    var b_buf: [cs.path_len]u8 = undefined;
    app.store.sync();
    const text = (app.store.read(app.gpa, cs.requestPath(&a_buf, &ctx.from.id, &src.id)) catch null) orelse return;
    app.store.writeOwned(cs.requestPath(&b_buf, &ctx.to.id, &dst.id), text);
}

fn cloneInto(app: *App, n: *const Node, from: *const Node, to: *const Node) ?*Node {
    return col.clone(app.gpa, app.io, n, CopyCtx{ .app = app, .from = from, .to = to }, copyFile) catch null;
}

/// One place up or down among its siblings.
pub fn reorder(app: *App, n: *Node, delta: i32) void {
    if (n.kind == .collection) return;
    if (col.reorder(n, delta)) persist.saveTree(app, n.root());
}

/// Into another folder or collection; the files follow if the collection changes.
pub fn moveTo(app: *App, n: *Node, target: *Node) void {
    moveAt(app, n, target, target.children.items.len);
}

/// Into `target` at child position `index` (counted before `n` is removed),
/// as drag reordering drops it. Dropping an item where it already is does
/// nothing and writes nothing.
pub fn moveAt(app: *App, n: *Node, target: *Node, index: usize) void {
    if (n.parent == target) if (n.indexInParent()) |at| {
        if (index == at or index == at + 1) return;
    };
    const from = n.root();
    const to = target.root();
    col.move(app.gpa, n, target, index) catch |e| {
        app.toast(.warning, "Can't move there", switch (e) {
            error.IntoItself => "A folder can't go inside itself.",
            error.BadTarget => "Only folders and collections can hold it.",
            error.OutOfMemory => "Out of memory.",
        });
        return;
    };
    target.expanded = true;
    if (from != to) {
        moveFiles(app, n, from, to);
        persist.saveTree(app, from);
    }
    persist.saveTree(app, to);
    app.selected = n;
}

fn moveFiles(app: *App, n: *const Node, from: *const Node, to: *const Node) void {
    if (n.kind == .request) {
        app.store.sync();
        var a_buf: [cs.path_len]u8 = undefined;
        var b_buf: [cs.path_len]u8 = undefined;
        const src = cs.requestPath(&a_buf, &from.id, &n.id);
        if (app.store.read(app.gpa, src) catch null) |text| {
            app.store.writeOwned(cs.requestPath(&b_buf, &to.id, &n.id), text);
            app.store.delete(src);
        }
        if (tabOf(app, n)) |t| t.link = .{ .collection = to.id, .request = n.id };
        for (app.closed_tabs.items) |t| if (t.link) |link| {
            if (std.mem.eql(u8, &link.request, &n.id)) t.link = .{ .collection = to.id, .request = n.id };
        };
    }
    for (n.children.items) |c| moveFiles(app, c, from, to);
}

pub fn finishDelete(app: *App) void {
    for (app.deleted.items) |d| {
        if (d.node.kind == .collection) cs.deleteCollection(app.store, &d.root) else cs.deleteRequests(app.store, &d.root, d.node);
        col.destroy(app.gpa, d.node);
    }
    app.deleted.clearRetainingCapacity();
    for (app.deleted_envs.items) |d| state.App.freeEnv(app.gpa, d.env);
    app.deleted_envs.clearRetainingCapacity();
}
pub fn deleteNode(app: *App, n: *Node) void {
    if (app.deleted.items.len > 0 and app.nowMs() >= app.undo_until) finishDelete(app);
    const root = n.root().id;
    const index = if (n.parent != null) n.indexInParent().? else std.mem.indexOfScalar(*Node, app.collections.items, n).?;
    app.deleted.append(app.gpa, .{ .node = n, .parent = n.parent, .root = root, .index = index }) catch return;
    closeTabsOf(app, n);
    if (app.selected) |s| if (n.contains(s)) {
        app.selected = neighbour(app, n);
    };
    app.selection.clearRetainingCapacity();
    app.selection_anchor = null;
    app.rename_action = null;
    app.tree_menu_node = null;
    app.save_target = null;
    if (n.parent) |parent| {
        col.detach(n);
        persist.saveTree(app, parent.root());
    } else {
        _ = app.collections.orderedRemove(index);
        // Hide the tree on disk immediately; request files remain for Undo.
        var buf: [cs.path_len]u8 = undefined;
        app.store.delete(cs.treePath(&buf, &root));
        _ = app.tree_hashes.remove(root);
    }
    app.rows_dirty = true;
    app.focus_tree = true;
    app.undo_until = app.nowMs() + 8000;
}
pub fn undoDelete(app: *App) void {
    var i = app.deleted.items.len;
    while (i > 0) {
        i -= 1;
        const d = app.deleted.items[i];
        if (d.parent) |parent| {
            parent.children.insert(app.gpa, @min(d.index, parent.children.items.len), d.node) catch return;
            d.node.parent = parent;
        } else app.collections.insert(app.gpa, @min(d.index, app.collections.items.len), d.node) catch return;
        persist.saveTree(app, d.node.root());
        app.selected = d.node;
        _ = app.deleted.pop();
    }
    app.rows_dirty = true;
    while (app.deleted_envs.items.len > 0) {
        const d = app.deleted_envs.items[app.deleted_envs.items.len - 1];
        app.envs.insert(app.gpa, @min(d.index, app.envs.items.len), d.env) catch return;
        persist.saveEnv(app, d.env);
        if (d.active) commands.setActiveEnv(app, d.env);
        _ = app.deleted_envs.pop();
    }
    app.undo_until = 0;
}

fn neighbour(app: *App, n: *Node) ?*Node {
    const siblings = if (n.parent) |p| p.children.items else app.collections.items;
    const i = std.mem.indexOfScalar(*Node, siblings, n) orelse return n.parent;
    if (i + 1 < siblings.len) return siblings[i + 1];
    if (i > 0) return siblings[i - 1];
    return n.parent;
}

fn closeTabsOf(app: *App, n: *const Node) void {
    for (app.closed_tabs.items) |t| if (t.link) |link| {
        if (std.mem.eql(u8, &link.request, &n.id)) t.link = null;
    };
    if (n.kind == .request) if (tabOf(app, n)) |t| {
        t.link = null;
        persist.touchTab(app, t);
    };
    for (n.children.items) |c| closeTabsOf(app, c);
}

pub fn addEnvironment(app: *App, name: []const u8) ?*state.Env {
    const e = persist.addEnv(app, col.newId(app.io), .{ .name = name }) catch return null;
    persist.saveEnv(app, e);
    return e;
}

pub fn deleteEnv(app: *App, e: *state.Env) void {
    if (app.nowMs() >= app.undo_until) finishDelete(app);
    const index = std.mem.indexOfScalar(*state.Env, app.envs.items, e) orelse return;
    app.deleted_envs.append(app.gpa, .{ .env = e, .index = index, .active = app.active_env == e }) catch return;
    app.undo_until = app.nowMs() + 8000;
    if (app.rename_action) |action| if (action == .rename_env and action.rename_env == e) {
        app.rename_action = null;
    };
    var buf: [ws.path_len]u8 = undefined;
    app.store.delete(ws.envPath(&buf, &e.id));
    if (app.active_env == e) commands.setActiveEnv(app, null);
    if (app.editing_env == e) app.editing_env = null;
    app.env_menu_env = null;
    if (std.mem.indexOfScalar(*state.Env, app.envs.items, e)) |i| _ = app.envs.orderedRemove(i);
}

pub fn renameEnv(app: *App, e: *state.Env, name: []const u8) void {
    tab_mod.setOwned(app.gpa, &e.name, name) catch return;
    persist.saveEnv(app, e);
}

/// Every folder `n` could move to, as rows for a list.
pub fn collectTargets(app: *App, n: *const Node) void {
    app.move_targets.clearRetainingCapacity();
    for (app.collections.items) |c| addTargets(app, c, n, 0);
}

fn addTargets(app: *App, at: *Node, n: *const Node, depth: u16) void {
    if (at.kind == .request or n.contains(at)) return;
    app.move_targets.append(app.gpa, .{ .node = at, .depth = depth }) catch return;
    for (at.children.items) |c| addTargets(app, c, n, depth + 1);
}
