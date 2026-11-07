//! Where a text's visual rows start, so a viewer draws only what's in view.
//! A row is one line, or a piece of a line longer than `wrap_at` bytes: a
//! minified megabyte stays a list of short rows, never one huge text run.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_wrap = 2000;

pub const Index = struct {
    /// Byte offset of each row; never empty once built.
    starts: std.ArrayList(u32) = .empty,
    /// Bit 31: the row continues the line above. The rest: its line number.
    lines: std.ArrayList(u32) = .empty,
    longest: usize = 0,
    wrap_at: usize = default_wrap,
    /// Soft wrapping prefers whitespace and budgets a tab as two cells.
    prefer_words: bool = false,

    const continued: u32 = 1 << 31;

    pub fn deinit(x: *Index, a: Allocator) void {
        x.starts.deinit(a);
        x.lines.deinit(a);
    }

    pub fn build(x: *Index, a: Allocator, text: []const u8) !void {
        return x.buildLimited(a, text, std.math.maxInt(usize));
    }

    pub fn buildLimited(x: *Index, a: Allocator, text: []const u8, max_rows: usize) !void {
        x.starts.clearRetainingCapacity();
        x.lines.clearRetainingCapacity();
        x.longest = 0;
        errdefer {
            x.starts.clearRetainingCapacity();
            x.lines.clearRetainingCapacity();
            x.longest = 0;
        }
        var at: usize = 0;
        var line: u32 = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            var start = at;
            var first = true;
            while (true) {
                if (x.starts.items.len >= max_rows) return error.TooManyRows;
                try x.starts.append(a, @intCast(start));
                try x.lines.append(a, if (first) line else line | continued);
                first = false;
                const limit = @max(4, x.wrap_at);
                if (nl - start <= limit and !x.prefer_words) break;
                var cut = @min(nl, start + limit);
                if (x.prefer_words) {
                    var budget: usize = 0;
                    cut = start;
                    var space: ?usize = null;
                    while (cut < nl) {
                        const cost: usize = if (text[cut] == '\t') 2 else 1;
                        if (budget + cost > limit) break;
                        budget += cost;
                        cut += 1;
                        if (text[cut - 1] == ' ' or text[cut - 1] == '\t') space = cut;
                    }
                    if (cut == nl) break;
                    if (space) |word_end| cut = word_end;
                }
                if (cut == nl) break;
                while (cut > start and (text[cut] & 0xc0) == 0x80) cut -= 1;
                x.longest = @max(x.longest, cut - start);
                start = cut;
            }
            x.longest = @max(x.longest, nl - start);
            if (nl == text.len) break;
            at = nl + 1;
            line += 1;
        }
    }

    pub fn count(x: *const Index) usize {
        return x.starts.items.len;
    }

    /// The row's bytes, without its newline.
    pub fn row(x: *const Index, text: []const u8, i: usize) []const u8 {
        const r = x.bounds(text, i);
        return text[r[0]..r[1]];
    }

    pub fn bounds(x: *const Index, text: []const u8, i: usize) [2]usize {
        const start: usize = x.starts.items[i];
        const next = if (i + 1 < x.starts.items.len) x.starts.items[i + 1] else text.len;
        var end: usize = next;
        if (i + 1 < x.starts.items.len and !x.isContinued(i + 1) and end > start) {
            end -= 1;
            if (end > start and text[end - 1] == '\r') end -= 1;
        }
        return .{ start, @max(start, end) };
    }

    pub fn isContinued(x: *const Index, i: usize) bool {
        return x.lines.items[i] & continued != 0;
    }

    /// The 1-based line a row is on.
    pub fn lineNumber(x: *const Index, i: usize) u32 {
        return (x.lines.items[i] & ~continued) + 1;
    }

    /// The row holding byte `pos`.
    pub fn rowOf(x: *const Index, pos: usize) usize {
        const items = x.starts.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (items[mid] <= pos) lo = mid else hi = mid;
        }
        return lo;
    }
};

const t = std.testing;

test "rows of short lines" {
    var x: Index = .{};
    defer x.deinit(t.allocator);
    const s = "ab\n\ncd";
    try x.build(t.allocator, s);
    try t.expectEqual(@as(usize, 3), x.count());
    try t.expectEqualStrings("ab", x.row(s, 0));
    try t.expectEqualStrings("", x.row(s, 1));
    try t.expectEqualStrings("cd", x.row(s, 2));
    try t.expectEqual(@as(usize, 0), x.rowOf(2));
    try t.expectEqual(@as(usize, 1), x.rowOf(3));
    try t.expectEqual(@as(usize, 2), x.rowOf(6));
    try t.expectEqual(@as(u32, 3), x.lineNumber(2));
}

test "a text ending in a newline has an empty last row" {
    var x: Index = .{};
    defer x.deinit(t.allocator);
    try x.build(t.allocator, "a\n");
    try t.expectEqual(@as(usize, 2), x.count());
    try t.expectEqualStrings("", x.row("a\n", 1));
    var empty: Index = .{};
    defer empty.deinit(t.allocator);
    try empty.build(t.allocator, "");
    try t.expectEqual(@as(usize, 1), empty.count());
}

test "long lines wrap, on character boundaries" {
    var x: Index = .{ .wrap_at = 4 };
    defer x.deinit(t.allocator);
    const s = "abcdef\u{e9}\u{e9}\u{e9}\nxy";
    try x.build(t.allocator, s);
    try t.expectEqualStrings("abcd", x.row(s, 0));
    try t.expectEqualStrings("ef\u{e9}", x.row(s, 1));
    try t.expect(x.isContinued(1));
    try t.expectEqual(@as(u32, 1), x.lineNumber(1));
    try t.expectEqualStrings("\u{e9}\u{e9}", x.row(s, 2));
    try t.expectEqualStrings("xy", x.row(s, 3));
    try t.expectEqual(@as(u32, 2), x.lineNumber(3));
    // Every byte is on exactly one row.
    var total: usize = 0;
    for (0..x.count()) |i| total += x.row(s, i).len;
    try t.expectEqual(s.len - 1, total);
}

test "soft wrapping prefers words and never splits UTF-8 or changes bytes" {
    var x: Index = .{ .wrap_at = 10, .prefer_words = true };
    defer x.deinit(t.allocator);
    const source = "one two three\t\u{e9}\u{1f642}abcdefghijk\n";
    try x.build(t.allocator, source);
    try t.expectEqualStrings("one two ", x.row(source, 0));
    var bytes: usize = 0;
    for (0..x.count()) |i| {
        const row = x.row(source, i);
        try t.expect(std.unicode.utf8ValidateSlice(row));
        bytes += row.len;
    }
    try t.expectEqual(source.len - 1, bytes);
    x.wrap_at = 1;
    try x.build(t.allocator, "\u{1f642}\u{1f642}");
    try t.expectEqual(@as(usize, 2), x.count());
}
