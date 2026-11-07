//! Postman Collection v2.1 and Environment files. What can't be carried over
//! (auth, scripts, saved responses, GraphQL, collection variables) is named in
//! the import's warnings; the request data around it is kept.
const std = @import("std");
const json = @import("../utils/json.zig");
const req = @import("../core/request.zig");
const url_util = @import("../utils/url.zig");
const doc = @import("doc.zig");
const environment = @import("../core/environment.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const KeyValue = req.KeyValue;

pub const schema_v21 = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json";

pub const ImportError = error{ NotJson, NotACollection, UnsupportedVersion, OutOfMemory };

pub fn describe(e: ImportError) []const u8 {
    return switch (e) {
        error.NotJson => "The file isn't valid JSON",
        error.NotACollection => "The file isn't a Postman collection: it has no info and item",
        error.UnsupportedVersion => "Only Postman Collection v2.0 and v2.1 can be imported",
        error.OutOfMemory => "Out of memory",
    };
}

const Ctx = struct {
    a: Allocator,
    warnings: std.ArrayList([]const u8) = .empty,
    auth: usize = 0,
    scripts: usize = 0,
    responses: usize = 0,
    graphql: usize = 0,
    path_vars: usize = 0,
    multi_src: usize = 0,

    fn warn(c: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try c.warnings.append(c.a, try std.fmt.allocPrint(c.a, fmt, args));
    }
};

/// Everything is allocated in `a`: use an arena.
pub fn importCollection(a: Allocator, text: []const u8) ImportError!doc.Doc {
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const info = json.get(v, "info") orelse return error.NotACollection;
    if (json.get(v, "item") == null or info != .object) return error.NotACollection;
    var c: Ctx = .{ .a = a };
    const schema = json.str(info, "schema") orelse "";
    if (std.mem.indexOf(u8, schema, "v2.1") == null) {
        if (std.mem.indexOf(u8, schema, "v2.0") != null) {
            try c.warn("This is a v2.0 collection; it was read as v2.1, which is nearly the same", .{});
        } else return error.UnsupportedVersion;
    }
    if (json.get(v, "auth") != null) c.auth += 1;
    if (json.array(v, "event").len > 0) c.scripts += 1;
    const items = try parseItems(&c, json.array(v, "item"));
    const var_count = json.array(v, "variable").len;
    if (var_count > 0) try c.warn("{d} collection variable(s) weren't imported: add them to an environment", .{var_count});
    if (c.auth > 0) try c.warn("Authentication settings on {d} item(s) weren't imported: add an Authorization header", .{c.auth});
    if (c.scripts > 0) try c.warn("Scripts on {d} item(s) weren't imported", .{c.scripts});
    if (c.responses > 0) try c.warn("{d} saved example response(s) weren't imported", .{c.responses});
    if (c.graphql > 0) try c.warn("{d} GraphQL request(s) were kept as plain JSON bodies", .{c.graphql});
    if (c.path_vars > 0) try c.warn("Path variables on {d} request(s) weren't imported: :names stay in the URL", .{c.path_vars});
    if (c.multi_src > 0) try c.warn("{d} form field(s) with several files keep only the first", .{c.multi_src});
    return .{
        .name = try json.dupeStr(a, info, "name", "Imported collection"),
        .description = try descriptionOf(a, json.get(info, "description")),
        .items = items,
        .warnings = c.warnings.items,
    };
}

fn parseItems(c: *Ctx, items: []const Value) ImportError![]const doc.Item {
    var out: std.ArrayList(doc.Item) = .empty;
    for (items) |it| {
        if (it != .object) continue;
        if (json.get(it, "auth") != null) c.auth += 1;
        if (json.array(it, "event").len > 0) c.scripts += 1;
        c.responses += json.array(it, "response").len;
        const name = try json.dupeStr(c.a, it, "name", "Untitled");
        if (json.get(it, "item") != null) {
            try out.append(c.a, .{
                .name = name,
                .description = try descriptionOf(c.a, json.get(it, "description")),
                .children = try parseItems(c, json.array(it, "item")),
            });
        } else if (json.get(it, "request")) |r| {
            const request = try parseRequest(c, r, name);
            try out.append(c.a, .{ .name = name, .description = request.description, .request = request });
        }
    }
    return out.items;
}

fn descriptionOf(a: Allocator, v: ?Value) ![]const u8 {
    const d = v orelse return "";
    return switch (d) {
        .string => |s| try a.dupe(u8, s),
        .object => try json.dupeStr(a, d, "content", ""),
        else => "",
    };
}

fn parseRequest(c: *Ctx, r: Value, name: []const u8) ImportError!req.Request {
    const a = c.a;
    var out: req.Request = .{ .name = name };
    // A request may be just its URL.
    if (r == .string) {
        out.url = try a.dupe(u8, r.string);
        out.params = try url_util.parseParams(a, r.string);
        return out;
    }
    if (r != .object) return out;
    if (json.get(r, "auth") != null) c.auth += 1;
    out.method = try json.dupeStr(a, r, "method", "GET");
    out.description = try descriptionOf(a, json.get(r, "description"));
    out.headers = try parseRows(a, json.array(r, "header"));
    if (json.get(r, "url")) |u| try parseUrl(c, u, &out);
    if (json.get(r, "body")) |b| try parseBody(c, b, &out);
    return out;
}

fn parseRows(a: Allocator, rows: []const Value) ![]const KeyValue {
    var out: std.ArrayList(KeyValue) = .empty;
    for (rows) |h| {
        if (h != .object) continue;
        try out.append(a, .{
            .key = try json.dupeStr(a, h, "key", ""),
            .value = try json.dupeStr(a, h, "value", ""),
            .enabled = !(json.boolean(h, "disabled") orelse false),
        });
    }
    return out.items;
}

fn parseUrl(c: *Ctx, u: Value, out: *req.Request) !void {
    const a = c.a;
    if (u == .string) {
        out.url = try a.dupe(u8, u.string);
        out.params = try url_util.parseParams(a, u.string);
        return;
    }
    if (u != .object) return;
    if (json.array(u, "variable").len > 0) c.path_vars += 1;
    if (json.str(u, "raw")) |raw| {
        out.url = try a.dupe(u8, raw);
    } else {
        out.url = try urlFromParts(a, u);
    }
    if (json.get(u, "query") != null) {
        out.params = try parseRows(a, json.array(u, "query"));
    } else {
        out.params = try url_util.parseParams(a, out.url);
    }
}

fn urlFromParts(a: Allocator, u: Value) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    if (json.str(u, "protocol")) |p| {
        try s.appendSlice(a, p);
        try s.appendSlice(a, "://");
    }
    try joinPart(a, &s, json.get(u, "host"), ".");
    if (json.str(u, "port")) |p| {
        try s.append(a, ':');
        try s.appendSlice(a, p);
    }
    if (json.get(u, "path")) |p| {
        const is_empty = (p == .array and p.array.items.len == 0) or (p == .string and p.string.len == 0);
        if (!is_empty) {
            if (!(p == .string and p.string[0] == '/')) try s.append(a, '/');
            try joinPart(a, &s, p, "/");
        }
    }
    const url = try s.toOwnedSlice(a);
    const rows = try parseRows(a, json.array(u, "query"));
    return url_util.withParams(a, url, rows);
}

fn joinPart(a: Allocator, s: *std.ArrayList(u8), v: ?Value, sep: []const u8) !void {
    const part = v orelse return;
    switch (part) {
        .string => |p| try s.appendSlice(a, p),
        .array => |arr| for (arr.items, 0..) |item, i| {
            if (i > 0) try s.appendSlice(a, sep);
            // A path segment may be {type, value}.
            if (item == .string) try s.appendSlice(a, item.string) else if (json.str(item, "value")) |x| try s.appendSlice(a, x);
        },
        else => {},
    }
}

fn parseBody(c: *Ctx, b: Value, out: *req.Request) !void {
    const a = c.a;
    if (b != .object) return;
    const mode = json.str(b, "mode") orelse return;
    if (std.mem.eql(u8, mode, "raw")) {
        out.body_text = try json.dupeStr(a, b, "raw", "");
        var language: []const u8 = "";
        if (json.get(b, "options")) |o| if (json.get(o, "raw")) |r| {
            language = json.str(r, "language") orelse "";
        };
        out.body_kind = if (std.ascii.eqlIgnoreCase(language, "json")) .json else if (std.ascii.eqlIgnoreCase(language, "xml")) .xml else fromHeader(out.*);
    } else if (std.mem.eql(u8, mode, "urlencoded")) {
        out.body_kind = .form_urlencoded;
        out.form = try parseRows(a, json.array(b, "urlencoded"));
    } else if (std.mem.eql(u8, mode, "formdata")) {
        out.body_kind = .multipart;
        var rows: std.ArrayList(KeyValue) = .empty;
        for (json.array(b, "formdata")) |f| {
            if (f != .object) continue;
            const is_file = std.mem.eql(u8, json.str(f, "type") orelse "text", "file");
            var value: []const u8 = json.str(f, "value") orelse "";
            if (is_file) if (json.get(f, "src")) |src| switch (src) {
                .string => |p| value = p,
                .array => |arr| {
                    if (arr.items.len > 1) c.multi_src += 1;
                    if (arr.items.len > 0 and arr.items[0] == .string) value = arr.items[0].string;
                },
                else => {},
            };
            try rows.append(a, .{
                .key = try json.dupeStr(a, f, "key", ""),
                .value = try a.dupe(u8, value),
                .enabled = !(json.boolean(f, "disabled") orelse false),
                .is_file = is_file,
            });
        }
        out.form = rows.items;
    } else if (std.mem.eql(u8, mode, "file")) {
        out.body_kind = .file;
        if (json.get(b, "file")) |f| out.file_path = try json.dupeStr(a, f, "src", "");
    } else if (std.mem.eql(u8, mode, "graphql")) {
        c.graphql += 1;
        out.body_kind = .json;
        if (json.get(b, "graphql")) |g| {
            var w: std.Io.Writer.Allocating = .init(a);
            std.json.Stringify.value(g, .{ .whitespace = .indent_2 }, &w.writer) catch return error.OutOfMemory;
            out.body_text = try w.toOwnedSlice();
        }
    }
}

fn fromHeader(r: req.Request) req.BodyKind {
    const ct = r.header("content-type") orelse return .text;
    if (std.ascii.findIgnoreCase(ct, "json") != null) return .json;
    if (std.ascii.findIgnoreCase(ct, "xml") != null) return .xml;
    return .text;
}

/// Doc as a Postman Collection v2.1 file.
pub fn exportCollection(a: Allocator, d: doc.Doc) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeCollection(&s, a, d) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeCollection(s: *std.json.Stringify, a: Allocator, d: doc.Doc) !void {
    try s.beginObject();
    try s.objectField("info");
    try s.beginObject();
    try json.field(s, "name", d.name);
    if (d.description.len > 0) try json.field(s, "description", d.description);
    try json.field(s, "schema", schema_v21);
    try s.endObject();
    try s.objectField("item");
    try writeItems(s, a, d.items);
    try s.endObject();
}

fn writeItems(s: *std.json.Stringify, a: Allocator, items: []const doc.Item) anyerror!void {
    try s.beginArray();
    for (items) |i| {
        try s.beginObject();
        try json.field(s, "name", i.name);
        if (i.request) |r| {
            try s.objectField("request");
            try writeRequest(s, a, r);
        } else {
            if (i.description.len > 0) try json.field(s, "description", i.description);
            try s.objectField("item");
            try writeItems(s, a, i.children);
        }
        try s.endObject();
    }
    try s.endArray();
}

fn writeRows(s: *std.json.Stringify, rows: []const KeyValue) !void {
    try s.beginArray();
    for (rows) |r| {
        try s.beginObject();
        try json.field(s, "key", r.key);
        try json.field(s, "value", r.value);
        if (!r.enabled) try json.field(s, "disabled", true);
        try s.endObject();
    }
    try s.endArray();
}

fn writeRequest(s: *std.json.Stringify, a: Allocator, r: req.Request) !void {
    try s.beginObject();
    try json.field(s, "method", r.method);
    if (r.description.len > 0) try json.field(s, "description", r.description);
    try s.objectField("header");
    try writeRows(s, r.headers);
    try s.objectField("url");
    try writeUrl(s, a, r);
    if (r.body_kind != .none) {
        try s.objectField("body");
        try writeBody(s, r);
    }
    try s.endObject();
}

fn writeUrl(s: *std.json.Stringify, a: Allocator, r: req.Request) !void {
    const parts = url_util.split(r.url);
    try s.beginObject();
    try json.field(s, "raw", r.url);
    var rest = parts.base;
    if (std.mem.indexOf(u8, rest, "://")) |sep| {
        try json.field(s, "protocol", rest[0..sep]);
        rest = rest[sep + 3 ..];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var authority = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| if (std.mem.indexOf(u8, authority, "{{") == null and authority[0] != '[') {
        try json.field(s, "port", authority[colon + 1 ..]);
        authority = authority[0..colon];
    };
    try s.objectField("host");
    try s.beginArray();
    if (std.mem.indexOf(u8, authority, "{{") != null) {
        try s.write(authority);
    } else {
        var it = std.mem.splitScalar(u8, authority, '.');
        while (it.next()) |h| try s.write(h);
    }
    try s.endArray();
    try s.objectField("path");
    try s.beginArray();
    if (slash < rest.len) {
        var it = std.mem.splitScalar(u8, rest[slash + 1 ..], '/');
        while (it.next()) |p| try s.write(p);
    }
    try s.endArray();
    if (r.params.len > 0) {
        try s.objectField("query");
        try writeRows(s, r.params);
    } else {
        const params = try url_util.parseParams(a, r.url);
        defer {
            for (params) |p| {
                a.free(p.key);
                a.free(p.value);
            }
            a.free(params);
        }
        if (params.len > 0) {
            try s.objectField("query");
            try writeRows(s, params);
        }
    }
    try s.endObject();
}

fn writeBody(s: *std.json.Stringify, r: req.Request) !void {
    try s.beginObject();
    switch (r.body_kind) {
        .none => {},
        .json, .text, .xml => {
            try json.field(s, "mode", "raw");
            try json.field(s, "raw", r.body_text);
            try s.objectField("options");
            try s.beginObject();
            try s.objectField("raw");
            try s.beginObject();
            try json.field(s, "language", switch (r.body_kind) {
                .json => "json",
                .xml => "xml",
                else => "text",
            });
            try s.endObject();
            try s.endObject();
        },
        .form_urlencoded => {
            try json.field(s, "mode", "urlencoded");
            try s.objectField("urlencoded");
            try writeRows(s, r.form);
        },
        .multipart => {
            try json.field(s, "mode", "formdata");
            try s.objectField("formdata");
            try s.beginArray();
            for (r.form) |f| {
                try s.beginObject();
                try json.field(s, "key", f.key);
                if (f.is_file) {
                    try json.field(s, "type", "file");
                    try json.field(s, "src", f.value);
                } else {
                    try json.field(s, "type", "text");
                    try json.field(s, "value", f.value);
                }
                if (!f.enabled) try json.field(s, "disabled", true);
                try s.endObject();
            }
            try s.endArray();
        },
        .file => {
            try json.field(s, "mode", "file");
            try s.objectField("file");
            try s.beginObject();
            try json.field(s, "src", r.file_path);
            try s.endObject();
        },
    }
    try s.endObject();
}

/// An environment as a Postman Environment file.
pub fn exportEnvironment(a: Allocator, e: environment.Environment) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    writeEnvironment(&s, e) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeEnvironment(s: *std.json.Stringify, e: environment.Environment) !void {
    try s.beginObject();
    try json.field(s, "name", e.name);
    try s.objectField("values");
    try s.beginArray();
    for (e.vars) |v| {
        try s.beginObject();
        try json.field(s, "key", v.key);
        try json.field(s, "value", v.value);
        try json.field(s, "enabled", v.enabled);
        try json.field(s, "type", "default");
        try s.endObject();
    }
    try s.endArray();
    try json.field(s, "_postman_variable_scope", "environment");
    try s.endObject();
}

/// Reads a Postman Environment (or native) file.
pub fn importEnvironment(a: Allocator, text: []const u8) !environment.Environment {
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (json.get(v, "values") == null and json.get(v, "variables") == null) return error.NotAnEnvironment;
    return environment.Environment.parse(a, v);
}
