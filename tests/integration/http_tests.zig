//! The real transport against a real socket on loopback.
const std = @import("std");
const lib = @import("retort");
const Server = @import("test_server.zig").Server;
const http_client = lib.http_client;
const req = lib.request;
const t = std.testing;
const Io = std.Io;
const Job = http_client.Job;

const Env = struct {
    server: Server = undefined,
    client: lib.transport.Client = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    tmp: std.testing.TmpDir = undefined,
    spill: []u8 = &.{},

    fn init(e: *Env) !void {
        e.arena = .init(t.allocator);
        try e.server.start(t.io);
        e.client = .init(t.allocator, t.io);
        e.tmp = t.tmpDir(.{});
        var buf: [1024]u8 = undefined;
        const n = try e.tmp.dir.realPath(t.io, &buf);
        e.spill = try e.arena.allocator().dupe(u8, buf[0..n]);
    }

    fn deinit(e: *Env) void {
        e.client.deinit();
        e.server.stop();
        e.tmp.cleanup();
        e.arena.deinit();
    }

    fn url(e: *Env, path: []const u8) []const u8 {
        return e.server.url(e.arena.allocator(), path) catch unreachable;
    }

    /// Sends `r` and waits until it's done.
    fn send(e: *Env, r: req.Request) !*Job {
        return e.sendOpts(r, .{ .spill_dir = e.spill });
    }

    fn sendOpts(e: *Env, r: req.Request, opts: http_client.Options) !*Job {
        var done: Done = .{};
        var problem: lib.prepare.Problem = .{};
        const j = try http_client.start(t.allocator, t.io, &e.client, r, &.{}, .{ .ctx = &done, .on_done = Done.onDone }, opts, e.arena.allocator(), &problem);
        try done.ev.wait(t.io);
        return j;
    }
};

const Done = struct {
    ev: Io.Event = .unset,
    fn onDone(ctx: ?*anyopaque, _: *Job) void {
        const d: *Done = @ptrCast(@alignCast(ctx.?));
        d.ev.set(t.io);
    }
};

fn body(j: *Job) []const u8 {
    return j.resp.preview.items;
}

fn has(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
}

test "the standard methods and a custom one reach the server" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    for ([_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "PURGE" }) |m| {
        const j = try e.send(.{ .method = m, .url = e.url("/echo?a=1&b=2") });
        defer j.destroy();
        try t.expectEqual(@as(u16, 200), j.resp.status);
        try t.expectEqual(lib.response.Stop.complete, j.resp.stop);
        var line: [64]u8 = undefined;
        try t.expect(std.mem.startsWith(u8, body(j), try std.fmt.bufPrint(&line, "{s} /echo?a=1&b=2\n", .{m})));
    }
}

test "HEAD has headers and no body" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{ .method = "HEAD", .url = e.url("/echo") });
    defer j.destroy();
    try t.expectEqual(@as(u16, 200), j.resp.status);
    try t.expectEqual(@as(usize, 0), body(j).len);
    try t.expectEqualStrings("text/plain", j.resp.content_type);
}

test "headers and a JSON body arrive; repeated response headers are kept" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{
        .method = "POST",
        .url = e.url("/echo"),
        .headers = &.{ .{ .key = "X-Custom", .value = "abc" }, .{ .key = "X-Off", .value = "no", .enabled = false } },
        .body_kind = .json,
        .body_text = "{\"a\":1}",
    });
    defer j.destroy();
    const b = body(j);
    try t.expect(has(b, "X-Custom: abc\n"));
    try t.expect(!has(b, "X-Off"));
    try t.expect(has(b, "Content-Type: application/json\n"));
    try t.expect(has(b, "Content-Length: 7\n"));
    try t.expect(has(b, "User-Agent: retort/"));
    try t.expect(std.mem.endsWith(u8, b, "\n\n{\"a\":1}"));
    var n: usize = 0;
    for (j.resp.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-multi")) n += 1;
    }
    try t.expectEqual(@as(usize, 2), n);
}

test "the user's headers replace the defaults" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{ .url = e.url("/echo"), .headers = &.{ .{ .key = "user-agent", .value = "me" }, .{ .key = "Accept", .value = "a/b" } } });
    defer j.destroy();
    const b = body(j);
    try t.expect(has(b, "user-agent: me\n"));
    try t.expect(!has(b, "User-Agent: retort"));
    try t.expect(has(b, "Accept: a/b\n"));
}

test "forms and multipart with a file upload" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const form = try e.send(.{ .method = "POST", .url = e.url("/echo"), .body_kind = .form_urlencoded, .form = &.{.{ .key = "a b", .value = "c&d" }} });
    defer form.destroy();
    try t.expect(has(body(form), "application/x-www-form-urlencoded"));
    try t.expect(std.mem.endsWith(u8, body(form), "a+b=c%26d"));

    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "up.txt", .data = "file contents here" });
    const path = try std.fmt.allocPrint(a, "{s}{c}up.txt", .{ e.spill, std.fs.path.sep });
    const mp = try e.send(.{
        .method = "POST",
        .url = e.url("/echo"),
        .body_kind = .multipart,
        .form = &.{ .{ .key = "title", .value = "x" }, .{ .key = "up", .value = path, .is_file = true } },
    });
    defer mp.destroy();
    const b = body(mp);
    try t.expect(has(b, "multipart/form-data; boundary=----retort"));
    try t.expect(has(b, "name=\"title\"\r\n\r\nx\r\n"));
    try t.expect(has(b, "filename=\"up.txt\"\r\nContent-Type: text/plain\r\n\r\nfile contents here\r\n"));

    const whole = try e.send(.{ .method = "PUT", .url = e.url("/echo"), .body_kind = .file, .file_path = path });
    defer whole.destroy();
    try t.expect(std.mem.endsWith(u8, body(whole), "\n\nfile contents here"));

    const missing = try e.send(.{ .method = "PUT", .url = e.url("/echo"), .body_kind = .file, .file_path = "no-such-file-anywhere" });
    defer missing.destroy();
    try t.expectEqual(lib.response.Stop.failed, missing.resp.stop);
    try t.expect(has(missing.resp.error_text, "file"));
}

test "statuses are reported, whatever they are" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    for ([_]u16{ 201, 204, 304, 404, 500 }) |code| {
        var buf: [32]u8 = undefined;
        const j = try e.send(.{ .url = e.url(try std.fmt.bufPrint(&buf, "/status/{d}", .{code})) });
        defer j.destroy();
        try t.expectEqual(code, j.resp.status);
        try t.expectEqual(lib.response.Stop.complete, j.resp.stop);
    }
}

test "redirects: followed, limited, or left alone" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{ .url = e.url("/redirect/2") });
    defer j.destroy();
    try t.expectEqual(@as(u16, 200), j.resp.status);
    try t.expectEqual(@as(u8, 3), j.resp.redirects);
    try t.expect(std.mem.endsWith(u8, j.resp.url, "/echo"));

    const off = try e.send(.{ .url = e.url("/redirect/1"), .settings = .{ .follow_redirects = false } });
    defer off.destroy();
    try t.expectEqual(@as(u16, 302), off.resp.status);
    try t.expectEqualStrings("/redirect/0", off.resp.header("location").?);

    const many = try e.send(.{ .url = e.url("/redirect/9"), .settings = .{ .max_redirects = 2 } });
    defer many.destroy();
    try t.expectEqual(lib.response.Stop.failed, many.resp.stop);
    try t.expect(has(many.resp.error_text, "Too many redirects"));
}

test "redirects: which keep the method and body" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const r307 = try e.send(.{ .method = "POST", .url = e.url("/307"), .body_kind = .text, .body_text = "kept" });
    defer r307.destroy();
    try t.expect(std.mem.startsWith(u8, body(r307), "POST /echo"));
    try t.expect(std.mem.endsWith(u8, body(r307), "kept"));
    const r303 = try e.send(.{ .method = "POST", .url = e.url("/303"), .body_kind = .text, .body_text = "gone" });
    defer r303.destroy();
    try t.expect(std.mem.startsWith(u8, body(r303), "GET /echo"));
    try t.expect(!has(body(r303), "gone"));
}

test "credentials don't follow a redirect to another origin" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    var other: Server = undefined;
    try other.start(t.io);
    defer other.stop();
    const a = e.arena.allocator();
    const target = try other.url(a, "/echo");
    const from = try std.fmt.allocPrint(a, "/to?u={s}", .{target});
    const j = try e.send(.{ .url = e.url(from), .headers = &.{ .{ .key = "Authorization", .value = "secret" }, .{ .key = "Cookie", .value = "c=1" }, .{ .key = "X-Safe", .value = "ok" } } });
    defer j.destroy();
    try t.expectEqual(@as(u16, 200), j.resp.status);
    try t.expect(!has(body(j), "secret"));
    try t.expect(!has(body(j), "c=1"));
    try t.expect(has(body(j), "X-Safe: ok"));
    // On the same origin they do.
    const same = try e.send(.{ .url = e.url("/redirect/0"), .headers = &.{.{ .key = "Authorization", .value = "secret" }} });
    defer same.destroy();
    try t.expect(has(body(same), "secret"));
}

test "chunked, gzip and close-framed bodies" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const c = try e.send(.{ .url = e.url("/chunked") });
    defer c.destroy();
    try t.expectEqualStrings("hello world", body(c));
    const g = try e.send(.{ .url = e.url("/gzip") });
    defer g.destroy();
    try t.expectEqualStrings("hello gzip", body(g));
    const cl = try e.send(.{ .url = e.url("/close") });
    defer cl.destroy();
    try t.expectEqualStrings("read until closed", body(cl));
    try t.expectEqual(lib.response.Stop.complete, cl.resp.stop);
}

test "connections are reused" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const a = try e.send(.{ .url = e.url("/conn") });
    defer a.destroy();
    try t.expect(!a.resp.reused_connection);
    try t.expectEqual(@as(usize, 1), e.client.idleCount());
    const b = try e.send(.{ .url = e.url("/conn") });
    defer b.destroy();
    try t.expect(b.resp.reused_connection);
    try t.expectEqualStrings(body(a), body(b));
    // A stale socket is retried on a new one, unnoticed. Close-framed: not kept.
    const c = try e.send(.{ .url = e.url("/close") });
    defer c.destroy();
    try t.expectEqual(lib.response.Stop.complete, c.resp.stop);
}

test "a timeout stops a server that never answers" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{ .url = e.url("/hang"), .settings = .{ .timeout_ms = 150 } });
    defer j.destroy();
    try t.expectEqual(lib.response.Stop.timed_out, j.resp.stop);
    try t.expectEqual(@as(u16, 0), j.resp.status);
    try t.expect(j.resp.time_ms >= 140 and j.resp.time_ms < 3000);
}

test "a timeout stops a stalled body and keeps what came" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.send(.{ .url = e.url("/stall"), .settings = .{ .timeout_ms = 200 } });
    defer j.destroy();
    try t.expectEqual(lib.response.Stop.timed_out, j.resp.stop);
    try t.expectEqual(@as(u16, 200), j.resp.status);
    try t.expectEqualStrings("half", body(j));
}

test "cancel stops a request promptly" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    var done: Done = .{};
    var problem: lib.prepare.Problem = .{};
    const j = try http_client.start(t.allocator, t.io, &e.client, .{ .url = e.url("/hang"), .settings = .{ .timeout_ms = 0 } }, &.{}, .{ .ctx = &done, .on_done = Done.onDone }, .{ .spill_dir = e.spill }, e.arena.allocator(), &problem);
    defer j.destroy();
    try t.io.sleep(.fromMilliseconds(50), .awake);
    try t.expect(!done.ev.isSet());
    j.cancel();
    try done.ev.wait(t.io);
    try t.expectEqual(lib.response.Stop.canceled, j.resp.stop);
    try t.expect(j.resp.time_ms < 3000);
}

test "an endless download stops at the size limit, in bounded memory" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const j = try e.sendOpts(.{ .url = e.url("/huge"), .settings = .{ .max_response_bytes = 5 * 1024 * 1024 } }, .{ .spill_dir = e.spill, .memory_limit = 64 * 1024 });
    defer j.destroy();
    try t.expectEqual(lib.response.Stop.too_large, j.resp.stop);
    try t.expectEqual(@as(u64, 5 * 1024 * 1024), j.resp.total.load(.monotonic));
    // Only the preview is in memory; the rest is on disk.
    try t.expectEqual(@as(usize, 64 * 1024), j.resp.preview.items.len);
    try t.expect(j.resp.spill_path != null);
    const st = try Io.Dir.cwd().statFile(t.io, j.resp.spill_path.?, .{});
    try t.expectEqual(@as(u64, 5 * 1024 * 1024), st.size);
}

test "a large download is byte for byte right, in memory and saved" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    const n: usize = 3 * 1024 * 1024 + 17;
    const j = try e.sendOpts(.{ .url = e.url("/bytes/3145745") }, .{ .spill_dir = e.spill, .memory_limit = 1024 * 1024 });
    defer j.destroy();
    try t.expectEqual(@as(u64, n), j.resp.total.load(.monotonic));
    try t.expect(j.resp.isPartial());
    const a = e.arena.allocator();
    const out = try std.fmt.allocPrint(a, "{s}{c}download.bin", .{ e.spill, std.fs.path.sep });
    try j.resp.saveTo(out);
    const back = try Io.Dir.cwd().readFileAlloc(t.io, out, t.allocator, .limited(n + 1));
    defer t.allocator.free(back);
    try t.expectEqual(n, back.len);
    for (back, 0..) |b, i| {
        if (b != @as(u8, @truncate(i % 251))) return error.ByteWrong;
    }
    // Freeing the response removes its temporary file.
    const spill = try a.dupe(u8, j.resp.spill_path.?);
    j.resp.deinit();
    j.resp = lib.response.Response.init(t.allocator, t.io, e.spill);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, spill, .{}));
}

test "invalid URLs and network errors are explained" {
    var e: Env = .{};
    try e.init();
    defer e.deinit();
    var problem: lib.prepare.Problem = .{};
    var done: Done = .{};
    try t.expectError(error.InvalidUrl, http_client.start(t.allocator, t.io, &e.client, .{ .url = "not a url" }, &.{}, .{ .ctx = &done, .on_done = Done.onDone }, .{ .spill_dir = e.spill }, e.arena.allocator(), &problem));
    try t.expectEqualStrings("The URL needs http:// or https://", problem.message);
    // A port nothing listens on: the server's own, once it's closed.
    var gone: Server = undefined;
    try gone.start(t.io);
    const closed = try gone.url(e.arena.allocator(), "/");
    gone.stop();
    const j = try e.send(.{ .url = closed });
    defer j.destroy();
    try t.expectEqual(lib.response.Stop.failed, j.resp.stop);
    try t.expectEqual(@as(u16, 0), j.resp.status);
    try t.expect(has(j.resp.error_text, "refused") or has(j.resp.error_text, "reached"));
    // A host that can't resolve (the .invalid TLD is reserved for this).
    const dns = try e.send(.{ .url = "http://no-such-host.invalid/", .settings = .{ .timeout_ms = 10_000 } });
    defer dns.destroy();
    try t.expectEqual(lib.response.Stop.failed, dns.resp.stop);
}
