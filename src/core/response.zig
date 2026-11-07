//! A response as it arrives on a worker thread and as the viewer reads it.
//! Its body is bounded in memory: the first `memory_limit` bytes are kept for
//! display, and once a body outgrows them every byte goes to a temporary file
//! instead, from which Save copies it whole.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const transport = @import("../network/transport.zig");

pub const default_memory_limit = 8 * 1024 * 1024;

pub const Header = struct { name: []const u8, value: []const u8, raw_line: []const u8 = "" };

pub const content = @import("response_content.zig");
pub const ContentClass = content.Class;

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
    /// Prepared on the worker before publishing the immutable response.
    content_info: ?content.Info = null,
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
    timing_known: bool = false,
    /// Execution failure is separate from the valid HTTP status, if any.
    failure: transport.Failure = .none,
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
        // Prepare the whole owned head before replacing any slices. A failed
        // allocation must not leave header rows pointing into freed raw bytes.
        const reason = try r.gpa.dupe(u8, head.reason);
        errdefer r.gpa.free(reason);
        const url = try r.gpa.dupe(u8, head.url);
        errdefer r.gpa.free(url);
        const raw = try r.gpa.dupe(u8, head.raw_headers);
        errdefer r.gpa.free(raw);
        var headers: std.ArrayList(Header) = .empty;
        errdefer headers.deinit(r.gpa);
        var it = std.mem.splitSequence(u8, raw, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try headers.append(r.gpa, .{
                .name = std.mem.trim(u8, line[0..colon], " \t"),
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
                .raw_line = line,
            });
        }
        r.gpa.free(r.reason);
        r.gpa.free(r.url);
        r.gpa.free(r.raw_headers);
        r.headers.deinit(r.gpa);
        r.reason = reason;
        r.url = url;
        r.raw_headers = raw;
        r.headers = headers;
        r.content_info = null;
        r.status = head.status;
        r.redirects = head.redirects;
        r.content_type = r.header("content-type") orelse "";
    }

    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        for (r.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// What the worker calls with body bytes, in order.
    pub fn onData(r: *Response, bytes_in: []const u8) !void {
        r.content_info = null;
        var bytes = bytes_in;
        const so_far = r.total.load(.monotonic);
        var over = false;
        if (so_far + bytes.len > r.max_bytes) {
            bytes = bytes[0..@intCast(r.max_bytes - so_far)];
            over = true;
        }
        if (r.spill_file == null and r.spill_path == null and !r.spill_failed and r.preview.items.len + bytes.len > r.memory_limit) r.openSpill();
        if (r.spill_failed and r.spill_path == null) {
            r.stop = .failed;
            return error.DiskFull;
        }
        if (r.spill_file) |f| {
            f.writeStreamingAll(r.io, bytes) catch {
                // A full disk stops the transfer rather than growing memory.
                r.spill_failed = true;
                r.stop = .failed;
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

    /// Called after stop/total are final, on the request worker. Classification
    /// scans at most the bounded in-memory preview and never copies the body.
    pub fn inspectContent(r: *Response) void {
        r.content_info = content.inspect(r.content_type, r.preview.items, !r.isPartial() and r.stop == .complete);
    }

    pub fn info(r: *const Response) content.Info {
        if (r.content_info) |value| return value;
        // Small manually constructed responses (including diagnostics) remain
        // useful. Never start an unbounded validation from a UI lookup.
        if (r.preview.items.len <= 64 * 1024) return content.inspect(r.content_type, r.preview.items, !r.isPartial() and r.stop == .complete);
        return .{ .kind = .binary };
    }

    pub fn class(r: *const Response) ContentClass {
        return r.info().kind;
    }
};

/// Standalone engine helper; callers control the work budget.
pub fn classify(content_type: []const u8, body: []const u8) ContentClass {
    return content.inspect(content_type, body, true).kind;
}

pub fn looksBinary(body: []const u8) bool {
    return content.binary(body, false);
}

const t = std.testing;

test "classify" {
    try t.expectEqual(ContentClass.json, classify("application/json; charset=utf-8", "{}"));
    try t.expectEqual(ContentClass.json, classify("application/problem+json", "null"));
    try t.expectEqual(ContentClass.html, classify("text/html", ""));
    try t.expectEqual(ContentClass.xml, classify("application/xml", ""));
    try t.expectEqual(ContentClass.image, classify("image/png", ""));
    try t.expectEqual(ContentClass.xml, classify("image/svg+xml", ""));
    try t.expectEqual(ContentClass.binary, classify("text/plain", "\x00"));
    try t.expectEqual(ContentClass.binary, classify("application/octet-stream", "\x00\x01"));
    try t.expectEqual(ContentClass.json, classify("", " {\"a\":1}"));
    try t.expectEqual(ContentClass.html, classify("", "<!DOCTYPE html><html>"));
    try t.expectEqual(ContentClass.image, classify("application/octet-stream", "\x89PNG\r\n\x1a\nxxxx"));
    try t.expectEqual(ContentClass.text, classify("", "héllo wörld"));
    try t.expectEqual(ContentClass.binary, classify("", "a\x00b"));
}

test "content analysis is invalidated by new bytes or headers" {
    var r = Response.init(t.allocator, t.io, ".");
    defer r.deinit();
    try r.onData("{}");
    r.inspectContent();
    try t.expectEqual(ContentClass.json, r.content_info.?.kind);
    try r.onData(" trailing");
    try t.expect(r.content_info == null);
    r.inspectContent();
    try t.expectEqual(ContentClass.text, r.content_info.?.kind);
    try r.onHead(.{ .status = 200, .reason = "OK", .raw_headers = "Content-Type: application/json\r\n", .url = "https://response.invalid/", .redirects = 0 });
    try t.expect(r.content_info == null);
    r.inspectContent();
    try t.expect(r.info().json_problem != null);
    try t.expectEqualStrings("{} trailing", r.preview.items);
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

test "failed spill allocation stops instead of silently discarding received data" {
    var fault = t.FailingAllocator.init(t.allocator, .{});
    var r = Response.init(fault.allocator(), t.io, ".");
    defer r.deinit();
    r.memory_limit = 4;
    try r.onData("1234");
    fault.fail_index = fault.alloc_index;
    fault.resize_fail_index = fault.resize_index;
    try t.expectError(error.DiskFull, r.onData("discarded before fix"));
    try t.expect(r.spill_failed and r.stop == .failed and r.spill_path == null);
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

test "head replacement is atomic on every allocation failure" {
    var succeeded = false;
    for (0..12) |offset| {
        var fault = t.FailingAllocator.init(t.allocator, .{});
        {
            var r = Response.init(fault.allocator(), t.io, ".");
            defer r.deinit();
            const old = "Content-Type: application/json\r\nX-Old:\t preserved  \t\r\n";
            try r.onHead(.{ .status = 201, .reason = "Old", .url = "https://old.invalid/", .raw_headers = old, .redirects = 1 });
            try r.onData("{}");
            r.inspectContent();
            const old_pointer = r.raw_headers.ptr;
            fault.fail_index = fault.alloc_index + offset;
            fault.resize_fail_index = fault.resize_index;
            const next = "Set-Cookie: a=1\r\nset-cookie: b=2\r\nX-New:\t new  \t\r\n";
            if (r.onHead(.{ .status = 202, .reason = "New", .url = "https://new.invalid/", .raw_headers = next, .redirects = 2 })) |_| {
                try t.expectEqual(@as(u16, 202), r.status);
                try t.expectEqualStrings(next, r.raw_headers);
                try t.expectEqualStrings("X-New:\t new  \t", r.headers.items[2].raw_line);
                try t.expectEqualStrings("new", r.headers.items[2].value);
                try t.expect(r.content_info == null);
                succeeded = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try t.expectEqual(@as(u16, 201), r.status);
                try t.expectEqualStrings("Old", r.reason);
                try t.expectEqualStrings("https://old.invalid/", r.url);
                try t.expect(r.raw_headers.ptr == old_pointer and r.content_info.?.kind == .json);
                try t.expectEqualStrings(old, r.raw_headers);
                try t.expectEqualStrings("preserved", r.headers.items[1].value);
                try t.expectEqualStrings("X-Old:\t preserved  \t", r.headers.items[1].raw_line);
            }
        }
        try t.expectEqual(fault.allocated_bytes, fault.freed_bytes);
        if (succeeded) break;
    }
    try t.expect(succeeded);
}
