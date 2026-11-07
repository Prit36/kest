//! Regressions for the sidebar empty-state screenshot: inset, wrap and recovery.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const shell = @import("ui/shell.zig");

fn expect(value: bool) !void {
    if (!value) return error.SidebarLayoutFailed;
}
fn rect(ui: *c.cui_ctx, id: [*:0]const u8) c.cui_rect {
    const sheet = shell.narrow_open and c.cui_viewport_size(ui).x < 840;
    if (sheet) c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "Workspace") ^ 0x5ee7));
    defer if (sheet) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, id));
}
fn checkEmpty(ui: *c.cui_ctx, id: []const u8) !void {
    const browser = rect(ui, "collection-browser");
    const title = rect(ui, w.fmt("{s}-title", .{id}));
    const detail = rect(ui, w.fmt("{s}-detail", .{id}));
    const viewport = rect(ui, w.z(id));
    try expect(title.w > 0 and detail.h >= 18);
    try expect(title.x >= browser.x + 13 and detail.x >= browser.x + 13);
    try expect(title.x + title.w <= browser.x + browser.w - 13);
    try expect(detail.x + detail.w <= browser.x + browser.w - 13);
    try expect(detail.y >= title.y + title.h + 5);
    try expect(detail.y + detail.h <= viewport.y + viewport.h);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, path: ?[]const u8, comptime frame: anytype, comptime click: anytype) !void {
    const old_mode = app.mode;
    const old_dark = app.prefs.dark;
    const old_sidebar = app.prefs.sidebar_open;
    const old_ratio = shell.sidebar_ratio;
    const old_narrow = shell.narrow_open;
    const old_method = app.history_method;
    const old_status = app.history_status;
    const old_query = try app.gpa.dupe(u8, app.history_query.text());
    defer app.gpa.free(old_query);
    defer {
        app.mode = old_mode;
        app.prefs.dark = old_dark;
        app.prefs.sidebar_open = old_sidebar;
        shell.sidebar_ratio = old_ratio;
        shell.narrow_open = old_narrow;
        app.history_method = old_method;
        app.history_status = old_status;
        app.history_query.set(old_query);
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    // The saved history was produced by the real loopback integration suite.
    const saved_history = app.history;
    var temporary_history = true;
    app.history = .init(app.gpa);
    defer if (temporary_history) {
        app.history.deinit();
        app.history = saved_history;
    };
    app.mode = .history;
    app.prefs.sidebar_open = true;
    app.history_query.clear();
    app.history_method = 0;
    app.history_status = 0;
    shell.sidebar_ratio = 0.01; // Exercise the actual 210px sidebar minimum.
    for ([_]bool{ true, false }) |dark| {
        app.prefs.dark = dark;
        for ([_]bool{ false, true }) |narrow| {
            shell.narrow_open = narrow;
            c.cui_set_viewport(ui, if (narrow) 640 else 840, 420, 1);
            for (0..5) |_| frame(ui, app);
            try checkEmpty(ui, "history-empty");
            const filters = rect(ui, "history-filters");
            const title = rect(ui, "history-empty-title");
            const browser = rect(ui, "collection-browser");
            try expect(title.y >= filters.y + filters.h + 13);
            inline for (.{ "history-method", "history-status" }) |key| {
                const control = rect(ui, key);
                try expect(control.w >= 70 and control.x >= browser.x + 9);
                try expect(control.x + control.w <= browser.x + browser.w - 9);
            }
            if (dark and !narrow) try capture(ui, sw, app, path, "history-empty");
            app.history_query.set("no-such-history-entry");
            app.history_method = 2;
            app.history_status = 3;
            for (0..3) |_| frame(ui, app);
            try checkEmpty(ui, "history-empty");
            const reset = rect(ui, "###reset-history-filters");
            const area = rect(ui, "history-empty");
            if (dark and narrow) try capture(ui, sw, app, path, "history-compact-filtered");
            try expect(reset.h == 28 and reset.y + reset.h <= area.y + area.h);
            if (dark and !narrow) try capture(ui, sw, app, path, "history-filtered");
            click(ui, app, reset.x + reset.w / 2, reset.y + reset.h / 2);
            try expect(app.history_query.len == 0 and app.history_method == 0 and app.history_status == 0);
        }
    }
    // The shared empty layout also has to fit environment setup actions.
    const saved_envs = app.envs;
    const saved_active_env = app.active_env;
    app.envs = .empty;
    app.active_env = null;
    defer {
        app.envs = saved_envs;
        app.active_env = saved_active_env;
    }
    app.mode = .environments;
    for ([_]bool{ false, true }) |narrow| {
        shell.narrow_open = narrow;
        c.cui_set_viewport(ui, if (narrow) 640 else 840, 420, 1);
        for (0..4) |_| frame(ui, app);
        try checkEmpty(ui, "environments-empty");
    }
    app.envs = saved_envs;
    app.active_env = saved_active_env;
    app.mode = .history;
    app.history.deinit();
    app.history = saved_history;
    temporary_history = false;
    shell.narrow_open = false;
    c.cui_set_viewport(ui, 1180, 800, 1);
    app.history_query.set("no-such-history-entry");
    for (0..3) |_| frame(ui, app);
    const reset = rect(ui, "###reset-history-filters");
    click(ui, app, reset.x + reset.w / 2, reset.y + reset.h / 2);
    frame(ui, app);
    try expect(app.history_visible.items.len == app.history.entries.items.len and app.history_visible.items.len > 0);
    std.debug.print("CUI sidebar: empty/history filter layout, 210px inset/wrap, compact sheet, dark/light and actual filter reset passed\n", .{});
}
