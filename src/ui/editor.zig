//! Virtualized editor with a row index and bounded undo.
//! Painting visits visible rows; source/wrap changes rebuild the cached index.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const code = @import("code_state.zig");
const hl = @import("../utils/highlight.zig");
const State = code.State;
const design = @import("design.zig");
const Paint = struct { state: *State, source: []const u8, lang: hl.Lang, focused: bool, char_w: f32, gutter: f32 };
const line_h = 20;
// Use the same font advance for text, token origins, hit testing and caret.
pub fn cellWidth(ui: *c.cui_ctx) f32 {
    return c.cui_measure_text(ui, c.CUI_FONT_MONO, 13, "M", 1).width;
}
// The gutter fits the widest line number, so short documents keep code close
// to their numbers and long ones never overlap. Code starts 12px after it.
pub fn gutterWidth(ui: *c.cui_ctx, lines: usize) f32 {
    var digits: f32 = 1;
    var n = lines;
    while (n >= 10) : (n /= 10) digits += 1;
    const digit_w = c.cui_measure_text(ui, c.CUI_FONT_MONO, 12, "0", 1).width;
    return @round(@max(2, digits) * digit_w + 20);
}
const code_gap = 12;

/// Items a view adds to its editor's context menu after the editing commands.
pub const Menu = struct {
    ctx: *anyopaque,
    items: *const fn (ui: *c.cui_ctx, ctx: *anyopaque) void,
};

fn menuItem(ui: *c.cui_ctx, label: [*:0]const u8, shortcut: [*:0]const u8, enabled: bool) bool {
    return c.cui_menu_item_ex(ui, label, &.{ .shortcut = shortcut, .disabled = !enabled });
}

/// The editing commands of a text view's context menu, acting as their
/// shortcuts do. Read-only views offer Copy and Select all.
pub fn editItems(ui: *c.cui_ctx, s: *State, source: []const u8, read_only: bool) void {
    const range = s.selection();
    const selected = range[1] > range[0];
    if (!read_only) {
        if (menuItem(ui, "Undo", "Ctrl Z", s.undo.items.len > 0)) _ = s.undoEdit();
        if (menuItem(ui, "Redo", "Ctrl Y", s.redo.items.len > 0)) _ = s.redoEdit();
        c.cui_menu_separator(ui);
        if (menuItem(ui, "Cut", "Ctrl X", selected)) {
            w.copy(ui, s.selected(source));
            s.replaceSelection("", false);
        }
    }
    if (menuItem(ui, "Copy", "Ctrl C", selected)) w.copy(ui, s.selected(source));
    if (!read_only) {
        if (menuItem(ui, "Paste", "Ctrl V", true)) {
            const clip = c.kest_clipboard(ui);
            if (clip != null) s.replaceSelection(std.mem.span(clip), false);
        }
        if (menuItem(ui, "Delete", "Del", selected)) s.replaceSelection("", false);
    }
    c.cui_menu_separator(ui);
    if (menuItem(ui, "Select all", "Ctrl A", source.len > 0)) {
        _ = s.command(.select_all, source, read_only);
        s.precise_goal = null;
    }
}

/// A right-click focuses the view; outside the selection it also moves the
/// caret there, so the menu acts on what was clicked.
pub fn rightClick(ui: *c.cui_ctx, id: [*:0]const u8, s: *State, at: ?usize) void {
    if (at) |pos| {
        const range = s.selection();
        if (range[0] == range[1] or pos < range[0] or pos > range[1]) s.moveTo(pos, false);
        s.precise_goal = null;
    }
    c.kest_focus(ui, id);
}

/// The context menu of the view `id`, built before the view paints: its
/// commands can replace the text the paint would otherwise still point at.
/// Returns true when an item changed the text or the selection.
pub fn contextMenu(ui: *c.cui_ctx, id: [*:0]const u8, s: *State, source: []const u8, read_only: bool, extra: ?Menu) bool {
    if (!c.kest_context_menu_begin(ui, w.fmt("{s}-menu", .{std.mem.span(id)}), c.cui_make_id(ui, id))) return false;
    const v0 = s.version;
    const caret = s.caret;
    const anchor = s.anchor;
    editItems(ui, s, source, read_only);
    if (extra) |menu| {
        c.cui_menu_separator(ui);
        menu.items(ui, menu.ctx);
    }
    c.cui_context_menu_end(ui);
    const chosen = v0 != s.version or caret != s.caret or anchor != s.anchor;
    if (chosen) {
        s.reveal = true;
        c.kest_focus(ui, id);
    }
    return chosen;
}

pub fn view(ui: *c.cui_ctx, id: [*:0]const u8, s: *State, source_in: []const u8, read_only: bool, lang: hl.Lang) bool {
    return viewMenu(ui, id, s, source_in, read_only, lang, null);
}

pub fn viewMenu(ui: *c.cui_ctx, id: [*:0]const u8, s: *State, source_in: []const u8, read_only: bool, lang: hl.Lang, extra: ?Menu) bool {
    const char_w = cellWidth(ui);
    var source = source_in;
    const v0 = s.version;
    if (s.search_open) search(ui, s, source);
    const identity = c.cui_make_id(ui, id);
    const previous = c.cui_get_rect(ui, identity);
    const gutter0 = gutterWidth(ui, if (s.index.count() > 0) s.index.lineNumber(s.index.count() - 1) else 1);
    const wrap_at: usize = if (s.word_wrap and previous.w > 0) @intFromFloat(@max(4, @floor((previous.w - gutter0 - code_gap - 16) / char_w))) else @import("../utils/lines.zig").default_wrap;
    index(s, source, wrap_at);
    const focused = c.kest_editor_focus(ui, identity) != 0;
    // Escape drops a text drag; the release that follows does nothing.
    if (s.move_drag != .none and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        s.move_drag = .cancelled;
        c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
    }
    if (focused) {
        if (!read_only and c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_M)) s.tab_moves_focus = !s.tab_moves_focus;
        c.kest_editor_tabs(ui, identity, @intFromBool(!read_only and !s.tab_moves_focus));
        keys(ui, s, source, read_only, char_w);
        if (!read_only) source = s.text();
    }
    if (c.kest_right_pressed(ui, identity) and previous.w > 0) {
        index(s, source, wrap_at);
        rightClick(ui, id, s, hit(ui, s, source, previous, gutter0, char_w));
    }
    _ = contextMenu(ui, id, s, source, read_only, extra);
    if (!read_only) source = s.text();
    index(s, source, wrap_at);
    if (s.word_wrap) s.scroll_x = 0;
    if (lang == .json and s.syntax_generation != s.index_generation) {
        if (hl.jsonContinuations(s.gpa, source, s.index.starts.items, &s.continued_strings)) |_| {
            s.syntax_generation = s.index_generation;
        } else |_| s.continued_strings.clearRetainingCapacity();
    }
    if (focused and lang == .json and (!read_only or source.len <= 256 * 1024)) {
        if (s.marked_version != s.version or s.marked_caret != s.caret or s.marked_ptr != @intFromPtr(source.ptr)) {
            s.marked = @import("../utils/brackets.zig").pair(source, s.caret);
            s.marked_version = s.version;
            s.marked_caret = s.caret;
            s.marked_ptr = @intFromPtr(source.ptr);
        }
    } else {
        s.marked = null;
        s.marked_version = 0;
    }
    s.glide.push(s.scroll_y, -c.kest_editor_scroll(ui, identity) * line_h * 3);
    if (s.glide.target != null) {
        const total: f32 = @floatFromInt(s.index.count() * line_h);
        s.glide.step(ui, &s.scroll_y, if (previous.h > 0) total - @max(1, previous.h - 16) else total);
    }
    const gutter = gutterWidth(ui, if (s.index.count() > 0) s.index.lineNumber(s.index.count() - 1) else 1);
    const paint = Paint{ .state = s, .source = source, .lang = lang, .focused = focused, .char_w = char_w, .gutter = gutter };
    const result = c.cui_canvas(ui, id, w.fill, w.fill, draw, &paint, @sizeOf(Paint));
    const rect = result.rect;
    c.kest_editor_register(ui, identity);
    c.kest_editor_tabs(ui, identity, @intFromBool(!read_only and !s.tab_moves_focus));
    if (result.pressed and rect.w > 0) if (hit(ui, s, source, rect, gutter, char_w)) |pos| {
        pointer(ui, s, source, pos, read_only);
    };
    if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT)) {
        switch (s.move_drag) {
            .moving => s.moveSelection(s.drop_at, c.cui_key_mods(ui) & c.CUI_MOD_PRIMARY != 0),
            // A click inside the selection that never moved places the caret.
            .pending => s.moveTo(s.drop_at, false),
            .none, .cancelled => {},
        }
        s.move_drag = .none;
        s.selecting = false;
    }
    return v0 != s.version;
}

/// The left button is down over the text at `pos`. A press starts a
/// selection, by words or lines after a double or triple click; a press
/// inside the selection may instead drag it somewhere else.
fn pointer(ui: *c.cui_ctx, s: *State, source: []const u8, pos: usize, read_only: bool) void {
    const mouse = c.cui_mouse_pos(ui);
    if (!s.selecting and s.move_drag == .none) {
        const range = s.selection();
        const clicks = c.kest_click_count(ui);
        const shift = c.cui_key_mods(ui) & c.CUI_MOD_SHIFT != 0;
        if (!read_only and clicks <= 1 and !shift and range[1] > range[0] and pos >= range[0] and pos < range[1]) {
            s.move_drag = .pending;
            s.press_x = mouse.x;
            s.press_y = mouse.y;
            s.drop_at = pos;
            return;
        }
        s.pressAt(source, pos, clicks, shift);
        s.selecting = true;
        return;
    }
    switch (s.move_drag) {
        .pending => {
            s.drop_at = pos;
            const dx = mouse.x - s.press_x;
            const dy = mouse.y - s.press_y;
            if (dx * dx + dy * dy > 16) s.move_drag = .moving;
        },
        .moving => s.drop_at = pos,
        .cancelled => {},
        .none => s.dragTo(source, pos),
    }
}

/// The byte under the mouse in the editor's rectangle.
fn hit(ui: *c.cui_ctx, s: *State, source: []const u8, rect: c.cui_rect, gutter: f32, char_w: f32) ?usize {
    if (s.index.count() == 0) return null;
    const m = c.cui_mouse_pos(ui);
    const row_n: usize = @intFromFloat(@max(0, @floor((m.y - rect.y - 8 + s.scroll_y) / line_h)));
    const row_at = @min(row_n, s.index.count() - 1);
    const bounds = s.index.bounds(source, row_at);
    return bounds[0] + byteAt(ui, source[bounds[0]..bounds[1]], @max(0, m.x - rect.x - gutter - code_gap + s.scroll_x), char_w);
}

fn index(s: *State, source: []const u8, wrap_at: usize) void {
    if (s.indexed_version == s.version and s.indexed_ptr == @intFromPtr(source.ptr) and s.indexed_len == source.len and s.index.wrap_at == wrap_at and s.index.prefer_words == s.word_wrap) return;
    s.index.wrap_at = wrap_at;
    s.index.prefer_words = s.word_wrap;
    s.index.build(s.gpa, source) catch {
        s.indexed_version = 0;
        return;
    };
    s.indexed_version = s.version;
    s.indexed_ptr = @intFromPtr(source.ptr);
    s.indexed_len = source.len;
    s.index_generation +%= 1;
    s.reveal = true;
}

fn keys(ui: *c.cui_ctx, s: *State, source_in: []const u8, read_only: bool, char_w: f32) void {
    var source = source_in;
    const mods = c.cui_key_mods(ui);
    const shift = mods & c.CUI_MOD_SHIFT != 0;
    const ctrl = mods & c.CUI_MOD_PRIMARY != 0;
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_A)) _ = s.command(.select_all, source, read_only);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_C)) w.copy(ui, s.selected(source));
    if (!read_only) {
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_X)) {
            w.copy(ui, s.selected(source));
            s.replaceSelection("", false);
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_V)) {
            const clip = c.kest_clipboard(ui);
            if (clip != null) s.replaceSelection(std.mem.span(clip), false);
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_Z)) _ = s.undoEdit();
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_Y) or c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_Z)) _ = s.redoEdit();
        const entered = c.kest_editor_text(ui);
        if (!ctrl and entered != null and entered[0] != 0) s.replaceSelection(std.mem.span(entered), true);
        // Paste/undo/typing may reallocate the buffer before navigation runs.
        source = s.text();
    }
    if (c.cui_key_pressed(ui, c.CUI_KEY_LEFT)) _ = s.command(if (ctrl) (if (shift) .select_word_left else .move_word_left) else (if (shift) .select_left else .move_left), source, read_only);
    if (c.cui_key_pressed(ui, c.CUI_KEY_RIGHT)) _ = s.command(if (ctrl) (if (shift) .select_word_right else .move_word_right) else (if (shift) .select_right else .move_right), source, read_only);
    if (c.cui_key_pressed(ui, c.CUI_KEY_HOME)) s.moveTo(if (ctrl) 0 else code.lineStart(source, s.caret), shift);
    if (c.cui_key_pressed(ui, c.CUI_KEY_END)) s.moveTo(if (ctrl) source.len else code.lineEnd(source, s.caret), shift);
    if (c.cui_key_pressed(ui, c.CUI_KEY_UP) or c.cui_key_pressed(ui, c.CUI_KEY_DOWN)) {
        index(s, source, s.index.wrap_at);
        if (s.index.count() > 0) {
            const row = s.index.rowOf(s.caret);
            const bounds = s.index.bounds(source, row);
            const aim = s.goal_x orelse advance(ui, source[bounds[0]..@min(s.caret, bounds[1])], char_w);
            const target = if (c.cui_key_pressed(ui, c.CUI_KEY_UP)) row -| 1 else @min(row + 1, s.index.count() - 1);
            if (target != row) {
                const next = s.index.bounds(source, target);
                s.moveTo(next[0] + byteAt(ui, source[next[0]..next[1]], aim, char_w), shift);
            }
            s.goal_x = aim;
        }
    }
    if (!read_only) {
        if (c.cui_key_pressed(ui, c.CUI_KEY_BACKSPACE)) _ = s.command(if (ctrl) .delete_word_backward else .delete_backward, s.text(), false);
        if (c.cui_key_pressed(ui, c.CUI_KEY_DELETE)) _ = s.command(if (ctrl) .delete_word_forward else .delete_forward, s.text(), false);
        if (!ctrl and c.cui_key_pressed(ui, c.CUI_KEY_ENTER)) s.newline(s.text(), @min(s.caret, s.text().len));
        if (!ctrl and !s.tab_moves_focus and c.cui_key_pressed(ui, c.CUI_KEY_TAB)) s.indent(shift);
        if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) c.kest_focus(ui, "###body-kind");
    }
}

pub fn search(ui: *c.cui_ctx, s: *State, source: []const u8) void {
    w.row(ui, .{ .gap = 6, .pad_x = 8, .pad_y = 6, .width = w.fill });
    defer w.end(ui);
    if (w.field(ui, "find", &s.query, .{ .placeholder = "Find in document", .width = w.fill, .size = c.CUI_SIZE_SM })) s.research(source);
    s.refreshSearch(source);
    w.muted(ui, w.fmt("{d}{s}", .{ s.matches.items.len, if (s.matches_truncated) "+" else "" }));
    if (w.icon(ui, c.CUI_ICON_CHEVRON_UP, "Previous match")) s.gotoMatch(-1);
    if (w.icon(ui, c.CUI_ICON_CHEVRON_DOWN, "Next match")) s.gotoMatch(1);
    if (w.icon(ui, c.CUI_ICON_X, "Close search")) s.search_open = false;
}

fn draw(ui_opt: ?*c.cui_ctx, rect: c.cui_rect, raw: ?*anyopaque) callconv(.c) void {
    const ui = ui_opt.?;
    const p: *const Paint = @ptrCast(@alignCast(raw.?));
    const s = p.state;
    const char_w = p.char_w;
    const gutter = p.gutter;
    if (s.index.count() == 0) return;
    const visible: f32 = @max(1, rect.h - 16);
    const total: f32 = @floatFromInt(s.index.count() * line_h);
    s.scroll_y = std.math.clamp(s.scroll_y, 0, @max(0, total - visible));
    if (s.reveal) {
        s.glide.stop();
        const caret_row: f32 = @floatFromInt(s.index.rowOf(@min(s.caret, p.source.len)) * line_h);
        if (caret_row < s.scroll_y) s.scroll_y = caret_row;
        if (caret_row + line_h > s.scroll_y + visible) s.scroll_y = caret_row + line_h - visible;
        const row_i = s.index.rowOf(@min(s.caret, p.source.len));
        const cb = s.index.bounds(p.source, row_i);
        const caret_col = advance(ui, p.source[cb[0]..@min(s.caret, cb[1])], char_w);
        if (caret_col < s.scroll_x) s.scroll_x = caret_col;
        if (!s.word_wrap and caret_col > s.scroll_x + @max(20, rect.w - gutter - code_gap - 16)) s.scroll_x = caret_col - @max(20, rect.w - gutter - code_gap - 16);
        s.reveal = false;
    }
    c.cui_push_clip(ui, rect);
    defer c.cui_pop_clip(ui);
    c.cui_draw_rect(ui, rect, .{}, w.color(c.CUI_TOKEN_SURFACE));
    c.cui_draw_rect(ui, .{ .x = rect.x, .y = rect.y, .w = gutter, .h = rect.h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
    c.cui_draw_line(ui, .{ .x = rect.x + gutter, .y = rect.y }, .{ .x = rect.x + gutter, .y = rect.y + rect.h }, 1 / @max(1, c.cui_dpi_scale(ui)), w.color(c.CUI_TOKEN_BORDER_SUBTLE));
    if (p.focused) c.cui_draw_line(ui, .{ .x = rect.x, .y = rect.y + 0.5 }, .{ .x = rect.x + rect.w, .y = rect.y + 0.5 }, 1 / @max(1, c.cui_dpi_scale(ui)), w.color(c.CUI_TOKEN_FOCUS_RING));
    const first: usize = @intFromFloat(@floor(s.scroll_y / line_h));
    const count: usize = @intFromFloat(@ceil(visible / line_h) + 2);
    const last = @min(s.index.count(), first + count);
    const sel = s.selection();
    const active_row = s.index.rowOf(@min(s.caret, p.source.len));
    for (first..last) |i| {
        const bounds = s.index.bounds(p.source, i);
        const entire_row = s.index.row(p.source, i);
        const col_lo = byteAt(ui, entire_row, @max(0, s.scroll_x - char_w), char_w);
        const col_hi = code.nextChar(entire_row, byteAt(ui, entire_row, s.scroll_x + @max(1, rect.w - gutter - code_gap) + char_w, char_w));
        const y = rect.y + 8 + @as(f32, @floatFromInt(i * line_h)) - s.scroll_y;
        const x = rect.x + gutter + code_gap - s.scroll_x;
        if (p.focused and active_row == i) c.cui_draw_rect(ui, .{ .x = rect.x + gutter + 1, .y = y, .w = @max(0, rect.w - gutter - 1), .h = line_h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
        if (s.marked) |pair| for (pair) |pos| {
            if (pos >= bounds[0] and pos < bounds[1]) {
                const mark_x = advance(ui, entire_row[0 .. pos - bounds[0]], char_w);
                c.cui_draw_rect(ui, .{ .x = x + mark_x, .y = y, .w = char_w, .h = line_h }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
            }
        };
        if (sel[1] > bounds[0] and sel[0] < bounds[1]) {
            const lo = @max(sel[0], bounds[0]) - bounds[0];
            const hi = @min(sel[1], bounds[1]) - bounds[0];
            const selection_x = advance(ui, entire_row[0..lo], char_w);
            const selection_end = advance(ui, entire_row[0..hi], char_w);
            c.cui_draw_rect(ui, .{ .x = x + selection_x, .y = y, .w = selection_end - selection_x, .h = line_h }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
        }
        var number: [16]u8 = undefined;
        const label = if (s.index.isContinued(i)) "" else std.fmt.bufPrint(&number, "{d}", .{s.index.lineNumber(i)}) catch "";
        const label_w = c.cui_measure_text(ui, c.CUI_FONT_MONO, 12, label.ptr, @intCast(label.len)).width;
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 12, .{ .x = rect.x + gutter - 10 - label_w, .y = y + 1 }, w.color(if (p.focused and active_row == i) c.CUI_TOKEN_TEXT_SECONDARY else c.CUI_TOKEN_TEXT_MUTED), label.ptr, @intCast(label.len));
        var tokens: [hl.max_tokens]hl.Token = undefined;
        const n = if (p.lang == .json) hl.jsonRow(p.source, bounds[0], bounds[1], @intCast(i), s.continued_strings.items, &tokens) else hl.tokens(entire_row, p.lang, &tokens);
        var at = col_lo;
        for (tokens[0..n]) |tok| {
            if (tok.end <= col_lo or tok.start >= col_hi) continue;
            const token_start = @max(col_lo, tok.start);
            const token_end = @min(col_hi, tok.end);
            segment(ui, char_w, x, y, entire_row, at, token_start, w.color(c.CUI_TOKEN_FOREGROUND));
            const token_color: c.cui_color = switch (tok.kind) {
                .key, .tag, .variable => design.syntax(ui, .key),
                .string => design.syntax(ui, .string),
                .number => design.syntax(ui, .number),
                .keyword => design.syntax(ui, .keyword),
                .comment => design.syntax(ui, .comment),
                else => w.color(c.CUI_TOKEN_FOREGROUND),
            };
            segment(ui, char_w, x, y, entire_row, token_start, token_end, token_color);
            at = token_end;
        }
        segment(ui, char_w, x, y, entire_row, at, col_hi, w.color(c.CUI_TOKEN_FOREGROUND));
        if (s.move_drag == .moving and (s.drop_at < s.selection()[0] or s.drop_at > s.selection()[1]) and s.drop_at >= bounds[0] and s.drop_at <= bounds[1] and (s.drop_at < bounds[1] or i + 1 == s.index.count() or s.index.bounds(p.source, i + 1)[0] > s.drop_at)) {
            const drop_x = x + advance(ui, entire_row[0..@min(s.drop_at - bounds[0], entire_row.len)], char_w);
            c.cui_draw_line(ui, .{ .x = drop_x, .y = y }, .{ .x = drop_x, .y = y + 17 }, 2, w.color(c.CUI_TOKEN_TEXT_SECONDARY));
        }
        if (p.focused and i == active_row) {
            const caret_x = x + advance(ui, entire_row[0..@min(s.caret -| bounds[0], entire_row.len)], char_w);
            c.cui_draw_line(ui, .{ .x = caret_x, .y = y }, .{ .x = caret_x, .y = y + 17 }, 1.5, w.color(c.CUI_TOKEN_ACCENT));
        }
    }
    if (total > visible) {
        const thumb = @max(20, visible * visible / total);
        c.cui_draw_rect(ui, .{ .x = rect.x + rect.w - 5, .y = rect.y + 8 + s.scroll_y / (total - visible) * (visible - thumb), .w = 3, .h = thumb }, .{ .tl = 2, .tr = 2, .br = 2, .bl = 2 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
    }
}

fn segment(ui: *c.cui_ctx, char_w: f32, x: f32, y: f32, source: []const u8, lo: usize, hi: usize, tint: c.cui_color) void {
    if (lo >= hi) return;
    var at = lo;
    while (at < hi) {
        if (source[at] == '\t' or source[at] == '\r') {
            at += 1;
            continue;
        }
        const end = std.mem.indexOfAnyPos(u8, source, at, "\t\r") orelse hi;
        const stop = @min(hi, end);
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 13, .{ .x = x + advance(ui, source[0..at], char_w), .y = y }, tint, source[at..stop].ptr, @intCast(stop - at));
        at = stop;
    }
}

/// Shared native text advances keep painting, selection and hit testing aligned
/// for UTF-8/fallback fonts. Tabs use two-space stops; CR in CRLF is invisible.
pub fn advance(ui: *c.cui_ctx, source: []const u8, char_w: f32) f32 {
    if (plainAscii(source)) return @as(f32, @floatFromInt(source.len)) * char_w;
    var at: usize = 0;
    var width: f32 = 0;
    while (at < source.len) {
        const stop = std.mem.indexOfAnyPos(u8, source, at, "\t\r") orelse source.len;
        if (stop > at) width += c.cui_measure_text(ui, c.CUI_FONT_MONO, 13, source[at..stop].ptr, @intCast(stop - at)).width;
        if (stop == source.len) break;
        if (source[stop] == '\t') width = (@floor(width / (char_w * 2)) + 1) * char_w * 2;
        at = stop + 1;
    }
    return width;
}

pub fn byteAt(ui: *c.cui_ctx, source: []const u8, target: f32, char_w: f32) usize {
    if (plainAscii(source)) return @min(source.len, @as(usize, @intFromFloat(@max(0, @round(target / char_w)))));
    var lo: usize = 0;
    var hi = source.len;
    while (hi > lo) {
        var mid = lo + (hi - lo) / 2;
        while (mid > lo and mid < source.len and source[mid] & 0xc0 == 0x80) mid -= 1;
        const next = code.nextChar(source, mid);
        const left = advance(ui, source[0..mid], char_w);
        const right = advance(ui, source[0..next], char_w);
        if (target < (left + right) / 2) hi = mid else lo = next;
    }
    return lo;
}

fn plainAscii(source: []const u8) bool {
    for (source) |byte| if (byte >= 0x80 or byte == '\t' or byte == '\r') return false;
    return true;
}
