//! Everything the app holds. The UI reads and changes this on the main thread;
//! workers only push finished jobs into `done`, under its lock.
const std = @import("std");
const ui = @import("../ui/model.zig");
const kit = @import("../ui/model.zig");
const col = @import("../core/collection.zig");
const environment = @import("../core/environment.zig");
const history_mod = @import("../core/history.zig");
const log_mod = @import("../core/log.zig");
const variables = @import("../core/variables.zig");
const transport = @import("../network/transport.zig");
const http_client = @import("../network/http_client.zig");
const Store = @import("../storage/store.zig").Store;
const ws = @import("../storage/workspace_store.zig");
const doc = @import("../import_export/doc.zig");
const Tab = @import("tab.zig").Tab;
const Table = @import("tab.zig").Table;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const SidebarMode = enum { collections, history, environments };

pub const Env = struct {
    id: col.Id,
    name: []u8,
    table: Table,
};

/// What a confirmation does when it's accepted.
pub const Pending = union(enum) {
    none,
    delete_node: *col.Node,
    delete_env: *Env,
    close_tab: *Tab,
    clear_history,
    delete_history: usize,
};

/// An import looked at and not yet accepted. All of it in `arena`.
pub const ImportPreview = struct {
    arena: std.heap.ArenaAllocator,
    format: doc.Format,
    file_name: []const u8 = "",
    document: ?doc.Doc = null,
    environment: ?environment.Environment = null,
    warnings: []const []const u8 = &.{},
    /// Requests here that an existing collection already has by name and URL.
    duplicates_inside: usize = 0,
    /// A collection of this name already exists.
    name_taken: bool = false,
    /// Null: a new collection. Otherwise, an index of `App.collections`.
    target: ?usize = null,
    target_open: bool = false,
};

pub const Modal = enum {
    none,
    /// A name: of a new or existing thing. See `name_action`.
    name,
    confirm,
    import_preview,
    import_curl,
    /// Save an unsaved tab: choose where.
    save_as,
    move_to,
    environment,
    settings,
};

pub const NameAction = union(enum) {
    new_collection,
    new_folder: *col.Node,
    new_request: *col.Node,
    rename_node: *col.Node,
    new_env,
    rename_env: *Env,
    rename_tab: *Tab,
    describe_node: *col.Node,
};

pub const Deleted = struct { node: *col.Node, parent: ?*col.Node, root: col.Id, index: usize };
pub const App = struct {
    gpa: Allocator,
    io: Io,
    store: *Store,
    client: *transport.Client,
    /// Where bodies too large for memory go while they're on show.
    tmp_dir: []const u8,
    prefs: ws.Prefs = .{},
    /// Asks for a frame from any thread. The real app's asks the window.
    wake_fn: *const fn (*App) void,
    /// Asks for `flush` in a while, once; on the main thread.
    schedule_fn: *const fn (*App, u64) void,
    read_clipboard: ?*const fn (Allocator) ?[]u8 = null,
    /// Optional host/test picker. A non-null result is owned by the caller.
    choose_upload: ?*const fn (Allocator) anyerror!?[]u8 = null,
    uploads: @import("upload_info.zig").Cache,
    response_preparation: @import("response_prepare.zig").Service,

    collections: std.ArrayList(*col.Node) = .empty,
    /// The hash of each tree as last written, to tell a change on disk.
    tree_hashes: std.AutoHashMapUnmanaged(col.Id, u64) = .empty,
    /// When each tree's file was last looked at, so an unchanged one isn't read.
    tree_mtimes: std.AutoHashMapUnmanaged(col.Id, i96) = .empty,
    rows: std.ArrayList(col.Row) = .empty,
    rows_dirty: bool = true,
    selected: ?*col.Node = null,
    selection: std.ArrayList(*col.Node) = .empty,
    selection_anchor: ?*col.Node = null,
    deleted: std.ArrayList(Deleted) = .empty,
    deleted_envs: std.ArrayList(struct { env: *Env, index: usize, active: bool }) = .empty,
    undo_until: i64 = 0,
    rename_action: ?NameAction = null,
    rename_text: ui.TextBuffer = .{},
    rename_session: u64 = 0,
    rename_field: u32 = 0,
    rename_owner: u32 = 0,
    rename_started: bool = false,
    rename_invalid: bool = false,
    envs: std.ArrayList(*Env) = .empty,
    active_env: ?*Env = null,
    /// The active environment's variables. `vars_arena` holds their strings.
    vars: []const variables.Var = &.{},
    vars_arena: std.heap.ArenaAllocator,
    vars_dirty: bool = true,
    vars_version: u64 = 0,
    history: history_mod.History,
    history_dirty: bool = false,
    log: log_mod.Log,
    activity: @import("../ui/activity.zig").Activity = .{},
    tabs: std.ArrayList(*Tab) = .empty,
    closed_tabs: std.ArrayList(*Tab) = .empty,
    active: usize = 0,
    next_tab_uid: u64 = 1,
    prefs_dirty: bool = false,
    flush_scheduled: bool = false,

    mode: SidebarMode = .collections,
    filter: ui.TextBuffer = .{},
    history_query: ui.TextBuffer = .{},
    history_method: ?usize = 0,
    history_status: ?usize = 0,
    history_visible: std.ArrayList(u32) = .empty,
    history_seen_total: u64 = 0,
    history_filter_key: u64 = 0,

    toaster: kit.Toaster,
    modal: Modal = .none,
    modal_open: bool = false,
    name_action: NameAction = .new_collection,
    name_text: ui.TextBuffer = .{},
    name_error: []const u8 = "",
    confirm_title: []const u8 = "",
    confirm_detail: []u8 = &.{},
    confirm_ok: []const u8 = "Delete",
    pending: Pending = .none,
    preview: ?*ImportPreview = null,
    curl_text: ui.TextBuffer = .{},
    move_node: ?*col.Node = null,
    move_targets: std.ArrayList(col.Row) = .empty,
    save_target: ?*col.Node = null,
    save_name: ui.TextBuffer = .{},
    /// A dirty tab whose close is waiting for Save as to finish.
    close_after_save: ?*Tab = null,
    editing_env: ?*Env = null,
    retention_text: ui.TextBuffer = .{},

    tree_menu_open: bool = false,
    tree_menu_at: ?ui.Rect = null,
    tree_menu_node: ?*col.Node = null,
    /// The tree takes keyboard focus on the next frame (after a delete).
    focus_tree: bool = false,
    history_menu_open: bool = false,
    history_menu_at: ?ui.Rect = null,
    history_menu_row: usize = 0,
    env_menu_open: bool = false,
    env_menu_at: ?ui.Rect = null,
    env_menu_env: ?*Env = null,
    tab_menu_open: bool = false,
    tab_menu_at: ?ui.Rect = null,
    tab_menu_tab: ?*Tab = null,
    workspace_menu_open: bool = false,
    workspace_menu_at: ?ui.Rect = null,

    palette_open: bool = false,
    palette_text: ui.TextBuffer = .{},
    palette_at: usize = 0,

    /// The sidebar's width this frame: the preference, fitted to the window.
    sidebar_shown: f32 = 0,
    dragging_sidebar: bool = false,
    dragging_split: bool = false,
    want_url_focus: bool = false,
    /// A bound on how much of a body we keep on show.
    memory_limit: usize = 8 * 1024 * 1024,

    done_lock: Io.Mutex = .init,
    done: std.ArrayList(*http_client.Job) = .empty,

    pub fn init(gpa: Allocator, io: Io, store: *Store, client: *transport.Client, tmp_dir: []const u8, wake_fn: *const fn (*App) void, schedule_fn: *const fn (*App, u64) void) App {
        return .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .client = client,
            .tmp_dir = tmp_dir,
            .wake_fn = wake_fn,
            .schedule_fn = schedule_fn,
            .vars_arena = .init(gpa),
            .uploads = .init(gpa, io),
            .response_preparation = .init(gpa, io),
            .history = .init(gpa),
            .log = .init(gpa),
            .toaster = .{ .gpa = gpa },
        };
    }

    /// The caller has stopped the client's jobs first.
    pub fn deinit(a: *App) void {
        a.response_preparation.deinit();
        a.uploads.deinit();
        for (a.tabs.items) |t| t.destroy();
        a.tabs.deinit(a.gpa);
        for (a.closed_tabs.items) |t| t.destroy();
        a.closed_tabs.deinit(a.gpa);
        @import("tree_ops.zig").finishDelete(a);
        a.deleted.deinit(a.gpa);
        a.deleted_envs.deinit(a.gpa);
        a.selection.deinit(a.gpa);
        a.rename_text.deinit();
        for (a.done.items) |j| j.destroy();
        a.done.deinit(a.gpa);
        for (a.collections.items) |n| col.destroy(a.gpa, n);
        a.collections.deinit(a.gpa);
        a.tree_hashes.deinit(a.gpa);
        a.tree_mtimes.deinit(a.gpa);
        a.rows.deinit(a.gpa);
        for (a.envs.items) |e| freeEnv(a.gpa, e);
        a.envs.deinit(a.gpa);
        a.vars_arena.deinit();
        a.history.deinit();
        a.history_visible.deinit(a.gpa);
        a.activity.deinit(a.gpa);
        a.log.deinit();
        a.toaster.deinit();
        a.filter.deinit();
        a.history_query.deinit();
        a.name_text.deinit();
        a.gpa.free(a.confirm_detail);
        a.curl_text.deinit();
        a.save_name.deinit();
        a.palette_text.deinit();
        a.retention_text.deinit();
        a.move_targets.deinit(a.gpa);
        if (a.preview) |p| freePreview(a.gpa, p);
    }

    pub fn freePreview(gpa: Allocator, p: *ImportPreview) void {
        p.arena.deinit();
        gpa.destroy(p);
    }

    pub fn freeEnv(gpa: Allocator, e: *Env) void {
        gpa.free(e.name);
        e.table.deinit();
        gpa.destroy(e);
    }

    pub fn wake(a: *App) void {
        a.wake_fn(a);
    }

    pub fn nowMs(a: *const App) i64 {
        return Io.Clock.real.now(a.io).toMilliseconds();
    }

    pub fn current(a: *const App) ?*Tab {
        if (a.tabs.items.len == 0) return null;
        return a.tabs.items[@min(a.active, a.tabs.items.len - 1)];
    }

    pub fn toast(a: *App, status: kit.Status, title: []const u8, message: []const u8) void {
        a.toaster.push(.{ .status = status, .title = title, .message = message, .duration = if (status == .danger or status == .warning) 8 else 3 });
    }
    /// A toast with a button (Retry, Open, Show in folder, Reopen); the
    /// shell carries out the action when it's clicked.
    pub fn toastAction(a: *App, status: kit.Status, title: []const u8, message: []const u8, action: kit.ToastAction) void {
        a.toaster.push(.{ .status = status, .title = title, .message = message, .duration = 8, .action = action });
    }

    /// The variables of the active environment, rebuilt when they change.
    pub fn activeVars(a: *App) []const variables.Var {
        if (!a.vars_dirty) return a.vars;
        a.vars_dirty = false;
        a.vars_version +%= 1;
        _ = a.vars_arena.reset(.retain_capacity);
        const e = a.active_env orelse {
            a.vars = &.{};
            return a.vars;
        };
        const al = a.vars_arena.allocator();
        var out: std.ArrayList(variables.Var) = .empty;
        for (e.table.rows.items) |r| {
            if (r.key.text().len == 0) continue;
            out.append(al, .{ .key = al.dupe(u8, r.key.text()) catch continue, .value = al.dupe(u8, r.value.text()) catch continue, .enabled = r.enabled }) catch continue;
        }
        a.vars = out.items;
        return a.vars;
    }

    /// Where a single imported request should land: what's selected, or the
    /// only collection there is; null means a new one.
    pub fn preferredTarget(a: *const App) ?usize {
        if (a.selected) |n| {
            const r = n.root();
            return std.mem.indexOfScalar(*col.Node, a.collections.items, r);
        }
        return if (a.collections.items.len == 1) 0 else null;
    }

    /// The tree's visible lines, flattened again after a filter or an edit.
    pub fn treeRows(a: *App) []const col.Row {
        if (a.rows_dirty) {
            a.rows_dirty = false;
            col.flatten(a.gpa, a.collections.items, std.mem.trim(u8, a.filter.text(), " "), &a.rows) catch {};
        }
        return a.rows.items;
    }
};
