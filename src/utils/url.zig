//! URLs as a request editor sees them: templates that may hold `{{vars}}`,
//! split into base, query and fragment without decoding anything, and
//! validated and normalized only when they're about to be sent.
const std = @import("std");
const KeyValue = @import("../core/request.zig").KeyValue;
const Allocator = std.mem.Allocator;

pub const Split = struct { base: []const u8, query: []const u8, fragment: []const u8 };

/// `?` and `#` inside `{{...}}` don't split.
pub fn split(url: []const u8) Split {
    var q: ?usize = null;
    var h: ?usize = null;
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '{' and i + 1 < url.len and url[i + 1] == '{') {
            if (std.mem.indexOfPos(u8, url, i, "}}")) |e| i = e + 1;
            continue;
        }
        if (url[i] == '?' and q == null and h == null) q = i;
        if (url[i] == '#' and h == null) h = i;
    }
    const end = h orelse url.len;
    return .{
        .base = url[0 .. q orelse end],
        .query = if (q) |x| url[x + 1 .. end] else "",
        .fragment = if (h) |x| url[x + 1 ..] else "",
    };
}

/// The query's pairs as written: not decoded, so what you typed stays.
pub fn parseParams(a: Allocator, url: []const u8) ![]KeyValue {
    const q = split(url).query;
    var out: std.ArrayList(KeyValue) = .empty;
    if (q.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        try out.append(a, .{
            .key = try a.dupe(u8, if (eq) |e| pair[0..e] else pair),
            .value = try a.dupe(u8, if (eq) |e| pair[e + 1 ..] else ""),
        });
    }
    return out.items;
}

/// `url` with its query made of the enabled rows (fragment kept).
pub fn withParams(a: Allocator, url: []const u8, params: []const KeyValue) ![]u8 {
    const s = split(url);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, s.base);
    var first = true;
    for (params) |p| {
        if (!p.enabled or (p.key.len == 0 and p.value.len == 0)) continue;
        try out.append(a, if (first) '?' else '&');
        first = false;
        try out.appendSlice(a, p.key);
        if (p.value.len > 0) {
            try out.append(a, '=');
            try out.appendSlice(a, p.value);
        }
    }
    if (s.fragment.len > 0) {
        try out.append(a, '#');
        try out.appendSlice(a, s.fragment);
    }
    return out.toOwnedSlice(a);
}

const unreserved = "-._~";

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, unreserved, c) != null;
}

/// RFC 3986 percent-encoding of everything but unreserved characters.
pub fn encode(a: Allocator, s: []const u8) ![]u8 {
    return encodeImpl(a, s, false);
}

/// application/x-www-form-urlencoded: as `encode`, spaces as '+'.
pub fn encodeForm(a: Allocator, s: []const u8) ![]u8 {
    return encodeImpl(a, s, true);
}

fn encodeImpl(a: Allocator, s: []const u8, plus: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, s.len);
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(a, c);
        } else if (plus and c == ' ') {
            try out.append(a, '+');
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(a);
}

/// Decodes %XX; malformed escapes stay as written. `plus`: '+' is a space.
pub fn decode(a: Allocator, s: []const u8, plus: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                try out.append(a, hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        try out.append(a, if (plus and s[i] == '+') ' ' else s[i]);
    }
    return out.toOwnedSlice(a);
}

/// `url` with what can't appear in a request line escaped. Existing %XX
/// escapes, delimiters and sub-delimiters are left as the user wrote them.
pub fn normalize(a: Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const legal = "-._~:/?#[]@!$&'()*+,;=%";
    for (url) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, legal, c) != null) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(a);
}

/// The Encode button: `normalize`, leaving {{variables}} as they are.
pub fn encodeKeepingVars(a: Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < url.len) {
        const open = std.mem.indexOfPos(u8, url, i, "{{");
        const close = if (open) |o| std.mem.indexOfPos(u8, url, o, "}}") else null;
        const end = if (close != null) open.? else url.len;
        const plain = try normalize(a, url[i..end]);
        defer a.free(plain);
        try out.appendSlice(a, plain);
        if (close) |e| try out.appendSlice(a, url[end .. e + 2]);
        i = if (close) |e| e + 2 else url.len;
    }
    return out.toOwnedSlice(a);
}

/// The Decode button: %XX becomes what it stands for, except where that would
/// change the URL's meaning (a delimiter, a percent sign, a control character).
pub fn decodeReadable(a: Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '%' and i + 2 < url.len) {
            const hi = std.fmt.charToDigit(url[i + 1], 16) catch 255;
            const lo = std.fmt.charToDigit(url[i + 2], 16) catch 255;
            if (hi != 255 and lo != 255) {
                const b = hi * 16 + lo;
                if (b > 0x20 and b != 0x7f and std.mem.indexOfScalar(u8, "%&=#+?/", b) == null) {
                    try out.append(a, b);
                    i += 2;
                    continue;
                }
            }
        }
        try out.append(a, url[i]);
    }
    // Half a character isn't readable: then the escapes stay.
    if (!std.unicode.utf8ValidateSlice(out.items)) {
        out.clearRetainingCapacity();
        try out.appendSlice(a, url);
    }
    return out.toOwnedSlice(a);
}

pub const Parts = struct {
    secure: bool,
    host: []const u8, // without brackets
    port: u16,
    /// Path and query, starting with '/': the request target.
    target: []const u8,
    /// Host (and port when it isn't the default) for the Host header.
    authority: []const u8,
};

pub const UrlError = error{
    Empty,
    MissingScheme,
    UnsupportedScheme,
    MissingHost,
    InvalidHost,
    InvalidPort,
    CredentialsInUrl,
    UnresolvedVariable,
    IllegalCharacter,
};

pub fn describe(e: UrlError) []const u8 {
    return switch (e) {
        error.Empty => "Enter a URL",
        error.MissingScheme => "The URL needs http:// or https://",
        error.UnsupportedScheme => "Only http and https URLs are supported",
        error.MissingHost => "The URL has no host",
        error.InvalidHost => "The URL's host is not valid",
        error.InvalidPort => "The URL's port is not valid",
        error.CredentialsInUrl => "Credentials in the URL aren't supported; use a header",
        error.UnresolvedVariable => "The URL has an unresolved {{variable}}",
        error.IllegalCharacter => "The URL contains a control character",
    };
}

/// Splits a resolved URL, or says what's wrong with it.
pub fn parse(url_in: []const u8) UrlError!Parts {
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    if (url.len == 0) return error.Empty;
    if (std.mem.indexOf(u8, url, "{{") != null) return error.UnresolvedVariable;
    for (url) |c| if (c < 0x20 or c == 0x7f) return error.IllegalCharacter;
    const sep = std.mem.indexOf(u8, url, "://") orelse return error.MissingScheme;
    const scheme = url[0..sep];
    const secure = std.ascii.eqlIgnoreCase(scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(scheme, "http")) return error.UnsupportedScheme;
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return error.MissingHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.CredentialsInUrl;
    var host = authority;
    var port: u16 = if (secure) 443 else 80;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidHost;
        host = authority[1..close];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.InvalidHost;
            port_text = authority[close + 2 ..];
        }
    } else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port_text = authority[colon + 1 ..];
    }
    if (host.len == 0) return error.MissingHost;
    if (authority[0] != '[') for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.' and c != '_') return error.InvalidHost;
    };
    if (port_text) |p| {
        if (p.len == 0) return error.InvalidPort;
        port = std.fmt.parseInt(u16, p, 10) catch return error.InvalidPort;
        if (port == 0) return error.InvalidPort;
    }
    var target = rest[end..];
    if (std.mem.indexOfScalar(u8, target, '#')) |h| target = target[0..h];
    return .{ .secure = secure, .host = host, .port = port, .target = target, .authority = authority };
}

/// Where a redirect's Location leads from `base`: absolute, scheme-relative,
/// absolute-path or relative.
pub fn resolveRedirect(a: Allocator, base: []const u8, location_in: []const u8) ![]u8 {
    const location = std.mem.trim(u8, location_in, " \t");
    if (std.mem.indexOf(u8, location, "://")) |sep| {
        // Only when what's before it is really a scheme.
        var scheme = sep > 0;
        for (location[0..sep]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            scheme = false;
        };
        if (scheme) return normalize(a, location);
    }
    const sep = std.mem.indexOf(u8, base, "://") orelse return error.BadBase;
    if (std.mem.startsWith(u8, location, "//")) return normalize(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ base[0..sep], location }));
    const after = base[sep + 3 ..];
    const auth_end = sep + 3 + (std.mem.indexOfAny(u8, after, "/?#") orelse after.len);
    const origin = base[0..auth_end];
    if (location.len == 0) return a.dupe(u8, base);
    if (location[0] == '/') return normalize(a, try std.mem.concat(a, u8, &.{ origin, location }));
    if (location[0] == '?') {
        const b = split(base).base;
        return normalize(a, try std.mem.concat(a, u8, &.{ b, location }));
    }
    const path_full = split(base[auth_end..]).base;
    const dir = if (std.mem.lastIndexOfScalar(u8, path_full, '/')) |s| path_full[0 .. s + 1] else "/";
    return normalize(a, try removeDots(a, origin, dir, location));
}

fn removeDots(a: Allocator, origin: []const u8, dir: []const u8, rel: []const u8) ![]u8 {
    const q = std.mem.indexOfAny(u8, rel, "?#") orelse rel.len;
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(a);
    const joined = try std.mem.concat(a, u8, &.{ dir, rel[0..q] });
    defer a.free(joined);
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = segs.pop();
            continue;
        }
        try segs.append(a, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, origin);
    for (segs.items) |seg| {
        try out.append(a, '/');
        try out.appendSlice(a, seg);
    }
    if (joined.len > 0 and joined[joined.len - 1] == '/') try out.append(a, '/');
    if (segs.items.len == 0 and (joined.len == 0 or joined[joined.len - 1] != '/')) try out.append(a, '/');
    try out.appendSlice(a, rel[q..]);
    return out.toOwnedSlice(a);
}

const t = std.testing;

test "split and params keep what was typed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = split("https://a.b/c?x=1&y=%20#f?g");
    try t.expectEqualStrings("https://a.b/c", s.base);
    try t.expectEqualStrings("x=1&y=%20", s.query);
    try t.expectEqualStrings("f?g", s.fragment);
    const v = split("{{base?#}}/c?x={{a#b}}");
    try t.expectEqualStrings("{{base?#}}/c", v.base);
    try t.expectEqualStrings("x={{a#b}}", v.query);
    const p = try parseParams(a, "http://h/?page=1&flag&dup=a&dup=b&&empty=");
    try t.expectEqual(@as(usize, 5), p.len);
    try t.expectEqualStrings("flag", p[1].key);
    try t.expectEqualStrings("b", p[3].value);
    try t.expectEqualStrings("empty", p[4].key);
}

test "withParams rewrites the query alone" {
    const a = t.allocator;
    const out = try withParams(a, "http://h/p?old=1#frag", &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "off", .value = "2", .enabled = false },
        .{ .key = "dup", .value = "x" },
        .{ .key = "dup", .value = "y" },
        .{ .key = "flag" },
    });
    defer a.free(out);
    try t.expectEqualStrings("http://h/p?a=1&dup=x&dup=y&flag#frag", out);
}

test "encode and decode" {
    const a = t.allocator;
    const e = try encode(a, "a b&c/é");
    defer a.free(e);
    try t.expectEqualStrings("a%20b%26c%2F%C3%A9", e);
    const d = try decode(a, e, false);
    defer a.free(d);
    try t.expectEqualStrings("a b&c/é", d);
    const f = try encodeForm(a, "a b+c");
    defer a.free(f);
    try t.expectEqualStrings("a+b%2Bc", f);
    const bad = try decode(a, "100%+%zz%4", true);
    defer a.free(bad);
    try t.expectEqualStrings("100% %zz%4", bad);
    const n = try normalize(a, "http://h/a b?q=é&r=%20");
    defer a.free(n);
    try t.expectEqualStrings("http://h/a%20b?q=%C3%A9&r=%20", n);
}

test "the Encode and Decode buttons keep the URL's meaning" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("http://h/a%20b?q=caf%C3%A9&r=%26", try encodeKeepingVars(a, "http://h/a b?q=caf\u{e9}&r=%26"));
    try t.expectEqualStrings("{{base}}/a%20b/{{id}}?x={{a b}}", try encodeKeepingVars(a, "{{base}}/a b/{{id}}?x={{a b}}"));
    try t.expectEqualStrings("%7B%7Bopen%20", try encodeKeepingVars(a, "{{open "));
    try t.expectEqualStrings("http://h/?q=caf\u{e9}&r=%26&s=%20&p=%25&t=%2F", try decodeReadable(a, "http://h/?q=caf%C3%A9&r=%26&s=%20&p=%25&t=%2F"));
    try t.expectEqualStrings("http://h/?q=%C3", try decodeReadable(a, "http://h/?q=%C3"));
    try t.expectEqualStrings("100%", try decodeReadable(a, "100%"));
}

test "parse" {
    const p = try parse("https://api.example.com:8443/users?page=1#x");
    try t.expect(p.secure);
    try t.expectEqualStrings("api.example.com", p.host);
    try t.expectEqual(@as(u16, 8443), p.port);
    try t.expectEqualStrings("/users?page=1", p.target);
    const v6 = try parse("http://[::1]:8080/a");
    try t.expectEqualStrings("::1", v6.host);
    try t.expectEqual(@as(u16, 8080), v6.port);
    try t.expectEqualStrings("[::1]:8080", v6.authority);
    try t.expectEqual(@as(u16, 80), (try parse("http://h")).port);
    try t.expectError(error.Empty, parse("  "));
    try t.expectError(error.MissingScheme, parse("example.com/a"));
    try t.expectError(error.UnsupportedScheme, parse("ftp://h"));
    try t.expectError(error.MissingHost, parse("http:///a"));
    try t.expectError(error.InvalidPort, parse("http://h:99999/"));
    try t.expectError(error.InvalidPort, parse("http://h:/"));
    try t.expectError(error.InvalidHost, parse("http://a b/"));
    try t.expectError(error.CredentialsInUrl, parse("http://u:p@h/"));
    try t.expectError(error.UnresolvedVariable, parse("{{base}}/a"));
    try t.expectError(error.IllegalCharacter, parse("http://h/\x01"));
}

test "redirect targets" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = "http://h:1/a/b/c?q=1";
    try t.expectEqualStrings("https://x/y", try resolveRedirect(a, base, "https://x/y"));
    try t.expectEqualStrings("http://x/y", try resolveRedirect(a, base, "//x/y"));
    try t.expectEqualStrings("http://h:1/z", try resolveRedirect(a, base, "/z"));
    try t.expectEqualStrings("http://h:1/a/b/d?r=2", try resolveRedirect(a, base, "d?r=2"));
    try t.expectEqualStrings("http://h:1/a/d", try resolveRedirect(a, base, "../d"));
    try t.expectEqualStrings("http://h:1/a/b/c?r", try resolveRedirect(a, base, "?r"));
    try t.expectEqualStrings("http://h:1/x%20y", try resolveRedirect(a, base, "/x y"));
    try t.expectEqualStrings("http://h:1/d", try resolveRedirect(a, "http://h:1", "d"));
}
