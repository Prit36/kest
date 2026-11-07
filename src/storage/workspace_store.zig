//! The rest of the data folder: preferences and layout (`workspace.json`),
//! environments (`environments/<id>.json`), history (`history.jsonl`) and tabs
//! not yet saved anywhere (`drafts/<id>.json`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../utils/json.zig");
const col = @import("../core/collection.zig");
const environment = @import("../core/environment.zig");
const history = @import("../core/history.zig");
const Store = @import("store.zig").Store;

pub const OpenTab = struct {
    /// A tab of a saved request: where it is.
    collection: ?col.Id = null,
    request: ?col.Id = null,
    /// A tab with no home yet: its draft file. Saved tabs have one too, while
    /// autosave is off and they have unsaved edits.
    draft: ?col.Id = null,
};

/// Plain data; `open_tabs` and `active_env` live in an arena or the app.
pub const Prefs = struct {
    dark: bool = true,
    sidebar_width: f32 = 280,
    sidebar_open: bool = true,
    /// The request pane's share of the workspace's height.
    split: f32 = 0.36,
    log_open: bool = false,
    autosave: bool = true,
    retention: u32 = history.default_retention,
    active_env: ?col.Id = null,
    open_tabs: []const OpenTab = &.{},
    active_tab: usize = 0,
    window_width: f32 = 1280,
    window_height: f32 = 800,
};

fn id(s: ?[]const u8) ?col.Id {
    const v = s orelse return null;
    if (!col.validId(v)) return null;
    return v[0..16].*;
}

/// What's in the file, forgiving what's missing or absurd.
pub fn parsePrefs(a: Allocator, text: []const u8) !Prefs {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (v != .object) return error.Malformed;
    var p: Prefs = .{};
    p.dark = json.boolean(v, "dark") orelse p.dark;
    p.sidebar_open = json.boolean(v, "sidebarOpen") orelse p.sidebar_open;
    p.log_open = json.boolean(v, "logOpen") orelse p.log_open;
    p.autosave = json.boolean(v, "autosave") orelse p.autosave;
    if (json.int(v, "sidebarWidth")) |w| p.sidebar_width = std.math.clamp(@as(f32, @floatFromInt(w)), 180, 640);
    if (json.int(v, "splitPercent")) |s| p.split = std.math.clamp(@as(f32, @floatFromInt(s)) / 100, 0.1, 0.9);
    if (json.int(v, "retention")) |r| p.retention = @intCast(std.math.clamp(r, 1, 100_000));
    if (json.int(v, "windowWidth")) |w| p.window_width = std.math.clamp(@as(f32, @floatFromInt(w)), 640, 8000);
    if (json.int(v, "windowHeight")) |h| p.window_height = std.math.clamp(@as(f32, @floatFromInt(h)), 420, 8000);
    p.active_env = id(json.str(v, "activeEnvironment"));
    var tabs: std.ArrayList(OpenTab) = .empty;
    for (json.array(v, "openTabs")) |row| {
        const tab: OpenTab = .{ .collection = id(json.str(row, "collection")), .request = id(json.str(row, "request")), .draft = id(json.str(row, "draft")) };
        if (tab.draft == null and (tab.collection == null or tab.request == null)) continue;
        try tabs.append(a, tab);
    }
    p.open_tabs = tabs.items;
    if (json.int(v, "activeTab")) |i| p.active_tab = @intCast(@max(0, i));
    return p;
}

pub fn prefsJson(a: Allocator, p: Prefs) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writePrefs(&s, p) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writePrefs(s: *std.json.Stringify, p: Prefs) !void {
    try s.beginObject();
    try json.field(s, "format", "retort.workspace/1");
    try json.field(s, "dark", p.dark);
    try json.field(s, "sidebarOpen", p.sidebar_open);
    try json.field(s, "sidebarWidth", @as(i64, @intFromFloat(p.sidebar_width)));
    try json.field(s, "splitPercent", @as(i64, @intFromFloat(p.split * 100)));
    try json.field(s, "logOpen", p.log_open);
    try json.field(s, "autosave", p.autosave);
    try json.field(s, "retention", p.retention);
    try json.field(s, "windowWidth", @as(i64, @intFromFloat(p.window_width)));
    try json.field(s, "windowHeight", @as(i64, @intFromFloat(p.window_height)));
    if (p.active_env) |e| try json.field(s, "activeEnvironment", &e);
    try s.objectField("openTabs");
    try s.beginArray();
    for (p.open_tabs) |tab| {
        try s.beginObject();
        if (tab.collection) |c| try json.field(s, "collection", &c);
        if (tab.request) |r| try json.field(s, "request", &r);
        if (tab.draft) |d| try json.field(s, "draft", &d);
        try s.endObject();
    }
    try s.endArray();
    try json.field(s, "activeTab", p.active_tab);
    try s.endObject();
}

pub const path_len = 64;

pub fn envPath(buf: []u8, env_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "environments/{s}.json", .{env_id}) catch unreachable;
}

pub fn draftPath(buf: []u8, draft_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "drafts/{s}.json", .{draft_id}) catch unreachable;
}

/// A file of one folder of the data folder, with an id for a name.
pub const IdFile = struct { id: col.Id, text: []u8 };

/// Every `<id>.json` in a folder; unreadable ones are counted, left alone.
pub fn readAllIn(store: *Store, a: Allocator, folder: []const u8, out: *std.ArrayList(IdFile)) !usize {
    const dir = store.dir.openDir(store.io, folder, .{ .iterate = true }) catch return 0;
    defer dir.close(store.io);
    var skipped: usize = 0;
    var it = dir.iterate();
    while (it.next(store.io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const stem = e.name[0 .. e.name.len - 5];
        if (!col.validId(stem)) continue;
        const text = dir.readFileAlloc(store.io, e.name, a, .limited(64 * 1024 * 1024)) catch {
            skipped += 1;
            continue;
        };
        try out.append(a, .{ .id = stem[0..16].*, .text = text });
    }
    return skipped;
}

pub const history_file = "history.jsonl";

const t = std.testing;

test "preferences round trip, and forgive what's wrong" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const env = col.newId(t.io);
    const req = col.newId(t.io);
    const text = try prefsJson(a, .{ .dark = false, .sidebar_width = 333, .split = 0.6, .retention = 50, .active_env = env, .autosave = false, .open_tabs = &.{ .{ .collection = req, .request = req }, .{ .draft = env } }, .active_tab = 1 });
    const p = try parsePrefs(a, text);
    try t.expect(!p.dark);
    try t.expect(!p.autosave);
    try t.expectEqual(@as(f32, 333), p.sidebar_width);
    try t.expectEqual(@as(u32, 50), p.retention);
    try t.expectEqualStrings(&env, &p.active_env.?);
    try t.expectEqual(@as(usize, 2), p.open_tabs.len);
    try t.expectEqual(@as(usize, 1), p.active_tab);

    const odd = try parsePrefs(a, "{\"sidebarWidth\":99999,\"retention\":-4,\"activeEnvironment\":\"../x\",\"openTabs\":[{\"draft\":\"../../evil\"},{\"collection\":\"zz\"}]}");
    try t.expectEqual(@as(f32, 640), odd.sidebar_width);
    try t.expectEqual(@as(u32, 1), odd.retention);
    try t.expect(odd.active_env == null);
    try t.expectEqual(@as(usize, 0), odd.open_tabs.len);
    try t.expectError(error.Malformed, parsePrefs(a, "not json"));
}

test "reading a folder of ids skips everything else" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var s = try Store.open(t.allocator, t.io, buf[0..n]);
    defer s.close();
    const env_id = col.newId(t.io);
    var pbuf: [path_len]u8 = undefined;
    const e: environment.Environment = .{ .name = "Dev", .vars = &.{.{ .key = "k", .value = "v" }} };
    s.writeOwned(envPath(&pbuf, &env_id), try e.toJson(t.allocator));
    s.write("environments/notes.txt", "x");
    s.write("environments/bad-name.json", "{}");
    var files: std.ArrayList(IdFile) = .empty;
    try t.expectEqual(@as(usize, 0), try readAllIn(&s, a, "environments", &files));
    try t.expectEqual(@as(usize, 1), files.items.len);
    try t.expectEqualStrings(&env_id, &files.items[0].id);
    try t.expectEqual(@as(usize, 0), try readAllIn(&s, a, "missing-folder", &files));
}
