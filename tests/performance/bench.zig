//! What a large workspace and a large response cost, below the UI.
//!   zig build bench -Doptimize=ReleaseFast
//! Works only on loopback and in a folder under .zig-cache, which it removes.
const std = @import("std");
const builtin = @import("builtin");
const lib = @import("kest");
const Server = @import("test_server").Server;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const col = lib.collection;
const cs = lib.collection_store;
const Store = lib.store.Store;

/// Counts what passes through it: calls, bytes live now, the most ever live.
const Counting = struct {
    parent: Allocator,
    calls: std.atomic.Value(u64) = .init(0),
    live: std.atomic.Value(u64) = .init(0),
    peak: std.atomic.Value(u64) = .init(0),

    fn allocator(s: *Counting) Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(s: *Counting, n: usize) void {
        const now = s.live.fetchAdd(n, .monotonic) + n;
        _ = s.peak.fetchMax(now, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        const p = s.parent.rawAlloc(len, al, ra) orelse return null;
        _ = s.calls.fetchAdd(1, .monotonic);
        s.grew(len);
        return p;
    }

    fn resized(s: *Counting, old: usize, new: usize) void {
        if (new > old) s.grew(new - old) else _ = s.live.fetchSub(old - new, .monotonic);
    }

    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, new: usize, ra: usize) bool {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        if (!s.parent.rawResize(m, al, new, ra)) return false;
        s.resized(m.len, new);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        const p = s.parent.rawRemap(m, al, new, ra) orelse return null;
        s.resized(m.len, new);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const s: *Counting = @ptrCast(@alignCast(ctx));
        s.parent.rawFree(m, al, ra);
        _ = s.live.fetchSub(m.len, .monotonic);
    }

    /// The peak from here on, and the calls.
    fn mark(s: *Counting) void {
        s.peak.store(s.live.load(.monotonic), .monotonic);
        s.calls.store(0, .monotonic);
    }
};

const Clock = struct {
    io: Io,
    start: Io.Clock.Timestamp,
    fn begin(io: Io) Clock {
        return .{ .io = io, .start = Io.Clock.Timestamp.now(io, .awake) };
    }
    fn ms(c: Clock) f64 {
        const d = c.start.untilNow(c.io);
        return @as(f64, @floatFromInt(d.raw.toNanoseconds())) / 1e6;
    }
};

fn mib(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (1024 * 1024);
}

fn line(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const Done = struct {
    ev: Io.Event = .unset,
    io: Io,
    fn onDone(ctx: ?*anyopaque, _: *lib.http_client.Job) void {
        const d: *Done = @ptrCast(@alignCast(ctx.?));
        d.ev.set(d.io);
    }
};

fn collection(gpa: Allocator, count: *Counting, io: Io, dir: []const u8) !void {
    line("\n## A collection of 10,000 requests", .{});
    var store = try Store.open(gpa, io, dir);
    defer store.close();
    try store.startWriter();
    const root = try col.create(gpa, col.newId(io), .collection, "Big", "");
    var buf: [64]u8 = undefined;
    var t = Clock.begin(io);
    count.mark();
    for (0..100) |f| {
        const folder = try col.create(gpa, col.newId(io), .folder, try std.fmt.bufPrint(&buf, "Folder {d}", .{f}), "");
        try col.append(gpa, root, folder);
        for (0..100) |r| {
            const n = try col.create(gpa, col.newId(io), .request, try std.fmt.bufPrint(&buf, "Request {d}-{d}", .{ f, r }), "GET");
            try col.append(gpa, folder, n);
        }
    }
    line("build in memory        {d:>9.1} ms  {d:>7.2} MiB  {d} allocations", .{ t.ms(), mib(count.peak.load(.monotonic)), count.calls.load(.monotonic) });

    var rows: std.ArrayList(col.Row) = .empty;
    defer rows.deinit(gpa);
    root.expanded = true;
    t = Clock.begin(io);
    try col.flatten(gpa, &.{root}, "", &rows);
    line("flatten, top level     {d:>9.3} ms  {d} rows", .{ t.ms(), rows.items.len });
    for (root.children.items) |f| f.expanded = true;
    t = Clock.begin(io);
    try col.flatten(gpa, &.{root}, "", &rows);
    line("flatten, all open      {d:>9.3} ms  {d} rows", .{ t.ms(), rows.items.len });
    t = Clock.begin(io);
    try col.flatten(gpa, &.{root}, "request 42-7", &rows);
    line("filter by name         {d:>9.3} ms  {d} rows", .{ t.ms(), rows.items.len });

    t = Clock.begin(io);
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const text = try cs.treeJson(ar.allocator(), root);
    line("tree to JSON           {d:>9.1} ms  {d:>7.2} MiB of JSON", .{ t.ms(), mib(text.len) });
    count.mark();
    var held = count.live.load(.monotonic);
    t = Clock.begin(io);
    const parsed = try cs.parseTree(gpa, text);
    line("tree from JSON         {d:>9.1} ms  {d:>7.2} MiB  {d} allocations", .{ t.ms(), mib(count.live.load(.monotonic) - held), count.calls.load(.monotonic) });
    col.destroy(gpa, parsed);

    t = Clock.begin(io);
    try cs.saveTree(&store, root);
    for (root.children.items) |f| for (f.children.items) |n| {
        try cs.saveRequest(&store, &root.id, &n.id, .{ .name = n.name, .method = "GET", .url = "https://api.example.com/v1/things?page=1" });
    };
    store.sync();
    const write_ms = t.ms();
    line("write 10,000 files     {d:>9.1} ms  ({d:.2} ms each, atomically)", .{ write_ms, write_ms / 10000 });

    var loaded: std.ArrayList(*col.Node) = .empty;
    var problems: std.ArrayList(cs.Problem) = .empty;
    held = count.live.load(.monotonic);
    t = Clock.begin(io);
    try cs.loadAll(&store, gpa, &loaded, &problems);
    line("open the workspace     {d:>9.1} ms  {d:>7.2} MiB held  (the tree only: requests load when opened)", .{ t.ms(), mib(count.live.load(.monotonic) - held) });
    const c = loaded.items[0];
    t = Clock.begin(io);
    var ar2 = std.heap.ArenaAllocator.init(gpa);
    defer ar2.deinit();
    _ = try cs.loadRequest(&store, ar2.allocator(), &c.id, &c.children.items[50].children.items[50].id);
    line("open one request       {d:>9.3} ms", .{t.ms()});
    for (loaded.items) |n| col.destroy(gpa, n);
    loaded.deinit(gpa);
    problems.deinit(gpa);
    col.destroy(gpa, root);
}

fn bigJson(a: Allocator, target: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, target + 256);
    out.appendAssumeCapacity('[');
    var i: usize = 0;
    while (out.items.len < target) : (i += 1) {
        if (i > 0) out.appendAssumeCapacity(',');
        try out.print(a, "{{\"id\":{d},\"name\":\"item number {d}\",\"active\":{},\"score\":{d}.5,\"tags\":[\"alpha\",\"beta\",null]}}", .{ i, i, i % 2 == 0, i % 100 });
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

fn json(gpa: Allocator, count: *Counting, io: Io, size_mib: usize) !void {
    line("\n## {d} MiB of JSON", .{size_mib});
    const text = try bigJson(gpa, size_mib * 1024 * 1024);
    defer gpa.free(text);
    count.mark();
    const before = count.live.load(.monotonic);
    var t = Clock.begin(io);
    var tree = lib.json_tree.Tree.build(gpa, text, 8_000_000) catch |e| {
        line("tree: {s}, shown as text", .{@errorName(e)});
        return;
    };
    defer tree.deinit(gpa);
    line("build the tree         {d:>9.1} ms  {d} nodes, {d:>7.2} MiB", .{ t.ms(), tree.nodes.items.len, mib(count.live.load(.monotonic) - before) });
    t = Clock.begin(io);
    try tree.setAll(gpa, true);
    line("collapse all           {d:>9.1} ms", .{t.ms()});
    t = Clock.begin(io);
    try tree.setAll(gpa, false);
    line("expand all             {d:>9.1} ms  {d} rows", .{ t.ms(), tree.rows.items.len });
    var index: lib.lines.Index = .{};
    defer index.deinit(gpa);
    t = Clock.begin(io);
    try index.build(gpa, text);
    line("index text rows        {d:>9.1} ms  {d} rows", .{ t.ms(), index.count() });
    var hits: std.ArrayList(lib.search.Match) = .empty;
    defer hits.deinit(gpa);
    t = Clock.begin(io);
    const more = try lib.search.findAll(gpa, text, "number 77", &hits);
    line("search, whole body     {d:>9.1} ms  {d} matches{s}", .{ t.ms(), hits.items.len, if (more) " (capped)" else "" });
}

fn send(gpa: Allocator, io: Io, client: *lib.transport.Client, arena: Allocator, url: []const u8, spill: []const u8, max: u64) !*lib.http_client.Job {
    var done: Done = .{ .io = io };
    var problem: lib.prepare.Problem = .{};
    const job = try lib.http_client.start(gpa, io, client, .{ .url = url, .settings = .{ .max_response_bytes = max, .timeout_ms = 0 } }, &.{}, .{ .ctx = &done, .on_done = Done.onDone }, .{ .spill_dir = spill }, arena, &problem);
    try done.ev.wait(io);
    return job;
}

fn network(gpa: Allocator, count: *Counting, io: Io, dir: []const u8) !void {
    var server: Server = undefined;
    try server.start(io);
    defer server.stop();
    var client = lib.transport.Client.init(gpa, io);
    defer client.deinit();
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    line("\n## A 1 GiB download, on loopback", .{});
    count.mark();
    const before = count.live.load(.monotonic);
    var t = Clock.begin(io);
    const big = try send(gpa, io, &client, a, try server.url(a, "/bytes/1073741824"), dir, 2 * 1024 * 1024 * 1024);
    const ms = t.ms();
    line("transfer               {d:>9.0} ms  {d:.0} MiB/s, {s}, {d:.0} MiB received", .{ ms, mib(big.resp.total.load(.monotonic)) / (ms / 1000), @tagName(big.resp.stop), mib(big.resp.total.load(.monotonic)) });
    line("most held in memory    {d:>9.2} MiB (the rest on disk)", .{mib(count.peak.load(.monotonic) - before)});
    big.destroy();

    line("\n## An endless response, limit 64 MiB", .{});
    count.mark();
    t = Clock.begin(io);
    const huge = try send(gpa, io, &client, a, try server.url(a, "/huge"), dir, 64 * 1024 * 1024);
    line("stopped                {d:>9.0} ms  {s}, {d:.0} MiB received", .{ t.ms(), @tagName(huge.resp.stop), mib(huge.resp.total.load(.monotonic)) });
    huge.destroy();

    line("\n## 2,000 requests, one after another", .{});
    const url = try server.url(a, "/bytes/4096");
    var first_live: u64 = 0;
    count.mark();
    t = Clock.begin(io);
    var reused: usize = 0;
    for (0..2000) |i| {
        var req_ar = std.heap.ArenaAllocator.init(gpa);
        defer req_ar.deinit();
        const j = try send(gpa, io, &client, req_ar.allocator(), url, dir, 1024 * 1024);
        if (j.resp.reused_connection) reused += 1;
        j.destroy();
        if (i == 100) first_live = count.live.load(.monotonic);
    }
    const total = t.ms();
    line("all                    {d:>9.0} ms  {d:.2} ms each, {d} on a reused connection", .{ total, total / 2000, reused });
    const last_live = count.live.load(.monotonic);
    line("held after 100, 2,000  {d:>9.2} MiB, {d:.2} MiB  (should not grow)", .{ mib(first_live), mib(last_live) });
}

fn history(gpa: Allocator, count: *Counting, io: Io) !void {
    line("\n## History: 100,000 sends, keeping 1,000", .{});
    var h = lib.history.History.init(gpa);
    defer h.deinit();
    h.setRetention(1000);
    count.mark();
    const before = count.live.load(.monotonic);
    const t = Clock.begin(io);
    for (0..100_000) |i| {
        var buf: [96]u8 = undefined;
        try h.add(.{ .method = "GET", .url = try std.fmt.bufPrint(&buf, "https://api.example.com/v1/things/{d}", .{i}), .timestamp_ms = @intCast(i), .status = 200, .time_ms = 12 });
    }
    const ms = t.ms();
    line("added                  {d:>9.1} ms  {d} kept, {d:.2} MiB held", .{ ms, h.entries.items.len, mib(count.live.load(.monotonic) - before) });
}

extern "kernel32" fn K32GetProcessMemoryInfo(process: std.os.windows.HANDLE, counters: *ProcessMemory, size: u32) callconv(.winapi) i32;
const ProcessMemory = extern struct {
    cb: u32 = @sizeOf(ProcessMemory),
    page_fault_count: u32 = 0,
    peak_working_set: usize = 0,
    working_set: usize = 0,
    quota_peak_paged: usize = 0,
    quota_paged: usize = 0,
    quota_peak_non_paged: usize = 0,
    quota_non_paged: usize = 0,
    pagefile: usize = 0,
    peak_pagefile: usize = 0,
};

fn peakWorkingSet() void {
    if (builtin.os.tag != .windows) return;
    var m: ProcessMemory = .{};
    const self: std.os.windows.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    if (K32GetProcessMemoryInfo(self, &m, @sizeOf(ProcessMemory)) != 0) line("\nPeak working set of this whole run: {d:.1} MiB", .{mib(m.peak_working_set)});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var count: Counting = .{ .parent = std.heap.smp_allocator };
    const gpa = count.allocator();
    const cwd = Io.Dir.cwd();
    const dir = ".zig-cache/bench-data";
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};

    line("Kest benchmarks ({s}, {s})", .{ @tagName(builtin.mode), @tagName(builtin.os.tag) });
    try collection(gpa, &count, io, dir ++ "/store");
    try json(gpa, &count, io, 8);
    try json(gpa, &count, io, 64);
    try network(gpa, &count, io, dir);
    try history(gpa, &count, io);
    peakWorkingSet();
}
