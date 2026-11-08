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
    /// Nodes inside this container, its closing node included. A closing
    /// node keeps its container's number of children in `key_len`.
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
    /// The deepest container's depth.
    max_depth: u16 = 0,
    /// The nodes a search found, in document order.
    hits: std.ArrayList(u32) = .empty,
    /// One bit per node: a search found it.
    hit_set: std.DynamicBitSetUnmanaged = .{},
    /// One bit per node: a container holding a hit.
    around: std.DynamicBitSetUnmanaged = .{},
    /// Rows are only the hits and the containers around them, held open.
    filtered: bool = false,

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
        var children: std.ArrayList(u32) = .empty;
        defer children.deinit(a);
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
            const closing = tok.kind == .rbrace or tok.kind == .rbracket;
            if (!closing and children.items.len > 0) children.items[children.items.len - 1] += 1;
            switch (tok.kind) {
                .rbrace, .rbracket => {
                    const start = open.pop().?;
                    t.nodes.items[start].skip = @intCast(t.nodes.items.len - start);
                    try t.nodes.append(a, .{ .kind = .close, .depth = depth - 1, .val_off = @intCast(tok.start), .val_len = 1, .key_len = children.pop().? });
                },
                .lbrace, .lbracket => {
                    t.max_depth = @max(t.max_depth, depth);
                    try children.append(a, 0);
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
        // The capacity was a guess from the text size; the tree is final now.
        @import("../utils/fit.zig").list(Node, a, &t.nodes);
        t.collapsed = try .initEmpty(a, t.nodes.items.len);
        t.hit_set = try .initEmpty(a, t.nodes.items.len);
        t.around = try .initEmpty(a, t.nodes.items.len);
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
        t.hits.deinit(a);
        t.hit_set.deinit(a);
        t.around.deinit(a);
    }

    pub fn isContainer(t: *const Tree, i: u32) bool {
        const k = t.nodes.items[i].kind;
        return k == .object or k == .array;
    }

    pub fn isCollapsed(t: *const Tree, i: u32) bool {
        return t.collapsed.isSet(i);
    }

    /// Container `i` shows its children: it's open, or a filter holds it.
    pub fn isOpen(t: *const Tree, i: u32) bool {
        return t.isContainer(i) and (t.isHeld(i) or !t.collapsed.isSet(i));
    }

    /// A filter holds container `i` open, around a hit.
    pub fn isHeld(t: *const Tree, i: u32) bool {
        return t.filtered and t.around.isSet(i);
    }

    pub fn refresh(t: *Tree, a: Allocator) !void {
        t.rows.clearRetainingCapacity();
        var i: u32 = 0;
        const n: u32 = @intCast(t.nodes.items.len);
        // Inside a hit, rows follow the usual rules up to its closing node.
        var plain_to: ?u32 = null;
        while (i < n) {
            if (plain_to) |end| if (i > end) {
                plain_to = null;
            };
            const node = t.nodes.items[i];
            if (!t.filtered or plain_to != null) {
                try t.rows.append(a, i);
                // Past a collapsed container and its closing node.
                if (t.isContainer(i) and t.collapsed.isSet(i)) i += node.skip;
            } else if (node.kind == .close or t.around.isSet(i)) {
                // Held open, showing only what leads to hits.
                try t.rows.append(a, i);
            } else if (t.hit_set.isSet(i)) {
                try t.rows.append(a, i);
                if (t.isContainer(i)) {
                    if (t.collapsed.isSet(i)) i += node.skip else plain_to = i + node.skip;
                }
            } else if (t.isContainer(i)) i += node.skip;
            i += 1;
        }
    }

    pub fn toggle(t: *Tree, a: Allocator, i: u32) !void {
        if (!t.isContainer(i) or t.isHeld(i)) return;
        if (t.filtered) {
            t.collapsed.toggle(i);
            return t.refresh(a);
        }
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
        try t.setLevel(a, if (collapsed) 1 else std.math.maxInt(u16));
    }

    /// Opens containers less than `level` deep and collapses the rest: at
    /// level 1 only the root's children show.
    pub fn setLevel(t: *Tree, a: Allocator, level: u16) !void {
        for (t.nodes.items, 0..) |n, i| {
            if (n.kind == .object or n.kind == .array) t.collapsed.setValue(i, n.depth >= level);
        }
        try t.refresh(a);
    }

    /// Shows only the hits and the containers around them, or everything.
    pub fn setFiltered(t: *Tree, a: Allocator, on: bool) !void {
        t.filtered = on;
        try t.refresh(a);
    }

    /// Replaces the hits (any order, repeats allowed), and the rows when
    /// filtering.
    pub fn setHits(t: *Tree, a: Allocator, found: []const u32) !void {
        t.hit_set.unsetAll();
        t.around.unsetAll();
        for (found) |i| t.hit_set.set(i);
        t.hits.clearRetainingCapacity();
        var it = t.hit_set.iterator(.{});
        while (it.next()) |i| try t.hits.append(a, @intCast(i));
        // One walk: the containers open on the way to a hit hold it.
        var open: std.ArrayList(u32) = .empty;
        defer open.deinit(a);
        var i: u32 = 0;
        const n: u32 = @intCast(t.nodes.items.len);
        while (i < n) : (i += 1) {
            if (t.nodes.items[i].kind == .close) {
                _ = open.pop();
                continue;
            }
            if (t.hit_set.isSet(i)) {
                var k = open.items.len;
                while (k > 0) {
                    k -= 1;
                    if (t.around.isSet(open.items[k])) break;
                    t.around.set(open.items[k]);
                }
            }
            if (t.isContainer(i)) try open.append(a, i);
        }
        if (t.filtered) try t.refresh(a);
    }

    /// Nodes with `query` in their key or value: inside the quotes for
    /// strings, as written for numbers, booleans and null.
    pub fn findText(t: *const Tree, a: Allocator, query: []const u8, case_sensitive: bool) ![]u32 {
        var found: std.ArrayList(u32) = .empty;
        errdefer found.deinit(a);
        if (query.len == 0) return found.toOwnedSlice(a);
        for (t.nodes.items, 0..) |n, at| {
            const i: u32 = @intCast(at);
            if (n.kind == .close) continue;
            if (locate(t.innerKey(i), query, case_sensitive) != null or locate(t.innerValue(i), query, case_sensitive) != null) try found.append(a, i);
        }
        return found.toOwnedSlice(a);
    }

    /// A key without its quotes.
    pub fn innerKey(t: *const Tree, i: u32) []const u8 {
        const k = t.key(i);
        return if (k.len >= 2) k[1 .. k.len - 1] else k;
    }

    /// A scalar as written, without a string's quotes; empty for containers.
    pub fn innerValue(t: *const Tree, i: u32) []const u8 {
        if (t.isContainer(i) or t.nodes.items[i].kind == .close) return "";
        const v = t.value(i);
        return if (t.nodes.items[i].kind == .string and v.len >= 2) v[1 .. v.len - 1] else v;
    }

    /// The container node `i` is in, or null for the root.
    pub fn parentOf(t: *const Tree, i: u32) ?u32 {
        const depth = t.nodes.items[i].depth;
        if (depth == 0) return null;
        var j = i;
        while (j > 0) {
            j -= 1;
            const n = t.nodes.items[j];
            if (n.depth == depth - 1 and n.kind != .close) return j;
        }
        return null;
    }

    /// The first child of container `i`; then `nextSibling` gives each
    /// next one, and null after the last.
    pub fn firstChild(t: *const Tree, i: u32) ?u32 {
        if (!t.isContainer(i) or t.nodes.items[i + 1].kind == .close) return null;
        return i + 1;
    }
    pub fn nextSibling(t: *const Tree, i: u32) ?u32 {
        const next = i + (if (t.isContainer(i)) t.nodes.items[i].skip else 0) + 1;
        if (next >= t.nodes.items.len or t.nodes.items[next].kind == .close) return null;
        return next;
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
        if (n.kind == .close) return "";
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

    /// Opens container `i` and everything inside it, or (`collapsed`) keeps
    /// `i` open and collapses every container inside it.
    pub fn setSubtree(t: *Tree, a: Allocator, i: u32, collapsed: bool) !void {
        if (!t.isContainer(i)) return;
        t.collapsed.unset(i);
        const end = i + t.nodes.items[i].skip;
        var j = i + 1;
        while (j < end) : (j += 1) if (t.isContainer(j)) t.collapsed.setValue(j, collapsed);
        try t.refresh(a);
    }

    /// The JSONPath of node `i`, as `$.data[0]["first name"]`: names that
    /// are plain identifiers follow a dot, others keep their JSON quoting.
    pub fn path(t: *const Tree, a: Allocator, i: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '$');
        var parent: u32 = 0;
        while (parent != i and t.isContainer(parent)) {
            const end = parent + t.nodes.items[parent].skip;
            var child = parent + 1;
            var index: usize = 0;
            const found = while (child < end) {
                const last = if (t.isContainer(child)) child + t.nodes.items[child].skip else child;
                if (i >= child and i <= last) break child;
                child = last + 1;
                index += 1;
            } else break;
            if (t.nodes.items[parent].kind == .array) {
                try out.print(a, "[{d}]", .{index});
            } else {
                const name = t.key(found);
                const bare = if (name.len >= 2) name[1 .. name.len - 1] else name;
                if (identifier(bare)) try out.print(a, ".{s}", .{bare}) else try out.print(a, "[{s}]", .{name});
            }
            parent = found;
        }
        return out.toOwnedSlice(a);
    }

    fn identifier(name: []const u8) bool {
        if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
        for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '$') return false;
        return true;
    }

    /// How many direct children a container has.
    pub fn childCount(t: *const Tree, i: u32) usize {
        return t.nodes.items[i + t.nodes.items[i].skip].key_len;
    }

    /// A string's text without quotes or escapes; anything else as written,
    /// a container as its whole source.
    pub fn plainValue(t: *const Tree, a: Allocator, i: u32) ![]const u8 {
        if (t.nodes.items[i].kind != .string) return t.sourceOf(i);
        return unescape(a, t.value(i));
    }
};

/// A JSON string literal's text: quotes removed, escapes decoded. A lone
/// surrogate becomes U+FFFD.
pub fn unescape(a: Allocator, literal: []const u8) ![]const u8 {
    const inner = if (literal.len >= 2 and literal[0] == '"') literal[1 .. literal.len - 1] else literal;
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var out: std.ArrayList(u8) = try .initCapacity(a, inner.len);
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch != '\\' or i + 1 >= inner.len) {
            try out.append(a, ch);
            i += 1;
            continue;
        }
        const e = inner[i + 1];
        i += 2;
        switch (e) {
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            'r' => try out.append(a, '\r'),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'u' => {
                var cp: u21 = hex4(inner, i) orelse {
                    try out.appendSlice(a, "\\u");
                    continue;
                };
                i += 4;
                if (cp >= 0xD800 and cp < 0xDC00 and i + 6 <= inner.len and inner[i] == '\\' and inner[i + 1] == 'u') {
                    if (hex4(inner, i + 2)) |low| if (low >= 0xDC00 and low < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        i += 6;
                    };
                }
                if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(a, buf[0..len]);
            },
            else => try out.append(a, e),
        }
    }
    return out.toOwnedSlice(a);
}

fn hex4(s: []const u8, at: usize) ?u21 {
    if (at + 4 > s.len) return null;
    return std.fmt.parseInt(u21, s[at..][0..4], 16) catch null;
}

/// Where `query` is in `text`, if it is.
pub fn locate(text: []const u8, query: []const u8, case_sensitive: bool) ?usize {
    if (query.len == 0) return null;
    return if (case_sensitive) std.mem.indexOf(u8, text, query) else std.ascii.findIgnoreCase(text, query);
}

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

test "paths name each node from the root" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    const cases = [_]struct { u32, []const u8 }{ .{ 0, "$" }, .{ 1, "$.a" }, .{ 3, "$.b[0]" }, .{ 5, "$.b[1].c" }, .{ 6, "$.b[1]" }, .{ 8, "$.d" }, .{ 9, "$.e" } };
    for (cases) |case| {
        const p = try t.path(a, case[0]);
        defer a.free(p);
        try testing.expectEqualStrings(case[1], p);
    }
    var quoted = try Tree.build(a, "{\"first name\":1,\"9x\":[[2]]}", 1000);
    defer quoted.deinit(a);
    const p1 = try quoted.path(a, 1);
    defer a.free(p1);
    try testing.expectEqualStrings("$[\"first name\"]", p1);
    const p2 = try quoted.path(a, 4);
    defer a.free(p2);
    try testing.expectEqualStrings("$[\"9x\"][0][0]", p2);
}

test "subtree expand and collapse leave the rest alone" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    try t.setAll(a, true);
    try t.setSubtree(a, 2, false);
    try testing.expect(!t.isCollapsed(2) and !t.isCollapsed(4));
    try testing.expect(t.isCollapsed(9));
    try t.setSubtree(a, 2, true);
    try testing.expect(!t.isCollapsed(2) and t.isCollapsed(4));
    try testing.expectEqual(@as(usize, 9), t.rows.items.len);
}

test "child counts, depth and levels" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    try testing.expectEqual(@as(usize, 4), t.childCount(0));
    try testing.expectEqual(@as(usize, 1), t.childCount(4));
    try testing.expectEqual(@as(usize, 0), t.childCount(9));
    try testing.expectEqual(@as(u16, 2), t.max_depth);
    try testing.expectEqualStrings("", t.key(7));
    try t.setLevel(a, 2);
    try testing.expect(!t.isCollapsed(0) and !t.isCollapsed(2) and t.isCollapsed(4));
    try t.setLevel(a, 0);
    try testing.expectEqual(@as(usize, 1), t.rows.items.len);
    try testing.expectEqual(@as(?u32, 2), t.parentOf(4));
    try testing.expectEqual(@as(?u32, null), t.parentOf(0));
    try testing.expectEqual(@as(?u32, 2), t.nextSibling(1));
    try testing.expectEqual(@as(?u32, null), t.nextSibling(9));
    try testing.expectEqual(@as(?u32, null), t.firstChild(9));
}

test "search finds keys and values, and filtering shows them with their containers" {
    const a = testing.allocator;
    var t = try Tree.build(a, doc, 1000);
    defer t.deinit(a);
    const found = try t.findText(a, "C", false);
    defer a.free(found);
    // The key "c" and nothing else; quotes don't match.
    try testing.expectEqualSlices(u32, &.{5}, found);
    const none = try t.findText(a, "\"", false);
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try t.setAll(a, true);
    try t.setHits(a, found);
    try t.setFiltered(a, true);
    // { b [ { c } ] }: the containers around the hit are held open.
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 5, 6, 7, 11 }, t.rows.items);
    try testing.expect(t.isOpen(4) and t.isHeld(4));
    // A hit container shows as usual inside.
    try t.setHits(a, &.{2});
    try testing.expectEqualSlices(u32, &.{ 0, 2, 11 }, t.rows.items);
    try t.toggle(a, 2);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4, 7, 11 }, t.rows.items);
    try t.setFiltered(a, false);
    try testing.expectEqual(@as(usize, 9), t.rows.items.len);
}

test "plain values unescape strings" {
    const a = testing.allocator;
    var t = try Tree.build(a, "[\"a\\n\\u00e9\\ud83d\\ude00\\\"\",1,{}]", 100);
    defer t.deinit(a);
    const text = try t.plainValue(a, 1);
    defer a.free(text);
    try testing.expectEqualStrings("a\n\u{e9}\u{1f600}\"", text);
    try testing.expectEqualStrings("1", try t.plainValue(a, 2));
    try testing.expectEqualStrings("{}", try t.plainValue(a, 3));
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
