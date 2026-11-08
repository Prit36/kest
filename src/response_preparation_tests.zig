//! Real CUI with bounded worker tasks. No native input, clipboard, or dialogs.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Tab = @import("app/tab.zig").Tab;
const HttpJob = @import("network/http_client.zig").Job;
const commands = @import("app/commands.zig");
const prep = @import("app/response_prepare.zig");
const fixtures = @import("response_fixtures");
const settle = @import("response_test_support.zig").settle;

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Response preparation regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ResponsePreparationRegression;
    }
}
fn noDone(_: ?*anyopaque, _: *HttpJob) void {}
pub fn fixture(app: *App, t: *Tab, mime: []const u8, source: []const u8) !void {
    commands.clearResponse(t);
    const job = try app.gpa.create(HttpJob);
    job.* = .{ .gpa = app.gpa, .io = app.io, .client = app.client, .arena = .init(app.gpa), .out = .{ .method = "GET", .url = "https://response.invalid/fixture" }, .unresolved = &.{}, .resp = .init(app.gpa, app.io, app.tmp_dir), .callbacks = .{ .on_done = noDone }, .timeout_ms = 0 };
    errdefer job.destroy();
    const headers = try std.fmt.allocPrint(job.arena.allocator(), "Content-Type: {s}\r\n", .{mime});
    try job.resp.onHead(.{ .status = 200, .reason = "OK", .raw_headers = headers, .url = job.out.url, .redirects = 0 });
    try job.resp.onData(source);
    job.resp.inspectContent();
    t.shown = job;
    t.response.pane = .pretty;
    t.response.body_pane = .pretty;
    t.response.pretty_mode = .text;
    t.url.set(job.out.url);
}
fn rect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn capture(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-preparation-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.wake();
}
const Gate = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    fn decode(ctx: ?*anyopaque, _: []const u8) prep.Decoded {
        const gate: *Gate = @ptrCast(@alignCast(ctx.?));
        gate.entered.set(gate.io);
        gate.proceed.wait(gate.io) catch {};
        return .{ .failure = .invalid };
    }
};

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype) !void {
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
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    @import("ui/workspace.zig").layout = .stacked;
    c.cui_set_viewport(ui, 640, 420, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    // Earlier notification regressions leave native toasts alive. Move clear
    // of their hover-pause area before advancing diagnostic capture time.
    if (snapshot != null) {
        c.cui_input_mouse_move(ui, -20, -20);
        for (0..540) |_| frame(ui, app);
    }
    try fixture(app, t, "application/json", "{\"n\":1.10}");
    // Fill both worker slots with deterministic, genuinely running tasks. The
    // UI must still accept input and navigation while its own task is waiting.
    var gate: Gate = .{ .io = app.io };
    {
        defer gate.proceed.set(app.io);
        const one = try app.response_preparation.start(t.shown.?, .image, .{ .ctx = &gate, .decode = Gate.decode }, .{ .ctx = app, .call = wake });
        defer one.abandon();
        const two = try app.response_preparation.start(t.shown.?, .image, .{ .ctx = &gate, .decode = Gate.decode }, .{ .ctx = app, .call = wake });
        defer two.abandon();
        try gate.entered.wait(app.io);
        for (0..4) |_| frame(ui, app);
        try check(@src(), t.response.preparation == null and t.response.formatted == null and rect(ui, t, "response-content-notice").h > 0);
        const url = rect(ui, t, "url");
        click(ui, app, url.x + 40, url.y + url.h / 2);
        c.cui_input_text(ui, "responsive");
        frame(ui, app);
        try check(@src(), std.mem.indexOf(u8, t.url.text(), "responsive") != null);
        t.url.set("https://response.invalid/while-preparing");
        // Validation feedback changes composer height; use current geometry
        // after the programmatic correction before clicking the pane tab.
        for (0..3) |_| frame(ui, app);
        const headers = rect(ui, t, "response-headers");
        click(ui, app, headers.x + headers.w / 2, headers.y + headers.h / 2);
        try check(@src(), t.response.pane == .headers);
        t.response.pane = .pretty;
        frame(ui, app);
        try capture(ui, app, sw, snapshot, "waiting");
    }
    try settle(ui, app, frame);
    try check(@src(), t.response.formatted != null and std.mem.indexOf(u8, t.response.formatted.?, "1.10") != null);
    try app.response_preparation.group.await(app.io);
    // A 4 MiB string crosses many virtual rows. Adopt exactly the worker's row
    // index and continuation spans; do not rebuild them on the UI thread.
    const blob = try app.gpa.alloc(u8, 4 * 1024 * 1024);
    defer app.gpa.free(blob);
    @memset(blob, 'a');
    @memcpy(blob[0..9], "{\"blob\":\"");
    const tail = "\",\"n\":1.10}";
    @memcpy(blob[blob.len - tail.len ..], tail);
    try fixture(app, t, "application/json", blob);
    const before = app.response_preparation.started;
    frame(ui, app);
    const task = t.response.preparation.?;
    const start = std.Io.Clock.awake.now(app.io).toMilliseconds();
    while (!task.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start > 10000) return error.PreparationTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
    try check(@src(), task.result == .text);
    const worker_rows = task.result.text.index.starts.items.ptr;
    const worker_spans = task.result.text.strings.items.ptr;
    frame(ui, app);
    try check(@src(), t.response.preparation == null and t.response.formatted != null);
    try check(@src(), t.response.code_pretty.index.starts.items.ptr == worker_rows and t.response.code_pretty.continued_strings.items.ptr == worker_spans);
    try check(@src(), t.response.code_pretty.syntax_generation == t.response.code_pretty.index_generation);
    try settle(ui, app, frame);
    try check(@src(), t.response.code_pretty.geometry != null);
    const spatial_rows = t.response.code_pretty.index.starts.items.ptr;
    const settled_count = app.response_preparation.started;
    // Format + a raw fallback index + spatial geometry, each on workers.
    try check(@src(), settled_count >= before + 2 and settled_count <= before + 3);
    for (0..20) |_| frame(ui, app);
    try check(@src(), app.response_preparation.started == settled_count and t.response.code_pretty.index.starts.items.ptr == spatial_rows);
    // Leaving a mode and clearing/closing drop worker interests immediately;
    // completions cannot overwrite a newer view or leave the source pinned.
    t.response.pretty_mode = .minified;
    frame(ui, app);
    try check(@src(), t.response.preparation != null);
    t.response.pane = .raw;
    frame(ui, app);
    try settle(ui, app, frame);
    try app.response_preparation.group.await(app.io);
    try check(@src(), t.response.preparation == null and t.response.formatted_mode == .text and t.shown.?.refs.load(.acquire) == 1);
    t.response.pane = .pretty;
    frame(ui, app);
    const pinned = t.shown.?;
    pinned.retain();
    commands.clearResponse(t);
    try app.response_preparation.group.await(app.io);
    try check(@src(), pinned.refs.load(.acquire) == 1 and t.response.formatted == null and t.response.code_pretty.index.count() == 0);
    pinned.destroy();
    const closing = commands.newTab(app) orelse return error.AllocationFailed;
    try fixture(app, closing, "application/json", blob);
    frame(ui, app);
    const closing_source = closing.shown.?;
    closing_source.retain();
    commands.closeNow(app, closing);
    try app.response_preparation.group.await(app.io);
    try check(@src(), closing_source.refs.load(.acquire) == 1);
    closing_source.destroy();
    // The failure is a bounded fallback, without a repeat attempt every frame.
    var deep: [7001]u8 = undefined;
    @memset(deep[0..3500], '[');
    deep[3500] = '0';
    @memset(deep[3501..], ']');
    try fixture(app, t, "application/json", &deep);
    try settle(ui, app, frame);
    try check(@src(), t.response.preparation_failure == .output_limit and t.response.formatted == null);
    const failed_count = app.response_preparation.started;
    for (0..5) |_| frame(ui, app);
    try check(@src(), app.response_preparation.started == failed_count);
    try capture(ui, app, sw, snapshot, "format-limit");
    const nodes = try app.gpa.alloc(u8, prep.max_nodes * 2 + 3);
    defer app.gpa.free(nodes);
    nodes[0] = '[';
    for (0..prep.max_nodes) |i| @memcpy(nodes[1 + i * 2 ..][0..2], "0,");
    @memcpy(nodes[nodes.len - 2 ..], "0]");
    try fixture(app, t, "application/json", nodes);
    t.response.pretty_mode = .tree;
    try settle(ui, app, frame);
    try check(@src(), t.response.tree_failed and t.response.tree == null and t.response.formatted != null);
    try capture(ui, app, sw, snapshot, "tree-limit");
    try app.response_preparation.group.await(app.io);
    const many_rows = try app.gpa.alloc(u8, (prep.max_rows + 1) * 2);
    defer app.gpa.free(many_rows);
    for (0..prep.max_rows + 1) |i| @memcpy(many_rows[i * 2 ..][0..2], "x\n");
    try fixture(app, t, "text/plain", many_rows);
    frame(ui, app);
    try check(@src(), t.response.raw_index_job != null and t.response.code_pretty.layout_fallback.?.indexed_len == prep.inline_limit);
    try settle(ui, app, frame);
    try check(@src(), t.response.raw_index_failure == .index_limit and t.response.code_pretty.layout_fallback.?.indexed_len == prep.inline_limit);
    const indexed_attempts = app.response_preparation.started;
    for (0..5) |_| frame(ui, app);
    try check(@src(), app.response_preparation.started == indexed_attempts);
    try capture(ui, app, sw, snapshot, "row-limit");
    try app.response_preparation.group.await(app.io);
    @memset(blob, 'a');
    @memcpy(blob[0..3], "<p>");
    @memcpy(blob[blob.len - 4 ..], "</p>");
    try fixture(app, t, "text/html", blob);
    t.response.pane = .preview;
    frame(ui, app);
    try check(@src(), t.response.preparation != null and t.response.stripped == null);
    try settle(ui, app, frame);
    try check(@src(), t.response.stripped.?.len == blob.len - 5 and t.response.code_pretty.indexed_ptr == @intFromPtr(t.response.stripped.?.ptr));
    try check(@src(), std.mem.eql(u8, blob, t.shown.?.resp.preview.items));
    // Native decoder runs on workers; texture creation/destruction stays on UI.
    try fixture(app, t, "image/png", fixtures.large_png);
    t.response.pane = .preview;
    try settle(ui, app, frame);
    try check(@src(), t.response.image != 0 and t.response.image_source_width == 3000 and t.response.image_source_height == 1600);
    try check(@src(), t.response.image_width == 2048 and t.response.image_height == 1092);
    try check(@src(), std.mem.eql(u8, fixtures.large_png, t.shown.?.resp.preview.items));
    c.cui_set_viewport(ui, 1000, 800, 1);
    for (0..3) |_| frame(ui, app);
    try capture(ui, app, sw, snapshot, "scaled-image");
    try fixture(app, t, "image/png", fixtures.expansion_invalid);
    t.response.pane = .preview;
    try settle(ui, app, frame);
    try check(@src(), t.response.image == 0 and t.response.preparation_failure == .image_limit);
    try capture(ui, app, sw, snapshot, "image-limit");
    // Decode again after a failed expansion: worker reuse resets its budget.
    try fixture(app, t, "image/jpeg", fixtures.jpeg);
    t.response.pane = .preview;
    try settle(ui, app, frame);
    try check(@src(), t.response.image != 0 and t.response.image_width == 96 and t.response.image_height == 48);
    try fixture(app, t, "image/png", "\x89PNG\r\n\x1a\ninvalid");
    t.response.pane = .preview;
    try settle(ui, app, frame);
    try check(@src(), t.response.image == 0 and t.response.preparation_failure == .invalid);
    try fixture(app, t, "image/jpeg", fixtures.jpeg);
    t.shown.?.resp.stop = .canceled;
    t.response.pane = .preview;
    try settle(ui, app, frame);
    try check(@src(), t.response.image == 0 and t.response.preparation_failure == .incomplete);
    std.debug.print("CUI response preparation: busy-slot input/navigation, worker index adoption, 4 MiB strings/HTML, mode/clear/close ownership, output/node/row limits, scaled PNG/JPEG, compressed expansion and partial/corrupt images passed\n", .{});
}
