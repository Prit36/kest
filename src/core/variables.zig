//! `{{name}}` substitution. One pass: values aren't expanded again, so there
//! is no inheritance to reason about and no cycle to guard against.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Var = @import("environment.zig").Var;

pub const Reference = struct {
    /// The whole `{{...}}`, in the text given.
    start: usize,
    end: usize,
    /// Trimmed name, within the text.
    name: []const u8,
};

/// The next well-formed reference at or after `from`.
pub fn nextReference(s: []const u8, from: usize) ?Reference {
    var i = from;
    while (std.mem.indexOfPos(u8, s, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, s, open + 2, "}}") orelse return null;
        const name = std.mem.trim(u8, s[open + 2 .. close], " \t");
        if (name.len > 0 and std.mem.indexOfAny(u8, name, "{}\n") == null) return .{ .start = open, .end = close + 2, .name = name };
        i = open + 2;
    }
    return null;
}

pub fn lookup(vars: []const Var, name: []const u8) ?[]const u8 {
    // The last enabled row wins, as in a file read top to bottom.
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        if (vars[i].enabled and std.mem.eql(u8, vars[i].key, name)) return vars[i].value;
    }
    return null;
}

/// `s` with what's known substituted; unknown references stay as written.
pub fn resolve(a: Allocator, s: []const u8, vars: []const Var) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (nextReference(s, i)) |r| {
        try out.appendSlice(a, s[i..r.start]);
        try out.appendSlice(a, lookup(vars, r.name) orelse s[r.start..r.end]);
        i = r.end;
    }
    try out.appendSlice(a, s[i..]);
    return out.toOwnedSlice(a);
}

/// Adds to `out` each name `s` refers to that has no value, once.
pub fn collectUnresolved(a: Allocator, s: []const u8, vars: []const Var, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (nextReference(s, i)) |r| : (i = r.end) {
        if (lookup(vars, r.name) != null) continue;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, r.name)) break;
        } else try out.append(a, r.name);
    }
}

const t = std.testing;

test "resolve" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const vars = [_]Var{
        .{ .key = "base", .value = "http://h" },
        .{ .key = "id", .value = "7" },
        .{ .key = "off", .value = "no", .enabled = false },
        .{ .key = "id", .value = "8" },
    };
    try t.expectEqualStrings("http://h/u/8", try resolve(a, "{{base}}/u/{{ id }}", &vars));
    try t.expectEqualStrings("{{off}} {{nope}}", try resolve(a, "{{off}} {{nope}}", &vars));
    try t.expectEqualStrings("{{ }} {x} {{", try resolve(a, "{{ }} {x} {{", &vars));
    // One pass only.
    const loop = [_]Var{.{ .key = "a", .value = "{{a}}" }};
    try t.expectEqualStrings("{{a}}", try resolve(a, "{{a}}", &loop));
}

test "unresolved names, once each" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    const vars = [_]Var{.{ .key = "known", .value = "1" }};
    try collectUnresolved(a, "{{x}} {{known}} {{y}} {{x}}", &vars, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("x", out.items[0]);
    try t.expectEqualStrings("y", out.items[1]);
}
