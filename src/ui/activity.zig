//! CUI's searchable log consumes only the engine's already-redacted events.
const std = @import("std");
const c = @import("c.zig").c;
const log = @import("../core/log.zig");

pub const Activity = struct {
    buffer: c.cui_log_buffer = std.mem.zeroes(c.cui_log_buffer),
    lines: [log.capacity]c.cui_log_line = undefined,
    text: []u8 = &.{},
    seen: usize = 0,
    generation: u64 = 0,

    pub fn deinit(self: *Activity, gpa: std.mem.Allocator) void {
        if (self.text.len > 0) gpa.free(self.text);
    }

    pub fn sync(self: *Activity, gpa: std.mem.Allocator, source: *const log.Log) !void {
        if (self.text.len == 0) {
            self.text = try gpa.alloc(u8, 256 * 1024);
            c.cui_log_init(&self.buffer, &self.lines, self.lines.len, self.text.ptr, self.text.len);
        }
        if (source.generation != self.generation or source.total < self.seen) {
            self.generation = source.generation;
            c.cui_log_clear(&self.buffer);
            self.seen = 0;
        }
        const first = source.total - source.count();
        for (@max(first, self.seen)..source.total) |i| {
            const entry = source.at(i - first);
            c.cui_log_append_text(&self.buffer, switch (entry.level) {
                .info => c.CUI_LOG_INFO,
                .warn => c.CUI_LOG_WARN,
                .err => c.CUI_LOG_ERROR,
            }, @as(f64, @floatFromInt(entry.timestamp_ms)) / 1000, entry.text.ptr, @intCast(entry.text.len));
        }
        self.seen = source.total;
    }
};

pub fn height(viewport_height: f32) f32 {
    return if (viewport_height < 600) 32 else @max(100, @min(160, viewport_height * 0.2));
}

pub fn view(ui: *c.cui_ctx, app: anytype) void {
    app.activity.sync(app.gpa, &app.log) catch return;
    const viewport_height = c.cui_viewport_size(ui).y;
    const w = @import("widgets.zig");
    w.column(ui, .{ .id = "activity-region", .width = w.fill, .height = w.px(height(viewport_height)), .clip = true });
    c.cui_log_view_ex(ui, "activity-console", &app.activity.buffer, &.{ .height = height(viewport_height), .size = c.KEST_TEXT_CAPTION, .no_toolbar = viewport_height < 600 });
    w.end(ui);
    // Clear in the component clears the source too; hidden/reopened panels stay empty.
    if (app.activity.buffer.count == 0 and app.log.count() > 0) {
        app.log.clear();
        app.activity.seen = 0;
    }
}
