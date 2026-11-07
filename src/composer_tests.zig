//! Request execution-row regressions with real CUI events and loopback HTTP.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const state = @import("app/state.zig");
const App = state.App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const composer = @import("ui/composer.zig");

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Composer regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ComposerRegression;
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
fn popupBounds(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8, suffix: u32) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key) ^ suffix);
}
fn tap(ui: *c.cui_ctx, app: *App, t: *tab.Tab, key: [*:0]const u8, comptime click: anytype) !void {
    const r = rect(ui, t, key);
    try check(@src(), r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-composer-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn wait(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.RequestTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const original_tabs = app.tabs;
    const original_active = app.active;
    const original_prefs = app.prefs;
    const original_env = app.active_env;
    const original_selected = app.selected;
    app.tabs = .empty;
    app.active = 0;
    var environment: state.Env = .{ .id = @splat('c'), .name = @constCast("Composer environment"), .table = .init(app.gpa) };
    defer environment.table.deinit();
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = original_tabs;
        app.active = original_active;
        app.prefs = original_prefs;
        app.active_env = original_env;
        app.selected = original_selected;
        app.vars_dirty = true;
        app.modal_open = false;
        app.modal = .none;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.url.set("https://example.invalid/a/long/path?first=one&second=two");
    t.syncParamsFromUrl();
    t.body_kind = .json;
    t.body.setText("{\"keep\":true}");
    t.pane = .body;
    t.pane_chosen = true;
    app.prefs.log_open = false;
    // Standard/custom selection never moves the URL or trailing actions.
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
        app.prefs.dark = dark;
        app.prefs.sidebar_open = true;
        app.prefs.sidebar_width = 320;
        c.cui_set_viewport(ui, width, 832, scale);
        var url_x: f32 = 0;
        for ([_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "PROPFIND", "VERY-LONG-CUSTOM-METHOD-###-LITERAL" }) |method| {
            t.method.set(method);
            for (0..3) |_| frame(ui, app);
            const row = rect(ui, t, "request-composer");
            const group = rect(ui, t, "url-group");
            const selector = rect(ui, t, "###http-method");
            const field = rect(ui, t, "url");
            const details = rect(ui, t, "###url-details");
            const save = rect(ui, t, "###save-request");
            const send = rect(ui, t, "###send-request");
            try check(@src(), row.x >= 0 and row.x + row.w <= width);
            try check(@src(), selector.w == c.KEST_COMPOSER_METHOD and selector.h == 38);
            try check(@src(), field.w >= 160 and field.x >= selector.x + selector.w);
            try check(@src(), field.x + field.w <= details.x + 1 and details.x + details.w <= group.x + group.w + 1);
            try check(@src(), save.x > group.x + group.w and send.x > save.x + save.w);
            try check(@src(), send.x + send.w <= row.x + row.w + 1 and save.h == 38 and send.h == 38);
            if (url_x != 0) try check(@src(), @abs(field.x - url_x) < 0.1);
            url_x = field.x;
            try check(@src(), t.pane == .body and t.body_kind == .json and std.mem.eql(u8, t.body.text(), "{\"keep\":true}"));
        }
    };
    app.prefs.dark = true;
    app.prefs.sidebar_open = false;
    c.cui_set_viewport(ui, 640, 420, 1);
    t.method.set("PROPFIND");
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "compact");
    // Native method-menu keyboard navigation and committing custom text must
    // preserve URL/body and must never trigger a request.
    focus(ui, t, "###http-method");
    chord(ui, app, c.CUI_KEY_TAB, 0);
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_SHIFT);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), std.mem.eql(u8, t.method.text(), "GET") and t.job == null);
    t.method.set("VERY-LONG-CUSTOM-METHOD-###-LITERAL-THAT-DOES-NOT-FIT-IN-A-COMPACT-SELECTOR");
    for (0..3) |_| frame(ui, app);
    try tap(ui, app, t, "###http-method", click);
    for (0..3) |_| frame(ui, app);
    const method_popup = popupBounds(ui, t, "###http-method", 0x3e40);
    try check(@src(), method_popup.w > 0 and method_popup.y >= 0 and method_popup.y + method_popup.h <= 420);
    try capture(ui, sw, app, snapshot, "custom-method");
    for (0..8) |_| chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), t.editing_method);
    frame(ui, app);
    const editing_x = rect(ui, t, "url").x;
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "PROPFIND");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    frame(ui, app);
    try check(@src(), !t.editing_method and t.job == null and std.mem.eql(u8, t.method.text(), "PROPFIND"));
    try check(@src(), @abs(rect(ui, t, "url").x - editing_x) < 0.1);
    // Native selection, word replacement and undo survive continuous builds.
    focus(ui, t, "url");
    chord(ui, app, c.CUI_KEY_END, 0);
    chord(ui, app, c.CUI_KEY_LEFT, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    for (0..3) |_| frame(ui, app);
    c.cui_input_text(ui, "changed");
    frame(ui, app);
    try check(@src(), std.mem.endsWith(u8, t.url.text(), "second=changed"));
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.endsWith(u8, t.url.text(), "second=two"));
    // Editing far beyond the visible width does not overlap Save or Send.
    var long_url: std.ArrayList(u8) = .empty;
    defer long_url.deinit(app.gpa);
    try long_url.appendSlice(app.gpa, "https://example.invalid/");
    for (0..300) |_| try long_url.appendSlice(app.gpa, "segment/");
    t.url.set(long_url.items);
    focus(ui, t, "url");
    chord(ui, app, c.CUI_KEY_END, 0);
    c.cui_input_text(ui, "tail");
    frame(ui, app);
    try check(@src(), std.mem.endsWith(u8, t.url.text(), "segment/tail"));
    try tap(ui, app, t, "###url-details", click);
    for (0..3) |_| frame(ui, app);
    const long_details = popupBounds(ui, t, "url-inspector", 0);
    try check(@src(), long_details.w > 0 and long_details.y >= 0 and long_details.y + long_details.h <= 420);
    try capture(ui, sw, app, snapshot, "long-url");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    // Variables/errors update without keeping a permanent successful URL row.
    const base = try environment.table.add(.{ .key = "base", .value = "https://first.invalid" });
    const value = try environment.table.add(.{ .key = "value", .value = "one two" });
    commands.setActiveEnv(app, &environment);
    t.url.set("{{base}}/echo?word={{value}}");
    t.syncParamsFromUrl();
    frame(ui, app);
    try check(@src(), rect(ui, t, "composer-problem").h == 0 and rect(ui, t, "composer-area").h == 54);
    try tap(ui, app, t, "###url-details", click);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "resolved");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var inspected = try composer.inspect(a, t.url.text(), app.activeVars());
    try check(@src(), inspected.problem == null and std.mem.eql(u8, inspected.resolved, "https://first.invalid/echo?word=one%20two"));
    base.value.set("https://second.invalid");
    app.vars_dirty = true;
    frame(ui, app);
    inspected = try composer.inspect(a, t.url.text(), app.activeVars());
    try check(@src(), std.mem.startsWith(u8, inspected.resolved, "https://second.invalid/"));
    value.enabled = false;
    app.vars_dirty = true;
    frame(ui, app);
    inspected = try composer.inspect(a, t.url.text(), app.activeVars());
    try check(@src(), inspected.problem != null and inspected.unresolved.len == 1 and rect(ui, t, "composer-area").h > 54);
    try capture(ui, sw, app, snapshot, "unresolved");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), !app.modal_open);
    commands.setActiveEnv(app, null);
    frame(ui, app);
    inspected = try composer.inspect(a, t.url.text(), app.activeVars());
    try check(@src(), inspected.unresolved.len == 2);
    t.url.set("http://host.invalid:wrong/");
    frame(ui, app);
    try check(@src(), rect(ui, t, "composer-area").h > 54);
    try tap(ui, app, t, "###send-request", click);
    try check(@src(), t.job == null);
    t.url.set("https://fixed.invalid/");
    frame(ui, app);
    try check(@src(), rect(ui, t, "composer-area").h == 54);
    t.method.set("BAD METHOD");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try check(@src(), t.job == null and rect(ui, t, "composer-area").h > 54);
    t.method.set("PROPFIND");
    focus(ui, t, "body-editor");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), t.job == null and std.mem.indexOfScalar(u8, t.body.text(), '\n') != null);
    // Save remains an explicit request action with a real unsaved/saved state.
    try tap(ui, app, t, "###save-request", click);
    try check(@src(), app.modal_open and app.modal == .save_as and t.job == null);
    // Native dialogs use the first Escape to leave their focused text field.
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), !app.modal_open);
    const tree = @import("app/tree_ops.zig");
    const collection = tree.newCollection(app, "Composer save regression") orelse return error.AllocationFailed;
    defer tree.deleteNode(app, collection);
    tree.saveTabAs(app, t, collection, "Composer request");
    frame(ui, app);
    try check(@src(), t.link != null and !t.dirty);
    t.url.set("https://saved.invalid/current");
    persist.touchTab(app, t);
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_S, c.CUI_MOD_PRIMARY);
    app.store.sync();
    try check(@src(), !t.dirty and t.job == null);
    const stored = try @import("storage/collection_store.zig").loadRequest(app.store, a, &t.link.?.collection, &t.link.?.request);
    try check(@src(), std.mem.eql(u8, stored.url, t.url.text()));
    // Bare Enter in URL sends exactly the freshly resolved/escaped request.
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    base.value.set(try server.url(a, ""));
    value.enabled = true;
    commands.setActiveEnv(app, &environment);
    t.method.set("GET");
    t.body_kind = .none;
    t.url.set("{{base}}/echo?word={{value}}");
    focus(ui, t, "url");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    inspected = try composer.inspect(a, t.url.text(), app.activeVars());
    try check(@src(), std.mem.eql(u8, t.shown.?.out.url, inspected.resolved));
    try check(@src(), std.mem.indexOf(u8, t.shown.?.resp.preview.items, "word=one%20two") != null);
    // A completed response must not make a held URL Enter send again.
    c.cui_input_key(ui, c.CUI_KEY_ENTER, true, 0);
    frame(ui, app);
    try wait(ui, app, t, frame);
    const completed = t.shown;
    c.cui_input_key(ui, c.CUI_KEY_ENTER, true, 0);
    frame(ui, app);
    try check(@src(), t.job == null and t.shown == completed);
    c.cui_input_key(ui, c.CUI_KEY_ENTER, false, 0);
    frame(ui, app);
    t.url.set(try server.url(a, "/hang"));
    focus(ui, t, "url");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    const running = t.job;
    try check(@src(), running != null);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    commands.send(app, t);
    try check(@src(), t.job == running and !running.?.cancel_requested.load(.acquire));
    // Changing URL while running must leave Cancel enabled even if now invalid.
    t.url.set("{{missing}}");
    frame(ui, app);
    try tap(ui, app, t, "###send-request", click);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.stop == .canceled);
    t.url.set(try server.url(a, "/hang"));
    focus(ui, t, "###send-request");
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_ENTER, true, c.CUI_MOD_PRIMARY);
    frame(ui, app);
    const shortcut_job = t.job;
    try check(@src(), shortcut_job != null and !shortcut_job.?.cancel_requested.load(.acquire));
    c.cui_input_key(ui, c.CUI_KEY_ENTER, true, c.CUI_MOD_PRIMARY);
    frame(ui, app);
    try check(@src(), t.job == shortcut_job and !shortcut_job.?.cancel_requested.load(.acquire));
    c.cui_input_key(ui, c.CUI_KEY_ENTER, false, 0);
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown.?.resp.stop == .canceled);
    std.debug.print("CUI composer: stable methods/actions, native URL selection/undo, current variable inspection/errors, Save, Enter send, duplicate prevention and Cancel passed\n", .{});
}
