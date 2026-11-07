//! What the bottom panel shows: a ring of recent events, each one line. Only
//! what the user may safely paste elsewhere gets in: request headers are never
//! logged, and a URL's credentials and secret-looking parameters are masked.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const capacity = 256;
pub const Level = enum { info, warn, err };

pub const Entry = struct { timestamp_ms: i64, level: Level, text: []u8 };

pub const Log = struct {
    gpa: Allocator,
    entries: [capacity]?Entry = @splat(null),
    /// How many were ever added; the newest is at `(total - 1) % capacity`.
    total: usize = 0,
    generation: u64 = 0,

    pub fn init(gpa: Allocator) Log {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Log) void {
        for (l.entries) |e| if (e) |x| l.gpa.free(x.text);
    }

    pub fn add(l: *Log, now_ms: i64, level: Level, text: []const u8) void {
        const copy = l.gpa.dupe(u8, text) catch return;
        const slot = &l.entries[l.total % capacity];
        if (slot.*) |old| l.gpa.free(old.text);
        slot.* = .{ .timestamp_ms = now_ms, .level = level, .text = copy };
        l.total += 1;
    }

    pub fn count(l: *const Log) usize {
        return @min(l.total, capacity);
    }

    /// The i-th oldest still kept.
    pub fn at(l: *const Log, i: usize) Entry {
        const first = l.total - l.count();
        return l.entries[(first + i) % capacity].?;
    }

    pub fn clear(l: *Log) void {
        l.generation +%= 1;
        for (&l.entries) |*e| {
            if (e.*) |x| l.gpa.free(x.text);
            e.* = null;
        }
        l.total = 0;
    }
};

const sensitive_headers = [_][]const u8{ "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token", "x-csrf-token" };
const sensitive_words = [_][]const u8{ "token", "secret", "password", "passwd", "pwd", "apikey", "api_key", "api-key", "auth", "signature", "sig", "session", "key" };

pub fn isSensitiveHeader(name: []const u8) bool {
    for (sensitive_headers) |h| if (std.ascii.eqlIgnoreCase(h, name)) return true;
    return false;
}

/// A header's value as a log may show it.
pub fn redactHeader(name: []const u8, value: []const u8) []const u8 {
    return if (isSensitiveHeader(name)) "***" else value;
}

fn isSensitiveParam(name: []const u8) bool {
    for (sensitive_words) |w| if (std.ascii.findIgnoreCase(name, w) != null) return true;
    return false;
}

/// `url` without credentials and without the values of secret-looking
/// parameters: what a log line, or a bug report made from one, can carry.
pub fn redactUrl(a: Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |sch| {
        try out.appendSlice(a, rest[0 .. sch + 3]);
        rest = rest[sch + 3 ..];
        const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        if (std.mem.lastIndexOfScalar(u8, rest[0..auth_end], '@')) |at| {
            try out.appendSlice(a, "***@");
            rest = rest[at + 1 ..];
        }
    }
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse {
        try out.appendSlice(a, rest);
        return out.toOwnedSlice(a);
    };
    try out.appendSlice(a, rest[0 .. q + 1]);
    const after = rest[q + 1 ..];
    const frag = std.mem.indexOfScalar(u8, after, '#') orelse after.len;
    var it = std.mem.splitScalar(u8, after[0..frag], '&');
    var first = true;
    while (it.next()) |pair| {
        if (!first) try out.append(a, '&');
        first = false;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            try out.appendSlice(a, pair);
            continue;
        };
        try out.appendSlice(a, pair[0 .. eq + 1]);
        try out.appendSlice(a, if (isSensitiveParam(pair[0..eq])) "***" else pair[eq + 1 ..]);
    }
    try out.appendSlice(a, after[frag..]);
    return out.toOwnedSlice(a);
}

const t = std.testing;

test "secrets don't reach the log" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("https://***@h/p?q=1&api_key=***&Token=***#f", try redactUrl(a, "https://u:pw@h/p?q=1&api_key=abc&Token=xyz#f"));
    try t.expectEqualStrings("http://h/a@b", try redactUrl(a, "http://h/a@b"));
    try t.expectEqualStrings("http://h?flag", try redactUrl(a, "http://h?flag"));
    try t.expectEqualStrings("***", redactHeader("Authorization", "Bearer x"));
    try t.expectEqualStrings("***", redactHeader("cookie", "a=b"));
    try t.expectEqualStrings("json", redactHeader("Accept", "json"));
}

test "the ring keeps the newest" {
    var l = Log.init(t.allocator);
    defer l.deinit();
    var buf: [16]u8 = undefined;
    for (0..capacity + 10) |i| l.add(@intCast(i), .info, try std.fmt.bufPrint(&buf, "{d}", .{i}));
    try t.expectEqual(@as(usize, capacity), l.count());
    try t.expectEqualStrings("10", l.at(0).text);
    try t.expectEqualStrings("265", l.at(capacity - 1).text);
    l.clear();
    try t.expectEqual(@as(usize, 0), l.count());
}
