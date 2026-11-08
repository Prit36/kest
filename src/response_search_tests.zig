//! Real CUI input, bounded search workers and an in-memory clipboard.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Tab = @import("app/tab.zig").Tab;
const commands = @import("app/commands.zig");
const prep = @import("app/response_prepare.zig");
const find = @import("ui/response_search.zig");
const core = @import("core/response_search.zig");
const editor = @import("ui/editor.zig");
const fixture = @import("response_preparation_tests.zig").fixture;
const settle = @import("response_test_support.zig").settle;
var clipboard: [8192:0]u8 = @splat(0);
fn getClipboard(_: ?*anyopaque) callconv(.c) [*c]const u8 {
    return &clipboard;
}
fn setClipboard(_: ?*anyopaque, text: [*c]const u8) callconv(.c) void {
    const source = std.mem.span(text);
    const size = @min(source.len, clipboard.len);
    @memcpy(clipboard[0..size], source[0..size]);
    clipboard[size] = 0;
}
fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Response search regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ResponseSearchRegression;
    }
}
fn rect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn focus(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.kest_focus(ui, key);
    c.cui_pop_id(ui);
}
fn focused(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) bool {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.kest_editor_focus(ui, c.cui_make_id(ui, key)) != 0;
}
fn menuRect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "Response actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn tap(ui: *c.cui_ctx, app: *App, t: *Tab, key: [*:0]const u8, comptime click: anytype) !void {
    const r = rect(ui, t, key);
    try check(@src(), r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-response-search-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
const Gate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    fn decode(raw: ?*anyopaque, _: []const u8) prep.Decoded {
        const gate: *Gate = @ptrCast(@alignCast(raw.?));
        gate.entered.set(gate.io);
        gate.proceed.wait(gate.io) catch {};
        return .{ .failure = .invalid };
    }
    fn wake(raw: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(raw));
        app.wake();
    }
};
fn pixelDifference(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, x0: f32, x1: f32, y: f32) !bool {
    const data = c.cui_get_draw_data(ui);
    const width = data.*.width_px;
    const height = data.*.height_px;
    const pixels = try app.gpa.alloc(u8, @as(usize, @intCast(width * height)) * 4);
    defer app.gpa.free(pixels);
    c.cui_sw_render(sw, data, pixels.ptr, width, height, width * 4, c.CUI_SW_RGBA);
    const a = (@as(usize, @intFromFloat(y)) * @as(usize, @intCast(width)) + @as(usize, @intFromFloat(x0))) * 4;
    const b = (@as(usize, @intFromFloat(y)) * @as(usize, @intCast(width)) + @as(usize, @intFromFloat(x1))) * 4;
    return !std.mem.eql(u8, pixels[a..][0..3], pixels[b..][0..3]);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_selected = app.selected;
    const old_layout = @import("ui/workspace.zig").layout;
    const old_ratio = @import("ui/workspace.zig").column_ratio;
    app.tabs = .empty;
    app.active = 0;
    app.selected = null;
    try app.response_preparation.group.await(app.io);
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    defer {
        c.cui_set_platform(ui, null);
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
        @import("ui/workspace.zig").column_ratio = old_ratio;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    app.prefs.dark = true;
    @import("ui/workspace.zig").layout = .stacked;
    c.cui_set_viewport(ui, 1000, 800, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    const blob = try app.gpa.alloc(u8, 4 * 1024 * 1024);
    defer app.gpa.free(blob);
    @memset(blob, 'x');
    for (0..blob.len / 64) |i| @memcpy(blob[i * 64 + 10 ..][0..6], if (i % 2 == 0) "Needle" else "needle");
    try fixture(app, t, "text/plain", blob);
    t.response.pane = .raw;
    try settle(ui, app, frame);
    const s = &t.response.code_raw;
    focus(ui, t, "raw-view");
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    try check(@src(), s.search_open and focused(ui, t, "response-find"));
    c.cui_input_text(ui, "needle");
    frame(ui, app);
    try settle(ui, app, frame);
    try check(@src(), s.search_index.?.total == blob.len / 64 and s.matches.items.len == core.page_size and s.search_selected == 0);
    const canvas = rect(ui, t, "raw-view");
    const origin = canvas.x + editor.gutterWidth(ui, 1) + 12;
    const cell = editor.cellWidth(ui);
    try check(@src(), try pixelDifference(ui, app, sw, origin + 74 * cell + 3, origin + 64 * cell + 3, canvas.y + 26));
    try capture(ui, app, sw, snapshot, "large-dark");
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_SHIFT);
    try settle(ui, app, frame);
    try check(@src(), s.search_selected == s.search_index.?.total - 1 and s.precise_x > 30_000_000 and std.mem.eql(u8, s.selected(blob), "needle"));
    try capture(ui, app, sw, snapshot, "last-match");
    chord(ui, app, c.CUI_KEY_F3, 0);
    try settle(ui, app, frame);
    try check(@src(), s.search_selected == 0);
    const before = app.response_preparation.started;
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), s.search_selected == 1 and app.response_preparation.started == before);
    try tap(ui, app, t, "response-find-next", click);
    try check(@src(), s.search_selected == 2);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0); // Escape from a focused navigation button
    try check(@src(), !s.search_open and focused(ui, t, "raw-view"));
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, std.mem.sliceTo(&clipboard, 0), "Needle"));
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "Needle"); // Ctrl+F selects the previous query
    frame(ui, app);
    try settle(ui, app, frame);
    try check(@src(), std.mem.eql(u8, s.query.text(), "Needle") and s.search_index.?.total == blob.len / 64);
    try tap(ui, app, t, "response-find-case", click);
    try settle(ui, app, frame);
    try check(@src(), s.search_case and s.search_index.?.total == blob.len / 128);
    // Full worker slots must leave the query and the rest of the app responsive.
    var gate: Gate = .{ .io = app.io };
    {
        defer gate.proceed.set(app.io);
        const decoder: prep.Decoder = .{ .ctx = &gate, .decode = Gate.decode };
        const wake: prep.Wake = .{ .ctx = app, .call = Gate.wake };
        const one = try app.response_preparation.start(t.shown.?, .image, decoder, wake);
        defer one.abandon();
        const two = try app.response_preparation.start(t.shown.?, .image, decoder, wake);
        defer two.abandon();
        try gate.entered.wait(app.io);
        s.query.set("obsolete query");
        frame(ui, app);
        try check(@src(), s.search_pending and s.search_job == null and s.search_index == null);
        focus(ui, t, "url");
        c.cui_input_text(ui, "responsive");
        frame(ui, app);
        try check(@src(), std.mem.indexOf(u8, t.url.text(), "responsive") != null);
        t.url.set("https://response.invalid/fixture");
        s.query.set("Needle");
        frame(ui, app);
        try capture(ui, app, sw, snapshot, "waiting");
    }
    try settle(ui, app, frame);
    try check(@src(), s.search_index.?.total == blob.len / 128 and std.mem.eql(u8, s.search_index.?.query, "Needle"));
    // Query changes cancel old interests, including already completed results.
    s.query.set("never present");
    frame(ui, app);
    s.query.set("Needle");
    frame(ui, app);
    try settle(ui, app, frame);
    try check(@src(), s.search_index.?.total == blob.len / 128);
    s.query.set("no matching text");
    try settle(ui, app, frame);
    try check(@src(), s.search_index.?.total == 0 and s.matches.items.len == 0);
    var oversized: [core.max_query + 1]u8 = @splat('a');
    s.query.set(&oversized);
    try settle(ui, app, frame);
    try check(@src(), s.search_failure == .query_limit and !s.search_pending);
    s.query.clear();
    try settle(ui, app, frame);
    try check(@src(), s.search_failure == null and s.search_index == null and s.matches.items.len == 0);
    s.query.set("Needle");
    try settle(ui, app, frame);
    c.cui_input_mouse_move(ui, -20, -20);
    for (0..800) |_| frame(ui, app);
    try check(@src(), !c.cui_needs_redraw(ui) and c.cui_next_wakeup(ui) < 0);
    try check(@src(), std.mem.eql(u8, blob, t.shown.?.resp.preview.items));
    // Search the current formatted source; retain independent Raw queries.
    try fixture(app, t, "application/json", "{\"title\":\"Needle\",\"description\":\"needle\",\"utf8\":\"caf\u{e9}\"}");
    try settle(ui, app, frame);
    focus(ui, t, "pretty-view");
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "needle");
    frame(ui, app);
    try settle(ui, app, frame);
    const pretty = &t.response.code_pretty;
    try check(@src(), t.response.pane == .pretty and pretty.search_index.?.total == 2 and pretty.searched_ptr == @intFromPtr(t.response.formatted.?.ptr));
    pretty.query.set("caf\u{e9}");
    try settle(ui, app, frame);
    try check(@src(), pretty.search_index.?.total == 1 and std.mem.eql(u8, pretty.selected(t.response.formatted.?), "caf\u{e9}"));
    pretty.query.set("needle");
    try settle(ui, app, frame);
    t.response.pretty_mode = .minified;
    try settle(ui, app, frame);
    try check(@src(), pretty.search_index.?.total == 2 and pretty.searched_ptr == @intFromPtr(t.response.formatted.?.ptr) and std.mem.indexOfScalar(u8, t.response.formatted.?, '\n') == null);
    t.response.pretty_mode = .text;
    try settle(ui, app, frame);
    t.response.wrap_response = true;
    try settle(ui, app, frame);
    const search_ptr = pretty.search_index.?.states.items.ptr;
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]bool{ false, true }) |columns| {
        app.prefs.dark = dark;
        @import("ui/workspace.zig").layout = if (columns) .columns else .stacked;
        @import("ui/workspace.zig").column_ratio = 0.7;
        c.cui_set_viewport(ui, if (columns) 1000 else 640, 832, scale);
        try settle(ui, app, frame);
        const bar = rect(ui, t, "response-search");
        const field = rect(ui, t, "response-find");
        const next = rect(ui, t, "response-find-next");
        const close = rect(ui, t, "response-find-close");
        try check(@src(), field.w > 60 and field.x >= bar.x and field.x + field.w <= bar.x + bar.w + 1 and next.x + next.w <= bar.x + bar.w + 1 and close.x + close.w <= bar.x + bar.w + 1);
        try check(@src(), pretty.search_index.?.states.items.ptr == search_ptr);
        const generation = pretty.index_generation;
        for (0..4) |_| frame(ui, app);
        try check(@src(), pretty.index_generation == generation);
        if (scale == 1) try capture(ui, app, sw, snapshot, if (columns) (if (dark) "compact-dark" else "compact-light") else if (dark) "formatted-dark" else "formatted-light");
    };
    @import("ui/workspace.zig").layout = .stacked;
    c.cui_set_viewport(ui, 1000, 800, 1);
    t.response.pane = .raw;
    find.open(t);
    t.response.code_raw.query.set("title");
    try settle(ui, app, frame);
    try check(@src(), t.response.code_raw.search_index.?.total == 1);
    t.response.pane = .headers;
    frame(ui, app);
    try tap(ui, app, t, "response-actions", click);
    const item = menuRect(ui, t, "Find in response");
    try check(@src(), item.w > 0 and item.h > 0);
    click(ui, app, item.x + 50, item.y + item.h / 2);
    try settle(ui, app, frame);
    try check(@src(), t.response.pane == .raw and std.mem.eql(u8, t.response.code_raw.query.text(), "title"));
    t.response.pane = .pretty;
    t.response.pretty_mode = .tree;
    try settle(ui, app, frame);
    find.open(t);
    try settle(ui, app, frame);
    try check(@src(), t.response.pane == .pretty and t.response.pretty_mode == .tree and t.response.json.find_open);
    // Ctrl+F in an editable body stays scoped to that body, with a response shown.
    pretty.search_open = false;
    t.pane = .body;
    t.body_kind = .text;
    t.body.setText("Request needle");
    for (0..3) |_| frame(ui, app);
    focus(ui, t, "body-editor");
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    try check(@src(), t.body.search_open and !pretty.search_open and t.response.pane == .pretty);
    t.body.search_open = false;
    t.pane = .params;
    try fixture(app, t, "text/html", "<needle>Needle</needle>");
    t.response.pane = .preview;
    try settle(ui, app, frame);
    find.open(t);
    pretty.query.set("needle");
    try settle(ui, app, frame);
    try check(@src(), t.response.pane == .preview and pretty.search_index.?.total == 1 and pretty.searched_ptr == @intFromPtr(t.response.stripped.?.ptr));
    // A distant match remains inspectable/copyable in the bounded fallback,
    // even if a million-row source exceeds the full layout/index limit.
    const many = try app.gpa.alloc(u8, (prep.max_rows + 1) * 2 + 6);
    defer app.gpa.free(many);
    for (0..prep.max_rows + 1) |i| @memcpy(many[i * 2 ..][0..2], "x\n");
    @memcpy(many[many.len - 6 ..], "target");
    try fixture(app, t, "text/plain", many);
    t.response.pane = .raw;
    find.open(t);
    s.query.set("target");
    try settle(ui, app, frame);
    try check(@src(), t.response.raw_index_failure == .index_limit and s.search_index.?.total == 1 and s.layout_fallback_offset > 1_000_000);
    try check(@src(), std.mem.eql(u8, s.selected(many), "target"));
    try capture(ui, app, sw, snapshot, "fallback-match");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, std.mem.sliceTo(&clipboard, 0), "target"));
    // Clearing and replacing results release every search/index source owner.
    try fixture(app, t, "text/plain", blob);
    find.open(t);
    pretty.query.set("needle");
    try settle(ui, app, frame);
    try check(@src(), t.response.pane == .pretty and pretty.search_index.?.total == blob.len / 64);
    t.response.pane = .raw;
    find.open(t);
    s.query.set("needle");
    frame(ui, app);
    const pinned = t.shown.?;
    pinned.retain();
    commands.clearResponse(t);
    try app.response_preparation.group.await(app.io);
    try check(@src(), pinned.refs.load(.acquire) == 1 and s.search_job == null and s.search_index == null and s.matches.capacity == 0);
    pinned.destroy();
    try fixture(app, t, "application/octet-stream", "Needle\x00");
    find.open(t);
    frame(ui, app);
    try check(@src(), !s.search_open and !pretty.search_open);
    std.debug.print("CUI response search: full 4 MiB counts, navigation past 10,000, visible highlights, Enter/F3/Escape and focus, case/UTF-8, busy-slot input, stale query/clear ownership, current modes and themes/scales passed\n", .{});
}
