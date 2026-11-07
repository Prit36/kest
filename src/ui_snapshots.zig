//! Diagnostic captures of real application views after the loopback UI suite.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;

pub fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: []const u8) !void {
    const size = c.cui_viewport_size(ui);
    const width: c_int = @intFromFloat(size.x);
    const height: c_int = @intFromFloat(size.y);
    const pixels = try app.gpa.alloc(u8, @as(usize, @intCast(width * height)) * 4);
    defer app.gpa.free(pixels);
    c.cui_sw_render(sw, c.cui_get_draw_data(ui), pixels.ptr, width, height, width * 4, c.CUI_SW_RGBA);
    if (!c.cui_write_png(w.z(path), pixels.ptr, width, height, width * 4)) return error.SnapshotFailed;
}

pub fn suite(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: []const u8, comptime frame: anytype) !void {
    const t = app.current().?;
    const old_pane = t.pane;
    const old_kind = t.body_kind;
    const old_mode = app.mode;
    const old_dark = app.prefs.dark;
    const old_log_open = app.prefs.log_open;
    const old_response_pane = t.response.pane;
    const old_layout = @import("ui/workspace.zig").layout;
    const old_modal = app.modal;
    const old_editing_env = app.editing_env;
    const old_size = c.cui_viewport_size(ui);
    defer {
        t.pane = old_pane;
        t.body_kind = old_kind;
        t.details_collapsed = false;
        app.mode = old_mode;
        app.prefs.dark = old_dark;
        app.prefs.log_open = old_log_open;
        t.response.pane = old_response_pane;
        @import("ui/workspace.zig").layout = old_layout;
        app.modal = old_modal;
        app.modal_open = false;
        app.editing_env = old_editing_env;
        @import("ui/shell.zig").narrow_open = false;
        c.cui_set_viewport(ui, old_size.x, old_size.y, 1);
    }
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    const scenes = [_][]const u8{ "body", "settings", "history", "variables", "focus", "light", "minimum", "sidebar", "response-headers", "stacked", "body-minimum", "environment-editor", "activity" };
    for (scenes, 0..) |scene, i| {
        t.pane = old_pane;
        t.body_kind = old_kind;
        t.details_collapsed = false;
        app.mode = old_mode;
        app.prefs.dark = old_dark;
        app.prefs.log_open = old_log_open;
        t.response.pane = old_response_pane;
        @import("ui/workspace.zig").layout = old_layout;
        app.modal_open = false;
        @import("ui/shell.zig").narrow_open = false;
        c.cui_set_viewport(ui, old_size.x, old_size.y, 1);
        switch (i) {
            0 => {
                t.pane = .body;
                t.body_kind = .json;
            },
            1 => t.pane = .settings,
            2 => app.mode = .history,
            3 => app.mode = .environments,
            4 => t.details_collapsed = true,
            5 => app.prefs.dark = false,
            6, 7 => {
                c.cui_set_viewport(ui, 640, 420, 1);
                @import("ui/shell.zig").narrow_open = i == 7;
            },
            8 => t.response.pane = .headers,
            9 => @import("ui/workspace.zig").layout = .stacked,
            10 => {
                c.cui_set_viewport(ui, 640, 420, 1);
                t.pane = .body;
                t.body_kind = .json;
            },
            11 => {
                c.cui_set_viewport(ui, 640, 420, 1);
                if (app.envs.items.len > 0) {
                    app.editing_env = app.envs.items[0];
                    app.modal = .environment;
                    app.modal_open = true;
                }
            },
            12 => app.prefs.log_open = true,
            else => unreachable,
        }
        for (0..8) |_| frame(ui, app);
        const target = try std.fmt.allocPrint(app.gpa, "{s}-{s}.png", .{ stem, scene });
        defer app.gpa.free(target);
        try capture(ui, sw, app, target);
    }
}
