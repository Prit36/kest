//! Wheel scrolling that eases toward where the wheel points instead of
//! jumping, the way CUI's own scroll areas move.
const c = @import("c.zig").c;

/// How long one wheel step takes to settle, as in CUI's scroll areas.
const duration = 0.14;

pub const Glide = struct {
    /// Where the view is heading; null when it isn't moving.
    target: ?f32 = null,

    /// Adds a wheel movement of `delta` pixels to where the view is heading.
    pub fn push(g: *Glide, current: f32, delta: f32) void {
        if (delta == 0) return;
        g.target = @max(0, (g.target orelse current) + delta);
    }

    /// Moves `pos` toward the target, at most `max`; stops once there.
    pub fn step(g: *Glide, ui: *c.cui_ctx, pos: *f32, max: f32) void {
        const goal = @min(@max(0, g.target orelse return), @max(0, max));
        g.target = goal;
        _ = c.kest_tween(ui, pos, goal, duration);
        if (@abs(pos.* - goal) < 0.5) {
            pos.* = goal;
            g.target = null;
        }
    }

    /// Something else moved the view: a drag, a reveal, a jump.
    pub fn stop(g: *Glide) void {
        g.target = null;
    }
};
