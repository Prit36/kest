//! Right-click menus: text fields, the body editor and request tabs, driven
//! by real mouse input through the CUI frame.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const workspace = @import("ui/workspace.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Context menu regression at {s}:{d}\n", .{ src.file, src.line });
        return error.ContextMenuRegression;
    }
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("Context menu text at {s}:{d}: wanted {s}, got {s}\n", .{ src.file, src.line, want, got });
        return error.ContextMenuRegression;
    }
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
fn copied() []const u8 {
    return std.mem.sliceTo(&clipboard, 0);
}

/// A control's rectangle in a request tab's id scope.
fn rect(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
/// Where a menu was built: a popup's items are named inside the id scope
/// that was current when it opened.
const Scope = union(enum) { tab: *tab.Tab, name: [*:0]const u8 };
const Menu = struct { scope: Scope, id: c.cui_id };
/// A menu item's rectangle.
fn item(ui: *c.cui_ctx, menu: Menu, label: [*:0]const u8) c.cui_rect {
    switch (menu.scope) {
        .tab => |t| c.cui_push_id_int(ui, @intCast(t.uid)),
        .name => |name| c.cui_push_id(ui, name),
    }
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @bitCast(menu.id));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
/// The edit menu of the text field `key`.
fn fieldMenu(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) Menu {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return .{ .scope = .{ .tab = t }, .id = c.cui_make_id(ui, key) ^ 0xC7C0E017 };
}
/// The context menu `key` built by `kest_context_menu_begin` in a tab's scope.
fn viewMenu(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) Menu {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return .{ .scope = .{ .tab = t }, .id = c.cui_make_id(ui, key) ^ 0xC7C };
}

fn rightClick(ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime frame: anytype) void {
    c.cui_input_mouse_move(ui, r.x + @min(24, r.w / 2), r.y + r.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_RIGHT, false);
    frame(ui, app);
}
fn choose(src: std.builtin.SourceLocation, ui: *c.cui_ctx, app: *App, menu: Menu, label: [*:0]const u8, comptime frame: anytype, comptime click: anytype) !void {
    const r = item(ui, menu, label);
    if (r.w <= 0) std.debug.print("Missing menu item {s}\n", .{label});
    try check(src, r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
    // A text field runs a chosen command in its next frame.
    for (0..2) |_| frame(ui, app);
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype) !void {
    c.cui_set_platform(ui, &.{ .get_clipboard = getClipboard, .set_clipboard = setClipboard });
    defer c.cui_set_platform(ui, null);
    const t = commands.newTab(app) orelse return error.TabLimit;
    const url = "https://example.test/items?id=7";
    t.url.set(url);
    t.pane = .body;
    t.body_kind = .json;
    t.body.setText("{\"a\":1}");
    for (0..4) |_| frame(ui, app);

    // Text field: the URL's own menu edits it as its shortcuts do.
    const url_menu = fieldMenu(ui, t, "url");
    rightClick(ui, app, rect(ui, t, "url"), frame);
    try check(@src(), item(ui, url_menu, "Paste").w > 0);
    try check(@src(), item(ui, url_menu, "Copy").w > 0);
    try choose(@src(), ui, app, url_menu, "Select all", frame, click);
    rightClick(ui, app, rect(ui, t, "url"), frame);
    try choose(@src(), ui, app, url_menu, "Copy", frame, click);
    try equal(@src(), url, copied());
    rightClick(ui, app, rect(ui, t, "url"), frame);
    try choose(@src(), ui, app, url_menu, "Cut", frame, click);
    try equal(@src(), "", t.url.text());
    rightClick(ui, app, rect(ui, t, "url"), frame);
    try choose(@src(), ui, app, url_menu, "Paste", frame, click);
    try equal(@src(), url, t.url.text());
    rightClick(ui, app, rect(ui, t, "url"), frame);
    try choose(@src(), ui, app, url_menu, "Undo", frame, click);
    try equal(@src(), "", t.url.text());

    // Body editor: editing commands, then the body's own.
    const body_menu = viewMenu(ui, t, "body-editor-menu");
    rightClick(ui, app, rect(ui, t, "body-editor"), frame);
    try choose(@src(), ui, app, body_menu, "Select all", frame, click);
    try check(@src(), t.body.selection()[0] == 0 and t.body.selection()[1] == t.body.text().len);
    rightClick(ui, app, rect(ui, t, "body-editor"), frame);
    try choose(@src(), ui, app, body_menu, "Cut", frame, click);
    try equal(@src(), "", t.body.text());
    try equal(@src(), "{\"a\":1}", copied());
    rightClick(ui, app, rect(ui, t, "body-editor"), frame);
    try choose(@src(), ui, app, body_menu, "Paste", frame, click);
    try equal(@src(), "{\"a\":1}", t.body.text());
    rightClick(ui, app, rect(ui, t, "body-editor"), frame);
    try choose(@src(), ui, app, body_menu, "Format JSON", frame, click);
    // A click elsewhere in the editor the menu was opened on closes it.
    rightClick(ui, app, rect(ui, t, "body-editor"), frame);
    try check(@src(), c.kest_popup_open(ui, body_menu.id));
    const editor = rect(ui, t, "body-editor");
    click(ui, app, editor.x + 8, editor.y + 8);
    try check(@src(), !c.kest_popup_open(ui, body_menu.id));
    try check(@src(), std.mem.indexOfScalar(u8, t.body.text(), '\n') != null);

    // Request tabs: Close others closes saved tabs and keeps edited ones.
    for (0..2) |_| {
        const other = commands.newTab(app) orelse return error.TabLimit;
        other.dirty = false;
        other.has_draft = false;
    }
    const edited = commands.newTab(app) orelse return error.TabLimit;
    edited.dirty = true;
    commands.activate(app, for (app.tabs.items, 0..) |x, i| {
        if (x == t) break i;
    } else unreachable);
    for (0..3) |_| frame(ui, app);
    c.cui_push_id(ui, "request-documents");
    const tab_rect = c.cui_get_rect(ui, c.cui_make_id(ui, workspace.documentTitle(t)));
    const tab_menu: Menu = .{ .scope = .{ .name = "request-documents" }, .id = c.cui_make_id(ui, "tab-menu") ^ 0xC7C };
    c.cui_pop_id(ui);
    rightClick(ui, app, tab_rect, frame);
    try check(@src(), item(ui, tab_menu, "Reveal in collection").w > 0);
    const others = app.tabs.items.len;
    var unsaved: usize = 0;
    for (app.tabs.items) |x| {
        if (x != t and (x.dirty or (x.link == null and x.has_draft))) unsaved += 1;
    }
    try check(@src(), others > 3 and unsaved >= 1);
    try choose(@src(), ui, app, tab_menu, "Close others", frame, click);
    try check(@src(), app.tabs.items.len == 1 + unsaved);
    try check(@src(), app.current() == t);
    edited.dirty = false;
    commands.requestClose(app, edited);
    for (0..2) |_| frame(ui, app);
    std.debug.print("Context menus: text field edit commands, body editor commands and tab Close others passed\n", .{});
}
