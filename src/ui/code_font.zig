//! The code font: the body editor, the response text and the JSON viewer.
//! Its size is a workspace preference; zooming (Ctrl+wheel, Ctrl+= and
//! Ctrl+-) changes it and Ctrl+0 puts it back. The shell sets `size` from
//! the preference at the start of each frame.
const std = @import("std");

pub const default: u8 = 13;
pub const min: u8 = 9;
pub const max: u8 = 24;

pub var size: f32 = default;

/// Ctrl+wheel steps the views took this frame, for the shell to apply:
/// the views don't hold the preferences. Trackpads send fractions.
pub var wheel: f32 = 0;

/// Takes a Ctrl+wheel movement over a code view. Returns whether it was
/// one, so the view doesn't also scroll.
pub fn ctrlWheel(ctrl: bool, dy: f32) bool {
    if (!ctrl or dy == 0) return false;
    wheel += dy;
    return true;
}

/// Whole zoom steps the wheel has made, leaving the remainder.
pub fn takeWheel() i32 {
    const steps: i32 = @intFromFloat(std.math.trunc(wheel));
    wheel -= @floatFromInt(steps);
    return steps;
}

/// A row of code: 20 px at the default size.
pub fn line() f32 {
    return @round(size * 20.0 / 13.0);
}

/// Line numbers and other small code text: 12 px at the default size.
pub fn small() f32 {
    return @round(size * 12.0 / 13.0);
}

/// The caret's height inside a row.
pub fn caret() f32 {
    return line() - 3;
}

/// The size after zooming `steps` steps in (or out, when negative).
pub fn zoomed(current: u8, steps: i32) u8 {
    const next = @as(i32, current) + steps;
    return @intCast(std.math.clamp(next, min, max));
}

test "zoom stays in range and rows grow with the font" {
    try std.testing.expectEqual(@as(u8, 14), zoomed(13, 1));
    try std.testing.expectEqual(max, zoomed(max, 3));
    try std.testing.expectEqual(min, zoomed(10, -5));
    const saved = size;
    defer size = saved;
    size = 13;
    try std.testing.expectEqual(@as(f32, 20), line());
    try std.testing.expectEqual(@as(f32, 12), small());
    size = 18;
    try std.testing.expectEqual(@as(f32, 28), line());
}
