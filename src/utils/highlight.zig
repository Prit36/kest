//! Colors for one row of text at a time: nothing is parsed beyond what's on
//! screen, so a large payload costs what its visible rows cost. A row cut from
//! the middle of a string is colored as well as it can be from the row alone.
const std = @import("std");

pub const Kind = enum { plain, key, string, number, keyword, punct, tag, attr, comment, variable };
pub const Lang = enum { plain, json, xml };
pub const Token = struct { start: u32, end: u32, kind: Kind };

pub const max_tokens = 256;

/// Fills `out`, returns how many; tokens are in order and don't overlap.
/// A row with more tokens than that keeps its first `out.len`.
pub fn tokens(row: []const u8, lang: Lang, out: []Token) usize {
    var w: Writer = .{ .out = out };
    switch (lang) {
        .plain => {},
        .json => json(row, &w),
        .xml => xml(row, &w),
    }
    return w.n;
}

const Writer = struct {
    out: []Token,
    n: usize = 0,

    fn add(w: *Writer, a: usize, b: usize, k: Kind) void {
        if (w.n == w.out.len or b <= a) return;
        w.out[w.n] = .{ .start = @intCast(a), .end = @intCast(b), .kind = k };
        w.n += 1;
    }
};

fn stringEnd(s: []const u8, from: usize, quote: u8) usize {
    var i = from + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == quote) return i + 1;
    }
    return s.len;
}

fn json(s: []const u8, w: *Writer) void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                const e = stringEnd(s, i, '"');
                var k = e;
                while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
                w.add(i, e, if (k < s.len and s[k] == ':') .key else .string);
                i = e;
            },
            '{', '}', '[', ']', ':', ',' => {
                w.add(i, i + 1, .punct);
                i += 1;
            },
            '-', '0'...'9' => {
                var e = i + 1;
                while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.' or s[e] == 'e' or s[e] == 'E' or s[e] == '+' or s[e] == '-')) e += 1;
                w.add(i, e, .number);
                i = e;
            },
            't', 'f', 'n' => {
                var matched = false;
                for ([_][]const u8{ "true", "false", "null" }) |word| {
                    if (std.mem.startsWith(u8, s[i..], word)) {
                        w.add(i, i + word.len, .keyword);
                        i += word.len;
                        matched = true;
                        break;
                    }
                }
                if (!matched) i += 1;
            },
            else => i += 1,
        }
    }
}

fn xml(s: []const u8, w: *Writer) void {
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "<!--")) {
            const e = if (std.mem.indexOfPos(u8, s, i, "-->")) |p| p + 3 else s.len;
            w.add(i, e, .comment);
            i = e;
            continue;
        }
        if (s[i] != '<') {
            i += 1;
            continue;
        }
        var e = i + 1;
        while (e < s.len and !std.ascii.isWhitespace(s[e]) and s[e] != '>' and !(s[e] == '/' and e > i + 1)) e += 1;
        w.add(i, e, .tag);
        i = e;
        while (i < s.len and s[i] != '>') {
            const c = s[i];
            if (c == '"' or c == '\'') {
                const end = stringEnd(s, i, c);
                w.add(i, end, .string);
                i = end;
            } else if (std.ascii.isAlphabetic(c)) {
                var a = i + 1;
                while (a < s.len and (std.ascii.isAlphanumeric(s[a]) or s[a] == '-' or s[a] == ':' or s[a] == '_')) a += 1;
                w.add(i, a, .attr);
                i = a;
            } else i += 1;
        }
        if (i < s.len) {
            w.add(i, i + 1, .tag);
            i += 1;
        }
    }
}

pub fn langOf(content_type: []const u8) Lang {
    if (std.ascii.findIgnoreCase(content_type, "json") != null) return .json;
    if (std.ascii.findIgnoreCase(content_type, "xml") != null or std.ascii.findIgnoreCase(content_type, "html") != null) return .xml;
    return .plain;
}

const t = std.testing;

test "json tokens" {
    var buf: [16]Token = undefined;
    const row = "{\"a\" : [1, true, \"x\\\"y\"]}";
    const n = tokens(row, .json, &buf);
    const toks = buf[0..n];
    try t.expectEqual(Kind.punct, toks[0].kind);
    try t.expectEqual(Kind.key, toks[1].kind);
    try t.expectEqualStrings("\"a\"", row[toks[1].start..toks[1].end]);
    var kinds: [8]Kind = undefined;
    var k: usize = 0;
    for (toks) |tok| if (tok.kind != .punct) {
        kinds[k] = tok.kind;
        k += 1;
    };
    try t.expectEqualSlices(Kind, &.{ .key, .number, .keyword, .string }, kinds[0..k]);
}

test "xml tokens" {
    var buf: [16]Token = undefined;
    const row = "<a href=\"x\">text<!-- c --></a>";
    const n = tokens(row, .xml, &buf);
    try t.expectEqualStrings("<a", row[buf[0].start..buf[0].end]);
    try t.expectEqual(Kind.attr, buf[1].kind);
    try t.expectEqual(Kind.string, buf[2].kind);
    try t.expectEqual(Kind.tag, buf[3].kind);
    try t.expectEqual(Kind.comment, buf[4].kind);
    try t.expectEqualStrings("</a", row[buf[5].start..buf[5].end]);
    try t.expect(n == 7);
}

test "a full buffer keeps the first tokens" {
    var buf: [2]Token = undefined;
    try t.expectEqual(@as(usize, 2), tokens("[1,2,3,4]", .json, &buf));
    try t.expectEqual(@as(usize, 0), tokens("anything", .plain, &buf));
}
