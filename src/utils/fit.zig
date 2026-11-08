//! Releasing growth slack from lists that are final.
//!
//! An ArrayList grows by half again each time, so a list built by appending
//! holds up to a third more than it uses. `shrinkAndFree` does not help with
//! the C allocator the app runs on: it treats every shrink as done in place
//! and keeps the whole block. `list` moves its items into an allocation of
//! their exact size instead, when the slack is worth a copy. Meant for large
//! results built once on a worker (a response body, its index, its tree).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Below this much slack a copy is not worth it.
const min_slack = 64 * 1024;

pub fn list(comptime T: type, a: Allocator, items: *std.ArrayList(T)) void {
    const slack = (items.capacity - items.items.len) * @sizeOf(T);
    if (slack < min_slack) return;
    if (items.items.len == 0) {
        items.clearAndFree(a);
        return;
    }
    // On failure the list simply keeps its capacity.
    const exact = a.dupe(T, items.items) catch return;
    items.deinit(a);
    items.* = .fromOwnedSlice(exact);
}

test "list keeps items and drops slack" {
    const a = std.testing.allocator;
    var l: std.ArrayList(u32) = .empty;
    defer l.deinit(a);
    for (0..100_000) |i| try l.append(a, @intCast(i));
    try std.testing.expect(l.capacity > l.items.len);
    list(u32, a, &l);
    try std.testing.expectEqual(l.items.len, l.capacity);
    try std.testing.expectEqual(@as(u32, 99_999), l.items[l.items.len - 1]);
    // Small slack is left alone.
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(a);
    try small.appendSlice(a, "abc");
    const before = small.capacity;
    list(u8, a, &small);
    try std.testing.expectEqual(before, small.capacity);
}
