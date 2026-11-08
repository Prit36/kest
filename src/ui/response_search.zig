//! Find controls for the current immutable response text. Query snapshots and
//! result ownership are bounded; search workers never reference native fields.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const State = @import("code_state.zig").State;
const core = @import("../core/response_search.zig");
const prep = @import("../app/response_prepare.zig");
const App = @import("../app/state.zig").App;
const Tab = @import("../app/tab.zig").Tab;

pub fn open(t: *Tab) void {
    const job = t.shown orelse return;
    const cls = job.resp.class();
    if (cls == .binary or cls == .image) return;
    const v = &t.response;
    if (v.pane == .headers) v.pane = v.body_pane;
    if (v.pane == .preview and cls != .html) v.pane = .raw;
    if (v.pane == .pretty and cls == .json and v.pretty_mode == .tree) {
        // The JSON viewer has its own search, unless it couldn't be built.
        if (!v.tree_failed and v.preparation_failure == null) {
            @import("json_view.zig").openFind(&v.json);
            return;
        }
        v.pretty_mode = .text;
    }
    if (v.pane == .raw or v.pane == .pretty) v.body_pane = v.pane;
    const s = if (v.pane == .raw) &v.code_raw else &v.code_pretty;
    s.search_open = true;
    if (s.search_failure == .unavailable) s.search_failure = null;
    s.query.focus();
}

pub fn abandon(s: *State) void {
    if (s.search_job) |job| job.abandon();
    s.search_job = null;
    s.search_pending = false;
    s.search_target = null;
}
fn wake(raw: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(raw));
    app.wake();
}
fn select(s: *State, ordinal: u32) bool {
    if (ordinal < s.search_page_start or ordinal - s.search_page_start >= s.matches.items.len) return false;
    const at = ordinal - s.search_page_start;
    const match = s.matches.items[at];
    s.search_selected = ordinal;
    s.match_at = at;
    s.anchor = match.start;
    s.caret = match.end;
    s.precise_goal = null;
    s.reveal = true;
    return true;
}

/// Every retained result is keyed by the exact original query, options, source
/// identity/length. Layout/index adoption does not change immutable source bytes.
fn update(app: *App, t: *Tab, s: *State, source: []const u8, owner: ?*prep.Bytes) void {
    const query = s.query.text();
    if (query.len > core.max_query or source.len > core.max_input) {
        s.clearResponseSearch();
        s.search_failure = if (query.len > core.max_query) .query_limit else .input_limit;
        s.searched_ptr = 0;
        return;
    }
    if (!std.mem.eql(u8, s.search_key[0..s.search_key_len], query) or s.search_key_case != s.search_case or s.searched_ptr != @intFromPtr(source.ptr) or s.searched_len != source.len) {
        s.clearResponseSearch();
        @memcpy(s.search_key[0..query.len], query);
        s.search_key_len = query.len;
        s.search_key_case = s.search_case;
        s.searched_version = s.version;
        s.searched_ptr = @intFromPtr(source.ptr);
        s.searched_len = source.len;
    }
    if (query.len == 0) return;
    if (s.search_job) |job| if (job.take()) |value| {
        var result = value;
        defer result.deinit(app.gpa);
        job.release();
        s.search_job = null;
        switch (result) {
            .search => |found| {
                if (s.search_index) |*old| old.deinit(app.gpa);
                s.matches.deinit(app.gpa);
                s.matches = found.matches;
                s.search_index = found.index;
                s.search_page_start = found.page_start;
                s.search_selected = found.selected;
                s.matches_truncated = found.index.total > found.matches.items.len;
                s.search_target = null;
                if (found.index.total > 0) _ = select(s, found.selected);
                result = .none;
            },
            else => s.search_failure = .unavailable,
        }
    };
    const needs = s.search_index == null or s.search_target != null;
    if (needs and s.search_job == null and s.search_failure == null) {
        const seek: core.Seek = if (s.search_target) |target| .{ .ordinal = target } else .{ .near = s.caret };
        s.search_job = app.response_preparation.find(t.shown.?, source, owner, query, .{ .case_sensitive = s.search_case }, seek, .{ .ctx = app, .call = wake }) catch |err| blk: {
            if (err != error.Busy) s.search_failure = .unavailable;
            break :blk null;
        };
    }
    s.search_pending = needs and s.search_failure == null;
}

pub fn navigate(s: *State, delta: i32) void {
    const index = if (s.search_index) |*value| value else return;
    if (index.total == 0) return;
    const at = s.search_target orelse s.search_selected;
    const target: u32 = @intCast(@mod(@as(i64, at) + delta, @as(i64, index.total)));
    if (s.search_job) |job| job.abandon();
    s.search_job = null;
    s.search_failure = null;
    if (select(s, target)) {
        s.search_target = null;
        s.search_pending = false;
    } else {
        s.search_target = target;
        s.search_pending = true;
    }
}
fn close(ui: *c.cui_ctx, s: *State, canvas: [*:0]const u8) void {
    s.search_open = false;
    abandon(s);
    c.kest_focus(ui, canvas);
}
fn caption(s: *const State) []const u8 {
    if (s.search_failure) |failure| return switch (failure) {
        .query_limit => "Query too long",
        .input_limit => "Text too large",
        .unavailable => "Search unavailable",
    };
    if (s.search_pending) return "Searching...";
    if (s.query.text().len == 0) return "";
    const index = if (s.search_index) |*value| value else return "Searching...";
    return if (index.total == 0) "No matches" else w.fmt("{d} / {d}", .{ s.search_selected + 1, index.total });
}
fn icon(ui: *c.cui_ctx, key: [*:0]const u8, glyph: [*:0]const u8, hint: [*:0]const u8) bool {
    w.row(ui, .{ .id = key, .width = w.px(28), .height = w.px(28) });
    defer w.end(ui);
    return w.icon(ui, glyph, hint);
}
fn controls(ui: *c.cui_ctx, s: *State, canvas: [*:0]const u8, compact: bool) void {
    if (w.action(ui, "response-find-case", "Aa", null, s.search_case, 28, 28, 0)) s.search_case = !s.search_case;
    c.kest_tooltip(ui, "Match case");
    w.text(ui, caption(s), .{ .width = if (compact) w.fill else w.px(112), .size = c.KEST_TEXT_CAPTION, .nowrap = true, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    c.cui_push_disabled(ui, s.search_index == null or s.search_index.?.total == 0);
    if (icon(ui, "response-find-prev", c.CUI_ICON_CHEVRON_UP, "Previous match (Shift+Enter or Shift+F3)")) navigate(s, -1);
    if (icon(ui, "response-find-next", c.CUI_ICON_CHEVRON_DOWN, "Next match (Enter or F3)")) navigate(s, 1);
    c.cui_pop_disabled(ui);
    if (!compact and icon(ui, "response-find-close", c.CUI_ICON_X, "Close response search (Escape)")) close(ui, s, canvas);
}

pub fn bar(ui: *c.cui_ctx, app: *App, t: *Tab, canvas: [*:0]const u8, s: *State, source: []const u8, owner: ?*prep.Bytes) void {
    if (!s.search_open) {
        abandon(s);
        return;
    }
    s.search_visible = true;
    const rect = c.cui_get_rect(ui, c.cui_make_id(ui, "response-content"));
    const compact = rect.w > 0 and rect.w < 400;
    const query_focus = c.kest_editor_focus(ui, c.cui_make_id(ui, "response-find")) != 0;
    const canvas_focus = c.kest_editor_focus(ui, c.cui_make_id(ui, canvas)) != 0;
    const select_query = s.query.want_focus;
    w.column(ui, .{ .id = "response-search", .width = w.fill, .pad_x = 8, .pad_y = 6, .gap = 4 });
    w.row(ui, .{ .width = w.fill, .gap = 4, .@"align" = c.CUI_ALIGN_CENTER });
    _ = s.query.reserve(core.max_query + 2);
    _ = w.field(ui, "response-find", &s.query, .{ .placeholder = "Find in response", .width = w.fill, .size = c.CUI_SIZE_SM });
    if (select_query) c.kest_input_select_all(ui, "response-find", @intCast(s.query.text().len));
    update(app, t, s, source, owner);
    if (compact) {
        if (icon(ui, "response-find-close", c.CUI_ICON_X, "Close response search (Escape)")) close(ui, s, canvas);
        w.end(ui);
        w.row(ui, .{ .width = w.fill, .gap = 4, .@"align" = c.CUI_ALIGN_CENTER });
    }
    controls(ui, s, canvas, compact);
    w.end(ui);
    w.end(ui);
    const mods = c.cui_key_mods(ui);
    const search_focus = query_focus or canvas_focus or c.kest_focus_within(ui, "response-search");
    if (search_focus and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) close(ui, s, canvas);
    if (s.search_open and search_focus) {
        const enter = query_focus and c.cui_key_pressed(ui, c.CUI_KEY_ENTER) and mods & c.CUI_MOD_PRIMARY == 0;
        if (enter or c.cui_key_pressed(ui, c.CUI_KEY_F3)) navigate(s, if (mods & c.CUI_MOD_SHIFT != 0) -1 else 1);
    }
    if (s.search_open) update(app, t, s, source, owner);
}
