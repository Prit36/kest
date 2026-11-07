//! Content detection over the entire available body, without allocating or
//! changing it. Completed network jobs run this on their worker before publish.
const std = @import("std");
const json = @import("../utils/json.zig");

pub const Class = enum { json, xml, html, text, image, binary };
pub const Info = struct {
    kind: Class,
    /// Only a declared JSON response warrants an invalid-JSON diagnostic.
    json_problem: ?json.Problem = null,
    json_incomplete: bool = false,
    json_limited: bool = false,
};

pub fn mime(content_type: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], " \t");
}

pub fn declaresJson(content_type: []const u8) bool {
    const value = mime(content_type);
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const subtype = value[slash + 1 ..];
    return std.ascii.eqlIgnoreCase(subtype, "json") or std.ascii.endsWithIgnoreCase(subtype, "+json");
}

pub fn inspect(content_type: []const u8, body: []const u8, whole: bool) Info {
    const ct = mime(content_type);
    const svg = std.ascii.eqlIgnoreCase(ct, "image/svg+xml");
    // Raster bytes are expected to be binary; SVG is text and uses the XML view.
    if ((!svg and std.ascii.startsWithIgnoreCase(ct, "image/")) or
        std.mem.startsWith(u8, body, "\x89PNG\r\n\x1a\n") or
        std.mem.startsWith(u8, body, "\xff\xd8\xff") or
        std.mem.startsWith(u8, body, "GIF87a") or std.mem.startsWith(u8, body, "GIF89a")) return .{ .kind = .image };
    if (binary(body, !whole)) return .{ .kind = .binary };
    if (svg or std.ascii.eqlIgnoreCase(ct, "application/xml") or std.ascii.eqlIgnoreCase(ct, "text/xml") or std.ascii.endsWithIgnoreCase(ct, "+xml")) return .{ .kind = .xml };
    if (std.ascii.eqlIgnoreCase(ct, "text/html")) return .{ .kind = .html };
    if (std.ascii.eqlIgnoreCase(ct, "text/markdown") or std.ascii.eqlIgnoreCase(ct, "text/x-markdown")) return .{ .kind = .text };

    const declared = declaresJson(ct);
    const start = std.mem.trimStart(u8, body, " \t\r\n");
    const candidate = start.len > 0 and switch (start[0]) {
        '{', '[', '"', '-', '0'...'9', 't', 'f', 'n' => true,
        else => false,
    };
    if (declared or candidate) {
        if (!whole) return .{ .kind = .text, .json_incomplete = declared };
        const problem = json.validate(body);
        if (problem == null) return .{ .kind = .json };
        if (declared) {
            if (std.mem.eql(u8, problem.?.message, "Nested too deeply")) return .{ .kind = .text, .json_limited = true };
            return .{ .kind = .text, .json_problem = problem };
        }
    }
    if (std.ascii.startsWithIgnoreCase(start, "<!doctype html") or std.ascii.startsWithIgnoreCase(start, "<html")) return .{ .kind = .html };
    if (std.mem.startsWith(u8, start, "<?xml")) return .{ .kind = .xml };
    return .{ .kind = .text };
}

/// Scan all available bytes: a late NUL or invalid UTF-8 must not reach a text
/// widget just because the server called it text/plain. A clipped preview may
/// end inside an otherwise valid UTF-8 sequence; that alone is not binary.
pub fn binary(body: []const u8, allow_cut_sequence: bool) bool {
    var controls: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        const byte = body[i];
        if (byte == 0) return true;
        if (byte < 0x80) {
            if ((byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n') or byte == 0x7f) controls += 1;
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(byte) catch return true;
            if (body.len - i < len) {
                if (!allow_cut_sequence) return true;
                if (byte < 0xc2 or byte > 0xf4) return true;
                // All available continuation bytes must still be plausible.
                for (body[i + 1 ..]) |tail| if (tail & 0xc0 != 0x80) return true;
                if (body.len - i > 1) {
                    const next = body[i + 1];
                    if ((byte == 0xe0 and next < 0xa0) or (byte == 0xed and next >= 0xa0) or
                        (byte == 0xf0 and next < 0x90) or (byte == 0xf4 and next >= 0x90)) return true;
                }
                return controls > body.len / 10;
            }
            if (!std.unicode.utf8ValidateSlice(body[i .. i + len])) return true;
            i += len;
        }
    }
    return controls > body.len / 10;
}

test "JSON requires one valid whole document, regardless of a MIME hint" {
    const t = std.testing;
    for ([_][]const u8{ "{}", " \r\n[1,2] \t", "42", "true", "null", "\"hello\"", "-1.10e+2" }) |body| {
        try t.expectEqual(Class.json, inspect("text/plain", body, true).kind);
        try t.expectEqual(Class.json, inspect("Application/Problem+JSON; charset=utf-8", body, true).kind);
    }
    for ([_][]const u8{ "", "{\"a\":1", "[1,]", "{} trailing", "{}{}", "HTTP/1.1 200 OK\n{\"a\":1}", "prefix {\"a\":1}", "{\"s\":\"\\q\"}", "{\"s\":\"\\uXX00\"}", "{\"s\":\"a\tb\"}" }) |body| {
        const result = inspect("application/json", body, true);
        try t.expectEqual(Class.text, result.kind);
        try t.expect(result.json_problem != null);
        const plain = inspect("text/plain", body, true);
        try t.expectEqual(Class.text, plain.kind);
        try t.expect(plain.json_problem == null);
    }
    try t.expect(!declaresJson("application/notjson"));
    try t.expect(!declaresJson("text/plain; name=application/json"));
    const prefix = inspect("application/json", "{}", false);
    try t.expectEqual(Class.text, prefix.kind);
    try t.expect(prefix.json_incomplete and prefix.json_problem == null);
    var deep: [8203]u8 = undefined;
    @memset(deep[0..4101], '[');
    deep[4101] = '0';
    @memset(deep[4102..], ']');
    const limited = inspect("application/json", &deep, true);
    try t.expect(limited.kind == .text and limited.json_limited and limited.json_problem == null);
}

test "binary checks override text MIME and inspect beyond the first sample" {
    const t = std.testing;
    var late: [16 * 1024]u8 = @splat('a');
    late[late.len - 1] = 0;
    for ([_][]const u8{ "text/plain", "application/json", "text/html", "image/svg+xml", "" }) |ct|
        try t.expectEqual(Class.binary, inspect(ct, &late, true).kind);
    try t.expectEqual(Class.binary, inspect("text/plain", "one\xfftwo", true).kind);
    try t.expectEqual(Class.text, inspect("", "h\xc3\xa9llo\r\n\tworld", true).kind);
    try t.expectEqual(Class.text, inspect("text/plain", "end\xe2\x82", false).kind);
    try t.expectEqual(Class.binary, inspect("text/plain", "end\xe2\x82", true).kind);
    try t.expectEqual(Class.binary, inspect("text/plain", "end\xe2?", false).kind);
    try t.expectEqual(Class.binary, inspect("text/plain", "end\xc0", false).kind);
    try t.expectEqual(Class.binary, inspect("text/plain", "end\xed\xa0", false).kind);
    try t.expectEqual(Class.xml, inspect("image/svg+xml", "<svg/>", true).kind);
    try t.expectEqual(Class.image, inspect("application/octet-stream", "\x89PNG\r\n\x1a\nxxxx", true).kind);
    try t.expectEqual(Class.text, inspect("text/plain; name=html", "plain text", true).kind);
    try t.expectEqual(Class.text, inspect("text/markdown", "42", true).kind);
}
