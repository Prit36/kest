//! Literal response search. KMP bounds repeated-prefix queries to linear work.
//! Checkpointed automaton state lets visible highlighting resume with the same
//! non-overlap semantics, without rescanning a multi-megabyte line's prefix.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Match = @import("../utils/search.zig").Match;
pub const max_query = 4096;
pub const page_size = 10_000;
pub const checkpoint_bytes = 256;
pub const max_input = 16 * 1024 * 1024;
pub const Error = error{ OutOfMemory, QueryLimit, InputLimit, Canceled };
pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,

    /// Whole words and regular expressions keep a list of every match
    /// instead of the literal automaton's checkpoints.
    fn listed(o: Options) bool {
        return o.whole_word or o.regex;
    }
};
/// A listed search keeps at most this many matches.
pub const max_listed = 1_000_000;
const search = @import("../utils/search.zig");
pub const Seek = union(enum) { near: usize, ordinal: u32 };

pub const Index = struct {
    query: []u8,
    prefix: []u32,
    states: std.ArrayList(u32) = .empty,
    options: Options,
    total: u32 = 0,
    source_len: usize,
    /// Every match, in a whole-word or regex search.
    all: std.ArrayList(Match) = .empty,
    /// The list stopped at max_listed.
    capped: bool = false,

    pub fn deinit(index: *Index, a: Allocator) void {
        a.free(index.query);
        a.free(index.prefix);
        index.states.deinit(a);
        index.all.deinit(a);
    }
    fn fold(index: *const Index, byte: u8) u8 {
        return if (index.options.case_sensitive) byte else std.ascii.toLower(byte);
    }
    fn step(index: *const Index, state: *usize, byte: u8) bool {
        const value = index.fold(byte);
        while (state.* > 0 and index.query[state.*] != value) state.* = index.prefix[state.* - 1];
        if (index.query[state.*] == value) state.* += 1;
        if (state.* != index.query.len) return false;
        state.* = 0; // same non-overlapping literal semantics as the body editor
        return true;
    }

    /// Only scans the visible range plus at most one checkpoint and one query.
    /// Returned ranges use full-source byte offsets and can cross line breaks.
    /// true means the caller's fixed highlight buffer filled.
    pub fn visible(index: *const Index, source: []const u8, start_in: usize, end_in: usize, out: []Match, count: *usize) bool {
        count.* = 0;
        if (source.len != index.source_len or index.query.len == 0 or index.total == 0 or start_in >= end_in or start_in >= source.len) return false;
        if (index.options.listed()) {
            var at = search.firstAfter(index.all.items, start_in);
            while (at < index.all.items.len and index.all.items[at].start < end_in) : (at += 1) {
                if (count.* == out.len) return true;
                out[count.*] = index.all.items[at];
                count.* += 1;
            }
            return false;
        }
        const start = start_in;
        const end = @min(end_in, source.len);
        const cp = start / checkpoint_bytes;
        var state: usize = index.states.items[cp];
        var at = cp * checkpoint_bytes;
        const stop = @min(source.len, end + index.query.len - 1);
        while (at < stop) : (at += 1) if (index.step(&state, source[at])) {
            const match: Match = .{ .start = @intCast(at + 1 - index.query.len), .end = @intCast(at + 1) };
            if (match.end <= start or match.start >= end) continue;
            if (count.* == out.len) return true;
            out[count.*] = match;
            count.* += 1;
        };
        return false;
    }
};

pub const Result = struct {
    index: Index,
    matches: std.ArrayList(Match) = .empty,
    page_start: u32 = 0,
    selected: u32 = 0,

    pub fn deinit(result: *Result, a: Allocator) void {
        result.index.deinit(a);
        result.matches.deinit(a);
    }
};

fn canceled(flag: ?*const std.atomic.Value(bool)) Error!void {
    if (flag) |value| if (value.load(.acquire)) return error.Canceled;
}

pub fn build(a: Allocator, source: []const u8, query: []const u8, options: Options, seek: Seek, cancel: ?*const std.atomic.Value(bool)) Error!Result {
    if (source.len > max_input) return error.InputLimit;
    if (query.len > max_query) return error.QueryLimit;
    try canceled(cancel);
    const owned_query = try a.dupe(u8, query);
    errdefer a.free(owned_query);
    const prefix = try a.alloc(u32, query.len);
    var result: Result = .{ .index = .{ .query = owned_query, .prefix = prefix, .options = options, .source_len = source.len } };
    // Query ownership is now in result (the query errdefer above only applies
    // until prefix allocation; avoid double cleanup by keeping the rest nested).
    return finish(a, source, &result, seek, cancel) catch |err| {
        a.free(prefix);
        result.index.states.deinit(a);
        result.matches.deinit(a);
        return err;
    };
}

fn finish(a: Allocator, source: []const u8, result: *Result, seek: Seek, cancel: ?*const std.atomic.Value(bool)) Error!Result {
    const index = &result.index;
    if (index.options.listed()) return finishListed(a, source, result, seek, cancel);
    if (!index.options.case_sensitive) for (index.query) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
    };
    if (index.query.len == 0) return result.*;
    index.prefix[0] = 0;
    var matched: usize = 0;
    for (1..index.query.len) |i| {
        while (matched > 0 and index.query[i] != index.query[matched]) matched = index.prefix[matched - 1];
        if (index.query[i] == index.query[matched]) matched += 1;
        index.prefix[i] = @intCast(matched);
    }
    try index.states.ensureTotalCapacity(a, source.len / checkpoint_bytes + 1);
    index.states.appendAssumeCapacity(0);
    var state: usize = 0;
    var selected: ?u32 = switch (seek) {
        .ordinal => |ordinal| ordinal,
        .near => null,
    };
    var wanted_page: ?u32 = if (selected) |value| value / page_size * page_size else null;
    for (source, 0..) |byte, at| {
        if (at % checkpoint_bytes == 0) try canceled(cancel);
        if (index.step(&state, byte)) {
            const match: Match = .{ .start = @intCast(at + 1 - index.query.len), .end = @intCast(at + 1) };
            if (selected == null and match.end > seek.near) {
                selected = index.total;
                wanted_page = index.total / page_size * page_size;
            }
            const page = index.total / page_size * page_size;
            if (wanted_page == null or wanted_page.? == page) {
                if (page != result.page_start) {
                    result.matches.clearRetainingCapacity();
                    result.page_start = page;
                }
                try result.matches.append(a, match);
            }
            index.total += 1;
        }
        if ((at + 1) % checkpoint_bytes == 0) index.states.appendAssumeCapacity(@intCast(state));
    }
    if (index.total == 0) return result.*;
    if (selected == null or selected.? >= index.total) {
        // Past the final match wraps to the beginning. Reuse the same bounded
        // buffer; the full automaton index and count do not need rebuilding.
        result.matches.clearRetainingCapacity();
        result.page_start = 0;
        selected = 0;
        state = 0;
        for (source, 0..) |byte, at| {
            if (at % checkpoint_bytes == 0) try canceled(cancel);
            if (index.step(&state, byte)) {
                try result.matches.append(a, .{ .start = @intCast(at + 1 - index.query.len), .end = @intCast(at + 1) });
                if (result.matches.items.len == page_size) break;
            }
        }
    }
    result.selected = selected.?;
    return result.*;
}

/// A whole-word or regex search: every match listed once, then the page
/// around the one to select.
fn finishListed(a: Allocator, source: []const u8, result: *Result, seek: Seek, cancel: ?*const std.atomic.Value(bool)) Error!Result {
    const index = &result.index;
    if (index.query.len == 0) return result.*;
    var problem: @import("../utils/regex.zig").Problem = .{};
    var finder = search.Finder.init(a, index.query, .{ .case_sensitive = index.options.case_sensitive, .whole_word = index.options.whole_word, .regex = index.options.regex }, &problem) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.QueryLimit,
    };
    defer finder.deinit();
    finder.cancel = cancel;
    var at: usize = 0;
    while (finder.next(source, at) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.QueryLimit,
    }) |m| {
        if (index.all.items.len == max_listed) {
            index.capped = true;
            break;
        }
        try index.all.append(a, m);
        at = m.end;
    }
    index.total = @intCast(index.all.items.len);
    if (index.total == 0) return result.*;
    const selected: u32 = switch (seek) {
        .ordinal => |ordinal| @min(ordinal, index.total - 1),
        .near => |near| blk: {
            const i = search.firstAfter(index.all.items, near);
            break :blk if (i < index.total) @intCast(i) else 0;
        },
    };
    result.page_start = selected / page_size * page_size;
    const page_end = @min(index.total, result.page_start + page_size);
    try result.matches.appendSlice(a, index.all.items[result.page_start..page_end]);
    result.selected = selected;
    return result.*;
}

test "whole words and regular expressions list their matches" {
    const t = std.testing;
    const source = "cat concat cat_x Cat\nid: 12, id: 345";
    var words = try build(t.allocator, source, "cat", .{ .whole_word = true }, .{ .near = 5 }, null);
    defer words.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), words.index.total);
    try t.expectEqual(@as(u32, 1), words.selected);
    try t.expectEqual(@as(u32, 17), words.matches.items[1].start);
    var re = try build(t.allocator, source, "id: (\\d+)", .{ .regex = true }, .{ .near = 0 }, null);
    defer re.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), re.index.total);
    var hits: [4]Match = undefined;
    var count: usize = 0;
    try t.expect(!re.index.visible(source, 30, source.len, &hits, &count));
    try t.expect(count == 1 and hits[0].end == source.len);
    try t.expectError(error.QueryLimit, build(t.allocator, source, "(", .{ .regex = true }, .{ .near = 0 }, null));
}

test "literal case, UTF-8, newline, overlap phase and near-caret wrap" {
    const t = std.testing;
    var result = try build(t.allocator, "aAaA\r\ncaf\xc3\xa9 CAF\xc3\xa9", "aa", .{}, .{ .near = 1 }, null);
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), result.index.total);
    var hits: [8]Match = undefined;
    var count: usize = 0;
    try t.expect(!result.index.visible("aAaA\r\ncaf\xc3\xa9 CAF\xc3\xa9", 1, 4, &hits, &count));
    try t.expectEqual(@as(usize, 2), count);
    try t.expectEqual(@as(u32, 0), hits[0].start);
    try t.expectEqual(@as(u32, 2), hits[1].start);
    var utf = try build(t.allocator, "caf\xc3\xa9 CAF\xc3\xa9", "caf\xc3\xa9", .{}, .{ .near = 999 }, null);
    defer utf.deinit(t.allocator);
    try t.expect(utf.index.total == 2 and utf.selected == 0);
    var sensitive = try build(t.allocator, "aa AA", "AA", .{ .case_sensitive = true }, .{ .near = 0 }, null);
    defer sensitive.deinit(t.allocator);
    try t.expect(sensitive.index.total == 1 and sensitive.matches.items[0].start == 3);
    var across = try build(t.allocator, "a\r\nb\r\na", "\r\nb", .{}, .{ .near = 0 }, null);
    defer across.deinit(t.allocator);
    try t.expect(across.index.total == 1 and across.matches.items[0].start == 1);
}

test "all matches remain navigable beyond a bounded cache and highlight checkpoints" {
    const t = std.testing;
    const source = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    defer t.allocator.free(source);
    @memset(source, 'a');
    var result = try build(t.allocator, source, "aaa", .{}, .{ .near = 3_000_001 }, null);
    defer result.deinit(t.allocator);
    try t.expect(result.index.total == source.len / 3 and result.selected == 1_000_000);
    try t.expect(result.page_start == 1_000_000 and result.matches.items.len == page_size);
    var hits: [8]Match = undefined;
    var count: usize = 0;
    try t.expect(!result.index.visible(source, 3_500_002, 3_500_014, &hits, &count));
    try t.expect(count >= 4);
    for (hits[0..count]) |match| try t.expect(match.start % 3 == 0 and match.end - match.start == 3);
    var last = try build(t.allocator, source, "aaa", .{}, .{ .ordinal = result.index.total - 1 }, null);
    defer last.deinit(t.allocator);
    try t.expect(last.selected == result.index.total - 1 and last.matches.items.len <= page_size);
    var bounded: [1]Match = undefined;
    try t.expect(last.index.visible(source, 1, 100, &bounded, &count));
}

fn allocationExercise(a: Allocator) !void {
    var result = try build(a, "aAaA aaaa", "aa", .{}, .{ .near = 100 }, null);
    defer result.deinit(a);
}
test "allocation failures, cancellation and limits are explicit" {
    const t = std.testing;
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
    var cancel: std.atomic.Value(bool) = .init(true);
    try t.expectError(error.Canceled, build(t.allocator, "abc", "b", .{}, .{ .near = 0 }, &cancel));
    var query: [max_query + 1]u8 = @splat('a');
    try t.expectError(error.QueryLimit, build(t.allocator, "abc", &query, .{}, .{ .near = 0 }, null));
    var empty = try build(t.allocator, "abc", "", .{}, .{ .near = 0 }, null);
    defer empty.deinit(t.allocator);
    try t.expect(empty.index.total == 0 and empty.matches.items.len == 0);
}

test "adversarial repeated prefixes and the maximum literal query remain linear" {
    const t = std.testing;
    const source = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    defer t.allocator.free(source);
    @memset(source, 'a');
    source[source.len - 1] = 'b';
    var query: [max_query]u8 = @splat('a');
    query[query.len - 1] = 'b';
    var result = try build(t.allocator, source, &query, .{}, .{ .near = 0 }, null);
    defer result.deinit(t.allocator);
    try t.expect(result.index.total == 1 and result.matches.items[0].end == source.len and result.matches.items[0].start == source.len - max_query);
    var matches: [1]Match = undefined;
    var count: usize = 0;
    try t.expect(!result.index.visible(source, source.len - 100, source.len, &matches, &count));
    try t.expect(count == 1 and matches[0].start == source.len - max_query);
    try t.expectEqual(source.len / checkpoint_bytes + 1, result.index.states.items.len);
}
