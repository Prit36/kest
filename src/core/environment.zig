//! Named sets of variables, in their own JSON form and Postman's.
const std = @import("std");
const json = @import("../utils/json.zig");
const Allocator = std.mem.Allocator;

pub const Var = struct {
    key: []const u8 = "",
    value: []const u8 = "",
    enabled: bool = true,
};

pub const Environment = struct {
    name: []const u8 = "Environment",
    vars: []const Var = &.{},

    pub fn toJson(e: Environment, a: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        writeTo(e, &s) catch return error.OutOfMemory;
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }

    fn writeTo(e: Environment, s: *std.json.Stringify) !void {
        try s.beginObject();
        try json.field(s, "format", "retort.environment/1");
        try json.field(s, "name", e.name);
        try s.objectField("variables");
        try s.beginArray();
        for (e.vars) |v| {
            try s.beginObject();
            try json.field(s, "key", v.key);
            try json.field(s, "value", v.value);
            if (!v.enabled) try json.field(s, "enabled", false);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }

    /// Reads the native form, or Postman's, whose rows are in `values`.
    pub fn parse(arena: Allocator, v: std.json.Value) !Environment {
        if (v != .object) return error.NotAnObject;
        var out: std.ArrayList(Var) = .empty;
        const rows = if (json.get(v, "variables") != null) json.array(v, "variables") else json.array(v, "values");
        for (rows) |r| {
            if (r != .object) continue;
            const key = json.str(r, "key") orelse continue;
            try out.append(arena, .{
                .key = try arena.dupe(u8, key),
                .value = try json.dupeStr(arena, r, "value", ""),
                .enabled = json.boolean(r, "enabled") orelse true,
            });
        }
        return .{ .name = try json.dupeStr(arena, v, "name", "Imported"), .vars = out.items };
    }
};

test "environment round trip" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const e: Environment = .{ .name = "Dev", .vars = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2", .enabled = false } } };
    const text = try e.toJson(a);
    const back = try Environment.parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}));
    try std.testing.expectEqualStrings("Dev", back.name);
    try std.testing.expectEqual(@as(usize, 2), back.vars.len);
    try std.testing.expect(!back.vars[1].enabled);
}
