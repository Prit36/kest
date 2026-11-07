//! Raw body editing through the actual CUI canvas and request persistence.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Env = @import("app/state.zig").Env;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const code = @import("ui/code_state.zig");
const editor = @import("ui/editor.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Body editor regression at {s}:{d}\n", .{ src.file, src.line });
        return error.BodyEditorRegression;
    }
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("Body editor text at {s}:{d}: wanted {s}, got {s}\n", .{ src.file, src.line, want, got });
        return error.BodyEditorRegression;
    }
}
fn rect(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn focus(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.kest_focus(ui, key);
}
fn tap(ui: *c.cui_ctx, app: *App, t: *tab.Tab, key: [*:0]const u8, comptime click: anytype) !void {
    const r = rect(ui, t, key);
    if (r.w <= 0 or r.h <= 0) std.debug.print("Missing body control {s}\n", .{key});
    try check(@src(), r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-body-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
var clipboard: [32768:0]u8 = @splat(0);
fn getClipboard(_: ?*anyopaque) callconv(.c) [*c]const u8 {
    return &clipboard;
}
fn setClipboard(_: ?*anyopaque, value: [*c]const u8) callconv(.c) void {
    const text = std.mem.span(value);
    const len = @min(text.len, clipboard.len);
    @memcpy(clipboard[0..len], text[0..len]);
    clipboard[len] = 0;
}
fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}
fn wait(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.RequestTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}

fn model(app: *App) !void {
    var state = code.State.init(app.gpa);
    defer state.deinit();
    state.setText("one\n  two\nthree\n");
    state.caret = 10;
    state.anchor = 0;
    state.indent(false);
    try equal(@src(), "  one\n    two\nthree\n", state.text());
    try check(@src(), state.caret == 14 and state.anchor == 2);
    try check(@src(), state.undoEdit());
    try equal(@src(), "one\n  two\nthree\n", state.text());
    try check(@src(), state.caret == 10 and state.anchor == 0);
    try check(@src(), state.redoEdit() and state.caret == 14 and state.anchor == 2);
    state.indent(true);
    try equal(@src(), "one\n  two\nthree\n", state.text());
    state.setText("\talpha\n beta");
    state.caret = state.text().len;
    state.anchor = 0;
    state.indent(true);
    try equal(@src(), "alpha\nbeta", state.text());
    state.setText("  {}\r\n");
    state.moveTo(3, false);
    state.newline(state.text(), state.caret);
    try equal(@src(), "  {\r\n    \r\n  }\r\n", state.text());
    try check(@src(), state.caret == 9 and state.undoEdit());
    try equal(@src(), "  {}\r\n", state.text());
    state.setText("one\r\ntwo");
    state.moveTo(5, false);
    _ = state.command(.delete_backward, state.text(), false);
    try equal(@src(), "onetwo", state.text());
    try check(@src(), state.undoEdit());
    state.moveTo(3, false);
    _ = state.command(.delete_forward, state.text(), false);
    try equal(@src(), "onetwo", state.text());
    try check(@src(), state.undoEdit());
    state.caret = state.text().len;
    state.anchor = 0;
    state.indent(false);
    try equal(@src(), "  one\r\n  two", state.text());
    state.indent(true);
    try equal(@src(), "one\r\ntwo", state.text());
    // Failed undo-record allocations must not apply an un-undoable edit.
    var succeeded = false;
    for (0..16) |offset| {
        var fault = std.testing.FailingAllocator.init(app.gpa, .{});
        {
            var probe = code.State.init(fault.allocator());
            defer probe.deinit();
            probe.setText("keep this draft");
            probe.moveTo(5, false);
            fault.fail_index = fault.alloc_index + offset;
            fault.resize_fail_index = fault.resize_index;
            probe.replaceSelection("changed", false);
            if (fault.has_induced_failure) {
                try equal(@src(), "keep this draft", probe.text());
                try check(@src(), probe.caret == 5 and probe.undo.items.len == 0);
            } else {
                try equal(@src(), "keep changedthis draft", probe.text());
                succeeded = true;
            }
        }
        try check(@src(), fault.allocated_bytes == fault.freed_bytes);
        if (succeeded) break;
    }
    try check(@src(), succeeded);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    try model(app);
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_selected = app.selected;
    app.tabs = .empty;
    app.active = 0;
    app.selected = null;
    var env: Env = .{ .id = @splat('b'), .name = @constCast("Body environment"), .table = .init(app.gpa) };
    defer env.table.deinit();
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        app.active_env = old_env;
        app.selected = old_selected;
        app.vars_dirty = true;
        c.cui_set_platform(ui, &.{});
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    commands.setActiveEnv(app, null);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.url.set("https://example.invalid/body");
    t.method.set("POST");
    t.pane = .body;
    t.pane_chosen = true;
    t.body_kind = .json;
    c.cui_set_viewport(ui, 640, 420, 1);
    t.body.setText("{}");
    for (0..4) |_| frame(ui, app);
    t.body.moveTo(1, false);
    focus(ui, t, "body-editor");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "{\n  \n}", t.body.text());
    try check(@src(), t.body.caret == 4);
    chord(ui, app, c.CUI_KEY_TAB, 0);
    try equal(@src(), "{\n    \n}", t.body.text());
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_SHIFT);
    try equal(@src(), "{\n  \n}", t.body.text());
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try equal(@src(), "{\n    \n}", t.body.text());
    chord(ui, app, c.CUI_KEY_Y, c.CUI_MOD_PRIMARY);
    try equal(@src(), "{\n  \n}", t.body.text());
    // Opt-out releases native Tab focus traversal without changing the draft.
    chord(ui, app, c.CUI_KEY_M, c.CUI_MOD_PRIMARY);
    try check(@src(), t.body.tab_moves_focus);
    chord(ui, app, c.CUI_KEY_TAB, 0);
    c.cui_push_id_int(ui, @intCast(t.uid));
    const editor_id = c.cui_make_id(ui, "body-editor");
    c.cui_pop_id(ui);
    try check(@src(), c.kest_editor_focus(ui, editor_id) == 0);
    t.body.tab_moves_focus = false;
    // Native clipboard interface is replaced with a memory-only test adapter.
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    t.body_kind = .text;
    t.body.setText("a\u{e9}\u{1f642}z\nshort\na\u{e9}\u{1f642}z");
    focus(ui, t, "body-editor");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try equal(@src(), t.body.text(), std.mem.sliceTo(&clipboard, 0));
    chord(ui, app, c.CUI_KEY_X, c.CUI_MOD_PRIMARY);
    try equal(@src(), "", t.body.text());
    chord(ui, app, c.CUI_KEY_V, c.CUI_MOD_PRIMARY);
    try equal(@src(), "a\u{e9}\u{1f642}z\nshort\na\u{e9}\u{1f642}z", t.body.text());
    t.body.moveTo(7, false);
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    try check(@src(), t.body.caret == 22);
    chord(ui, app, c.CUI_KEY_LEFT, 0);
    try check(@src(), t.body.caret == 18);
    const char_w = c.cui_measure_text(ui, c.CUI_FONT_MONO, 13, "M", 1).width;
    const sample = "a\u{e9}\u{1f642}z";
    for ([_]usize{ 0, 1, 3, 7, 8 }) |at| try check(@src(), editor.byteAt(ui, sample, editor.advance(ui, sample[0..at], char_w), char_w) == at);
    const canvas = rect(ui, t, "body-editor");
    const gutter = @round(c.cui_measure_text(ui, c.CUI_FONT_MONO, 12, "00", 2).width + 20);
    click(ui, app, canvas.x + gutter + 12 + editor.advance(ui, sample[0..3], char_w), canvas.y + 12);
    try check(@src(), t.body.caret == 3);
    // Kind and environment changes invalidate JSON diagnostics without edits.
    t.body_kind = .text;
    t.body.setText("{bad");
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_text.len == 0);
    t.body_kind = .json;
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_text.len > 0 and t.body_problem_at != null);
    const bad_version = t.body.version;
    commands.formatBody(app, t, 2);
    try check(@src(), t.body.version == bad_version);
    try equal(@src(), "{bad", t.body.text());
    t.body.setText("{\"value\":{{value}}}");
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_pending);
    const value = try env.table.add(.{ .key = "value", .value = "true" });
    commands.setActiveEnv(app, &env);
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_text.len == 0);
    value.value.set("SECRET_INVALID_TOKEN");
    app.vars_dirty = true;
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_text.len > 0 and !t.body_problem_pending and t.body_problem_at == null);
    try check(@src(), std.mem.indexOf(u8, t.body_problem_text, "SECRET") == null);
    commands.setActiveEnv(app, null);
    t.body.setText("{\"literal\":\"{{\",\"bad\":}");
    commands.bodyProblem(app, t);
    try check(@src(), t.body_problem_text.len > 0 and !t.body_problem_pending);
    // Format is one undoable edit and retains numbers/string spelling.
    t.body.setText("{\"exact\":1.10,\"escaped\":\"\\u0061\"}");
    t.body.moveTo(4, false);
    commands.formatBody(app, t, 2);
    try check(@src(), std.mem.indexOf(u8, t.body.text(), "1.10") != null);
    try check(@src(), t.body.undoEdit() and t.body.caret == 4);
    try equal(@src(), "{\"exact\":1.10,\"escaped\":\"\\u0061\"}", t.body.text());
    // Wrap never changes bytes, dirty state, caret or undo history when resized.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(app.gpa);
    try long.appendSlice(app.gpa, "{\n  \"message\": \"");
    for (0..70) |_| try long.appendSlice(app.gpa, "long words \u{e9} ");
    try long.appendSlice(app.gpa, "\",\n  \"values\": [1, 2, 3]\n}");
    t.body.setText(long.items);
    t.body.moveTo(1, false);
    focus(ui, t, "body-editor");
    for (0..3) |_| frame(ui, app);
    if (snapshot != null) for (0..540) |_| frame(ui, app);
    const dirty = t.dirty;
    try tap(ui, app, t, "wrap-body", click);
    try check(@src(), t.body.word_wrap and t.dirty == dirty and t.body.undo.items.len == 0);
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
        app.prefs.dark = dark;
        c.cui_set_viewport(ui, width, 832, scale);
        for (0..3) |_| frame(ui, app);
        const toolbar = rect(ui, t, "body-toolbar");
        const body_rect = rect(ui, t, "body-editor");
        const wrap = rect(ui, t, "wrap-body");
        const format = rect(ui, t, "format-body");
        const find = rect(ui, t, "find-body");
        const actions = rect(ui, t, "body-actions");
        try check(@src(), toolbar.h == 36 and body_rect.w > 250 and body_rect.h > 32);
        try check(@src(), format.x + format.w <= wrap.x + 1 and wrap.x + wrap.w <= find.x + 1);
        if (format.w > 28) try check(@src(), c.cui_measure_text(ui, c.CUI_FONT_BODY, 12, "Format", 6).width + 42 <= format.w);
        try check(@src(), find.x + find.w <= actions.x + 1 and actions.x + actions.w <= toolbar.x + toolbar.w and toolbar.x + toolbar.w <= width);
        try equal(@src(), long.items, t.body.text());
        try check(@src(), t.body.caret == 1 and t.body.undo.items.len == 0 and t.body.scroll_x == 0);
    };
    app.prefs.dark = true;
    c.cui_set_viewport(ui, 640, 420, 1);
    focus(ui, t, "body-editor");
    for (0..4) |_| frame(ui, app);
    try check(@src(), t.body.marked != null);
    try capture(ui, sw, app, snapshot, "wrap-compact");
    app.prefs.dark = false;
    for (0..3) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "wrap-light");
    // An open body menu covers the canvas, so text cannot leak into the draft.
    try tap(ui, app, t, "body-actions", click);
    focus(ui, t, "body-editor");
    c.cui_input_text(ui, "must not leak");
    frame(ui, app);
    try equal(@src(), long.items, t.body.text());
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    for (0..3) |_| frame(ui, app);
    t.body.word_wrap = false;
    t.body.setText("{\n  \"keep_invalid_draft\": [1, 2,\n}");
    t.file_path.set("retained-file.bin");
    _ = try t.form.add(.{ .key = "retained", .value = "form value" });
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "invalid");
    try tap(ui, app, t, "body-problem-location", click);
    try check(@src(), t.body.caret == t.body_problem_at.?);
    try check(@src(), rect(ui, t, "body-editor").h >= 32);
    try check(@src(), c.cui_measure_text(ui, c.CUI_FONT_BODY, 12, "Go to", 5).width + 20 <= rect(ui, t, "body-problem-location").w);
    const invalid = try app.gpa.dupe(u8, t.body.text());
    defer app.gpa.free(invalid);
    // Temporary content/document navigation retains the invalid editor state.
    try tap(ui, app, t, "pane-params", click);
    try tap(ui, app, t, "pane-body", click);
    const other = commands.newTab(app) orelse return error.AllocationFailed;
    frame(ui, app);
    commands.closeNow(app, other);
    for (0..3) |_| frame(ui, app);
    try equal(@src(), invalid, t.body.text());
    // Validation is advisory: the exact invalid draft remains sendable, and
    // soft wrap never alters the bytes or JSON content type on the wire.
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    t.url.set(try server.url(w.arena.allocator(), "/echo"));
    t.body.word_wrap = true;
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    const echo = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.endsWith(u8, echo, invalid) and std.mem.indexOf(u8, echo, "Content-Type: application/json") != null);
    persist.touchTab(app, t);
    persist.flush(app);
    persist.savePrefs(app);
    app.store.sync();
    {
        var restored = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
        defer restored.deinit();
        try persist.load(&restored);
        const loaded = restored.current() orelse return error.MissingDraft;
        try equal(@src(), invalid, loaded.body.text());
        try check(@src(), loaded.body_kind == .json and loaded.pane == .body);
        try equal(@src(), "retained-file.bin", loaded.file_path.text());
        try check(@src(), loaded.form.rows.items.len == 1);
    }
    std.debug.print("CUI body editor: indentation/CRLF/undo, native Tab/clipboard, UTF-8 caret, current JSON validation, wrap/resize, covered input and invalid draft reload passed\n", .{});
}
