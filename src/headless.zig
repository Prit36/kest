//! Tests render CUI directly; no native window, OS input or clipboard.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const shell = @import("ui/shell.zig");
const App = @import("app/state.zig").App;
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const tree = @import("app/tree_ops.zig");

fn frame(ui: *c.cui_ctx, app: *App) void {
    c.cui_begin_frame(ui, 1.0 / 60.0);
    shell.view(ui, app);
    c.kest_end_frame(ui);
    c.kest_quiet_caret(ui);
}
fn click(ui: *c.cui_ctx, app: *App, x: f32, y: f32) void {
    c.cui_input_mouse_move(ui, x, y);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
}
fn wait(ui: *c.cui_ctx, app: *App) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (app.current().?.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.RequestTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}
pub fn run(app: *App, test_mode: bool, snapshot: ?[]const u8, width: f32, height: f32, scale: f32) !void {
    const sw = c.cui_sw_create() orelse return error.RendererFailed;
    defer c.cui_sw_destroy(sw);
    const ui = c.cui_create(&.{ .renderer = c.cui_sw_iface(sw), .theme = c.CUI_THEME_DARK, .accent = c.CUI_ACCENT_BLUE }) orelse return error.ContextFailed;
    @import("ui/platform.zig").context = ui;
    defer {
        for (app.tabs.items) |t| t.response.reset();
        @import("ui/platform.zig").context = null;
        c.cui_destroy(ui);
    }
    c.cui_set_reduced_motion(ui, true);
    c.cui_set_viewport(ui, width, height, scale);
    errdefer if (snapshot) |path| @import("ui_snapshots.zig").capture(ui, sw, app, path) catch {};
    if (test_mode) {
        // This mode owns a scratch workspace. Start its UI fixtures independently
        // of prior restored tabs, including a previous 64-document stress run.
        // Destroy only in-memory views here; stored requests/drafts stay on disk.
        for (app.tabs.items) |t| t.destroy();
        app.tabs.clearRetainingCapacity();
        app.active = 0;
        // Suite interactions begin on the desktop layout; requested snapshot
        // dimensions are restored below. Tests exercise compact layout explicitly.
        // Scratch workspaces survive runs; start from a deterministic console
        // state. Individual compact regressions exercise the open console.
        app.prefs.log_open = false;
        c.cui_set_viewport(ui, 1180, 800, 1);
        try tests(ui, app);
        try workspaceUx(ui, app, sw, snapshot);
        try @import("ui_interaction_tests.zig").run(ui, app, frame, click, chord);
        try integration(ui, app);
        try @import("sidebar_tests.zig").run(ui, app, sw, snapshot, frame, click);
        try @import("geometry_tests.zig").run(ui, app, frame, click);
        try @import("document_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("composer_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("table_data_tests.zig").run(ui, app, sw, snapshot, frame, click);
        try @import("table_ui_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("body_editor_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("context_menu_tests.zig").run(ui, app, frame, click);
        try @import("text_editing_tests.zig").run(ui, app, frame, chord);
        try @import("upload_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("response_state_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("response_preparation_tests.zig").run(ui, app, sw, snapshot, frame, click);
        try @import("response_header_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("response_text_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("response_search_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("workflow_tests.zig").run(ui, app, sw, snapshot, frame, click, chord);
        try @import("keyboard_tests.zig").run(ui, app, frame, chord, wait);
        try @import("workspace_ux_tests.zig").run(ui, sw, app, frame, chord);
        try memoryLifecycle(app);
        try performance(ui, app);
    }
    for (0..8) |_| frame(ui, app);
    c.cui_set_viewport(ui, width, height, scale);
    for (0..8) |_| frame(ui, app);
    if (snapshot) |path| {
        try @import("ui_snapshots.zig").capture(ui, sw, app, path);
        if (test_mode) try @import("ui_snapshots.zig").suite(ui, sw, app, path, frame);
    }
}
fn expect(src: std.builtin.SourceLocation, condition: bool) !void {
    if (!condition) {
        std.debug.print("Check failed at {s}:{d}\n", .{ src.file, src.line });
        return error.SelfTestFailed;
    }
}
fn chord(ui: *c.cui_ctx, app: *App, key: c.cui_key, mods: c_int) void {
    c.cui_input_key(ui, key, true, mods);
    frame(ui, app);
    c.cui_input_key(ui, key, false, 0);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, 0);
    frame(ui, app);
}
fn tests(ui: *c.cui_ctx, app: *App) !void {
    try requestSelection(app);
    commands.ensureTab(app);
    const count = app.tabs.items.len;
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_N, c.CUI_MOD_PRIMARY);
    try expect(@src(), app.tabs.items.len == count + 1);
    const t = app.current().?;
    t.url.set("http://127.0.0.1:1/test?one=two");
    t.syncParamsFromUrl();
    try expect(@src(), t.params.rows.items.len == 1);
    t.params.rows.items[0].value.set("changed");
    t.syncUrlFromParams();
    try expect(@src(), std.mem.indexOf(u8, t.url.text(), "changed") != null);
    t.body_kind = .json;
    t.pane = .body;
    t.body.setText("{\"answer\":42}");
    commands.formatBody(app, t, 2);
    try expect(@src(), std.mem.indexOfScalar(u8, t.body.text(), '\n') != null);
    try expect(@src(), t.body.undoEdit());
    try expect(@src(), std.mem.eql(u8, t.body.text(), "{\"answer\":42}"));
    const collection = tree.newCollection(app, "CUI self-test") orelse return error.AllocationFailed;
    tree.saveTabAs(app, t, collection, "Round trip");
    app.store.sync();
    try expect(@src(), t.link != null);
    persist.touchTab(app, t);
    persist.flush(app);
    app.store.sync();
    const env = tree.addEnvironment(app, "Loopback") orelse return error.AllocationFailed;
    _ = try env.table.add(.{ .key = "base", .value = "http://127.0.0.1" });
    commands.setActiveEnv(app, env);
    try expect(@src(), app.activeVars().len == 1);
    const old_sidebar = app.prefs.sidebar_open;
    chord(ui, app, c.CUI_KEY_B, c.CUI_MOD_PRIMARY);
    try expect(@src(), app.prefs.sidebar_open != old_sidebar);
    // Every request and response mode must build and lay out at minimum size.
    c.cui_set_viewport(ui, 640, 420, 1);
    app.prefs.sidebar_open = false;
    inline for (std.meta.tags(@import("app/tab.zig").RequestPane)) |pane| {
        t.pane = pane;
        frame(ui, app);
    }
    const old_log = app.prefs.log_open;
    const old_body = t.body_kind;
    t.pane = .body;
    for ([_]@import("core/request.zig").BodyKind{ .json, .form_urlencoded, .multipart }) |kind| {
        t.body_kind = kind;
        for ([_]bool{ false, true }) |log_open| {
            app.prefs.log_open = log_open;
            for (0..8) |_| frame(ui, app);
            const region = c.cui_get_rect(ui, c.cui_make_id(ui, "workspace-region"));
            const panel = tabRect(ui, t, "response-panel");
            try expect(@src(), region.h > 0 and region.y + region.h <= 420);
            try expect(@src(), panel.h > 0 and panel.y + panel.h <= region.y + region.h);
            if (kind == .form_urlencoded or kind == .multipart) {
                c.cui_push_id_int(ui, @intCast(t.uid));
                c.cui_push_id(ui, "form");
                c.cui_push_id_int(ui, @intCast(t.form.entry.?.uid));
                const insertion = c.cui_get_rect(ui, c.cui_make_id(ui, "key"));
                c.cui_pop_id(ui);
                c.cui_pop_id(ui);
                c.cui_pop_id(ui);
                try expect(@src(), insertion.h >= 30 and insertion.y + insertion.h <= panel.y);
            }
        }
    }
    app.prefs.log_open = old_log;
    t.body_kind = old_body;
    t.pane = .params;
    c.cui_set_viewport(ui, 1180, 800, 1);
    for (0..12) |_| frame(ui, app);
    std.debug.print("CUI headless: shortcuts, query sync, JSON undo, saved request, environment, minimum layout passed\n", .{});
}

fn tabRect(ui: *c.cui_ctx, t: *@import("app/tab.zig").Tab, id: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, id));
}

fn workspaceUx(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8) !void {
    const t = app.current().?;
    const old_log_open = app.prefs.log_open;
    defer app.prefs.log_open = old_log_open;
    app.prefs.log_open = false;
    const original_dark = app.prefs.dark;
    defer app.prefs.dark = original_dark;
    app.prefs.dark = true;
    frame(ui, app);
    // The native app uses the same motion policy as this software context.
    try expect(@src(), c.cui_theme_get(ui).*.motion == 0);
    const dark = c.cui_token_color(ui, c.CUI_TOKEN_SURFACE);
    app.prefs.dark = false;
    frame(ui, app);
    const light = c.cui_token_color(ui, c.CUI_TOKEN_SURFACE);
    try expect(@src(), light.r > dark.r and c.cui_theme_get(ui).*.motion == 0);
    app.prefs.dark = true;
    frame(ui, app);
    try expect(@src(), c.cui_token_color(ui, c.CUI_TOKEN_SURFACE).r == dark.r);

    t.params.clear();
    t.pane = .params;
    t.details_collapsed = false;
    t.url.set("http://127.0.0.1:1/test");
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..3) |_| frame(ui, app);
    const composer = tabRect(ui, t, "request-composer");
    const url_field = tabRect(ui, t, "url");
    try expect(@src(), composer.x >= 0 and composer.x + composer.w <= 640);
    try expect(@src(), url_field.w >= 200 and url_field.x + url_field.w < composer.x + composer.w);
    try expect(@src(), t.params.rows.items.len == 0 and t.params.entry != null);
    const new_row = t.params.entry.?;
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, "params");
    c.cui_push_id_int(ui, @intCast(new_row.uid));
    const blank_key = c.cui_get_rect(ui, c.cui_make_id(ui, "key"));
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    click(ui, app, blank_key.x + 20, blank_key.y + 16);
    c.cui_input_text(ui, "que");
    frame(ui, app);
    try expect(@src(), t.params.rows.items.len == 1 and t.params.rows.items[0] == new_row);
    c.cui_input_text(ui, "ry");
    frame(ui, app);
    try expect(@src(), std.mem.eql(u8, new_row.key.text(), "query"));
    // Focus and cursor survive promoting the insertion row to real data.
    chord(ui, app, c.CUI_KEY_TAB, 0);
    c.cui_input_text(ui, "native");
    frame(ui, app);
    try expect(@src(), std.mem.eql(u8, new_row.value.text(), "native"));
    try expect(@src(), std.mem.indexOf(u8, t.url.text(), "query=native") != null);
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, "params");
    c.cui_push_id_int(ui, @intCast(new_row.uid));
    const key_rect = c.cui_get_rect(ui, c.cui_make_id(ui, "key"));
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    try expect(@src(), key_rect.h >= 30 and key_rect.y + key_rect.h <= tabRect(ui, t, "response-panel").y);
    // Both the populated row and the next insertion row fit at minimum size.
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, "params");
    c.cui_push_id_int(ui, @intCast(t.params.entry.?.uid));
    const next_row = c.cui_get_rect(ui, c.cui_make_id(ui, "key"));
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    if (next_row.h < 30 or next_row.y + next_row.h > tabRect(ui, t, "response-panel").y)
        std.debug.print("Parameter insertion={any}, response={any}, log={}\n", .{ next_row, tabRect(ui, t, "response-panel"), app.prefs.log_open });
    try expect(@src(), next_row.h >= 30 and next_row.y + next_row.h <= tabRect(ui, t, "response-panel").y);
    const response_before = tabRect(ui, t, "response-panel");
    // Layout > Focus response hides the request editor; any section tab
    // restores it (the old floating chevron duplicated the Layout menu).
    t.details_collapsed = true;
    t.response_collapsed = false;
    frame(ui, app);
    frame(ui, app);
    const response_after = tabRect(ui, t, "response-panel");
    try expect(@src(), response_after.h > response_before.h + 30);
    const params_tab = tabRect(ui, t, "pane-params");
    click(ui, app, params_tab.x + params_tab.w / 2, params_tab.y + params_tab.h / 2);
    try expect(@src(), !t.details_collapsed);

    c.cui_set_viewport(ui, 1180, 800, 1);
    app.prefs.sidebar_open = true;
    app.mode = .collections;
    for (0..3) |_| frame(ui, app);
    const request_rect = tabRect(ui, t, "request-panel");
    const response_rect = tabRect(ui, t, "response-panel");
    try expect(@src(), response_rect.x > request_rect.x + request_rect.w - 1 and response_rect.h > 400);
    if (snapshot) |path| {
        const stem = path[0 .. path.len - std.fs.path.extension(path).len];
        const target = try std.fmt.allocPrint(app.gpa, "{s}-params.png", .{stem});
        defer app.gpa.free(target);
        try @import("ui_snapshots.zig").capture(ui, sw, app, target);
    }
    var root = app.collections.items[0];
    if (t.link) |link| for (app.collections.items) |collection| {
        if (std.mem.eql(u8, &collection.id, &link.collection)) {
            root = collection;
            break;
        }
    };
    @import("ui/sidebar.zig").reveal(app, root);
    for (0..3) |_| frame(ui, app);
    c.kest_focus(ui, "collection-rows");
    chord(ui, app, c.CUI_KEY_LEFT, 0);
    try expect(@src(), !root.expanded);
    chord(ui, app, c.CUI_KEY_RIGHT, 0);
    try expect(@src(), root.expanded);
    // Click the real path-bar ancestor: it clears a filter and reveals the
    // collection even when the sidebar had been hidden.
    app.filter.set("no-such-request");
    app.rows_dirty = true;
    app.prefs.sidebar_open = false;
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, "request-path");
    c.cui_push_id_int(ui, 0);
    const crumb = c.cui_get_rect(ui, c.cui_make_id(ui, "seg"));
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    try expect(@src(), crumb.w > 0);
    click(ui, app, crumb.x + crumb.w / 2, crumb.y + crumb.h / 2);
    try expect(@src(), app.filter.len == 0 and app.prefs.sidebar_open and app.selected == root);
    t.params.clear();
    t.syncUrlFromParams();
    std.debug.print("CUI workspace UX: instant themes, joined composer, direct row entry, continuous typing, Tab to value, URL sync, two visible rows at 640px, response focus, adaptive columns, collection navigation passed\n", .{});
}

fn integration(ui: *c.cui_ctx, app: *App) !void {
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    const t = app.current().?;
    t.settings.timeout_ms = 3000;
    t.body_kind = .none;
    t.url.set(try server.url(w.arena.allocator(), "/json"));
    // This is the same shortcut path as the real window.
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try wait(ui, app);
    try expect(@src(), t.shown != null and t.shown.?.resp.status == 200);
    try expect(@src(), std.mem.indexOf(u8, t.shown.?.resp.preview.items, "needle") != null);
    try @import("ui_interaction_tests.zig").response(ui, app, frame, click);
    t.response.pretty_mode = .tree;
    inline for (std.meta.tags(@import("app/tab.zig").ResponsePane)) |pane| {
        t.response.pane = pane;
        frame(ui, app);
        try @import("response_test_support.zig").settle(ui, app, frame);
    }
    try expect(@src(), t.response.tree != null);
    const expanded_rows = t.response.tree.?.rows.items.len;
    try t.response.tree.?.setAll(app.gpa, true);
    try expect(@src(), t.response.tree.?.rows.items.len < expanded_rows);
    try t.response.tree.?.setAll(app.gpa, false);
    t.response.pretty_mode = .text;
    t.response.pane = .pretty;
    try @import("response_test_support.zig").settle(ui, app, frame);
    try expect(@src(), t.response.formatted != null);
    t.response.pretty_mode = .minified;
    try @import("response_test_support.zig").settle(ui, app, frame);
    try expect(@src(), std.mem.indexOfScalar(u8, t.response.formatted.?, '\n') == null);
    t.response.pane = .raw;
    t.response.code_raw.search_open = true;
    t.response.code_raw.query.set("needle");
    t.response.code_raw.research(t.shown.?.resp.preview.items);
    try expect(@src(), t.response.code_raw.matches.items.len == 1);
    t.response.code_raw.search_open = false;
    // Actual pointer and text events, entirely inside CUI's context.
    t.pane = .body;
    t.body_kind = .json;
    t.body.setText("{}");
    for (0..3) |_| frame(ui, app);
    const rect = c.cui_get_rect(ui, c.cui_make_id(ui, "unused"));
    _ = rect;
    // The editor has an id scope belonging to the active request.
    c.cui_push_id_int(ui, @intCast(t.uid));
    const body_id = c.cui_make_id(ui, "body-editor");
    c.cui_pop_id(ui);
    const body_rect = c.cui_get_rect(ui, body_id);
    try expect(@src(), body_rect.w > 100 and body_rect.h > 30);
    click(ui, app, body_rect.x + 62, body_rect.y + 15);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "{\"typed\":true}");
    frame(ui, app);
    try expect(@src(), std.mem.eql(u8, t.body.text(), "{\"typed\":true}"));
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try expect(@src(), std.mem.eql(u8, t.body.text(), "{}"));
    // POST body travels through the request builder and transport.
    t.method.set("POST");
    t.url.set(try server.url(w.arena.allocator(), "/echo"));
    t.body.setText("{\"sent\":true}");
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try wait(ui, app);
    try expect(@src(), std.mem.indexOf(u8, t.shown.?.resp.preview.items, "{\"sent\":true}") != null);
    // Queue an export, then clear the response immediately. The writer pins it.
    const export_path = try std.fs.path.join(app.gpa, &.{ app.store.path, "exported-response.txt" });
    defer app.gpa.free(export_path);
    try @import("app/export_jobs.zig").response(app.store, export_path, t.shown.?);
    commands.clearResponse(t);
    app.store.sync();
    const exported = try std.Io.Dir.cwd().readFileAlloc(app.io, export_path, app.gpa, .limited(65536));
    defer app.gpa.free(exported);
    try expect(@src(), std.mem.indexOf(u8, exported, "sent") != null);
    t.method.set("GET");
    t.body_kind = .none;
    t.url.set(try server.url(w.arena.allocator(), "/bytes/9437184"));
    commands.send(app, t);
    try wait(ui, app);
    try expect(@src(), t.shown.?.resp.spill_path != null);
    try @import("app/export_jobs.zig").response(app.store, export_path, t.shown.?);
    commands.clearResponse(t);
    app.store.sync();
    const saved_stat = try std.Io.Dir.cwd().statFile(app.io, export_path, .{});
    try expect(@src(), saved_stat.size == 9437184);
    t.url.set(try server.url(w.arena.allocator(), "/hang"));
    commands.send(app, t);
    commands.cancel(t);
    try wait(ui, app);
    try expect(@src(), t.shown.?.resp.stop == .canceled);
    t.url.set(try server.url(w.arena.allocator(), "/html"));
    commands.send(app, t);
    try wait(ui, app);
    t.response.pane = .preview;
    try @import("response_test_support.zig").settle(ui, app, frame);
    try expect(@src(), t.response.stripped != null and std.mem.indexOf(u8, t.response.stripped.?, "Loopback preview") != null);
    t.url.set(try server.url(w.arena.allocator(), "/markdown"));
    commands.send(app, t);
    try wait(ui, app);
    try expect(@src(), @import("ui/response.zig").isMarkdown(&t.shown.?.resp));
    t.response.pane = .preview;
    for (0..4) |_| frame(ui, app);
    try expect(@src(), tabRect(ui, t, "markdown-preview").h > 50);
    const markdown_bytes = try app.gpa.dupe(u8, t.shown.?.resp.preview.items);
    defer app.gpa.free(markdown_bytes);
    frame(ui, app);
    try expect(@src(), std.mem.eql(u8, markdown_bytes, t.shown.?.resp.preview.items));
    // Oversized markup stays on the bounded, virtualized editor path.
    try t.shown.?.resp.preview.resize(app.gpa, 256 * 1024 + 1);
    @memset(t.shown.?.resp.preview.items, 'x');
    for (0..3) |_| frame(ui, app);
    try expect(@src(), tabRect(ui, t, "text-preview").h > 30);
    t.url.set(try server.url(w.arena.allocator(), "/png"));
    commands.send(app, t);
    try wait(ui, app);
    t.response.pane = .preview;
    try @import("response_test_support.zig").settle(ui, app, frame);
    try expect(@src(), t.response.image != 0 and t.response.image_width == 1);
    // Validate real import + saved request files + a reload of the workspace.
    @import("app/import_ops.zig").previewText(app, "curl -X POST http://127.0.0.1/echo -H 'Content-Type: application/json' -d '{\"hello\":1}'", "test.curl");
    try expect(@src(), app.preview != null);
    @import("app/import_ops.zig").accept(app);
    app.modal_open = false;
    // Different choices belong to different requests, including a body request
    // deliberately left on Headers. Neither choice is request data.
    t.pane = .headers;
    commands.moveTab(app, std.mem.indexOfScalar(*@import("app/tab.zig").Tab, app.tabs.items, t).?, 0);
    const selection_draft = commands.openUnsaved(app, .{
        .name = "Selection restoration draft",
        .method = "POST",
        .body_kind = .json,
        .body_text = "{\"restore\":true}",
    }) orelse return error.AllocationFailed;
    selection_draft.pane = .settings;
    // Keep both restoration probes first, independently of other suite fixtures.
    commands.moveTab(app, app.active, 0);
    persist.flush(app);
    persist.savePrefs(app);
    app.store.sync();
    var restored = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
    defer restored.deinit();
    try persist.load(&restored);
    try expect(@src(), restored.collections.items.len == app.collections.items.len and restored.envs.items.len == app.envs.items.len);
    try expect(@src(), restored.tabs.items.len > 0);
    var restored_selection_draft = false;
    for (restored.tabs.items) |loaded| {
        const original = for (app.tabs.items) |candidate| {
            if (std.mem.eql(u8, &candidate.id, &loaded.id) or
                (candidate.link != null and loaded.link != null and
                    std.mem.eql(u8, &candidate.link.?.request, &loaded.link.?.request))) break candidate;
        } else return error.RestoredTabMissing;
        try expect(@src(), loaded.pane == original.pane and loaded.pane_chosen);
        try expect(@src(), std.mem.eql(u8, loaded.body.text(), original.body.text()));
        if (original == selection_draft) restored_selection_draft = true;
    }
    try expect(@src(), restored_selection_draft);
    commands.closeNow(app, selection_draft);
    // Finish with real JSON on show, also used by the optional screenshot.
    t.url.set(try server.url(w.arena.allocator(), "/json"));
    t.syncParamsFromUrl();
    commands.send(app, t);
    try wait(ui, app);
    t.pane = .params;
    t.response.pane = .pretty;
    t.response.pretty_mode = .tree;
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..4) |_| frame(ui, app);
    try @import("response_test_support.zig").settle(ui, app, frame);
    const json_rect = tabRect(ui, t, "json-rows");
    try expect(@src(), json_rect.h >= 60 and json_rect.y + json_rect.h <= 420);
    chord(ui, app, c.CUI_KEY_B, c.CUI_MOD_PRIMARY);
    try expect(@src(), shell.narrow_open);
    chord(ui, app, c.CUI_KEY_B, c.CUI_MOD_PRIMARY);
    try expect(@src(), !shell.narrow_open);
    c.cui_set_viewport(ui, 1180, 800, 1);
    for (0..4) |_| frame(ui, app);
    app.prefs.sidebar_open = true;
    t.response.pretty_mode = .text;
    std.debug.print("CUI integration: loopback GET/POST, response modes, tree, search, pointer editing/undo, cancel, memory/spill export lifetime, HTML/PNG preview, cURL import, workspace reload passed\n", .{});
}
fn requestSelection(app: *App) !void {
    const Tab = @import("app/tab.zig").Tab;
    const t = try Tab.create(app.gpa, @import("core/collection.zig").newId(app.io), 999999);
    defer t.destroy();
    try t.fromRequest(.{ .method = "POST", .url = "https://example.invalid/?q=1", .body_kind = .json, .body_text = "{\"keep\":true}" });
    try expect(@src(), t.pane == .body and t.hasBodyContent());
    try expect(@src(), std.mem.eql(u8, t.body.text(), "{\"keep\":true}"));
    try t.fromRequest(.{ .url = "https://example.invalid/?q=1", .headers = &.{.{ .key = "Accept", .value = "application/json" }} });
    try expect(@src(), t.pane == .params and !t.hasBodyContent());
    for ([_]@import("core/request.zig").BodyKind{ .form_urlencoded, .multipart }) |kind| {
        try t.fromRequest(.{ .body_kind = kind, .form = &.{.{ .key = "file", .value = "sample.txt", .is_file = true }} });
        try expect(@src(), t.pane == .body and t.hasBodyContent());
    }
    try t.fromRequest(.{ .body_kind = .file, .file_path = "sample.bin" });
    try expect(@src(), t.pane == .body and t.hasBodyContent());
    try t.fromRequest(.{ .method = "PATCH" });
    try expect(@src(), t.pane == .body and !t.hasBodyContent());
    std.debug.print("CUI request selection: JSON, URL query priority, forms, upload and method defaults passed\n", .{});
}

fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}

fn memoryLifecycle(app: *App) !void {
    var view = @import("app/tab.zig").ResponseView.init(app.gpa);
    defer view.deinit();
    const text = "first\nsecond\nthird";
    try view.code_raw.index.build(app.gpa, text);
    view.code_raw.query.set("second");
    view.code_raw.research(text);
    try expect(@src(), view.code_raw.matches.items.len == 1);
    view.code_raw.scroll_y = 100;
    view.json.toggleString(app.gpa, 1, 8);
    view.reset();
    try expect(@src(), view.code_raw.index.starts.capacity == 0 and view.code_raw.index.lines.capacity == 0);
    try expect(@src(), view.code_raw.matches.capacity == 0 and view.json.open_strings.capacity == 0);
    try expect(@src(), view.code_raw.scroll_y == 0);
    // Search caching tracks its own source rather than the rendered index.
    var source = [_]u8{ 'a', 'b', 'a' };
    view.code_raw.query.set("a");
    view.code_raw.refreshSearch(&source);
    try expect(@src(), view.code_raw.matches.items.len == 2);
    view.code_raw.refreshSearch(source[0..1]);
    try expect(@src(), view.code_raw.matches.items.len == 1);
    // Reusing a response after clear and clearing it again are both safe.
    try view.code_pretty.index.build(app.gpa, text);
    view.reset();
    view.reset();
    try expect(@src(), view.code_pretty.index.starts.capacity == 0);
    std.debug.print("CUI memory: response clear releases indexes/search, repeated reset and source-length search invalidation passed\n", .{});
}

fn performance(ui: *c.cui_ctx, app: *App) !void {
    // Let transient toast deadlines expire, then require an entirely idle UI.
    for (0..800) |_| frame(ui, app);
    try expect(@src(), !c.cui_needs_redraw(ui));
    try expect(@src(), c.cui_next_wakeup(ui) < 0);
    const t = app.current().?;
    const previous = try app.gpa.dupe(u8, t.body.text());
    defer app.gpa.free(previous);
    const payload = try app.gpa.alloc(u8, 4 * 1024 * 1024);
    defer app.gpa.free(payload);
    @memset(payload, 'x');
    t.body.setText(payload);
    t.pane = .body;
    t.body_kind = .text;
    frame(ui, app);
    frame(ui, app);
    var times: [200]u64 = undefined;
    for (&times, 0..) |*slot, i| {
        c.cui_input_mouse_move(ui, 500 + @as(f32, @floatFromInt(i % 100)), 240);
        const start = std.Io.Clock.Timestamp.now(app.io, .awake);
        frame(ui, app);
        slot.* = @intCast(start.untilNow(app.io).raw.toNanoseconds());
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    std.debug.print("CUI build/layout/paint 4 MiB single line: median {d:.3} ms, p99 {d:.3} ms (200 frames); idle redraw=false, wakeup<0\n", .{ @as(f64, @floatFromInt(times[100])) / 1e6, @as(f64, @floatFromInt(times[198])) / 1e6 });
    try nativeEditorSample(app, payload);
    t.body.setText(previous);
    t.body_kind = .none;
    t.pane = .params;
}

// Keep the upstream editor under measurement before adopting it for large HTTP
// documents. An isolated context prevents it changing the app's editor state.
fn nativeEditorSample(app: *App, payload: []const u8) !void {
    const sw = c.cui_sw_create() orelse return error.RendererFailed;
    defer c.cui_sw_destroy(sw);
    const ui = c.cui_create(&.{ .renderer = c.cui_sw_iface(sw), .theme = c.CUI_THEME_DARK }) orelse return error.ContextFailed;
    defer c.cui_destroy(ui);
    c.cui_set_viewport(ui, 800, 500, 1);
    c.cui_set_reduced_motion(ui, true);
    const text = try app.gpa.dupeSentinel(u8, payload, 0);
    defer app.gpa.free(text);
    var times: [8]u64 = undefined;
    for (&times) |*slot| {
        const start = std.Io.Clock.Timestamp.now(app.io, .awake);
        c.cui_begin_frame(ui, 1.0 / 60.0);
        _ = c.cui_code_editor_ex(ui, "upstream-editor", text.ptr, text.len + 1, &.{ .height = -1, .read_only = true });
        c.cui_end_frame(ui);
        slot.* = @intCast(start.untilNow(app.io).raw.toNanoseconds());
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    std.debug.print("CUI 1.1 native editor, isolated 4 MiB single line: median {d:.3} ms (8 frames)\n", .{@as(f64, @floatFromInt(times[4])) / 1e6});
}
