//! Postman import and export against a fixture written the way Postman
//! writes its files.
const std = @import("std");
const postman = @import("postman.zig");
const doc = @import("doc.zig");
const req = @import("../core/request.zig");
const fixtures = @import("fixtures");
const t = std.testing;

fn find(items: []const doc.Item, name: []const u8) ?doc.Item {
    for (items) |i| {
        if (std.mem.eql(u8, i.name, name)) return i;
        if (find(i.children, name)) |f| return f;
    }
    return null;
}

fn warned(d: doc.Doc, word: []const u8) bool {
    for (d.warnings) |w| if (std.mem.indexOf(u8, w, word) != null) return true;
    return false;
}

test "import keeps names, order and request data" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const d = try postman.importCollection(ar.allocator(), fixtures.postman_v21);
    try t.expectEqualStrings("Pet Store", d.name);
    try t.expectEqualStrings("A sample of what Postman writes.", d.description);
    try t.expectEqual(@as(usize, 8), d.countRequests());
    try t.expectEqual(@as(usize, 1), d.countFolders());
    try t.expectEqualStrings("Pets", d.items[0].name);
    try t.expectEqualStrings("Everything about pets", d.items[0].description);
    try t.expectEqualStrings("Create pet", d.items[0].children[1].name);

    const list = find(d.items, "List pets").?.request.?;
    try t.expectEqualStrings("{{baseUrl}}/pets?limit=20&offset=0", list.url);
    try t.expectEqual(@as(usize, 3), list.params.len);
    try t.expect(!list.params[2].enabled);
    try t.expect(!list.headers[1].enabled);
    try t.expectEqualStrings("Lists pets.", list.description);

    const create = find(d.items, "Create pet").?.request.?;
    try t.expectEqual(req.BodyKind.json, create.body_kind);
    try t.expect(std.mem.indexOf(u8, create.body_text, "Rex") != null);

    const get = find(d.items, "Get pet").?.request.?;
    try t.expectEqualStrings("https://petstore.example.com:8443/pets/:id?full=true", get.url);

    const photo = find(d.items, "Upload photo").?.request.?;
    try t.expectEqual(req.BodyKind.multipart, photo.body_kind);
    try t.expect(photo.form[1].is_file);
    try t.expectEqualStrings("C:\\pets\\rex.png", photo.form[1].value);
    try t.expect(!photo.form[2].enabled);
    try t.expectEqualStrings("a", photo.params[0].value);

    const login = find(d.items, "Login").?.request.?;
    try t.expectEqual(req.BodyKind.form_urlencoded, login.body_kind);
    try t.expectEqualStrings("{{password}}", login.form[1].value);

    const bin = find(d.items, "Binary").?.request.?;
    try t.expectEqual(req.BodyKind.file, bin.body_kind);
    try t.expectEqualStrings("/tmp/blob.bin", bin.file_path);

    const graph = find(d.items, "Graph").?.request.?;
    try t.expectEqual(req.BodyKind.json, graph.body_kind);
    try t.expect(std.mem.indexOf(u8, graph.body_text, "pets") != null);

    const bare = find(d.items, "Bare URL").?.request.?;
    try t.expectEqualStrings("GET", bare.method);
    try t.expectEqualStrings("x", bare.params[0].key);
}

test "what can't be imported is named" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const d = try postman.importCollection(ar.allocator(), fixtures.postman_v21);
    try t.expect(warned(d, "Authentication settings on 2"));
    try t.expect(warned(d, "Scripts on 2"));
    try t.expect(warned(d, "1 saved example"));
    try t.expect(warned(d, "1 collection variable"));
    try t.expect(warned(d, "1 GraphQL"));
    try t.expect(warned(d, "Path variables on 1"));
    try t.expect(warned(d, "1 form field"));
}

test "export, then import again, loses nothing supported" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = try postman.importCollection(a, fixtures.postman_v21);
    const out = try postman.exportCollection(a, d);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try t.expectEqualStrings(postman.schema_v21, v.object.get("info").?.object.get("schema").?.string);
    const back = try postman.importCollection(a, out);
    try t.expectEqual(d.countRequests(), back.countRequests());
    try t.expectEqual(@as(usize, 0), back.warnings.len);
    const names = [_][]const u8{ "List pets", "Create pet", "Get pet", "Upload photo", "Login", "Binary", "Graph", "Bare URL" };
    for (names) |n| {
        const x = find(d.items, n).?.request.?;
        const y = find(back.items, n).?.request.?;
        try t.expectEqualStrings(x.method, y.method);
        try t.expectEqualStrings(x.url, y.url);
        try t.expectEqual(x.body_kind, y.body_kind);
        try t.expectEqualStrings(x.body_text, y.body_text);
        try t.expectEqual(x.headers.len, y.headers.len);
        try t.expectEqual(x.params.len, y.params.len);
        try t.expectEqual(x.form.len, y.form.len);
        try t.expectEqualStrings(x.file_path, y.file_path);
    }
}

test "environments" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const e = try postman.importEnvironment(a, fixtures.postman_env);
    try t.expectEqualStrings("Staging", e.name);
    try t.expectEqual(@as(usize, 3), e.vars.len);
    try t.expect(!e.vars[2].enabled);
    const out = try postman.exportEnvironment(a, e);
    const back = try postman.importEnvironment(a, out);
    try t.expectEqualStrings("abc", back.vars[1].value);
    try t.expect(!back.vars[2].enabled);
    try t.expect(std.mem.indexOf(u8, out, "_postman_variable_scope") != null);
    try t.expectError(error.NotJson, postman.importEnvironment(a, "nope"));
    try t.expectError(error.NotAnEnvironment, postman.importEnvironment(a, "{\"name\":\"x\"}"));
}

test "bad files say what's wrong" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NotJson, postman.importCollection(a, "{nope"));
    try t.expectError(error.NotACollection, postman.importCollection(a, "{\"a\":1}"));
    try t.expectError(error.UnsupportedVersion, postman.importCollection(a, "{\"info\":{\"schema\":\"https://schema.getpostman.com/json/collection/v1.0.0/collection.json\"},\"item\":[]}"));
    const old = try postman.importCollection(a, "{\"info\":{\"name\":\"o\",\"schema\":\"https://schema.getpostman.com/json/collection/v2.0.0/collection.json\"},\"item\":[]}");
    try t.expectEqual(@as(usize, 1), old.warnings.len);
}
