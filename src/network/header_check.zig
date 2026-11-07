//! What may go on a request line or in a header: nothing that could start a
//! new line of its own.
const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };

const separators = "\"(),/:;<=>?@[\\]{}";

pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

/// Headers that don't follow a redirect to another host.
pub fn isSensitive(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or std.ascii.eqlIgnoreCase(name, "cookie") or std.ascii.eqlIgnoreCase(name, "proxy-authorization");
}

/// Whether `name` is a token and `value` can't start a new header line.
pub fn validHeader(name: []const u8, value: []const u8) bool {
    if (!validMethod(name)) return false;
    for (value) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

pub fn validMethod(m: []const u8) bool {
    if (m.len == 0) return false;
    for (m) |c| if (c <= 0x20 or c >= 0x7f or std.mem.indexOfScalar(u8, separators, c) != null) return false;
    return true;
}

test "header and method checks refuse what could inject a line" {
    try std.testing.expect(validHeader("X-A", "b c"));
    try std.testing.expect(!validHeader("X-A", "b\r\nEvil: 1"));
    try std.testing.expect(!validHeader("X A", "b"));
    try std.testing.expect(!validHeader("", "b"));
    try std.testing.expect(validMethod("PURGE"));
    try std.testing.expect(!validMethod("GET /x HTTP/1.1\r\n"));
}
