//! Keyboard-only workflow (req. 46): create, edit, send and inspect a
//! request without pointer input, and keep focus sensible after closing the
//! palette, toggling the sidebar and deleting the selected item.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const tree = @import("app/tree_ops.zig");

fn check(src: std.builtin.SourceLocation, value: bool, ui: *c.cui_ctx) !void {
    if (!value) {
        std.debug.print("Keyboard regression at {s}:{d} (focus {s})\n", .{ src.file, src.line, std.mem.span(c.kest_focus_label(ui)) });
        return error.KeyboardRegression;
    }
}
/// Focus is on `key` (or inside it) within the request tab's scope.
fn focusIn(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) bool {
    if (c.kest_focus_inside(ui, key)) return true;
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.kest_focus_inside(ui, key);
}
fn label(ui: *c.cui_ctx) []const u8 {
    return std.mem.span(c.kest_focus_label(ui));
}
fn labelHas(ui: *c.cui_ctx, text: []const u8) bool {
    return std.mem.indexOf(u8, label(ui), text) != null;
}
/// Presses Tab until `done`, at most `limit` times.
fn tabUntil(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime chord: anytype, limit: usize, ctx: anytype, comptime done: fn (*c.cui_ctx, @TypeOf(ctx)) bool) bool {
    _ = frame;
    for (0..limit) |_| {
        if (done(ui, ctx)) return true;
        chord(ui, app, c.CUI_KEY_TAB, 0);
    }
    return done(ui, ctx);
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime chord: anytype, comptime wait: anytype) !void {
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    const original_prefs = app.prefs;
    const original_selected = app.selected;
    const original_mode = app.mode;
    defer {
        app.prefs = original_prefs;
        app.selected = original_selected;
        app.mode = original_mode;
        app.palette_open = false;
        app.modal_open = false;
        app.modal = .none;
        app.pending = .none;
        app.rows_dirty = true;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    app.prefs.sidebar_open = true;
    app.prefs.log_open = false;
    app.prefs.autosave = false;
    app.mode = .collections;
    c.cui_set_viewport(ui, 1282, 832, 1);
    // No pointer input at all from here on.
    c.cui_input_mouse_move(ui, -100, -100);
    for (0..3) |_| frame(ui, app);

    // Ctrl N creates a request with the URL field focused; typing fills it.
    chord(ui, app, c.CUI_KEY_N, c.CUI_MOD_PRIMARY);
    for (0..2) |_| frame(ui, app);
    const t = app.current().?;
    try check(@src(), focusIn(ui, t, "url"), ui);
    // The frame arena is reset each frame; keep a copy to compare with.
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}", .{try server.url(w.arena.allocator(), "/echo")});
    c.cui_input_text(ui, w.z(url));
    for (0..2) |_| frame(ui, app);
    try check(@src(), std.mem.eql(u8, t.url.text(), url), ui);

    // Shift Tab reaches the method; Down opens its menu and moves through
    // it, Enter picks. (The highlight is not keyboard focus, so try each
    // position from the button until POST is chosen.)
    chord(ui, app, c.CUI_KEY_TAB, c.CUI_MOD_SHIFT);
    try check(@src(), labelHas(ui, "GET"), ui);
    const method_button = c.kest_get_focus(ui);
    for (1..8) |steps| {
        if (std.mem.eql(u8, t.method.text(), "POST")) break;
        c.kest_set_focus(ui, method_button);
        for (0..steps) |_| chord(ui, app, c.CUI_KEY_DOWN, 0);
        chord(ui, app, c.CUI_KEY_ENTER, 0);
        for (0..2) |_| frame(ui, app);
    }
    try check(@src(), std.mem.eql(u8, t.method.text(), "POST") and t.job == null, ui);

    // Tab to the request sections; arrows move between them (Body).
    const sections = struct {
        fn at(u: *c.cui_ctx, _: void) bool {
            return labelHas(u, "Params") or labelHas(u, "Body") or labelHas(u, "Headers") or labelHas(u, "Settings");
        }
    };
    try check(@src(), tabUntil(ui, app, frame, chord, 12, {}, sections.at), ui);
    var guard: usize = 0;
    while (t.pane != .body and guard < 4) : (guard += 1) chord(ui, app, c.CUI_KEY_RIGHT, 0);
    for (0..2) |_| frame(ui, app);
    try check(@src(), t.pane == .body, ui);

    // The body type menu: choose JSON from the keyboard.
    const kind = struct {
        fn at(u: *c.cui_ctx, _: void) bool {
            return labelHas(u, "No body");
        }
    };
    try check(@src(), tabUntil(ui, app, frame, chord, 6, {}, kind.at), ui);
    const kind_button = c.kest_get_focus(ui);
    for (1..8) |steps| {
        if (t.body_kind == .json) break;
        c.kest_set_focus(ui, kind_button);
        chord(ui, app, c.CUI_KEY_ENTER, 0);
        for (0..steps) |_| chord(ui, app, c.CUI_KEY_DOWN, 0);
        chord(ui, app, c.CUI_KEY_ENTER, 0);
        for (0..2) |_| frame(ui, app);
    }
    try check(@src(), t.body_kind == .json, ui);
    c.kest_set_focus(ui, kind_button);
    frame(ui, app);

    // Tab into the body editor and type a payload.
    const editor = struct {
        fn at(u: *c.cui_ctx, tt: *tab.Tab) bool {
            return focusIn(u, tt, "body-editor");
        }
    };
    try check(@src(), tabUntil(ui, app, frame, chord, 10, t, editor.at), ui);
    c.cui_input_text(ui, "{\"keyboard\":true}");
    for (0..2) |_| frame(ui, app);
    try check(@src(), std.mem.indexOf(u8, t.body.text(), "\"keyboard\":true") != null, ui);

    // Ctrl Enter sends from the editor; focus stays where the person was.
    const before_send = c.kest_get_focus(ui);
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY);
    try wait(ui, app);
    for (0..2) |_| frame(ui, app);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200, ui);
    try check(@src(), std.mem.indexOf(u8, t.shown.?.resp.preview.items, "keyboard") != null, ui);
    try check(@src(), c.kest_get_focus(ui) == before_send, ui);

    // Tab reaches the response: its status, view selector and the body
    // viewer; Ctrl F there opens Find in the response.
    const status = struct {
        fn at(u: *c.cui_ctx, _: void) bool {
            return labelHas(u, "200");
        }
    };
    // In the editor Tab indents; Ctrl M makes Tab move focus instead.
    chord(ui, app, c.CUI_KEY_M, c.CUI_MOD_PRIMARY);
    try check(@src(), t.body.tab_moves_focus, ui);
    try check(@src(), tabUntil(ui, app, frame, chord, 12, {}, status.at), ui);
    try check(@src(), std.mem.indexOfScalar(u8, t.body.text(), 9) == null, ui);
    const viewer = struct {
        fn at(u: *c.cui_ctx, tt: *tab.Tab) bool {
            return focusIn(u, tt, "response-content");
        }
    };
    try check(@src(), tabUntil(ui, app, frame, chord, 6, t, viewer.at), ui);
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    for (0..2) |_| frame(ui, app);
    try check(@src(), t.response.code_raw.search_open or t.response.code_pretty.search_open, ui);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    for (0..2) |_| frame(ui, app);

    // The palette: Escape returns focus to where it was, and Tab continues
    // from there rather than from the window's first control.
    c.kest_focus(ui, "collection-filter");
    for (0..2) |_| frame(ui, app);
    const filter = c.kest_get_focus(ui);
    chord(ui, app, c.CUI_KEY_P, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    for (0..2) |_| frame(ui, app);
    try check(@src(), app.palette_open and c.kest_get_focus(ui) != filter, ui);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    for (0..2) |_| frame(ui, app);
    try check(@src(), !app.palette_open and c.kest_get_focus(ui) == filter, ui);

    // Closing the sidebar around the keyboard moves focus to its toggle;
    // Enter on the toggle opens it again.
    chord(ui, app, c.CUI_KEY_B, c.CUI_MOD_PRIMARY);
    for (0..3) |_| frame(ui, app);
    try check(@src(), !app.prefs.sidebar_open, ui);
    try check(@src(), c.kest_get_focus(ui) == @import("ui/shell.zig").sidebarToggleId(), ui);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    for (0..3) |_| frame(ui, app);
    try check(@src(), app.prefs.sidebar_open, ui);

    // Deleting the selected item keeps the keyboard in the tree, on the
    // next item.
    const collection = tree.newCollection(app, "Keyboard delete") orelse return error.AllocationFailed;
    defer tree.deleteNode(app, collection);
    collection.expanded = true;
    const doomed = tree.addRequest(app, collection, .{ .name = "Doomed", .method = "GET", .url = "https://example.invalid/a" }) orelse return error.AllocationFailed;
    const next = tree.addRequest(app, collection, .{ .name = "Next", .method = "GET", .url = "https://example.invalid/b" }) orelse return error.AllocationFailed;
    app.store.sync();
    @import("ui/sidebar.zig").reveal(app, doomed);
    for (0..4) |_| frame(ui, app);
    c.kest_focus(ui, "collection-rows");
    for (0..2) |_| frame(ui, app);
    try check(@src(), app.selected == doomed, ui);
    commands.confirm(app, .{ .delete_node = doomed }, "Delete permanently?", doomed.name, "Delete");
    for (0..2) |_| frame(ui, app);
    try check(@src(), app.modal_open, ui);
    // The confirm dialog's primary action, from the keyboard.
    const confirm = struct {
        fn at(u: *c.cui_ctx, _: void) bool {
            return labelHas(u, "Delete") and !labelHas(u, "permanently");
        }
    };
    try check(@src(), tabUntil(ui, app, frame, chord, 6, {}, confirm.at), ui);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    for (0..3) |_| frame(ui, app);
    try check(@src(), !app.modal_open and collection.children.items.len == 1, ui);
    try check(@src(), app.selected == next, ui);
    try check(@src(), c.kest_focus_inside(ui, "collection-rows"), ui);
    std.debug.print("CUI keyboard only: Ctrl N, URL typing, method and body type menus, section arrows, body typing, Ctrl Enter send keeps focus, response status/viewer/Find, palette Escape focus return, sidebar close focus, delete keeps tree focus passed\n", .{});
}
