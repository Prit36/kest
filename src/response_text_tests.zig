//! Native CUI geometry/input and worker ownership for response wrapping.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Tab = @import("app/tab.zig").Tab;
const commands = @import("app/commands.zig");
const spatial = @import("core/text_layout.zig");
const text_ui = @import("ui/response_text.zig");
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
        std.debug.print("Response text regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ResponseTextRegression;
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
fn menuItem(ui: *c.cui_ctx, t: *Tab, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "Response actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn capture(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-response-text-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

const Gate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    fn decode(raw: ?*anyopaque, _: []const u8) @import("app/response_prepare.zig").Decoded {
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
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    @import("ui/workspace.zig").layout = .stacked;
    c.cui_set_viewport(ui, 1000, 800, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    const blob = try app.gpa.alloc(u8, 4 * 1024 * 1024);
    defer app.gpa.free(blob);
    @memset(blob, 'x');
    @memcpy(blob[blob.len - 16 ..], " exact line end!");
    try fixture(app, t, "text/plain", blob);
    t.response.pane = .raw;
    try settle(ui, app, frame);
    const s = &t.response.code_raw;
    try check(@src(), s.geometry != null and s.index.count() == 1 and s.indexed_len == blob.len);
    try check(@src(), s.geometry.?.starts.items.len == blob.len / spatial.checkpoint_bytes);
    const row_ptr = s.index.starts.items.ptr;
    const checkpoints = s.geometry.?.starts.items.ptr;
    const started = app.response_preparation.started;
    for (0..20) |_| frame(ui, app);
    try check(@src(), app.response_preparation.started == started and s.index.starts.items.ptr == row_ptr and s.geometry.?.starts.items.ptr == checkpoints);
    c.cui_input_mouse_move(ui, -20, -20);
    for (0..800) |_| frame(ui, app);
    try check(@src(), !c.cui_needs_redraw(ui) and c.cui_next_wakeup(ui) < 0);
    // A user can select the prefix while both worker slots are occupied.
    // That selection must survive the eventual full spatial-index adoption.
    s.clearLayout();
    var gate: Gate = .{ .io = app.io };
    {
        defer gate.proceed.set(app.io);
        const decoder: @import("app/response_prepare.zig").Decoder = .{ .ctx = &gate, .decode = Gate.decode };
        const wake: @import("app/response_prepare.zig").Wake = .{ .ctx = app, .call = Gate.wake };
        const one = try app.response_preparation.start(t.shown.?, .image, decoder, wake);
        defer one.abandon();
        const two = try app.response_preparation.start(t.shown.?, .image, decoder, wake);
        defer two.abandon();
        try gate.entered.wait(app.io);
        for (0..3) |_| frame(ui, app);
        try check(@src(), s.layout_job == null and s.layout_pending and s.layout_fallback != null);
        const prefix = rect(ui, t, "raw-view");
        click(ui, app, prefix.x + 160, prefix.y + 16);
        chord(ui, app, c.CUI_KEY_HOME, c.CUI_MOD_SHIFT);
        try check(@src(), s.caret != s.anchor and s.caret == s.layout_fallback.?.caret and s.anchor == s.layout_fallback.?.anchor);
    }
    const prefix_selection = s.selection();
    try settle(ui, app, frame);
    try check(@src(), std.meta.eql(prefix_selection, s.selection()));
    focus(ui, t, "raw-view");
    chord(ui, app, c.CUI_KEY_END, c.CUI_MOD_PRIMARY);
    try check(@src(), s.caret == blob.len and s.precise_x > 30_000_000);
    for (0..5) |_| chord(ui, app, c.CUI_KEY_LEFT, c.CUI_MOD_SHIFT);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, std.mem.sliceTo(&clipboard, 0), blob[blob.len - 5 ..]));
    c.cui_input_text(ui, "must remain read only");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_DELETE, 0);
    chord(ui, app, c.CUI_KEY_V, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, t.shown.?.resp.preview.items, blob) and s.undo.items.len == 0);
    try capture(ui, app, sw, snapshot, "distant-end");
    chord(ui, app, c.CUI_KEY_HOME, 0);
    try check(@src(), s.caret == 0 and s.precise_x == 0);
    var canvas = rect(ui, t, "raw-view");
    c.cui_input_mouse_move(ui, canvas.x + 180, canvas.y + 30);
    frame(ui, app);
    c.cui_input_scroll(ui, -10, 0);
    frame(ui, app);
    const trackpad_x = s.precise_x;
    try check(@src(), trackpad_x > 200 and s.scroll_y == 0);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, c.CUI_MOD_SHIFT);
    c.cui_input_scroll(ui, 0, -10);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, 0);
    frame(ui, app);
    try check(@src(), s.precise_x > trackpad_x + 200 and s.scroll_y == 0);
    // Track click + drag reaches a far byte without measuring its prefix.
    c.cui_input_mouse_move(ui, canvas.x + 120, canvas.y + canvas.h - 6);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, canvas.x + canvas.w - 24, canvas.y + canvas.h - 6);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try check(@src(), s.precise_x > s.geometry.?.widest * 0.9 and s.caret == 0);
    // Use the actual contextual action, including its checked state.
    const actions = rect(ui, t, "response-actions");
    click(ui, app, actions.x + actions.w / 2, actions.y + actions.h / 2);
    const wrap = menuItem(ui, t, "Wrap lines");
    try check(@src(), wrap.w > 0 and wrap.h > 0);
    click(ui, app, wrap.x + 50, wrap.y + wrap.h / 2);
    try settle(ui, app, frame);
    try check(@src(), t.response.wrap_response and s.geometry.?.config.wrap_width > 0 and s.index.count() > 30_000 and s.precise_x == 0);
    for (s.geometry.?.widths.items) |width| try check(@src(), width <= s.geometry.?.config.wrap_width + 0.01);
    // Page navigation and vertical track interactions retain byte selection.
    focus(ui, t, "raw-view");
    chord(ui, app, c.CUI_KEY_END, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_PAGE_UP, c.CUI_MOD_SHIFT);
    try check(@src(), s.caret < s.anchor and s.scroll_y > 0);
    const saved_selection = s.selection();
    canvas = rect(ui, t, "raw-view");
    click(ui, app, canvas.x + canvas.w - 6, canvas.y + 8);
    try check(@src(), s.scroll_y < 100 and std.meta.eql(saved_selection, s.selection()));
    s.scroll_y = 4000;
    s.reveal = false;
    frame(ui, app);
    const anchor = s.index.starts.items[@as(usize, @intFromFloat(s.scroll_y / 20))];
    c.cui_set_viewport(ui, 640, 800, 1);
    try settle(ui, app, frame);
    const top = @as(usize, @intFromFloat(s.scroll_y / 20));
    const bounds = s.index.bounds(blob, top);
    try check(@src(), bounds[0] <= anchor and bounds[1] >= anchor and std.meta.eql(saved_selection, s.selection()));
    // Raw and formatted views keep independent reading/selection state.
    const phrase = "A response can contain long lines, tabs\tand UTF-8: caf\u{e9}, \u{3a9}. ";
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(app.gpa);
    try json.appendSlice(app.gpa, "{\"message\":\"");
    for (0..150) |_| try json.appendSlice(app.gpa, "A response can contain long lines and UTF-8: caf\u{e9}, \u{3a9}. ");
    try json.appendSlice(app.gpa, "\",\"ok\":true,\"count\":42}");
    t.response.wrap_response = false;
    try fixture(app, t, "application/json", json.items);
    t.response.pane = .raw;
    try settle(ui, app, frame);
    s.precise_x = 500;
    s.caret = 75;
    s.anchor = 10;
    s.reveal = false;
    frame(ui, app);
    t.response.pane = .pretty;
    try settle(ui, app, frame);
    try check(@src(), t.response.formatted_owner != null and t.response.code_pretty.geometry != null);
    const formatted = t.response.formatted.?.ptr;
    t.response.pane = .headers;
    frame(ui, app);
    t.response.pane = .raw;
    try settle(ui, app, frame);
    try check(@src(), s.precise_x == 500 and s.caret == 75 and s.anchor == 10);
    t.response.pane = .pretty;
    try settle(ui, app, frame);
    try check(@src(), t.response.formatted.?.ptr == formatted);
    t.response.wrap_response = true;
    // Compare the worker's native font measurements with UI-side metrics.
    try settle(ui, app, frame);
    const pretty = &t.response.code_pretty;
    for (pretty.geometry.?.widths.items, 0..) |width, row| {
        const measured = editor.advance(ui, pretty.index.row(t.response.formatted.?, row), editor.cellWidth(ui));
        try check(@src(), @abs(width - measured) < 0.1 and width <= pretty.geometry.?.config.wrap_width + 0.1);
    }
    for ([_]c_int{ c.CUI_THEME_DARK, c.CUI_THEME_LIGHT }) |theme| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 1000, 1282 }) |width| {
        app.prefs.dark = theme == c.CUI_THEME_DARK;
        c.cui_set_viewport(ui, width, 832, scale);
        try settle(ui, app, frame);
        const r = rect(ui, t, "pretty-view");
        try check(@src(), r.w > 100 and r.h > 30);
        for (pretty.geometry.?.widths.items) |used| try check(@src(), used <= pretty.geometry.?.config.wrap_width + 0.1);
        if (width == 640 and scale == 1) try capture(ui, app, sw, snapshot, if (theme == c.CUI_THEME_DARK) "wrap-dark" else "wrap-light");
    };
    // Cross-check Unicode checkpoint boundaries, native advances and hit tests
    // including tabs and CRLF using enough bytes to cross several checkpoints.
    var mixed: std.ArrayList(u8) = .empty;
    defer mixed.deinit(app.gpa);
    for (0..20) |_| try mixed.appendSlice(app.gpa, phrase);
    try mixed.appendSlice(app.gpa, "\r\nsecond line\r\n");
    try fixture(app, t, "text/plain", mixed.items);
    t.response.wrap_response = false;
    t.response.pane = .raw;
    try settle(ui, app, frame);
    const geometry = &s.geometry.?;
    for (geometry.starts.items) |pos| {
        if (pos < mixed.items.len) try check(@src(), mixed.items[pos] & 0xc0 != 0x80);
        const row = s.index.rowOf(pos);
        const b = s.index.bounds(mixed.items, row);
        const x = geometry.position(&s.index, mixed.items, row, pos, text_ui.metrics(ui));
        try check(@src(), @abs(x - editor.advance(ui, mixed.items[b[0]..pos], editor.cellWidth(ui))) < 0.2);
        try check(@src(), geometry.byteAt(&s.index, mixed.items, row, x, text_ui.metrics(ui)) == pos);
    }
    try check(@src(), s.index.count() == 3 and std.mem.eql(u8, mixed.items, t.shown.?.resp.preview.items));
    focus(ui, t, "raw-view");
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, mixed.items, std.mem.sliceTo(&clipboard, 0)));
    // A derived buffer remains pinned until a pending reflow is discarded.
    try fixture(app, t, "application/json", json.items);
    try settle(ui, app, frame);
    const source = t.shown.?;
    const owner = t.response.formatted_owner.?;
    source.retain();
    owner.retain();
    t.response.wrap_response = true;
    c.cui_set_viewport(ui, 700, 832, 1);
    frame(ui, app);
    try check(@src(), t.response.code_pretty.layout_job != null);
    commands.clearResponse(t);
    try app.response_preparation.group.await(app.io);
    try check(@src(), source.refs.load(.acquire) == 1 and owner.refs.load(.acquire) == 1 and t.response.code_pretty.geometry == null);
    source.destroy();
    owner.release();
    try check(@src(), t.response.wrap_response); // preference survives clear
    std.debug.print("CUI response text: 4 MiB true lines, distant selection/copy, wheel/Shift/trackpad and draggable scrollbars, wrap/reflow anchors, Page keys, UTF-8/tabs/CRLF, independent views, themes/scales and pending-clear ownership passed\n", .{});
}
