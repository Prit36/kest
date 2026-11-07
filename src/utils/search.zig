//! Case-insensitive search of a text, up to a bound: a one-letter search of
//! a large body stops at `max_matches` and says so instead of using more memory.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Match = struct { start: u32, end: u32 };
pub const max_matches = 10_000;

/// Replaces `out` with what's found; true if there were more than it keeps.
pub fn findAll(a: Allocator, text: []const u8, query: []const u8, out: *std.ArrayList(Match)) !bool {
    out.clearRetainingCapacity();
    if (query.len == 0) return false;
    var at: usize = 0;
    while (at + query.len <= text.len) {
        const rel = std.ascii.findIgnoreCase(text[at..], query) orelse return false;
        if (out.items.len == max_matches) return true;
        const start = at + rel;
        try out.append(a, .{ .start = @intCast(start), .end = @intCast(start + query.len) });
        at = start + query.len;
    }
    return false;
}

/// The first match ending after `pos`, as an index of `matches`.
pub fn firstAfter(matches: []const Match, pos: usize) usize {
    var lo: usize = 0;
    var hi: usize = matches.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (matches[mid].end <= pos) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const t = std.testing;

test "finds without regard to case, and doesn't overlap" {
    var m: std.ArrayList(Match) = .empty;
    defer m.deinit(t.allocator);
    try t.expect(!try findAll(t.allocator, "aXa xA aaa", "xa", &m));
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expectEqual(@as(u32, 1), m.items[0].start);
    try t.expect(!try findAll(t.allocator, "aaaa", "aa", &m));
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expect(!try findAll(t.allocator, "abc", "", &m));
    try t.expectEqual(@as(usize, 0), m.items.len);
    try t.expectEqual(@as(usize, 0), firstAfter(&.{}, 3));
}

test "the bound holds" {
    const text = try t.allocator.alloc(u8, max_matches + 50);
    defer t.allocator.free(text);
    @memset(text, 'a');
    var m: std.ArrayList(Match) = .empty;
    defer m.deinit(t.allocator);
    try t.expect(try findAll(t.allocator, text, "a", &m));
    try t.expectEqual(@as(usize, max_matches), m.items.len);
    try t.expectEqual(@as(usize, 3), firstAfter(m.items, 3));
}
