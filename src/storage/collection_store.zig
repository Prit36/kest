//! Collections on disk, one folder each, made to be read and diffed by people:
//!
//!   collections/<id>/collection.json    the tree: names, order, methods
//!   collections/<id>/requests/<id>.json one request per file
//!
//! A tree loads without touching a request's file, so opening a large
//! collection costs what its tree costs. Saving a request rewrites one file.
//! A file that can't be read is reported and left alone, never overwritten.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = @import("../utils/json.zig");
const col = @import("../core/collection.zig");
const req = @import("../core/request.zig");
const doc = @import("../import_export/doc.zig");
const Store = @import("store.zig").Store;
const Node = col.Node;

/// The tree's path: `buf` must hold it.
pub fn treePath(buf: []u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "collections/{s}/collection.json", .{id}) catch unreachable;
}

pub fn requestPath(buf: []u8, collection_id: []const u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "collections/{s}/requests/{s}.json", .{ collection_id, id }) catch unreachable;
}

pub const path_len = 80;

/// The collection's tree as its file holds it.
pub fn treeJson(a: Allocator, c: *const Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeTree(&s, c) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeTree(s: *std.json.Stringify, c: *const Node) !void {
    try s.beginObject();
    try json.field(s, "format", "retort.collection/1");
    try json.field(s, "id", &c.id);
    try json.field(s, "name", c.name);
    if (c.description.len > 0) try json.field(s, "description", c.description);
    try json.field(s, "expanded", c.expanded);
    try s.objectField("items");
    try writeChildren(s, c);
    try s.endObject();
}

fn writeChildren(s: *std.json.Stringify, n: *const Node) anyerror!void {
    try s.beginArray();
    for (n.children.items) |c| {
        try s.beginObject();
        try json.field(s, "type", @tagName(c.kind));
        try json.field(s, "id", &c.id);
        try json.field(s, "name", c.name);
        if (c.kind == .request) {
            try json.field(s, "method", c.method);
        } else {
            if (c.description.len > 0) try json.field(s, "description", c.description);
            try json.field(s, "expanded", c.expanded);
            try s.objectField("items");
            try writeChildren(s, c);
        }
        try s.endObject();
    }
    try s.endArray();
}

pub const LoadError = error{ NotACollection, BadId, OutOfMemory };

/// Parses a tree file into nodes. Items with bad ids are skipped: an id is a
/// file name, and a hand-edited file mustn't choose where we read or write.
pub fn parseTree(gpa: Allocator, text: []const u8) LoadError!*Node {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, ar.allocator(), text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotACollection,
    };
    const id = json.str(v, "id") orelse return error.NotACollection;
    if (!col.validId(id)) return error.BadId;
    const c = try col.create(gpa, id[0..16].*, .collection, json.str(v, "name") orelse "Untitled", "");
    errdefer col.destroy(gpa, c);
    c.description = try gpa.dupe(u8, json.str(v, "description") orelse "");
    c.expanded = json.boolean(v, "expanded") orelse true;
    try parseChildren(gpa, c, json.array(v, "items"));
    return c;
}

fn parseChildren(gpa: Allocator, parent: *Node, items: []const std.json.Value) LoadError!void {
    for (items) |i| {
        if (i != .object) continue;
        const id = json.str(i, "id") orelse continue;
        if (!col.validId(id)) continue;
        const kind = std.meta.stringToEnum(col.Kind, json.str(i, "type") orelse "") orelse continue;
        if (kind == .collection) continue;
        const n = try col.create(gpa, id[0..16].*, kind, json.str(i, "name") orelse "Untitled", json.str(i, "method") orelse "GET");
        errdefer col.destroy(gpa, n);
        if (kind == .folder) {
            n.description = try gpa.dupe(u8, json.str(i, "description") orelse "");
            n.expanded = json.boolean(i, "expanded") orelse false;
            try parseChildren(gpa, n, json.array(i, "items"));
        }
        try col.append(gpa, parent, n);
    }
}

pub fn saveTree(store: *Store, c: *const Node) !void {
    var buf: [path_len]u8 = undefined;
    const text = try treeJson(store.gpa, c);
    store.writeOwned(treePath(&buf, &c.id), text);
}

/// `r`'s file, written soon.
pub fn saveRequest(store: *Store, collection_id: []const u8, id: []const u8, r: req.Request) !void {
    var buf: [path_len]u8 = undefined;
    const text = try r.toJson(store.gpa);
    store.writeOwned(requestPath(&buf, collection_id, id), text);
}

pub const RequestLoadError = error{ RequestMissing, RequestUnreadable, OutOfMemory };

/// Reads one request; its strings are in `a`.
pub fn loadRequest(store: *Store, a: Allocator, collection_id: []const u8, id: []const u8) RequestLoadError!req.Request {
    var buf: [path_len]u8 = undefined;
    const path = requestPath(&buf, collection_id, id);
    const text = (store.read(a, path) catch return error.RequestUnreadable) orelse return error.RequestMissing;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RequestUnreadable,
    };
    return req.Request.parse(a, v) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RequestUnreadable,
    };
}

pub fn deleteCollection(store: *Store, id: []const u8) void {
    var buf: [path_len]u8 = undefined;
    store.deleteTree(std.fmt.bufPrint(&buf, "collections/{s}", .{id}) catch unreachable);
}

/// Deletes the files of `n`'s requests, and below it.
pub fn deleteRequests(store: *Store, collection_id: []const u8, n: *const Node) void {
    if (n.kind == .request) {
        var buf: [path_len]u8 = undefined;
        store.delete(requestPath(&buf, collection_id, &n.id));
    }
    for (n.children.items) |c| deleteRequests(store, collection_id, c);
}

pub const Problem = struct { name: []u8, message: []const u8 };

/// Every collection in the folder; those it can't read go in `problems`.
pub fn loadAll(store: *Store, gpa: Allocator, out: *std.ArrayList(*Node), problems: *std.ArrayList(Problem)) !void {
    const root = store.dir.openDir(store.io, "collections", .{ .iterate = true }) catch return;
    defer root.close(store.io);
    var it = root.iterate();
    while (it.next(store.io) catch null) |e| {
        if (e.kind != .directory or !col.validId(e.name)) continue;
        var buf: [path_len]u8 = undefined;
        const text = (store.read(gpa, treePath(&buf, e.name)) catch null) orelse {
            try problems.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .message = "its collection.json couldn't be read" });
            continue;
        };
        defer gpa.free(text);
        const node = parseTree(gpa, text) catch {
            try problems.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .message = "its collection.json isn't valid" });
            continue;
        };
        // The folder is the truth: a copied file keeps saying its old id.
        node.id = e.name[0..16].*;
        try out.append(gpa, node);
    }
}

/// Writes an imported document into the workspace as files, under `parent`.
pub fn addItems(store: *Store, gpa: Allocator, collection_id: []const u8, parent: *Node, items: []const doc.Item) anyerror!void {
    for (items) |i| {
        if (i.request) |r| {
            const n = try col.create(gpa, col.newId(store.io), .request, i.name, r.method);
            errdefer col.destroy(gpa, n);
            var named = r;
            named.name = i.name;
            try saveRequest(store, collection_id, &n.id, named);
            try col.append(gpa, parent, n);
        } else {
            const n = try col.create(gpa, col.newId(store.io), .folder, i.name, "");
            errdefer col.destroy(gpa, n);
            n.description = try gpa.dupe(u8, i.description);
            try addItems(store, gpa, collection_id, n, i.children);
            try col.append(gpa, parent, n);
        }
    }
}

/// The tree under `n` as a document, reading every request from disk. A
/// request file that can't be read is left out, and its name added to `missing`.
pub fn toItems(store: *Store, a: Allocator, collection_id: []const u8, n: *const Node, missing: *std.ArrayList([]const u8)) anyerror![]const doc.Item {
    var out: std.ArrayList(doc.Item) = .empty;
    for (n.children.items) |c| {
        if (c.kind == .request) {
            const r = loadRequest(store, a, collection_id, &c.id) catch {
                try missing.append(a, try a.dupe(u8, c.name));
                continue;
            };
            var named = r;
            named.name = try a.dupe(u8, c.name);
            try out.append(a, .{ .name = named.name, .description = r.description, .request = named });
        } else {
            try out.append(a, .{
                .name = try a.dupe(u8, c.name),
                .description = try a.dupe(u8, c.description),
                .children = try toItems(store, a, collection_id, c, missing),
            });
        }
    }
    return out.items;
}

const t = std.testing;

fn tempStore(tmp: *std.testing.TmpDir, buf: []u8) !Store {
    const n = try tmp.dir.realPath(t.io, buf);
    return Store.open(t.allocator, t.io, buf[0..n]);
}

test "a collection reopens as it was, after a restart" {
    const a = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    {
        var s = try tempStore(&tmp, &buf);
        defer s.close();
        try s.startWriter();
        const c = try col.create(a, col.newId(t.io), .collection, "API \"v2\"", "");
        defer col.destroy(a, c);
        c.description = try a.dupe(u8, "desc");
        const f = try col.create(a, col.newId(t.io), .folder, "Users", "");
        f.expanded = true;
        try col.append(a, c, f);
        const r = try col.create(a, col.newId(t.io), .request, "Get user", "PURGE");
        try col.append(a, f, r);
        try saveRequest(&s, &c.id, &r.id, .{ .name = "Get user", .method = "PURGE", .url = "http://x/{{id}}", .body_kind = .json, .body_text = "{}" });
        try col.append(a, c, try col.create(a, col.newId(t.io), .request, "Second", "GET"));
        try saveTree(&s, c);
    }
    var s = try tempStore(&tmp, &buf);
    defer s.close();
    var cols: std.ArrayList(*Node) = .empty;
    defer {
        for (cols.items) |c| col.destroy(a, c);
        cols.deinit(a);
    }
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(a);
    try loadAll(&s, a, &cols, &problems);
    try t.expectEqual(@as(usize, 1), cols.items.len);
    try t.expectEqual(@as(usize, 0), problems.items.len);
    const c = cols.items[0];
    try t.expectEqualStrings("API \"v2\"", c.name);
    try t.expectEqualStrings("desc", c.description);
    try t.expectEqual(@as(usize, 2), c.children.items.len);
    const f = c.children.items[0];
    try t.expect(f.expanded);
    const r = f.children.items[0];
    try t.expectEqualStrings("PURGE", r.method);
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const loaded = try loadRequest(&s, ar.allocator(), &c.id, &r.id);
    try t.expectEqualStrings("http://x/{{id}}", loaded.url);
    try t.expectEqual(req.BodyKind.json, loaded.body_kind);
    try t.expectError(error.RequestMissing, loadRequest(&s, ar.allocator(), &c.id, &c.children.items[1].id));
}

test "a broken file is reported and left alone" {
    const a = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var s = try tempStore(&tmp, &buf);
    defer s.close();
    const id = col.newId(t.io);
    var pbuf: [path_len]u8 = undefined;
    const path = treePath(&pbuf, &id);
    s.write(path, "{ not json");
    // A folder that isn't ours is ignored.
    s.write("collections/not-an-id/collection.json", "{}");
    var cols: std.ArrayList(*Node) = .empty;
    defer cols.deinit(a);
    var problems: std.ArrayList(Problem) = .empty;
    defer {
        for (problems.items) |p| a.free(p.name);
        problems.deinit(a);
    }
    try loadAll(&s, a, &cols, &problems);
    try t.expectEqual(@as(usize, 0), cols.items.len);
    try t.expectEqual(@as(usize, 1), problems.items.len);
    const still = (try s.read(a, path)).?;
    defer a.free(still);
    try t.expectEqualStrings("{ not json", still);
}

test "ids in files can't reach outside the folder" {
    const a = t.allocator;
    try t.expectError(error.BadId, parseTree(a, "{\"id\":\"../../evil\",\"name\":\"x\"}"));
    const c = try parseTree(a, "{\"id\":\"0123456789abcdef\",\"name\":\"x\",\"items\":[{\"type\":\"request\",\"id\":\"../../../evil\",\"name\":\"bad\"},{\"type\":\"request\",\"id\":\"fedcba9876543210\",\"name\":\"good\"}]}");
    defer col.destroy(a, c);
    try t.expectEqual(@as(usize, 1), c.children.items.len);
    try t.expectEqualStrings("good", c.children.items[0].name);
}

test "import writes files, export reads them back" {
    const a = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var s = try tempStore(&tmp, &buf);
    defer s.close();
    const c = try col.create(a, col.newId(t.io), .collection, "C", "");
    defer col.destroy(a, c);
    const d: doc.Doc = .{ .name = "C", .items = &.{
        .{ .name = "F", .description = "fd", .children = &.{.{ .name = "R1", .request = .{ .method = "POST", .url = "http://1" } }} },
        .{ .name = "R2", .request = .{ .url = "http://2" } },
    } };
    try addItems(&s, a, &c.id, c, d.items);
    s.sync();
    try t.expectEqual(@as(usize, 2), c.countRequests());
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    var missing: std.ArrayList([]const u8) = .empty;
    const items = try toItems(&s, ar.allocator(), &c.id, c, &missing);
    try t.expectEqual(@as(usize, 0), missing.items.len);
    try t.expectEqualStrings("R1", items[0].children[0].request.?.name);
    try t.expectEqualStrings("http://1", items[0].children[0].request.?.url);
    try t.expectEqualStrings("fd", items[0].description);
    // Deleting a request's file: export names what's lost.
    deleteRequests(&s, &c.id, c.children.items[1]);
    s.sync();
    _ = try toItems(&s, ar.allocator(), &c.id, c, &missing);
    try t.expectEqual(@as(usize, 1), missing.items.len);
}
