//! Folding in the body editor. A JSON object or array that spans lines can
//! fold to its first line; the rows between its brackets are hidden and its
//! closing line stays. Folds are kept by the offset of their opening bracket,
//! move with edits, and go when that bracket does.
const std = @import("std");
const json = @import("../utils/json.zig");
const Index = @import("../utils/lines.zig").Index;
const Allocator = std.mem.Allocator;

/// Documents larger than this aren't scanned for folds.
pub const max_source = 4 * 1024 * 1024;
const max_depth = 4096;

pub const Region = struct { open: u32, close: u32, open_row: u32, close_row: u32 };

pub const Folds = struct {
    /// Regions with rows to hide, by first row; on a row where several
    /// begin, the outermost.
    regions: std.ArrayList(Region) = .empty,
    /// Opening brackets of folded regions, ascending.
    folded: std.ArrayList(u32) = .empty,
    /// The rows shown, in order, while anything is folded.
    shown: std.ArrayList(u32) = .empty,
    /// The row index generation the regions were found for.
    generation: u64 = 0,
    dirty: bool = true,

    pub fn deinit(f: *Folds, a: Allocator) void {
        f.regions.deinit(a);
        f.folded.deinit(a);
        f.shown.deinit(a);
    }

    /// New text: nothing is folded.
    pub fn clear(f: *Folds) void {
        f.regions.clearRetainingCapacity();
        f.folded.clearRetainingCapacity();
        f.shown.clearRetainingCapacity();
        f.generation = 0;
        f.dirty = true;
    }

    /// Finds the regions again when the rows changed. Folds whose bracket no
    /// longer opens a region unfold.
    pub fn update(f: *Folds, a: Allocator, source: []const u8, index: *const Index, generation: u64) void {
        if (generation != f.generation) {
            f.generation = generation;
            f.scan(a, source, index) catch f.regions.clearRetainingCapacity();
            var kept: usize = 0;
            for (f.folded.items) |open| if (f.regionAt(open) != null) {
                f.folded.items[kept] = open;
                kept += 1;
            };
            f.folded.shrinkRetainingCapacity(kept);
            f.dirty = true;
        }
        if (f.dirty) {
            f.dirty = false;
            f.layout(a, index.count()) catch {
                f.folded.clearRetainingCapacity();
                f.shown.clearRetainingCapacity();
            };
        }
    }

    fn scan(f: *Folds, a: Allocator, source: []const u8, index: *const Index) !void {
        f.regions.clearRetainingCapacity();
        if (source.len > max_source or index.count() == 0) return;
        var stack: [max_depth]u32 = undefined;
        var depth: usize = 0;
        var offset: usize = 0;
        while (offset < source.len) {
            const token = json.nextToken(source, offset);
            if (token.kind == .eof or token.end <= offset) break;
            offset = token.end;
            switch (token.kind) {
                .lbrace, .lbracket => {
                    if (depth == max_depth) return;
                    stack[depth] = @intCast(token.start);
                    depth += 1;
                },
                .rbrace, .rbracket => {
                    if (depth == 0) continue;
                    depth -= 1;
                    const open = stack[depth];
                    if ((source[open] == '{') != (token.kind == .rbrace)) continue;
                    const open_row = index.rowOf(open);
                    const close_row = index.rowOf(token.start);
                    if (close_row >= open_row + 2) try f.regions.append(a, .{ .open = open, .close = @intCast(token.start), .open_row = @intCast(open_row), .close_row = @intCast(close_row) });
                },
                else => {},
            }
        }
        // Closing order puts inner regions first: sort by row, outermost first.
        std.mem.sort(Region, f.regions.items, {}, struct {
            fn less(_: void, x: Region, y: Region) bool {
                return if (x.open_row != y.open_row) x.open_row < y.open_row else x.open < y.open;
            }
        }.less);
        var kept: usize = 0;
        for (f.regions.items) |r| {
            if (kept > 0 and f.regions.items[kept - 1].open_row == r.open_row) continue;
            f.regions.items[kept] = r;
            kept += 1;
        }
        f.regions.shrinkRetainingCapacity(kept);
    }

    fn layout(f: *Folds, a: Allocator, total: usize) !void {
        f.shown.clearRetainingCapacity();
        if (f.folded.items.len == 0) return;
        try f.shown.ensureTotalCapacity(a, total);
        var row: usize = 0;
        var hidden_until: usize = 0;
        var next_region: usize = 0;
        while (row < total) : (row += 1) {
            if (row >= hidden_until) f.shown.appendAssumeCapacity(@intCast(row));
            // A folded region starting here hides through its last inner row.
            while (next_region < f.regions.items.len and f.regions.items[next_region].open_row <= row) : (next_region += 1) {
                const r = f.regions.items[next_region];
                if (r.open_row == row and row >= hidden_until and f.isFolded(r.open)) hidden_until = r.close_row;
            }
            hidden_until = @max(hidden_until, row + 1);
        }
    }

    /// The region whose opening bracket is `open`.
    pub fn regionAt(f: *const Folds, open: u32) ?Region {
        for (f.regions.items) |r| if (r.open == open) return r;
        return null;
    }

    /// The region that starts on `row`, if any.
    pub fn regionOnRow(f: *const Folds, row: usize) ?Region {
        var lo: usize = 0;
        var hi = f.regions.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = f.regions.items[mid];
            if (r.open_row == row) return r;
            if (r.open_row < row) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// The innermost region around `pos`, or the one starting on its row.
    pub fn regionAround(f: *const Folds, index: *const Index, pos: usize) ?Region {
        if (f.regionOnRow(index.rowOf(pos))) |r| return r;
        var best: ?Region = null;
        for (f.regions.items) |r| {
            if (r.open > pos) break;
            if (pos <= r.close) best = r;
        }
        return best;
    }

    pub fn isFolded(f: *const Folds, open: u32) bool {
        return std.sort.binarySearch(u32, f.folded.items, open, order) != null;
    }

    pub fn anyFolded(f: *const Folds) bool {
        return f.folded.items.len > 0;
    }

    pub fn fold(f: *Folds, a: Allocator, open: u32) void {
        if (f.isFolded(open)) return;
        const at = std.sort.lowerBound(u32, f.folded.items, open, order);
        f.folded.insert(a, at, open) catch return;
        f.dirty = true;
    }

    pub fn unfold(f: *Folds, open: u32) void {
        const at = std.sort.binarySearch(u32, f.folded.items, open, order) orelse return;
        _ = f.folded.orderedRemove(at);
        f.dirty = true;
    }

    pub fn toggle(f: *Folds, a: Allocator, open: u32) void {
        if (f.isFolded(open)) f.unfold(open) else f.fold(a, open);
    }

    pub fn foldAll(f: *Folds, a: Allocator) void {
        f.folded.clearRetainingCapacity();
        for (f.regions.items) |r| f.folded.append(a, r.open) catch break;
        std.mem.sort(u32, f.folded.items, {}, std.sort.asc(u32));
        f.dirty = true;
    }

    pub fn unfoldAll(f: *Folds) void {
        if (f.folded.items.len == 0) return;
        f.folded.clearRetainingCapacity();
        f.dirty = true;
    }

    /// Unfolds whatever hides `row`. Returns whether anything did.
    pub fn reveal(f: *Folds, row: usize) bool {
        var changed = false;
        var i: usize = 0;
        while (i < f.folded.items.len) {
            const r = f.regionAt(f.folded.items[i]) orelse {
                i += 1;
                continue;
            };
            if (row > r.open_row and row < r.close_row) {
                _ = f.folded.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
        if (changed) f.dirty = true;
        return changed;
    }

    /// The text changed: `removed` bytes at `at` became `inserted` bytes.
    /// Folds after the edit move with it; a fold whose bracket was edited
    /// goes.
    pub fn shift(f: *Folds, at: usize, removed: usize, inserted: usize) void {
        var kept: usize = 0;
        for (f.folded.items) |open| {
            if (open >= at + removed) {
                f.folded.items[kept] = @intCast(open + inserted - removed);
            } else if (open >= at) {
                continue;
            } else f.folded.items[kept] = open;
            kept += 1;
        }
        if (kept != f.folded.items.len) f.dirty = true;
        f.folded.shrinkRetainingCapacity(kept);
    }

    /// How many rows show.
    pub fn rows(f: *const Folds, total: usize) usize {
        return if (f.folded.items.len == 0) total else f.shown.items.len;
    }

    /// The row shown `visual` rows from the top.
    pub fn rowAt(f: *const Folds, visual: usize) usize {
        if (f.folded.items.len == 0) return visual;
        if (f.shown.items.len == 0) return 0;
        return f.shown.items[@min(visual, f.shown.items.len - 1)];
    }

    /// Where `row` shows; a hidden row shows as its fold's first row.
    pub fn visualOf(f: *const Folds, row: usize) usize {
        if (f.folded.items.len == 0) return row;
        const at = std.sort.upperBound(u32, f.shown.items, @as(u32, @intCast(row)), order);
        return at -| 1;
    }

    fn order(want: u32, item: u32) std.math.Order {
        return std.math.order(want, item);
    }
};

const t = std.testing;

test "regions, folding, hidden rows and edits" {
    const source = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {\"c\": 1},\n  \"d\": {\n    \"e\": [3,\n      4]\n  }\n}";
    var index: Index = .{};
    defer index.deinit(t.allocator);
    try index.build(t.allocator, source);
    var f: Folds = .{};
    defer f.deinit(t.allocator);
    f.update(t.allocator, source, &index, 1);
    // The root, "a" and "d"; "b" is one line and "e" spans only two rows.
    try t.expectEqual(@as(usize, 3), f.regions.items.len);
    try t.expectEqual(@as(u32, 0), f.regions.items[0].open_row);
    try t.expectEqual(@as(u32, 1), f.regions.items[1].open_row);
    try t.expectEqual(@as(u32, 6), f.regions.items[2].open_row);
    try t.expect(f.regionOnRow(3) == null);
    try t.expectEqual(@as(u32, 1), f.regionAround(&index, 14).?.open_row);
    const a = f.regionOnRow(1).?;
    f.fold(t.allocator, a.open);
    f.update(t.allocator, source, &index, 1);
    // Rows 2 and 3 hide; row 4 ("],") stays.
    try t.expectEqual(index.count() - 2, f.rows(index.count()));
    try t.expectEqual(@as(usize, 4), f.rowAt(2));
    try t.expectEqual(@as(usize, 1), f.visualOf(3));
    try t.expectEqual(@as(usize, 2), f.visualOf(4));
    // Folding the root hides everything inside it, nested folds or not.
    f.fold(t.allocator, f.regionOnRow(0).?.open);
    f.update(t.allocator, source, &index, 1);
    try t.expectEqual(@as(usize, 2), f.rows(index.count()));
    try t.expectEqual(index.count() - 1, f.rowAt(1));
    // A row inside a fold unfolds what hides it.
    try t.expect(f.reveal(3));
    f.update(t.allocator, source, &index, 1);
    try t.expect(!f.anyFolded());
    // Edits before a fold move it; editing its bracket drops it.
    f.fold(t.allocator, a.open);
    f.shift(0, 0, 3);
    try t.expectEqual(a.open + 3, f.folded.items[0]);
    f.shift(a.open + 3, 1, 0);
    try t.expect(!f.anyFolded());
    f.foldAll(t.allocator);
    try t.expectEqual(@as(usize, 3), f.folded.items.len);
    f.unfoldAll();
    try t.expect(!f.anyFolded());
}
