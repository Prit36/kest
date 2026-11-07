//! Compact, consistent response measurements with explicit IEC byte units.
const std = @import("std");
pub fn duration(buf: *[48]u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d} ms", .{ms}) catch "";
    if (ms < 60000) return std.fmt.bufPrint(buf, "{d}.{d:0>2} s", .{ ms / 1000, ms % 1000 / 10 }) catch "";
    return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ ms / 60000, ms / 1000 % 60 }) catch "";
}
pub fn bytes(buf: *[48]u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    const labels = [_][]const u8{ "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var value: f64 = @as(f64, @floatFromInt(n)) / 1024;
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < labels.len) : (unit += 1) value /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, labels[unit] }) catch "";
}
test "response durations and byte units retain real zero measurements" {
    const t = std.testing;
    var buf: [48]u8 = undefined;
    try t.expectEqualStrings("0 ms", duration(&buf, 0));
    try t.expectEqualStrings("999 ms", duration(&buf, 999));
    try t.expectEqualStrings("1.23 s", duration(&buf, 1234));
    try t.expectEqualStrings("1m 01s", duration(&buf, 61000));
    try t.expectEqualStrings("0 B", bytes(&buf, 0));
    try t.expectEqualStrings("1.0 KiB", bytes(&buf, 1024));
    try t.expectEqualStrings("1.0 GiB", bytes(&buf, 1024 * 1024 * 1024));
}
