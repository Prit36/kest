//! Explicit test synchronization for lazy views; frames themselves never wait.
const std = @import("std");
const c = @import("ui/c.zig").c;
const App = @import("app/state.zig").App;

pub fn settle(ui: *c.cui_ctx, app: *App, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io).toMilliseconds();
    var stable: u8 = 0;
    var raw_generation: u64 = 0;
    var pretty_generation: u64 = 0;
    var previous_width: f32 = 0;
    var previous_height: f32 = 0;
    while (true) {
        frame(ui, app);
        const t = app.current() orelse return;
        const r = if (t.shown) |job| &job.resp else return;
        c.cui_push_id_int(ui, @intCast(t.uid));
        const bounds = c.cui_get_rect(ui, c.cui_make_id(ui, "response-content"));
        c.cui_pop_id(ui);
        const unchanged = raw_generation == t.response.code_raw.index_generation and pretty_generation == t.response.code_pretty.index_generation and bounds.w == previous_width and bounds.h == previous_height;
        if (unchanged and @import("ui/response_preparation.zig").settled(&t.response, @import("ui/response.zig").wanted(t, r))) {
            stable += 1;
            if (stable >= 3) return;
        } else stable = 0;
        raw_generation = t.response.code_raw.index_generation;
        pretty_generation = t.response.code_pretty.index_generation;
        previous_width = bounds.w;
        previous_height = bounds.h;
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start > 10000) return error.PreparationTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}
