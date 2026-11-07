//! cURL commands to requests and back. Options it doesn't understand become
//! warnings, never silence: the user is told exactly what wasn't carried over.
const std = @import("std");
const req = @import("../core/request.zig");
const url_util = @import("../utils/url.zig");
const Allocator = std.mem.Allocator;
const KeyValue = req.KeyValue;

pub const Imported = struct {
    request: req.Request,
    warnings: []const []const u8,
};

pub const ParseError = error{ NotCurl, UnterminatedQuote, NoUrl, OutOfMemory };

pub fn describe(e: ParseError) []const u8 {
    return switch (e) {
        error.NotCurl => "This doesn't look like a curl command",
        error.UnterminatedQuote => "The command has an unterminated quote",
        error.NoUrl => "The command has no URL",
        error.OutOfMemory => "Out of memory",
    };
}

/// Shell words: single and double quotes, backslash escapes, line
/// continuations (`\` for bash, `^` for cmd, backtick for PowerShell), and
/// `$'...'` strings.
pub fn tokenize(a: Allocator, s: []const u8) ParseError![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (in_word) {
                    try words.append(a, try cur.toOwnedSlice(a));
                    in_word = false;
                }
                i += 1;
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, s, i + 1, '\'') orelse return error.UnterminatedQuote;
                try cur.appendSlice(a, s[i + 1 .. end]);
                i = end + 1;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (true) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    if (s[i] == '"') break;
                    if (s[i] == '\\' and i + 1 < s.len and std.mem.indexOfScalar(u8, "\\\"$`\n", s[i + 1]) != null) i += 1;
                    try cur.append(a, s[i]);
                    i += 1;
                }
                i += 1;
            },
            '$' => if (i + 1 < s.len and s[i + 1] == '\'') {
                in_word = true;
                i += 2;
                while (true) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    if (s[i] == '\'') break;
                    if (s[i] == '\\' and i + 1 < s.len) {
                        i += 1;
                        try cur.append(a, switch (s[i]) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            else => s[i],
                        });
                    } else try cur.append(a, s[i]);
                    i += 1;
                }
                i += 1;
            } else {
                in_word = true;
                try cur.append(a, c);
                i += 1;
            },
            '\\', '^', '`' => {
                // A continuation: this character, then the line's end.
                var j = i + 1;
                if (j < s.len and s[j] == '\r') j += 1;
                if (j >= s.len or s[j] == '\n') {
                    i = @min(j + 1, s.len);
                } else if (c == '\\') {
                    in_word = true;
                    try cur.append(a, s[i + 1]);
                    i += 2;
                } else {
                    in_word = true;
                    try cur.append(a, c);
                    i += 1;
                }
            },
            else => {
                in_word = true;
                try cur.append(a, c);
                i += 1;
            },
        }
    }
    if (in_word) try words.append(a, try cur.toOwnedSlice(a));
    return words.items;
}

/// Parses `command` with everything allocated in `a` (use an arena).
pub fn parse(a: Allocator, command: []const u8) ParseError!Imported {
    const args = try tokenize(a, std.mem.trim(u8, command, " \t\r\n"));
    if (args.len == 0 or !isCurlName(args[0])) return error.NotCurl;
    var warnings: std.ArrayList([]const u8) = .empty;
    var r: req.Request = .{ .name = "Imported request" };
    var headers: std.ArrayList(KeyValue) = .empty;
    var data: std.ArrayList(u8) = .empty;
    var has_data = false;
    var form: std.ArrayList(KeyValue) = .empty;
    var url: ?[]const u8 = null;
    var method: ?[]const u8 = null;
    var get_with_data = false;
    var urlencode = false;
    var file: ?[]const u8 = null;
    var head = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var arg = args[i];
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                inline_value = arg[eq + 1 ..];
                arg = arg[0..eq];
            }
        } else if (arg.len > 2 and arg[0] == '-' and takesValue(arg[0..2])) {
            // -XPOST, -d'data'
            inline_value = arg[2..];
            arg = arg[0..2];
        } else if (arg.len > 2 and arg[0] == '-') {
            // Clusters of flags: -sSL.
            for (arg[1..]) |flag| {
                const name = try std.fmt.allocPrint(a, "-{c}", .{flag});
                if (isIgnored(name)) continue;
                switch (flag) {
                    'L' => r.settings.follow_redirects = true,
                    'k' => r.settings.verify_tls = false,
                    'I' => head = true,
                    'G' => get_with_data = true,
                    else => try warnings.append(a, try std.fmt.allocPrint(a, "Unsupported option {s} was ignored", .{name})),
                }
            }
            continue;
        }
        if (arg.len == 0 or arg[0] != '-') {
            if (url == null) url = arg else try warnings.append(a, try std.fmt.allocPrint(a, "Extra URL ignored: {s}", .{arg}));
            continue;
        }
        const value = struct {
            fn get(all: []const []const u8, at: *usize, given: ?[]const u8) ?[]const u8 {
                if (given) |g| return g;
                if (at.* + 1 >= all.len) return null;
                at.* += 1;
                return all[at.*];
            }
        }.get;
        if (eqAny(arg, &.{ "-X", "--request" })) {
            method = value(args, &i, inline_value);
        } else if (eqAny(arg, &.{ "-H", "--header" })) {
            const h = value(args, &i, inline_value) orelse continue;
            if (std.mem.indexOfScalar(u8, h, ':')) |colon| {
                try headers.append(a, .{ .key = std.mem.trim(u8, h[0..colon], " \t"), .value = std.mem.trim(u8, h[colon + 1 ..], " \t") });
            } else if (std.mem.endsWith(u8, h, ";")) {
                try headers.append(a, .{ .key = h[0 .. h.len - 1] });
            } else try warnings.append(a, try std.fmt.allocPrint(a, "Header without a colon ignored: {s}", .{h}));
        } else if (eqAny(arg, &.{ "-d", "--data", "--data-ascii", "--data-raw", "--data-binary", "--data-urlencode", "--json" })) {
            const d = value(args, &i, inline_value) orelse continue;
            if (d.len > 0 and d[0] == '@' and !std.mem.eql(u8, arg, "--data-raw")) {
                if (std.mem.eql(u8, arg, "--data-binary") or std.mem.eql(u8, arg, "--json")) {
                    file = d[1..];
                } else try warnings.append(a, try std.fmt.allocPrint(a, "Data from a file isn't read here: {s}", .{d}));
                continue;
            }
            if (has_data) try data.append(a, '&');
            has_data = true;
            if (std.mem.eql(u8, arg, "--data-urlencode")) {
                urlencode = true;
                if (std.mem.indexOfScalar(u8, d, '=')) |eq| {
                    try data.appendSlice(a, d[0 .. eq + 1]);
                    try data.appendSlice(a, try url_util.encodeForm(a, d[eq + 1 ..]));
                } else try data.appendSlice(a, try url_util.encodeForm(a, d));
            } else try data.appendSlice(a, d);
            if (std.mem.eql(u8, arg, "--json")) {
                if (headerIndex(headers.items, "content-type") == null) try headers.append(a, .{ .key = "Content-Type", .value = "application/json" });
                if (headerIndex(headers.items, "accept") == null) try headers.append(a, .{ .key = "Accept", .value = "application/json" });
            }
        } else if (eqAny(arg, &.{ "-F", "--form", "--form-string" })) {
            const f = value(args, &i, inline_value) orelse continue;
            const eq = std.mem.indexOfScalar(u8, f, '=') orelse {
                try warnings.append(a, try std.fmt.allocPrint(a, "Form field without '=' ignored: {s}", .{f}));
                continue;
            };
            var val = f[eq + 1 ..];
            var is_file = false;
            if (!std.mem.eql(u8, arg, "--form-string") and val.len > 0 and (val[0] == '@' or val[0] == '<')) {
                is_file = true;
                if (std.mem.indexOfScalar(u8, val, ';')) |semi| {
                    try warnings.append(a, try std.fmt.allocPrint(a, "Form field options ignored: {s}", .{val[semi..]}));
                    val = val[0..semi];
                }
                val = val[1..];
            }
            try form.append(a, .{ .key = f[0..eq], .value = val, .is_file = is_file });
        } else if (eqAny(arg, &.{"--url"})) {
            url = value(args, &i, inline_value);
        } else if (eqAny(arg, &.{ "-A", "--user-agent" })) {
            try headers.append(a, .{ .key = "User-Agent", .value = value(args, &i, inline_value) orelse continue });
        } else if (eqAny(arg, &.{ "-e", "--referer" })) {
            try headers.append(a, .{ .key = "Referer", .value = value(args, &i, inline_value) orelse continue });
        } else if (eqAny(arg, &.{ "-b", "--cookie" })) {
            const v = value(args, &i, inline_value) orelse continue;
            if (std.mem.indexOfScalar(u8, v, '=') != null) {
                try headers.append(a, .{ .key = "Cookie", .value = v });
            } else try warnings.append(a, try std.fmt.allocPrint(a, "Cookie file ignored: {s}", .{v}));
        } else if (eqAny(arg, &.{ "-u", "--user" })) {
            _ = value(args, &i, inline_value);
            try warnings.append(a, "Basic credentials (-u) were not imported: authentication isn't managed here; add an Authorization header");
        } else if (eqAny(arg, &.{"--max-time"}) or eqAny(arg, &.{"-m"})) {
            const v = value(args, &i, inline_value) orelse continue;
            const seconds = std.fmt.parseFloat(f64, v) catch 0;
            if (seconds > 0) r.settings.timeout_ms = @intFromFloat(@min(seconds * 1000, 4e9));
        } else if (eqAny(arg, &.{"--max-redirs"})) {
            const v = value(args, &i, inline_value) orelse continue;
            r.settings.max_redirects = std.fmt.parseInt(u8, v, 10) catch r.settings.max_redirects;
        } else if (eqAny(arg, &.{ "-L", "--location" })) {
            r.settings.follow_redirects = true;
        } else if (eqAny(arg, &.{ "-k", "--insecure" })) {
            r.settings.verify_tls = false;
        } else if (eqAny(arg, &.{ "-I", "--head" })) {
            head = true;
        } else if (eqAny(arg, &.{ "-G", "--get" })) {
            get_with_data = true;
        } else if (eqAny(arg, &.{"--compressed"}) or isIgnored(arg)) {
            // Harmless output options, and what Retort does anyway.
            if (takesValue(arg) and inline_value == null) i += 1;
        } else {
            try warnings.append(a, try std.fmt.allocPrint(a, "Unsupported option {s} was ignored", .{arg}));
            // Its value would otherwise read as the URL.
            if (takesValue(arg) and inline_value == null) i += 1;
        }
    }

    const full = url orelse return error.NoUrl;
    r.url = full;
    r.settings.follow_redirects = hasLocationFlag(args);
    if (has_data and get_with_data) {
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, full, '?') != null) "&" else "?";
        r.url = try std.mem.concat(a, u8, &.{ full, sep, data.items });
        has_data = false;
    }
    r.params = try url_util.parseParams(a, r.url);
    if (form.items.len > 0) {
        r.body_kind = .multipart;
        r.form = form.items;
    } else if (file) |f| {
        r.body_kind = .file;
        r.file_path = f;
    } else if (has_data) {
        r.body_text = data.items;
        r.body_kind = kindOf(headers.items, data.items, urlencode);
    }
    const has_body = r.body_kind != .none;
    r.method = method orelse if (head) "HEAD" else if (has_body) "POST" else "GET";
    r.headers = headers.items;
    if (head and method != null) try warnings.append(a, "Both -I and -X were given; -X wins");
    return .{ .request = r, .warnings = warnings.items };
}

fn hasLocationFlag(args: []const []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--location") or std.mem.eql(u8, arg, "-L")) return true;
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-' and !takesValue(arg[0..2]) and std.mem.indexOfScalar(u8, arg, 'L') != null) return true;
    }
    return false;
}

fn kindOf(headers: []const KeyValue, data: []const u8, urlencode: bool) req.BodyKind {
    if (headerIndex(headers, "content-type")) |i| {
        const ct = headers[i].value;
        if (std.ascii.findIgnoreCase(ct, "json") != null) return .json;
        if (std.ascii.findIgnoreCase(ct, "xml") != null) return .xml;
        if (std.ascii.findIgnoreCase(ct, "x-www-form-urlencoded") != null) return .form_urlencoded;
        return .text;
    }
    if (urlencode) return .form_urlencoded;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return .json;
    // curl's own default for -d.
    return .form_urlencoded;
}

fn headerIndex(headers: []const KeyValue, name: []const u8) ?usize {
    for (headers, 0..) |h, i| if (std.ascii.eqlIgnoreCase(h.key, name)) return i;
    return null;
}

fn isCurlName(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "curl") or std.ascii.eqlIgnoreCase(s, "curl.exe");
}

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn isIgnored(s: []const u8) bool {
    return eqAny(s, &.{ "-s", "--silent", "-S", "--show-error", "-v", "--verbose", "-i", "--include", "-#", "--progress-bar", "-f", "--fail", "-o", "--output", "-w", "--write-out", "-O", "--remote-name", "--http1.1", "--http2", "-g", "--globoff" });
}

/// Options whose value is the next word, including ones only warned about.
fn takesValue(s: []const u8) bool {
    return eqAny(s, &.{
        "-X",              "-H",           "-d",           "-F",       "-A",            "-e",                "-b",        "-u",
        "-m",              "-o",           "-w",           "--output", "--write-out",   "--connect-timeout", "--retry",   "--proxy",
        "-x",              "--cert",       "-E",           "--key",    "--cacert",      "--capath",          "--resolve", "--interface",
        "-c",              "--cookie-jar", "--limit-rate", "-T",       "--upload-file", "--max-filesize",    "-r",        "--range",
        "--oauth2-bearer", "--aws-sigv4",
    });
}

/// A shell-quoted word (POSIX single quotes).
fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    var it = std.mem.splitScalar(u8, s, '\'');
    var first = true;
    while (it.next()) |part| {
        if (!first) try w.writeAll("'\\''");
        first = false;
        try w.writeAll(part);
    }
    try w.writeByte('\'');
}

/// A curl command for `r`, which it was given with variables already resolved
/// or as templates: what you see is what's copied.
pub fn generate(a: Allocator, r: req.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    generateTo(&out.writer, a, r) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn generateTo(w: *std.Io.Writer, a: Allocator, r: req.Request) !void {
    try w.writeAll("curl");
    if (!std.mem.eql(u8, r.method, "GET")) {
        try w.writeAll(" -X ");
        try w.writeAll(r.method);
    }
    try w.writeByte(' ');
    try writeQuoted(w, r.url);
    if (r.settings.follow_redirects) try w.writeAll(" -L");
    if (!r.settings.verify_tls) try w.writeAll(" -k");
    for (r.headers) |h| {
        if (!h.enabled or h.key.len == 0) continue;
        try w.writeAll(" \\\n  -H ");
        const line = try std.fmt.allocPrint(a, "{s}: {s}", .{ h.key, h.value });
        defer a.free(line);
        try writeQuoted(w, line);
    }
    switch (r.body_kind) {
        .none => {},
        .json, .text, .xml => {
            if (r.body_kind.contentType()) |ct| if (r.header("content-type") == null) {
                try w.writeAll(" \\\n  -H ");
                const line = try std.fmt.allocPrint(a, "Content-Type: {s}", .{ct});
                defer a.free(line);
                try writeQuoted(w, line);
            };
            if (r.body_text.len > 0) {
                try w.writeAll(" \\\n  --data-raw ");
                try writeQuoted(w, r.body_text);
            }
        },
        .form_urlencoded => for (r.form) |f| {
            if (!f.enabled) continue;
            try w.writeAll(" \\\n  --data-urlencode ");
            const pair = try std.fmt.allocPrint(a, "{s}={s}", .{ f.key, f.value });
            defer a.free(pair);
            try writeQuoted(w, pair);
        },
        .multipart => for (r.form) |f| {
            if (!f.enabled) continue;
            try w.writeAll(" \\\n  -F ");
            const pair = try std.fmt.allocPrint(a, "{s}={s}{s}", .{ f.key, if (f.is_file) "@" else "", f.value });
            defer a.free(pair);
            try writeQuoted(w, pair);
        },
        .file => if (r.file_path.len > 0) {
            try w.writeAll(" \\\n  --data-binary ");
            const at = try std.fmt.allocPrint(a, "@{s}", .{r.file_path});
            defer a.free(at);
            try writeQuoted(w, at);
        },
    }
}

const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "a typical command" {
    var ar = arena();
    defer ar.deinit();
    const r = try parse(ar.allocator(),
        \\curl -X PUT 'https://api.example.com/users/1?verbose=true&x=1' \
        \\  -H 'Content-Type: application/json' \
        \\  -H "Accept: */*" \
        \\  --data-raw '{"name":"Ada \"L\""}' -sS --compressed
    );
    try t.expectEqual(@as(usize, 0), r.warnings.len);
    try t.expectEqualStrings("PUT", r.request.method);
    try t.expectEqualStrings("https://api.example.com/users/1?verbose=true&x=1", r.request.url);
    try t.expectEqual(@as(usize, 2), r.request.params.len);
    try t.expectEqual(@as(usize, 2), r.request.headers.len);
    try t.expectEqualStrings("*/*", r.request.headers[1].value);
    try t.expectEqual(req.BodyKind.json, r.request.body_kind);
    try t.expectEqualStrings("{\"name\":\"Ada \\\"L\\\"\"}", r.request.body_text);
    try t.expect(!r.request.settings.follow_redirects);
}

test "method inference and data forms" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("GET", (try parse(a, "curl http://h")).request.method);
    try t.expectEqualStrings("HEAD", (try parse(a, "curl -I http://h")).request.method);
    try t.expectEqualStrings("DELETE", (try parse(a, "curl -XDELETE http://h")).request.method);
    try t.expectEqualStrings("PATCH", (try parse(a, "curl --request=PATCH http://h")).request.method);
    const d = try parse(a, "curl http://h -d a=1 -d b=2");
    try t.expectEqualStrings("POST", d.request.method);
    try t.expectEqualStrings("a=1&b=2", d.request.body_text);
    try t.expectEqual(req.BodyKind.form_urlencoded, d.request.body_kind);
    const u = try parse(a, "curl http://h --data-urlencode 'q=a b'");
    try t.expectEqualStrings("q=a+b", u.request.body_text);
    const g = try parse(a, "curl -G http://h?z=0 -d a=1");
    try t.expectEqualStrings("GET", g.request.method);
    try t.expectEqualStrings("http://h?z=0&a=1", g.request.url);
    const f = try parse(a, "curl http://h -F 'name=x' -F 'file=@/tmp/a.png;type=image/png'");
    try t.expectEqual(req.BodyKind.multipart, f.request.body_kind);
    try t.expect(f.request.form[1].is_file);
    try t.expectEqualStrings("/tmp/a.png", f.request.form[1].value);
    try t.expectEqual(@as(usize, 1), f.warnings.len);
    const j = try parse(a, "curl --json '{\"a\":1}' http://h");
    try t.expectEqual(req.BodyKind.json, j.request.body_kind);
    try t.expectEqual(@as(usize, 2), j.request.headers.len);
    const fl = try parse(a, "curl -sSLk http://h");
    try t.expect(fl.request.settings.follow_redirects);
    try t.expect(!fl.request.settings.verify_tls);
    try t.expectEqual(@as(usize, 0), fl.warnings.len);
}

test "unsupported options warn, and their values aren't mistaken for the URL" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try parse(a, "curl --proxy http://p:1 --cert c.pem -u me:pw http://real/ --tlsv1.2");
    try t.expectEqualStrings("http://real/", r.request.url);
    try t.expectEqual(@as(usize, 4), r.warnings.len);
    try t.expect(std.mem.indexOf(u8, r.warnings[0], "--proxy") != null);
    try t.expect(std.mem.indexOf(u8, r.warnings[3], "--tlsv1.2") != null);
}

test "bad commands" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NotCurl, parse(a, "wget http://h"));
    try t.expectError(error.NotCurl, parse(a, ""));
    try t.expectError(error.NoUrl, parse(a, "curl -s"));
    try t.expectError(error.UnterminatedQuote, parse(a, "curl 'http://h"));
    try t.expectError(error.UnterminatedQuote, parse(a, "curl \"http://h"));
}

test "shells' quoting" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const w = try tokenize(a, "curl 'it'\\''s' \"a\\\"b\" $'x\\ny' c\\ d ^\n end");
    try t.expectEqualStrings("it's", w[1]);
    try t.expectEqualStrings("a\"b", w[2]);
    try t.expectEqualStrings("x\ny", w[3]);
    try t.expectEqualStrings("c d", w[4]);
    try t.expectEqualStrings("end", w[5]);
}

test "generate, then parse again" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r: req.Request = .{
        .method = "POST",
        .url = "http://h/a?x=1",
        .headers = &.{ .{ .key = "X-A", .value = "it's" }, .{ .key = "X-Off", .value = "no", .enabled = false } },
        .body_kind = .json,
        .body_text = "{\"q\":\"it's\"}",
        .settings = .{ .follow_redirects = false, .verify_tls = false },
    };
    const text = try generate(a, r);
    try t.expect(std.mem.indexOf(u8, text, "X-Off") == null);
    const back = (try parse(a, text)).request;
    try t.expectEqualStrings(r.method, back.method);
    try t.expectEqualStrings(r.url, back.url);
    try t.expectEqualStrings(r.body_text, back.body_text);
    try t.expectEqualStrings("it's", back.headers[0].value);
    try t.expectEqual(req.BodyKind.json, back.body_kind);
    try t.expect(!back.settings.verify_tls);
    const m = try generate(a, .{ .method = "POST", .url = "http://h", .body_kind = .multipart, .form = &.{ .{ .key = "a", .value = "1" }, .{ .key = "f", .value = "/x y.bin", .is_file = true } } });
    const mb = (try parse(a, m)).request;
    try t.expectEqual(@as(usize, 2), mb.form.len);
    try t.expectEqualStrings("/x y.bin", mb.form[1].value);
}
