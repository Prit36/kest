//! The application's own one-file collection format, for moving a collection
//! between machines: the whole tree with every request embedded.
const std = @import("std");
const json = @import("../utils/json.zig");
const req = @import("../core/request.zig");
const doc = @import("doc.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const format_name = "kest.collection-export/1";

pub fn write(a: Allocator, d: doc.Doc) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeTo(&s, d) catch return error.OutOfMemory;
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeTo(s: *std.json.Stringify, d: doc.Doc) !void {
    try s.beginObject();
    try json.field(s, "format", format_name);
    try json.field(s, "name", d.name);
    if (d.description.len > 0) try json.field(s, "description", d.description);
    try s.objectField("items");
    try writeItems(s, d.items);
    try s.endObject();
}

fn writeItems(s: *std.json.Stringify, items: []const doc.Item) anyerror!void {
    try s.beginArray();
    for (items) |i| {
        try s.beginObject();
        if (i.request) |r| {
            try json.field(s, "type", "request");
            try r.writeFields(s);
        } else {
            try json.field(s, "type", "folder");
            try json.field(s, "name", i.name);
            if (i.description.len > 0) try json.field(s, "description", i.description);
            try s.objectField("items");
            try writeItems(s, i.children);
        }
        try s.endObject();
    }
    try s.endArray();
}

pub const ReadError = error{ NotJson, NotACollection, OutOfMemory };

/// Reads an export; everything is allocated in `a`: use an arena.
pub fn read(a: Allocator, text: []const u8) ReadError!doc.Doc {
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const f = json.str(v, "format") orelse return error.NotACollection;
    if (!std.mem.startsWith(u8, f, "kest.collection-export")) return error.NotACollection;
    return .{
        .name = try json.dupeStr(a, v, "name", "Imported collection"),
        .description = try json.dupeStr(a, v, "description", ""),
        .items = try readItems(a, json.array(v, "items")),
    };
}

fn readItems(a: Allocator, items: []const Value) ReadError![]const doc.Item {
    var out: std.ArrayList(doc.Item) = .empty;
    for (items) |i| {
        if (i != .object) continue;
        const name = try json.dupeStr(a, i, "name", "Untitled");
        if (std.mem.eql(u8, json.str(i, "type") orelse "", "folder")) {
            try out.append(a, .{ .name = name, .description = try json.dupeStr(a, i, "description", ""), .children = try readItems(a, json.array(i, "items")) });
        } else {
            const r = req.Request.parse(a, i) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            try out.append(a, .{ .name = name, .description = r.description, .request = r });
        }
    }
    return out.items;
}

test "an export comes back the same" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d: doc.Doc = .{ .name = "API", .description = "desc", .items = &.{
        .{ .name = "Folder", .description = "f", .children = &.{
            .{ .name = "Get", .request = .{ .name = "Get", .method = "GET", .url = "http://h" } },
        } },
        .{ .name = "Post", .request = .{ .name = "Post", .method = "POST", .url = "http://p", .body_kind = .json, .body_text = "{}" } },
    } };
    const text = try write(a, d);
    const back = try read(a, text);
    try std.testing.expectEqualStrings("API", back.name);
    try std.testing.expectEqual(@as(usize, 2), back.items.len);
    try std.testing.expectEqualStrings("f", back.items[0].description);
    try std.testing.expectEqualStrings("http://h", back.items[0].children[0].request.?.url);
    try std.testing.expectEqualStrings("{}", back.items[1].request.?.body_text);
    try std.testing.expectError(error.NotACollection, read(a, "{\"name\":1}"));
    try std.testing.expectError(error.NotJson, read(a, "nope"));
}
