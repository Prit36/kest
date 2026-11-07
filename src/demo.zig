//! Repeatable, isolated manual-testing workspace. Every URL is loopback.
const std = @import("std");
const App = @import("app/state.zig").App;
const tree = @import("app/tree_ops.zig");
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const Node = @import("core/collection.zig").Node;
const Request = @import("core/request.zig").Request;

fn add(app: *App, parent: *Node, request: Request) !*Node {
    return tree.addRequest(app, parent, request) orelse error.DemoSeedFailed;
}

pub fn populate(app: *App, port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    for ([_][]const u8{ "Demo - Local", "Demo - Alternate variables", "Demo - An intentionally long environment name for testing truncation" }, 0..) |name, i| {
        const env = tree.addEnvironment(app, name) orelse return error.DemoSeedFailed;
        _ = try env.table.add(.{ .key = "base_url", .value = base });
        _ = try env.table.add(.{ .key = "token", .value = "dummy-token-not-a-real-secret" });
        _ = try env.table.add(.{ .key = "team", .value = if (i == 0) "design" else "engineering" });
        _ = try env.table.add(.{ .key = "page_size", .value = "25" });
        _ = try env.table.add(.{ .key = "disabled_example", .value = "not included", .enabled = false });
        persist.saveEnv(app, env);
        if (i == 0) commands.setActiveEnv(app, env);
    }

    const api = tree.newCollection(app, "01 - Demo API") orelse return error.DemoSeedFailed;
    const people = tree.newFolder(app, api, "People and orders") orelse return error.DemoSeedFailed;
    const users = try add(app, people, .{ .name = "List people", .url = "{{base_url}}/demo/users", .headers = &.{ .{ .key = "Accept", .value = "application/json" }, .{ .key = "Authorization", .value = "Bearer {{token}}" }, .{ .key = "X-Debug", .value = "disabled header", .enabled = false } } });
    const orders = try add(app, people, .{ .name = "List orders with nested line items", .url = "{{base_url}}/demo/orders" });
    const search = try add(app, people, .{ .name = "Search with enabled and disabled parameters", .url = "{{base_url}}/echo?search=design&page=1&limit=25", .params = &.{ .{ .key = "search", .value = "design" }, .{ .key = "page", .value = "1" }, .{ .key = "limit", .value = "25" }, .{ .key = "include_archived", .value = "true", .enabled = false } } });
    _ = tree.newFolder(app, api, "Empty folder - try adding a request") orelse return error.DemoSeedFailed;

    const bodies = tree.newCollection(app, "02 - Request bodies") orelse return error.DemoSeedFailed;
    const create = try add(app, bodies, .{ .name = "Create a person", .method = "POST", .url = "{{base_url}}/echo", .body_kind = .json, .body_text = "{\n  \"name\": \"Avery Chen\",\n  \"email\": \"avery@example.test\",\n  \"team\": \"{{team}}\",\n  \"roles\": [\"editor\", \"reviewer\"],\n  \"active\": true\n}" });
    _ = try add(app, bodies, .{ .name = "Update preferences", .method = "PATCH", .url = "{{base_url}}/echo", .body_kind = .json, .body_text = "{\"theme\":\"dark\",\"notifications\":false}" });
    const form = try add(app, bodies, .{ .name = "Submit a form", .method = "POST", .url = "{{base_url}}/echo", .body_kind = .form_urlencoded, .form = &.{ .{ .key = "name", .value = "Morgan Lee" }, .{ .key = "message", .value = "Hello from Kest demo" }, .{ .key = "optional", .value = "disabled value", .enabled = false } } });
    app.store.writeOwned("demo-upload.txt", try app.gpa.dupe(u8, "Kest demo upload\nThis is a local sample file.\n"));
    const file_path = try std.fs.path.join(a, &.{ app.store.path, "demo-upload.txt" });
    const multipart = try add(app, bodies, .{ .name = "Upload a file with metadata", .method = "POST", .url = "{{base_url}}/echo", .body_kind = .multipart, .form = &.{ .{ .key = "title", .value = "Sample attachment" }, .{ .key = "attachment", .value = file_path, .is_file = true } } });
    _ = try add(app, bodies, .{ .name = "Upload a raw file", .method = "PUT", .url = "{{base_url}}/echo", .body_kind = .file, .file_path = file_path });
    _ = try add(app, bodies, .{ .name = "XML payload", .method = "POST", .url = "{{base_url}}/echo", .body_kind = .xml, .body_text = "<person>\n  <name>Avery Chen</name>\n  <active>true</active>\n</person>" });
    _ = try add(app, bodies, .{ .name = "Plain text payload", .method = "POST", .url = "{{base_url}}/echo", .body_kind = .text, .body_text = "A multiline example.\nTry selection, find, copy and undo.\n" });
    _ = try add(app, bodies, .{ .name = "Delete a person", .method = "DELETE", .url = "{{base_url}}/echo?person=42" });
    _ = try add(app, bodies, .{ .name = "Custom PROPFIND method", .method = "PROPFIND", .url = "{{base_url}}/echo" });

    const responses = tree.newCollection(app, "03 - Responses and edge cases") orelse return error.DemoSeedFailed;
    const not_found = try add(app, responses, .{ .name = "404 - Not found", .url = "{{base_url}}/status/404" });
    for ([_]u16{ 201, 204, 301, 401, 403, 429, 500, 503 }) |status| {
        _ = try add(app, responses, .{ .name = try std.fmt.allocPrint(a, "Status {d}", .{status}), .url = try std.fmt.allocPrint(a, "{{{{base_url}}}}/status/{d}", .{status}) });
    }
    const markdown = try add(app, responses, .{ .name = "Markdown preview", .url = "{{base_url}}/markdown" });
    _ = try add(app, responses, .{ .name = "HTML preview", .url = "{{base_url}}/html" });
    _ = try add(app, responses, .{ .name = "Image preview", .url = "{{base_url}}/png" });
    _ = try add(app, responses, .{ .name = "Binary and hex view - 16 KiB", .url = "{{base_url}}/bytes/16384" });
    _ = try add(app, responses, .{ .name = "Follow three redirects", .url = "{{base_url}}/redirect/3" });
    _ = try add(app, responses, .{ .name = "Inspect redirect without following", .url = "{{base_url}}/redirect/3", .settings = .{ .follow_redirects = false } });
    _ = try add(app, responses, .{ .name = "Timeout and cancel - waits for a response", .url = "{{base_url}}/hang", .settings = .{ .timeout_ms = 3000 } });
    _ = try add(app, responses, .{ .name = "Chunked response", .url = "{{base_url}}/chunked" });

    const layout = tree.newCollection(app, "04 - Layout stress - deliberately long collection name to check truncation") orelse return error.DemoSeedFailed;
    var nested = layout;
    for ([_][]const u8{ "Projects", "An unusually long folder name", "Nested requests" }) |name| nested = tree.newFolder(app, nested, name) orelse return error.DemoSeedFailed;
    for (0..36) |i| {
        _ = try add(app, nested, .{ .name = try std.fmt.allocPrint(a, "Sample {d:0>2} - A long request title for sidebar scrolling and menus", .{i + 1}), .url = try std.fmt.allocPrint(a, "{{{{base_url}}}}/echo?sample={d}", .{i + 1}) });
    }
    layout.expanded = false;
    persist.saveTree(app, layout);
    _ = tree.newCollection(app, "05 - Empty collection") orelse return error.DemoSeedFailed;
    app.store.sync();

    // Real responses/history are ready on launch; overflow tabs are intentional.
    for ([_]*Node{ users, orders, create, search, form, multipart, not_found, markdown }) |node| commands.openRequest(app, node);
    commands.activate(app, 0);
    app.prefs.sidebar_open = true;
    app.rows_dirty = true;
    persist.flush(app);
    app.store.sync();
}

pub fn warm(app: *App) !void {
    for (app.tabs.items) |tab| commands.send(app, tab);
    const started = std.Io.Clock.awake.now(app.io).toMilliseconds();
    while (true) {
        commands.drainDone(app);
        var running = false;
        for (app.tabs.items) |tab| running = running or tab.running();
        if (!running) break;
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - started > 5000) return error.DemoWarmupTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
    persist.flush(app);
    app.store.sync();
}

/// The build's demo smoke check uses the same startup path as the launcher.
pub fn validate(app: *App) !void {
    if (app.collections.items.len != 5 or app.envs.items.len != 3 or app.tabs.items.len != 8 or app.history.entries.items.len != 8) return error.DemoValidationFailed;
    for (app.tabs.items, 0..) |tab, i| {
        const shown = tab.shown orelse return error.DemoValidationFailed;
        if (shown.resp.status != (if (i == 6) @as(u16, 404) else @as(u16, 200))) return error.DemoValidationFailed;
    }
    if (std.mem.indexOf(u8, app.tabs.items[0].shown.?.resp.preview.items, "Avery Chen") == null) return error.DemoValidationFailed;
    if (std.mem.indexOf(u8, app.tabs.items[5].shown.?.resp.preview.items, "Kest demo upload") == null) return error.DemoValidationFailed;
    std.debug.print("Demo: isolated workspace, five collections, three environments, eight populated tabs/history entries and local multipart upload passed\n", .{});
}
