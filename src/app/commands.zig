//! What the user can do to tabs, requests and history. Every entry point the
//! UI calls: buttons, shortcuts and the command palette all land here.
const std = @import("std");
const url_util = @import("../utils/url.zig");
const state = @import("state.zig");
const persist = @import("persist.zig");
const tab_mod = @import("tab.zig");
const req = @import("../core/request.zig");
const col = @import("../core/collection.zig");
const history = @import("../core/history.zig");
const log_mod = @import("../core/log.zig");
const http_client = @import("../network/http_client.zig");
const prepare = @import("../network/prepare.zig");
const cs = @import("../storage/collection_store.zig");
const App = state.App;
const Tab = tab_mod.Tab;
const Allocator = std.mem.Allocator;

pub fn newTab(app: *App) ?*Tab {
    if (app.tabs.items.len >= tab_mod.max_open_tabs) {
        app.toast(.warning, "Tab limit reached", "Close a request before opening another (64 tabs maximum).");
        return null;
    }
    const t = Tab.create(app.gpa, col.newId(app.io), app.next_tab_uid) catch return null;
    app.next_tab_uid += 1;
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    t.saved_hash = persist.emptyHash(ar.allocator());
    app.tabs.append(app.gpa, t) catch {
        t.destroy();
        return null;
    };
    app.active = app.tabs.items.len - 1;
    app.want_url_focus = true;
    return t;
}

pub fn ensureTab(app: *App) void {
    if (app.tabs.items.len == 0) _ = newTab(app);
}

pub fn activate(app: *App, i: usize) void {
    if (i >= app.tabs.items.len or app.active == i) return;
    app.active = i;
    persist.prefsChanged(app);
}

/// Move a document without changing which request owns the active state.
pub fn moveTab(app: *App, from: usize, to: usize) void {
    if (from >= app.tabs.items.len or to >= app.tabs.items.len or from == to) return;
    const active = app.current();
    const tab = app.tabs.orderedRemove(from);
    app.tabs.insertAssumeCapacity(to, tab);
    if (active) |t| app.active = std.mem.indexOfScalar(*Tab, app.tabs.items, t).?;
    persist.prefsChanged(app);
}

fn indexOfTab(app: *const App, t: *const Tab) ?usize {
    return std.mem.indexOfScalar(*Tab, app.tabs.items, @constCast(t));
}

/// Closes a tab, asking first if that would lose edits.
pub fn requestClose(app: *App, t: *Tab) void {
    persist.flushTab(app, t, false);
    if (t.dirty or (t.link == null and t.has_draft)) {
        var buf: [512]u8 = undefined;
        confirm(app, .{ .close_tab = t }, "Save changes?", std.fmt.bufPrint(&buf, "\"{s}\" has changes that haven't been saved. Save them before closing, or discard them.", .{t.name}) catch "This request has changes that haven't been saved.", "Discard");
        return;
    }
    closeNow(app, t);
}

/// The Save choice when closing a tab with edits: a saved request writes
/// and closes; an unsaved one asks where to save and closes once it has.
pub fn saveAndClose(app: *App, t: *Tab) void {
    if (indexOfTab(app, t) == null) return;
    if (t.link == null) {
        app.close_after_save = t;
        beginSaveAs(app, t);
        return;
    }
    const link = t.link.?;
    persist.flushTab(app, t, true);
    // Closing drops the only in-memory copy, so wait for this write to land
    // and keep the tab if it failed (the shell then reports it and marks the
    // request changed again).
    app.store.sync();
    var buf: [cs.path_len]u8 = undefined;
    if (app.store.lastFailureIs(cs.requestPath(&buf, &link.collection, &link.request))) return;
    if (!t.dirty) closeNow(app, t);
}

pub fn closeNow(app: *App, t: *Tab) void {
    const i = indexOfTab(app, t) orelse return;
    if (app.close_after_save == t) app.close_after_save = null;
    if (t.job) |j| {
        // The job finishes on its own; nothing refers to this tab after this.
        j.user_data = null;
        j.cancel();
        t.job = null;
    }
    if (t.has_draft) {
        var buf: [64]u8 = undefined;
        const ws = @import("../storage/workspace_store.zig");
        app.store.delete(ws.draftPath(&buf, &t.id));
    }
    _ = app.tabs.orderedRemove(i);
    t.destroy();
    if (app.active > i or app.active >= app.tabs.items.len) app.active -|= 1;
    persist.prefsChanged(app);
}

/// Asks before something that can't be undone.
pub fn confirm(app: *App, pending: state.Pending, title: []const u8, detail: []const u8, ok: []const u8) void {
    app.pending = pending;
    app.confirm_title = title;
    tab_mod.setOwned(app.gpa, &app.confirm_detail, detail) catch {};
    app.confirm_ok = ok;
    app.modal = .confirm;
    app.modal_open = true;
}

/// Opens a saved request, or the tab it's already in.
pub fn openRequest(app: *App, n: *col.Node) void {
    if (n.kind != .request) return;
    const c = n.root();
    for (app.tabs.items, 0..) |t, i| if (t.link) |l| {
        if (std.mem.eql(u8, &l.request, &n.id)) return activate(app, i);
    };
    if (app.tabs.items.len >= tab_mod.max_open_tabs) {
        app.toast(.warning, "Tab limit reached", "Close a request before opening another (64 tabs maximum).");
        return;
    }
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const r = cs.loadRequest(app.store, a, &c.id, &n.id) catch |e| {
        const why = switch (e) {
            error.RequestMissing => "Its file is missing.",
            error.RequestUnreadable => "Its file isn't valid. It was left as it is.",
            error.OutOfMemory => "Out of memory.",
        };
        app.toast(.danger, "Couldn't open the request", why);
        return;
    };
    const t = Tab.create(app.gpa, col.newId(app.io), app.next_tab_uid) catch return;
    app.next_tab_uid += 1;
    var named = r;
    named.name = n.name;
    t.fromRequest(named) catch {
        t.destroy();
        return;
    };
    t.link = .{ .collection = c.id, .request = n.id };
    const text = named.toJson(a) catch "";
    t.saved_hash = persist.hashOf(text);
    var buf: [cs.path_len]u8 = undefined;
    t.file_mtime = app.store.mtime(cs.requestPath(&buf, &c.id, &n.id));
    app.tabs.append(app.gpa, t) catch {
        t.destroy();
        return;
    };
    app.active = app.tabs.items.len - 1;
    persist.prefsChanged(app);
}

/// Opens a copy of `r` with no home yet (history, an import).
pub fn openUnsaved(app: *App, r: req.Request) ?*Tab {
    const t = newTab(app) orelse return null;
    t.fromRequest(r) catch return t;
    t.touched = true;
    t.dirty = true;
    persist.scheduleFlush(app);
    return t;
}

pub fn save(app: *App, t: *Tab) void {
    if (t.link == null) return beginSaveAs(app, t);
    persist.flushTab(app, t, true);
    if (t.link != null) app.toast(.success, "Saved", t.name);
}

pub fn beginSaveAs(app: *App, t: *Tab) void {
    app.save_name.set(t.name);
    app.save_name.focus();
    app.save_target = app.selected;
    app.modal = .save_as;
    app.modal_open = true;
}

/// A saved request gets its copy beside it; an unsaved one opens as a new tab.
pub fn duplicateTab(app: *App, t: *Tab) void {
    if (t.link) |l| if (persist.findCollection(app, &l.collection)) |c| if (c.find(&l.request)) |n| {
        persist.flushTab(app, t, false);
        @import("tree_ops.zig").duplicate(app, n);
        return;
    };
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var r = t.toRequest(a) catch return;
    r.name = std.fmt.allocPrint(a, "{s} copy", .{t.name}) catch r.name;
    _ = openUnsaved(app, r);
}

fn onDone(ctx: ?*anyopaque, job: *http_client.Job) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.done_lock.lockUncancelable(app.io);
    // A failed append leaks one job at the very end of memory, rather than
    // losing track of a response that a tab may still point to.
    app.done.append(app.gpa, job) catch {};
    app.done_lock.unlock(app.io);
    app.wake();
}

fn onProgress(ctx: ?*anyopaque, _: *http_client.Job) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.wake();
}

pub fn send(app: *App, t: *Tab) void {
    if (t.job != null) return;
    if (!@import("../network/header_check.zig").validMethod(std.mem.trim(u8, t.method.text(), " "))) {
        startFailed(app, t, .method, "Enter a valid HTTP method");
        logLine(app, .err, "Not sent: invalid HTTP method", .{});
        return;
    }
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const r = t.toRequest(a) catch {
        startFailed(app, t, .memory, "Not enough memory to prepare this request");
        return;
    };
    var problem: prepare.Problem = .{};
    const job = http_client.start(app.gpa, app.io, app.client, r, app.activeVars(), .{ .ctx = app, .on_done = onDone, .on_progress = onProgress }, .{ .spill_dir = app.tmp_dir, .memory_limit = app.memory_limit, .user_data = t }, a, &problem) catch |e| {
        const message: []const u8 = if (problem.message.len > 0) problem.message else @errorName(e);
        const failure: @import("../core/response_status.zig").StartFailure = switch (e) {
            error.InvalidUrl => .url,
            error.InvalidHeader => .header,
            error.OutOfMemory => .memory,
            error.ConcurrencyUnavailable => .busy,
        };
        startFailed(app, t, failure, message);
        logLine(app, .err, "Not sent: {s}", .{message});
        return;
    };
    t.job = job;
    // Keep the last immutable response readable while this job runs. The UI
    // labels it previous; only the new job supplies current progress metadata.
    discardEmptyFailure(t);
    t.start_failure = .none;
    app.gpa.free(t.start_failure_text);
    t.start_failure_text = &.{};
    t.response.error_details_open = false;
    app.gpa.free(t.unresolved_note);
    t.unresolved_note = &.{};
    if (job.unresolved.len > 0) t.unresolved_note = std.mem.join(app.gpa, ", ", job.unresolved) catch &.{};
    if (history.snapshotOf(app.gpa, r) catch null) |snap| {
        if (t.pending_snapshot) |old| app.gpa.free(old);
        t.pending_snapshot = snap;
    } else {
        if (t.pending_snapshot) |old| app.gpa.free(old);
        t.pending_snapshot = null;
    }
    const safe = log_mod.redactUrl(a, job.out.url) catch "";
    logLine(app, .info, "{s} {s}", .{ job.out.method, safe });
}

fn startFailed(app: *App, t: *Tab, failure: @import("../core/response_status.zig").StartFailure, message: []const u8) void {
    discardEmptyFailure(t);
    t.start_failure = failure;
    app.gpa.free(t.start_failure_text);
    t.start_failure_text = &.{};
    tab_mod.setOwned(app.gpa, &t.start_failure_text, message) catch {};
    t.response.error_details_open = false;
    if (t.response_collapsed) app.toast(.danger, "Not sent", message);
    app.wake();
}

fn discardEmptyFailure(t: *Tab) void {
    const old = t.shown orelse return;
    if (old.resp.status == 0 and old.resp.preview.items.len == 0) {
        old.destroy();
        t.shown = null;
        t.response.reset();
    }
}

pub fn cancel(t: *Tab) void {
    if (t.job) |j| j.cancel();
}

pub fn logLine(app: *App, level: log_mod.Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    app.log.add(app.nowMs(), level, text);
}

/// Takes in what workers finished: called at the top of every frame.
pub fn drainDone(app: *App) void {
    app.done_lock.lockUncancelable(app.io);
    defer app.done_lock.unlock(app.io);
    while (app.done.items.len > 0) {
        const job = app.done.orderedRemove(0);
        app.done_lock.unlock(app.io);
        finished(app, job);
        app.done_lock.lockUncancelable(app.io);
    }
}

fn finished(app: *App, job: *http_client.Job) void {
    // File metadata is advisory. A completed send invalidates cached checks;
    // an open file panel/inspector refreshes from its next ordinary frame.
    for (job.out.body) |part| switch (part) {
        .file => |path| app.uploads.invalidate(path),
        .bytes => {},
    };
    const t: *Tab = if (job.user_data) |u| @ptrCast(@alignCast(u)) else {
        job.destroy();
        return;
    };
    t.job = null;
    if (t.shown) |old| old.destroy();
    t.shown = job;
    t.response.reset();
    const r = &job.resp;
    r.closeSpill();
    history_add: {
        if (r.stop == .canceled and r.status == 0) break :history_add;
        app.history.add(.{
            .method = job.out.method,
            .url = job.out.url,
            .timestamp_ms = app.nowMs(),
            .status = r.status,
            .time_ms = r.time_ms,
            .snapshot = t.pending_snapshot,
        }) catch {};
        app.history_dirty = true;
        persist.scheduleFlush(app);
    }
    if (r.status != 0) {
        logLine(app, if (r.stop == .complete) .info else .warn, "{d} {s} in {d} ms, {d} bytes, {d} redirects, connection {s}", .{ r.status, r.reason, r.time_ms, r.total.load(.monotonic), r.redirects, if (r.reused_connection) "reused" else "new" });
    }
    if (r.error_text.len > 0) logLine(app, if (r.stop == .canceled) .info else if (r.stop == .timed_out) .warn else .err, "{s}", .{r.error_text});
}

pub fn clearResponse(t: *Tab) void {
    if (t.shown) |j| j.destroy();
    t.shown = null;
    t.start_failure = .none;
    t.gpa.free(t.start_failure_text);
    t.start_failure_text = &.{};
    t.response.reset();
}

/// A history entry, as a tab of its own.
pub fn openHistory(app: *App, index: usize) ?*Tab {
    const e = app.history.entries.items[index];
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var r: req.Request = .{ .method = e.method, .url = e.url };
    if (e.snapshot) |snap| if (std.json.parseFromSliceLeaky(std.json.Value, a, snap, .{}) catch null) |v| {
        r = req.Request.parse(a, v) catch r;
    };
    const t = openUnsaved(app, r) orelse return null;
    if (e.snapshot == null) app.toast(.info, "Opened without its body", "The body was too large to keep in history.");
    return t;
}

pub fn deleteHistory(app: *App, index: usize) void {
    if (index >= app.history.entries.items.len) return;
    app.history.remove(index);
    app.history_dirty = true;
    persist.scheduleFlush(app);
}

pub fn clearHistory(app: *App) void {
    app.history.clear();
    app.history_dirty = true;
    persist.scheduleFlush(app);
}

pub fn setActiveEnv(app: *App, e: ?*state.Env) void {
    app.active_env = e;
    app.vars_dirty = true;
    persist.prefsChanged(app);
}

pub fn cycleTab(app: *App, delta: i32) void {
    const n = app.tabs.items.len;
    if (n < 2) return;
    const i: i64 = @as(i64, @intCast(app.active)) + delta;
    activate(app, @intCast(@mod(i, @as(i64, @intCast(n)))));
}

/// Runs what a confirmation asked about.
pub fn acceptPending(app: *App) void {
    const tree = @import("tree_ops.zig");
    const p = app.pending;
    app.pending = .none;
    switch (p) {
        .none => {},
        .delete_node => |n| tree.deleteNode(app, n),
        .delete_env => |e| tree.deleteEnv(app, e),
        .close_tab => |t| closeNow(app, t),
        .clear_history => clearHistory(app),
        .delete_history => |i| deleteHistory(app, i),
    }
}

/// The JSON body's problem, worked out once per edit.
/// The URL rewritten as `f` sees fit; the params follow.
fn rewriteUrl(app: *App, t: *Tab, comptime f: fn (std.mem.Allocator, []const u8) anyerror![]u8) void {
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const next = f(ar.allocator(), t.url.text()) catch return;
    if (std.mem.eql(u8, next, t.url.text())) return;
    t.url.set(next);
    t.syncParamsFromUrl();
    persist.touchTab(app, t);
}

pub fn encodeUrl(app: *App, t: *Tab) void {
    rewriteUrl(app, t, url_util.encodeKeepingVars);
}

pub fn decodeUrl(app: *App, t: *Tab) void {
    rewriteUrl(app, t, url_util.decodeReadable);
}

pub fn bodyProblem(app: *App, t: *Tab) void {
    const vars = app.activeVars();
    if (t.body_problem_version == t.body.version and t.body_problem_kind == t.body_kind and t.body_problem_vars == app.vars_version) return;
    t.body_problem_version = t.body.version;
    t.body_problem_kind = t.body_kind;
    t.body_problem_vars = app.vars_version;
    t.body_problem_pending = false;
    t.body_problem_at = null;
    tab_mod.setOwned(app.gpa, &t.body_problem_text, "") catch return;
    if (t.body_kind != .json) return;
    const json = @import("../utils/json.zig");
    const variables = @import("../core/variables.zig");
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    var source = t.body.text();
    const templated = variables.nextReference(source, 0) != null;
    if (templated) {
        var missing: std.ArrayList([]const u8) = .empty;
        variables.collectUnresolved(ar.allocator(), source, vars, &missing) catch return;
        if (missing.items.len > 0) {
            t.body_problem_pending = true;
            tab_mod.setOwned(app.gpa, &t.body_problem_text, "JSON validation waits for unresolved body variables") catch {};
            return;
        }
        source = variables.resolve(ar.allocator(), source, vars) catch return;
    }
    const p = json.validate(source) orelse return;
    if (!templated) t.body_problem_at = p.offset;
    var buf: [200]u8 = undefined;
    tab_mod.setOwned(app.gpa, &t.body_problem_text, std.fmt.bufPrint(&buf, "{s}Line {d}, column {d}: {s}", .{ if (templated) "Resolved JSON: " else "", p.line, p.column, p.message }) catch p.message) catch {};
}

/// Format (`indent` 2) or minify (0) the JSON body.
pub fn formatBody(app: *App, t: *Tab, indent: usize) void {
    const json = @import("../utils/json.zig");
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const r = json.format(ar.allocator(), t.body.text(), indent) catch return;
    switch (r) {
        .problem => |p| {
            var buf: [200]u8 = undefined;
            app.toast(.warning, "Not valid JSON", std.fmt.bufPrint(&buf, "Line {d}, column {d}: {s}", .{ p.line, p.column, p.message }) catch p.message);
        },
        .ok => |text| {
            t.body.replaceAll(text);
            persist.touchTab(app, t);
        },
    }
}
