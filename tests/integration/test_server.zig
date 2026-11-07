//! A small deterministic HTTP server for the tests, on a loopback port:
//! no external services, no surprises.
//!
//!   /echo            method, target, headers and body, as text
//!   /json            a small JSON document
//!   /status/N        status N, a short body
//!   /redirect/N      302 to /redirect/N-1, finally /echo
//!   /to?u=URL        302 to URL
//!   /307, /303       those redirects to /echo
//!   /bytes/N         N bytes of a known pattern (Content-Length)
//!   /chunked         three chunks
//!   /gzip            a gzip-encoded body
//!   /close           no framing: the body ends when the connection closes
//!   /conn            which accepted connection answered (for reuse tests)
//!   /hang            never answers
//!   /stall           sends half a body, then never finishes
//!   /huge            an endless stream of bytes
const std = @import("std");
const Io = std.Io;
const net = Io.net;

pub const Server = struct {
    io: Io,
    server: net.Server,
    port: u16,
    accept_task: Io.Future(void) = undefined,
    conn_counter: std.atomic.Value(u32) = .init(0),
    group: Io.Group = .init,

    pub fn start(s: *Server, io: Io) !void {
        var addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        s.io = io;
        s.server = try addr.listen(io, .{ .reuse_address = true });
        s.port = s.server.socket.address.getPort();
        s.conn_counter = .init(0);
        s.group = .init;
        s.accept_task = try io.concurrent(acceptLoop, .{s});
    }

    pub fn stop(s: *Server) void {
        s.accept_task.cancel(s.io);
        s.group.cancel(s.io);
        s.server.deinit(s.io);
    }

    pub fn url(s: *Server, a: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ s.port, path });
    }

    fn acceptLoop(s: *Server) void {
        while (true) {
            const stream = s.server.accept(s.io) catch return;
            const n = s.conn_counter.fetchAdd(1, .monotonic) + 1;
            s.group.concurrent(s.io, handle, .{ s, stream, n }) catch {
                stream.close(s.io);
                return;
            };
        }
    }

    fn handle(s: *Server, stream: net.Stream, conn: u32) Io.Cancelable!void {
        defer stream.close(s.io);
        var rbuf: [64 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var r = stream.reader(s.io, &rbuf);
        var w = stream.writer(s.io, &wbuf);
        while (true) {
            const keep = serveOne(s, &r.interface, &w.interface, conn) catch return;
            w.interface.flush() catch return;
            if (!keep) return;
        }
    }

    fn serveOne(s: *Server, r: *Io.Reader, w: *Io.Writer, conn: u32) !bool {
        var hp: std.http.HeadParser = .{};
        var head_len: usize = 0;
        while (hp.state != .finished) {
            const avail = r.buffered()[head_len..];
            if (avail.len == 0) {
                try r.fillMore();
                continue;
            }
            head_len += hp.feed(avail);
        }
        var head_copy: [32 * 1024]u8 = undefined;
        const head = head_copy[0..head_len];
        @memcpy(head, r.buffered()[0..head_len]);
        r.toss(head_len);

        const line_end = std.mem.indexOf(u8, head, "\r\n").?;
        var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
        const method = parts.next().?;
        const target = parts.next().?;
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, head[line_end + 2 ..], "\r\n");
        while (lines.next()) |l| {
            if (std.ascii.startsWithIgnoreCase(l, "content-length:")) content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, l["content-length:".len..], " "), 10);
        }
        var body_buf: [256 * 1024]u8 = undefined;
        const take = @min(content_length, body_buf.len);
        const body = body_buf[0..take];
        try r.readSliceAll(body);
        if (content_length > take) try r.discardAll(content_length - take);

        const is_head = std.mem.eql(u8, method, "HEAD");
        if (std.mem.eql(u8, target, "/markdown")) {
            try respond(w, 200, "OK", "text/markdown; charset=utf-8", is_head, "# Loopback Markdown\n\n**Formatted response** with a [link](https://example.test).\n\n- [ ] Read-only task\n\n```json\n{\"answer\":42}\n```\n", null);
            return true;
        }
        if (std.mem.eql(u8, target, "/html")) {
            try respond(w, 200, "OK", "text/html", is_head, "<html><body><h1>Loopback preview</h1><p>Actual response</p></body></html>", null);
            return true;
        }
        if (std.mem.eql(u8, target, "/png")) {
            const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==";
            var png: [128]u8 = undefined;
            const length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
            try std.base64.standard.Decoder.decode(png[0..length], encoded);
            try respond(w, 200, "OK", "image/png", is_head, png[0..length], null);
            return true;
        }
        if (std.mem.eql(u8, target, "/json")) {
            const json = "{\"find\":\"needle\",\"n\":[1,2,{\"deep\":true}]}";
            try w.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.len, json });
            return true;
        }
        if (std.mem.eql(u8, target, "/hang")) {
            try w.flush();
            try s.io.sleep(.fromSeconds(120), .awake);
            return false;
        }
        if (std.mem.eql(u8, target, "/stall")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nhalf");
            try w.flush();
            try s.io.sleep(.fromSeconds(120), .awake);
            return false;
        }
        if (std.mem.eql(u8, target, "/huge")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n");
            var block: [16 * 1024]u8 = undefined;
            @memset(&block, 'h');
            while (true) try w.writeAll(&block);
        }
        if (std.mem.eql(u8, target, "/close")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nread until closed");
            return false;
        }
        if (std.mem.eql(u8, target, "/chunked")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n");
            return true;
        }
        if (std.mem.eql(u8, target, "/gzip")) {
            // "hello gzip" compressed, stored by hand so tests need no encoder.
            const gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x57\x48\xaf\xca\x2c\x00\x00\x65\x7d\xe0\xbc\x0a\x00\x00\x00";
            try w.print("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n", .{gz.len});
            try w.writeAll(gz);
            return true;
        }
        if (std.mem.eql(u8, target, "/conn")) {
            try respond(w, 200, "OK", "text/plain", is_head, "", conn);
            return true;
        }
        if (std.mem.startsWith(u8, target, "/status/")) {
            const code = try std.fmt.parseInt(u16, target["/status/".len..], 10);
            if (code == 204 or code == 304) {
                try w.print("HTTP/1.1 {d} X\r\n\r\n", .{code});
                return true;
            }
            try respond(w, code, "Status", "text/plain", is_head, "status body", null);
            return true;
        }
        if (std.mem.startsWith(u8, target, "/redirect/")) {
            const n = try std.fmt.parseInt(u32, target["/redirect/".len..], 10);
            if (n == 0) {
                try w.writeAll("HTTP/1.1 302 Found\r\nLocation: /echo\r\nContent-Length: 0\r\n\r\n");
            } else {
                try w.print("HTTP/1.1 302 Found\r\nLocation: /redirect/{d}\r\nContent-Length: 0\r\n\r\n", .{n - 1});
            }
            return true;
        }
        if (std.mem.startsWith(u8, target, "/to?u=")) {
            try w.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n\r\n", .{target["/to?u=".len..]});
            return true;
        }
        if (std.mem.eql(u8, target, "/307") or std.mem.eql(u8, target, "/303")) {
            try w.print("HTTP/1.1 {s} X\r\nLocation: /echo\r\nContent-Length: 0\r\n\r\n", .{target[1..]});
            return true;
        }
        if (std.mem.startsWith(u8, target, "/bytes/")) {
            const n = try std.fmt.parseInt(u64, target["/bytes/".len..], 10);
            try w.print("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n", .{n});
            if (is_head) return true;
            var block: [4096]u8 = undefined;
            var sent: u64 = 0;
            while (sent < n) {
                const len: usize = @intCast(@min(block.len, n - sent));
                for (block[0..len], 0..) |*b, i| b.* = @truncate((sent + i) % 251);
                try w.writeAll(block[0..len]);
                sent += len;
            }
            return true;
        }
        // /echo and anything else.
        var echo: std.ArrayList(u8) = .empty;
        defer echo.deinit(std.heap.smp_allocator);
        const a = std.heap.smp_allocator;
        try echo.print(a, "{s} {s}\n", .{ method, target });
        var hl = std.mem.splitSequence(u8, head[line_end + 2 ..], "\r\n");
        while (hl.next()) |l| if (l.len > 0) try echo.print(a, "{s}\n", .{l});
        try echo.print(a, "\n{s}", .{body});
        try respond(w, 200, "OK", "text/plain", is_head, echo.items, null);
        return true;
    }

    fn respond(w: *Io.Writer, code: u16, reason: []const u8, ctype: []const u8, is_head: bool, body: []const u8, conn: ?u32) !void {
        var tmp: [32]u8 = undefined;
        const text = if (conn) |c| try std.fmt.bufPrint(&tmp, "conn {d}", .{c}) else body;
        try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nX-Multi: one\r\nX-Multi: two\r\nContent-Length: {d}\r\n\r\n", .{ code, reason, ctype, text.len });
        if (!is_head) try w.writeAll(text);
    }
};
