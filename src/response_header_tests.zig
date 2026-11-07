//! Actual received headers and CUI input, with an in-memory clipboard adapter.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Tab = @import("app/tab.zig").Tab;
const commands = @import("app/commands.zig");
const header_ui = @import("ui/response_headers.zig");

var clipboard: [128 * 1024:0]u8 = @splat(0);
var overflow = false;
fn getClipboard(_: ?*anyopaque) callconv(.c) [*c]const u8 {
    return &clipboard;
}
fn setClipboard(_: ?*anyopaque, value: [*c]const u8) callconv(.c) void {
    const source = std.mem.span(value);
    overflow = overflow or source.len > clipboard.len;
    const length = @min(clipboard.len, source.len);
    @memcpy(clipboard[0..length], source[0..length]);
    clipboard[length] = 0;
}
fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Response header regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ResponseHeaderRegression;
    }
}
fn copied(src: std.builtin.SourceLocation, want: []const u8) !void {
    const got = std.mem.sliceTo(&clipboard, 0);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("Header clipboard mismatch at {s}:{d}, wanted {d} bytes, got {d}\n", .{ src.file, src.line, want.len, got.len });
        return error.ResponseHeaderRegression;
    }
}
fn rect(ui: *c.cui_ctx, t: *Tab, row: ?usize, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    if (row) |i| c.cui_push_id_int(ui, @intCast(i));
    defer if (row != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn present(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) bool {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.kest_has_node(ui, c.cui_make_id(ui, key));
}
fn popupRect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "response-header-details")));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn rowMenu(ui: *c.cui_ctx, t: *Tab, row: usize, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @intCast(row));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "row-actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn tableMenu(ui: *c.cui_ctx, t: *Tab, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "table-actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn focus(ui: *c.cui_ctx, t: *Tab, row: usize, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id_int(ui, @intCast(row));
    c.kest_focus(ui, key);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
}
fn focused(ui: *c.cui_ctx, t: *Tab, row: usize, key: [*:0]const u8) bool {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @intCast(row));
    defer c.cui_pop_id(ui);
    return c.kest_editor_focus(ui, c.cui_make_id(ui, key)) != 0;
}
fn tap(ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime click: anytype) !void {
    try check(@src(), r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn wait(ui: *c.cui_ctx, app: *App, t: *Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io).toMilliseconds();
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start > 10000) return error.RequestTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
    for (0..3) |_| frame(ui, app);
}
fn capture(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-headers-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn inside(inner: c.cui_rect, outer: c.cui_rect) bool {
    return inner.w > 0 and inner.h > 0 and inner.x >= outer.x - 1 and inner.y >= outer.y - 1 and inner.x + inner.w <= outer.x + outer.w + 1 and inner.y + inner.h <= outer.y + outer.h + 1;
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_selected = app.selected;
    const old_layout = @import("ui/workspace.zig").layout;
    app.tabs = .empty;
    app.active = 0;
    app.selected = null;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.response_preparation.group.await(app.io) catch {};
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        app.active_env = old_env;
        app.selected = old_selected;
        app.vars_dirty = true;
        @import("ui/workspace.zig").layout = old_layout;
        c.cui_set_platform(ui, &.{});
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    overflow = false;
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    @import("ui/workspace.zig").layout = .stacked;
    c.cui_set_viewport(ui, 640, 420, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    if (snapshot != null) {
        c.cui_input_mouse_move(ui, -20, -20);
        for (0..540) |_| frame(ui, app);
    }
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    t.url.set(try server.url(w.arena.allocator(), "/headers/large"));
    t.response.pane = .headers;
    commands.send(app, t);
    try wait(ui, app, t, frame);
    const r = &t.shown.?.resp;
    try check(@src(), r.status == 200 and r.headers.items.len == 1207 and r.headers.items[2].value.len == 17 * 1024);
    const raw = try app.gpa.dupe(u8, r.raw_headers);
    defer app.gpa.free(raw);
    // Visible cells select/copy literal text, without enabling editing or Cut.
    try tap(ui, app, rect(ui, t, 0, "key"), click);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try copied(@src(), "Set-Cookie");
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_SHIFT);
    try check(@src(), !focused(ui, t, 0, "key"));
    focus(ui, t, 0, "key");
    frame(ui, app);
    setClipboard(null, "unchanged");
    chord(ui, app, c.CUI_KEY_X, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "must not change headers");
    frame(ui, app);
    // Native read-only Cut copies its selection without deleting it.
    try copied(@src(), "Set-Cookie");
    try check(@src(), std.mem.eql(u8, raw, r.raw_headers));
    chord(ui, app, c.CUI_KEY_TAB, 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try copied(@src(), "b=2; Path=/");
    chord(ui, app, c.CUI_KEY_F10, c.CUI_MOD_SHIFT);
    try tap(ui, app, rowMenu(ui, t, 1, "Copy header line"), click);
    try copied(@src(), "set-cookie: b=2; Path=/");
    // Jump to distant virtualized rows and reveal the focused field.
    focus(ui, t, 1, "value");
    chord(ui, app, c.CUI_KEY_END, c.CUI_MOD_PRIMARY);
    try check(@src(), inside(rect(ui, t, 1206, "value"), rect(ui, t, null, "response-header-rows")));
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try copied(@src(), "4");
    chord(ui, app, c.CUI_KEY_TAB, 0);
    try check(@src(), !focused(ui, t, 1206, "value"));
    focus(ui, t, 1206, "value");
    chord(ui, app, c.CUI_KEY_HOME, c.CUI_MOD_PRIMARY);
    try check(@src(), inside(rect(ui, t, 0, "value"), rect(ui, t, null, "response-header-rows")));
    chord(ui, app, c.CUI_KEY_PAGE_DOWN, 0);
    chord(ui, app, c.CUI_KEY_HOME, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    // Explicit inspection exposes a bounded selectable prefix; full-copy
    // actions use original data and raw-line whitespace, beyond that prefix.
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.response.inspected_header == 2);
    const bounds = rect(ui, t, null, "response-header-details");
    try check(@src(), bounds.x >= 0 and bounds.y >= 0 and bounds.x + bounds.w <= 640 and bounds.y + bounds.h <= 420);
    try tap(ui, app, popupRect(ui, t, "copy-header-value"), click);
    try copied(@src(), r.headers.items[2].value);
    try tap(ui, app, popupRect(ui, t, "copy-header-line"), click);
    try copied(@src(), r.headers.items[2].raw_line);
    try tap(ui, app, popupRect(ui, t, "inspected-value"), click);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.sliceTo(&clipboard, 0).len == header_ui.inspector_limit + 3);
    try tap(ui, app, popupRect(ui, t, "###header-value-next"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.response.header_value_offset == header_ui.inspector_limit);
    try tap(ui, app, popupRect(ui, t, "inspected-value"), click);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try copied(@src(), r.headers.items[2].value[header_ui.inspector_limit..]);
    try tap(ui, app, popupRect(ui, t, "###header-value-previous"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.response.header_value_offset == 0);
    try capture(ui, app, sw, snapshot, "inspector");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    // Preserve raw CRLF/spacing for all-header copies.
    try tap(ui, app, rect(ui, t, null, "table-actions"), click);
    try tap(ui, app, tableMenu(ui, t, "Copy response headers"), click);
    try copied(@src(), raw);
    for ([_]bool{ true, false }) |dark| {
        app.prefs.dark = dark;
        for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
            for ([_]f32{ 640, 1000, 1282 }) |width| {
                c.cui_set_viewport(ui, width, 832, scale);
                focus(ui, t, 0, "value");
                chord(ui, app, c.CUI_KEY_HOME, c.CUI_MOD_PRIMARY);
                for (0..3) |_| frame(ui, app);
                const heading = rect(ui, t, null, "response-header-heading");
                const names = rect(ui, t, null, "response-header-name-column");
                const values = rect(ui, t, null, "response-header-value-column");
                try check(@src(), names.x >= heading.x and names.x + names.w <= values.x + 1 and values.x + values.w <= heading.x + heading.w);
                try check(@src(), inside(rect(ui, t, 0, "key"), rect(ui, t, null, "response-header-rows")));
            }
        }
        c.cui_set_viewport(ui, 640, 420, 1);
        for (0..3) |_| frame(ui, app);
        try capture(ui, app, sw, snapshot, if (dark) "compact-dark" else "compact-light");
    }
    // An open inspector belongs to the shown response/tab and closes on mode
    // switches, a new document, replacement or Clear.
    focus(ui, t, 0, "value");
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    const other = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    const orphan = c.cui_popover_is_open(ui, "response-header-details");
    c.cui_pop_id(ui);
    try check(@src(), !orphan);
    commands.closeNow(app, other);
    for (0..3) |_| frame(ui, app);
    // Unsafe byte copies are explicitly escaped, never silently cut at NUL.
    try r.onHead(.{ .status = 200, .reason = "OK", .url = "https://headers.invalid/", .raw_headers = "X-Bytes: a\x00b\xff\r\n", .redirects = 0 });
    t.response.inspected_header = null;
    for (0..3) |_| frame(ui, app);
    focus(ui, t, 0, "value");
    chord(ui, app, c.CUI_KEY_F10, c.CUI_MOD_SHIFT);
    try tap(ui, app, rowMenu(ui, t, 0, "Copy escaped value"), click);
    try copied(@src(), "a\\x00b\\xFF");
    header_ui.copyAll(ui, r);
    try copied(@src(), "X-Bytes: a\\x00b\\xFF\\r\\n");
    try check(@src(), r.headers.items[0].value.len == 4);
    focus(ui, t, 0, "value");
    chord(ui, app, c.CUI_KEY_F10, c.CUI_MOD_SHIFT);
    t.url.set(try server.url(w.arena.allocator(), "/headers"));
    commands.send(app, t);
    try wait(ui, app, t, frame);
    setClipboard(null, "old menu must close");
    chord(ui, app, c.CUI_KEY_LEFT, 0);
    try check(@src(), t.response.pane != .headers);
    chord(ui, app, c.CUI_KEY_RIGHT, 0);
    try check(@src(), t.response.pane == .headers);
    focus(ui, t, 0, "value");
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try copied(@src(), "a=1; Path=/");
    t.url.set(try server.url(w.arena.allocator(), "/status/204"));
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.status == 204 and t.shown.?.resp.headers.items.len == 0);
    try check(@src(), !present(ui, t, "response-header-grid") and present(ui, t, "received-headers"));
    try capture(ui, app, sw, snapshot, "empty");
    commands.clearResponse(t);
    frame(ui, app);
    try check(@src(), t.response.inspected_header == null and !overflow);
    std.debug.print("CUI response headers: literal duplicates/order/OWS, read-only selection and Cut guard, full/escaped clipboard, 1207-row navigation, bounded inspection, themes/scales and popup cleanup passed\n", .{});
}
