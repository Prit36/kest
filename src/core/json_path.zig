//! JSONPath queries over a `json_tree.Tree`: `$`, `.name`, `['name']`,
//! `[0]`, `[-1]`, `[0,2]`, `[1:3]`, `*`, `..` (any depth) and filters such
//! as `[?(@.price < 10 && @.tags)]`. Results are node indices in document
//! order, without repeats.
const std = @import("std");
const json_tree = @import("json_tree.zig");
const Tree = json_tree.Tree;
const Allocator = std.mem.Allocator;

pub const Problem = struct { at: usize = 0, message: []const u8 = "" };
pub const Error = error{ InvalidPath, OutOfMemory };

/// A query is JSONPath when it starts with `$`; otherwise it's plain text.
pub fn isPath(query: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, query, " \t");
    return trimmed.len > 0 and trimmed[0] == '$';
}

pub fn evaluate(a: Allocator, tree: *const Tree, query: []const u8, problem: *Problem) Error![]u32 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var p: Parser = .{ .src = query, .problem = problem, .a = scratch };
    p.space();
    if (!p.eat('$')) return p.fail("A path starts with $");
    var current: std.ArrayList(u32) = .empty;
    if (tree.nodes.items.len > 0) try current.append(scratch, 0);
    while (true) {
        p.space();
        if (p.done()) break;
        var deep = false;
        if (p.eatText("..")) {
            deep = true;
        } else if (!p.eat('.') and p.peek() != '[') return p.fail("Expected . or [");
        var items: []const Item = undefined;
        if (p.peek() == '[') {
            items = try p.bracket();
        } else if (p.eat('*')) {
            items = try scratch.dupe(Item, &.{.wildcard});
        } else {
            const name = p.name();
            if (name.len == 0) return p.fail("Expected a name");
            items = try scratch.dupe(Item, &.{.{ .name = name }});
        }
        const base = if (deep) try descendants(scratch, tree, current.items) else current.items;
        var next: std.DynamicBitSetUnmanaged = try .initEmpty(scratch, tree.nodes.items.len);
        for (base) |node| for (items) |item| try select(tree, scratch, node, item, &next);
        current.clearRetainingCapacity();
        var it = next.iterator(.{});
        while (it.next()) |i| try current.append(scratch, @intCast(i));
    }
    return a.dupe(u32, current.items);
}

const Slice = struct { start: ?i64, end: ?i64, step: i64 };
const Item = union(enum) {
    name: []const u8,
    index: i64,
    slice: Slice,
    wildcard,
    filter: *const Expr,
};

const Op = enum { eq, ne, lt, le, gt, ge };
const Operand = union(enum) {
    /// `@` and the steps after it: names and indices.
    relative: []const Step,
    number: f64,
    string: []const u8,
    boolean: bool,
    null_,
};
const Step = union(enum) { name: []const u8, index: i64 };
const Expr = union(enum) {
    any: [2]*const Expr,
    all: [2]*const Expr,
    not: *const Expr,
    exists: Operand,
    compare: struct { left: Operand, op: Op, right: Operand },
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    problem: *Problem,
    a: Allocator,

    fn fail(p: *Parser, message: []const u8) Error {
        p.problem.* = .{ .at = p.pos, .message = message };
        return error.InvalidPath;
    }
    fn done(p: *const Parser) bool {
        return p.pos >= p.src.len;
    }
    fn peek(p: *const Parser) u8 {
        return if (p.done()) 0 else p.src[p.pos];
    }
    fn eat(p: *Parser, ch: u8) bool {
        if (p.peek() != ch) return false;
        p.pos += 1;
        return true;
    }
    fn eatText(p: *Parser, text: []const u8) bool {
        if (!std.mem.startsWith(u8, p.src[p.pos..], text)) return false;
        p.pos += text.len;
        return true;
    }
    fn space(p: *Parser) void {
        while (p.peek() == ' ' or p.peek() == '\t') p.pos += 1;
    }
    fn expect(p: *Parser, ch: u8, message: []const u8) Error!void {
        p.space();
        if (!p.eat(ch)) return p.fail(message);
    }
    /// Letters, digits, `_`, `$`, `-` and anything beyond ASCII.
    fn name(p: *Parser) []const u8 {
        const start = p.pos;
        while (!p.done()) {
            const ch = p.src[p.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '$' or ch >= 0x80) p.pos += 1 else break;
        }
        return p.src[start..p.pos];
    }
    fn integer(p: *Parser) ?i64 {
        p.space();
        const start = p.pos;
        if (p.peek() == '-') p.pos += 1;
        while (std.ascii.isDigit(p.peek())) p.pos += 1;
        const text = p.src[start..p.pos];
        const value = std.fmt.parseInt(i64, text, 10) catch {
            p.pos = start;
            return null;
        };
        return value;
    }
    fn quoted(p: *Parser) Error!?[]const u8 {
        p.space();
        const quote = p.peek();
        if (quote != '\'' and quote != '"') return null;
        p.pos += 1;
        const start = p.pos;
        while (!p.done() and p.src[p.pos] != quote) : (p.pos += 1) {
            if (p.src[p.pos] == '\\') p.pos += 1;
        }
        if (p.done()) return p.fail("Unclosed quote");
        const raw = p.src[start..p.pos];
        p.pos += 1;
        // Single-quoted names may contain a double quote unescaped.
        if (quote == '\'' and std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        return try json_tree.unescape(p.a, raw);
    }

    /// `[...]`: a union of names, indices, slices, `*` or one filter.
    fn bracket(p: *Parser) Error![]const Item {
        p.pos += 1;
        var items: std.ArrayList(Item) = .empty;
        while (true) {
            p.space();
            if (p.eat('*')) {
                try items.append(p.a, .wildcard);
            } else if (p.eat('?')) {
                p.space();
                const wrapped = p.eat('(');
                const expr = try p.any();
                if (wrapped) try p.expect(')', "Expected )");
                try items.append(p.a, .{ .filter = expr });
            } else if (try p.quoted()) |text| {
                try items.append(p.a, .{ .name = text });
            } else {
                const start = p.integer();
                p.space();
                if (p.eat(':')) {
                    const end = p.integer();
                    var step: i64 = 1;
                    p.space();
                    if (p.eat(':')) step = p.integer() orelse 1;
                    if (step <= 0) return p.fail("A slice step is at least 1");
                    try items.append(p.a, .{ .slice = .{ .start = start, .end = end, .step = step } });
                } else if (start) |index| {
                    try items.append(p.a, .{ .index = index });
                } else return p.fail("Expected a name, index, slice, * or filter");
            }
            p.space();
            if (p.eat(']')) break;
            if (!p.eat(',')) return p.fail("Expected , or ]");
        }
        return items.toOwnedSlice(p.a);
    }

    fn node(p: *Parser, value: Expr) Error!*const Expr {
        const e = try p.a.create(Expr);
        e.* = value;
        return e;
    }
    fn any(p: *Parser) Error!*const Expr {
        var left = try p.all();
        while (true) {
            p.space();
            if (!p.eatText("||")) return left;
            left = try p.node(.{ .any = .{ left, try p.all() } });
        }
    }
    fn all(p: *Parser) Error!*const Expr {
        var left = try p.unary();
        while (true) {
            p.space();
            if (!p.eatText("&&")) return left;
            left = try p.node(.{ .all = .{ left, try p.unary() } });
        }
    }
    fn unary(p: *Parser) Error!*const Expr {
        p.space();
        if (p.peek() == '!' and !std.mem.startsWith(u8, p.src[p.pos..], "!=")) {
            p.pos += 1;
            return p.node(.{ .not = try p.unary() });
        }
        if (p.eat('(')) {
            const inner = try p.any();
            try p.expect(')', "Expected )");
            return inner;
        }
        const left = try p.operand();
        p.space();
        const ops = [_]struct { []const u8, Op }{ .{ "==", .eq }, .{ "!=", .ne }, .{ "<=", .le }, .{ ">=", .ge }, .{ "<", .lt }, .{ ">", .gt }, .{ "=", .eq } };
        for (ops) |entry| if (p.eatText(entry[0])) {
            return p.node(.{ .compare = .{ .left = left, .op = entry[1], .right = try p.operand() } });
        };
        return p.node(.{ .exists = left });
    }
    fn operand(p: *Parser) Error!Operand {
        p.space();
        if (p.eat('@')) {
            var steps: std.ArrayList(Step) = .empty;
            while (true) {
                if (p.eat('.')) {
                    const text = p.name();
                    if (text.len == 0) return p.fail("Expected a name");
                    try steps.append(p.a, .{ .name = text });
                } else if (p.peek() == '[') {
                    p.pos += 1;
                    if (try p.quoted()) |text| {
                        try steps.append(p.a, .{ .name = text });
                    } else if (p.integer()) |index| {
                        try steps.append(p.a, .{ .index = index });
                    } else return p.fail("Expected a name or index");
                    try p.expect(']', "Expected ]");
                } else break;
            }
            return .{ .relative = try steps.toOwnedSlice(p.a) };
        }
        if (try p.quoted()) |text| return .{ .string = text };
        if (p.eatText("true")) return .{ .boolean = true };
        if (p.eatText("false")) return .{ .boolean = false };
        if (p.eatText("null")) return .null_;
        const start = p.pos;
        while (!p.done() and (std.ascii.isDigit(p.src[p.pos]) or std.mem.indexOfScalar(u8, "+-.eE", p.src[p.pos]) != null)) p.pos += 1;
        if (std.fmt.parseFloat(f64, p.src[start..p.pos])) |n| return .{ .number = n } else |_| {}
        p.pos = start;
        return p.fail("Expected @, a number, a quoted string, true, false or null");
    }
};

/// Every node in each subtree, the subtree's root included.
fn descendants(a: Allocator, tree: *const Tree, roots: []const u32) Error![]const u32 {
    var set: std.DynamicBitSetUnmanaged = try .initEmpty(a, tree.nodes.items.len);
    for (roots) |root| {
        const end = root + (if (tree.isContainer(root)) tree.nodes.items[root].skip else 0);
        var i = root;
        while (i <= end) : (i += 1) if (tree.nodes.items[i].kind != .close) set.set(i);
    }
    var out: std.ArrayList(u32) = .empty;
    var it = set.iterator(.{});
    while (it.next()) |i| try out.append(a, @intCast(i));
    return out.items;
}

fn select(tree: *const Tree, a: Allocator, parent: u32, item: Item, out: *std.DynamicBitSetUnmanaged) Error!void {
    const kind = tree.nodes.items[parent].kind;
    switch (item) {
        .name => |name| if (kind == .object) {
            if (child(tree, parent, name)) |c| out.set(c);
        },
        .index => |index| if (kind == .array) {
            if (nth(tree, parent, index)) |c| out.set(c);
        },
        .wildcard => {
            var c = tree.firstChild(parent);
            while (c) |i| : (c = tree.nextSibling(i)) out.set(i);
        },
        .slice => |s| if (kind == .array) {
            const len: i64 = @intCast(tree.childCount(parent));
            const start = clampIndex(s.start orelse 0, len);
            const end = clampIndex(s.end orelse len, len);
            var at: i64 = 0;
            var c = tree.firstChild(parent);
            while (c) |i| : (c = tree.nextSibling(i)) {
                if (at >= end) break;
                if (at >= start and @mod(at - start, s.step) == 0) out.set(i);
                at += 1;
            }
        },
        .filter => |expr| {
            var c = tree.firstChild(parent);
            while (c) |i| : (c = tree.nextSibling(i)) if (try test_(tree, a, expr, i)) out.set(i);
        },
    }
}

fn clampIndex(index: i64, len: i64) i64 {
    const value = if (index < 0) len + index else index;
    return std.math.clamp(value, 0, len);
}

/// The member of object `parent` named `name` (its text, unescaped).
fn child(tree: *const Tree, parent: u32, name: []const u8) ?u32 {
    var buf: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    var c = tree.firstChild(parent);
    while (c) |i| : (c = tree.nextSibling(i)) {
        const raw = tree.innerKey(i);
        if (std.mem.eql(u8, raw, name)) return i;
        if (std.mem.indexOfScalar(u8, raw, '\\') != null) {
            fixed.reset();
            const text = json_tree.unescape(fixed.allocator(), tree.key(i)) catch continue;
            if (std.mem.eql(u8, text, name)) return i;
        }
    }
    return null;
}

fn nth(tree: *const Tree, parent: u32, index: i64) ?u32 {
    const len: i64 = @intCast(tree.childCount(parent));
    const at = if (index < 0) len + index else index;
    if (at < 0 or at >= len) return null;
    var c = tree.firstChild(parent);
    var k: i64 = 0;
    while (c) |i| : (c = tree.nextSibling(i)) {
        if (k == at) return i;
        k += 1;
    }
    return null;
}

const Value = union(enum) { missing, number: f64, string: []const u8, boolean: bool, null_, container };

fn resolve(tree: *const Tree, a: Allocator, operand: Operand, at: u32) Error!Value {
    return switch (operand) {
        .number => |n| .{ .number = n },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .boolean = b },
        .null_ => .null_,
        .relative => |steps| {
            var node = at;
            for (steps) |step| {
                const found = switch (step) {
                    .name => |name| if (tree.nodes.items[node].kind == .object) child(tree, node, name) else null,
                    .index => |index| if (tree.nodes.items[node].kind == .array) nth(tree, node, index) else null,
                };
                node = found orelse return .missing;
            }
            return switch (tree.nodes.items[node].kind) {
                .number => .{ .number = std.fmt.parseFloat(f64, tree.value(node)) catch return .missing },
                .string => .{ .string = try json_tree.unescape(a, tree.value(node)) },
                .boolean => .{ .boolean = tree.value(node)[0] == 't' },
                .null_ => .null_,
                else => .container,
            };
        },
    };
}

fn test_(tree: *const Tree, a: Allocator, expr: *const Expr, at: u32) Error!bool {
    return switch (expr.*) {
        .any => |pair| try test_(tree, a, pair[0], at) or try test_(tree, a, pair[1], at),
        .all => |pair| try test_(tree, a, pair[0], at) and try test_(tree, a, pair[1], at),
        .not => |inner| !try test_(tree, a, inner, at),
        .exists => |operand| switch (try resolve(tree, a, operand, at)) {
            .missing => false,
            // `@.flag` tests that it exists; a bare `false` is false.
            .boolean => |b| operand == .relative or b,
            else => true,
        },
        .compare => |cmp| compare(try resolve(tree, a, cmp.left, at), cmp.op, try resolve(tree, a, cmp.right, at)),
    };
}

fn compare(left: Value, op: Op, right: Value) bool {
    // Only numbers with numbers and strings with strings have an order.
    const order: ?std.math.Order = switch (left) {
        .number => |l| if (right == .number) std.math.order(l, right.number) else null,
        .string => |l| if (right == .string) std.mem.order(u8, l, right.string) else null,
        else => null,
    };
    const equal = switch (left) {
        .number, .string => order == .eq,
        .boolean => |l| right == .boolean and l == right.boolean,
        .null_ => right == .null_,
        else => false,
    };
    return switch (op) {
        .eq => equal,
        .ne => !equal,
        .lt => order == .lt,
        .le => order != null and order != .gt,
        .gt => order == .gt,
        .ge => order != null and order != .lt,
    };
}

const testing = std.testing;
const doc =
    \\{"store":{"book":[{"title":"A","price":8.95,"tags":["x"]},{"title":"B","price":12.99},{"title":"C","price":8.99,"isbn":"0-553"}],"bicycle":{"color":"red","price":19.95}},"first name":"Ann"}
;

fn expectPath(tree: *const Tree, query: []const u8, want: []const []const u8) !void {
    var problem: Problem = .{};
    const found = try evaluate(testing.allocator, tree, query, &problem);
    defer testing.allocator.free(found);
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(testing.allocator);
    for (found) |i| try got.append(testing.allocator, tree.sourceOf(i));
    if (got.items.len != want.len) {
        std.debug.print("{s}: got {d} results\n", .{ query, got.items.len });
        return error.TestUnexpectedResult;
    }
    for (want, got.items) |w, g| try testing.expectEqualStrings(w, g);
}

test "names, indices, slices, wildcards and descent" {
    var tree = try Tree.build(testing.allocator, doc, 1000);
    defer tree.deinit(testing.allocator);
    try expectPath(&tree, "$.store.bicycle.color", &.{"\"red\""});
    try expectPath(&tree, "$['first name']", &.{"\"Ann\""});
    try expectPath(&tree, "$.store.book[-1].title", &.{"\"C\""});
    try expectPath(&tree, "$.store.book[0,2].title", &.{ "\"A\"", "\"C\"" });
    try expectPath(&tree, "$.store.book[:2].title", &.{ "\"A\"", "\"B\"" });
    try expectPath(&tree, "$.store.book[*].price", &.{ "8.95", "12.99", "8.99" });
    try expectPath(&tree, "$..price", &.{ "8.95", "12.99", "8.99", "19.95" });
    try expectPath(&tree, "$.store.*.color", &.{"\"red\""});
    try expectPath(&tree, "$..book[1].title", &.{"\"B\""});
    try expectPath(&tree, "$", &.{doc});
}

test "filters compare, combine and test for members" {
    var tree = try Tree.build(testing.allocator, doc, 1000);
    defer tree.deinit(testing.allocator);
    try expectPath(&tree, "$.store.book[?(@.price < 10)].title", &.{ "\"A\"", "\"C\"" });
    try expectPath(&tree, "$.store.book[?(@.isbn)].title", &.{"\"C\""});
    try expectPath(&tree, "$.store.book[?(!@.isbn && @.price > 9)].title", &.{"\"B\""});
    try expectPath(&tree, "$..book[?(@.title == 'B' || @.tags[0] == \"x\")].price", &.{ "8.95", "12.99" });
    try expectPath(&tree, "$..[?(@.color)]", &.{"{\"color\":\"red\",\"price\":19.95}"});
}

test "malformed paths say where" {
    var tree = try Tree.build(testing.allocator, doc, 1000);
    defer tree.deinit(testing.allocator);
    var problem: Problem = .{};
    try testing.expectError(error.InvalidPath, evaluate(testing.allocator, &tree, "store", &problem));
    try testing.expectEqual(@as(usize, 0), problem.at);
    try testing.expectError(error.InvalidPath, evaluate(testing.allocator, &tree, "$.store[0", &problem));
    try testing.expectEqual(@as(usize, 9), problem.at);
    try testing.expectError(error.InvalidPath, evaluate(testing.allocator, &tree, "$[?(@.a ~ 1)]", &problem));
    try testing.expect(isPath("  $.a") and !isPath("a.$"));
}
