//! Feel and feedback: the app's Edit menu, toast buttons and the hover cards
//! on a response's status, time and size.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const shell = @import("ui/shell.zig");
const editor = @import("ui/editor.zig");
const chrome = @import("ui/response_chrome.zig");
const Job = @import("network/http_client.zig").Job;

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (ok) return;
    std.debug.print("Feedback at {s}:{d}\n", .{ src.file, src.line });
    return error.FeedbackRegression;
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print("Feedback at {s}:{d}: wanted \"{s}\", got \"{s}\"\n", .{ src.file, src.line, want, got });
    return error.FeedbackRegression;
}

var clipboard: [4096:0]u8 = @splat(0);
fn getClipboard(_: ?*anyopaque) callconv(.c) [*c]const u8 {
    return &clipboard;
}
fn setClipboard(_: ?*anyopaque, value: [*c]const u8) callconv(.c) void {
    const text = std.mem.span(value);
    const len = @min(text.len, clipboard.len);
    @memcpy(clipboard[0..len], text[0..len]);
    clipboard[len] = 0;
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-feedback-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn noDone(_: ?*anyopaque, _: *Job) void {}

fn id(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_id {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_make_id(ui, key);
}
fn focus(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.kest_focus(ui, key);
    c.cui_pop_id(ui);
}
fn center(r: c.cui_rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}
fn editItem(ui: *c.cui_ctx, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @bitCast(shell.edit_button ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
/// Opens the Edit menu with the pointer and chooses `label`.
fn choose(ui: *c.cui_ctx, app: *App, label: [*:0]const u8, comptime frame: anytype, comptime click: anytype) !void {
    const button = center(c.cui_get_rect(ui, shell.edit_button));
    click(ui, app, button[0], button[1]);
    for (0..10) |_| frame(ui, app);
    const item = editItem(ui, label);
    try check(@src(), item.w > 0);
    const at = center(item);
    click(ui, app, at[0], at[1]);
    for (0..4) |_| frame(ui, app);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype) !void {
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    defer c.cui_set_platform(ui, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    c.cui_set_viewport(ui, 1100, 700, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..3) |_| frame(ui, app);

    // The Edit menu acts on the field focused last, though opening it moves
    // focus to its button.
    const url_id = id(ui, t, "url");
    t.url.set("https://feedback.invalid/a");
    t.url.focus();
    for (0..3) |_| frame(ui, app);
    try check(@src(), c.kest_edit_target == url_id);
    try choose(ui, app, "Select all", frame, click);
    try choose(ui, app, "Cut", frame, click);
    try equal(@src(), "", t.url.text());
    try equal(@src(), "https://feedback.invalid/a", std.mem.span(@as([*:0]const u8, &clipboard)));
    try check(@src(), c.kest_get_focus(ui) == url_id);
    try choose(ui, app, "Paste", frame, click);
    try equal(@src(), "https://feedback.invalid/a", t.url.text());
    try choose(ui, app, "Undo", frame, click);
    try equal(@src(), "", t.url.text());

    // The body editor too.
    t.pane = .body;
    t.body_kind = .json;
    t.method.set("POST");
    t.body.setText("{\"k\": 1}");
    for (0..3) |_| frame(ui, app);
    focus(ui, t, "body-editor");
    for (0..3) |_| frame(ui, app);
    try check(@src(), c.kest_edit_target == id(ui, t, "body-editor") and editor.edit_target != null);
    try choose(ui, app, "Select all", frame, click);
    try choose(ui, app, "Copy", frame, click);
    try equal(@src(), "{\"k\": 1}", std.mem.span(@as([*:0]const u8, &clipboard)));
    try choose(ui, app, "Delete", frame, click);
    try equal(@src(), "", t.body.text());
    try choose(ui, app, "Undo", frame, click);
    try equal(@src(), "{\"k\": 1}", t.body.text());
    try check(@src(), c.kest_get_focus(ui) == id(ui, t, "body-editor"));

    // Focus elsewhere: the menu has nothing to act on, and says so.
    c.kest_focus(ui, "nothing-here");
    for (0..3) |_| frame(ui, app);
    try check(@src(), c.kest_edit_target == 0);
    const button = center(c.cui_get_rect(ui, shell.edit_button));
    click(ui, app, button[0], button[1]);
    for (0..10) |_| frame(ui, app);
    try check(@src(), editItem(ui, "Copy").w > 0);
    try capture(ui, sw, app, snapshot, "edit-menu");
    c.cui_input_key(ui, c.CUI_KEY_ESCAPE, true, 0);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_ESCAPE, false, 0);
    for (0..10) |_| frame(ui, app);

    // Toast buttons: Reopen brings closed tabs back; Open switches tabs; a
    // path a toast holds is its own copy.
    const second = commands.newTab(app) orelse return error.AllocationFailed;
    const third = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..3) |_| frame(ui, app);
    commands.closeNow(app, third);
    commands.closeNow(app, second);
    try check(@src(), app.tabs.items.len == 1);
    shell.runToastAction(app, .{ .reopen = 2 });
    try check(@src(), app.tabs.items.len == 3);
    shell.runToastAction(app, .{ .open = t.uid });
    try check(@src(), app.current() == t);
    {
        var path = "C:/feedback/saved.json".*;
        app.toastAction(.info, "Export queued", "saved.json", .{ .show = &path });
        path[0] = 'X';
        frame(ui, app);
        const live = app.toaster.live.items;
        try check(@src(), live.len > 0 and live[live.len - 1].action == .show);
        try equal(@src(), "C:/feedback/saved.json", live[live.len - 1].action.show);
    }
    app.toastAction(.danger, "Not sent", "", .{ .retry = t.uid });
    frame(ui, app);
    try check(@src(), app.toaster.live.items[app.toaster.live.items.len - 1].action == .retry);

    // Hover cards: resting on the status, time or size opens what each means.
    t.pane = .headers;
    const job = try app.gpa.create(Job);
    job.* = .{ .gpa = app.gpa, .io = app.io, .client = app.client, .arena = .init(app.gpa), .out = .{ .method = "GET", .url = "https://feedback.invalid/x" }, .unresolved = &.{}, .resp = .init(app.gpa, app.io, app.tmp_dir), .callbacks = .{ .on_done = noDone }, .timeout_ms = 1000, .start_ms = std.Io.Clock.awake.now(app.io).toMilliseconds() };
    try job.resp.onHead(.{ .status = 429, .reason = "Too Many Requests", .raw_headers = "Content-Type: text/plain\r\nRetry-After: 30\r\n", .url = job.out.url, .redirects = 0 });
    try job.resp.onData("slow down");
    job.resp.time_ms = 87;
    job.resp.timing_known = true;
    job.resp.reused_connection = true;
    commands.clearResponse(t);
    t.shown = job;
    for (0..5) |_| frame(ui, app);
    const keys = [_][*:0]const u8{ "response-status", "response-duration", "response-size" };
    for (keys, 0..) |key, i| {
        const r = c.cui_get_rect(ui, id(ui, t, key));
        try check(@src(), r.w > 0);
        c.cui_input_mouse_move(ui, r.x + r.w / 2, r.y + r.h / 2);
        var opened = false;
        for (0..80) |_| {
            frame(ui, app);
            if (chrome.cards_open & (@as(u8, 1) << @intCast(i)) != 0) {
                opened = true;
                break;
            }
        }
        try check(@src(), opened);
        for (0..20) |_| frame(ui, app);
        try capture(ui, sw, app, snapshot, std.mem.span(keys[i])[9..]);
        c.cui_input_mouse_move(ui, 2, 690);
        for (0..60) |_| frame(ui, app);
    }
    try equal(@src(), "Too many requests; wait before retrying, as Retry-After may say.", @import("core/response_status.zig").explain(429));
    std.debug.print("CUI feedback: Edit menu on fields and the body editor, toast Reopen/Open/Retry/Show, status/time/size hover cards passed\n", .{});
}
