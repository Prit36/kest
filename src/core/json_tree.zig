//! A JSON document as a flat, compact array of nodes over the original text:
//! nothing is copied, so a viewer's tree costs a fixed 24 bytes per node.
//! Showing a tree is then walking that array, jumping over collapsed
//! containers, which costs what's visible rather than what's in the document.
const std = @import("std");
const json = @import("../utils/json.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) { object, array, string, number, boolean, null_, close };

pub const Node = struct {
    key_off: u32 = 0,
    key_len: u32 = 0,
    val_off: u32 = 0,
    val_len: u32 = 0,
    /// Nodes inside this container, its closing node included.
    skip: u32 = 0,
    depth: u16 = 0,
    kind: Kind = .null_,
    /// A comma follows it in the formatted view.
    comma: bool = false,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 24);
}

pub const Error = error{ NotJson, TooLarge, OutOfMemory };

pub const Tree = struct {
    text: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    /// One bit per node: collapsed.
    collapsed: std.DynamicBitSetUnmanaged = .{},
    /// Node indices shown, in order; `refresh` rebuilds it.
    rows: std.ArrayList(u32) = .empty,

    /// Fails with `TooLarge` past `max_nodes`: the caller shows plain text.
    pub fn build(a: Allocator, text: []const u8, max_nodes: usize) Error!Tree {
        var t: Tree = .{ .text = text };
        errdefer t.deinit(a);
        if (text.len > std.math.maxInt(u32)) return error.TooLarge;
        if (json.validate(text) != null) return error.NotJson;
        // Most documents have about one node per 12 bytes.
        try t.nodes.ensureTotalCapacity(a, @min(max_nodes, text.len / 12 + 16));
        var open: std.ArrayList(u32) = .empty;
        defer open.deinit(a);
        var i: usize = 0;
        var pending: ?json.Token = null;
        while (true) {
            const tok = json.nextToken(text, i);
            i = tok.end;
            switch (tok.kind) {
                .eof => break,
                .comma => {
                    if (t.nodes.items.len > 0) t.nodes.items[t.nodes.items.len - 1].comma = true;
                    continue;
                },
                .colon => continue,
                .string => if (open.items.len > 0 and t.nodes.items[open.getLast()].kind == .object and pending == null) {
                    pending = tok;
                    continue;
                },
                else => {},
            }
            if (t.nodes.items.len >= max_nodes) return error.TooLarge;
            const depth: u16 = @intCast(open.items.len);
            switch (tok.kind) {
                .rbrace, .rbracket => {
                    const start = open.pop().?;
                    t.nodes.items[start].skip = @intCast(t.nodes.items.len - start);
                    try t.nodes.append(a, .{ .kind = .close, .depth = depth - 1, .val_off = @intCast(tok.start), .val_len = 1 });
                },
                .lbrace, .lbracket => {
                    try open.append(a, @intCast(t.nodes.items.len));
                    try t.nodes.append(a, withKey(.{ .kind = if (tok.kind == .lbrace) .object else .array, .depth = depth, .val_off = @intCast(tok.start), .val_len = 1 }, pending));
                    pending = null;
                },
                else => {
                    const kind: Kind = switch (tok.kind) {
                        .string => .string,
                        .number => .number,
                        .true_, .false_ => .boolean,
                        else => .null_,
                    };
                    try t.nodes.append(a, withKey(.{ .kind = kind, .depth = depth, .val_off = @intCast(tok.start), .val_len = @intCast(tok.end - tok.start) }, pending));
                    pending = null;
                },
            }
        }
        t.collapsed = try .initEmpty(a, t.nodes.items.len);
        try t.refresh(a);
        return t;
    }

    fn withKey(n_in: Node, name: ?json.Token) Node {
        var n = n_in;
        if (name) |k| {
            n.key_off = @intCast(k.start);
            n.key_len = @intCast(k.end - k.start);
        }
        return n;
    }

    pub fn deinit(t: *Tree, a: Allocator) void {
        t.nodes.deinit(a);
        t.collapsed.deinit(a);
        t.rows.deinit(a);
    }

    pub fn isContainer(t: *const Tree, i: u32) bool {
        const k = t.nodes.items[i].kind;
        return k == .object or k == .array;
    }

    pub fn isCollapsed(t: *const Tree, i: u32) bool {
        return t.collapsed.isSet(i);
    }

    pub fn refresh(t: *Tree, a: Allocator) !void {
        t.rows.clearRetainingCapacity();
        var i: u32 = 0;
        const n: u32 = @intCast(t.nodes.items.len);
        while (i < n) {
            try t.rows.append(a, i);
            // Past a collapsed container and its closing node.
            if (t.isContainer(i) and t.collapsed.isSet(i)) i += t.nodes.items[i].skip;
            i += 1;
        }
    }

    pub fn toggle(t: *Tree, a: Allocator, i: u32) !void {
        if (!t.isContainer(i)) return;
        const row = t.rowOf(i) orelse {
            t.collapsed.toggle(i);
            return;
        };
        const end = i + t.nodes.items[i].skip;
        if (t.isCollapsed(i)) {
            // Count and insert just this subtree; unrelated nodes need no walk.
            var count: usize = 0;
            var j = i + 1;
            while (j <= end) : (j += 1) {
                count += 1;
                if (t.isContainer(j) and t.isCollapsed(j)) j += t.nodes.items[j].skip;
            }
            const added = try t.rows.addManyAt(a, row + 1, count);
            j = i + 1;
            for (added) |*slot| {
                slot.* = j;
                if (t.isContainer(j) and t.isCollapsed(j)) j += t.nodes.items[j].skip;
                j += 1;
            }
        } else {
            // Find the first row beyond the subtree in logarithmic time, then
            // move the remaining row indices once. No document-wide rebuild.
            var lo = row + 1;
            var hi = t.rows.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (t.rows.items[mid] <= end) lo = mid + 1 else hi = mid;
            }
            t.rows.replaceRangeAssumeCapacity(row + 1, lo - row - 1, &.{});
        }
        t.collapsed.toggle(i);
    }

    /// Collapses everything below the root, or opens everything.
    pub fn setAll(t: *Tree, a: Allocator, collapsed: bool) !void {
        t.collapsed.unsetAll();
        if (collapsed) for (t.nodes.items, 0..) |n, i| {
            if ((n.kind == .object or n.kind == .array) and n.depth >= 1) t.collapsed.set(i);
        };
        try t.refresh(a);
    }

    /// Opens the containers around node `i`, so it's shown.
    pub fn reveal(t: *Tree, a: Allocator, i: u32) !void {
        var j: u32 = 0;
        var changed = false;
        while (j < i) : (j += 1) {
            if (!t.isContainer(j)) continue;
            if (j + t.nodes.items[j].skip >= i) {
                if (t.collapsed.isSet(j)) {
                    t.collapsed.unset(j);
                    changed = true;
                }
            } else {
                j += t.nodes.items[j].skip;
            }
        }
        if (changed) try t.refresh(a);
    }

    /// The row showing node `i`: binary search, as `rows` is sorted.
    pub fn rowOf(t: *const Tree, i: u32) ?usize {
        const Ctx = struct {
            fn order(want: u32, x: u32) std.math.Order {
                return std.math.order(want, x);
            }
        };
        return std.sort.binarySearch(u32, t.rows.items, i, Ctx.order);
    }

    pub fn key(t: *const Tree, i: u32) []const u8 {
        const n = t.nodes.items[i];
        return t.text[n.key_off..][0..n.key_len];
    }

    pub fn value(t: *const Tree, i: u32) []const u8 {
        const n = t.nodes.items[i];
        return t.text[n.val_off..][0..n.val_len];
    }

    /// The source text of node `i`, whole for a container: Copy Value.
    pub fn sourceOf(t: *const Tree, i: u32) []const u8 {
        const n = t.nodes.items[i];
        if (n.kind != .object and n.kind != .array) return t.value(i);
        const close = t.nodes.items[i + n.skip];
        return t.text[n.val_off .. close.val_off + 1];
    }

    /// How many direct children a container has.
    pub fn childCount(t: *const Tree, i: u32) usize {
        const n = t.nodes.items[i];
        var j = i + 1;
        const end = i + n.skip;
        var count: usize = 0;
        while (j < end) {
            count += 1;
            if (t.isContainer(j)) j += t.nodes.items[j].skip;
            j += 1;
        }
        return count;
    }
};

const testing = std.testing;
const doc = "{\"a\":1,\"b\":[true,{\"c\":null}],\"d\":\"x\",\"e\":{}}";

test "tree shape" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    // { a b [ true { c } ] d e { } }
    try testing.expectEqual(@as(usize, 12), t.nodes.items.len);
    try testing.expectEqual(@as(usize, 12), t.rows.items.len);
    try testing.expectEqualStrings("\"a\"", t.key(1));
    try testing.expectEqualStrings("1", t.value(1));
    try testing.expect(t.nodes.items[1].comma);
    try testing.expectEqual(Kind.array, t.nodes.items[2].kind);
    try testing.expectEqual(@as(usize, 2), t.childCount(2));
    try testing.expectEqual(@as(usize, 4), t.childCount(0));
    try testing.expectEqualStrings("[true,{\"c\":null}]", t.sourceOf(2));
    try testing.expectEqualStrings("{}", t.sourceOf(9));
}

test "collapsing skips what's inside, and reveal opens it" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    try t.toggle(a, 2);
    try testing.expectEqual(@as(usize, 7), t.rows.items.len);
    try testing.expectEqual(@as(?usize, null), t.rowOf(5));
    try t.setAll(a, true);
    try testing.expectEqual(@as(usize, 6), t.rows.items.len);
    // The null inside the object inside the array.
    try t.reveal(a, 5);
    try testing.expect(t.rowOf(5) != null);
    try t.setAll(a, false);
    try testing.expectEqual(@as(usize, 12), t.rows.items.len);
}

test "limits and bad input" {
    const a = testing.allocator;
    try testing.expectError(error.NotJson, Tree.build(a, "{", 10));
    try testing.expectError(error.TooLarge, Tree.build(a, doc, 3));
    var scalar = try Tree.build(a, "42", 10);
    defer scalar.deinit(a);
    try testing.expectEqual(@as(usize, 1), scalar.rows.items.len);
}

test "incremental toggles match rebuilding, including hidden and empty containers" {
    const a = testing.allocator;
    var tree = try Tree.build(a, doc, 1000);
    defer tree.deinit(a);
    var reference = try Tree.build(a, doc, 1000);
    defer reference.deinit(a);
    for ([_]u32{ 2, 4, 9, 0, 2, 9, 0, 4, 2, 9, 0, 0 }) |index| {
        try tree.toggle(a, index);
        reference.collapsed.toggle(index);
        try reference.refresh(a);
        try testing.expectEqualSlices(u32, reference.rows.items, tree.rows.items);
    }
}
