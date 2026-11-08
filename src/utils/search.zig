//! Case-insensitive search of a text, up to a bound: a one-letter search of
//! a large body stops at `max_matches` and says so instead of using more memory.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Match = struct { start: u32, end: u32 };
pub const max_matches = 10_000;

const regex = @import("regex.zig");

pub const Options = struct {
    case_sensitive: bool = false,
    /// Only matches with no word character just before or after them.
    whole_word: bool = false,
    /// The query is a regular expression (see regex.zig).
    regex: bool = false,
};

/// Finds with options. A malformed regular expression fails with
/// error.Syntax and says where in `problem`. Empty regex matches are
/// skipped. True if there were more matches than `max_matches`.
pub fn findWith(a: Allocator, text: []const u8, query: []const u8, options: Options, out: *std.ArrayList(Match), problem: *regex.Problem) !bool {
    if (!options.regex and !options.whole_word and !options.case_sensitive) return findAll(a, text, query, out);
    out.clearRetainingCapacity();
    if (query.len == 0) return false;
    var finder = try Finder.init(a, query, options, problem);
    defer finder.deinit();
    var at: usize = 0;
    while (try finder.next(text, at)) |m| {
        if (out.items.len == max_matches) return true;
        try out.append(a, m);
        at = m.end;
    }
    return false;
}

/// One search, step by step: for Replace and for workers that count.
pub const Finder = struct {
    a: Allocator,
    query: []const u8,
    options: Options,
    re: ?regex.Regex = null,
    vm: regex.Vm,
    caps: []u32 = &.{},
    /// Stops a long search when set.
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn init(a: Allocator, query: []const u8, options: Options, problem: *regex.Problem) !Finder {
        var f: Finder = .{ .a = a, .query = query, .options = options, .vm = .init(a) };
        if (options.regex) {
            f.re = try regex.Regex.compile(a, query, .{ .case_sensitive = options.case_sensitive }, problem);
            f.caps = a.alloc(u32, f.re.?.slots) catch |err| {
                f.re.?.deinit(a);
                return err;
            };
        }
        return f;
    }

    pub fn deinit(f: *Finder) void {
        if (f.re) |*re| re.deinit(f.a);
        f.a.free(f.caps);
        f.vm.deinit();
    }

    /// The first match at or after `from`. After a regex match, `caps`
    /// holds its groups.
    pub fn next(f: *Finder, text: []const u8, from_in: usize) !?Match {
        var from = from_in;
        f.vm.cancel = f.cancel;
        while (from <= text.len) {
            if (f.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
            var m: Match = undefined;
            if (f.re) |*re| {
                if (!try re.find(&f.vm, text, from, false, f.caps)) return null;
                m = .{ .start = f.caps[0], .end = f.caps[1] };
                if (m.end == m.start) {
                    from = m.start + 1;
                    continue;
                }
            } else {
                if (f.query.len == 0 or from + f.query.len > text.len) return null;
                const rel = (if (f.options.case_sensitive) std.mem.indexOf(u8, text[from..], f.query) else std.ascii.findIgnoreCase(text[from..], f.query)) orelse return null;
                m = .{ .start = @intCast(from + rel), .end = @intCast(from + rel + f.query.len) };
            }
            if (f.options.whole_word and !wholeWord(text, m)) {
                from = m.start + 1;
                continue;
            }
            return m;
        }
        return null;
    }

    /// Whether `m` is a match on its own, as Replace checks the selection.
    pub fn exact(f: *Finder, text: []const u8, m: Match) !bool {
        if (f.re) |*re| {
            // What the search would find starting here, ending where the
            // selection does.
            if (!try re.find(&f.vm, text, m.start, true, f.caps)) return false;
            if (f.caps[1] != m.end) return false;
        } else {
            const piece = text[m.start..m.end];
            if (!(if (f.options.case_sensitive) std.mem.eql(u8, piece, f.query) else std.ascii.eqlIgnoreCase(piece, f.query))) return false;
        }
        return !f.options.whole_word or wholeWord(text, m);
    }

    /// What replaces `m` (found by `next` or `exact` just before): the
    /// template, with groups filled in for a regex.
    pub fn replacement(f: *Finder, out: *std.ArrayList(u8), text: []const u8, template: []const u8) !void {
        if (f.re != null) return regex.expand(f.a, out, template, text, f.caps);
        try out.appendSlice(f.a, template);
    }
};

fn wholeWord(text: []const u8, m: Match) bool {
    if (m.start > 0 and regex.wordByte(text[m.start - 1])) return false;
    if (m.end < text.len and regex.wordByte(text[m.end])) return false;
    return true;
}

/// Replaces `out` with what's found; true if there were more than it keeps.
pub fn findAll(a: Allocator, text: []const u8, query: []const u8, out: *std.ArrayList(Match)) !bool {
    out.clearRetainingCapacity();
    if (query.len == 0) return false;
    var at: usize = 0;
    while (at + query.len <= text.len) {
        const rel = std.ascii.findIgnoreCase(text[at..], query) orelse return false;
        if (out.items.len == max_matches) return true;
        const start = at + rel;
        try out.append(a, .{ .start = @intCast(start), .end = @intCast(start + query.len) });
        at = start + query.len;
    }
    return false;
}

/// The first match ending after `pos`, as an index of `matches`.
pub fn firstAfter(matches: []const Match, pos: usize) usize {
    var lo: usize = 0;
    var hi: usize = matches.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (matches[mid].end <= pos) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const t = std.testing;

test "finds without regard to case, and doesn't overlap" {
    var m: std.ArrayList(Match) = .empty;
    defer m.deinit(t.allocator);
    try t.expect(!try findAll(t.allocator, "aXa xA aaa", "xa", &m));
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expectEqual(@as(u32, 1), m.items[0].start);
    try t.expect(!try findAll(t.allocator, "aaaa", "aa", &m));
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expect(!try findAll(t.allocator, "abc", "", &m));
    try t.expectEqual(@as(usize, 0), m.items.len);
    try t.expectEqual(@as(usize, 0), firstAfter(&.{}, 3));
}

test "the bound holds" {
    const text = try t.allocator.alloc(u8, max_matches + 50);
    defer t.allocator.free(text);
    @memset(text, 'a');
    var m: std.ArrayList(Match) = .empty;
    defer m.deinit(t.allocator);
    try t.expect(try findAll(t.allocator, text, "a", &m));
    try t.expectEqual(@as(usize, max_matches), m.items.len);
    try t.expectEqual(@as(usize, 3), firstAfter(m.items, 3));
}

test "options: case, whole words and regular expressions" {
    var m: std.ArrayList(Match) = .empty;
    defer m.deinit(t.allocator);
    var problem: regex.Problem = .{};
    try t.expect(!try findWith(t.allocator, "Cat cat concat", "cat", .{ .case_sensitive = true }, &m, &problem));
    try t.expectEqual(@as(usize, 2), m.items.len);
    _ = try findWith(t.allocator, "Cat cat concat cat_x", "cat", .{ .whole_word = true }, &m, &problem);
    try t.expectEqual(@as(usize, 2), m.items.len);
    try t.expectEqual(@as(u32, 4), m.items[1].start);
    _ = try findWith(t.allocator, "a1 b22 c333", "\\d+", .{ .regex = true }, &m, &problem);
    try t.expectEqual(@as(usize, 3), m.items.len);
    try t.expectEqual(@as(u32, 8), m.items[2].start);
    // Empty matches are skipped instead of looping.
    _ = try findWith(t.allocator, "abc", "x*", .{ .regex = true }, &m, &problem);
    try t.expectEqual(@as(usize, 0), m.items.len);
    try t.expectError(error.Syntax, findWith(t.allocator, "abc", "(a", .{ .regex = true }, &m, &problem));
    try t.expectEqualStrings("Unclosed group", problem.message);
    // Replace checks the selection and fills in groups.
    var f = try Finder.init(t.allocator, "(\\w+)=(\\w+)", .{ .regex = true }, &problem);
    defer f.deinit();
    const text = "a=1 bb=22";
    try t.expect(try f.exact(text, .{ .start = 4, .end = 9 }));
    try t.expect(!try f.exact(text, .{ .start = 4, .end = 8 }));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try t.expect(try f.exact(text, .{ .start = 4, .end = 9 }));
    try f.replacement(&out, text, "$2=$1");
    try t.expectEqualStrings("22=bb", out.items);
}
