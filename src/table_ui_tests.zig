//! Native cell/menu events, scoped undo, bounded tables and current headers.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const kv = @import("ui/key_value.zig");
const validation = @import("ui/table_validation.zig");

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Table UI regression at {s}:{d}\n", .{ src.file, src.line });
        return error.TableUiRegression;
    }
}
fn scope(ui: *c.cui_ctx, t: *tab.Tab, kind: kv.Kind, row: ?u32) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.cui_push_id(ui, kind.scope());
    if (row) |uid| c.cui_push_id_int(ui, @intCast(uid));
}
fn unscope(ui: *c.cui_ctx, row: ?u32) void {
    if (row != null) c.cui_pop_id(ui);
    c.cui_pop_id(ui);
    c.cui_pop_id(ui);
}
fn rect(ui: *c.cui_ctx, t: *tab.Tab, kind: kv.Kind, row: ?u32, key: [*:0]const u8) c.cui_rect {
    scope(ui, t, kind, row);
    defer unscope(ui, row);
    const suffix: c.cui_id = if (std.mem.eql(u8, std.mem.span(key), "###enabled") or std.mem.eql(u8, std.mem.span(key), "###file")) 0xc0ec0001 else 0;
    return c.cui_get_rect(ui, c.cui_make_id(ui, key) ^ suffix);
}
fn focus(ui: *c.cui_ctx, t: *tab.Tab, kind: kv.Kind, row: u32, key: [*:0]const u8) void {
    scope(ui, t, kind, row);
    defer unscope(ui, row);
    c.kest_focus(ui, key);
}
fn focused(ui: *c.cui_ctx, t: *tab.Tab, kind: kv.Kind, row: u32, key: [*:0]const u8) bool {
    scope(ui, t, kind, row);
    defer unscope(ui, row);
    return c.kest_editor_focus(ui, c.cui_make_id(ui, key)) != 0;
}
fn tap(src: std.builtin.SourceLocation, ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime click: anytype) !void {
    try check(src, r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn menu(ui: *c.cui_ctx, t: *tab.Tab, kind: kv.Kind, row: ?u32, label: [*:0]const u8) c.cui_rect {
    scope(ui, t, kind, row);
    defer unscope(ui, row);
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, if (row == null) "table-actions" else "row-actions") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn pane(ui: *c.cui_ctx, app: *App, t: *tab.Tab, key: [*:0]const u8, comptime click: anytype) !void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    const r = c.cui_get_rect(ui, c.cui_make_id(ui, key));
    c.cui_pop_id(ui);
    try tap(@src(), ui, app, r, click);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-tables-{s}.png", .{ stem, suffix });
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

fn environmentUndo(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime chord: anytype) !void {
    const tree = @import("app/tree_ops.zig");
    const first = tree.addEnvironment(app, "Table undo A") orelse return error.AllocationFailed;
    defer tree.deleteEnv(app, first);
    const second = tree.addEnvironment(app, "Table undo B") orelse return error.AllocationFailed;
    defer tree.deleteEnv(app, second);
    const a = try first.table.add(.{ .key = "name", .value = "first original" });
    const b = try second.table.add(.{ .key = "name", .value = "second original" });
    app.editing_env = first;
    app.modal = .environment;
    app.modal_open = true;
    a.value.focus();
    for (0..3) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "first changed");
    frame(ui, app);
    app.editing_env = second;
    b.value.focus();
    for (0..3) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "second changed");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, b.value.text(), "second original") and std.mem.eql(u8, a.value.text(), "first changed"));
    app.editing_env = first;
    a.value.focus();
    for (0..3) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, a.value.text(), "first original"));
    app.modal_open = false;
    for (0..3) |_| frame(ui, app);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const original_tabs = app.tabs;
    const original_active = app.active;
    const original_prefs = app.prefs;
    const original_env = app.active_env;
    const original_editing_env = app.editing_env;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = original_tabs;
        app.active = original_active;
        app.prefs = original_prefs;
        app.active_env = original_env;
        app.editing_env = original_editing_env;
        app.vars_dirty = true;
        app.modal_open = false;
        app.modal = .none;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.url.set("https://example.invalid/path");
    t.pane = .params;
    t.pane_chosen = true;
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    app.prefs.dark = true;
    const h0 = try t.headers.add(.{ .key = "X-Value", .value = "header original" });
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..5) |_| frame(ui, app);
    if (snapshot != null) {
        // Let notifications from earlier, unrelated fixtures expire before
        // collecting table evidence. This advances only the software UI clock.
        c.cui_input_mouse_move(ui, -10, -10);
        for (0..540) |_| frame(ui, app);
    }
    const insertion = t.params.entry.?;
    const empty = rect(ui, t, .params, null, "kv-grid");
    try check(@src(), empty.h <= 63 and t.params.rows.items.len == 0);
    try capture(ui, sw, app, snapshot, "empty");
    try tap(@src(), ui, app, rect(ui, t, .params, insertion.uid, "key"), click);
    c.cui_input_text(ui, "dup");
    frame(ui, app);
    const p0 = t.params.rows.items[0];
    try check(@src(), p0 == insertion);
    chord(ui, app, c.CUI_KEY_TAB, 0);
    try check(@src(), focused(ui, t, .params, p0.uid, "value"));
    c.cui_input_text(ui, "value1");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    const next = t.params.entry.?;
    try check(@src(), focused(ui, t, .params, next.uid, "key"));
    c.cui_input_text(ui, "dup");
    frame(ui, app);
    const p1 = t.params.rows.items[1];
    chord(ui, app, c.CUI_KEY_TAB, 0);
    c.cui_input_text(ui, "value2");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_UP, 0);
    try check(@src(), focused(ui, t, .params, p0.uid, "value"));
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_SHIFT);
    try check(@src(), focused(ui, t, .params, p0.uid, "key"));
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    try check(@src(), focused(ui, t, .params, p1.uid, "key"));
    // A queued notice must not intercept lower popup actions, independently of
    // which earlier application fixtures happened to produce notifications.
    _ = c.cui_toast_ex(ui, "Table action regression notice", &.{ .duration = 8 });
    chord(ui, app, c.CUI_KEY_DOWN, c.CUI_MOD_ALT);
    try tap(@src(), ui, app, menu(ui, t, .params, p1.uid, "Duplicate row"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.params.rows.items.len == 3 and std.mem.eql(u8, t.params.rows.items[2].value.text(), "value2"));
    const copied = t.params.rows.items[2];
    chord(ui, app, c.CUI_KEY_DOWN, c.CUI_MOD_ALT);
    try tap(@src(), ui, app, menu(ui, t, .params, copied.uid, "Move up"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.params.rows.items[1] == copied and t.params.rows.items[2] == p1);
    chord(ui, app, c.CUI_KEY_DOWN, c.CUI_MOD_ALT);
    try tap(@src(), ui, app, menu(ui, t, .params, copied.uid, "Delete row"), click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.params.rows.items.len == 2 and t.params.rows.items[1] == p1);
    if (snapshot != null) for (0..540) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_UP, 0);
    try tap(@src(), ui, app, rect(ui, t, .params, p0.uid, "###enabled"), click);
    try check(@src(), !p0.enabled and std.mem.endsWith(u8, t.url.text(), "?dup=value2"));
    try tap(@src(), ui, app, rect(ui, t, .params, p0.uid, "###enabled"), click);
    try check(@src(), p0.enabled and std.mem.endsWith(u8, t.url.text(), "?dup=value1&dup=value2"));
    // Identical numeric row ids in distinct sections must never share undo.
    focus(ui, t, .params, p0.uid, "value");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "param changed");
    frame(ui, app);
    try pane(ui, app, t, "pane-headers", click);
    focus(ui, t, .headers, h0.uid, "value");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "header changed");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, h0.value.text(), "header original") and std.mem.eql(u8, p0.value.text(), "param changed"));
    try pane(ui, app, t, "pane-params", click);
    focus(ui, t, .params, p0.uid, "value");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), std.mem.eql(u8, p0.value.text(), "value1"));
    // A fresh bulk session must not borrow undo from a cancelled session.
    try tap(@src(), ui, app, rect(ui, t, .params, null, "table-actions"), click);
    try tap(@src(), ui, app, menu(ui, t, .params, null, "Bulk edit"), click);
    for (0..2) |_| frame(ui, app);
    const first_session = t.params.bulk_session;
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "temporary: edit");
    frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, .params, null, "cancel-bulk"), click);
    for (0..3) |_| frame(ui, app);
    try environmentUndo(ui, app, frame, chord);
    kv.openBulk(&t.params);
    frame(ui, app);
    const before_undo = try app.gpa.dupe(u8, t.params.bulk.?.text());
    defer app.gpa.free(before_undo);
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try check(@src(), t.params.bulk_session != first_session and std.mem.eql(u8, before_undo, t.params.bulk.?.text()));
    try tap(@src(), ui, app, rect(ui, t, .params, null, "cancel-bulk"), click);
    for (0..3) |_| frame(ui, app);
    // Validation is current, non-destructive and uses static, non-secret hints.
    try check(@src(), validation.check(w.arena.allocator(), .headers, "Bad Name", "v", &.{}).danger);
    try check(@src(), validation.check(w.arena.allocator(), .headers, "X-A", "a\r\nb", &.{}).danger);
    try check(@src(), validation.check(w.arena.allocator(), .params, "q", "a&b#c%2f", &.{}).message == null);
    try check(@src(), validation.check(w.arena.allocator(), .headers, "Authorization", "{{token}}", &.{}).message != null);
    const vars = [_]@import("core/variables.zig").Var{ .{ .key = "token", .value = "secret" }, .{ .key = "header", .value = "aCcEpT" } };
    try check(@src(), validation.check(w.arena.allocator(), .headers, "Authorization", "{{token}}", &vars).message == null);
    _ = try t.headers.add(.{ .key = "{{header}}", .value = "custom" });
    try check(@src(), @import("ui/table_headers.zig").configured(t, "Accept", &vars));
    t.headers.rows.items[1].enabled = false;
    try check(@src(), !@import("ui/table_headers.zig").configured(t, "ACCEPT", &vars));
    // Geometry and row visibility across request layouts, themes and DPI.
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
        app.prefs.dark = dark;
        app.prefs.sidebar_open = true;
        app.prefs.sidebar_width = 320;
        c.cui_set_viewport(ui, width, if (width == 640) 420 else 832, scale);
        for ([_]tab.RequestPane{ .params, .headers }) |selected| {
            t.pane = selected;
            const kind: kv.Kind = if (selected == .params) .params else .headers;
            const row = if (selected == .params) p0 else h0;
            for (0..4) |_| frame(ui, app);
            const grid = rect(ui, t, kind, null, "kv-grid");
            const key = rect(ui, t, kind, row.uid, "key");
            const value = rect(ui, t, kind, row.uid, "value");
            const actions = rect(ui, t, kind, row.uid, "row-actions");
            try check(@src(), key.w >= 60 and value.w > key.w and key.h == 32 and value.h == 32);
            try check(@src(), key.x >= grid.x and key.x + key.w <= value.x + 1 and value.x + value.w <= actions.x + 1);
            try check(@src(), actions.x + actions.w <= grid.x + grid.w + 1 and actions.y + actions.h <= grid.y + grid.h + 1);
            if (snapshot != null and width == 640 and scale == 1 and selected == .params) try capture(ui, sw, app, snapshot, if (dark) "compact" else "light");
        }
    };
    app.prefs.dark = true;
    app.prefs.sidebar_open = false;
    c.cui_set_viewport(ui, 640, 420, 1);
    t.pane = .headers;
    h0.key.set("Bad Name");
    var long_value: std.ArrayList(u8) = .empty;
    defer long_value.deinit(app.gpa);
    for (0..100) |_| try long_value.appendSlice(app.gpa, "long-value-component/");
    h0.value.set(long_value.items);
    focus(ui, t, .headers, h0.uid, "value");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_END, 0);
    c.cui_input_text(ui, "tail");
    frame(ui, app);
    try check(@src(), std.mem.endsWith(u8, h0.value.text(), "component/tail"));
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "invalid");
    // Context menu applies to a cell, not just the trailing action target.
    const context_cell = rect(ui, t, .headers, h0.uid, "key");
    c.cui_input_mouse_move(ui, context_cell.x + 20, context_cell.y + 16);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, false);
    frame(ui, app);
    try tap(@src(), ui, app, menu(ui, t, .headers, h0.uid, "Inspect row"), click);
    for (0..3) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "inspect");
    const inspector_bounds = rect(ui, t, .headers, null, "row-inspector");
    try check(@src(), inspector_bounds.x >= 0 and inspector_bounds.y >= 0 and inspector_bounds.x + inspector_bounds.w <= 640 and inspector_bounds.y + inspector_bounds.h <= 420);
    // Switching away closes an inspector that no longer has a rendered owner.
    t.pane = .params;
    for (0..3) |_| frame(ui, app);
    focus(ui, t, .params, p0.uid, "key");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    try check(@src(), focused(ui, t, .params, p1.uid, "key"));
    chord(ui, app, c.CUI_KEY_F10, c.CUI_MOD_SHIFT);
    try check(@src(), menu(ui, t, .params, p1.uid, "Inspect row").w > 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), !p1.enabled);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), p1.enabled);
    // Virtualized navigation reveals the last insertion cell and keeps controls
    // inside the scrolling table even with hundreds of configured rows.
    for (0..200) |i| _ = try t.params.add(.{ .key = "item", .value = w.fmt("value {d}", .{i}) });
    for (0..3) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, .params, null, "table-actions"), click);
    try tap(@src(), ui, app, menu(ui, t, .params, null, "Add row"), click);
    for (0..3) |_| frame(ui, app);
    const final_entry = rect(ui, t, .params, t.params.entry.?.uid, "key");
    const viewport = rect(ui, t, .params, null, "kv-rows");
    try check(@src(), final_entry.y >= viewport.y - 1 and final_entry.y + final_entry.h <= viewport.y + viewport.h + 1);
    chord(ui, app, c.CUI_KEY_UP, 0);
    try check(@src(), focused(ui, t, .params, t.params.rows.items[201].uid, "key"));
    // Current generated-header inspection uses the actual default-header list.
    t.pane = .headers;
    h0.key.set("aCcEpT");
    h0.value.set("application/custom");
    t.body_kind = .json;
    t.body.setText("{}");
    for (0..3) |_| frame(ui, app);
    try tap(@src(), ui, app, rect(ui, t, .headers, null, "table-actions"), click);
    try tap(@src(), ui, app, menu(ui, t, .headers, null, "Automatic request headers"), click);
    for (0..4) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "automatic");
    const automatic_bounds = rect(ui, t, .headers, null, "automatic-headers");
    try check(@src(), automatic_bounds.x >= 0 and automatic_bounds.y >= 0 and automatic_bounds.x + automatic_bounds.w <= 640 and automatic_bounds.y + automatic_bounds.h <= 420);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    t.url.set(try server.url(w.arena.allocator(), "/echo"));
    t.method.set("POST");
    _ = try t.headers.add(.{ .key = "Content-Length", .value = "999" });
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    const echo = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.indexOf(u8, echo, "aCcEpT: application/custom") != null and std.mem.indexOf(u8, echo, "Accept: */*") == null);
    try check(@src(), std.mem.indexOf(u8, echo, "Content-Length: 2") != null and std.mem.indexOf(u8, echo, "Content-Length: 999") == null);
    try check(@src(), std.mem.indexOf(u8, echo, "Content-Type: application/json") != null);
    std.debug.print("CUI table UI: compact geometry, cell navigation, scoped undo/bulk sessions, row actions, validation, virtual reveal and actual automatic headers passed\n", .{});
}
