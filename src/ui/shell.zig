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
    if (c.cui_viewport_size(ui).x < w.design.geometry.sidebar_sheet) narrow_open = !narrow_open else {
        app.prefs.sidebar_open = !app.prefs.sidebar_open;
        persist.prefsChanged(app);
    }
    // Focus inside a sidebar that just closed moves to the toggle.
    focus_check = .sidebar_closed;
}

/// Keyboard focus across overlays and hidden panes. CUI leaves focus on a
/// closed palette or dialog, or on a control that is no longer drawn; Tab
/// would then restart at the window's first control.
var plain_focus: c.cui_id = 0; // last frame-start focus with no overlay open
var focus_before_overlay: c.cui_id = 0;
var overlay_focus: c.cui_id = 0;
var overlay_was_open = false;
var sidebar_toggle: c.cui_id = 0;
var focus_check: enum { none, overlay_closed, sidebar_closed } = .none;

fn keepFocus(ui: *c.cui_ctx, app: *App) void {
    const focus = c.kest_get_focus(ui);
    // A check scheduled last frame: the focused control is no longer drawn.
    if (focus_check != .none and focus != 0 and !c.kest_was_focusable(ui, focus)) {
        if (focus_check == .sidebar_closed and sidebar_toggle != 0) c.kest_set_focus(ui, sidebar_toggle) else if (app.current()) |t| t.url.focus();
    }
    focus_check = .none;
    const open = app.palette_open or app.modal_open;
    if (open) {
        if (!overlay_was_open) focus_before_overlay = plain_focus;
        overlay_focus = focus;
    } else if (overlay_was_open) {
        // Closed with focus still on it (Escape, Cancel, most choices):
        // return to where the keyboard was. Actions that moved focus keep it.
        if (focus_before_overlay != 0 and (focus == overlay_focus or focus == 0)) {
            c.kest_set_focus(ui, focus_before_overlay);
            focus_check = .overlay_closed;
        }
    } else plain_focus = focus;
    overlay_was_open = open;
}

/// Test hook: the toggle button's id, which takes focus when the sidebar
/// it controls closes around the keyboard.
pub fn sidebarToggleId() c.cui_id {
    return sidebar_toggle;
}

pub fn view(ui: *c.cui_ctx, app: *App) void {
    // Imports and bulk edits may use megabytes of temporary text in one frame.
    // Keep a small reusable arena without retaining that high-water mark forever.
    _ = w.arena.reset(.{ .retain_with_limit = 256 * 1024 });
    commands.drainDone(app);
    if (app.store.takeFailure()) |failure| {
        defer app.gpa.free(failure);
        app.toast(.danger, "Saving failed", failure);
    }
    if (app.store.takeFailedPath()) |path| {
        defer app.gpa.free(path);
        persist.writeFailed(app, path);
    }
    commands.ensureTab(app);
    followSystemAppearance(app);
    const font = @import("code_font.zig");
    const steps = font.takeWheel();
    if (steps != 0) commands.zoomCode(app, steps);
    font.size = @floatFromInt(app.prefs.editor_font_size);
    keepFocus(ui, app);
    // Requested last frame; dropped if no tree is drawn to take it.
    const tree_focus_requested = app.focus_tree;
    defer if (tree_focus_requested) {
        app.focus_tree = false;
    };
    @import("design.zig").apply(ui, app.prefs.dark);
    const renaming = @import("rename.zig").process(ui, app);
    if (!renaming) shortcuts(ui, app);
    droppedFiles(ui, app);
    const size = c.cui_viewport_size(ui);
    w.column(ui, .{ .width = w.fill, .height = w.fill, .bg = w.color(c.CUI_TOKEN_BACKGROUND) });
    topbar(ui, app, size.x);
    w.column(ui, .{ .id = "workspace-region", .width = w.fill, .height = w.fill, .gap = 0 });
    if (app.prefs.sidebar_open and size.x >= w.design.geometry.sidebar_sheet) {
        // Width is a user preference, not a fraction of the current window.
        const geometry = w.design.geometry;
        const maximum = @min(geometry.sidebar_max, @min(size.x * 0.4, size.x - geometry.workspace_min));
        sidebar_ratio = std.math.clamp(app.prefs.sidebar_width, geometry.sidebar_min, maximum) / size.x;
        const before = sidebar_ratio;
        c.cui_split_begin(ui, "sidebar-split", &sidebar_ratio, &.{ .min_first = geometry.sidebar_min, .min_second = @max(geometry.workspace_min, size.x - maximum), .width = w.fill, .height = w.fill });
        sidebar.view(ui, app);
        c.kest_split_next(ui, "sidebar-split", false);
        workspace_ui.view(ui, app);
        c.cui_split_end(ui);
        if (before != sidebar_ratio) {
            app.prefs.sidebar_width = sidebar_ratio * size.x;
            persist.prefsChanged(app);
        }
    } else workspace_ui.view(ui, app);
    w.end(ui);
    if (app.prefs.log_open) log(ui, app);
    w.end(ui);
    if (narrow_open and size.x < w.design.geometry.sidebar_sheet) {
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
    deletionToast(ui, app);
    c.kest_quiet_caret(ui);
}

fn topbar(ui: *c.cui_ctx, app: *App, width: f32) void {
    w.row(ui, .{ .id = "global-toolbar", .height = w.px(36), .pad_x = 10, .gap = w.design.space.normal, .width = w.fill });
    defer w.end(ui);
    const toggled = w.icon(ui, c.CUI_ICON_PANEL_LEFT, "Toggle workspace (Ctrl B)");
    sidebar_toggle = c.kest_last_id(ui);
    if (toggled) toggleSidebar(ui, app);
    var running: usize = 0;
    for (app.tabs.items) |t| if (t.running()) {
        running += 1;
    };
    if (running > 0) w.text(ui, w.fmt("{d} running", .{running}), .{ .size = w.design.text.secondary, .color = w.color(c.CUI_TOKEN_INFO), .nowrap = true });
    c.cui_spacer(ui);
    if (w.iconMenu(ui, w.fmt("{s}###active-environment", .{if (app.active_env) |e| e.name else "No environment"}), c.CUI_ICON_DATABASE, if (width < 800) 170 else 200, w.color(if (app.active_env != null) c.CUI_TOKEN_FOREGROUND else c.CUI_TOKEN_TEXT_MUTED))) {
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
            if (width < w.design.geometry.sidebar_sheet) narrow_open = true else app.prefs.sidebar_open = true;
        }
        if (w.menuItem(ui, "New environment...")) dialogs.askName(app, .new_env, "");
        c.cui_menu_end(ui);
    }
    if (w.action(ui, "command-search", if (width >= 1000) "Commands" else "", c.CUI_ICON_SEARCH, false, if (width >= 1000) 122 else 28, 28, 3)) app.palette_open = true;
    c.kest_tooltip(ui, "Commands (Ctrl Shift P)");
    if (w.action(ui, "activity-toggle", if (width >= 1000) "Activity" else "", c.CUI_ICON_SQUARE_TERMINAL, app.prefs.log_open, if (width >= 1000) 96 else 28, 28, 3)) {
        app.prefs.log_open = !app.prefs.log_open;
        persist.prefsChanged(app);
    }
    c.kest_tooltip(ui, "Activity console (Ctrl J)");
    if (w.icon(ui, if (app.prefs.dark) c.CUI_ICON_SUN else c.CUI_ICON_MOON, "Switch appearance")) {
        app.prefs.dark = !app.prefs.dark;
        app.prefs.follow_system = false;
        persist.prefsChanged(app);
    }
    if (c.kest_dropdown_begin(ui, "Workspace actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (w.menuItem(ui, "Show data folder") and !@import("platform.zig").headless) _ = c.cui_app_open_url(w.z(app.store.path));
        if (w.menuItem(ui, "Settings")) settings(app);
        c.cui_menu_end(ui);
    }
}

fn log(ui: *c.cui_ctx, app: *App) void {
    @import("activity.zig").view(ui, app);
}

fn settings(app: *App) void {
    app.retention_text.set(w.fmt("{d}", .{app.prefs.retention}));
    app.modal = .settings;
    app.modal_open = true;
}
fn shortcuts(ui: *c.cui_ctx, app: *App) void {
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_P)) app.palette_open = true;
    if (app.modal_open or app.palette_open) return;
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_T)) commands.reopenClosed(app);
    if (c.cui_key_pressed(ui, c.CUI_KEY_F2)) {
        if (app.mode == .collections and (c.kest_get_focus(ui) == c.cui_make_id(ui, "collection-rows") or c.kest_focus_within(ui, "collection-rows"))) {
            if (app.selected) |n| @import("rename.zig").begin(app, .{ .rename_node = n }, n.name);
        } else if (app.current()) |t| @import("rename.zig").begin(app, .{ .rename_tab = t }, t.name);
    }
    const request_submit = c.kest_request_shortcut(ui);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_N)) _ = commands.newTab(app);
    // Ctrl+= (or Ctrl++), Ctrl+- and Ctrl+0 zoom the code font.
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_EQUAL) or c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_EQUAL)) commands.zoomCode(app, 1);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_MINUS)) commands.zoomCode(app, -1);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_0)) commands.zoomCode(app, 0);
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
        if (request_submit) {
            if (t.running()) commands.cancel(t) else commands.send(app, t);
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_S)) commands.save(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_W)) commands.requestClose(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_D)) commands.duplicateTab(app, t);
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_F)) {
            c.cui_push_id_int(ui, @intCast(t.uid));
            const body_focused = c.kest_editor_focus(ui, c.cui_make_id(ui, "body-editor")) != 0;
            c.cui_pop_id(ui);
            if (body_focused or (t.pane == .body and t.shown == null)) {
                @import("editor.zig").openSearch(&t.body, false);
            } else @import("response_search.zig").open(t);
        }
        // Replace is for the body: Ctrl+H opens it there.
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_H)) {
            if (t.pane != .body) t.pane = .body;
            @import("editor.zig").openSearch(&t.body, true);
        }
    }
}
const PaletteAction = enum { send, new_request, save, save_as, duplicate, close_tab, next_tab, previous_tab, find, copy_curl, focus_request, focus_response, both_panes, import_file, import_curl, new_collection, new_environment, manage_environments, toggle_sidebar, toggle_activity, appearance, settings, encode_url, decode_url };
const PaletteEntry = struct { title: [*:0]const u8, group: [*:0]const u8, shortcut: ?[*:0]const u8 = null, action: PaletteAction };
const palette_entries = [_]PaletteEntry{
    .{ .title = "Send or cancel request", .group = "Request", .shortcut = "Ctrl Enter", .action = .send },
    .{ .title = "Save request", .group = "Request", .shortcut = "Ctrl S", .action = .save },
    .{ .title = "Save request as...", .group = "Request", .action = .save_as },
    .{ .title = "Duplicate request", .group = "Request", .shortcut = "Ctrl D", .action = .duplicate },
    .{ .title = "Copy as cURL", .group = "Request", .action = .copy_curl },
    .{ .title = "Encode URL", .group = "Request", .action = .encode_url },
    .{ .title = "Decode URL", .group = "Request", .action = .decode_url },
    .{ .title = "Find in body or response", .group = "Request", .shortcut = "Ctrl F", .action = .find },
    .{ .title = "New request", .group = "Tabs", .shortcut = "Ctrl N", .action = .new_request },
    .{ .title = "Close tab", .group = "Tabs", .shortcut = "Ctrl W", .action = .close_tab },
    .{ .title = "Next tab", .group = "Tabs", .shortcut = "Ctrl Tab", .action = .next_tab },
    .{ .title = "Previous tab", .group = "Tabs", .shortcut = "Ctrl Shift Tab", .action = .previous_tab },
    .{ .title = "Show request and response", .group = "Layout", .action = .both_panes },
    .{ .title = "Focus request editor", .group = "Layout", .action = .focus_request },
    .{ .title = "Focus response", .group = "Layout", .action = .focus_response },
    .{ .title = "Toggle sidebar", .group = "Layout", .shortcut = "Ctrl B", .action = .toggle_sidebar },
    .{ .title = "Toggle activity console", .group = "Layout", .shortcut = "Ctrl J", .action = .toggle_activity },
    .{ .title = "Import file...", .group = "Collections", .action = .import_file },
    .{ .title = "Import cURL...", .group = "Collections", .action = .import_curl },
    .{ .title = "New collection...", .group = "Collections", .action = .new_collection },
    .{ .title = "New environment...", .group = "Environments", .action = .new_environment },
    .{ .title = "Manage environments", .group = "Environments", .action = .manage_environments },
    .{ .title = "Switch appearance", .group = "Application", .action = .appearance },
    .{ .title = "Workspace settings...", .group = "Application", .action = .settings },
};

fn palette(ui: *c.cui_ctx, app: *App) void {
    if (!app.palette_open) return;
    var items: std.ArrayList(c.cui_command) = .empty;
    var nodes: std.ArrayList(*col.Node) = .empty;
    const a = w.arena.allocator();
    for (palette_entries) |entry| items.append(a, .{ .title = entry.title, .group = entry.group, .shortcut = entry.shortcut }) catch {};
    // Environments are switched by name, beside the toolbar picker.
    const env_start = items.items.len;
    items.append(a, .{ .title = "Use no environment", .group = "Environments" }) catch {};
    for (app.envs.items) |e| items.append(a, .{ .title = w.fmt("Use environment: {s}", .{e.name}), .group = "Environments" }) catch {};
    const env_end = items.items.len;
    for (app.collections.items) |root| collect(a, root, &items, &nodes);
    const chosen = c.cui_command_palette(ui, &app.palette_open, items.items.ptr, @intCast(items.items.len));
    if (chosen < 0) return;
    const i: usize = @intCast(chosen);
    if (i >= env_start and i < env_end) {
        commands.setActiveEnv(app, if (i == env_start) null else app.envs.items[i - env_start - 1]);
        return;
    }
    if (i >= env_end) {
        if (i - env_end < nodes.items.len) commands.openRequest(app, nodes.items[i - env_end]);
        return;
    }
    runPalette(ui, app, palette_entries[i].action);
}

fn runPalette(ui: *c.cui_ctx, app: *App, action: PaletteAction) void {
    const t = app.current();
    switch (action) {
        .send => if (t) |x| {
            if (x.running()) commands.cancel(x) else commands.send(app, x);
        },
        .new_request => _ = commands.newTab(app),
        .save => if (t) |x| commands.save(app, x),
        .save_as => if (t) |x| commands.beginSaveAs(app, x),
        .duplicate => if (t) |x| commands.duplicateTab(app, x),
        .close_tab => if (t) |x| commands.requestClose(app, x),
        .next_tab => commands.cycleTab(app, 1),
        .previous_tab => commands.cycleTab(app, -1),
        .find => if (t) |x| {
            if (x.pane == .body and x.shown == null) {
                x.body.search_open = true;
                x.body.query.focus();
            } else @import("response_search.zig").open(x);
        },
        .copy_curl => if (t) |x| {
            if (x.toRequest(w.arena.allocator()) catch null) |r| w.copy(ui, @import("../import_export/curl.zig").generate(w.arena.allocator(), r) catch "");
        },
        .both_panes => if (t) |x| {
            x.details_collapsed = false;
            x.response_collapsed = false;
        },
        .focus_request => if (t) |x| {
            x.details_collapsed = false;
            x.response_collapsed = true;
        },
        .focus_response => if (t) |x| {
            x.details_collapsed = true;
            x.response_collapsed = false;
        },
        .import_file => imports.chooseFile(app),
        .import_curl => {
            app.modal = .import_curl;
            app.modal_open = true;
        },
        .new_collection => dialogs.askName(app, .new_collection, ""),
        .new_environment => dialogs.askName(app, .new_env, ""),
        .manage_environments => {
            app.mode = .environments;
            if (c.cui_viewport_size(ui).x < w.design.geometry.sidebar_sheet) narrow_open = true else {
                app.prefs.sidebar_open = true;
                persist.prefsChanged(app);
            }
        },
        .toggle_sidebar => toggleSidebar(ui, app),
        .toggle_activity => {
            app.prefs.log_open = !app.prefs.log_open;
            persist.prefsChanged(app);
        },
        .appearance => {
            app.prefs.dark = !app.prefs.dark;
            app.prefs.follow_system = false;
            persist.prefsChanged(app);
        },
        .settings => settings(app),
        .encode_url => if (t) |x| commands.encodeUrl(app, x),
        .decode_url => if (t) |x| commands.decodeUrl(app, x),
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

/// Until an appearance is chosen, match the Windows app theme (read again
/// when Windows reports a settings change). Headless runs keep theirs.
pub fn followSystemAppearance(app: *App) void {
    if (!app.prefs.follow_system or @import("platform.zig").headless) return;
    switch (c.kest_system_dark()) {
        0 => app.prefs.dark = false,
        1 => app.prefs.dark = true,
        else => {},
    }
}

var undo_handle: c_int = 0;
var undo_deadline: i64 = 0;
fn deletionToast(ui: *c.cui_ctx, app: *App) void {
    const tree = @import("../app/tree_ops.zig");
    if (app.deleted.items.len == 0 and app.deleted_envs.items.len == 0) return;
    if (undo_deadline != app.undo_until) {
        if (undo_handle != 0) c.cui_toast_dismiss(ui, undo_handle);
        undo_handle = c.cui_toast_ex(ui, "Deleted from sidebar", &.{ .action = "Undo", .duration = 8, .show_timer = true });
        undo_deadline = app.undo_until;
    }
    if (c.cui_toast_action_clicked(ui, undo_handle)) {
        tree.undoDelete(app);
        c.cui_toast_dismiss(ui, undo_handle);
    } else if (app.nowMs() >= app.undo_until) tree.finishDelete(app);
}
fn droppedFiles(ui: *c.cui_ctx, app: *App) void {
    const count = c.cui_dropped_file_count(ui);
    if (count <= 0) return;
    if (app.modal_open or app.palette_open) {
        app.toast(.info, "File wasn't opened", "Finish the current dialog, then drop the file again.");
        return;
    }
    if (count > 1) {
        app.toast(.warning, "Drop one file at a time", "Import a collection or attach a single body file.");
        return;
    }
    const path = std.mem.span(c.cui_dropped_file(ui, 0));
    if (app.current()) |t| {
        c.cui_push_id_int(ui, @intCast(t.uid));
        const area = c.cui_get_rect(ui, c.cui_make_id(ui, "request-body-drop"));
        c.cui_pop_id(ui);
        const mouse = c.kest_file_drop_position(ui);
        if (area.h > 0 and mouse.x >= area.x and mouse.x < area.x + area.w and mouse.y >= area.y and mouse.y < area.y + area.h) {
            if (!t.file_path.reserve(path.len)) return;
            t.file_path.set(path);
            t.body_kind = .file;
            persist.touchTab(app, t);
            app.toast(.success, "Body file attached", std.fs.path.basename(path));
            return;
        }
    }
    imports.importFile(app, path);
}
