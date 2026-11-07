const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const editor = @import("editor.zig");
const platform = @import("platform.zig");

pub const bar = @import("composer.zig").view;

pub fn minimumHeight(t: *const tab.Tab) f32 {
    return switch (t.pane) {
        .params => if (t.params.rows.items.len > 0 or t.params.bulk != null) 148 else 112,
        .headers => if (t.headers.rows.items.len > 0 or t.headers.bulk != null) 148 else 112,
        .body => if (t.body_kind == .multipart or t.body_kind == .form_urlencoded) 148 else 140,
        .settings => 140,
    };
}

pub fn view(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    w.column(ui, .{ .id = "request-panel", .height = w.fill, .width = w.fill, .clip = true });
    defer w.end(ui);
    w.row(ui, .{ .id = "request-navigation", .pad_left = 4, .pad_right = 6, .height = w.px(36), .width = w.fill });
    const labels = [_][]const u8{ w.fmt("Params{s}", .{if (t.params.rows.items.len > 0) w.fmt(" {d}", .{t.params.rows.items.len}) else ""}), "Body", w.fmt("Headers{s}", .{if (t.headers.rows.items.len > 0) w.fmt(" {d}", .{t.headers.rows.items.len}) else ""}) };
    const panes = [_]tab.RequestPane{ .params, .body, .headers };
    for (labels, panes) |label, pane| {
        if (w.action(ui, w.fmt("pane-{s}", .{@tagName(pane)}), label, null, t.pane == pane, 0, 36, 2)) {
            t.pane = pane;
            t.details_collapsed = false;
        }
    }
    c.cui_spacer(ui);
    if (w.action(ui, "request-options", "", c.CUI_ICON_SETTINGS, t.pane == .settings, 28, 28, 3)) {
        t.pane = .settings;
        t.details_collapsed = false;
    }
    c.cui_tooltip(ui, "Request settings");
    if (w.action(ui, "toggle-details", "", if (t.details_collapsed) c.CUI_ICON_CHEVRON_DOWN else c.CUI_ICON_CHEVRON_UP, false, 26, 28, 3)) t.details_collapsed = !t.details_collapsed;
    c.cui_tooltip(ui, if (t.details_collapsed) "Show request editor" else "Focus response");
    w.end(ui);
    c.cui_separator(ui);
    if (t.details_collapsed) return;
    switch (t.pane) {
        .params => if (@import("key_value.zig").view(ui, &t.params, false, "Query parameters")) {
            t.syncUrlFromParams();
            persist.touchTab(app, t);
        },
        .headers => if (@import("key_value.zig").view(ui, &t.headers, false, "Request headers")) persist.touchTab(app, t),
        .body => body(ui, app, t),
        .settings => settings(ui, app, t),
    }
}

pub fn table(ui: *c.cui_ctx, values: *tab.Table, files: bool) bool {
    return @import("key_value.zig").view(ui, values, files, if (files) "Form fields" else "Variables");
}

fn body(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    w.row(ui, .{ .id = "body-toolbar", .gap = 4, .pad_x = 12, .height = w.px(36), .width = w.fill });
    const kinds = [_][]const u8{ "No body", "JSON", "Text", "XML", "Form", "Multipart", "File" };
    if (w.menu(ui, w.fmt("{s}###body-kind", .{kinds[@intCast(@backingInt(t.body_kind))]}), 126, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        for (kinds, 0..) |label, i| {
            if (c.cui_menu_item_ex(ui, w.z(label), &.{ .checked = @backingInt(t.body_kind) == i })) {
                t.body_kind = @fromBackingInt(@intCast(i));
                persist.touchTab(app, t);
            }
        }
        c.cui_menu_end(ui);
    }
    c.cui_spacer(ui);
    if (t.body_kind == .json) {
        if (w.action(ui, "format-body", "", c.CUI_ICON_LIST, false, 28, 28, 3)) commands.formatBody(app, t, 2);
        c.cui_tooltip(ui, "Format JSON");
    }
    if (w.action(ui, "find-body", "", c.CUI_ICON_SEARCH, false, 28, 28, 3)) {
        t.body.search_open = !t.body.search_open;
        t.body.query.focus();
    }
    c.cui_tooltip(ui, "Find in body");
    if (c.kest_dropdown_begin(ui, "Body actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END })) {
        if (t.body_kind == .json) {
            if (w.menuItem(ui, "Format JSON")) commands.formatBody(app, t, 2);
            if (w.menuItem(ui, "Minify JSON")) commands.formatBody(app, t, 0);
        }
        if (w.menuItem(ui, "Copy body")) w.copy(ui, t.body.text());
        c.cui_menu_end(ui);
    }
    w.end(ui);
    switch (t.body_kind) {
        .none => w.empty(ui, "This request has no body", "Choose JSON, text, a form, or a file from the menu above."),
        .json, .text, .xml => {
            commands.bodyProblem(app, t);
            if (t.body_problem_text.len > 0) w.text(ui, t.body_problem_text, .{ .size = 12, .color = w.color(c.CUI_TOKEN_DANGER) });
            if (editor.view(ui, "body-editor", &t.body, t.body.text(), false, if (t.body_kind == .json) .json else if (t.body_kind == .xml) .xml else .plain)) persist.touchTab(app, t);
        },
        .form_urlencoded, .multipart => if (table(ui, &t.form, t.body_kind == .multipart)) persist.touchTab(app, t),
        .file => {
            if (w.field(ui, "file-path", &t.file_path, .{ .placeholder = "Path to upload", .width = w.fill })) persist.touchTab(app, t);
            if (w.button(ui, "Choose file", .{})) {
                if (platform.dialog.open(app.gpa, .{ .title = "Upload file" }) catch null) |paths| {
                    defer {
                        for (paths) |p| app.gpa.free(p);
                        app.gpa.free(paths);
                    }
                    if (paths.len > 0) {
                        t.file_path.set(paths[0]);
                        persist.touchTab(app, t);
                    }
                }
            }
        },
    }
}

fn settings(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    c.cui_scroll_begin(ui, &.{ .id = "request-settings", .height = w.fill, .pad = 16, .gap = 12 });
    defer c.cui_scroll_end(ui);
    var changed = false;
    if (setting(ui, "Timeout", "Cancel the request after this duration.", "timeout", &t.timeout_text, "ms")) {
        t.settings.timeout_ms = std.fmt.parseInt(u32, t.timeout_text.text(), 10) catch 30000;
        changed = true;
    }
    if (setting(ui, "Response limit", "Stop receiving when the body reaches this size.", "max-size", &t.max_size_text, "MiB")) {
        t.settings.max_response_bytes = @as(u64, std.fmt.parseInt(u32, t.max_size_text.text(), 10) catch 256) * 1024 * 1024;
        changed = true;
    }
    if (setting(ui, "Redirect limit", "Maximum number of redirects to follow.", "redirect-limit", &t.max_redirects_text, null)) {
        t.settings.max_redirects = std.fmt.parseInt(u8, t.max_redirects_text.text(), 10) catch 10;
        changed = true;
    }
    c.cui_separator(ui);
    changed = c.cui_switch_ex(ui, "Follow redirects", &t.settings.follow_redirects, &.{ .description = "Continue when the server sends a redirect." }) or changed;
    changed = c.cui_switch_ex(ui, "Verify TLS certificates", &t.settings.verify_tls, &.{ .description = "Recommended. Disabling allows interception of this request." }) or changed;
    if (!t.settings.verify_tls) w.text(ui, "TLS verification is OFF for this request. The server's identity is not checked.", .{ .size = 12, .color = w.color(c.CUI_TOKEN_WARNING) });
    if (changed) persist.touchTab(app, t);
}

fn setting(ui: *c.cui_ctx, label: []const u8, detail: []const u8, id: [*:0]const u8, value: *@import("model.zig").TextBuffer, suffix: ?[*:0]const u8) bool {
    w.row(ui, .{ .width = w.fill, .gap = 16, .min_height = 42 });
    defer w.end(ui);
    w.column(ui, .{ .width = w.fill, .gap = 4 });
    w.text(ui, label, .{ .width = w.fill, .size = 13, .font = c.CUI_FONT_MEDIUM });
    w.text(ui, detail, .{ .width = w.fill, .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_MUTED) });
    w.end(ui);
    return w.field(ui, id, value, .{ .width = w.px(128), .suffix = suffix });
}
