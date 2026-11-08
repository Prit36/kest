//! Response state/ownership regressions, using actual CUI and loopback jobs.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Tab = @import("app/tab.zig").Tab;
const Job = @import("network/http_client.zig").Job;
const commands = @import("app/commands.zig");
const chrome = @import("ui/response_chrome.zig");
const states = @import("core/response_status.zig");
const Response = @import("core/response.zig").Response;

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Response state regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ResponseStateRegression;
    }
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    try check(src, std.mem.eql(u8, want, got));
}
fn rect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn present(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) bool {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.kest_has_node(ui, c.cui_make_id(ui, key));
}
fn menu(ui: *c.cui_ctx, t: *Tab, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "Response actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn tap(src: std.builtin.SourceLocation, ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime click: anytype) !void {
    try check(src, r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-response-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}
fn noDone(_: ?*anyopaque, _: *Job) void {}
fn wait(ui: *c.cui_ctx, app: *App, t: *Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.ResponseTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}
fn fixture(app: *App, t: *Tab, status: u16, reason: []const u8, headers: []const u8, source: []const u8) !*Response {
    try check(@src(), !t.running());
    commands.clearResponse(t);
    const job = try app.gpa.create(Job);
    job.* = .{ .gpa = app.gpa, .io = app.io, .client = app.client, .arena = .init(app.gpa), .out = .{ .method = "GET", .url = "https://response.invalid/fixture" }, .unresolved = &.{}, .resp = .init(app.gpa, app.io, app.tmp_dir), .callbacks = .{ .on_done = noDone }, .timeout_ms = 1000, .start_ms = std.Io.Clock.awake.now(app.io).toMilliseconds() };
    errdefer job.destroy();
    if (status > 0) try job.resp.onHead(.{ .status = status, .reason = reason, .raw_headers = headers, .url = job.out.url, .redirects = 0 });
    try job.resp.onData(source);
    job.resp.time_ms = 1234;
    job.resp.timing_known = true;
    t.shown = job;
    t.response.pane = .pretty;
    t.response.body_pane = .pretty;
    t.response.pretty_mode = .text;
    return &job.resp;
}
fn outOfMemory(app: *App) !void {
    var fault = std.testing.FailingAllocator.init(app.gpa, .{});
    {
        var probe = App.init(fault.allocator(), app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
        defer probe.deinit();
        const t = commands.newTab(&probe) orelse return error.AllocationFailed;
        t.url.set("https://example.invalid/retained");
        fault.fail_index = fault.alloc_index;
        fault.resize_fail_index = fault.resize_index;
        commands.send(&probe, t);
        try check(@src(), t.start_failure == .memory and !t.running());
        try equal(@src(), "https://example.invalid/retained", t.url.text());
    }
    try check(@src(), fault.allocated_bytes == fault.freed_bytes);
}

fn contentDetection(ui: *c.cui_ctx, app: *App, t: *Tab, server: *@import("test_server").Server, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const cases = [_]struct { []const u8, response_class, bool }{
        .{ "malformed", .text, true },
        .{ "invalid-escape", .text, true },
        .{ "fragment", .text, false },
        .{ "scalar", .json, false },
        .{ "svg", .xml, false },
        .{ "binary-markdown", .binary, false },
        .{ "late-nul", .binary, false },
        .{ "late-invalid", .text, true },
    };
    for (cases) |case| {
        t.url.set(try server.url(w.arena.allocator(), w.fmt("/content/{s}", .{case[0]})));
        t.response.pane = .pretty;
        t.response.pretty_mode = .tree;
        commands.send(app, t);
        try wait(ui, app, t, frame);
        for (0..3) |_| frame(ui, app);
        const r = &t.shown.?.resp;
        try check(@src(), r.content_info != null and r.class() == case[1]);
        try check(@src(), present(ui, t, "response-content-notice") == case[2]);
        if (case[1] != .json) try check(@src(), t.response.tree == null and !t.response.format_attempted);
        if (case[1] == .binary) {
            try check(@src(), !present(ui, t, "response-preview") and !present(ui, t, "pretty-view") and t.response.code_pretty.indexed_len == 0);
        }
        if (std.mem.eql(u8, case[0], "malformed")) {
            const source = r.preview.items;
            try check(@src(), t.response.code_pretty.indexed_ptr == @intFromPtr(source.ptr));
            try tap(@src(), ui, app, rect(ui, t, "pretty-view"), click);
            chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
            try check(@src(), t.response.code_pretty.caret == source.len and t.response.code_pretty.anchor == 0);
            c.cui_input_text(ui, "must not replace a response");
            frame(ui, app);
            try equal(@src(), "{\"broken\":[1,]}", r.preview.items);
        }
        if (std.mem.eql(u8, case[0], "malformed") or std.mem.eql(u8, case[0], "fragment") or std.mem.eql(u8, case[0], "binary-markdown")) try capture(ui, sw, app, snapshot, case[0]);
    }
    // Mode choices only appear for a whole, valid document. The same complete
    // JSON prefix is intentionally not formatted when the rest is unavailable
    // in the viewer (the real worker/spill counterpart is covered by HTTP tests).
    const r = try fixture(app, t, 200, "OK", "Content-Type: application/json\r\n", "{}");
    r.total.store(200, .monotonic);
    r.inspectContent();
    t.response.pretty_mode = .tree;
    for (0..3) |_| frame(ui, app);
    try check(@src(), r.class() == .text and r.info().json_incomplete and present(ui, t, "response-content-notice"));
    try check(@src(), t.response.tree == null and !t.response.format_attempted);
    try capture(ui, sw, app, snapshot, "json-prefix");
    std.debug.print("CUI response content: worker classification, malformed/fragment/scalar JSON, original read-only selection, binary MIME override, late invalid bytes, SVG and incomplete preview passed\n", .{});
}

const response_class = @import("core/response.zig").ContentClass;
fn linear(channel: f64) f64 {
    const value = channel / 255;
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}
fn luminance(color: [3]f64) f64 {
    return 0.2126 * linear(color[0]) + 0.7152 * linear(color[1]) + 0.0722 * linear(color[2]);
}
fn contrast(fg: c.cui_color, bg: [3]f64) f64 {
    const a = luminance(.{ @floatFromInt(fg.r), @floatFromInt(fg.g), @floatFromInt(fg.b) });
    const b = luminance(bg);
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}
fn badgeContrast(ui: *c.cui_ctx) !void {
    const base = c.cui_token_color(ui, c.CUI_TOKEN_SURFACE);
    const hover = c.cui_token_color(ui, c.CUI_TOKEN_HOVER);
    for ([_]c_int{ c.CUI_TOKEN_FOREGROUND, c.CUI_TOKEN_SUCCESS, c.CUI_TOKEN_INFO, c.CUI_TOKEN_WARNING, c.CUI_TOKEN_DANGER }) |role| {
        const fg = c.cui_token_color(ui, @intCast(role));
        const tint = chrome.statusTint(ui, role);
        const alpha = @as(f64, @floatFromInt(tint.a)) / 255;
        const bg: [3]f64 = .{
            @as(f64, @floatFromInt(base.r)) * (1 - alpha) + @as(f64, @floatFromInt(tint.r)) * alpha,
            @as(f64, @floatFromInt(base.g)) * (1 - alpha) + @as(f64, @floatFromInt(tint.g)) * alpha,
            @as(f64, @floatFromInt(base.b)) * (1 - alpha) + @as(f64, @floatFromInt(tint.b)) * alpha,
        };
        try check(@src(), contrast(fg, bg) >= 4.5);
        try check(@src(), contrast(fg, .{ @floatFromInt(hover.r), @floatFromInt(hover.g), @floatFromInt(hover.b) }) >= 4.5);
    }
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    try outOfMemory(app);
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_selected = app.selected;
    const old_ratio = @import("ui/workspace.zig").column_ratio;
    app.tabs = .empty;
    app.active = 0;
    app.selected = null;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        app.active_env = old_env;
        app.selected = old_selected;
        app.vars_dirty = true;
        @import("ui/workspace.zig").column_ratio = old_ratio;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.method.set("GET");
    t.body_kind = .none;
    t.pane = .params;
    t.url.set("https://example.invalid/response");
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..4) |_| frame(ui, app);
    try check(@src(), chrome.summaryData(t) == null and !present(ui, t, "response-summary"));
    try capture(ui, sw, app, snapshot, "empty");
    // Metric source distinctions, valid zeros and status tone categories.
    var r = try fixture(app, t, 204, "No Content", "X-Probe: present\r\n", "");
    r.time_ms = 0;
    frame(ui, app);
    try equal(@src(), "0 ms", chrome.summaryData(t).?.duration);
    try equal(@src(), "0 B", chrome.summaryData(t).?.size);
    try check(@src(), !present(ui, t, "response-notice"));
    r.timing_known = false;
    frame(ui, app);
    try equal(@src(), "\u{2014}", chrome.summaryData(t).?.duration);
    try capture(ui, sw, app, snapshot, "no-content");
    for ([_]struct { u16, c_int }{ .{ 200, c.CUI_TOKEN_SUCCESS }, .{ 302, c.CUI_TOKEN_INFO }, .{ 404, c.CUI_TOKEN_WARNING }, .{ 503, c.CUI_TOKEN_DANGER }, .{ 700, c.CUI_TOKEN_FOREGROUND } }) |pair| {
        r.status = pair[0];
        try check(@src(), chrome.summaryData(t).?.token == pair[1]);
    }
    // Geometry: include three-tab HTML and extreme, legal header counts.
    for ([_]bool{ true, false }) |html| {
        r = try fixture(app, t, 503, "Service Unavailable", if (html) "Content-Type: text/html\r\n" else "Content-Type: application/json\r\n", if (html) "<html><body>Response body</body></html>" else "{\"response\":true}");
        for (0..1200) |_| try r.headers.append(app.gpa, .{ .name = "X-Count", .value = "value" });
        for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
            app.prefs.dark = dark;
            app.prefs.sidebar_open = true;
            app.prefs.sidebar_width = 320;
            @import("ui/workspace.zig").column_ratio = 0.85;
            c.cui_set_viewport(ui, width, if (width == 640) 420 else 832, scale);
            for (0..4) |_| frame(ui, app);
            if (scale == 1 and width == 640) try badgeContrast(ui);
            const nav = rect(ui, t, "response-navigation");
            const headers = rect(ui, t, "response-headers");
            const status = rect(ui, t, "response-status");
            const actions = rect(ui, t, "response-actions");
            try check(@src(), nav.w >= 359 and nav.h == 36);
            const tabs_end = if (html) rect(ui, t, "response-preview").x + rect(ui, t, "response-preview").w else headers.x + headers.w;
            try check(@src(), status.x >= tabs_end - 0.1 and status.x + status.w <= actions.x + 0.1);
            try check(@src(), actions.x + actions.w <= nav.x + nav.w + 0.1 and actions.h == 28);
            for ([_][*:0]const u8{ "response-status", "response-duration", "response-size", "###response-format", "response-actions" }) |key| if (present(ui, t, key)) {
                const item = rect(ui, t, key);
                try check(@src(), item.x >= tabs_end - 0.1 and item.x + item.w <= nav.x + nav.w + 0.1);
                try check(@src(), @abs((item.y + item.h / 2) - (nav.y + nav.h / 2)) < 1);
            };
        };
    }
    app.prefs.dark = true;
    app.prefs.sidebar_open = false;
    @import("ui/workspace.zig").column_ratio = old_ratio;
    c.cui_set_viewport(ui, 640, 420, 1);
    // Long reason phrases remain literal and fully available in bounded details.
    const reason = try app.gpa.alloc(u8, 2048);
    defer app.gpa.free(reason);
    @memset(reason, 'x');
    @memcpy(reason[0..10], "###literal");
    r = try fixture(app, t, 200, reason, "Content-Type: application/json\r\n", "{\"literal\":true}");
    for (0..4) |_| frame(ui, app);
    try equal(@src(), "200", chrome.summaryData(t).?.short);
    try tap(@src(), ui, app, rect(ui, t, "response-status"), click);
    for (0..3) |_| frame(ui, app);
    const details = rect(ui, t, "response-details");
    try check(@src(), details.w > 200 and details.x >= 0 and details.y >= 0 and details.x + details.w <= 640 and details.y + details.h <= 420);
    try capture(ui, sw, app, snapshot, "details");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    // Structured failure UI is non-modal and technical text is explicit.
    for ([_]@import("network/transport.zig").Failure{ .dns, .refused, .connection_lost, .tls_certificate, .tls_handshake, .file }) |failure| {
        r = try fixture(app, t, 0, "", "", "");
        r.stop = .failed;
        r.failure = failure;
        r.setError("Technical details: test endpoint failed without an HTTP response");
        for (0..4) |_| frame(ui, app);
        try check(@src(), present(ui, t, "response-notice") and !app.modal_open and !t.response.error_details_open);
        try tap(@src(), ui, app, rect(ui, t, "response-error-details"), click);
        try check(@src(), t.response.error_details_open);
        if (failure == .tls_certificate) try capture(ui, sw, app, snapshot, "certificate-details");
    }
    r = try fixture(app, t, 200, "OK", "Content-Type: text/plain\r\n", "available prefix");
    r.spill_failed = true;
    r.stop = .failed;
    for (0..3) |_| frame(ui, app);
    try equal(@src(), "Response storage failed", states.issue(r).?.title);
    try equal(@src(), "200 Partial", chrome.summaryData(t).?.short);
    try capture(ui, sw, app, snapshot, "storage-failed");
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    t.settings.timeout_ms = 3000;
    try contentDetection(ui, app, t, &server, sw, snapshot, frame, click, chord);
    t.url.set(try server.url(w.arena.allocator(), "/json"));
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200 and t.shown.?.resp.timing_known);
    const previous = t.shown.?;
    previous.retain();
    defer previous.destroy();
    previous.resp.time_ms = 54321;
    t.response.pane = .raw;
    t.response.code_raw.caret = 5;
    t.response.code_raw.anchor = 2;
    for (0..3) |_| frame(ui, app);
    const source_index = t.response.code_raw.index.starts.items.ptr;
    t.url.set(try server.url(w.arena.allocator(), "/hang"));
    commands.send(app, t);
    const active_job = t.job.?;
    commands.send(app, t);
    frame(ui, app);
    try check(@src(), t.job == active_job and t.shown == previous and present(ui, t, "response-previous"));
    try equal(@src(), "Sending", chrome.summaryData(t).?.short);
    try equal(@src(), "\u{2014}", chrome.summaryData(t).?.size);
    try check(@src(), t.response.code_raw.caret == 5 and t.response.code_raw.anchor == 2 and t.response.code_raw.index.starts.items.ptr == source_index);
    try capture(ui, sw, app, snapshot, "previous-sending");
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try wait(ui, app, t, frame);
    frame(ui, app);
    try check(@src(), t.shown != previous and t.shown.?.resp.stop == .canceled and !present(ui, t, "response-previous"));
    try check(@src(), previous.refs.load(.acquire) == 1 and std.mem.indexOf(u8, previous.resp.preview.items, "needle") != null);
    try equal(@src(), "Cancelled", chrome.summaryData(t).?.short);
    try check(@src(), chrome.summaryData(t).?.token == c.CUI_TOKEN_FOREGROUND and t.response.code_raw.caret == 0);
    try check(@src(), !present(ui, t, "###response-format"));
    try capture(ui, sw, app, snapshot, "cancelled");
    // Clear while a job runs releases only previous data, never the new job.
    t.url.set(try server.url(w.arena.allocator(), "/json"));
    commands.send(app, t);
    try wait(ui, app, t, frame);
    t.url.set(try server.url(w.arena.allocator(), "/hang"));
    commands.send(app, t);
    const clearing_job = t.job.?;
    commands.clearResponse(t);
    try check(@src(), t.job == clearing_job and t.shown == null);
    commands.cancel(t);
    try wait(ui, app, t, frame);
    // Timeout, incomplete HTTP response, HTTP errors and redirects use real jobs.
    t.settings.timeout_ms = 30;
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.stop == .timed_out and t.shown.?.resp.status == 0);
    frame(ui, app);
    try equal(@src(), "Timed out", chrome.summaryData(t).?.short);
    try capture(ui, sw, app, snapshot, "timeout");
    t.settings.timeout_ms = 3000;
    t.url.set(try server.url(w.arena.allocator(), "/stall"));
    commands.send(app, t);
    const stall_start = std.Io.Clock.awake.now(app.io);
    while (t.job != null and t.job.?.resp.total.load(.monotonic) < 4) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - stall_start.toMilliseconds() > 1500) return error.NoPartialBody;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
    commands.cancel(t);
    try wait(ui, app, t, frame);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.shown.?.resp.status == 200 and t.shown.?.resp.stop == .canceled);
    try equal(@src(), "half", t.shown.?.resp.preview.items);
    try equal(@src(), "200 Partial", chrome.summaryData(t).?.short);
    try check(@src(), chrome.summaryData(t).?.token == c.CUI_TOKEN_WARNING);
    try capture(ui, sw, app, snapshot, "partial");
    for ([_]u16{ 204, 302, 404, 503 }) |status| {
        t.settings.follow_redirects = false;
        t.url.set(try server.url(w.arena.allocator(), w.fmt("/status/{d}", .{status})));
        commands.send(app, t);
        try wait(ui, app, t, frame);
        for (0..3) |_| frame(ui, app);
        try check(@src(), t.shown.?.resp.status == status and t.shown.?.resp.stop == .complete and !present(ui, t, "response-notice"));
        if (status != 204) try equal(@src(), "status body", t.shown.?.resp.preview.items);
        if (status == 404) {
            try capture(ui, sw, app, snapshot, "http-client-error");
            app.prefs.dark = false;
            for (0..3) |_| frame(ui, app);
            try capture(ui, sw, app, snapshot, "http-client-error-light");
            app.prefs.dark = true;
        }
        if (status == 503) try capture(ui, sw, app, snapshot, "http-server-error");
    }
    // Preparation failure keeps the previous response but marks it previous.
    t.url.set("{{missing}}/path");
    const retained = t.shown.?;
    const before_notice = app.toaster.items.items.len;
    commands.send(app, t);
    try check(@src(), app.toaster.items.items.len == before_notice);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.start_failure == .url and !t.running() and t.shown == retained and present(ui, t, "response-previous"));
    try equal(@src(), "Not sent", chrome.summaryData(t).?.short);
    try capture(ui, sw, app, snapshot, "not-sent");
    // A hidden response panel still needs visible feedback for a failed start.
    t.response_collapsed = true;
    commands.send(app, t);
    try check(@src(), app.toaster.items.items.len == 1);
    t.response_collapsed = false;
    if (snapshot != null) for (0..540) |_| frame(ui, app);
    commands.clearResponse(t);
    t.url.set(try server.url(w.arena.allocator(), "/drop"));
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.status == 0 and t.shown.?.resp.stop == .failed and t.shown.?.resp.failure == .connection_lost);
    var closed: @import("test_server").Server = undefined;
    try closed.start(app.io);
    const refused_url = try closed.url(app.gpa, "/");
    defer app.gpa.free(refused_url);
    closed.stop();
    t.url.set(refused_url);
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.failure == .refused and t.shown.?.resp.status == 0);
    for (0..3) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "refused");
    // Narrow overflow retains body formats, with details accessible by status.
    r = try fixture(app, t, 200, "OK", "Content-Type: text/html\r\n", "<html><body>body</body></html>");
    app.prefs.sidebar_open = true;
    @import("ui/workspace.zig").column_ratio = 0.85;
    c.cui_set_viewport(ui, 1282, 832, 1);
    for (0..4) |_| frame(ui, app);
    try check(@src(), !present(ui, t, "###response-format"));
    try tap(@src(), ui, app, rect(ui, t, "response-actions"), click);
    try tap(@src(), ui, app, menu(ui, t, "Raw text"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.response.pane == .raw);
    try tap(@src(), ui, app, rect(ui, t, "response-headers"), click);
    try tap(@src(), ui, app, rect(ui, t, "response-body"), click);
    try check(@src(), t.response.pane == .raw);
    try capture(ui, sw, app, snapshot, "narrow-header");
    // Disappearing response menus must not block editing in another document.
    try tap(@src(), ui, app, rect(ui, t, "response-status"), click);
    const other = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..4) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    const still_open = c.cui_popover_is_open(ui, "response-details");
    c.cui_pop_id(ui);
    try check(@src(), !still_open);
    c.cui_push_id_int(ui, @intCast(other.uid));
    c.kest_focus(ui, "url");
    c.cui_pop_id(ui);
    c.cui_input_text(ui, "https://new.invalid");
    frame(ui, app);
    try check(@src(), std.mem.indexOf(u8, other.url.text(), "new.invalid") != null);
    commands.closeNow(app, other);
    // The longest contextual menu is bounded and reveals its final keyboard
    // item instead of clipping it below the viewport.
    const long_menu_tab = commands.newTab(app) orelse return error.AllocationFailed;
    r = try fixture(app, long_menu_tab, 200, "OK", "Content-Type: application/json\r\n", "{\"values\":[1,2,3]}");
    // A failed preparation retains this complete previous JSON body; the
    // wider Not sent badge also exercises format overflow on a narrow panel.
    long_menu_tab.start_failure = .memory;
    for (0..1200) |_| try r.headers.append(app.gpa, .{ .name = "X-Count", .value = "value" });
    long_menu_tab.response.pretty_mode = .tree;
    c.cui_set_viewport(ui, 1282, 420, 1);
    for (0..4) |_| frame(ui, app);
    try @import("response_test_support.zig").settle(ui, app, frame);
    try check(@src(), !present(ui, long_menu_tab, "###response-format"));
    try tap(@src(), ui, app, rect(ui, long_menu_tab, "response-actions"), click);
    // In a window this short the menu may open over the pointer; keep the
    // pointer off it so the keyboard starts from no highlighted item.
    c.cui_input_mouse_move(ui, -20, -20);
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(long_menu_tab.uid));
    const popup = c.cui_get_rect(ui, c.cui_make_id(ui, "Response actions") ^ 0x3e40);
    c.cui_pop_id(ui);
    try check(@src(), popup.y >= 0 and popup.y + popup.h <= 420);
    c.cui_input_mouse_move(ui, -20, -20);
    var last_visible = false;
    for (0..16) |_| {
        chord(ui, app, c.CUI_KEY_UP, 0);
        const viewport = menu(ui, long_menu_tab, "response-action-list");
        const last = menu(ui, long_menu_tab, "Clear response");
        if (last.y >= viewport.y and last.y + last.h <= viewport.y + viewport.h + 0.1) {
            last_visible = true;
            break;
        }
    }
    try check(@src(), last_visible);
    try capture(ui, sw, app, snapshot, "scrolling-actions");
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), long_menu_tab.shown == null);
    commands.closeNow(app, long_menu_tab);
    std.debug.print("CUI response states: adaptive metadata/overflow, missing versus zero metrics, previous-response ownership, HTTP/transport/partial/preflight outcomes, error disclosure and popup cleanup passed\n", .{});
}
