//! A collection as import and export see it: a whole tree in memory, in one
//! arena, independent of how the workspace keeps it on disk.
const std = @import("std");
const req = @import("../core/request.zig");
const Allocator = std.mem.Allocator;

pub const Item = struct {
    name: []const u8,
    description: []const u8 = "",
    /// Null for a folder.
    request: ?req.Request = null,
    children: []const Item = &.{},

    pub fn countRequests(i: Item) usize {
        var n: usize = if (i.request != null) 1 else 0;
        for (i.children) |c| n += c.countRequests();
        return n;
    }

    pub fn countFolders(i: Item) usize {
        var n: usize = if (i.request == null) 1 else 0;
        for (i.children) |c| n += c.countFolders();
        return n;
    }
};

pub const Doc = struct {
    name: []const u8,
    description: []const u8 = "",
    items: []const Item = &.{},
    warnings: []const []const u8 = &.{},

    pub fn countRequests(d: Doc) usize {
        var n: usize = 0;
        for (d.items) |i| n += i.countRequests();
        return n;
    }

    pub fn countFolders(d: Doc) usize {
        var n: usize = 0;
        for (d.items) |i| n += i.countFolders();
        return n;
    }

    /// Requests sharing a name, method and URL with an earlier one here.
    pub fn countInternalDuplicates(d: Doc, a: Allocator) !usize {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| a.free(k.*);
            seen.deinit(a);
        }
        var dups: usize = 0;
        for (d.items) |i| try countDup(a, i, &seen, &dups);
        return dups;
    }
};

fn countDup(a: Allocator, i: Item, seen: *std.StringHashMapUnmanaged(void), dups: *usize) Allocator.Error!void {
    if (i.request) |r| {
        const k = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ i.name, r.method, r.url });
        const g = try seen.getOrPut(a, k);
        if (g.found_existing) {
            dups.* += 1;
            a.free(k);
        }
    }
    for (i.children) |c| try countDup(a, c, seen, dups);
}

/// What a pasted or opened text seems to be.
pub const Format = enum { curl, postman_collection, postman_environment, native_collection, native_environment, native_request, unknown };

pub const parse_limit = 512 * 1024 * 1024;

pub fn detect(a: Allocator, text_in: []const u8) Format {
    const text = std.mem.trim(u8, text_in, " \t\r\n\xef\xbb\xbf");
    if (std.ascii.startsWithIgnoreCase(text, "curl ") or std.ascii.startsWithIgnoreCase(text, "curl.exe ")) return .curl;
    if (text.len == 0 or text[0] != '{') return .unknown;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, ar.allocator(), text, .{}) catch return .unknown;
    if (v != .object) return .unknown;
    if (v.object.get("format")) |f| if (f == .string) {
        if (std.mem.startsWith(u8, f.string, "retort.collection")) return .native_collection;
        if (std.mem.startsWith(u8, f.string, "retort.environment")) return .native_environment;
        if (std.mem.startsWith(u8, f.string, "retort.request")) return .native_request;
    };
    if (v.object.get("info") != null and v.object.get("item") != null) return .postman_collection;
    if (v.object.get("values") != null) return .postman_environment;
    return .unknown;
}

test "detect" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Format.curl, detect(a, "  curl http://x"));
    try std.testing.expectEqual(Format.postman_collection, detect(a, "{\"info\":{},\"item\":[]}"));
    try std.testing.expectEqual(Format.postman_environment, detect(a, "{\"name\":\"e\",\"values\":[]}"));
    try std.testing.expectEqual(Format.native_collection, detect(a, "{\"format\":\"retort.collection-export/1\"}"));
    try std.testing.expectEqual(Format.unknown, detect(a, "{\"a\":1}"));
    try std.testing.expectEqual(Format.unknown, detect(a, "{broken"));
    try std.testing.expectEqual(Format.unknown, detect(a, "hello"));
}

test "duplicates" {
    const a = std.testing.allocator;
    const r: req.Request = .{ .method = "GET", .url = "http://x" };
    const d: Doc = .{ .name = "c", .items = &.{
        .{ .name = "one", .request = r },
        .{ .name = "f", .children = &.{ .{ .name = "one", .request = r }, .{ .name = "two", .request = r } } },
    } };
    try std.testing.expectEqual(@as(usize, 1), try d.countInternalDuplicates(a));
    try std.testing.expectEqual(@as(usize, 3), d.countRequests());
    try std.testing.expectEqual(@as(usize, 1), d.countFolders());
}
