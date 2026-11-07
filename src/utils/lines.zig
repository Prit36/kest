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

    const continued: u32 = 1 << 31;

    pub fn deinit(x: *Index, a: Allocator) void {
        x.starts.deinit(a);
        x.lines.deinit(a);
    }

    pub fn build(x: *Index, a: Allocator, text: []const u8) !void {
        x.starts.clearRetainingCapacity();
        x.lines.clearRetainingCapacity();
        x.longest = 0;
        var at: usize = 0;
        var line: u32 = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            var start = at;
            var first = true;
            while (true) {
                try x.starts.append(a, @intCast(start));
                try x.lines.append(a, if (first) line else line | continued);
                first = false;
                if (nl - start <= x.wrap_at) break;
                var cut = start + x.wrap_at;
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
        if (i + 1 < x.starts.items.len and !x.isContinued(i + 1) and end > start) end -= 1;
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
