//! Form/binary controls, asynchronous metadata and actual upload payloads.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const Env = @import("app/state.zig").Env;
const Tab = @import("app/tab.zig").Tab;
const commands = @import("app/commands.zig");
const persist = @import("app/persist.zig");
const upload = @import("ui/upload.zig");
const metadata = @import("app/upload_info.zig");
const prepare = @import("network/prepare.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Upload regression at {s}:{d}\n", .{ src.file, src.line });
        return error.UploadRegression;
    }
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    try check(src, std.mem.eql(u8, want, got));
}
fn rect(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8, row: ?u32) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    if (row != null) c.cui_push_id(ui, "form");
    defer if (row != null) c.cui_pop_id(ui);
    if (row) |uid| c.cui_push_id_int(ui, @intCast(uid));
    defer if (row != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn menu(ui: *c.cui_ctx, t: *Tab, row: ?u32, trigger: [*:0]const u8, item: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    if (row != null) c.cui_push_id(ui, "form");
    defer if (row != null) c.cui_pop_id(ui);
    if (row) |uid| c.cui_push_id_int(ui, @intCast(uid));
    defer if (row != null) c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, trigger) ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, item));
}
fn present(ui: *c.cui_ctx, t: *Tab, key: [*:0]const u8) bool {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.kest_has_node(ui, c.cui_make_id(ui, key));
}
fn tap(src: std.builtin.SourceLocation, ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime click: anytype) !void {
    try check(src, r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const original = path orelse return;
    const stem = original[0 .. original.len - std.fs.path.extension(original).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-upload-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
var picker_mode: enum { cancel, fail, choose } = .cancel;
var picker_path: []const u8 = "";
var picker_calls: usize = 0;
fn picker(a: std.mem.Allocator) !?[]u8 {
    picker_calls += 1;
    return switch (picker_mode) {
        .cancel => null,
        .fail => error.PickerFailed,
        .choose => try a.dupe(u8, picker_path),
    };
}
fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}
fn countedWake(ctx: *anyopaque) void {
    const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
    _ = value.fetchAdd(1, .monotonic);
}
fn settle(app: *App, path: []const u8) !metadata.Info {
    _ = upload.info(app, path, false);
    try app.uploads.group.await(app.io);
    return upload.info(app, path, false);
}
fn wait(ui: *c.cui_ctx, app: *App, t: *Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.UploadTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}

fn cacheChecks(app: *App, file: []const u8, empty: []const u8, missing: []const u8, size: u64) !void {
    var counted: std.atomic.Value(u32) = .init(0);
    const wake: metadata.Wake = .{ .ctx = &counted, .call = countedWake };
    var fault = std.testing.FailingAllocator.init(app.gpa, .{});
    {
        var cache = metadata.Cache.init(fault.allocator(), app.io);
        defer cache.deinit();
        const mutable = try app.gpa.dupe(u8, file);
        defer app.gpa.free(mutable);
        _ = cache.lookup(mutable, wake);
        @memset(mutable, 'x');
        try cache.group.await(app.io);
        try check(@src(), cache.lookup(file, wake).status == .ready and cache.lookup(file, wake).size == size);
        const started = cache.started;
        for (0..100) |_| _ = cache.lookup(file, wake);
        try check(@src(), cache.started == started and counted.load(.acquire) == 1);
        _ = cache.lookup(empty, wake);
        _ = cache.lookup(missing, wake);
        _ = cache.lookup(app.tmp_dir, wake);
        try cache.group.await(app.io);
        try check(@src(), cache.lookup(empty, wake).status == .ready and cache.lookup(empty, wake).size == 0);
        try check(@src(), cache.lookup(missing, wake).status == .missing and cache.lookup(app.tmp_dir, wake).status == .not_file);
        try check(@src(), cache.lookup("bad\x00path", wake).status == .invalid);
        // Evict while jobs are pending; only the bounded cache owns UI state.
        for (0..48) |i| {
            const path = try std.fmt.allocPrint(app.gpa, "{s}-{d}", .{ missing, i });
            _ = cache.lookup(path, wake);
            app.gpa.free(path);
            try check(@src(), cache.running.load(.acquire) <= metadata.max_running);
            if (i % 4 == 3) try cache.group.await(app.io);
        }
        try cache.group.await(app.io);
        cache.invalidate(file);
        _ = cache.lookup(file, wake);
        try cache.group.await(app.io);
        try check(@src(), cache.lookup(file, wake).status == .ready and cache.running.load(.acquire) == 0);
    }
    try check(@src(), fault.allocated_bytes == fault.freed_bytes);
    // Failed allocations leave no half-owned cache entry and can retry.
    for (0..2) |offset| {
        var failing = std.testing.FailingAllocator.init(app.gpa, .{ .fail_index = offset });
        {
            var cache = metadata.Cache.init(failing.allocator(), app.io);
            defer cache.deinit();
            try check(@src(), cache.lookup(file, wake).status == .unavailable and cache.started == 0);
            failing.fail_index = std.math.maxInt(usize);
            _ = cache.lookup(file, wake);
            try cache.group.await(app.io);
            try check(@src(), cache.lookup(file, wake).status == .ready);
        }
        try check(@src(), failing.allocated_bytes == failing.freed_bytes);
    }
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const file = try std.fs.path.join(app.gpa, &.{ app.tmp_dir, "upload é sample.bin" });
    defer app.gpa.free(file);
    const empty = try std.fs.path.join(app.gpa, &.{ app.tmp_dir, "body-7b-empty.txt" });
    defer app.gpa.free(empty);
    const missing = try std.fs.path.join(app.gpa, &.{ app.tmp_dir, "body-7b-does-not-exist.file" });
    defer app.gpa.free(missing);
    const payload = "binary\x00\xff\x80\r\nexact contents";
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = file, .data = payload });
    defer std.Io.Dir.cwd().deleteFile(app.io, file) catch {};
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = empty, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(app.io, empty) catch {};
    try cacheChecks(app, file, empty, missing, payload.len);
    try equal(@src(), "upload é sample.bin", prepare.basename(file));
    try equal(@src(), "application/json", prepare.guessType("C:\\uploads\\EXAMPLE.JSON"));
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_selected = app.selected;
    const old_picker = app.choose_upload;
    app.tabs = .empty;
    app.active = 0;
    app.selected = null;
    app.choose_upload = picker;
    var env: Env = .{ .id = @splat('u'), .name = @constCast("Upload environment"), .table = .init(app.gpa) };
    defer env.table.deinit();
    defer {
        app.uploads.group.await(app.io) catch {};
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        app.active_env = old_env;
        app.selected = old_selected;
        app.choose_upload = old_picker;
        app.vars_dirty = true;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    commands.setActiveEnv(app, null);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.url.set("https://example.invalid/upload");
    t.method.set("POST");
    t.pane = .body;
    t.pane_chosen = true;
    t.body_kind = .file;
    t.body.setText("{\"retained_invalid\":}");
    c.cui_set_viewport(ui, 640, 420, 1);
    t.body_kind = .multipart;
    for (0..4) |_| frame(ui, app);
    try check(@src(), t.form.rows.items.len == 0 and t.form.entry != null);
    try check(@src(), rect(ui, t, "value", t.form.entry.?.uid).h == 32);
    try capture(ui, sw, app, snapshot, "multipart-empty");
    t.body_kind = .file;
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "empty");
    picker_mode = .choose;
    picker_path = file;
    const prior_calls = picker_calls;
    try tap(@src(), ui, app, rect(ui, t, "choose-upload", null), click);
    try equal(@src(), file, t.file_path.text());
    try check(@src(), picker_calls == prior_calls + 1 and (try settle(app, file)).size == payload.len);
    t.dirty = false;
    picker_mode = .cancel;
    try tap(@src(), ui, app, rect(ui, t, "choose-upload", null), click);
    try equal(@src(), file, t.file_path.text());
    try check(@src(), !t.dirty);
    picker_mode = .fail;
    try tap(@src(), ui, app, rect(ui, t, "choose-upload", null), click);
    try equal(@src(), file, t.file_path.text());
    try check(@src(), !t.dirty);
    if (snapshot != null) for (0..540) |_| frame(ui, app);
    // Every supported mode preserves all three independent draft stores.
    const row = try t.form.add(.{ .key = "upload", .value = "kept value", .is_file = true });
    const modes = [_][]const u8{ "No body", "JSON", "Text", "XML", "Form URL encoded", "Multipart form", "Binary / file" };
    for (modes, 0..) |name, i| {
        try tap(@src(), ui, app, rect(ui, t, "###body-kind", null), click);
        try tap(@src(), ui, app, menu(ui, t, null, "###body-kind", w.z(name)), click);
        for (0..3) |_| frame(ui, app);
        try check(@src(), @backingInt(t.body_kind) == i);
        try equal(@src(), "{\"retained_invalid\":}", t.body.text());
        try equal(@src(), file, t.file_path.text());
        try equal(@src(), "kept value", row.value.text());
        try check(@src(), row.is_file);
        if (i == 0 or i >= 4) try check(@src(), !present(ui, t, "body-editor"));
    }
    const started = app.uploads.started;
    for (0..20) |_| frame(ui, app);
    try check(@src(), app.uploads.started == started);
    // File size changes are explicit Refresh operations, not idle disk polling.
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = file, .data = "updated bytes" });
    try tap(@src(), ui, app, rect(ui, t, "refresh-file-info", null), click);
    try check(@src(), (try settle(app, file)).size == 13);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "selected");
    t.file_path.set(missing);
    try check(@src(), (try settle(app, missing)).status == .missing);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "missing");
    t.file_path.set("{{upload_path}}");
    const path_var = try env.table.add(.{ .key = "upload_path", .value = file });
    commands.setActiveEnv(app, &env);
    try equal(@src(), file, upload.resolve(w.arena.allocator(), t.file_path.text(), app.activeVars()).resolved);
    path_var.value.set(empty);
    app.vars_dirty = true;
    const resolved_empty = upload.resolve(w.arena.allocator(), t.file_path.text(), app.activeVars());
    try equal(@src(), empty, resolved_empty.resolved);
    try check(@src(), (try settle(app, empty)).status == .ready and (try settle(app, empty)).size == 0);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "zero-byte");
    path_var.enabled = false;
    app.vars_dirty = true;
    const before_unresolved = app.uploads.started;
    for (0..4) |_| frame(ui, app);
    try check(@src(), upload.resolve(w.arena.allocator(), t.file_path.text(), app.activeVars()).problem != null and app.uploads.started == before_unresolved);
    try capture(ui, sw, app, snapshot, "unresolved");
    path_var.enabled = true;
    path_var.value.set(file);
    app.vars_dirty = true;
    // Remove affects only the binary path, and Change can select again.
    try tap(@src(), ui, app, rect(ui, t, "remove-upload", null), click);
    try check(@src(), t.file_path.len == 0);
    try equal(@src(), "kept value", row.value.text());
    try equal(@src(), "{\"retained_invalid\":}", t.body.text());
    picker_mode = .choose;
    picker_path = file;
    try tap(@src(), ui, app, rect(ui, t, "choose-upload", null), click);
    // Multipart file mode is explicit and retains values when toggled.
    t.body_kind = .multipart;
    for (0..4) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, "field-type", row.uid), click);
    try check(@src(), !row.is_file);
    try equal(@src(), "kept value", row.value.text());
    try tap(@src(), ui, app, rect(ui, t, "field-type", row.uid), click);
    picker_mode = .cancel;
    try tap(@src(), ui, app, rect(ui, t, "choose-field-file", row.uid), click);
    try equal(@src(), "kept value", row.value.text());
    picker_mode = .choose;
    try tap(@src(), ui, app, rect(ui, t, "choose-field-file", row.uid), click);
    try equal(@src(), file, row.value.text());
    const entry = t.form.entry.?;
    try tap(@src(), ui, app, rect(ui, t, "field-type", entry.uid), click);
    try check(@src(), entry.is_file and t.form.rows.items.len == 1);
    for (0..2) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, "choose-field-file", entry.uid), click);
    try check(@src(), t.form.rows.items.len == 2 and t.form.rows.items[1] == entry and entry.is_file);
    // The picker commits its insertion value, even before a required field name.
    entry.key.set("second");
    entry.enabled = false;
    for (0..3) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, "row-actions", row.uid), click);
    try tap(@src(), ui, app, menu(ui, t, row.uid, "row-actions", "Use text field"), click);
    try check(@src(), !row.is_file);
    // Same menu action is reachable using native keyboard menu navigation.
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, "form");
    c.cui_push_id_int(ui, @intCast(row.uid));
    c.kest_focus(ui, "value");
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    chord(ui, app, c.CUI_KEY_DOWN, c.CUI_MOD_ALT);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), row.is_file);
    for (0..4) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, "row-actions", row.uid), click);
    try tap(@src(), ui, app, menu(ui, t, row.uid, "row-actions", "Inspect row"), click);
    try app.uploads.group.await(app.io);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "multipart-inspect");
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    for (0..3) |_| frame(ui, app);
    // Form and binary geometry across both themes, widths, and native scales.
    entry.is_file = false;
    entry.value.set("Text field value");
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
        app.prefs.dark = dark;
        app.prefs.sidebar_open = true;
        app.prefs.sidebar_width = 320;
        c.cui_set_viewport(ui, width, if (width == 640) 420 else 832, scale);
        for ([_]@import("core/request.zig").BodyKind{ .multipart, .form_urlencoded, .file }) |kind| {
            t.body_kind = kind;
            for (0..4) |_| frame(ui, app);
            if (kind == .file) {
                const controls = rect(ui, t, "upload-controls", null);
                const path = rect(ui, t, "file-path", null);
                const choose = rect(ui, t, "choose-upload", null);
                const remove = rect(ui, t, "remove-upload", null);
                try check(@src(), path.w >= 80 and path.h == 32 and choose.h == 32);
                try check(@src(), path.x + path.w <= choose.x + 1 and choose.x + choose.w <= remove.x + 1 and remove.x + remove.w <= controls.x + controls.w);
                const size = rect(ui, t, "upload-size", null);
                const details = rect(ui, t, "upload-details", null);
                try check(@src(), size.h > 0 and size.y + size.h <= details.y + details.h + 1);
            } else {
                const key = rect(ui, t, "key", row.uid);
                const value = rect(ui, t, "value", row.uid);
                try check(@src(), key.w >= 60 and value.w > key.w and key.h == 32);
                if (kind == .multipart) {
                    const pick = rect(ui, t, "choose-field-file", row.uid);
                    const field_type = rect(ui, t, "field-type", row.uid);
                    try check(@src(), pick.w == 28 and field_type.w == 48 and value.x + value.w <= pick.x + 1 and pick.x + pick.w <= field_type.x + 1);
                }
            }
            if (snapshot != null and width == 640 and scale == 1) try capture(ui, sw, app, snapshot, if (kind == .multipart) (if (dark) "multipart-compact" else "multipart-light") else if (kind == .file) (if (dark) "binary-compact" else "binary-light") else "form-compact");
        }
    };
    entry.is_file = true;
    entry.value.set(file);
    app.prefs.dark = true;
    app.prefs.sidebar_open = false;
    c.cui_set_viewport(ui, 640, 420, 1);
    // Wire checks exercise binary bytes, disabled files and URL-encoded values.
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    t.url.set(try server.url(w.arena.allocator(), "/echo"));
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = file, .data = payload });
    row.value.set("{{upload_path}}");
    row.is_file = true;
    t.body_kind = .multipart;
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    var echo = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.indexOf(u8, echo, "multipart/form-data; boundary=") != null and std.mem.indexOf(u8, echo, "filename=\"upload é sample.bin\"") != null and std.mem.indexOf(u8, echo, payload) != null);
    try check(@src(), std.mem.indexOf(u8, echo, "name=\"second\"") == null);
    t.body_kind = .form_urlencoded;
    row.value.set("a&b + é");
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    try check(@src(), std.mem.endsWith(u8, t.shown.?.resp.preview.items, "upload=a%26b+%2B+%C3%A9") and row.is_file);
    t.body_kind = .file;
    t.file_path.set("{{upload_path}}");
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200 and std.mem.endsWith(u8, t.shown.?.resp.preview.items, payload));
    echo = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.indexOf(u8, echo, "Content-Type: application/octet-stream") != null);
    t.file_path.set(empty);
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    echo = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.endsWith(u8, echo, "\n\n") and std.mem.indexOf(u8, echo, "Content-Length: 0") != null);
    // Missing/directory files fail before opening a network connection.
    var invalid_server: @import("test_server").Server = undefined;
    try invalid_server.start(app.io);
    defer invalid_server.stop();
    t.url.set(try invalid_server.url(w.arena.allocator(), "/echo"));
    for ([_][]const u8{ missing, app.tmp_dir }) |bad| {
        t.file_path.set(bad);
        commands.send(app, t);
        try wait(ui, app, t, frame);
        try check(@src(), t.shown != null and t.shown.?.resp.stop == .failed and invalid_server.conn_counter.load(.acquire) == 0);
        if (std.mem.eql(u8, bad, app.tmp_dir)) try check(@src(), std.mem.indexOf(u8, t.shown.?.resp.error_text, "Not a regular file") != null);
    }
    t.file_path.set("{{upload_path}}");
    t.body_kind = .multipart;
    row.value.set("{{upload_path}}");
    persist.touchTab(app, t);
    persist.flush(app);
    persist.savePrefs(app);
    app.store.sync();
    {
        var restored = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
        defer restored.deinit();
        try persist.load(&restored);
        const loaded = restored.current() orelse return error.MissingDraft;
        try equal(@src(), "{{upload_path}}", loaded.file_path.text());
        try equal(@src(), "{\"retained_invalid\":}", loaded.body.text());
        try check(@src(), loaded.body_kind == .multipart and loaded.form.rows.items.len == 2 and loaded.form.rows.items[0].is_file and !loaded.form.rows.items[1].enabled);
    }
    // Closing a tab cannot invalidate a pending metadata worker's path.
    const closing = commands.newTab(app) orelse return error.AllocationFailed;
    closing.file_path.set(file);
    _ = upload.info(app, closing.file_path.text(), true);
    commands.closeNow(app, closing);
    try app.uploads.group.await(app.io);
    try check(@src(), upload.info(app, file, false).status == .ready);
    t.body_kind = .file;
    t.file_path.set(file);
    c.cui_input_mouse_move(ui, -20, -20);
    const idle_started = app.uploads.started;
    for (0..800) |_| frame(ui, app);
    try check(@src(), app.uploads.started == idle_started and !c.cui_needs_redraw(ui) and c.cui_next_wakeup(ui) < 0);
    std.debug.print("CUI uploads: bounded async metadata/ownership, picker cancel/error, seven-mode preservation, multipart types/picking, binary details, geometry, real file/form payloads and draft reload passed\n", .{});
}
