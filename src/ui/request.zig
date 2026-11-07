const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const persist = @import("../app/persist.zig");

pub const bar = @import("composer.zig").view;

pub fn minimumHeight(t: *const tab.Tab) f32 {
    return switch (t.pane) {
        .params => if (t.params.rows.items.len > 0 or t.params.bulk != null) 148 else 112,
        .headers => if (t.headers.rows.items.len > 0 or t.headers.bulk != null) 148 else 112,
        .body => if (t.body_kind == .multipart or t.body_kind == .form_urlencoded) (if (t.form.rows.items.len > 0 or t.form.bulk != null) 180 else 148) else if (t.body_kind == .file and t.file_path.len > 0) 184 else if (t.body_kind == .json and t.body_problem_text.len > 0) 176 else 140,
        .settings => 140,
    };
}

pub fn view(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    w.column(ui, .{ .id = "request-panel", .height = w.fill, .width = w.fill, .clip = true });
    defer w.end(ui);
    w.row(ui, .{ .id = "request-navigation", .pad_left = w.design.space.tight, .pad_right = w.design.space.compact, .height = w.px(w.design.control.tab_height), .width = w.fill });
    // Settings is an ordinary labeled section rather than a floating gear.
    // Focusing the response lives in the Layout menu; any section restores it.
    const keys = [_][*:0]const u8{ "pane-params", "pane-body", "pane-headers", "pane-settings" };
    const custom = customSettings(t);
    const labels = [_][]const u8{ w.counted("Params", t.params.rows.items.len), if (t.hasBodyContent()) "Body •" else "Body", w.counted("Headers", t.headers.rows.items.len), if (custom) "Settings •" else "Settings" };
    const panes = [_]tab.RequestPane{ .params, .body, .headers, .settings };
    const current = std.mem.indexOfScalar(tab.RequestPane, &panes, t.pane);
    const next = w.tabNavigation(ui, &keys, current orelse 0);
    if (current != null and next != current.?) selectPane(app, t, panes[next]);
    for (labels, panes, keys) |label, pane, key| {
        if (w.contentTab(ui, key, label, t.pane == pane and !t.details_collapsed)) {
            selectPane(app, t, pane);
        }
        switch (pane) {
            .body => c.cui_tooltip(ui, if (t.hasBodyContent()) "Request body contains content" else "Request body"),
            .headers => c.cui_tooltip(ui, "Configured request headers; automatic headers are in the table actions menu"),
            .settings => c.cui_tooltip(ui, if (custom) "Timeout, size, redirect and TLS options; some differ from the defaults" else "Timeout, size, redirect and TLS options"),
            .params => {},
        }
    }
    c.cui_spacer(ui);
    w.end(ui);
    w.separator(ui, "request-navigation-boundary");
    if (t.details_collapsed) return;
    switch (t.pane) {
        .params => if (@import("key_value.zig").view(ui, &t.params, false, "Query parameters", .{ .kind = .params, .vars = app.activeVars() })) {
            t.syncUrlFromParams();
            persist.touchTab(app, t);
        },
        .headers => if (@import("key_value.zig").view(ui, &t.headers, false, "Configured request headers", .{ .kind = .headers, .vars = app.activeVars(), .request = t })) persist.touchTab(app, t),
        .body => @import("body.zig").view(ui, app, t),
        .settings => settings(ui, app, t),
    }
}

fn selectPane(app: *App, t: *tab.Tab, pane: tab.RequestPane) void {
    t.pane = pane;
    t.pane_chosen = true;
    t.details_collapsed = false;
    persist.prefsChanged(app);
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

/// Whether any per-request transfer option differs from its default, so the
/// Settings section can say so without being opened.
pub fn customSettings(t: *const tab.Tab) bool {
    const defaults: @import("../core/request.zig").Settings = .{};
    const s = t.settings;
    return s.timeout_ms != defaults.timeout_ms or s.follow_redirects != defaults.follow_redirects or
        s.max_redirects != defaults.max_redirects or s.max_response_bytes != defaults.max_response_bytes or
        s.verify_tls != defaults.verify_tls;
}
