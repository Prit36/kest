//! Native layout and pointer regressions; no OS input or clipboard.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const workspace = @import("ui/workspace.zig");

fn check(value: bool) !void {
    if (!value) return error.GeometryRegression;
}
fn rect(ui: *c.cui_ctx, uid: ?u64, key: [*:0]const u8, suffix: u32) c.cui_rect {
    if (uid) |id| c.cui_push_id_int(ui, @intCast(id));
    defer if (uid != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key) ^ suffix);
}
fn drag(ui: *c.cui_ctx, app: *App, handle: c.cui_rect, x: f32, y: f32, comptime frame: anytype) void {
    c.cui_input_mouse_move(ui, handle.x + handle.w / 2, handle.y + handle.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, x, y);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    for (0..3) |_| frame(ui, app);
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype) !void {
    const t = app.current().?;
    const old_prefs = app.prefs;
    const old_layout = workspace.layout;
    const old_ratio = workspace.column_ratio;
    const old_pane = t.pane;
    const old_details = t.details_collapsed;
    const old_response = t.response_collapsed;
    defer {
        app.prefs = old_prefs;
        workspace.layout = old_layout;
        workspace.column_ratio = old_ratio;
        t.pane = old_pane;
        t.details_collapsed = old_details;
        t.response_collapsed = old_response;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    app.prefs.sidebar_open = true;
    app.prefs.sidebar_width = 280;
    app.prefs.log_open = false;
    t.pane = .body;
    t.details_collapsed = false;
    t.response_collapsed = false;
    workspace.layout = .auto;
    const sizes = [_][2]f32{ .{ 640, 420 }, .{ 1024, 768 }, .{ 1280, 800 }, .{ 1280, 832 }, .{ 1282, 832 }, .{ 1366, 768 }, .{ 1440, 900 }, .{ 1920, 1080 }, .{ 2560, 1440 } };
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for (sizes) |size| {
        app.prefs.dark = dark;
        c.cui_set_viewport(ui, size[0], size[1], scale);
        for (0..4) |_| frame(ui, app);
        const main = rect(ui, null, "main-workspace", 0);
        const request = rect(ui, t.uid, "request-panel", 0);
        const response = rect(ui, t.uid, "response-panel", 0);
        const region = rect(ui, null, "workspace-region", 0);
        try check(request.w >= 300 and response.w >= 350);
        try check(request.y >= main.y and response.y >= main.y);
        try check(request.x + request.w <= main.x + main.w + 1);
        try check(response.x + response.w <= main.x + main.w + 1);
        try check(request.y + request.h <= region.y + region.h + 1 and response.y + response.h <= region.y + region.h + 1);
        try check(@abs(region.y + region.h - size[1]) < 1);
        const columns = response.x > request.x + request.w - 1;
        try check(columns == (main.w >= 730));
        if (size[0] >= 840) {
            const sidebar = rect(ui, null, "collection-browser", 0);
            try check(@abs(sidebar.w - 280) < 2);
        }
    };
    // Explicit columns can use the safe minimum; Auto keeps extra breathing room.
    c.cui_set_viewport(ui, 980, 800, 1);
    workspace.layout = .columns;
    for (0..4) |_| frame(ui, app);
    try check(rect(ui, t.uid, "response-panel", 0).x > rect(ui, t.uid, "request-panel", 0).x + 300);
    workspace.layout = .auto;
    for (0..4) |_| frame(ui, app);
    try check(rect(ui, t.uid, "response-panel", 0).y > rect(ui, t.uid, "request-panel", 0).y);
    // Pointer dragging retains editor identity, selection and buffer version.
    app.prefs.dark = true;
    c.cui_set_viewport(ui, 1440, 900, 1);
    for (0..4) |_| frame(ui, app);
    const before = workspace.column_ratio;
    const version = t.body.version;
    const caret = t.body.caret;
    const anchor = t.body.anchor;
    const handle = rect(ui, t.uid, "editors-columns", 0x77);
    try check(handle.w > 0 and handle.h > 100);
    drag(ui, app, handle, handle.x + 80, handle.y + handle.h / 2, frame);
    try check(workspace.column_ratio > before and app.prefs.column_split == workspace.column_ratio);
    try check(t.body.version == version and t.body.caret == caret and t.body.anchor == anchor);
    for ([_]f32{ 0, 1440 }) |target| {
        const divider = rect(ui, t.uid, "editors-columns", 0x77);
        drag(ui, app, divider, target, divider.y + divider.h / 2, frame);
        try check(rect(ui, t.uid, "request-panel", 0).w >= 320);
        try check(rect(ui, t.uid, "response-panel", 0).w >= 360);
    }
    for ([_]f32{ 0, 1440 }) |target| {
        const divider = rect(ui, null, "sidebar-split", 0x77);
        drag(ui, app, divider, target, divider.y + divider.h / 2, frame);
        const browser = rect(ui, null, "collection-browser", 0);
        try check(browser.w >= 210 and browser.w <= 481);
        try check(app.prefs.sidebar_width >= 210 and app.prefs.sidebar_width <= 481);
    }
    app.prefs.sidebar_width = 280;
    for (0..3) |_| frame(ui, app);
    const choices = [_][*:0]const u8{ "Focus request", "Focus response", "Show both panes", "Reset split to equal" };
    for (choices, 0..) |choice, i| {
        const menu = rect(ui, null, "###workspace-layout", 0);
        click(ui, app, menu.x + menu.w / 2, menu.y + menu.h / 2);
        const popup = c.cui_make_id(ui, "###workspace-layout") ^ 0x3e40;
        c.cui_push_id_int(ui, @bitCast(popup));
        const option = c.cui_get_rect(ui, c.cui_make_id(ui, choice));
        c.cui_pop_id(ui);
        try check(option.w > 0);
        click(ui, app, option.x + option.w / 2, option.y + option.h / 2);
        for (0..3) |_| frame(ui, app);
        switch (i) {
            0 => try check(t.response_collapsed and !t.details_collapsed and rect(ui, t.uid, "request-panel", 0).w > 1000),
            1 => try check(t.details_collapsed and !t.response_collapsed and rect(ui, t.uid, "response-panel", 0).w > 1000),
            2 => try check(!t.details_collapsed and !t.response_collapsed),
            3 => try check(workspace.column_ratio == 0.5 and app.prefs.split == 0.5 and app.prefs.column_split == 0.5),
            else => unreachable,
        }
    }
    try check(t.body.version == version and t.body.caret == caret);
    std.debug.print("CUI geometry: nine window sizes, both themes/four scales, fixed sidebar width, column dragging, state preservation and Layout focus/reset actions passed\n", .{});
}
