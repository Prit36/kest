//! Response-only geometry, reflow and navigation. Large source scans run on
//! bounded workers; paint and hit testing only visit visible checkpoints.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const code = @import("code_state.zig");
const State = code.State;
const editor = @import("editor.zig");
const hl = @import("../utils/highlight.zig");
const spatial = @import("../core/text_layout.zig");
const prep = @import("../app/response_prepare.zig");
const find = @import("response_search.zig");
const App = @import("../app/state.zig").App;
const Tab = @import("../app/tab.zig").Tab;
const line_h = 20;
const gap = 12;
const bar = 12;
const inline_limit = 4096;
const Paint = struct { state: *State, source: []const u8, lang: hl.Lang, focused: bool, gutter: f32 };

pub fn beginFrame(v: *@import("../app/tab.zig").ResponseView) void {
    v.code_raw.layout_visible = false;
    v.code_pretty.layout_visible = false;
    v.code_raw.search_visible = false;
    v.code_pretty.search_visible = false;
}
pub fn endFrame(v: *@import("../app/tab.zig").ResponseView) void {
    for ([_]*State{ &v.code_raw, &v.code_pretty }) |s| if (!s.layout_visible) {
        if (s.layout_job) |job| job.abandon();
        s.layout_job = null;
        s.layout_pending = false;
    };
    for ([_]*State{ &v.code_raw, &v.code_pretty }) |s| if (!s.search_visible) find.abandon(s);
}
fn boundary(source: []const u8, position: usize) usize {
    var pos = @min(position, source.len);
    while (pos > 0 and pos < source.len and source[pos] & 0xc0 == 0x80) pos -= 1;
    return pos;
}

pub fn metrics(ui: *c.cui_ctx) spatial.Metrics {
    return .{ .ctx = ui, .width = nativeWidth };
}
fn nativeWidth(raw: ?*anyopaque, source: []const u8) f64 {
    const ui: *c.cui_ctx = @ptrCast(@alignCast(raw.?));
    return c.cui_measure_text(ui, c.CUI_FONT_MONO, 13, source.ptr, @intCast(source.len)).width;
}
fn openMetrics(_: ?*anyopaque) ?*anyopaque {
    return c.cui_create(&.{});
}
fn closeMetrics(raw: *anyopaque) void {
    c.cui_destroy(@ptrCast(@alignCast(raw)));
}
const factory: spatial.Factory = .{ .open = openMetrics, .width = nativeWidth, .close = closeMetrics };
fn wake(raw: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(raw));
    app.wake();
}

pub fn view(ui: *c.cui_ctx, app: *App, t: *Tab, id: [*:0]const u8, s: *State, source: []const u8, owner: ?*prep.Bytes, lang: hl.Lang) void {
    s.layout_visible = true;
    const identity = c.cui_make_id(ui, id);
    const previous = c.cui_get_rect(ui, identity);
    const char_w = editor.cellWidth(ui);
    const gutter = editor.gutterWidth(ui, if (s.index.count() > 0) s.index.lineNumber(s.index.count() - 1) else 1);
    const config: spatial.Config = .{ .char_width = char_w, .wrap_width = if (t.response.wrap_response) @max(char_w, previous.w - gutter - gap - bar - 8) else 0, .lang = lang };
    if (s.layout_ptr != @intFromPtr(source.ptr) or s.layout_len != source.len) {
        s.clearLayout();
        s.layout_ptr = @intFromPtr(source.ptr);
        s.layout_len = source.len;
        s.caret = boundary(source, @min(s.caret, source.len));
        s.anchor = boundary(source, @min(s.anchor, source.len));
        s.scroll_y = 0;
        s.precise_x = 0;
        s.layout_fallback_offset = 0;
        if (s.layout_fallback) |fallback| {
            fallback.deinit();
            fallback.* = .init(app.gpa);
        }
    }
    if (s.layout_config == null or !s.layout_config.?.eql(config)) {
        if (s.layout_job) |job| job.abandon();
        s.layout_job = null;
        s.layout_config = config;
        s.layout_failure = false;
    }
    if (s.layout_job) |job| if (job.take()) |value| {
        var result = value;
        defer result.deinit(app.gpa);
        job.release();
        s.layout_job = null;
        switch (result) {
            .layout => |layout| {
                adopt(ui, s, source, layout);
                result = .none;
            },
            else => s.layout_failure = true,
        }
    };
    const needs_layout = if (s.geometry) |*geometry| !geometry.config.eql(config) else true;
    if (needs_layout and s.layout_job == null and !s.layout_failure) {
        if (source.len <= inline_limit) {
            if (spatial.Layout.build(app.gpa, source, config, metrics(ui), null)) |layout| adopt(ui, s, source, layout) else |_| {
                s.layout_failure = true;
            }
        } else {
            s.layout_job = app.response_preparation.layout(t.shown.?, source, owner, config, factory, .{ .ctx = app, .call = wake }) catch |err| blk: {
                if (err != error.Busy) s.layout_failure = true;
                break :blk null;
            };
        }
    }
    s.word_wrap = t.response.wrap_response;
    s.layout_pending = !s.layout_failure and (if (s.geometry) |*geometry| !geometry.config.eql(config) else true);
    find.bar(ui, app, t, id, s, source, owner);
    if (s.geometry == null) {
        w.text(ui, if (s.layout_failure) "Text layout could not be prepared." else "Preparing text layout...", .{ .size = 11, .width = w.fill, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        fallbackView(ui, app, id, s, source, lang, inline_limit);
        return;
    }
    if (s.layout_pending or (needs_layout and s.layout_failure)) w.text(ui, if (s.layout_failure) "Reflow unavailable; keeping the previous layout." else "Reflowing text...", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    const focused = c.kest_editor_focus(ui, identity) != 0;
    if (focused) keys(ui, s, source, previous.h);
    const wheel = c.kest_editor_scroll_axes(ui, identity);
    s.scroll_y = @max(0, s.scroll_y - wheel.y * line_h * 3);
    s.precise_x = @max(0, s.precise_x - @as(f64, wheel.x) * char_w * 3);
    const paint: Paint = .{ .state = s, .source = source, .lang = lang, .focused = focused, .gutter = gutter };
    const result = c.cui_canvas(ui, id, w.fill, w.fill, draw, &paint, @sizeOf(Paint));
    c.kest_editor_register(ui, identity);
    c.kest_editor_tabs(ui, identity, 0);
    pointer(ui, s, source, result.rect, gutter, result.pressed, c.kest_editor_focus(ui, identity) != 0);
}

/// The initial/raw-index fallback still searches the full available text. A
/// distant match selects a bounded byte window even when full layout is limited.
pub fn pendingView(ui: *c.cui_ctx, app: *App, t: *Tab, id: [*:0]const u8, s: *State, source: []const u8, lang: hl.Lang) void {
    find.bar(ui, app, t, id, s, source, null);
    fallbackView(ui, app, id, s, source, lang, prep.inline_limit);
}
fn fallbackView(ui: *c.cui_ctx, app: *App, id: [*:0]const u8, s: *State, source: []const u8, lang: hl.Lang, limit: usize) void {
    if (s.layout_fallback == null) {
        const fallback = app.gpa.create(State) catch return;
        fallback.* = .init(app.gpa);
        s.layout_fallback = fallback;
    }
    const fallback = s.layout_fallback.?;
    var base = @min(s.layout_fallback_offset, source.len);
    if (s.search_open and s.reveal and (s.caret > base + @min(limit, source.len - base) or s.anchor < base)) base = boundary(source, s.selection()[0] -| 512);
    var end = @min(source.len, base + limit);
    while (end > base and end < source.len and source[end] & 0xc0 == 0x80) end -= 1;
    const window = source[base..end];
    if (fallback.indexed_ptr != @intFromPtr(window.ptr) or fallback.indexed_len != window.len or s.reveal) {
        fallback.caret = boundary(window, s.caret -| base);
        fallback.anchor = boundary(window, s.anchor -| base);
        fallback.reveal = true;
    }
    s.layout_fallback_offset = base;
    if (base > 0) w.text(ui, w.fmt("Viewing bytes {d}-{d} of {d}", .{ base + 1, end, source.len }), .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    const caret_before = fallback.caret;
    const anchor_before = fallback.anchor;
    _ = editor.view(ui, id, fallback, window, true, lang);
    if (fallback.caret != caret_before or fallback.anchor != anchor_before) {
        s.caret = base + fallback.caret;
        s.anchor = base + fallback.anchor;
        s.precise_goal = null;
    }
    s.reveal = false;
}

fn adopt(ui: *c.cui_ctx, s: *State, source: []const u8, value: spatial.Layout) void {
    var anchor: usize = 0;
    var old_y = @mod(s.scroll_y, line_h);
    const had_geometry = s.geometry != null;
    const fallback = s.layout_fallback;
    if (!had_geometry) if (fallback) |prefix| if (prefix.index.count() > 0) {
        const row = @min(prefix.index.count() - 1, @as(usize, @intFromFloat(@max(0, prefix.scroll_y / line_h))));
        anchor = s.layout_fallback_offset + prefix.index.starts.items[row];
        old_y = @mod(prefix.scroll_y, line_h);
    };
    if (s.geometry) |*old| {
        const row = @min(s.index.count() - 1, @as(usize, @intFromFloat(@max(0, s.scroll_y / line_h))));
        anchor = old.byteAt(&s.index, source, row, s.precise_x, metrics(ui));
        old.deinit(s.gpa);
    }
    s.index.deinit(s.gpa);
    s.index = value.index;
    s.geometry = value;
    s.geometry.?.index = .{};
    s.indexed_ptr = @intFromPtr(source.ptr);
    s.indexed_len = source.len;
    s.indexed_version = s.version;
    s.index_generation +%= 1;
    s.precise_goal = null;
    s.scroll_y = @as(f32, @floatFromInt(s.index.rowOf(anchor) * line_h)) + old_y;
    s.precise_x = if (value.config.wrap_width > 0 or !had_geometry) 0 else value.position(&s.index, source, s.index.rowOf(anchor), anchor, metrics(ui));
    if (!had_geometry) {
        s.reveal = fallback == null;
        s.selecting = if (fallback) |prefix| prefix.selecting else false;
    }
}

fn keys(ui: *c.cui_ctx, s: *State, source: []const u8, height: f32) void {
    const mods = c.cui_key_mods(ui);
    const shift = mods & c.CUI_MOD_SHIFT != 0;
    const ctrl = mods & c.CUI_MOD_PRIMARY != 0;
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_A)) {
        _ = s.command(.select_all, source, true);
        s.precise_goal = null;
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_C)) w.copy(ui, s.selected(source));
    if (c.cui_key_pressed(ui, c.CUI_KEY_LEFT)) {
        _ = s.command(if (ctrl) (if (shift) .select_word_left else .move_word_left) else (if (shift) .select_left else .move_left), source, true);
        s.precise_goal = null;
    }
    if (c.cui_key_pressed(ui, c.CUI_KEY_RIGHT)) {
        _ = s.command(if (ctrl) (if (shift) .select_word_right else .move_word_right) else (if (shift) .select_right else .move_right), source, true);
        s.precise_goal = null;
    }
    const row = s.index.rowOf(s.caret);
    const bounds = s.index.bounds(source, row);
    if (c.cui_key_pressed(ui, c.CUI_KEY_HOME)) {
        s.moveTo(if (ctrl) 0 else bounds[0], shift);
        s.precise_goal = null;
    }
    if (c.cui_key_pressed(ui, c.CUI_KEY_END)) {
        s.moveTo(if (ctrl) source.len else bounds[1], shift);
        s.precise_goal = null;
    }
    const up = c.cui_key_pressed(ui, c.CUI_KEY_UP);
    const down = c.cui_key_pressed(ui, c.CUI_KEY_DOWN);
    const pgup = c.cui_key_pressed(ui, c.CUI_KEY_PAGE_UP);
    const pgdown = c.cui_key_pressed(ui, c.CUI_KEY_PAGE_DOWN);
    if (up or down or pgup or pgdown) {
        const geometry = &s.geometry.?;
        const aim = s.precise_goal orelse geometry.position(&s.index, source, row, s.caret, metrics(ui));
        const rows: usize = if (pgup or pgdown) @intFromFloat(@max(1, @floor((height - 16 - bar) / line_h))) else 1;
        const target = if (up or pgup) row -| rows else @min(row + rows, s.index.count() - 1);
        s.moveTo(geometry.byteAt(&s.index, source, target, aim, metrics(ui)), shift);
        s.precise_goal = aim;
    }
}

const Scrollbars = struct {
    horizontal: c.cui_rect,
    vertical: c.cui_rect,
    hthumb: c.cui_rect,
    vthumb: c.cui_rect,
    width: f64,
    height: f32,
    max_x: f64,
    max_y: f32,
};
fn scrollbars(s: *State, rect: c.cui_rect, gutter: f32) Scrollbars {
    const width = @max(1, rect.w - gutter - gap - bar - 8);
    const height = @max(1, rect.h - 16 - bar);
    const total: f32 = @floatFromInt(s.index.count() * line_h);
    const max_x = if (s.geometry.?.config.wrap_width > 0) 0 else @max(0, s.geometry.?.widest - width);
    const max_y = @max(0, total - height);
    s.precise_x = std.math.clamp(s.precise_x, 0, max_x);
    s.scroll_y = std.math.clamp(s.scroll_y, 0, max_y);
    const horizontal: c.cui_rect = .{ .x = rect.x + gutter + gap, .y = rect.y + rect.h - bar, .w = width, .h = bar };
    const vertical: c.cui_rect = .{ .x = rect.x + rect.w - bar, .y = rect.y + 8, .w = bar, .h = height };
    const hw: f32 = @floatCast(@min(width, @max(24, @as(f64, width) * width / @max(width, s.geometry.?.widest))));
    const vh = @min(height, @max(24, height * height / @max(height, total)));
    return .{ .width = width, .height = height, .max_x = max_x, .max_y = max_y, .horizontal = horizontal, .vertical = vertical, .hthumb = .{ .x = horizontal.x + (if (max_x > 0) @as(f32, @floatCast(s.precise_x / max_x)) * (width - hw) else 0), .y = horizontal.y + 3, .w = hw, .h = 6 }, .vthumb = .{ .x = vertical.x + 3, .y = vertical.y + (if (max_y > 0) s.scroll_y / max_y * (height - vh) else 0), .w = 6, .h = vh } };
}
fn inside(rect: c.cui_rect, mouse: c.cui_vec2) bool {
    return mouse.x >= rect.x and mouse.x < rect.x + rect.w and mouse.y >= rect.y and mouse.y < rect.y + rect.h;
}
fn pointer(ui: *c.cui_ctx, s: *State, source: []const u8, rect: c.cui_rect, gutter: f32, pressed: bool, focused: bool) void {
    if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT) or !focused) {
        s.selecting = false;
        s.scroll_drag = .none;
        return;
    }
    const bars = scrollbars(s, rect, gutter);
    const mouse = c.cui_mouse_pos(ui);
    if (pressed and !s.selecting and s.scroll_drag == .none) {
        if (bars.max_x > 0 and inside(bars.horizontal, mouse)) {
            s.scroll_drag = .horizontal;
            s.drag_offset = if (inside(bars.hthumb, mouse)) mouse.x - bars.hthumb.x else bars.hthumb.w / 2;
        } else if (bars.max_y > 0 and inside(bars.vertical, mouse)) {
            s.scroll_drag = .vertical;
            s.drag_offset = if (inside(bars.vthumb, mouse)) mouse.y - bars.vthumb.y else bars.vthumb.h / 2;
        } else if (inside(rect, mouse)) {
            s.selecting = true;
            const row = @min(s.index.count() - 1, @as(usize, @intFromFloat(@max(0, @floor((mouse.y - rect.y - 8 + s.scroll_y) / line_h)))));
            s.moveTo(s.geometry.?.byteAt(&s.index, source, row, @max(0, mouse.x - rect.x - gutter - gap + s.precise_x), metrics(ui)), c.cui_key_mods(ui) & c.CUI_MOD_SHIFT != 0);
            return;
        }
    }
    switch (s.scroll_drag) {
        .horizontal => s.precise_x = std.math.clamp((mouse.x - bars.horizontal.x - s.drag_offset) / @max(1, bars.horizontal.w - bars.hthumb.w), 0, 1) * bars.max_x,
        .vertical => s.scroll_y = std.math.clamp((mouse.y - bars.vertical.y - s.drag_offset) / @max(1, bars.vertical.h - bars.vthumb.h), 0, 1) * bars.max_y,
        .none => if (s.selecting) {
            if (mouse.y < rect.y + 8) s.scroll_y = @max(0, s.scroll_y - line_h);
            if (mouse.y > rect.y + rect.h - bar) s.scroll_y += line_h;
            if (mouse.x < rect.x + gutter + gap) s.precise_x = @max(0, s.precise_x - 24);
            if (mouse.x > rect.x + rect.w - bar) s.precise_x += 24;
            const row = @min(s.index.count() - 1, @as(usize, @intFromFloat(@max(0, @floor((mouse.y - rect.y - 8 + s.scroll_y) / line_h)))));
            s.moveTo(s.geometry.?.byteAt(&s.index, source, row, @max(0, mouse.x - rect.x - gutter - gap + s.precise_x), metrics(ui)), true);
        },
    }
}

fn draw(raw_ui: ?*c.cui_ctx, rect: c.cui_rect, raw: ?*anyopaque) callconv(.c) void {
    const ui = raw_ui.?;
    const p: *const Paint = @ptrCast(@alignCast(raw.?));
    const s = p.state;
    const geometry = &s.geometry.?;
    var bars = scrollbars(s, rect, p.gutter);
    if (s.reveal) {
        const row = s.index.rowOf(s.caret);
        const y: f32 = @floatFromInt(row * line_h);
        if (y < s.scroll_y) s.scroll_y = y;
        if (y + line_h > s.scroll_y + bars.height) s.scroll_y = y + line_h - bars.height;
        const x = geometry.position(&s.index, p.source, row, s.caret, metrics(ui));
        if (x < s.precise_x) s.precise_x = x;
        if (x > s.precise_x + bars.width) s.precise_x = x - bars.width;
        s.reveal = false;
        bars = scrollbars(s, rect, p.gutter);
    }
    s.scroll_x = @floatCast(s.precise_x); // compatibility/diagnostics only
    c.cui_push_clip(ui, rect);
    defer c.cui_pop_clip(ui);
    c.cui_draw_rect(ui, rect, .{}, w.color(c.CUI_TOKEN_SURFACE));
    c.cui_draw_rect(ui, .{ .x = rect.x, .y = rect.y, .w = p.gutter, .h = rect.h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
    c.cui_draw_line(ui, .{ .x = rect.x + p.gutter, .y = rect.y }, .{ .x = rect.x + p.gutter, .y = rect.y + rect.h }, 1 / @max(1, c.cui_dpi_scale(ui)), w.color(c.CUI_TOKEN_BORDER_SUBTLE));
    if (p.focused) c.cui_draw_line(ui, .{ .x = rect.x, .y = rect.y + 0.5 }, .{ .x = rect.x + rect.w, .y = rect.y + 0.5 }, 1 / @max(1, c.cui_dpi_scale(ui)), w.color(c.CUI_TOKEN_FOCUS_RING));
    const first: usize = @intFromFloat(@floor(s.scroll_y / line_h));
    const last = @min(s.index.count(), first + @as(usize, @intFromFloat(@ceil(bars.height / line_h))) + 1);
    const active = s.index.rowOf(s.caret);
    const selection = s.selection();
    var dense = false;
    for (first..last) |row| {
        const bounds = s.index.bounds(p.source, row);
        const y = rect.y + 8 + @as(f32, @floatFromInt(row * line_h)) - s.scroll_y;
        const origin: f64 = rect.x + p.gutter + gap;
        c.cui_push_clip(ui, .{ .x = @floatCast(origin), .y = rect.y + 8, .w = @floatCast(bars.width + 1), .h = bars.height });
        if (p.focused and row == active) c.cui_draw_rect(ui, .{ .x = @floatCast(origin), .y = y, .w = @floatCast(bars.width), .h = line_h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
        dense = highlight(ui, s, p.source, row, origin, y, bars.width) or dense;
        if (selection[1] > bounds[0] and selection[0] < bounds[1]) {
            const left = @max(0, geometry.position(&s.index, p.source, row, @max(bounds[0], selection[0]), metrics(ui)) - s.precise_x);
            const right = @min(bars.width, geometry.position(&s.index, p.source, row, @min(bounds[1], selection[1]), metrics(ui)) - s.precise_x);
            if (right > left) c.cui_draw_rect(ui, .{ .x = @floatCast(origin + left), .y = y, .w = @floatCast(right - left), .h = line_h }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
        }
        const cps = geometry.checkpoints(row);
        const begin = geometry.atX(row, @max(0, s.precise_x - geometry.config.char_width));
        const end = @min(cps[1], geometry.atX(row, s.precise_x + bars.width) + 1);
        // A pathological run of combining/zero-width characters has bounded
        // painting too. Bytes stay available for selection/copy/save.
        const limit = @min(end, begin + 32);
        dense = dense or limit < end;
        for (begin..limit) |cp| {
            const chunk = geometry.chunkBounds(&s.index, p.source, row, cp);
            var tokens: [hl.max_tokens]hl.Token = undefined;
            const text = p.source[chunk[0]..chunk[1]];
            const n = if (p.lang == .json) hl.jsonRow(p.source, chunk[0], chunk[1], @intCast(cp), geometry.strings.items, &tokens) else hl.tokens(text, p.lang, &tokens);
            var at = chunk[0];
            for (tokens[0..n]) |token| {
                const lo = chunk[0] + token.start;
                const hi = chunk[0] + token.end;
                segment(ui, s, p.source, row, origin, y, at, lo, w.color(c.CUI_TOKEN_FOREGROUND));
                const tint = switch (token.kind) {
                    .key, .tag, .variable => w.design.syntax(ui, .key),
                    .string => w.design.syntax(ui, .string),
                    .number => w.design.syntax(ui, .number),
                    .keyword => w.design.syntax(ui, .keyword),
                    .comment => w.design.syntax(ui, .comment),
                    else => w.color(c.CUI_TOKEN_FOREGROUND),
                };
                segment(ui, s, p.source, row, origin, y, lo, hi, tint);
                at = hi;
            }
            segment(ui, s, p.source, row, origin, y, at, chunk[1], w.color(c.CUI_TOKEN_FOREGROUND));
        }
        if (p.focused and row == active) {
            const x: f32 = @floatCast(origin + geometry.position(&s.index, p.source, row, s.caret, metrics(ui)) - s.precise_x);
            c.cui_draw_line(ui, .{ .x = x, .y = y }, .{ .x = x, .y = y + 17 }, 1.5, w.color(c.CUI_TOKEN_ACCENT));
        }
        c.cui_pop_clip(ui);
        var number: [16]u8 = undefined;
        const label = if (s.index.isContinued(row)) "" else std.fmt.bufPrint(&number, "{d}", .{s.index.lineNumber(row)}) catch "";
        const width = c.cui_measure_text(ui, c.CUI_FONT_MONO, 12, label.ptr, @intCast(label.len)).width;
        c.cui_push_clip(ui, .{ .x = rect.x, .y = rect.y + 8, .w = p.gutter, .h = bars.height });
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 12, .{ .x = rect.x + p.gutter - 10 - width, .y = y + 1 }, w.color(c.CUI_TOKEN_TEXT_MUTED), label.ptr, @intCast(label.len));
        c.cui_pop_clip(ui);
    }
    if (dense) c.cui_draw_text(ui, c.CUI_FONT_BODY, 11, .{ .x = rect.x + p.gutter + gap, .y = rect.y + rect.h - 26 }, w.color(c.CUI_TOKEN_TEXT_SECONDARY), "Preview limited", -1);
    if (bars.max_x > 0) {
        c.cui_draw_rect(ui, bars.horizontal, .{}, w.color(c.CUI_TOKEN_SURFACE));
        c.cui_draw_rect(ui, bars.hthumb, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
    }
    if (bars.max_y > 0) c.cui_draw_rect(ui, bars.vthumb, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
}
fn highlight(ui: *c.cui_ctx, s: *State, source: []const u8, row: usize, origin: f64, y: f32, width: f64) bool {
    if (!s.search_open) return false;
    const index = if (s.search_index) |*value| value else return false;
    const geometry = &s.geometry.?;
    const bounds = s.index.bounds(source, row);
    const left = geometry.byteAt(&s.index, source, row, @max(0, s.precise_x - geometry.config.char_width), metrics(ui));
    const right = @min(bounds[1], code.nextChar(source, geometry.byteAt(&s.index, source, row, s.precise_x + width + geometry.config.char_width, metrics(ui))));
    var hits: [256]@import("../core/response_search.zig").Match = undefined;
    var count: usize = 0;
    const limited = index.visible(source, left, right, &hits, &count);
    var at: usize = 0;
    while (at < count) {
        const lo = @max(bounds[0], hits[at].start);
        var hi = hits[at].end;
        at += 1;
        while (at < count and hits[at].start == hi) : (at += 1) hi = hits[at].end;
        hi = @intCast(@min(hi, bounds[1]));
        const x0 = @max(0, geometry.position(&s.index, source, row, lo, metrics(ui)) - s.precise_x);
        const x1 = @min(width, geometry.position(&s.index, source, row, hi, metrics(ui)) - s.precise_x);
        if (x1 > x0) c.cui_draw_rect(ui, .{ .x = @floatCast(origin + x0), .y = y, .w = @floatCast(x1 - x0), .h = line_h }, .{}, w.tinted(ui, c.CUI_TOKEN_WARNING, 0.18));
    }
    return limited;
}
fn segment(ui: *c.cui_ctx, s: *State, source: []const u8, row: usize, origin: f64, y: f32, lo: usize, hi: usize, tint: c.cui_color) void {
    var at = lo;
    while (at < hi) {
        if (source[at] == '\t' or source[at] == '\r') {
            at += 1;
            continue;
        }
        const stop = at + (std.mem.indexOfAny(u8, source[at..hi], "\t\r") orelse (hi - at));
        const x: f32 = @floatCast(origin + s.geometry.?.position(&s.index, source, row, at, metrics(ui)) - s.precise_x);
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 13, .{ .x = x, .y = y }, tint, source[at..stop].ptr, @intCast(stop - at));
        at = stop;
    }
}
