//! A request template plus an environment makes what goes on the wire: the
//! resolved URL, headers and body, and what couldn't be resolved.
const std = @import("std");
const req = @import("../core/request.zig");
const variables = @import("../core/variables.zig");
const url_util = @import("../utils/url.zig");
const transport = @import("transport.zig");
const Allocator = std.mem.Allocator;
const Var = variables.Var;

pub const Prepared = struct {
    out: transport.Outgoing,
    /// Variables with no value, anywhere in the request.
    unresolved: []const []const u8,
};

pub const Error = error{ InvalidUrl, InvalidHeader, OutOfMemory };

pub const Problem = struct { message: []const u8 = "" };

/// Everything in `a`: an arena living as long as the send.
pub fn prepare(a: Allocator, io: std.Io, r: req.Request, vars: []const Var, problem: *Problem) Error!Prepared {
    var unresolved: std.ArrayList([]const u8) = .empty;
    const scan = struct {
        fn f(al: Allocator, s: []const u8, v: []const Var, out: *std.ArrayList([]const u8)) !void {
            try variables.collectUnresolved(al, s, v, out);
        }
    }.f;
    try scan(a, r.url, vars, &unresolved);

    const resolved = std.mem.trim(u8, try variables.resolve(a, r.url, vars), " \t\r\n");
    // Judged as written: escaping would hide a {{variable}} or a control byte.
    _ = url_util.parse(resolved) catch |e| {
        problem.message = url_util.describe(e);
        return error.InvalidUrl;
    };
    const url = try url_util.normalize(a, resolved);

    var headers: std.ArrayList(transport.Header) = .empty;
    for (r.headers) |h| {
        if (!h.enabled or h.key.len == 0) continue;
        try scan(a, h.key, vars, &unresolved);
        try scan(a, h.value, vars, &unresolved);
        const name = try variables.resolve(a, h.key, vars);
        const value = try variables.resolve(a, h.value, vars);
        if (!transport.validHeader(name, value)) {
            problem.message = try std.fmt.allocPrint(a, "The header \"{s}\" isn't valid", .{name});
            return error.InvalidHeader;
        }
        try headers.append(a, .{ .name = name, .value = value });
    }

    var parts: std.ArrayList(transport.BodyPart) = .empty;
    var content_type: ?[]const u8 = r.body_kind.contentType();
    switch (r.body_kind) {
        .none => {},
        .json, .text, .xml => {
            try scan(a, r.body_text, vars, &unresolved);
            try parts.append(a, .{ .bytes = try variables.resolve(a, r.body_text, vars) });
        },
        .form_urlencoded => {
            var body: std.ArrayList(u8) = .empty;
            for (r.form) |f| {
                if (!f.enabled or f.key.len == 0) continue;
                try scan(a, f.key, vars, &unresolved);
                try scan(a, f.value, vars, &unresolved);
                if (body.items.len > 0) try body.append(a, '&');
                try body.appendSlice(a, try url_util.encodeForm(a, try variables.resolve(a, f.key, vars)));
                try body.append(a, '=');
                try body.appendSlice(a, try url_util.encodeForm(a, try variables.resolve(a, f.value, vars)));
            }
            try parts.append(a, .{ .bytes = body.items });
        },
        .multipart => {
            var raw: [12]u8 = undefined;
            io.random(&raw);
            const boundary = try std.fmt.allocPrint(a, "----kest{s}", .{&std.fmt.bytesToHex(raw, .lower)});
            content_type = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary});
            for (r.form) |f| {
                if (!f.enabled or f.key.len == 0) continue;
                try scan(a, f.key, vars, &unresolved);
                try scan(a, f.value, vars, &unresolved);
                const name = try quoteField(a, try variables.resolve(a, f.key, vars));
                const value = try variables.resolve(a, f.value, vars);
                if (f.is_file) {
                    const file = try quoteField(a, basename(value));
                    try parts.append(a, .{ .bytes = try std.fmt.allocPrint(a, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{ boundary, name, file, guessType(value) }) });
                    try parts.append(a, .{ .file = value });
                    try parts.append(a, .{ .bytes = "\r\n" });
                } else {
                    try parts.append(a, .{ .bytes = try std.fmt.allocPrint(a, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, name, value }) });
                }
            }
            try parts.append(a, .{ .bytes = try std.fmt.allocPrint(a, "--{s}--\r\n", .{boundary}) });
        },
        .file => {
            try scan(a, r.file_path, vars, &unresolved);
            const path = try variables.resolve(a, r.file_path, vars);
            if (path.len == 0) {
                problem.message = "Choose a file to send";
                return error.InvalidHeader;
            }
            try parts.append(a, .{ .file = path });
            content_type = guessType(path);
        },
    }
    if (content_type) |ct| {
        var has = false;
        for (headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            has = true;
        };
        if (!has) try headers.append(a, .{ .name = "Content-Type", .value = ct });
    }

    return .{
        .out = .{
            .method = try a.dupe(u8, std.mem.trim(u8, r.method, " ")),
            .url = url,
            .headers = headers.items,
            .body = parts.items,
            .follow_redirects = r.settings.follow_redirects,
            .max_redirects = r.settings.max_redirects,
            .verify_tls = r.settings.verify_tls,
        },
        .unresolved = unresolved.items,
    };
}

fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}

/// A form field's name, safe inside its quotes (as browsers escape it).
fn quoteField(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "%22"),
        '\r' => try out.appendSlice(a, "%0D"),
        '\n' => try out.appendSlice(a, "%0A"),
        else => try out.append(a, c),
    };
    return out.items;
}

fn guessType(path: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".json", "application/json" }, .{ ".xml", "application/xml" },
        .{ ".txt", "text/plain" },        .{ ".csv", "text/csv" },
        .{ ".html", "text/html" },        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },         .{ ".svg", "image/svg+xml" },
        .{ ".pdf", "application/pdf" },   .{ ".zip", "application/zip" },
        .{ ".gz", "application/gzip" },
    };
    for (types) |entry| if (std.ascii.endsWithIgnoreCase(path, entry[0])) return entry[1];
    return "application/octet-stream";
}

/// The resolved URL, for the preview under the URL bar: never fails.
pub fn previewUrl(a: Allocator, url: []const u8, vars: []const Var) ![]u8 {
    return variables.resolve(a, url, vars);
}

const t = std.testing;

test "variables reach everywhere, and what's missing is reported" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const vars = [_]Var{ .{ .key = "base", .value = "http://h:1" }, .{ .key = "id", .value = "7" }, .{ .key = "tok", .value = "s3" } };
    var problem: Problem = .{};
    const p = try prepare(a, t.io, .{
        .method = "POST",
        .url = "{{base}}/u/{{id}}?q={{id}}&sp=a b",
        .headers = &.{ .{ .key = "Authorization", .value = "Bearer {{tok}}" }, .{ .key = "X-Off", .value = "x", .enabled = false }, .{ .key = "X-Miss", .value = "{{nope}}" } },
        .body_kind = .json,
        .body_text = "{\"id\":{{id}},\"m\":\"{{other}}\"}",
    }, &vars, &problem);
    try t.expectEqualStrings("http://h:1/u/7?q=7&sp=a%20b", p.out.url);
    try t.expectEqual(@as(usize, 3), p.out.headers.len);
    try t.expectEqualStrings("Bearer s3", p.out.headers[0].value);
    try t.expectEqualStrings("application/json", p.out.headers[2].value);
    try t.expectEqualStrings("{\"id\":7,\"m\":\"{{other}}\"}", p.out.body[0].bytes);
    try t.expectEqual(@as(usize, 2), p.unresolved.len);
    try t.expectEqualStrings("nope", p.unresolved[0]);
    try t.expectEqualStrings("other", p.unresolved[1]);
}

test "a chosen content type stays" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var problem: Problem = .{};
    const p = try prepare(ar.allocator(), t.io, .{
        .method = "POST",
        .url = "http://h",
        .headers = &.{.{ .key = "content-type", .value = "application/vnd.x+json" }},
        .body_kind = .json,
    }, &.{}, &problem);
    try t.expectEqual(@as(usize, 1), p.out.headers.len);
}

test "forms are encoded" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var problem: Problem = .{};
    const p = try prepare(ar.allocator(), t.io, .{
        .method = "POST",
        .url = "http://h",
        .body_kind = .form_urlencoded,
        .form = &.{ .{ .key = "a b", .value = "c&d" }, .{ .key = "off", .value = "x", .enabled = false }, .{ .key = "e", .value = "é" } },
    }, &.{}, &problem);
    try t.expectEqualStrings("a+b=c%26d&e=%C3%A9", p.out.body[0].bytes);
}

test "multipart parts" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var problem: Problem = .{};
    const p = try prepare(ar.allocator(), t.io, .{
        .method = "POST",
        .url = "http://h",
        .body_kind = .multipart,
        .form = &.{ .{ .key = "title", .value = "x" }, .{ .key = "up\"load", .value = "C:\\dir\\a.png", .is_file = true } },
    }, &.{}, &problem);
    try t.expectEqual(@as(usize, 5), p.out.body.len);
    try t.expect(std.mem.indexOf(u8, p.out.body[0].bytes, "name=\"title\"") != null);
    try t.expect(std.mem.indexOf(u8, p.out.body[1].bytes, "name=\"up%22load\"; filename=\"a.png\"") != null);
    try t.expect(std.mem.indexOf(u8, p.out.body[1].bytes, "image/png") != null);
    try t.expectEqualStrings("C:\\dir\\a.png", p.out.body[2].file);
    try t.expect(std.mem.endsWith(u8, p.out.body[4].bytes, "--\r\n"));
    try t.expect(std.mem.startsWith(u8, p.out.headers[0].value, "multipart/form-data; boundary=----kest"));
}

test "bad input is explained, not sent" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var problem: Problem = .{};
    try t.expectError(error.InvalidUrl, prepare(a, t.io, .{ .url = "{{nope}}/x" }, &.{}, &problem));
    try t.expectEqualStrings("The URL has an unresolved {{variable}}", problem.message);
    try t.expectError(error.InvalidUrl, prepare(a, t.io, .{ .url = "" }, &.{}, &problem));
    const evil = [_]Var{.{ .key = "v", .value = "a\r\nEvil: 1" }};
    try t.expectError(error.InvalidHeader, prepare(a, t.io, .{ .url = "http://h", .headers = &.{.{ .key = "X", .value = "{{v}}" }} }, &evil, &problem));
    try t.expectError(error.InvalidHeader, prepare(a, t.io, .{ .url = "http://h", .body_kind = .file }, &.{}, &problem));
}
