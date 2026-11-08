//! Editable tables: sorting from the headings, a resizable split, picking
//! rows with their grips, bulk enable/disable/copy/delete with Undo,
//! dragging rows to reorder, and pasting tab-separated rows.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (ok) return;
    std.debug.print("Tables at {s}:{d}\n", .{ src.file, src.line });
    return error.TableRegression;
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print("Tables at {s}:{d}: wanted \"{s}\", got \"{s}\"\n", .{ src.file, src.line, want, got });
    return error.TableRegression;
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

fn rect(ui: *c.cui_ctx, t: *tab.Tab, row: ?u32, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, "headers");
    defer c.cui_pop_id(ui);
    if (row) |uid| c.cui_push_id_int(ui, @intCast(uid));
    defer if (row != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn focusCell(ui: *c.cui_ctx, t: *tab.Tab, row: u32, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, "headers");
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @intCast(row));
    defer c.cui_pop_id(ui);
    c.kest_focus(ui, key);
}
fn middle(r: c.cui_rect) struct { x: f32, y: f32 } {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}
fn click(ui: *c.cui_ctx, app: *App, r: c.cui_rect, mods: c_int, comptime frame: anytype) void {
    const m = middle(r);
    c.cui_input_mouse_move(ui, m.x, m.y);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, mods);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, 0);
    frame(ui, app);
}
fn keys(t: *const tab.Tab, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.headers.rows.items, 0..) |r, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, r.key.text());
    }
    return out.items;
}

fn model(app: *App) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t = tab.Table.init(app.gpa);
    defer t.deinit();
    const r0 = try t.add(.{ .key = "a", .value = "1" });
    const r1 = try t.add(.{ .key = "b", .value = "2" });
    const r2 = try t.add(.{ .key = "c", .value = "3" });
    _ = try t.add(.{ .key = "d", .value = "4" });
    // One row to the end, then two picked rows to the start, in their order.
    try check(@src(), t.moveRows(r0.uid, 4));
    try equal(@src(), "b", t.rows.items[0].key.text());
    try equal(@src(), "a", t.rows.items[3].key.text());
    t.selectOnly(r2.uid);
    t.toggleSelected(r0.uid);
    try check(@src(), t.moveRows(r0.uid, 0));
    try equal(@src(), "c", t.rows.items[0].key.text());
    try equal(@src(), "a", t.rows.items[1].key.text());
    // Dropping where they are already changes nothing.
    try check(@src(), !t.moveRows(r0.uid, 0));
    try equal(@src(), "c\t3\na\t1", try t.selectedTsv(a));
    // Shift picks a range by position.
    t.selectOnly(r2.uid);
    t.selectTo(r1.uid);
    try check(@src(), t.selected.items.len == 3);
    // Undo restores rows a bulk change replaced.
    t.remember();
    try check(@src(), t.removeSelected() == 3 and t.rows.items.len == 1);
    try t.restore();
    try check(@src(), t.rows.items.len == 4);
    t.sortBy(.key_down);
    try equal(@src(), "d", t.rows.items[0].key.text());
    t.sortBy(.key_up);
    try equal(@src(), "a", t.rows.items[0].key.text());
    // Pasted lines: name and value, a name alone, blank lines skipped.
    try check(@src(), try t.pasteTsv("x\t9\n\ny\r\n", 1) == 2);
    try equal(@src(), "x", t.rows.items[1].key.text());
    try equal(@src(), "9", t.rows.items[1].value.text());
    try check(@src(), t.rows.items[2].value.text().len == 0 and !t.rows.items[2].has_equals);
}

fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-tables-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime chord: anytype) !void {
    try model(app);
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    app.tabs = .empty;
    app.active = 0;
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    defer {
        c.cui_set_platform(ui, null);
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    c.cui_set_viewport(ui, 1000, 700, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.pane = .headers;
    t.pane_chosen = true;
    _ = try t.headers.add(.{ .key = "b-two", .value = "2" });
    _ = try t.headers.add(.{ .key = "A-one", .value = "3" });
    _ = try t.headers.add(.{ .key = "c-three", .value = "1" });
    for (0..4) |_| frame(ui, app);

    // A heading click sorts, ignoring case, with no toast; again, the other
    // way; a third time, back to the original order.
    click(ui, app, rect(ui, t, null, "kv-key-heading"), 0, frame);
    try equal(@src(), "A-one,b-two,c-three", try keys(t, a));
    try check(@src(), t.headers.sort == .key_up and t.headers.undo_toast == 0);
    click(ui, app, rect(ui, t, null, "kv-key-heading"), 0, frame);
    try equal(@src(), "c-three,b-two,A-one", try keys(t, a));
    click(ui, app, rect(ui, t, null, "kv-value-heading"), 0, frame);
    try equal(@src(), "c-three,b-two,A-one", try keys(t, a));
    click(ui, app, rect(ui, t, null, "kv-value-heading"), 0, frame);
    try equal(@src(), "A-one,b-two,c-three", try keys(t, a));
    click(ui, app, rect(ui, t, null, "kv-value-heading"), 0, frame);
    try equal(@src(), "b-two,A-one,c-three", try keys(t, a));
    try check(@src(), t.headers.sort == .none);
    // The rest of this test starts from names Z to A.
    t.headers.sortBy(.key_down);
    frame(ui, app);
    try equal(@src(), "c-three,b-two,A-one", try keys(t, a));

    // The split between the headings drags; a double-click resets it.
    const key0 = rect(ui, t, null, "kv-key-heading");
    const edge = key0.x + key0.w;
    c.cui_input_mouse_move(ui, edge, key0.y + key0.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, edge + 120, key0.y + key0.h / 2);
    frame(ui, app);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try check(@src(), t.headers.key_share > 0.5 and !t.headers.resizing);
    const key1 = rect(ui, t, null, "kv-key-heading");
    try check(@src(), key1.w > key0.w + 80);
    const cell = rect(ui, t, t.headers.rows.items[0].uid, "key");
    try check(@src(), @abs(cell.w - key1.w) < 16);
    try equal(@src(), "c-three,b-two,A-one", try keys(t, a));
    const edge1 = key1.x + key1.w;
    for (0..2) |_| {
        c.cui_input_mouse_move(ui, edge1, key1.y + key1.h / 2);
        frame(ui, app);
        c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
        frame(ui, app);
        c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
        frame(ui, app);
    }
    try check(@src(), t.headers.key_share == tab.Table.default_share);
    for (0..30) |_| frame(ui, app);

    // Grips pick rows: a click, Shift for a range, Ctrl to take one out.
    click(ui, app, rect(ui, t, t.headers.rows.items[0].uid, "grip"), 0, frame);
    try check(@src(), t.headers.selected.items.len == 1);
    try check(@src(), rect(ui, t, null, "kv-selection").h > 0);
    for (0..30) |_| frame(ui, app);
    click(ui, app, rect(ui, t, t.headers.rows.items[2].uid, "grip"), c.CUI_MOD_SHIFT, frame);
    try check(@src(), t.headers.selected.items.len == 3);
    for (0..30) |_| frame(ui, app);
    const middle_uid = t.headers.rows.items[1].uid;
    click(ui, app, rect(ui, t, middle_uid, "grip"), c.CUI_MOD_PRIMARY, frame);
    try check(@src(), t.headers.selected.items.len == 2 and !t.headers.isSelected(middle_uid));
    for (0..20) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "selected");
    // Ctrl+C copies them as tab-separated lines.
    chord(ui, app, c.CUI_KEY_C, c.CUI_MOD_PRIMARY);
    try equal(@src(), "c-three\t1\nA-one\t3", std.mem.span(@as([*:0]const u8, &clipboard)));
    // Disable from the bar, then Delete, then Undo.
    click(ui, app, rect(ui, t, null, "selection-disable"), 0, frame);
    try check(@src(), !t.headers.rows.items[0].enabled and t.headers.rows.items[1].enabled and !t.headers.rows.items[2].enabled);
    chord(ui, app, c.CUI_KEY_DELETE, 0);
    try equal(@src(), "b-two", try keys(t, a));
    try check(@src(), t.headers.undo_toast != 0 and t.headers.selected.items.len == 0);
    try t.headers.restore();
    for (0..3) |_| frame(ui, app);
    try equal(@src(), "c-three,b-two,A-one", try keys(t, a));
    try check(@src(), !t.headers.rows.items[0].enabled);
    // Escape lets go of the pick.
    for (0..30) |_| frame(ui, app);
    click(ui, app, rect(ui, t, t.headers.rows.items[1].uid, "grip"), 0, frame);
    try check(@src(), t.headers.selected.items.len == 1);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), t.headers.selected.items.len == 0);

    // Dragging the first row's grip below the last row moves it there.
    const first_uid = t.headers.rows.items[0].uid;
    const from = middle(rect(ui, t, first_uid, "grip"));
    const last_row = rect(ui, t, t.headers.rows.items[2].uid, "kv-row");
    c.cui_input_mouse_move(ui, from.x, from.y);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, from.x, last_row.y + last_row.h - 3);
    frame(ui, app);
    frame(ui, app);
    try capture(ui, sw, app, snapshot, "dragging");
    try check(@src(), t.headers.drag != null and t.headers.drag.?.moving and t.headers.drag.?.target == 3);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try equal(@src(), "b-two,A-one,c-three", try keys(t, a));
    try check(@src(), t.headers.drag == null);

    // Pasting tab-separated lines in a cell adds rows after it.
    for (0..30) |_| frame(ui, app);
    t.headers.clearSelection();
    focusCell(ui, t, t.headers.rows.items[0].uid, "value");
    frame(ui, app);
    w.copy(ui, "X-One\tfirst\nX-Two\tsecond\n");
    chord(ui, app, c.CUI_KEY_V, c.CUI_MOD_PRIMARY);
    try equal(@src(), "b-two,X-One,X-Two,A-one,c-three", try keys(t, a));
    try equal(@src(), "2", t.headers.rows.items[0].value.text());
    try equal(@src(), "second", t.headers.rows.items[2].value.text());
    // A single line pastes into the cell as text.
    focusCell(ui, t, t.headers.rows.items[0].uid, "value");
    frame(ui, app);
    w.copy(ui, "plain");
    chord(ui, app, c.CUI_KEY_V, c.CUI_MOD_PRIMARY);
    try check(@src(), t.headers.rows.items.len == 5 and std.mem.indexOf(u8, t.headers.rows.items[0].value.text(), "plain") != null);
    std.debug.print("CUI tables: heading sort/Undo, resizable split, grip picks, bulk disable/copy/delete/Undo, drag reorder and tab-separated paste passed\n", .{});
}
