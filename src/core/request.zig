//! A saved HTTP request: plain data whose strings live in an arena, and its
//! human-readable JSON form (`retort.request/1`). Templates stay templates:
//! `{{variables}}` are only resolved when a request is sent.
const std = @import("std");
const json = @import("../utils/json.zig");
const Allocator = std.mem.Allocator;

pub const KeyValue = struct {
    key: []const u8 = "",
    value: []const u8 = "",
    enabled: bool = true,
    /// Multipart only: `value` is a path to upload.
    is_file: bool = false,
};

pub const BodyKind = enum {
    none,
    json,
    text,
    xml,
    form_urlencoded,
    multipart,
    /// The whole body is the contents of `file_path`.
    file,

    pub fn contentType(k: BodyKind) ?[]const u8 {
        return switch (k) {
            .none, .multipart, .file => null, // multipart needs its boundary
            .json => "application/json",
            .text => "text/plain; charset=utf-8",
            .xml => "application/xml",
            .form_urlencoded => "application/x-www-form-urlencoded",
        };
    }
};

pub const default_max_response: u64 = 256 * 1024 * 1024;

pub const Settings = struct {
    timeout_ms: u32 = 30_000,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    max_response_bytes: u64 = default_max_response,
    verify_tls: bool = true,
};

pub const Request = struct {
    name: []const u8 = "Untitled",
    description: []const u8 = "",
    method: []const u8 = "GET",
    url: []const u8 = "",
    /// Disabled rows live here only; enabled rows are also in `url`'s query.
    params: []const KeyValue = &.{},
    headers: []const KeyValue = &.{},
    body_kind: BodyKind = .none,
    body_text: []const u8 = "",
    form: []const KeyValue = &.{},
    file_path: []const u8 = "",
    settings: Settings = .{},

    pub fn write(r: Request, s: *std.json.Stringify) !void {
        try s.beginObject();
        try json.field(s, "format", "retort.request/1");
        try r.writeFields(s);
        try s.endObject();
    }

    /// The fields without the object around them: exports embed them.
    pub fn writeFields(r: Request, s: *std.json.Stringify) !void {
        try json.field(s, "name", r.name);
        if (r.description.len > 0) try json.field(s, "description", r.description);
        try json.field(s, "method", r.method);
        try json.field(s, "url", r.url);
        try writeRows(s, "params", r.params);
        try writeRows(s, "headers", r.headers);
        try s.objectField("body");
        try s.beginObject();
        try json.field(s, "kind", @tagName(r.body_kind));
        if (r.body_text.len > 0) try json.field(s, "text", r.body_text);
        if (r.form.len > 0) try writeRows(s, "form", r.form);
        if (r.file_path.len > 0) try json.field(s, "file", r.file_path);
        try s.endObject();
        try s.objectField("settings");
        try s.write(r.settings);
    }

    /// Reads what `write` wrote, forgiving what's missing: files are for
    /// people too. Every string is copied into `arena`.
    pub fn parse(arena: Allocator, v: std.json.Value) !Request {
        if (v != .object) return error.NotAnObject;
        var r: Request = .{};
        r.name = try json.dupeStr(arena, v, "name", r.name);
        r.description = try json.dupeStr(arena, v, "description", "");
        r.method = try json.dupeStr(arena, v, "method", "GET");
        r.url = try json.dupeStr(arena, v, "url", "");
        r.params = try parseRows(arena, json.get(v, "params"));
        r.headers = try parseRows(arena, json.get(v, "headers"));
        if (json.get(v, "body")) |b| {
            const kind = json.str(b, "kind") orelse "none";
            r.body_kind = std.meta.stringToEnum(BodyKind, kind) orelse .none;
            r.body_text = try json.dupeStr(arena, b, "text", "");
            r.form = try parseRows(arena, json.get(b, "form"));
            r.file_path = try json.dupeStr(arena, b, "file", "");
        }
        if (json.get(v, "settings")) |st| {
            const d: Settings = .{};
            r.settings = .{
                .timeout_ms = @intCast(std.math.clamp(json.int(st, "timeout_ms") orelse d.timeout_ms, 0, std.math.maxInt(u32))),
                .follow_redirects = json.boolean(st, "follow_redirects") orelse d.follow_redirects,
                .max_redirects = @intCast(std.math.clamp(json.int(st, "max_redirects") orelse d.max_redirects, 0, 50)),
                .max_response_bytes = @intCast(@max(json.int(st, "max_response_bytes") orelse @as(i64, @intCast(d.max_response_bytes)), 0)),
                .verify_tls = json.boolean(st, "verify_tls") orelse d.verify_tls,
            };
        }
        return r;
    }

    pub fn clone(r: Request, a: Allocator) !Request {
        var o = r;
        o.name = try a.dupe(u8, r.name);
        o.description = try a.dupe(u8, r.description);
        o.method = try a.dupe(u8, r.method);
        o.url = try a.dupe(u8, r.url);
        o.params = try cloneRows(a, r.params);
        o.headers = try cloneRows(a, r.headers);
        o.body_text = try a.dupe(u8, r.body_text);
        o.form = try cloneRows(a, r.form);
        o.file_path = try a.dupe(u8, r.file_path);
        return o;
    }

    pub fn toJson(r: Request, a: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        r.write(&s) catch return error.OutOfMemory;
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }

    /// The first header named `name` that is on.
    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (h.enabled and std.ascii.eqlIgnoreCase(h.key, name)) return h.value;
        return null;
    }
};

fn cloneRows(a: Allocator, rows: []const KeyValue) ![]const KeyValue {
    const out = try a.alloc(KeyValue, rows.len);
    for (rows, out) |r, *o| o.* = .{ .key = try a.dupe(u8, r.key), .value = try a.dupe(u8, r.value), .enabled = r.enabled, .is_file = r.is_file };
    return out;
}

fn writeRows(s: *std.json.Stringify, name: []const u8, rows: []const KeyValue) !void {
    try s.objectField(name);
    try s.beginArray();
    for (rows) |r| {
        try s.beginObject();
        try json.field(s, "key", r.key);
        try json.field(s, "value", r.value);
        if (!r.enabled) try json.field(s, "enabled", false);
        if (r.is_file) try json.field(s, "file", true);
        try s.endObject();
    }
    try s.endArray();
}

fn parseRows(arena: Allocator, v: ?std.json.Value) ![]const KeyValue {
    const list = v orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(KeyValue) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        try out.append(arena, .{
            .key = try json.dupeStr(arena, item, "key", ""),
            .value = try json.dupeStr(arena, item, "value", ""),
            .enabled = json.boolean(item, "enabled") orelse true,
            .is_file = json.boolean(item, "file") orelse false,
        });
    }
    return out.items;
}

test "a request survives its file form" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r: Request = .{
        .name = "Get \"user\"",
        .description = "line one\nline two",
        .method = "PURGE",
        .url = "{{base}}/u?a=1",
        .params = &.{ .{ .key = "a", .value = "1" }, .{ .key = "off", .value = "x", .enabled = false } },
        .headers = &.{.{ .key = "Accept", .value = "*/*" }},
        .body_kind = .multipart,
        .form = &.{.{ .key = "f", .value = "C:\\a b.png", .is_file = true }},
        .settings = .{ .timeout_ms = 5, .follow_redirects = false, .max_redirects = 2, .max_response_bytes = 7, .verify_tls = false },
    };
    const text = try r.toJson(a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const back = try Request.parse(a, v);
    try std.testing.expectEqualStrings(r.name, back.name);
    try std.testing.expectEqualStrings(r.description, back.description);
    try std.testing.expectEqualStrings("PURGE", back.method);
    try std.testing.expectEqual(@as(usize, 2), back.params.len);
    try std.testing.expect(!back.params[1].enabled);
    try std.testing.expect(back.form[0].is_file);
    try std.testing.expectEqual(BodyKind.multipart, back.body_kind);
    try std.testing.expectEqual(r.settings, back.settings);
}

test "missing fields take their defaults" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"url\":\"http://x\",\"body\":{\"kind\":\"nonsense\"},\"headers\":3}", .{});
    const r = try Request.parse(a, v);
    try std.testing.expectEqualStrings("GET", r.method);
    try std.testing.expectEqual(BodyKind.none, r.body_kind);
    try std.testing.expectEqual(@as(usize, 0), r.headers.len);
    try std.testing.expect(r.settings.verify_tls);
}
