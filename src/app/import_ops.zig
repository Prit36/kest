//! Import looks first and changes nothing: a preview says what's in a file,
//! what can't be carried over, and what's already here. Only accepting it
//! writes anything. Export reads requests back from their files.
const std = @import("std");
const platform = @import("../ui/platform.zig");
const state = @import("state.zig");
const persist = @import("persist.zig");
const commands = @import("commands.zig");
const tree = @import("tree_ops.zig");
const col = @import("../core/collection.zig");
const req = @import("../core/request.zig");
const environment = @import("../core/environment.zig");
const doc = @import("../import_export/doc.zig");
const curl = @import("../import_export/curl.zig");
const postman = @import("../import_export/postman.zig");
const native = @import("../import_export/native_format.zig");
const cs = @import("../storage/collection_store.zig");
const App = state.App;
const Allocator = std.mem.Allocator;

/// A file much larger than any real collection is refused, not loaded.
const max_import = 128 * 1024 * 1024;

pub fn chooseFile(app: *App) void {
    const paths = platform.dialog.open(app.gpa, .{ .title = "Import", .extensions = &.{ "json", "txt", "sh", "curl" } }) catch return;
    const list = paths orelse return;
    defer {
        for (list) |p| app.gpa.free(p);
        app.gpa.free(list);
    }
    if (list.len == 0) return;
    importFile(app, list[0]);
}

pub fn importFile(app: *App, path: []const u8) void {
    const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(max_import)) catch |e| {
        var buf: [200]u8 = undefined;
        app.toast(.danger, "Couldn't read the file", std.fmt.bufPrint(&buf, "{s}", .{@errorName(e)}) catch "");
        return;
    };
    defer app.gpa.free(text);
    previewText(app, text, std.fs.path.basename(path));
}

/// Works out what `text` is and opens the preview, or says why it can't.
pub fn previewText(app: *App, text: []const u8, file_name: []const u8) void {
    const p = app.gpa.create(state.ImportPreview) catch return;
    p.* = .{ .arena = .init(app.gpa), .format = .unknown };
    const a = p.arena.allocator();
    fill(app, p, a, text, file_name) catch |e| {
        const why: []const u8 = switch (e) {
            error.Unknown => "It doesn't look like a Postman collection or environment, a Kest/Kest export, or a cURL command.",
            else => @errorName(e),
        };
        app.toast(.danger, "Can't import this", why);
        state.App.freePreview(app.gpa, p);
        return;
    };
    if (app.preview) |old| state.App.freePreview(app.gpa, old);
    app.preview = p;
    app.modal = .import_preview;
    app.modal_open = true;
}

fn fill(app: *App, p: *state.ImportPreview, a: Allocator, text: []const u8, file_name: []const u8) !void {
    p.file_name = try a.dupe(u8, file_name);
    p.format = doc.detect(a, text);
    switch (p.format) {
        .curl => {
            const imp = curl.parse(a, text) catch |e| {
                app.toast(.danger, "That cURL command can't be read", curl.describe(e));
                return error.Reported;
            };
            const name = try curlName(a, imp.request);
            var r = imp.request;
            r.name = name;
            const items = try a.alloc(doc.Item, 1);
            items[0] = .{ .name = name, .request = r };
            p.document = .{ .name = "cURL import", .items = items, .warnings = imp.warnings };
            p.warnings = imp.warnings;
            p.target = app.preferredTarget();
        },
        .postman_collection => {
            const d = postman.importCollection(a, text) catch |e| {
                app.toast(.danger, "That collection can't be read", postman.describe(e));
                return error.Reported;
            };
            p.document = d;
            p.warnings = d.warnings;
        },
        .native_collection => {
            const d = native.read(a, text) catch {
                app.toast(.danger, "That file can't be read", "It says it's a Kest/Kest export, but its contents aren't valid.");
                return error.Reported;
            };
            p.document = d;
            p.warnings = d.warnings;
        },
        .native_request => {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
            const r = try req.Request.parse(a, v);
            const items = try a.alloc(doc.Item, 1);
            items[0] = .{ .name = r.name, .request = r };
            p.document = .{ .name = r.name, .items = items };
            p.target = app.preferredTarget();
        },
        .postman_environment, .native_environment => {
            p.environment = postman.importEnvironment(a, text) catch {
                app.toast(.danger, "That environment can't be read", "It isn't a valid environment file.");
                return error.Reported;
            };
            for (app.envs.items) |e| if (std.mem.eql(u8, e.name, p.environment.?.name)) {
                p.name_taken = true;
            };
        },
        .unknown => return error.Unknown,
    }
    refreshDuplicates(app, p);
}

fn curlName(a: Allocator, r: req.Request) ![]const u8 {
    const after = if (std.mem.indexOf(u8, r.url, "://")) |i| r.url[i + 3 ..] else r.url;
    const end = std.mem.indexOfAny(u8, after, "?#") orelse after.len;
    return std.fmt.allocPrint(a, "{s} {s}", .{ r.method, after[0..@min(end, 60)] });
}

fn countSame(items: []const doc.Item, n: *const col.Node) usize {
    var total: usize = 0;
    for (items) |i| {
        if (i.request) |r| {
            if (hasRequest(n, i.name, r.method)) total += 1;
        }
        total += countSame(i.children, n);
    }
    return total;
}

fn hasRequest(n: *const col.Node, name: []const u8, method: []const u8) bool {
    if (n.kind == .request and std.mem.eql(u8, n.name, name) and std.ascii.eqlIgnoreCase(n.method, method)) return true;
    for (n.children.items) |c| if (hasRequest(c, name, method)) return true;
    return false;
}

/// How the import compares with where it would land.
pub fn refreshDuplicates(app: *App, p: *state.ImportPreview) void {
    const d = p.document orelse return;
    p.name_taken = false;
    p.duplicates_inside = d.countInternalDuplicates(p.arena.allocator()) catch 0;
    if (p.target) |i| {
        if (i < app.collections.items.len) p.duplicates_inside += countSame(d.items, app.collections.items[i]);
        return;
    }
    for (app.collections.items) |c| if (std.mem.eql(u8, c.name, d.name)) {
        p.name_taken = true;
    };
}

/// Writes it in. Existing things are never overwritten: an imported request
/// with the same name as one already here sits beside it.
pub fn accept(app: *App) void {
    const p = app.preview orelse return;
    defer {
        state.App.freePreview(app.gpa, p);
        app.preview = null;
    }
    if (p.environment) |env| {
        const name = if (p.name_taken) std.fmt.allocPrint(p.arena.allocator(), "{s} (imported)", .{env.name}) catch env.name else env.name;
        var named = env;
        named.name = name;
        const e = persist.addEnv(app, col.newId(app.io), named) catch return;
        persist.saveEnv(app, e);
        var buf: [160]u8 = undefined;
        app.toast(.success, "Environment imported", std.fmt.bufPrint(&buf, "\"{s}\", {d} variables", .{ name, env.vars.len }) catch "");
        return;
    }
    const d = p.document orelse return;
    const target = blk: {
        if (p.target) |i| if (i < app.collections.items.len) break :blk app.collections.items[i];
        const name = if (p.name_taken) std.fmt.allocPrint(p.arena.allocator(), "{s} (imported)", .{d.name}) catch d.name else d.name;
        const c = tree.newCollection(app, name) orelse return;
        col.setString(app.gpa, &c.description, d.description) catch {};
        break :blk c;
    };
    cs.addItems(app.store, app.gpa, &target.id, target, d.items) catch |e| {
        app.toast(.danger, "The import stopped partway", @errorName(e));
    };
    target.expanded = true;
    persist.saveTree(app, target);
    var buf: [200]u8 = undefined;
    const w = p.warnings.len;
    app.toast(if (w > 0) .warning else .success, "Imported", std.fmt.bufPrint(&buf, "{d} requests into \"{s}\"{s}", .{ d.countRequests(), target.name, if (w > 0) ", with the warnings shown" else "" }) catch "");
    commands.logLine(app, if (w > 0) .warn else .info, "Imported {d} requests from {s}, {d} warnings", .{ d.countRequests(), p.file_name, w });
    for (p.warnings) |warning| commands.logLine(app, .warn, "Import: {s}", .{warning});
}

pub const ExportFormat = enum { postman, native };

/// The collection under `n` to a file the user names.
pub fn exportCollection(app: *App, n: *col.Node, format: ExportFormat) void {
    app.store.sync();
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const c = n.root();
    var missing: std.ArrayList([]const u8) = .empty;
    const items = cs.toItems(app.store, a, &c.id, n, &missing) catch |e| {
        app.toast(.danger, "Couldn't export", @errorName(e));
        return;
    };
    const d: doc.Doc = .{ .name = n.name, .description = n.description, .items = items };
    const text = switch (format) {
        .postman => postman.exportCollection(a, d),
        .native => native.write(a, d),
    } catch |e| {
        app.toast(.danger, "Couldn't export", @errorName(e));
        return;
    };
    const suffix: []const u8 = if (format == .postman) ".postman_collection.json" else ".kest.json";
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ safeName(a, n.name), suffix }) catch return;
    if (saveToFile(app, name, text) and missing.items.len > 0) {
        var buf: [200]u8 = undefined;
        app.toast(.warning, "Some requests were left out", std.fmt.bufPrint(&buf, "{d} request files couldn't be read.", .{missing.items.len}) catch "");
    }
}

pub fn exportEnvironment(app: *App, e: *const state.Env, format: ExportFormat) void {
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const data = persist.envAsData(a, e) catch return;
    const text = (switch (format) {
        .postman => postman.exportEnvironment(a, data),
        .native => data.toJson(a),
    }) catch return;
    const suffix: []const u8 = if (format == .postman) ".postman_environment.json" else ".kest-env.json";
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ safeName(a, e.name), suffix }) catch return;
    _ = saveToFile(app, name, text);
}

/// Asks where, writes atomically. True if it was written.
pub fn saveToFile(app: *App, default_name: []const u8, text: []const u8) bool {
    const path = (platform.dialog.save(app.gpa, .{ .title = "Save as", .name = default_name }) catch return false) orelse return false;
    defer app.gpa.free(path);
    @import("export_jobs.zig").bytes(app.store, path, text) catch |e| return wrote(app, e);
    app.toast(.info, "Export queued", std.fs.path.basename(path));
    return true;
}

fn wrote(app: *App, e: anyerror) bool {
    app.toast(.danger, "Couldn't write the file", @errorName(e));
    return false;
}

fn safeName(a: Allocator, name: []const u8) []const u8 {
    const out = a.dupe(u8, name) catch return "export";
    for (out) |*b| if (std.mem.indexOfScalar(u8, "<>:\"/\\|?*", b.*) != null or b.* < 0x20) {
        b.* = '_';
    };
    return out;
}

pub fn exportSelection(app: *App, format: ExportFormat) void {
    app.store.sync();
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var missing: std.ArrayList([]const u8) = .empty;
    const d = selectionDocument(app, a, &missing) catch return;
    const text = (switch (format) {
        .postman => postman.exportCollection(a, d),
        .native => native.write(a, d),
    }) catch return;
    if (saveToFile(app, "selection.json", text) and missing.items.len > 0) app.toast(.warning, "Incomplete export", "Some request files could not be read.");
}

/// A single export document for the selected forest, preserving folder names.
pub fn selectionDocument(app: *App, a: Allocator, missing: *std.ArrayList([]const u8)) !doc.Doc {
    var items: std.ArrayList(doc.Item) = .empty;
    for (@import("../ui/sidebar.zig").selectionRoots(app, a)) |n| {
        if (n.kind == .request) {
            var request = cs.loadRequest(app.store, a, &n.root().id, &n.id) catch {
                try missing.append(a, n.name);
                continue;
            };
            request.name = n.name;
            try items.append(a, .{ .name = n.name, .description = n.description, .request = request });
        } else {
            const children = try cs.toItems(app.store, a, &n.root().id, n, missing);
            try items.append(a, .{ .name = n.name, .description = n.description, .children = children });
        }
    }
    return .{ .name = "Selected requests", .items = items.items };
}
