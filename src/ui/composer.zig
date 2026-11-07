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

pub fn view(ui: *c.cui_ctx, app: *App, t: *Tab) void {
    w.column(ui, .{ .id = "composer-area", .width = w.fill, .pad_x = 14, .pad_y = 10, .gap = 5 });
    defer w.end(ui);
    w.row(ui, .{ .id = "request-composer", .gap = 8, .height = w.px(38), .width = w.fill });
    w.row(ui, .{ .id = "url-group", .width = w.fill, .height = w.fill, .border = 1, .border_color = w.color(c.CUI_TOKEN_BORDER_STRONG), .radius = 4, .clip = true, .pad_x = 2 });
    var method_changed = false;
    if (t.editing_method) {
        method_changed = w.flatField(ui, "method", &t.method, .{ .width = w.px(82), .size = c.CUI_SIZE_LG, .placeholder = "METHOD" }, false);
        if (w.action(ui, "standard-methods", "", c.CUI_ICON_CHEVRON_DOWN, false, 26, 32, 3)) t.editing_method = false;
    } else if (w.menu(ui, w.fmt("{s}###http-method", .{t.method.text()}), 94, w.methodColor(t.method.text()))) {
        for (methods) |method| if (c.cui_menu_item_ex(ui, w.z(method), &.{ .checked = std.mem.eql(u8, t.method.text(), method) })) {
            t.method.set(method);
            method_changed = true;
        };
        c.cui_menu_separator(ui);
        if (w.menuItem(ui, "Custom method...")) {
            t.editing_method = true;
            t.method.focus();
        }
        c.cui_menu_end(ui);
    }
    c.cui_separator(ui);
    if (app.want_url_focus) {
        t.url.focus();
        app.want_url_focus = false;
    }
    if (w.flatField(ui, "url", &t.url, .{ .placeholder = "Enter URL or paste a cURL request", .width = w.fill, .size = c.CUI_SIZE_LG }, false)) {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t.url.text(), " \t"), "curl ")) {
            if (@import("../import_export/curl.zig").parse(w.arena.allocator(), t.url.text()) catch null) |r| {
                t.fromRequest(r.request) catch {};
                for (r.warnings) |warning| app.toast(.warning, "cURL import", warning);
            }
        }
        t.syncParamsFromUrl();
        persist.touchTab(app, t);
    }
    if (method_changed) persist.touchTab(app, t);
    if (w.action(ui, "save-request", "", c.CUI_ICON_SAVE, false, 30, 32, 3)) commands.save(app, t);
    c.cui_tooltip(ui, if (t.link == null) "Save to collection (Ctrl S)" else "Save request (Ctrl S)");
    w.end(ui);
    if (w.button(ui, if (t.running()) "Cancel" else "Send", .{ .variant = if (t.running()) c.CUI_BUTTON_DANGER else c.CUI_BUTTON_PRIMARY, .size = c.CUI_SIZE_LG, .icon_right = if (t.running()) c.CUI_ICON_SQUARE else c.CUI_ICON_ARROW_RIGHT, .tooltip = if (t.running()) "Cancel request (Ctrl Enter)" else "Send request (Ctrl Enter)", .shortcut = "Ctrl Enter", .width = w.px(86) })) {
        if (t.running()) commands.cancel(t) else commands.send(app, t);
    }
    w.end(ui);
    if (variables.nextReference(t.url.text(), 0) != null) {
        // Resolution text can contain secrets from an environment. Keep it out
        // of logs and draw it only as part of this explicit request view.
        const resolved = variables.resolve(w.arena.allocator(), t.url.text(), app.activeVars()) catch "";
        w.text(ui, w.fmt("Resolved: {s}", .{resolved}), .{ .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true, .width = w.fill });
    } else if (t.url.len > 0) {
        _ = url.parse(t.url.text()) catch |err| w.text(ui, url.describe(err), .{ .size = 11, .color = w.color(c.CUI_TOKEN_DANGER) });
    }
}
