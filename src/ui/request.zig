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
        .headers => if (@import("key_value.zig").view(ui, &t.headers, false, "Configured request headers", .{ .kind = .headers, .vars = app.activeVars(), .env_name = if (app.active_env) |env| env.name else null, .request = t })) persist.touchTab(app, t),
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
    c.cui_scroll_begin(ui, &.{ .id = "request-settings", .height = w.fill, .pad = w.design.space.group, .gap = w.design.space.normal });
    defer c.cui_scroll_end(ui);
    var changed = false;
    if (setting(ui, "Timeout", "timeout", &t.timeout_text, "ms")) {
        t.settings.timeout_ms = std.fmt.parseInt(u32, t.timeout_text.text(), 10) catch 30000;
        changed = true;
    }
    if (setting(ui, "Response limit", "max-size", &t.max_size_text, "MiB")) {
        t.settings.max_response_bytes = @as(u64, std.fmt.parseInt(u32, t.max_size_text.text(), 10) catch 256) * 1024 * 1024;
        changed = true;
    }
    if (setting(ui, "Redirect limit", "redirect-limit", &t.max_redirects_text, null)) {
        t.settings.max_redirects = std.fmt.parseInt(u8, t.max_redirects_text.text(), 10) catch 10;
        changed = true;
    }
    c.cui_separator(ui);
    changed = c.cui_switch_ex(ui, "Follow redirects", &t.settings.follow_redirects, &.{}) or changed;
    changed = c.cui_switch_ex(ui, "Verify TLS certificates", &t.settings.verify_tls, &.{}) or changed;
    if (changed) persist.touchTab(app, t);
}

fn setting(ui: *c.cui_ctx, label: []const u8, id: [*:0]const u8, value: *@import("model.zig").TextBuffer, suffix: ?[*:0]const u8) bool {
    w.row(ui, .{ .width = w.fill, .gap = w.design.space.section, .@"align" = c.CUI_ALIGN_CENTER });
    defer w.end(ui);
    w.text(ui, label, .{ .width = w.fill, .size = c.KEST_TEXT_BODY, .nowrap = true });
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
