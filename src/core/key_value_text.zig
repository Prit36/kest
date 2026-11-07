//! Human-editable key/value lines. Quote ambiguous strings with JSON syntax;
//! `# ` disables a row and `@file ` preserves a multipart file field.
const std = @import("std");
const KeyValue = @import("request.zig").KeyValue;
const Allocator = std.mem.Allocator;
pub const max_rows = 4096;
pub const Problem = struct { line: usize = 0, message: []const u8 = "" };

fn token(a: Allocator, out: *std.ArrayList(u8), value: []const u8, key: bool) !void {
    const control = for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) break true;
    } else false;
    const quote = value.len == 0 or value[0] == '"' or
        (key and (value[0] == '#' or std.mem.startsWith(u8, value, "@file ") or std.mem.indexOfAny(u8, value, ":=") != null)) or
        !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n")) or control;
    if (!quote) return out.appendSlice(a, value);
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    var stringify: std.json.Stringify = .{ .writer = &encoded.writer };
    stringify.write(value) catch return error.OutOfMemory;
    try out.appendSlice(a, encoded.written());
}

pub fn write(a: Allocator, rows: []const KeyValue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (rows) |r| {
        if (r.key.len == 0 and r.value.len == 0 and !r.has_equals) continue;
        if (!r.enabled) try out.appendSlice(a, "# ");
        if (r.is_file) try out.appendSlice(a, "@file ");
        try token(a, &out, r.key, true);
        // A bare key retains ?flag, while `key: ""` retains ?key=.
        if (r.value.len > 0 or r.has_equals) {
            try out.appendSlice(a, ": ");
            try token(a, &out, r.value, false);
        }
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn quotedEnd(s: []const u8) ?usize {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '"') return i + 1;
    }
    return null;
}

/// Strings are owned by the caller's arena, including error-path allocations.
pub fn parse(a: Allocator, text: []const u8, problem: *Problem) ![]KeyValue {
    problem.* = .{};
    var out: std.ArrayList(KeyValue) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 0;
    while (lines.next()) |raw| {
        line += 1;
        var s = std.mem.trim(u8, raw, " \t\r");
        if (s.len == 0) continue;
        if (out.items.len == max_rows) {
            problem.* = .{ .line = line, .message = "Too many rows (4096 maximum)" };
            return error.TooManyRows;
        }
        var row: KeyValue = .{};
        if (s[0] == '#') {
            row.enabled = false;
            s = std.mem.trimStart(u8, s[1..], " \t");
        }
        if (std.mem.startsWith(u8, s, "@file ")) {
            row.is_file = true;
            s = std.mem.trimStart(u8, s[6..], " \t");
        }
        if (s.len == 0) continue;
        problem.* = .{ .line = line, .message = "Invalid quoted key or value" };
        if (s[0] == '"') {
            const end = quotedEnd(s) orelse return error.InvalidLine;
            row.key = std.json.parseFromSliceLeaky([]const u8, a, s[0..end], .{ .allocate = .alloc_always }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidLine,
            };
            s = std.mem.trimStart(u8, s[end..], " \t");
            if (s.len > 0 and s[0] != ':' and s[0] != '=') return error.InvalidLine;
        } else {
            const end = std.mem.indexOfAny(u8, s, ":=") orelse s.len;
            row.key = try a.dupe(u8, std.mem.trim(u8, s[0..end], " \t"));
            s = s[end..];
        }
        row.has_equals = s.len > 0;
        if (s.len > 0) {
            s = std.mem.trim(u8, s[1..], " \t");
            row.value = if (s.len > 0 and s[0] == '"') std.json.parseFromSliceLeaky([]const u8, a, s, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidLine,
            } else try a.dupe(u8, s);
        }
        if (std.mem.indexOfScalar(u8, row.key, 0) != null or std.mem.indexOfScalar(u8, row.value, 0) != null) {
            problem.message = "Null bytes aren't supported in editable rows";
            return error.InvalidLine;
        }
        try out.append(a, row);
    }
    problem.* = .{};
    return out.items;
}

test "bulk lines preserve ambiguous strings, disabled/file flags and empty query values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_]KeyValue{
        .{ .key = "Accept", .value = "application/json" },
        .{ .key = "#active", .value = " literal whitespace " },
        .{ .key = "a=b:c", .value = "line one\nline two\r\n\"quoted\"" },
        .{ .key = "@file literal", .value = "{{token}}", .enabled = false },
        .{ .key = "upload", .value = "C:\\a b\\file.txt", .is_file = true },
        .{ .key = "flag" },
        .{ .key = "empty", .has_equals = true },
        .{ .has_equals = true },
        .{ .key = "", .value = "value only" },
        .{ .key = "dup", .value = "one" },
        .{ .key = "dup", .value = "two" },
        .{ .key = "café", .value = "☕" },
        .{ .key = "control", .value = "a\tb\x01c" },
    };
    const encoded = try write(a, &rows);
    var problem: Problem = .{};
    const decoded = try parse(a, encoded, &problem);
    try std.testing.expectEqual(rows.len, decoded.len);
    for (rows, decoded) |before, after| {
        try std.testing.expectEqualStrings(before.key, after.key);
        try std.testing.expectEqualStrings(before.value, after.value);
        try std.testing.expectEqual(before.enabled, after.enabled);
        try std.testing.expectEqual(before.is_file, after.is_file);
        if (before.value.len == 0) try std.testing.expectEqual(before.has_equals, after.has_equals);
    }
    const plain = try parse(a, "Content-Type: application/json\r\n# Off=value\nflag\nempty=\n", &problem);
    try std.testing.expectEqualStrings("application/json", plain[0].value);
    try std.testing.expect(!plain[1].enabled and !plain[2].has_equals and plain[3].has_equals);
}

test "bulk syntax errors name the line and row limit is explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: Problem = .{};
    try std.testing.expectError(error.InvalidLine, parse(a, "Good: kept\nBad: \"unterminated", &problem));
    try std.testing.expectEqual(@as(usize, 2), problem.line);
    try std.testing.expectError(error.InvalidLine, parse(a, "\"key\" trailing: bad", &problem));
    try std.testing.expectError(error.InvalidLine, parse(a, "\"bad\\q\": value", &problem));
    try std.testing.expectError(error.InvalidLine, parse(a, "key: \"\\u0000\"", &problem));
    var many: std.ArrayList(u8) = .empty;
    for (0..max_rows + 1) |_| try many.appendSlice(a, "key: value\n");
    try std.testing.expectError(error.TooManyRows, parse(a, many.items, &problem));
    try std.testing.expectEqual(max_rows + 1, problem.line);
}
