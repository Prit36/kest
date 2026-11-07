//! Requests sent, newest last, in a bounded list. An entry keeps what the
//! list shows and a snapshot of the request template to reopen or resend it;
//! never a response body. Oversized bodies are left out of the snapshot.
const std = @import("std");
const json = @import("../utils/json.zig");
const req = @import("request.zig");
const Allocator = std.mem.Allocator;

pub const default_retention = 1000;
/// A body larger than this isn't kept: the entry says so and still reopens.
pub const max_snapshot_body = 256 * 1024;

pub const Entry = struct {
    method: []const u8,
    url: []const u8,
    /// Milliseconds since the epoch.
    timestamp_ms: i64,
    /// 0: no response (an error, or canceled).
    status: u16,
    time_ms: u32,
    /// The request's JSON (template form), null if it was too large.
    snapshot: ?[]const u8 = null,
};

pub const StatusFilter = enum { any, ok_2xx, redirect_3xx, client_4xx, server_5xx, failed };

pub const Filter = struct {
    query: []const u8 = "",
    /// Null: every method.
    method: ?[]const u8 = null,
    status: StatusFilter = .any,

    pub fn accepts(f: Filter, e: *const Entry) bool {
        if (f.method) |m| if (!std.ascii.eqlIgnoreCase(m, e.method)) return false;
        const ok = switch (f.status) {
            .any => true,
            .ok_2xx => e.status >= 200 and e.status < 300,
            .redirect_3xx => e.status >= 300 and e.status < 400,
            .client_4xx => e.status >= 400 and e.status < 500,
            .server_5xx => e.status >= 500,
            .failed => e.status == 0,
        };
        if (!ok) return false;
        return f.query.len == 0 or std.ascii.findIgnoreCase(e.url, f.query) != null;
    }
};

pub const History = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    retention: usize = default_retention,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(h: *History) void {
        for (h.entries.items) |e| h.free(e);
        h.entries.deinit(h.gpa);
    }

    fn free(h: *History, e: Entry) void {
        h.gpa.free(e.method);
        h.gpa.free(e.url);
        if (e.snapshot) |s| h.gpa.free(s);
    }

    /// Copies `e` in, dropping the oldest entries past the retention.
    pub fn add(h: *History, e: Entry) !void {
        const method = try h.gpa.dupe(u8, e.method);
        errdefer h.gpa.free(method);
        const url = try h.gpa.dupe(u8, e.url);
        errdefer h.gpa.free(url);
        const snapshot = if (e.snapshot) |s| try h.gpa.dupe(u8, s) else null;
        errdefer if (snapshot) |s| h.gpa.free(s);
        try h.entries.append(h.gpa, .{ .method = method, .url = url, .timestamp_ms = e.timestamp_ms, .status = e.status, .time_ms = e.time_ms, .snapshot = snapshot });
        h.trim();
    }

    pub fn trim(h: *History) void {
        if (h.entries.items.len <= h.retention) return;
        const drop = h.entries.items.len - h.retention;
        for (h.entries.items[0..drop]) |e| h.free(e);
        h.entries.replaceRangeAssumeCapacity(0, drop, &.{});
    }

    pub fn remove(h: *History, index: usize) void {
        h.free(h.entries.orderedRemove(index));
    }

    pub fn clear(h: *History) void {
        for (h.entries.items) |e| h.free(e);
        h.entries.clearRetainingCapacity();
    }

    pub fn setRetention(h: *History, n: usize) void {
        h.retention = @max(1, n);
        h.trim();
    }

    /// One line of the file (JSON Lines), without its newline.
    pub fn writeLine(e: Entry, w: *std.Io.Writer) !void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try json.field(&s, "method", e.method);
        try json.field(&s, "url", e.url);
        try json.field(&s, "at", e.timestamp_ms);
        try json.field(&s, "status", e.status);
        try json.field(&s, "ms", e.time_ms);
        if (e.snapshot) |snap| try json.field(&s, "request", snap);
        try s.endObject();
    }

    /// Loads JSON Lines, skipping lines it can't read: a crash can only hurt
    /// the last one, and one bad line must not cost the rest. Returns how
    /// many lines were skipped.
    pub fn loadLines(h: *History, text: []const u8) !usize {
        var skipped: usize = 0;
        var ar = std.heap.ArenaAllocator.init(h.gpa);
        defer ar.deinit();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line_in| {
            const line = std.mem.trim(u8, line_in, " \r\t");
            if (line.len == 0) continue;
            // Reuse JSON parser scratch across entries without retaining an
            // oversized history line for the remainder of startup.
            _ = ar.reset(.{ .retain_with_limit = 512 * 1024 });
            const v = std.json.parseFromSliceLeaky(std.json.Value, ar.allocator(), line, .{}) catch {
                skipped += 1;
                continue;
            };
            const url = json.str(v, "url") orelse {
                skipped += 1;
                continue;
            };
            try h.add(.{
                .method = json.str(v, "method") orelse "GET",
                .url = url,
                .timestamp_ms = json.int(v, "at") orelse 0,
                .status = @intCast(std.math.clamp(json.int(v, "status") orelse 0, 0, 999)),
                .time_ms = @intCast(std.math.clamp(json.int(v, "ms") orelse 0, 0, std.math.maxInt(u32))),
                .snapshot = json.str(v, "request"),
            });
        }
        return skipped;
    }

    pub fn toLines(h: *const History, a: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        for (h.entries.items) |e| {
            writeLine(e, &out.writer) catch return error.OutOfMemory;
            out.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }
};

/// The snapshot to keep for `r`: null when its body is too large to keep.
pub fn snapshotOf(a: Allocator, r: req.Request) !?[]u8 {
    if (r.body_text.len > max_snapshot_body) return null;
    return try r.toJson(a);
}

const t = std.testing;

test "retention drops the oldest" {
    var h = History.init(t.allocator);
    defer h.deinit();
    h.retention = 3;
    var buf: [8]u8 = undefined;
    for (0..5) |i| try h.add(.{ .method = "GET", .url = try std.fmt.bufPrint(&buf, "u{d}", .{i}), .timestamp_ms = @intCast(i), .status = 200, .time_ms = 1 });
    try t.expectEqual(@as(usize, 3), h.entries.items.len);
    try t.expectEqualStrings("u2", h.entries.items[0].url);
    h.setRetention(1);
    try t.expectEqualStrings("u4", h.entries.items[0].url);
}

test "filters" {
    const e: Entry = .{ .method = "POST", .url = "http://api/users", .timestamp_ms = 0, .status = 404, .time_ms = 3 };
    try t.expect((Filter{}).accepts(&e));
    try t.expect((Filter{ .query = "USERS" }).accepts(&e));
    try t.expect(!(Filter{ .query = "orders" }).accepts(&e));
    try t.expect((Filter{ .method = "post" }).accepts(&e));
    try t.expect(!(Filter{ .method = "GET" }).accepts(&e));
    try t.expect((Filter{ .status = .client_4xx }).accepts(&e));
    try t.expect(!(Filter{ .status = .ok_2xx }).accepts(&e));
    try t.expect(!(Filter{ .status = .failed }).accepts(&e));
}

test "lines round trip, and a torn line costs only itself" {
    var h = History.init(t.allocator);
    defer h.deinit();
    try h.add(.{ .method = "GET", .url = "http://a/\"q\"", .timestamp_ms = 5, .status = 200, .time_ms = 9, .snapshot = "{\"name\":\"x\"}" });
    try h.add(.{ .method = "PUT", .url = "http://b", .timestamp_ms = 6, .status = 0, .time_ms = 1 });
    const lines = try h.toLines(t.allocator);
    defer t.allocator.free(lines);
    var torn: std.ArrayList(u8) = .empty;
    defer torn.deinit(t.allocator);
    try torn.appendSlice(t.allocator, lines);
    try torn.appendSlice(t.allocator, "{\"method\":\"GET\",\"url\":\"http://c");
    var back = History.init(t.allocator);
    defer back.deinit();
    try t.expectEqual(@as(usize, 1), try back.loadLines(torn.items));
    try t.expectEqual(@as(usize, 2), back.entries.items.len);
    try t.expectEqualStrings("http://a/\"q\"", back.entries.items[0].url);
    try t.expectEqualStrings("{\"name\":\"x\"}", back.entries.items[0].snapshot.?);
    try t.expect(back.entries.items[1].snapshot == null);
}

test "snapshots skip huge bodies" {
    const a = t.allocator;
    const big = try a.alloc(u8, max_snapshot_body + 1);
    defer a.free(big);
    @memset(big, 'x');
    try t.expect(try snapshotOf(a, .{ .body_text = big }) == null);
    const small = (try snapshotOf(a, .{ .url = "http://x" })).?;
    defer a.free(small);
    try t.expect(std.mem.indexOf(u8, small, "http://x") != null);
}
