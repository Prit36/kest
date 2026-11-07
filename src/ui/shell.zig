const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const imports = @import("../app/import_ops.zig");
const dialogs = @import("dialogs.zig");
const sidebar = @import("sidebar.zig");
const workspace_ui = @import("workspace.zig");
const col = @import("../core/collection.zig");
pub var sidebar_ratio: f32 = 0.215;
pub var narrow_open = false;

fn toggleSidebar(ui: *c.cui_ctx, app: *App) void {
    if (c.cui_viewport_size(ui).x < 840) narrow_open = !narrow_open else {
        app.prefs.sidebar_open = !app.prefs.sidebar_open;
        persist.prefsChanged(app);
    }
}

pub fn view(ui: *c.cui_ctx, app: *App) void {
    _ = w.arena.reset(.retain_capacity);
    commands.drainDone(app);
    if (app.store.takeFailure()) |failure| {
        defer app.gpa.free(failure);
        app.toast(.danger, "Saving failed", failure);
    }
    commands.ensureTab(app);
    @import("design.zig").apply(ui, app.prefs.dark);
    shortcuts(ui, app);
    const size = c.cui_viewport_size(ui);
    w.column(ui, .{ .width = w.fill, .height = w.fill, .bg = w.color(c.CUI_TOKEN_BACKGROUND) });
    topbar(ui, app, size.x);
    w.column(ui, .{ .width = w.fill, .height = w.fill, .gap = 0 });
    if (app.prefs.sidebar_open and size.x >= 840) {
        const before = sidebar_ratio;
        c.cui_split_begin(ui, "sidebar-split", &sidebar_ratio, &.{ .min_first = 210, .min_second = 520, .width = w.fill, .height = w.fill });
        sidebar.view(ui, app);
        c.cui_split_next(ui);
        workspace_ui.view(ui, app);
        c.cui_split_end(ui);
        if (before != sidebar_ratio) {
            app.prefs.sidebar_width = sidebar_ratio * size.x;
            persist.prefsChanged(app);
        }
    } else workspace_ui.view(ui, app);
    w.end(ui);
    if (app.prefs.log_open) log(ui, app);
    status(ui, app, size.x);
    w.end(ui);
    if (narrow_open and size.x < 840) {
        var opened = true;
        if (c.cui_sheet_begin(ui, "Workspace", &opened, &.{ .side = c.CUI_SIDE_LEFT, .size = @min(300, size.x - 80) })) {
            sidebar.view(ui, app);
            c.cui_sheet_end(ui);
        }
        if (!opened) narrow_open = false;
    }
    dialogs.view(ui, app);
    palette(ui, app);
    app.toaster.view(ui);
    c.retort_quiet_caret(ui);
}

fn topbar(ui: *c.cui_ctx, app: *App, width: f32) void {
    w.row(ui, .{ .height = w.px(36), .pad_x = 10, .gap = 8, .width = w.fill });
    defer w.end(ui);
    if (w.icon(ui, c.CUI_ICON_PANEL_LEFT, "Toggle workspace (Ctrl B)")) {
        toggleSidebar(ui, app);
    }
    @import("brand.zig").view(ui);
    if (width >= 900) {
        w.muted(ui, "/");
        w.text(ui, "Workspace", .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
    }
    c.cui_spacer(ui);
    if (w.menu(ui, w.fmt("{s}###active-environment", .{if (app.active_env) |e| e.name else "No environment"}), if (width < 800) 160 else 185, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        c.cui_menu_label(ui, "ACTIVE ENVIRONMENT");
        if (c.cui_menu_item_ex(ui, "No environment", &.{ .checked = app.active_env == null })) commands.setActiveEnv(app, null);
        if (app.envs.items.len > 0) {
            c.cui_scroll_begin(ui, &.{ .id = "environment-options", .height = w.px(@min(224, @as(f32, @floatFromInt(app.envs.items.len)) * 32)), .width = w.fill });
            for (app.envs.items) |e| {
                if (c.cui_menu_item_ex(ui, w.fmt("{s}###env-{s}", .{ e.name, e.id }), &.{ .checked = app.active_env == e })) commands.setActiveEnv(app, e);
            }
            c.cui_scroll_end(ui);
        }
        c.cui_menu_separator(ui);
        if (w.menuItem(ui, "Manage environments...")) {
            app.mode = .environments;
            if (width < 840) narrow_open = true else app.prefs.sidebar_open = true;
        }
        if (w.menuItem(ui, "New environment...")) dialogs.askName(app, .new_env, "");
        c.cui_menu_end(ui);
    }
    if (width >= 1000 and w.action(ui, "command-search", "Commands", c.CUI_ICON_SEARCH, false, 122, 28, 3)) app.palette_open = true;
    if (w.icon(ui, if (app.prefs.dark) c.CUI_ICON_SUN else c.CUI_ICON_MOON, "Switch appearance")) {
        app.prefs.dark = !app.prefs.dark;
        persist.prefsChanged(app);
    }
    if (c.retort_dropdown_begin(ui, "Workspace actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (w.menuItem(ui, "New collection")) dialogs.askName(app, .new_collection, "");
        if (w.menuItem(ui, "New environment")) dialogs.askName(app, .new_env, "");
        if (w.menuItem(ui, "Import file")) imports.chooseFile(app);
        if (w.menuItem(ui, "Show data folder") and !@import("platform.zig").headless) _ = c.cui_app_open_url(w.z(app.store.path));
        if (w.menuItem(ui, "Settings")) settings(app);
        c.cui_menu_end(ui);
    }
}

fn status(ui: *c.cui_ctx, app: *App, width: f32) void {
    c.cui_status_bar_begin(ui, "status", &.{});
    if (app.current()) |t| {
        c.cui_status_bar_text_ex(ui, if (t.running()) "Sending request..." else "Ready", &.{});
        c.cui_status_bar_spacer(ui);
        if (width >= 800) c.cui_status_bar_text_ex(ui, "Ctrl Shift P  Commands", &.{});
    }
    if (c.cui_status_bar_item_ex(ui, "Log", &.{ .icon = c.CUI_ICON_SQUARE_TERMINAL })) {
        app.prefs.log_open = !app.prefs.log_open;
        persist.prefsChanged(app);
    }
    c.cui_status_bar_text_ex(ui, "Ctrl Enter  Send", &.{});
    c.cui_status_bar_end(ui);
}
fn log(ui: *c.cui_ctx, app: *App) void {
    w.column(ui, .{ .height = w.px(105), .pad_x = 12, .gap = 4 });
    defer w.end(ui);
    w.muted(ui, "ACTIVITY");
    c.cui_scroll_begin(ui, &.{ .id = "log", .height = w.fill, .gap = 2 });
    var i = app.log.count();
    while (i > 0) {
        i -= 1;
        const entry = app.log.at(i);
        w.text(ui, entry.text, .{ .font = c.CUI_FONT_MONO, .size = 11, .nowrap = true, .color = w.color(if (entry.level == .err) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_TEXT_SECONDARY) });
    }
    c.cui_scroll_end(ui);
}
fn settings(app: *App) void {
    app.retention_text.set(w.fmt("{d}", .{app.prefs.retention}));
    app.modal = .settings;
    app.modal_open = true;
}
fn shortcuts(ui: *c.cui_ctx, app: *App) void {
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_P)) app.palette_open = true;
    if (app.modal_open or app.palette_open) return;
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_N)) _ = commands.newTab(app);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_B)) {
        toggleSidebar(ui, app);
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_J)) {
        app.prefs.log_open = !app.prefs.log_open;
        persist.prefsChanged(app);
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_TAB)) commands.cycleTab(app, 1);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_TAB)) commands.cycleTab(app, -1);
    if (app.current()) |t| {
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_ENTER)) {
            if (t.running()) commands.cancel(t) else commands.send(app, t);
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_S)) commands.save(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_W)) commands.requestClose(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_D)) commands.duplicateTab(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_F)) {
            const code = if (t.pane == .body and t.shown == null) &t.body else &t.response.code_raw;
            code.search_open = true;
            code.query.focus();
            if (t.shown != null) t.response.pane = .raw;
        }
    }
}
fn palette(ui: *c.cui_ctx, app: *App) void {
    if (!app.palette_open) return;
    const names = [_][*:0]const u8{ "Send / cancel request", "New request", "Save request", "Duplicate request", "Import file", "Import cURL", "New collection", "New environment", "Toggle sidebar", "Toggle log", "Switch appearance", "Settings", "Encode URL", "Decode URL" };
    var items: std.ArrayList(c.cui_command) = .empty;
    var nodes: std.ArrayList(*col.Node) = .empty;
    const a = w.arena.allocator();
    for (names) |name| items.append(a, .{ .title = name, .group = "Actions" }) catch {};
    for (app.collections.items) |root| collect(a, root, &items, &nodes);
    const chosen = c.cui_command_palette(ui, &app.palette_open, items.items.ptr, @intCast(items.items.len));
    if (chosen < 0) return;
    const i: usize = @intCast(chosen);
    const t = app.current();
    switch (i) {
        0 => if (t) |x| {
            if (x.running()) commands.cancel(x) else commands.send(app, x);
        },
        1 => _ = commands.newTab(app),
        2 => if (t) |x| commands.save(app, x),
        3 => if (t) |x| commands.duplicateTab(app, x),
        4 => imports.chooseFile(app),
        5 => {
            app.modal = .import_curl;
            app.modal_open = true;
        },
        6 => dialogs.askName(app, .new_collection, ""),
        7 => dialogs.askName(app, .new_env, ""),
        8 => {
            toggleSidebar(ui, app);
        },
        9 => {
            app.prefs.log_open = !app.prefs.log_open;
            persist.prefsChanged(app);
        },
        10 => {
            app.prefs.dark = !app.prefs.dark;
            persist.prefsChanged(app);
        },
        11 => settings(app),
        12 => if (t) |x| commands.encodeUrl(app, x),
        13 => if (t) |x| commands.decodeUrl(app, x),
        else => if (i - names.len < nodes.items.len) commands.openRequest(app, nodes.items[i - names.len]),
    }
}
fn collect(a: std.mem.Allocator, n: *col.Node, items: *std.ArrayList(c.cui_command), nodes: *std.ArrayList(*col.Node)) void {
    if (nodes.items.len >= 10000) return;
    if (n.kind == .request) {
        items.append(a, .{ .title = w.fmt("{s} {s}", .{ n.method, n.name }), .group = "Saved requests" }) catch return;
        nodes.append(a, n) catch return;
    }
    for (n.children.items) |child| collect(a, child, items, nodes);
}
