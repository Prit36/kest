//! Isolated document workspace: real native tab/menu pointer and key events.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const workspace = @import("ui/workspace.zig");

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Document regression at {s}:{d}\n", .{ src.file, src.line });
        return error.DocumentRegression;
    }
}
fn documentId(ui: *c.cui_ctx, t: *tab.Tab) c.cui_id {
    c.cui_push_id(ui, "request-documents");
    defer c.cui_pop_id(ui);
    return c.cui_make_id(ui, workspace.documentTitle(t));
}
fn menuItem(ui: *c.cui_ctx, t: *tab.Tab) c.cui_rect {
    c.cui_push_id_int(ui, @bitCast(c.cui_make_id(ui, "###open-requests") ^ 0x3e40));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, workspace.documentTitle(t)));
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const original_tabs = app.tabs;
    const original_active = app.active;
    const original_prefs = app.prefs;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = original_tabs;
        app.active = original_active;
        app.prefs = original_prefs;
        app.modal_open = false;
        app.modal = .none;
        app.pending = .none;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    var docs: [12]*tab.Tab = undefined;
    for (&docs, 0..) |*slot, i| {
        const t = commands.newTab(app) orelse return error.AllocationFailed;
        slot.* = t;
        const name = try std.fmt.allocPrint(app.gpa, "Order API ## literal ### name {d} with a long complete description", .{i});
        defer app.gpa.free(name);
        try tab.setOwned(app.gpa, &t.name, name);
        t.method.set(([_][]const u8{ "GET", "POST", "OPTIONS", "PROPFIND" })[i % 4]);
    }
    for ([_]bool{ true, false }) |dark| for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| for ([_]f32{ 640, 840, 1282 }) |width| {
        app.prefs.dark = dark;
        app.prefs.sidebar_open = true;
        app.prefs.sidebar_width = 320;
        c.cui_set_viewport(ui, width, 832, scale);
        for (0..5) |_| frame(ui, app);
        const active = c.cui_get_rect(ui, documentId(ui, docs[11]));
        const strip = c.cui_get_rect(ui, c.cui_make_id(ui, "request-documents") ^ 0xd0c7);
        try check(@src(), active.w >= 144 and active.w <= 280);
        try check(@src(), active.x >= strip.x - 1 and active.x + active.w <= strip.x + strip.w + 1);
        inline for (.{ "new-document", "###open-requests", "###workspace-layout" }) |key| {
            const action = c.cui_get_rect(ui, c.cui_make_id(ui, key));
            try check(@src(), action.w > 0 and action.x >= strip.x + strip.w - 1 and action.x + action.w <= width);
        }
    };
    app.prefs.dark = true;
    app.prefs.sidebar_open = false;
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..5) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "tabs-compact");
    const strip = c.cui_get_rect(ui, c.cui_make_id(ui, "request-documents") ^ 0xd0c7);
    const first_x = c.cui_get_rect(ui, documentId(ui, docs[0])).x;
    c.cui_input_mouse_move(ui, strip.x + strip.w / 2, strip.y + strip.h / 2);
    frame(ui, app);
    c.cui_input_scroll(ui, 0, 10);
    for (0..3) |_| frame(ui, app);
    const wheel_x = c.cui_get_rect(ui, documentId(ui, docs[0])).x;
    try check(@src(), wheel_x > first_x + 10 and app.current().? == docs[11]);
    c.cui_input_scroll(ui, -10, 0);
    for (0..3) |_| frame(ui, app);
    try check(@src(), c.cui_get_rect(ui, documentId(ui, docs[0])).x < wheel_x - 10);
    const trigger = c.cui_get_rect(ui, c.cui_make_id(ui, "###open-requests"));
    click(ui, app, trigger.x + trigger.w / 2, trigger.y + trigger.h / 2);
    for (0..3) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "tabs-menu");
    const option = menuItem(ui, docs[0]);
    try check(@src(), option.w > 0 and option.h >= 32 and option.x >= 0 and option.x + option.w <= 640);
    click(ui, app, option.x + option.w / 2, option.y + option.h / 2);
    for (0..3) |_| frame(ui, app);
    try check(@src(), app.current().? == docs[0]);
    chord(ui, app, c.CUI_KEY_RIGHT, 0);
    try check(@src(), app.current().? == docs[1]);
    chord(ui, app, c.CUI_KEY_END, 0);
    try check(@src(), app.current().? == docs[11]);
    chord(ui, app, c.CUI_KEY_HOME, 0);
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_PRIMARY);
    try check(@src(), app.current().? == docs[1]);
    chord(ui, app, c.CUI_KEY_RIGHT, 0);
    try check(@src(), app.current().? == docs[2]);
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    try check(@src(), app.current().? == docs[1]);
    click(ui, app, trigger.x + trigger.w / 2, trigger.y + trigger.h / 2);
    for (0..12) |_| chord(ui, app, c.CUI_KEY_DOWN, 0);
    const last = menuItem(ui, docs[11]);
    try check(@src(), last.y >= 76 and last.y + last.h <= 420);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), app.current().? == docs[11]);
    // Middle click uses the same close policy as a close button or Ctrl+W.
    const middle = c.cui_get_rect(ui, documentId(ui, docs[11]));
    c.cui_input_mouse_move(ui, middle.x + middle.w / 2, middle.y + middle.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_MIDDLE, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_MIDDLE, false);
    frame(ui, app);
    try check(@src(), app.tabs.items.len == 11);
    chord(ui, app, c.CUI_KEY_LEFT, 0);
    try check(@src(), app.current().? == docs[9]);
    commands.activate(app, 0);
    docs[0].url.set("https://example.invalid/unsaved");
    @import("app/persist.zig").touchTab(app, docs[0]);
    for (0..5) |_| frame(ui, app);
    const active_id = documentId(ui, docs[0]);
    const close = c.cui_get_rect(ui, active_id ^ 0xc105e);
    const marker = c.cui_get_rect(ui, active_id ^ 0xd17);
    try check(@src(), marker.x + marker.w <= close.x);
    try capture(ui, sw, app, snapshot, "tabs-dirty");
    click(ui, app, close.x + close.w / 2, close.y + close.h / 2);
    try check(@src(), app.modal_open and app.pending == .close_tab and app.pending.close_tab == docs[0]);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), app.tabs.items.len == 11 and docs[0].dirty);
    app.modal_open = false;
    app.modal = .none;
    app.pending = .none;
    // Every request-opening path must respect the document array's capacity.
    while (app.tabs.items.len < 64) _ = commands.newTab(app) orelse return error.AllocationFailed;
    try check(@src(), commands.newTab(app) == null);
    const collection = @import("core/collection.zig");
    const unopened = try collection.create(app.gpa, collection.newId(app.io), .request, "Capacity check", "GET");
    defer collection.destroy(app.gpa, unopened);
    commands.openRequest(app, unopened);
    try check(@src(), app.tabs.items.len == 64);
    try check(@src(), std.mem.eql(u8, app.toaster.items.items[app.toaster.items.items.len - 1].title, "Tab limit reached"));
    const existing = app.tabs.items[63];
    existing.link = .{ .collection = unopened.id, .request = unopened.id };
    commands.activate(app, 0);
    commands.openRequest(app, unopened);
    try check(@src(), app.current().? == existing and app.tabs.items.len == 64);
    existing.link = null;
    for (0..3) |_| frame(ui, app);
    try restoration(app);
    std.debug.print("CUI documents: bounded widths, literal names, overflow/keyboard reveal, wheel/trackpad scrolling, middle close, dirty cancel and capacity passed\n", .{});
}

fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}

fn restoration(app: *App) !void {
    const persist = @import("app/persist.zig");
    for (app.tabs.items, 0..) |t, i| {
        const name = try std.fmt.allocPrint(app.gpa, "Restore request {d}", .{i});
        defer app.gpa.free(name);
        try tab.setOwned(app.gpa, &t.name, name);
        t.pane = if (i % 2 == 0) .headers else .body;
        persist.touchTab(app, t);
    }
    persist.flush(app);
    persist.savePrefs(app);
    app.store.sync();
    {
        var restored = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
        defer restored.deinit();
        try persist.load(&restored);
        try check(@src(), restored.tabs.items.len == 64 and restored.active == app.active);
        for (restored.tabs.items, app.tabs.items) |loaded, original| {
            try check(@src(), std.mem.eql(u8, loaded.name, original.name) and loaded.pane == original.pane);
        }
    }
    // Skipping an untouched blank tab must not shift the selected request.
    commands.closeNow(app, app.tabs.items[0]);
    _ = commands.newTab(app) orelse return error.AllocationFailed;
    commands.moveTab(app, 63, 0);
    commands.activate(app, 5);
    const selected = app.current().?;
    persist.savePrefs(app);
    app.store.sync();
    var restored = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
    defer restored.deinit();
    try persist.load(&restored);
    try check(@src(), restored.tabs.items.len == 63 and restored.current() != null);
    try check(@src(), std.mem.eql(u8, restored.current().?.name, selected.name));
    std.debug.print("CUI documents: all 64 drafts restore with per-request views; skipped blank tabs retain the selected request\n", .{});
}
