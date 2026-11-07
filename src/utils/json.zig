//! JSON helpers: forgiving field access over `std.json.Value`, and a small
//! lossless lexer used to validate, format and minify text *without* parsing
//! values: numbers and strings keep their exact bytes, so "1.10" stays "1.10".
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn int(v: std.json.Value, key: []const u8) ?i64 {
    const f = get(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |d| if (d >= -9e15 and d <= 9e15) @intFromFloat(d) else null,
        else => null,
    };
}

pub fn boolean(v: std.json.Value, key: []const u8) ?bool {
    const f = get(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}

pub fn array(v: std.json.Value, key: []const u8) []const std.json.Value {
    const f = get(v, key) orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

pub fn dupeStr(a: Allocator, v: std.json.Value, key: []const u8, default: []const u8) ![]const u8 {
    return a.dupe(u8, str(v, key) orelse default);
}

pub fn field(s: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try s.objectField(name);
    try s.write(value);
}

pub const TokenKind = enum { lbrace, rbrace, lbracket, rbracket, comma, colon, string, number, true_, false_, null_, invalid, eof };

pub const Token = struct { kind: TokenKind, start: usize, end: usize };

/// The token at or after `i`. Never fails: bad input is an `invalid` token.
pub fn nextToken(s: []const u8, start: usize) Token {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    if (i >= s.len) return .{ .kind = .eof, .start = s.len, .end = s.len };
    const one: ?TokenKind = switch (s[i]) {
        '{' => .lbrace,
        '}' => .rbrace,
        '[' => .lbracket,
        ']' => .rbracket,
        ',' => .comma,
        ':' => .colon,
        else => null,
    };
    if (one) |k| return .{ .kind = k, .start = i, .end = i + 1 };
    if (s[i] == '"') {
        var j = i + 1;
        while (j < s.len) : (j += 1) {
            switch (s[j]) {
                '"' => return .{ .kind = .string, .start = i, .end = j + 1 },
                '\\' => j += 1,
                '\n' => return .{ .kind = .invalid, .start = i, .end = j },
                else => {},
            }
        }
        return .{ .kind = .invalid, .start = i, .end = s.len };
    }
    if (s[i] == '-' or std.ascii.isDigit(s[i])) {
        var j = i + 1;
        while (j < s.len) : (j += 1) switch (s[j]) {
            '0'...'9', '.', 'e', 'E', '+', '-' => {},
            else => break,
        };
        if (!validNumber(s[i..j])) return .{ .kind = .invalid, .start = i, .end = j };
        return .{ .kind = .number, .start = i, .end = j };
    }
    const words = [_]struct { []const u8, TokenKind }{ .{ "true", .true_ }, .{ "false", .false_ }, .{ "null", .null_ } };
    for (words) |w| if (std.mem.startsWith(u8, s[i..], w[0]))
        return .{ .kind = w[1], .start = i, .end = i + w[0].len };
    return .{ .kind = .invalid, .start = i, .end = i + 1 };
}

fn validNumber(n: []const u8) bool {
    var i: usize = 0;
    if (i < n.len and n[i] == '-') i += 1;
    if (i >= n.len) return false;
    if (n[i] == '0') {
        i += 1;
    } else if (std.ascii.isDigit(n[i])) {
        while (i < n.len and std.ascii.isDigit(n[i])) i += 1;
    } else return false;
    if (i < n.len and n[i] == '.') {
        i += 1;
        const b = i;
        while (i < n.len and std.ascii.isDigit(n[i])) i += 1;
        if (i == b) return false;
    }
    if (i < n.len and (n[i] == 'e' or n[i] == 'E')) {
        i += 1;
        if (i < n.len and (n[i] == '+' or n[i] == '-')) i += 1;
        const b = i;
        while (i < n.len and std.ascii.isDigit(n[i])) i += 1;
        if (i == b) return false;
    }
    return i == n.len;
}

pub const Problem = struct {
    offset: usize,
    line: usize,
    column: usize,
    message: []const u8,
};

const max_depth = 4096;

fn problemAt(s: []const u8, offset: usize, message: []const u8) Problem {
    var line: usize = 1;
    var last: usize = 0;
    for (s[0..@min(offset, s.len)], 0..) |ch, i| if (ch == '\n') {
        line += 1;
        last = i + 1;
    };
    return .{ .offset = offset, .line = line, .column = offset - @min(last, offset) + 1, .message = message };
}

/// What is expected next in the value grammar.
const Expect = enum { value, value_or_close, key_or_close, key, colon, comma_or_close, end };

/// Null when `s` is one well-formed JSON document; else where it first isn't.
/// `visit`, if given, sees each token as it's accepted (format and minify).
pub fn check(s: []const u8, visitor: anytype) ?Problem {
    var stack: [max_depth / 8]u8 = undefined; // one bit per level: 1 is an object
    var depth: usize = 0;
    var expect: Expect = .value;
    var i: usize = 0;
    while (true) {
        const t = nextToken(s, i);
        i = t.end;
        const in_object = depth > 0 and (stack[(depth - 1) / 8] >> @intCast((depth - 1) % 8)) & 1 == 1;
        switch (t.kind) {
            .eof => {
                if (expect == .end) return null;
                return problemAt(s, s.len, if (s.len == 0) "Empty document" else "Unexpected end of JSON");
            },
            .invalid => return problemAt(s, t.start, if (t.start < s.len and s[t.start] == '"') "Unterminated string" else "Invalid token"),
            .lbrace, .lbracket => {
                if (expect != .value and expect != .value_or_close) return problemAt(s, t.start, unexpected(expect));
                if (depth >= max_depth) return problemAt(s, t.start, "Nested too deeply");
                const bit: u3 = @intCast(depth % 8);
                if (t.kind == .lbrace) stack[depth / 8] |= @as(u8, 1) << bit else stack[depth / 8] &= ~(@as(u8, 1) << bit);
                depth += 1;
                expect = if (t.kind == .lbrace) .key_or_close else .value_or_close;
            },
            .rbrace, .rbracket => {
                const wants_object = t.kind == .rbrace;
                const can_close = expect == .comma_or_close or (wants_object and expect == .key_or_close) or (!wants_object and expect == .value_or_close);
                if (depth == 0 or in_object != wants_object or !can_close) return problemAt(s, t.start, if (expect == .key or expect == .value) "Trailing comma" else "Mismatched closing bracket");
                depth -= 1;
                expect = if (depth == 0) .end else .comma_or_close;
            },
            .comma => {
                if (expect != .comma_or_close) return problemAt(s, t.start, unexpected(expect));
                expect = if (in_object) .key else .value;
            },
            .colon => {
                if (expect != .colon) return problemAt(s, t.start, unexpected(expect));
                expect = .value;
            },
            .string, .number, .true_, .false_, .null_ => {
                if (expect == .key or expect == .key_or_close) {
                    if (t.kind != .string) return problemAt(s, t.start, "Object keys must be strings");
                    expect = .colon;
                } else if (expect == .value or expect == .value_or_close) {
                    expect = if (depth == 0) .end else .comma_or_close;
                } else return problemAt(s, t.start, unexpected(expect));
            },
        }
        if (@TypeOf(visitor) != void) visitor.token(s, t) catch return problemAt(s, t.start, "Out of memory");
    }
}

fn unexpected(e: Expect) []const u8 {
    return switch (e) {
        .colon => "Expected ':' after the key",
        .comma_or_close => "Expected ',' or a closing bracket",
        .end => "Unexpected content after the document",
        .key, .key_or_close => "Expected a string key",
        .value, .value_or_close => "Expected a value",
    };
}

pub fn validate(s: []const u8) ?Problem {
    return check(s, {});
}

const Formatter = struct {
    out: *std.ArrayList(u8),
    a: Allocator,
    indent: usize,
    level: usize = 0,
    fresh: bool = false, // just opened a container

    fn newline(f: *Formatter) !void {
        try f.out.append(f.a, '\n');
        try f.out.appendNTimes(f.a, ' ', f.level * f.indent);
    }

    fn token(f: *Formatter, s: []const u8, t: Token) !void {
        const text = s[t.start..t.end];
        if (f.indent == 0) return f.out.appendSlice(f.a, text);
        switch (t.kind) {
            .lbrace, .lbracket => {
                if (f.fresh) try f.newline();
                try f.out.appendSlice(f.a, text);
                f.level += 1;
                f.fresh = true;
            },
            .rbrace, .rbracket => {
                f.level -= 1;
                // {} and [] stay on one line.
                if (!f.fresh) try f.newline();
                f.fresh = false;
                try f.out.appendSlice(f.a, text);
            },
            .comma => {
                try f.out.append(f.a, ',');
                try f.newline();
            },
            .colon => try f.out.appendSlice(f.a, ": "),
            else => {
                if (f.fresh) try f.newline();
                f.fresh = false;
                try f.out.appendSlice(f.a, text);
            },
        }
    }
};

pub const FormatResult = union(enum) { ok: []u8, problem: Problem };

/// `s` re-indented (`indent` spaces), or minified when `indent` is 0.
pub fn format(a: Allocator, s: []const u8, indent: usize) !FormatResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, s.len + s.len / 4);
    var f: Formatter = .{ .out = &out, .a = a, .indent = indent };
    if (check(s, &f)) |p| {
        out.deinit(a);
        return .{ .problem = p };
    }
    return .{ .ok = try out.toOwnedSlice(a) };
}

test "format keeps numbers and strings exact" {
    const a = std.testing.allocator;
    const r = try format(a, "{\"a\":1.10,\"b\":[true,null,{}],\"c\":[],\"s\":\"x\\n\\\"y\"}", 2);
    defer a.free(r.ok);
    try std.testing.expectEqualStrings(
        \\{
        \\  "a": 1.10,
        \\  "b": [
        \\    true,
        \\    null,
        \\    {}
        \\  ],
        \\  "c": [],
        \\  "s": "x\n\"y"
        \\}
    , r.ok);
}

test "minify undoes format" {
    const a = std.testing.allocator;
    const src = "{\"a\":[1,2,{\"b\":\"c d\"}],\"e\":{}}";
    const pretty = try format(a, src, 4);
    defer a.free(pretty.ok);
    const mini = try format(a, pretty.ok, 0);
    defer a.free(mini.ok);
    try std.testing.expectEqualStrings(src, mini.ok);
}

test "problems say where" {
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "{\"a\":1,}", 1, "Trailing comma" },
        .{ "[1,\n2,\n3", 3, "Unexpected end of JSON" },
        .{ "{\"a\" 1}", 1, "Expected ':' after the key" },
        .{ "{a:1}", 1, "Invalid token" },
        .{ "[1] 2", 1, "Unexpected content after the document" },
        .{ "\"abc", 1, "Unterminated string" },
        .{ "[01]", 1, "Invalid token" },
        .{ "", 1, "Empty document" },
        .{ "[1}", 1, "Mismatched closing bracket" },
    };
    for (cases) |c| {
        const p = validate(c[0]) orelse return error.ExpectedProblem;
        try std.testing.expectEqual(c[1], p.line);
        try std.testing.expectEqualStrings(c[2], p.message);
    }
    try std.testing.expect(validate(" {\"a\": [1, -2.5e3, \"\\u00e9\", {}]} ") == null);
    try std.testing.expect(validate("42") == null);
}
