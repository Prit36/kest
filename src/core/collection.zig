//! The tree the sidebar shows: collections of folders of requests. Nodes hold
//! only what the tree draws (a name, a method): a request's headers and body
//! stay on disk until its tab opens, so 10 000 requests cost about a megabyte.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { collection, folder, request };

/// Hex of 8 random bytes: safe as a file name, unique enough for one person.
pub const Id = [16]u8;

pub fn newId(io: std.Io) Id {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Whether `s` could be one of our ids: nothing else ever reaches a path.
pub fn validId(s: []const u8) bool {
    if (s.len != 16) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub const Node = struct {
    id: Id,
    kind: Kind,
    name: []u8,
    description: []u8 = &.{},
    /// A request's method, for the tree.
    method: []u8 = &.{},
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,
    expanded: bool = false,

    /// The collection this node is in (itself, for one).
    pub fn root(n: *Node) *Node {
        var cur = n;
        while (cur.parent) |p| cur = p;
        return cur;
    }

    pub fn indexInParent(n: *const Node) ?usize {
        const p = n.parent orelse return null;
        return std.mem.indexOfScalar(*Node, p.children.items, @constCast(n));
    }

    /// Whether `other` is `n` or below it.
    pub fn contains(n: *const Node, other: *const Node) bool {
        var cur: ?*const Node = other;
        while (cur) |c| : (cur = c.parent) if (c == n) return true;
        return false;
    }

    pub fn countRequests(n: *const Node) usize {
        var total: usize = if (n.kind == .request) 1 else 0;
        for (n.children.items) |c| total += c.countRequests();
        return total;
    }

    pub fn find(n: *Node, id: []const u8) ?*Node {
        if (std.mem.eql(u8, &n.id, id)) return n;
        for (n.children.items) |c| if (c.find(id)) |f| return f;
        return null;
    }
};

pub fn create(a: Allocator, id: Id, kind: Kind, name: []const u8, method: []const u8) !*Node {
    const n = try a.create(Node);
    errdefer a.destroy(n);
    const owned = try a.dupe(u8, name);
    errdefer a.free(owned);
    n.* = .{ .id = id, .kind = kind, .name = owned, .method = try a.dupe(u8, method) };
    return n;
}

pub fn destroy(a: Allocator, n: *Node) void {
    for (n.children.items) |c| destroy(a, c);
    n.children.deinit(a);
    a.free(n.name);
    a.free(n.description);
    a.free(n.method);
    a.destroy(n);
}

pub fn setString(a: Allocator, field: *[]u8, value: []const u8) !void {
    const copy = try a.dupe(u8, value);
    a.free(field.*);
    field.* = copy;
}

pub fn append(a: Allocator, parent: *Node, child: *Node) !void {
    try parent.children.append(a, child);
    child.parent = parent;
}

/// Takes `n` out of its parent; the caller owns it now.
pub fn detach(n: *Node) void {
    if (n.indexInParent()) |i| _ = n.parent.?.children.orderedRemove(i);
    n.parent = null;
}

pub const MoveError = error{ IntoItself, BadTarget, OutOfMemory };

/// Moves `n` to be child `index` of `target`. Requests go into folders and
/// collections; folders too, but not into themselves; collections don't move.
pub fn move(a: Allocator, n: *Node, target: *Node, index_in: usize) MoveError!void {
    if (n.kind == .collection or target.kind == .request) return error.BadTarget;
    if (n.contains(target)) return error.IntoItself;
    var index = index_in;
    // Moving down within one parent: the removal shifts the place.
    if (n.parent == target) if (n.indexInParent()) |at| {
        if (at < index) index -= 1;
    };
    try target.children.ensureUnusedCapacity(a, 1);
    detach(n);
    target.children.insertAssumeCapacity(@min(index, target.children.items.len), n);
    n.parent = target;
}

/// Moves `n` one place up or down among its siblings.
pub fn reorder(n: *Node, delta: i32) bool {
    const p = n.parent orelse return false;
    const at = n.indexInParent() orelse return false;
    const to = @as(i64, @intCast(at)) + delta;
    if (to < 0 or to >= p.children.items.len) return false;
    std.mem.swap(*Node, &p.children.items[at], &p.children.items[@intCast(to)]);
    return true;
}

/// A deep copy with new ids. `visit` sees each (source, copy) pair of
/// requests, whose files must be copied too.
pub fn clone(a: Allocator, io: std.Io, n: *const Node, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *const Node, *const Node) void) error{OutOfMemory}!*Node {
    const copy = try create(a, newId(io), n.kind, n.name, n.method);
    errdefer destroy(a, copy);
    copy.description = try a.dupe(u8, n.description);
    copy.expanded = n.expanded;
    for (n.children.items) |c| {
        const cc = try clone(a, io, c, ctx, visit);
        try append(a, copy, cc);
    }
    if (n.kind == .request) visit(ctx, n, copy);
    return copy;
}

/// One line of the tree.
pub const Row = struct { node: *Node, depth: u16 };

fn matches(n: *const Node, query: []const u8) bool {
    return std.ascii.findIgnoreCase(n.name, query) != null or
        (n.kind == .request and std.ascii.findIgnoreCase(n.method, query) != null);
}

/// Whether `n` or anything below it matches.
fn anyMatch(n: *const Node, query: []const u8) bool {
    if (matches(n, query)) return true;
    for (n.children.items) |c| if (anyMatch(c, query)) return true;
    return false;
}

/// The lines of the tree: open folders' contents; or with a query, what
/// matches and the folders around it, open.
pub fn flatten(a: Allocator, roots: []const *Node, query: []const u8, out: *std.ArrayList(Row)) !void {
    out.clearRetainingCapacity();
    for (roots) |r| try flattenInto(a, r, 0, query, out);
}

fn flattenInto(a: Allocator, n: *Node, depth: u16, query: []const u8, out: *std.ArrayList(Row)) Allocator.Error!void {
    if (query.len > 0 and !anyMatch(n, query)) return;
    try out.append(a, .{ .node = n, .depth = depth });
    if (query.len > 0 and matches(n, query) and n.kind != .request) {
        // A matching folder shows what's in it, by its own open state.
        if (!n.expanded) return;
        for (n.children.items) |c| try flattenInto(a, c, depth + 1, "", out);
        return;
    }
    if (query.len == 0 and !n.expanded) return;
    for (n.children.items) |c| try flattenInto(a, c, depth + 1, query, out);
}

const t = std.testing;

fn fixture(a: Allocator) !*Node {
    const io = t.io;
    const c = try create(a, newId(io), .collection, "API", "");
    c.expanded = true;
    const users = try create(a, newId(io), .folder, "Users", "");
    users.expanded = true;
    try append(a, c, users);
    try append(a, users, try create(a, newId(io), .request, "List users", "GET"));
    try append(a, users, try create(a, newId(io), .request, "Create user", "POST"));
    try append(a, c, try create(a, newId(io), .request, "Health", "GET"));
    return c;
}

test "flatten follows open folders" {
    const a = t.allocator;
    const c = try fixture(a);
    defer destroy(a, c);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    try flatten(a, &.{c}, "", &rows);
    try t.expectEqual(@as(usize, 5), rows.items.len);
    try t.expectEqual(@as(u16, 2), rows.items[2].depth);
    c.children.items[0].expanded = false;
    try flatten(a, &.{c}, "", &rows);
    try t.expectEqual(@as(usize, 3), rows.items.len);
}

test "search opens what matches, whatever is collapsed" {
    const a = t.allocator;
    const c = try fixture(a);
    defer destroy(a, c);
    c.children.items[0].expanded = false;
    c.expanded = false;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    try flatten(a, &.{c}, "create", &rows);
    try t.expectEqual(@as(usize, 3), rows.items.len);
    try t.expectEqualStrings("Create user", rows.items[2].node.name);
    try flatten(a, &.{c}, "post", &rows);
    try t.expectEqual(@as(usize, 3), rows.items.len);
    try flatten(a, &.{c}, "nothing", &rows);
    try t.expectEqual(@as(usize, 0), rows.items.len);
}

test "moving and reordering" {
    const a = t.allocator;
    const c = try fixture(a);
    defer destroy(a, c);
    const users = c.children.items[0];
    const health = c.children.items[1];
    const list = users.children.items[0];
    try move(a, health, users, 1);
    try t.expectEqual(@as(usize, 1), c.children.items.len);
    try t.expectEqualStrings("Health", users.children.items[1].name);
    try t.expectEqual(users, health.parent.?);
    // Within one parent, downward: the last place.
    try move(a, list, users, 3);
    try t.expectEqualStrings("List users", users.children.items[2].name);
    try t.expect(reorder(list, -1));
    try t.expectEqualStrings("List users", users.children.items[1].name);
    try t.expect(!reorder(users.children.items[0], -1));
    try t.expectError(error.IntoItself, move(a, users, users, 0));
    try t.expectError(error.BadTarget, move(a, c, users, 0));
    try t.expectError(error.BadTarget, move(a, users, list, 0));
    try t.expectEqual(@as(usize, 3), c.countRequests());
}

test "cloning makes new ids" {
    const a = t.allocator;
    const c = try fixture(a);
    defer destroy(a, c);
    var seen: usize = 0;
    const Visit = struct {
        fn f(count: *usize, from: *const Node, to: *const Node) void {
            count.* += 1;
            std.debug.assert(!std.mem.eql(u8, &from.id, &to.id));
        }
    };
    const copy = try clone(a, t.io, c, &seen, Visit.f);
    defer destroy(a, copy);
    try t.expectEqual(@as(usize, 3), seen);
    try t.expectEqual(@as(usize, 3), copy.countRequests());
    try t.expect(c.find(&copy.id) == null);
}

test "ids" {
    const id = newId(t.io);
    try t.expect(validId(&id));
    try t.expect(!validId("../../etc/passwd"));
    try t.expect(!validId("ABCDEF0123456789"));
}
