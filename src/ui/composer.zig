//! One joined HTTP method/URL control. Save and Send stay beside the request.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const Tab = @import("../app/tab.zig").Tab;
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const variables = @import("../core/variables.zig");
const url = @import("../utils/url.zig");
const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

pub const Inspection = struct {
    resolved: []const u8 = "",
    problem: ?[]const u8 = null,
    unresolved: []const []const u8 = &.{},
    has_variables: bool = false,
};

/// Uses the same one-pass substitution, trimming, validation and escaping as
/// request preparation. Rebuilt from current text/environment, never cached.
pub fn inspect(a: std.mem.Allocator, value: []const u8, vars: []const variables.Var) !Inspection {
    var out: Inspection = .{ .has_variables = std.mem.indexOf(u8, value, "{{") != null };
    var missing: std.ArrayList([]const u8) = .empty;
    try variables.collectUnresolved(a, value, vars, &missing);
    out.unresolved = missing.items;
    const resolved = std.mem.trim(u8, try variables.resolve(a, value, vars), " \t\r\n");
    out.resolved = resolved;
    _ = url.parse(resolved) catch |err| {
        out.problem = if (missing.items.len > 0) try std.fmt.allocPrint(a, "Unresolved variables ({d}). Inspect URL for missing names.", .{missing.items.len}) else url.describe(err);
        return out;
    };
    out.resolved = try url.normalize(a, resolved);
    return out;
}

pub fn view(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    w.column(ui, .{ .id = "composer-area", .width = w.fill, .pad_x = w.design.space.group, .pad_top = w.design.space.normal, .pad_bottom = w.design.space.normal, .gap = w.design.space.tight });
    defer w.end(ui);
    w.row(ui, .{ .id = "request-composer", .gap = w.design.space.normal, .height = w.px(w.design.control.large), .width = w.fill, .@"align" = c.CUI_ALIGN_CENTER });
    w.row(ui, .{ .id = "url-group", .width = w.fill, .height = w.fill, .border = 1, .border_color = w.color(c.CUI_TOKEN_BORDER_STRONG), .radius = c.KEST_RADIUS_CONTROL, .clip = true, .pad_x = 2, .@"align" = c.CUI_ALIGN_CENTER });
    var method_changed = false;
    if (t.editing_method) {
        w.row(ui, .{ .width = w.px(c.KEST_COMPOSER_METHOD), .height = w.fill, .@"align" = c.CUI_ALIGN_CENTER });
        const flags = w.flatFieldFlags(ui, "method", &t.method, .{ .width = w.fill, .size = c.CUI_SIZE_LG, .placeholder = "METHOD" }, false);
        method_changed = flags & c.CUI_CHANGED != 0;
        const done = flags & c.CUI_SUBMITTED != 0 and c.cui_key_mods(ui) == 0;
        if (w.action(ui, "standard-methods", "", c.CUI_ICON_CHEVRON_DOWN, false, 26, w.design.control.large, 3) or done) {
            t.editing_method = false;
            c.kest_focus(ui, "###http-method");
        }
        c.kest_tooltip(ui, "Standard methods");
        w.end(ui);
    } else if (c.kest_method_menu_begin(ui, w.z(t.method.text()), w.methodColor(t.method.text()))) {
        c.kest_document_list_begin(ui, "http-method-list", @min(320, c.cui_viewport_size(ui).y - 80));
        const standard = for (methods) |method| {
            if (std.mem.eql(u8, method, t.method.text())) break true;
        } else false;
        if (!standard) {
            c.kest_document_list_begin(ui, "custom-method-value", 120);
            w.text(ui, t.method.text(), .{ .width = w.fill, .font = c.CUI_FONT_MONO, .size = w.design.text.secondary });
            c.cui_scroll_end(ui);
            c.cui_menu_separator(ui);
        }
        var custom = false;
        for (methods) |method| if (c.kest_document_menu_item(ui, w.z(method), w.z(method), std.mem.eql(u8, t.method.text(), method), "http-method-list")) {
            t.method.set(method);
            method_changed = true;
        };
        c.cui_menu_separator(ui);
        if (c.kest_document_menu_item(ui, "Custom method...", "Custom method...", false, "http-method-list")) custom = true;
        c.cui_scroll_end(ui);
        c.cui_menu_end(ui);
        if (custom) {
            t.editing_method = true;
            t.method.focus();
        }
    }
    c.cui_separator(ui);
    if (app.want_url_focus) {
        t.url.focus();
        app.want_url_focus = false;
    }
    const url_flags = w.flatFieldFlags(ui, "url", &t.url, .{ .placeholder = "Enter URL or paste a cURL request", .width = w.fill, .size = c.CUI_SIZE_LG }, false);
    if (url_flags & c.CUI_CHANGED != 0) {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t.url.text(), " \t"), "curl ")) {
            if (@import("../import_export/curl.zig").parse(w.arena.allocator(), t.url.text()) catch null) |r| {
                t.fromRequest(r.request) catch {};
                for (r.warnings) |warning| app.toast(.warning, "cURL import", warning);
            }
        }
        t.syncParamsFromUrl();
        persist.touchTab(app, t);
    }
    if (method_changed) {
        if (!t.pane_chosen) t.pane = t.preferredPane();
        persist.touchTab(app, t);
    }
    const inspection = inspect(w.arena.allocator(), t.url.text(), app.activeVars()) catch Inspection{ .problem = "Couldn't inspect this URL" };
    const method_valid = @import("../network/header_check.zig").validMethod(std.mem.trim(u8, t.method.text(), " "));
    const problem = if (!method_valid) "Enter a valid HTTP method" else if (t.url.len > 0) inspection.problem else null;
    const valid = method_valid and inspection.problem == null;
    // An empty URL is not an error yet: Send stays disabled, nothing turns red.
    details(ui, app, inspection, problem != null);
    c.kest_url_invalid(ui, problem != null);
    w.end(ui);
    const saved = t.link != null and !t.dirty;
    if (c.kest_request_button(ui, if (saved) "Saved###save-request" else if (t.dirty) "Save •###save-request" else "Save###save-request", &.{ .variant = c.CUI_BUTTON_SECONDARY, .disabled = saved, .tooltip = if (saved) "Saved to collection" else if (t.link == null) "Save to collection" else "Save request changes", .shortcut = "Ctrl S", .width = w.px(c.KEST_COMPOSER_SAVE) })) commands.save(app, t);
    // Bare Enter belongs only to the focused URL. It never cancels an active
    // request, repeats a send, or steals Enter from a method/menu/dialog.
    if (url_flags & c.CUI_SUBMITTED != 0 and c.cui_key_mods(ui) == 0 and c.kest_request_enter(ui) and valid and !t.running()) commands.send(app, t);
    if (c.kest_request_button(ui, if (t.running()) "Cancel###send-request" else "Send###send-request", &.{ .variant = if (t.running()) c.CUI_BUTTON_DANGER else c.CUI_BUTTON_PRIMARY, .disabled = !t.running() and !valid, .icon_right = if (t.running()) c.CUI_ICON_SQUARE else c.CUI_ICON_ARROW_RIGHT, .tooltip = w.z(if (t.running()) "Cancel active request" else if (!valid) problem orelse "Enter a URL to send" else "Send request"), .shortcut = "Ctrl Enter", .width = w.px(c.KEST_COMPOSER_SEND) })) {
        if (t.running()) commands.cancel(t) else commands.send(app, t);
    }
    w.end(ui);
    if (problem) |message| {
        w.column(ui, .{ .id = "composer-problem", .width = w.fill });
        w.text(ui, message, .{ .size = w.design.text.secondary, .color = w.color(c.CUI_TOKEN_DANGER), .width = w.fill });
        w.end(ui);
    }
}

fn details(ui: *c.cui_ctx, app: *App, inspection: Inspection, flagged: bool) void {
    // Resolved environment values can contain secrets. Display/copy only on
    // explicit inspection; this surface never adds them to logs or preferences.
    const open = c.cui_popover_is_open(ui, "url-inspector");
    if (c.kest_request_button(ui, "###url-details", &.{ .variant = c.CUI_BUTTON_GHOST, .icon = c.CUI_ICON_LINK, .selected = open, .color = w.color(if (flagged) c.CUI_TOKEN_DANGER else if (inspection.has_variables) c.CUI_TOKEN_INFO else c.CUI_TOKEN_TEXT_SECONDARY), .width = w.px(32), .tooltip = if (inspection.has_variables) "Inspect resolved URL and variables" else "Inspect URL" })) c.cui_popover_toggle(ui, "url-inspector");
    if (!c.cui_popover_begin(ui, "url-inspector", &.{ .width = @min(520, c.cui_viewport_size(ui).x - 32), .pad = w.design.space.group, .gap = w.design.space.normal, .placement = c.CUI_PLACE_BOTTOM_END })) return;
    var close = false;
    w.text(ui, if (inspection.has_variables) "Resolved URL" else "Request URL", .{ .font = c.CUI_FONT_MEDIUM, .size = w.design.text.body });
    if (inspection.has_variables) w.text(ui, if (app.active_env) |env| w.fmt("Environment: {s}", .{env.name}) else "No environment selected", .{ .size = w.design.text.secondary, .width = w.fill });
    c.kest_document_list_begin(ui, "resolved-url-content", @min(220, c.cui_viewport_size(ui).y - 200));
    w.text(ui, if (inspection.resolved.len > 0) inspection.resolved else "Enter a URL to inspect", .{ .font = c.CUI_FONT_MONO, .size = w.design.text.secondary, .width = w.fill });
    for (inspection.unresolved) |name| w.text(ui, w.fmt("Missing: {s}", .{name}), .{ .size = w.design.text.secondary, .color = w.color(c.CUI_TOKEN_DANGER), .width = w.fill });
    c.cui_scroll_end(ui);
    if (inspection.problem) |message| w.text(ui, message, .{ .size = w.design.text.secondary, .color = w.color(c.CUI_TOKEN_DANGER), .width = w.fill });
    if (w.button(ui, "Copy resolved URL", .{ .icon = c.CUI_ICON_COPY, .disabled = inspection.problem != null })) {
        w.copy(ui, inspection.resolved);
        close = true;
    }
    c.cui_popover_end(ui);
    if (close) c.cui_popover_close(ui, "url-inspector");
}
