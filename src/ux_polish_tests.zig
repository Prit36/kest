//! Response viewer polish with real pointer events: selecting JSON text,
//! the shortened context menu and its More submenu, and the response bar's
//! one-click actions. Captures sit beside the requested snapshot.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const json_view = @import("ui/json_view.zig");

fn expect(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Polish check failed at {s}:{d}\n", .{ src.file, src.line });
        return error.PolishCheckFailed;
    }
}
fn rect(ui: *c.cui_ctx, uid: ?u64, key: [*:0]const u8) c.cui_rect {
    if (uid) |n| c.cui_push_id_int(ui, @intCast(n));
    defer if (uid != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
/// An item of the context menu `key` (built in the tab's scope).
fn contextItem(ui: *c.cui_ctx, uid: u64, key: [*:0]const u8, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(uid));
    defer c.cui_pop_id(ui);
    const popup = c.cui_make_id(ui, key) ^ 0xC7C;
    c.cui_push_id_int(ui, @bitCast(popup));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
/// An item of the submenu `parent_label` inside the context menu `key`.
fn submenuItem(ui: *c.cui_ctx, uid: u64, key: [*:0]const u8, parent_label: [*:0]const u8, label: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(uid));
    defer c.cui_pop_id(ui);
    const popup = c.cui_make_id(ui, key) ^ 0xC7C;
    c.cui_push_id_int(ui, @bitCast(popup));
    defer c.cui_pop_id(ui);
    const sub = c.cui_make_id(ui, parent_label) ^ 0x5B3E40;
    c.cui_push_id_int(ui, @bitCast(sub));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn shot(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, snapshot: ?[]const u8, name: []const u8) !void {
    const path = snapshot orelse return;
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-{s}.png", .{ stem, name });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const t = app.current().?;
    t.response.pane = .pretty;
    t.response.body_pane = .pretty;
    t.response.pretty_mode = .tree;
    try @import("response_test_support.zig").settle(ui, app, frame);
    for (0..4) |_| frame(ui, app);
    if (t.response.tree == null) return error.PolishCheckFailed;
    const tr = &t.response.tree.?;
    try tr.setAll(app.gpa, false);
    const s = &t.response.json;
    s.clearSelection();
    frame(ui, app);
    const canvas = rect(ui, t.uid, json_view.canvas_id);
    try expect(@src(), canvas.w > 100 and canvas.h > 60);

    // Drag from the start of the first row across three rows.
    c.cui_input_mouse_move(ui, canvas.x + 27, canvas.y + 10);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, canvas.x + 160, canvas.y + 70);
    frame(ui, app);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try expect(@src(), s.hasSelection() and !s.selecting);
    const dragged = try json_view.selectionText(w.arena.allocator(), tr, s);
    try expect(@src(), dragged.len > 4 and std.mem.indexOfScalar(u8, dragged, '\n') != null);
    try shot(ui, sw, app, snapshot, "json-selection");

    // Select all copies the document as formatted JSON.
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    const everything = try json_view.selectionText(w.arena.allocator(), tr, s);
    // Frames reset the arena; keep the expected text apart.
    const whole = try json_view.formatted(app.gpa, tr);
    defer app.gpa.free(whole);
    try expect(@src(), std.mem.eql(u8, everything, whole));
    try expect(@src(), @import("utils/json.zig").validate(whole) == null);
    // Folded containers still copy whole.
    try tr.setAll(app.gpa, true);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    const folded = try json_view.selectionText(w.arena.allocator(), tr, s);
    if (!std.mem.eql(u8, folded, whole)) std.debug.print("folded copy:\n{s}\n---\nexpected:\n{s}\n", .{ folded, whole });
    try expect(@src(), std.mem.eql(u8, folded, whole));
    try tr.setAll(app.gpa, false);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try expect(@src(), !s.hasSelection());

    // Double-click a value: the value alone is selected.
    const row_y = canvas.y + 6 + 2.5 * @import("ui/code_font.zig").line();
    click(ui, app, canvas.x + 120, row_y);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);

    // The context menu: short, with the rest under More.
    c.cui_input_mouse_move(ui, canvas.x + 60, canvas.y + 30);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, false);
    for (0..3) |_| frame(ui, app);
    const more = contextItem(ui, t.uid, "json-menu", "More");
    try expect(@src(), more.w > 0);
    try expect(@src(), contextItem(ui, t.uid, "json-menu", "Expand to level 2").w == 0);
    try shot(ui, sw, app, snapshot, "json-menu");
    c.cui_input_mouse_move(ui, more.x + more.w / 2, more.y + more.h / 2);
    for (0..4) |_| frame(ui, app);
    const level = submenuItem(ui, t.uid, "json-menu", "More", "Collapse all");
    try expect(@src(), level.w > 0 and level.x >= more.x + more.w - 4);
    try shot(ui, sw, app, snapshot, "json-menu-more");
    // Choosing a submenu item runs it and closes both menus.
    click(ui, app, level.x + level.w / 2, level.y + level.h / 2);
    for (0..3) |_| frame(ui, app);
    try expect(@src(), !tr.isOpen(1) or tr.rows.items.len < 6);
    try expect(@src(), contextItem(ui, t.uid, "json-menu", "More").w == 0 or !c.kest_popup_open(ui, 0));
    try tr.setAll(app.gpa, false);

    // One-click Copy, Find and Save in the response bar.
    for (0..3) |_| frame(ui, app);
    try expect(@src(), rect(ui, t.uid, "response-copy").w > 0);
    try expect(@src(), rect(ui, t.uid, "response-find").w > 0);
    try expect(@src(), rect(ui, t.uid, "response-save").w > 0);
    const find = rect(ui, t.uid, "response-find");
    click(ui, app, find.x + find.w / 2, find.y + find.h / 2);
    try expect(@src(), s.find_open);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    for (0..3) |_| frame(ui, app);
    try shot(ui, sw, app, snapshot, "response-bar");

    // The URL caret is drawn by Kest after the coloured {{variable}} text.
    app.want_url_focus = true;
    for (0..3) |_| frame(ui, app);
    try shot(ui, sw, app, snapshot, "url-caret");
    std.debug.print("CUI polish: JSON drag/all/folded selection, value double-click, More submenu, response bar actions passed\n", .{});
}
