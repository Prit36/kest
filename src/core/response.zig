//! A response as it arrives on a worker thread and as the viewer reads it.
//! Its body is bounded in memory: the first `memory_limit` bytes are kept for
//! display, and once a body outgrows them every byte goes to a temporary file
//! instead, from which Save copies it whole.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const transport = @import("../network/transport.zig");

pub const default_memory_limit = 8 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const ContentClass = enum { json, xml, html, text, image, binary };

pub const Stop = enum {
    /// The whole body arrived.
    complete,
    /// Over the request's size limit: what came before it is kept.
    too_large,
    canceled,
    timed_out,
    /// The transfer broke partway, or there was no response at all.
    failed,
};

pub const Response = struct {
    gpa: Allocator,
    io: Io,
    /// Set once a head arrived; 0 means no response.
    status: u16 = 0,
    reason: []u8 = &.{},
    url: []u8 = &.{},
    redirects: u8 = 0,
    raw_headers: []u8 = &.{},
    headers: std.ArrayList(Header) = .empty,
    content_type: []const u8 = "",
    /// The first bytes of the body, decoded.
    preview: std.ArrayList(u8) = .empty,
    /// Bytes received so far, decoded (read across threads for progress).
    total: std.atomic.Value(u64) = .init(0),
    /// Set when the body outgrew memory: the file with all of it.
    spill_path: ?[]u8 = null,
    spill_file: ?Io.File = null,
    spill_failed: bool = false,
    spill_dir: []const u8,
    memory_limit: usize = default_memory_limit,
    max_bytes: u64 = 256 * 1024 * 1024,
    stop: Stop = .complete,
    time_ms: u32 = 0,
    /// Why the request failed, for the user.
    error_text: []u8 = &.{},
    reused_connection: bool = false,

    pub fn init(gpa: Allocator, io: Io, spill_dir: []const u8) Response {
        return .{ .gpa = gpa, .io = io, .spill_dir = spill_dir };
    }

    pub fn deinit(r: *Response) void {
        r.closeSpill();
        if (r.spill_path) |p| {
            Io.Dir.cwd().deleteFile(r.io, p) catch {};
            r.gpa.free(p);
        }
        r.gpa.free(r.reason);
        r.gpa.free(r.url);
        r.gpa.free(r.raw_headers);
        r.headers.deinit(r.gpa);
        r.preview.deinit(r.gpa);
        r.gpa.free(r.error_text);
    }

    pub fn closeSpill(r: *Response) void {
        if (r.spill_file) |f| f.close(r.io);
        r.spill_file = null;
    }

    pub fn setError(r: *Response, text: []const u8) void {
        r.gpa.free(r.error_text);
        r.error_text = r.gpa.dupe(u8, text) catch &.{};
    }

    /// What the worker calls on a head: replaces anything from before.
    pub fn onHead(r: *Response, head: transport.Head) !void {
        r.status = head.status;
        r.redirects = head.redirects;
        r.gpa.free(r.reason);
        r.reason = &.{};
        r.reason = try r.gpa.dupe(u8, head.reason);
        r.gpa.free(r.url);
        r.url = &.{};
        r.url = try r.gpa.dupe(u8, head.url);
        r.gpa.free(r.raw_headers);
        r.raw_headers = &.{};
        r.raw_headers = try r.gpa.dupe(u8, head.raw_headers);
        r.headers.clearRetainingCapacity();
        var it = std.mem.splitSequence(u8, r.raw_headers, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try r.headers.append(r.gpa, .{
                .name = std.mem.trim(u8, line[0..colon], " \t"),
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
            });
        }
        r.content_type = r.header("content-type") orelse "";
    }

    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// What the worker calls with body bytes, in order.
    pub fn onData(r: *Response, bytes_in: []const u8) !void {
        var bytes = bytes_in;
        const so_far = r.total.load(.monotonic);
        var over = false;
        if (so_far + bytes.len > r.max_bytes) {
            bytes = bytes[0..@intCast(r.max_bytes - so_far)];
            over = true;
        }
        if (r.spill_file == null and r.spill_path == null and !r.spill_failed and r.preview.items.len + bytes.len > r.memory_limit) r.openSpill();
        if (r.spill_file) |f| {
            f.writeStreamingAll(r.io, bytes) catch {
                // A full disk stops the transfer rather than growing memory.
                r.spill_failed = true;
                return error.DiskFull;
            };
        }
        if (r.preview.items.len < r.memory_limit) {
            const room = r.memory_limit - r.preview.items.len;
            try r.preview.appendSlice(r.gpa, bytes[0..@min(room, bytes.len)]);
        }
        r.total.store(so_far + bytes.len, .monotonic);
        if (over) {
            r.stop = .too_large;
            return error.TooLarge;
        }
    }

    fn openSpill(r: *Response) void {
        var raw: [8]u8 = undefined;
        r.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        const path = std.fmt.allocPrint(r.gpa, "{s}{c}{s}.body", .{ r.spill_dir, std.fs.path.sep, &hex }) catch {
            r.spill_failed = true;
            return;
        };
        const f = Io.Dir.cwd().createFile(r.io, path, .{ .exclusive = true, .read = true }) catch {
            r.gpa.free(path);
            r.spill_failed = true;
            return;
        };
        f.writeStreamingAll(r.io, r.preview.items) catch {
            f.close(r.io);
            Io.Dir.cwd().deleteFile(r.io, path) catch {};
            r.gpa.free(path);
            r.spill_failed = true;
            return;
        };
        r.spill_file = f;
        r.spill_path = path;
    }

    /// Whether the preview is not the whole body.
    pub fn isPartial(r: *const Response) bool {
        return r.total.load(.monotonic) > r.preview.items.len;
    }

    /// Writes the whole body to `path`, from memory or the temporary file.
    pub fn saveTo(r: *const Response, path: []const u8) !void {
        const cwd = Io.Dir.cwd();
        if (r.spill_path) |from| {
            return cwd.copyFile(from, cwd, path, r.io, .{ .replace = true });
        }
        var af = try cwd.createFileAtomic(r.io, path, .{ .replace = true });
        defer af.deinit(r.io);
        try af.file.writeStreamingAll(r.io, r.preview.items);
        try af.replace(r.io);
    }

    pub fn class(r: *const Response) ContentClass {
        return classify(r.content_type, r.preview.items);
    }
};

/// By the Content-Type first; without a useful one, by the first bytes.
pub fn classify(content_type: []const u8, body: []const u8) ContentClass {
    const ct = std.mem.trim(u8, content_type, " ");
    const has = struct {
        fn f(s: []const u8, w: []const u8) bool {
            return std.ascii.findIgnoreCase(s, w) != null;
        }
    }.f;
    if (ct.len > 0) {
        if (has(ct, "json")) return .json;
        if (has(ct, "html")) return .html;
        if (has(ct, "svg") or has(ct, "image/")) return .image;
        if (has(ct, "xml")) return .xml;
        if (has(ct, "text/") or has(ct, "javascript") or has(ct, "x-www-form-urlencoded") or has(ct, "yaml") or has(ct, "csv")) return .text;
        if (!has(ct, "octet-stream")) return if (looksBinary(body)) .binary else .text;
    }
    const start = std.mem.trimStart(u8, body[0..@min(body.len, 256)], " \t\r\n");
    if (std.mem.startsWith(u8, body, "\x89PNG\r\n\x1a\n") or std.mem.startsWith(u8, body, "\xff\xd8\xff") or std.mem.startsWith(u8, body, "GIF8")) return .image;
    if (start.len > 0 and (start[0] == '{' or start[0] == '[')) return if (looksBinary(body)) .binary else .json;
    if (std.ascii.startsWithIgnoreCase(start, "<!doctype html") or std.ascii.startsWithIgnoreCase(start, "<html")) return .html;
    if (std.mem.startsWith(u8, start, "<?xml")) return .xml;
    return if (looksBinary(body)) .binary else .text;
}

/// NUL bytes, or lots of bytes that aren't text, in the first 8 KB.
pub fn looksBinary(body: []const u8) bool {
    const sample = body[0..@min(body.len, 8 * 1024)];
    var odd: usize = 0;
    var i: usize = 0;
    while (i < sample.len) {
        const c = sample[i];
        if (c == 0) return true;
        if (c < 0x09 or (c > 0x0d and c < 0x20) or c == 0x7f) {
            odd += 1;
            i += 1;
        } else if (c < 0x80) {
            i += 1;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(c) catch {
                odd += 1;
                i += 1;
                continue;
            };
            // A sequence the sample cut in half is not evidence.
            if (i + n > sample.len) break;
            if (std.unicode.utf8ValidateSlice(sample[i .. i + n])) i += n else {
                odd += 1;
                i += 1;
            }
        }
    }
    return odd * 10 > sample.len;
}

const t = std.testing;

test "classify" {
    try t.expectEqual(ContentClass.json, classify("application/json; charset=utf-8", "{}"));
    try t.expectEqual(ContentClass.json, classify("application/problem+json", ""));
    try t.expectEqual(ContentClass.html, classify("text/html", ""));
    try t.expectEqual(ContentClass.xml, classify("application/xml", ""));
    try t.expectEqual(ContentClass.image, classify("image/png", ""));
    try t.expectEqual(ContentClass.image, classify("image/svg+xml", ""));
    try t.expectEqual(ContentClass.text, classify("text/plain", "\x00"));
    try t.expectEqual(ContentClass.binary, classify("application/octet-stream", "\x00\x01"));
    try t.expectEqual(ContentClass.json, classify("", " {\"a\":1}"));
    try t.expectEqual(ContentClass.html, classify("", "<!DOCTYPE html><html>"));
    try t.expectEqual(ContentClass.image, classify("application/octet-stream", "\x89PNG\r\n\x1a\nxxxx"));
    try t.expectEqual(ContentClass.text, classify("", "héllo wörld"));
    try t.expectEqual(ContentClass.binary, classify("", "a\x00b"));
}

test "a body stays in memory until it outgrows it, then all of it is on disk" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const io = t.io;
    var dir_buf: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..n];
    var r = Response.init(t.allocator, io, dir);
    defer r.deinit();
    r.memory_limit = 10;
    try r.onData("12345");
    try t.expect(r.spill_path == null);
    try r.onData("67890");
    try t.expect(r.spill_path == null);
    try t.expect(!r.isPartial());
    try r.onData("abc");
    try t.expect(r.spill_path != null);
    try r.onData("def");
    try t.expectEqualStrings("1234567890", r.preview.items);
    try t.expect(r.isPartial());
    try t.expectEqual(@as(u64, 16), r.total.load(.monotonic));
    r.closeSpill();
    const out = try std.fmt.allocPrint(t.allocator, "{s}{c}saved.bin", .{ dir, std.fs.path.sep });
    defer t.allocator.free(out);
    try r.saveTo(out);
    const back = try Io.Dir.cwd().readFileAlloc(io, out, t.allocator, .limited(100));
    defer t.allocator.free(back);
    try t.expectEqualStrings("1234567890abcdef", back);
}

test "the size limit stops the transfer and keeps what came" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var r = Response.init(t.allocator, t.io, ".");
    defer r.deinit();
    r.max_bytes = 4;
    try t.expectError(error.TooLarge, r.onData("123456"));
    try t.expectEqual(Stop.too_large, r.stop);
    try t.expectEqualStrings("1234", r.preview.items);
    try t.expectEqual(@as(u64, 4), r.total.load(.monotonic));
}

test "headers are parsed from the head" {
    var r = Response.init(t.allocator, t.io, ".");
    defer r.deinit();
    try r.onHead(.{ .status = 201, .reason = "Created", .url = "http://x", .redirects = 1, .raw_headers = "Content-Type: a/b\r\nX-Two: 1\r\nX-Two: 2\r\n\r\n" });
    try t.expectEqual(@as(usize, 3), r.headers.items.len);
    try t.expectEqualStrings("a/b", r.content_type);
    try t.expectEqualStrings("2", r.headers.items[2].value);
    try t.expectEqualStrings("1", r.header("x-two").?);
}
