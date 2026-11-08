//! What to suggest while typing: `{{variable}}` names, common header names and
//! values, and URLs sent before. No UI here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Var = @import("environment.zig").Var;

pub const Item = struct {
    /// Shown in the list.
    label: []const u8,
    /// Put in place of `start..end` when accepted.
    insert: []const u8,
    /// A muted second column: a variable's value.
    detail: []const u8 = "",
};

/// A suggestion list for the text around the caret.
pub const Proposal = struct {
    start: usize,
    end: usize,
    items: []Item,
    /// Where the caret lands, counted from `start`, when an item is taken:
    /// past a `}}` that was already there.
    skip_after: usize = 0,
};

pub const max_items = 8;

pub fn isNameChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.' or b == '$';
}

pub const Token = struct { start: usize, end: usize, prefix: []const u8, closed: bool };

/// The `{{name` the caret is in: the name from `start` to `end`.
pub fn variableAt(text: []const u8, caret: usize) ?Token {
    if (caret > text.len) return null;
    var i = caret;
    while (i > 0 and isNameChar(text[i - 1])) i -= 1;
    if (i < 2 or text[i - 1] != '{' or text[i - 2] != '{') return null;
    var e = caret;
    while (e < text.len and isNameChar(text[e])) e += 1;
    return .{ .start = i, .end = e, .prefix = text[i..caret], .closed = std.mem.startsWith(u8, text[e..], "}}") };
}

/// How well `label` matches what was typed: 0 starts with it exactly, 1
/// starts with it in any case, 2 contains it; null not at all.
pub fn rank(label: []const u8, query: []const u8) ?u8 {
    if (query.len == 0) return 1;
    if (std.mem.startsWith(u8, label, query)) return 0;
    if (label.len >= query.len and std.ascii.eqlIgnoreCase(label[0..query.len], query)) return 1;
    if (std.ascii.findIgnoreCase(label, query) != null) return 2;
    return null;
}

const Ranked = struct { item: Item, rank: u8, order: usize };
fn better(_: void, x: Ranked, y: Ranked) bool {
    return x.rank < y.rank or (x.rank == y.rank and x.order < y.order);
}

fn finish(a: Allocator, ranked: []Ranked) ![]Item {
    std.mem.sort(Ranked, ranked, {}, better);
    const n = @min(ranked.len, max_items);
    const out = try a.alloc(Item, n);
    for (out, ranked[0..n]) |*o, r| o.* = r.item;
    return out;
}

/// The enabled variables matching `prefix`, each name once (the last row wins).
pub fn variables(a: Allocator, vars: []const Var, prefix: []const u8, closed: bool) ![]Item {
    var ranked: std.ArrayList(Ranked) = .empty;
    var i = vars.len;
    outer: while (i > 0) {
        i -= 1;
        const v = vars[i];
        if (!v.enabled or v.key.len == 0) continue;
        for (ranked.items) |r| if (std.mem.eql(u8, r.item.label, v.key)) continue :outer;
        const score = rank(v.key, prefix) orelse continue;
        const insert = if (closed) v.key else try std.mem.concat(a, u8, &.{ v.key, "}}" });
        try ranked.append(a, .{ .item = .{ .label = v.key, .insert = insert, .detail = v.value }, .rank = score, .order = i });
    }
    // Typed in full already, with nothing longer: nothing to suggest.
    if (ranked.items.len == 1 and std.mem.eql(u8, ranked.items[0].item.label, prefix) and closed) return &.{};
    return finish(a, ranked.items);
}

/// Fixed choices matching the whole of `query`, leaving out an exact match.
pub fn choices(a: Allocator, list: []const []const u8, query: []const u8) ![]Item {
    var ranked: std.ArrayList(Ranked) = .empty;
    for (list, 0..) |choice, i| {
        if (std.ascii.eqlIgnoreCase(choice, query)) continue;
        const score = rank(choice, query) orelse continue;
        try ranked.append(a, .{ .item = .{ .label = choice, .insert = choice }, .rank = score, .order = i });
    }
    return finish(a, ranked.items);
}

/// URLs sent before (`urls` oldest first) containing `query`, newest first.
pub fn history(a: Allocator, urls: []const []const u8, query: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    var i = urls.len;
    outer: while (i > 0 and out.items.len < max_items) {
        i -= 1;
        const url = urls[i];
        if (url.len == 0 or std.mem.eql(u8, url, query)) continue;
        if (query.len > 0 and std.ascii.findIgnoreCase(url, query) == null) continue;
        for (out.items) |seen| if (std.mem.eql(u8, seen.label, url)) continue :outer;
        try out.append(a, .{ .label = url, .insert = url });
    }
    return out.items;
}

pub const header_names = [_][]const u8{
    "Accept",              "Accept-Encoding",  "Accept-Language", "Authorization",
    "Cache-Control",       "Connection",       "Content-Encoding", "Content-Type",
    "Cookie",              "Idempotency-Key",  "If-Match",        "If-Modified-Since",
    "If-None-Match",       "Origin",           "Pragma",          "Range",
    "Referer",             "User-Agent",       "X-API-Key",       "X-Correlation-ID",
    "X-Forwarded-For",     "X-Request-ID",     "X-Requested-With",
};

/// Common values for a header, by name in any case.
pub fn headerValues(name: []const u8) []const []const u8 {
    const Values = struct { name: []const u8, values: []const []const u8 };
    const table = [_]Values{
        .{ .name = "Accept", .values = &.{ "application/json", "*/*", "text/plain", "text/html", "application/xml" } },
        .{ .name = "Accept-Encoding", .values = &.{ "gzip, deflate, br", "gzip", "identity" } },
        .{ .name = "Accept-Language", .values = &.{ "en-US,en;q=0.9", "en" } },
        .{ .name = "Authorization", .values = &.{ "Bearer ", "Basic " } },
        .{ .name = "Cache-Control", .values = &.{ "no-cache", "no-store", "max-age=0" } },
        .{ .name = "Connection", .values = &.{ "keep-alive", "close" } },
        .{ .name = "Content-Encoding", .values = &.{ "gzip", "deflate", "br" } },
        .{ .name = "Content-Type", .values = &.{ "application/json", "application/x-www-form-urlencoded", "multipart/form-data", "text/plain", "application/xml", "application/octet-stream" } },
        .{ .name = "Pragma", .values = &.{"no-cache"} },
        .{ .name = "X-Requested-With", .values = &.{"XMLHttpRequest"} },
    };
    for (table) |entry| if (std.ascii.eqlIgnoreCase(entry.name, std.mem.trim(u8, name, " \t"))) return entry.values;
    return &.{};
}

/// What to suggest in a field, given where the caret is. Inside `{{`, the
/// variables; otherwise `fallback` (fixed choices or past URLs) for the
/// whole text when the caret is at its end.
pub const Fallback = union(enum) {
    none,
    choices: []const []const u8,
    urls: []const []const u8,
};

pub fn propose(a: Allocator, text: []const u8, caret: usize, vars: []const Var, fallback: Fallback) !?Proposal {
    if (variableAt(text, caret)) |token| {
        const items = try variables(a, vars, token.prefix, token.closed);
        if (items.len == 0) return null;
        return .{ .start = token.start, .end = token.end, .items = items, .skip_after = if (token.closed) 2 else 0 };
    }
    if (caret != text.len) return null;
    const items = switch (fallback) {
        .none => return null,
        .choices => |list| try choices(a, list, text),
        .urls => |urls| if (text.len == 0) return null else try history(a, urls, text),
    };
    if (items.len == 0) return null;
    return .{ .start = 0, .end = text.len, .items = items };
}

/// `text` with the item taken, and where the caret goes.
pub fn accept(a: Allocator, text: []const u8, p: Proposal, item: Item) !struct { text: []u8, caret: usize } {
    const out = try std.mem.concat(a, u8, &.{ text[0..p.start], item.insert, text[p.end..] });
    return .{ .text = out, .caret = p.start + item.insert.len + p.skip_after };
}

test "variable completion" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vars = [_]Var{
        .{ .key = "base_url", .value = "http://h" },
        .{ .key = "token", .value = "abc" },
        .{ .key = "off", .value = "x", .enabled = false },
        .{ .key = "api_base", .value = "v1" },
        .{ .key = "token", .value = "later" },
    };
    try t.expect(variableAt("{{to", 4).?.start == 2);
    try t.expect(variableAt("x {to", 5) == null);
    try t.expect(variableAt("{{a}} b", 7) == null);
    const tok = variableAt("{{tok}}/x", 3).?;
    try t.expect(tok.closed and tok.end == 5);
    // Typing the start of a name: matches by start first, then contained.
    const p = (try propose(a, "{{ba", 4, &vars, .none)).?;
    try t.expectEqual(@as(usize, 2), p.items.len);
    try t.expectEqualStrings("base_url", p.items[0].label);
    try t.expectEqualStrings("api_base", p.items[1].label);
    const done = try accept(a, "{{ba", p, p.items[0]);
    try t.expectEqualStrings("{{base_url}}", done.text);
    try t.expectEqual(@as(usize, 12), done.caret);
    // Inside a closed reference, only the name is replaced and the caret goes past.
    const q = (try propose(a, "{{to}}/x", 4, &vars, .none)).?;
    try t.expectEqual(@as(usize, 1), q.items.len);
    try t.expectEqualStrings("later", q.items[0].detail);
    const taken = try accept(a, "{{to}}/x", q, q.items[0]);
    try t.expectEqualStrings("{{token}}/x", taken.text);
    try t.expectEqual(@as(usize, 9), taken.caret);
    // Just "{{": everything enabled, once each.
    try t.expectEqual(@as(usize, 3), (try propose(a, "{{", 2, &vars, .none)).?.items.len);
    try t.expect(try propose(a, "{{zz", 4, &vars, .none) == null);
}

test "header and history completion" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = (try propose(a, "cont", 4, &.{}, .{ .choices = &header_names })).?;
    try t.expectEqualStrings("Content-Encoding", names.items[0].label);
    try t.expectEqualStrings("Content-Type", names.items[1].label);
    try t.expect(try propose(a, "Content-Type", 12, &.{}, .{ .choices = &.{"Content-Type"} }) == null);
    try t.expect(try propose(a, "cont", 2, &.{}, .{ .choices = &header_names }) == null);
    try t.expectEqualStrings("application/json", headerValues("content-type")[0]);
    try t.expectEqual(@as(usize, 0), headerValues("X-Nope").len);
    const urls = [_][]const u8{ "http://a/one", "http://b/two", "http://a/one", "http://a/three" };
    const h = (try propose(a, "a/", 2, &.{}, .{ .urls = &urls })).?;
    try t.expectEqual(@as(usize, 2), h.items.len);
    try t.expectEqualStrings("http://a/three", h.items[0].label);
    try t.expectEqualStrings("http://a/one", h.items[1].label);
    try t.expect(try propose(a, "", 0, &.{}, .{ .urls = &urls }) == null);
}
