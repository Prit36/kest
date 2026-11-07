//! Bounded literal display for received header bytes. Original bytes remain
//! owned by Response; clipboard text must not silently truncate at NUL or
//! replace invalid UTF-8. Such values have explicitly escaped copy actions.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Display = struct { text: []u8, truncated: bool, escaped: bool, source_bytes: usize = 0 };

pub fn clipboardSafe(source: []const u8) bool {
    return std.mem.indexOfScalar(u8, source, 0) == null and std.unicode.utf8ValidateSlice(source);
}

pub fn display(a: Allocator, source: []const u8, limit: usize) !Display {
    var end = @min(source.len, limit);
    // Do not turn a valid multi-byte character cut by the preview into escapes.
    if (end > 0 and end < source.len and source[end] & 0xc0 == 0x80) {
        var boundary = end;
        while (boundary > 0 and end - boundary < 3 and source[boundary] & 0xc0 == 0x80) boundary -= 1;
        const count = std.unicode.utf8ByteSequenceLength(source[boundary]) catch 0;
        if (count > 0 and boundary + count > end and boundary + count <= source.len and std.unicode.utf8ValidateSlice(source[boundary .. boundary + count])) end = boundary;
    }
    const prefix = source[0..end];
    var escape = !std.unicode.utf8ValidateSlice(prefix);
    for (prefix) |ch| if (ch < 0x20 or ch == 0x7f) {
        escape = true;
        break;
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < prefix.len) {
        const byte = prefix[i];
        const escaped: ?[]const u8 = if (escape) switch (byte) {
            '\t' => "\\t",
            '\r' => "\\r",
            '\n' => "\\n",
            '\\' => "\\\\",
            else => null,
        } else null;
        if (escaped) |text| {
            try out.appendSlice(a, text);
        } else if (byte < 0x20 or byte == 0x7f) {
            try hex(a, &out, byte);
        } else if (byte < 0x80) {
            try out.append(a, byte);
        } else {
            const count = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            if (count > 0 and prefix.len - i >= count and std.unicode.utf8ValidateSlice(prefix[i .. i + count])) {
                try out.appendSlice(a, prefix[i .. i + count]);
                i += count;
                continue;
            }
            try hex(a, &out, byte);
        }
        i += 1;
    }
    if (end < source.len) try out.appendSlice(a, "\u{2026}");
    return .{ .text = try out.toOwnedSlice(a), .truncated = end < source.len, .escaped = escape, .source_bytes = end };
}

fn hex(a: Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    const digits = "0123456789ABCDEF";
    try out.appendSlice(a, &.{ '\\', 'x', digits[byte >> 4], digits[byte & 15] });
}

/// Call only when clipboardSafe is false; normal values copy exactly, including
/// whitespace/backslashes. Escaped copies are always labeled as escaped in UI.
pub fn escapedCopy(a: Allocator, source: []const u8) ![]u8 {
    return (try display(a, source, source.len)).text;
}

pub fn clipboardText(a: Allocator, source: []const u8) ![:0]u8 {
    if (clipboardSafe(source)) return a.dupeSentinel(u8, source, 0);
    const escaped = try escapedCopy(a, source);
    defer a.free(escaped);
    return a.dupeSentinel(u8, escaped, 0);
}

fn copyAllocationExercise(a: Allocator, source: []const u8) !void {
    const result = try clipboardText(a, source);
    defer a.free(result);
    try std.testing.expect(clipboardSafe(result));
}

test "clipboard preparation releases temporary escaped bytes on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyAllocationExercise, .{"original\r\n"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyAllocationExercise, .{"a\x00b\xff"});
}

test "header previews are literal, bounded, UTF-8 aligned and byte-explicit" {
    const t = std.testing;
    for ([_]struct { []const u8, []const u8 }{
        .{ "value###literal", "value###literal" },
        .{ "C:\\path", "C:\\path" },
        .{ "a\x00b\xff\\x", "a\\x00b\\xFF\\\\x" },
        .{ " \tvalue\r\n", " \\tvalue\\r\\n" },
    }) |case| {
        const result = try display(t.allocator, case[0], 100);
        defer t.allocator.free(result.text);
        try t.expectEqualStrings(case[1], result.text);
        try t.expect(!result.truncated and clipboardSafe(result.text));
    }
    const clipped = try display(t.allocator, "a\xc3\xa9z", 2);
    defer t.allocator.free(clipped.text);
    try t.expectEqualStrings("a\u{2026}", clipped.text);
    try t.expect(clipped.truncated and !clipped.escaped);
    try t.expect(!clipboardSafe("a\x00b") and !clipboardSafe("\xff"));
    try t.expect(clipboardSafe("\tvalid\r\n") and clipboardSafe("\xc3\xa9"));
    const invalid_cut = try display(t.allocator, "\x80\x80\x80\x80\x80", 4);
    defer t.allocator.free(invalid_cut.text);
    try t.expectEqualStrings("\\x80\\x80\\x80\\x80\u{2026}", invalid_cut.text);
}
