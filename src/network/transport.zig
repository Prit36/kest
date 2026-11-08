//! HTTP/1.1 over std's sockets and TLS. `std.http.Client` can't send custom
//! methods or turn certificate checks off, so requests are written here; its
//! head and body readers (chunked, gzip) are reused. Bodies stream to a sink:
//! nothing here holds a response in memory. Every blocking call is a
//! cancelation point of `std.Io`, which is how timeouts and Cancel work.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;
const tls = std.crypto.tls;
const url_util = @import("../utils/url.zig");
const check = @import("header_check.zig");
const Allocator = std.mem.Allocator;
const Parsed = std.http.Client.Response.Head;

pub const Header = check.Header;

pub const BodyPart = union(enum) {
    bytes: []const u8,
    /// A path: its contents are streamed as this part.
    file: []const u8,
};

pub const Outgoing = struct {
    method: []const u8,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const BodyPart = &.{},
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    verify_tls: bool = true,
};

pub const Head = struct {
    status: u16,
    reason: []const u8,
    /// Everything after the status line, as received.
    raw_headers: []const u8,
    /// The URL that answered, after redirects.
    url: []const u8,
    redirects: u8,
};

pub const Sink = struct {
    ctx: *anyopaque,
    /// May be called more than once: only the final response has `final`.
    on_head: *const fn (ctx: *anyopaque, head: Head) anyerror!void,
    on_data: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

/// Failures the UI can explain. Anything else keeps its error name.
pub const Failure = enum {
    none,
    canceled,
    invalid_url,
    invalid_header,
    dns,
    refused,
    unreachable_host,
    tls_handshake,
    tls_certificate,
    too_many_redirects,
    protocol,
    connection_lost,
    file,
    stopped_by_sink,
    other,
};

pub const Result = struct {
    failure: Failure = .none,
    /// The underlying error's name, for the details.
    detail: []const u8 = "",
    reused_connection: bool = false,
};

pub const validHeader = check.validHeader;
pub const user_agent = "kest/0.0.2";
pub const default_headers = [_]Header{
    .{ .name = "User-Agent", .value = user_agent },
    .{ .name = "Accept", .value = "*/*" },
    .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
};
const max_head = 256 * 1024;
const socket_buffer = 64 * 1024;
const max_idle_connections = 4;
const idle_lifetime_ms = 60_000;

/// One socket and everything reading and writing it. The buffers are inline:
/// a connection is one allocation of about 150 KB, for as long as it lives.
const Conn = struct {
    stream: net.Stream,
    socket_reader: net.Stream.Reader,
    socket_writer: net.Stream.Writer,
    secure: bool,
    verify: bool,
    port: u16,
    host_len: u8,
    idle_since_ms: i64 = 0,
    tls_client: ?tls.Client = null,
    host_buf: [255]u8 = undefined,
    socket_read: [socket_buffer]u8 = undefined,
    // TLS writes whole records into the socket writer's buffer.
    socket_write: [tls.Client.min_buffer_len]u8 = undefined,
    tls_read: [tls.Client.min_buffer_len + 8 * 1024]u8 = undefined,
    tls_write: [8 * 1024]u8 = undefined,

    fn host(c: *const Conn) []const u8 {
        return c.host_buf[0..c.host_len];
    }

    fn writer(c: *Conn) *Io.Writer {
        return if (c.tls_client) |*t| &t.writer else &c.socket_writer.interface;
    }

    fn reader(c: *Conn) *Io.Reader {
        return if (c.tls_client) |*t| &t.reader else &c.socket_reader.interface;
    }

    fn flush(c: *Conn) !void {
        if (c.tls_client) |*t| try t.writer.flush();
        try c.socket_writer.interface.flush();
    }
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    idle: std.ArrayList(*Conn) = .empty,
    bundle_lock: Io.RwLock = .init,
    bundle: std.crypto.Certificate.Bundle = .empty,
    bundle_loaded: bool = false,
    /// Every running job (`http_client`).
    jobs: Io.Group = .init,

    pub fn init(gpa: Allocator, io: Io) Client {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(c: *Client) void {
        c.jobs.cancel(c.io);
        for (c.idle.items) |conn| destroyConn(c, conn);
        c.idle.deinit(c.gpa);
        c.bundle.deinit(c.gpa);
    }

    /// How many sockets are kept open for reuse.
    pub fn idleCount(c: *Client) usize {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.idle.items.len;
    }

    fn take(c: *Client, host: []const u8, port: u16, secure: bool, verify: bool) ?*Conn {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        const now = nowMs(c.io);
        var i: usize = c.idle.items.len;
        while (i > 0) {
            i -= 1;
            const conn = c.idle.items[i];
            if (now - conn.idle_since_ms > idle_lifetime_ms) {
                _ = c.idle.orderedRemove(i);
                destroyConn(c, conn);
                continue;
            }
            if (conn.port == port and conn.secure == secure and conn.verify == verify and std.ascii.eqlIgnoreCase(conn.host(), host)) {
                _ = c.idle.orderedRemove(i);
                return conn;
            }
        }
        return null;
    }

    fn give(c: *Client, conn: *Conn) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        conn.idle_since_ms = nowMs(c.io);
        if (c.idle.items.len >= max_idle_connections) destroyConn(c, c.idle.orderedRemove(0));
        c.idle.append(c.gpa, conn) catch destroyConn(c, conn);
    }

    fn loadBundle(c: *Client) !void {
        {
            try c.bundle_lock.lockShared(c.io);
            defer c.bundle_lock.unlockShared(c.io);
            if (c.bundle_loaded) return;
        }
        var fresh: std.crypto.Certificate.Bundle = .empty;
        errdefer fresh.deinit(c.gpa);
        try fresh.rescan(c.gpa, c.io, Io.Clock.real.now(c.io));
        try c.bundle_lock.lock(c.io);
        defer c.bundle_lock.unlock(c.io);
        std.mem.swap(std.crypto.Certificate.Bundle, &c.bundle, &fresh);
        fresh.deinit(c.gpa);
        c.bundle_loaded = true;
    }

    fn connect(c: *Client, host: []const u8, port: u16, secure: bool, verify: bool, result: *Result) !*Conn {
        if (host.len > 255) {
            result.failure = .invalid_url;
            return error.Failed;
        }
        const stream = openSocket(c.io, host, port) catch |e| {
            const any: anyerror = e;
            result.failure = switch (any) {
                error.Canceled => .canceled,
                error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned, error.HostLacksNetworkAddresses, error.InvalidHostName, error.NameTooLong, error.ResolvConfParseFailed => .dns,
                error.ConnectionRefused => .refused,
                error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown, error.Timeout => .unreachable_host,
                else => .other,
            };
            result.detail = @errorName(e);
            return error.Failed;
        };
        errdefer stream.close(c.io);
        const conn = try c.gpa.create(Conn);
        errdefer c.gpa.destroy(conn);
        conn.stream = stream;
        conn.secure = secure;
        conn.verify = verify;
        conn.port = port;
        conn.host_len = @intCast(host.len);
        @memcpy(conn.host_buf[0..host.len], host);
        conn.tls_client = null;
        conn.idle_since_ms = 0;
        conn.socket_reader = stream.reader(c.io, &conn.socket_read);
        conn.socket_writer = stream.writer(c.io, &conn.socket_write);
        if (secure) {
            if (verify) c.loadBundle() catch |e| {
                result.failure = if (e == error.Canceled) .canceled else .tls_certificate;
                result.detail = @errorName(e);
                return error.Failed;
            };
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            c.io.random(&entropy);
            conn.tls_client = tls.Client.init(&conn.socket_reader.interface, &conn.socket_writer.interface, .{
                .host = if (verify) .{ .explicit = conn.host() } else .no_verification,
                .ca = if (verify) .{ .bundle = .{ .gpa = c.gpa, .io = c.io, .lock = &c.bundle_lock, .bundle = &c.bundle } } else .no_verification,
                .read_buffer = &conn.tls_read,
                .write_buffer = &conn.tls_write,
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(c.io),
                // Content-Length catches truncation, as in std's own client.
                .allow_truncation_attacks = true,
            }) catch |e| {
                const inner: anyerror = switch (e) {
                    error.ReadFailed => conn.socket_reader.err orelse e,
                    error.WriteFailed => conn.socket_writer.err orelse e,
                    else => e,
                };
                result.failure = if (inner == error.Canceled) .canceled else if (isCertificateError(inner)) .tls_certificate else .tls_handshake;
                result.detail = @errorName(inner);
                return error.Failed;
            };
        }
        return conn;
    }

    /// Sends `out`, following redirects if asked, streaming the final body
    /// to `sink`. `a` is for this call's temporary memory: an arena.
    pub fn perform(c: *Client, a: Allocator, out: Outgoing, sink: Sink) Result {
        var result: Result = .{};
        c.performInner(a, out, sink, &result) catch |e| {
            if (result.failure == .none) {
                result.failure = if (e == error.Canceled) .canceled else .other;
                result.detail = @errorName(e);
            }
        };
        return result;
    }

    fn performInner(c: *Client, a: Allocator, out: Outgoing, sink: Sink, result: *Result) !void {
        var url: []const u8 = out.url;
        var method = out.method;
        var body = out.body;
        var drop_sensitive = false;
        var redirects: u8 = 0;
        // The head and the transfer's scratch, off the worker's stack.
        const transfer_buffer = try a.alloc(u8, 64 * 1024);
        const decompress_buffer = try a.alloc(u8, std.compress.flate.max_window_len);
        while (true) {
            const parts = url_util.parse(url) catch |e| {
                result.failure = .invalid_url;
                result.detail = url_util.describe(e);
                return error.Failed;
            };
            const outcome = try c.exchange(a, .{
                .method = method,
                .url = url,
                .parts = parts,
                .headers = out.headers,
                .body = body,
                .verify = out.verify_tls,
                .drop_sensitive = drop_sensitive,
                .follow = out.follow_redirects,
                .redirects = redirects,
                .transfer = transfer_buffer,
                .decompress = decompress_buffer,
            }, sink, result);
            const location = outcome orelse return;
            if (redirects >= out.max_redirects) {
                result.failure = .too_many_redirects;
                return error.Failed;
            }
            redirects += 1;
            const next = try url_util.resolveRedirect(a, url, location.target);
            const next_parts = url_util.parse(next) catch |e| {
                result.failure = .invalid_url;
                result.detail = url_util.describe(e);
                return error.Failed;
            };
            // Credentials don't follow a request to another origin.
            if (!std.ascii.eqlIgnoreCase(parts.host, next_parts.host) or parts.port != next_parts.port or parts.secure != next_parts.secure) drop_sensitive = true;
            if (location.becomes_get) {
                body = &.{};
                if (!std.ascii.eqlIgnoreCase(method, "HEAD")) method = "GET";
            }
            url = next;
        }
    }

    const Exchange = struct {
        method: []const u8,
        url: []const u8,
        parts: url_util.Parts,
        headers: []const Header,
        body: []const BodyPart,
        verify: bool,
        drop_sensitive: bool,
        follow: bool,
        redirects: u8,
        transfer: []u8,
        decompress: []u8,
    };

    const Redirect = struct { target: []const u8, becomes_get: bool };

    /// One request and response. Returns where to go next when redirected.
    fn exchange(c: *Client, a: Allocator, x: Exchange, sink: Sink, result: *Result) !?Redirect {
        const head_text = try writeHead(a, x);
        const body_len = try bodyLength(c.io, x.body, result);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const pooled = if (attempt == 0) c.take(x.parts.host, x.parts.port, x.parts.secure, x.verify) else null;
            const conn = pooled orelse try c.connect(x.parts.host, x.parts.port, x.parts.secure, x.verify, result);
            result.reused_connection = pooled != null;
            var keep = false;
            defer if (keep) c.give(conn) else destroyConn(c, conn);
            var hr: http.Reader = .{ .in = conn.reader(), .state = .ready, .interface = undefined, .max_head_len = max_head };
            const head_bytes = send(c.io, conn, head_text, x.body, body_len, &hr, result) catch |e| {
                // A kept socket the server closed: tell nobody, try a new one.
                if (pooled != null and result.failure != .canceled and e == error.Stale) continue;
                return e;
            };
            return try c.receive(a, x, conn, &hr, head_bytes, sink, result, &keep);
        }
    }

    fn receive(_: *Client, a: Allocator, x: Exchange, conn: *Conn, hr: *http.Reader, head_bytes_in: []const u8, sink: Sink, result: *Result, keep: *bool) !?Redirect {
        // 1xx answers aren't the answer.
        var head_bytes = head_bytes_in;
        while (head_bytes.len >= 12 and head_bytes[9] == '1') {
            head_bytes = hr.receiveHead() catch |e| return readFailed(conn, e, result);
        }
        const head = Parsed.parse(head_bytes) catch |e| {
            result.failure = .protocol;
            result.detail = @errorName(e);
            return error.Failed;
        };
        const status: u16 = @backingInt(head.status);
        const is_head = std.ascii.eqlIgnoreCase(x.method, "HEAD");
        const no_body = is_head or status == 204 or status == 304;
        const redirect = x.follow and head.location != null and switch (status) {
            301, 302, 303, 307, 308 => true,
            else => false,
        };
        if (redirect) {
            const target = try a.dupe(u8, head.location.?);
            const becomes_get = status == 303 or ((status == 301 or status == 302) and std.ascii.eqlIgnoreCase(x.method, "POST"));
            // Reuse the socket when the rest of this answer is small.
            if (!no_body) {
                const r = hr.bodyReader(x.transfer, head.transfer_encoding, head.content_length);
                keep.* = head.keep_alive and (head.content_length != null or head.transfer_encoding == .chunked) and drain(r, 64 * 1024);
            } else {
                keep.* = head.keep_alive;
            }
            return .{ .target = target, .becomes_get = becomes_get };
        }
        // The head is in the socket's buffer, which reading the body reuses.
        const line_end = std.mem.indexOf(u8, head_bytes, "\r\n") orelse head_bytes.len;
        const raw = try a.dupe(u8, head_bytes[@min(line_end + 2, head_bytes.len)..]);
        const reason = try a.dupe(u8, head.reason);
        sink.on_head(sink.ctx, .{ .status = status, .reason = reason, .raw_headers = raw, .url = x.url, .redirects = x.redirects }) catch |e| {
            result.failure = .stopped_by_sink;
            result.detail = @errorName(e);
            return error.Failed;
        };
        if (no_body) {
            keep.* = head.keep_alive;
            return null;
        }
        var decompress: http.Decompress = undefined;
        // zstd and compress weren't asked for by us: their bytes are passed on.
        const encoding: http.ContentEncoding = switch (head.content_encoding) {
            .gzip, .deflate => head.content_encoding,
            else => .identity,
        };
        const framed_by_close = head.transfer_encoding == .none and head.content_length == null;
        const body = hr.bodyReaderDecompressing(x.transfer, head.transfer_encoding, head.content_length, encoding, &decompress, x.decompress);
        while (true) {
            const chunk = body.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    const inner = bodyError(conn, hr, &decompress, encoding);
                    result.failure = if (inner == error.Canceled) .canceled else .connection_lost;
                    result.detail = @errorName(inner);
                    return error.Failed;
                },
            };
            sink.on_data(sink.ctx, chunk) catch |e| {
                result.failure = if (e == error.Canceled) .canceled else .stopped_by_sink;
                result.detail = @errorName(e);
                return error.Failed;
            };
            body.toss(chunk.len);
        }
        keep.* = head.keep_alive and !framed_by_close;
        return null;
    }
};

fn bodyError(conn: *Conn, hr: *http.Reader, decompress: *http.Decompress, encoding: http.ContentEncoding) anyerror {
    if (conn.socket_reader.err) |e| return e;
    if (conn.tls_client) |*t| if (t.read_err) |e| return e;
    if (hr.body_err) |e| return e;
    if (encoding == .gzip or encoding == .deflate) if (decompress.flate.err) |e| return e;
    return error.ReadFailed;
}

fn drain(r: *Io.Reader, limit: usize) bool {
    var left = limit;
    while (left > 0) {
        const n = r.discard(.limited(left)) catch |e| return e == error.EndOfStream;
        if (n == 0) return true;
        left -= n;
    }
    return false;
}

fn nowMs(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

fn destroyConn(c: *Client, conn: *Conn) void {
    conn.stream.close(c.io);
    c.gpa.destroy(conn);
}

fn openSocket(io: Io, host: []const u8, port: u16) !net.Stream {
    if (net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream });
    } else |_| {}
    const name = try net.HostName.init(host);
    return name.connect(io, port, .{ .mode = .stream });
}

fn isCertificateError(e: anyerror) bool {
    return switch (e) {
        error.TlsCertificateNotVerified,
        error.CertificateIssuerNotFound,
        error.CertificateHostMismatch,
        error.CertificateExpired,
        error.CertificateNotYetValid,
        error.CertificateSignatureInvalid,
        error.CertificatePublicKeyInvalid,
        error.CertificateIssuerMismatch,
        error.CertificateNotBefore,
        error.CertificateTimeInvalid,
        => true,
        else => false,
    };
}

fn writeHead(a: Allocator, x: Client.Exchange) ![]u8 {
    if (!check.validMethod(x.method)) return error.InvalidHttpMethod;
    var out: std.ArrayList(u8) = .empty;
    const target = if (x.parts.target.len == 0) "/" else if (x.parts.target[0] == '?') try std.mem.concat(a, u8, &.{ "/", x.parts.target }) else x.parts.target;
    try out.print(a, "{s} {s} HTTP/1.1\r\n", .{ x.method, target });
    const custom = x.headers;
    if (!check.hasHeader(custom, "host")) try out.print(a, "Host: {s}\r\n", .{x.parts.authority});
    for (default_headers) |header| if (!check.hasHeader(custom, header.name)) try out.print(a, "{s}: {s}\r\n", .{ header.name, header.value });
    for (custom) |h| {
        if (x.drop_sensitive and check.isSensitive(h.name)) continue;
        // After a redirect to GET, the body's headers are out of place.
        if (x.body.len == 0 and std.ascii.eqlIgnoreCase(h.name, "content-type") and std.ascii.eqlIgnoreCase(x.method, "GET") and x.redirects > 0) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) continue;
        try out.print(a, "{s}: {s}\r\n", .{ h.name, h.value });
    }
    return out.toOwnedSlice(a);
}

fn bodyLength(io: Io, body: []const BodyPart, result: *Result) !u64 {
    var total: u64 = 0;
    for (body) |p| switch (p) {
        .bytes => |b| total += b.len,
        .file => |path| {
            const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
                result.failure = .file;
                result.detail = @errorName(e);
                return error.Failed;
            };
            if (st.kind != .file) {
                result.failure = .file;
                result.detail = "Not a regular file";
                return error.Failed;
            }
            total += st.size;
        },
    };
    return total;
}

/// Writes the request and waits for the head of the answer.
fn send(io: Io, conn: *Conn, head: []const u8, body: []const BodyPart, body_len: u64, hr: *http.Reader, result: *Result) ![]const u8 {
    const w = conn.writer();
    sendAll(io, conn, w, head, body, body_len, result) catch |e| {
        if (result.failure == .file) return e;
        const inner = writeError(conn, e);
        if (inner == error.Canceled) {
            result.failure = .canceled;
            return error.Failed;
        }
        result.failure = .connection_lost;
        result.detail = @errorName(inner);
        return error.Stale;
    };
    return hr.receiveHead() catch |e| {
        if (e == error.HttpConnectionClosing) {
            result.failure = .connection_lost;
            result.detail = "The server closed the connection without answering";
            return error.Stale;
        }
        const f = readFailed(conn, e, result);
        if (result.failure == .connection_lost) return error.Stale;
        return f;
    };
}

fn writeError(conn: *Conn, e: anyerror) anyerror {
    if (conn.socket_writer.err) |w| return w;
    return e;
}

fn sendAll(io: Io, conn: *Conn, w: *Io.Writer, head: []const u8, body: []const BodyPart, body_len: u64, result: *Result) !void {
    try w.writeAll(head);
    if (body_len > 0 or body.len > 0) try w.print("Content-Length: {d}\r\n", .{body_len});
    try w.writeAll("\r\n");
    for (body) |p| switch (p) {
        .bytes => |b| try w.writeAll(b),
        .file => |path| {
            const f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
                result.failure = .file;
                result.detail = @errorName(e);
                return error.Failed;
            };
            defer f.close(io);
            var buf: [32 * 1024]u8 = undefined;
            var fr = f.readerStreaming(io, &buf);
            _ = fr.interface.streamRemaining(w) catch |e| {
                if (e == error.ReadFailed) {
                    result.failure = .file;
                    result.detail = if (fr.err) |x| @errorName(x) else "ReadFailed";
                    return error.Failed;
                }
                return e;
            };
        },
    };
    try conn.flush();
}

fn readFailed(conn: *Conn, e: anyerror, result: *Result) anyerror {
    var inner: anyerror = e;
    if (e == error.ReadFailed) {
        if (conn.socket_reader.err) |r| inner = r;
        if (inner == error.ReadFailed) if (conn.tls_client) |*t| if (t.read_err) |r| {
            inner = r;
        };
    }
    switch (inner) {
        error.Canceled => result.failure = .canceled,
        error.HttpHeadersOversize, error.HttpRequestTruncated => result.failure = .protocol,
        else => result.failure = .connection_lost,
    }
    result.detail = @errorName(inner);
    return error.Failed;
}

/// Reads the head's status and each header, from `raw_headers`.
pub fn iterateHeaders(raw: []const u8) http.HeaderIterator {
    // The iterator begins after a first line; give it none to skip.
    return .{ .bytes = raw, .index = 0 };
}
