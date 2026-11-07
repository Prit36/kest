//! Virtualized editor with a row index and bounded undo.
//! The canvas paints only visible rows, never reflows the entire document.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const code = @import("code_state.zig");
const hl = @import("../utils/highlight.zig");
const State = code.State;
const design = @import("design.zig");
const Paint = struct { state: *State, source: []const u8, lang: hl.Lang, focused: bool };
const line_h = 20;
const char_w: f32 = 7.8;

pub fn view(ui: *c.cui_ctx, id: [*:0]const u8, s: *State, source_in: []const u8, read_only: bool, lang: hl.Lang) bool {
    var source = source_in;
    const v0 = s.version;
    if (s.search_open) search(ui, s, source);
    const identity = c.cui_make_id(ui, id);
    const focused = c.kest_editor_focus(ui, identity) != 0;
    if (focused) {
        keys(ui, s, source, read_only);
        if (!read_only) source = s.text();
    }
    if (s.indexed_version != s.version or s.indexed_ptr != @intFromPtr(source.ptr) or s.indexed_len != source.len) {
        s.index.build(s.gpa, source) catch {};
        s.indexed_version = s.version;
        s.indexed_ptr = @intFromPtr(source.ptr);
        s.indexed_len = source.len;
    }
    s.scroll_y = @max(0, s.scroll_y - c.kest_editor_scroll(ui, identity) * line_h * 3);
    const paint = Paint{ .state = s, .source = source, .lang = lang, .focused = focused };
    const result = c.cui_canvas(ui, id, w.fill, w.fill, draw, &paint, @sizeOf(Paint));
    c.kest_editor_register(ui, identity);
    const rect = result.rect;
    if (result.pressed and rect.w > 0) {
        const m = c.cui_mouse_pos(ui);
        const row_n: usize = @intFromFloat(@max(0, @floor((m.y - rect.y - 8 + s.scroll_y) / line_h)));
        if (s.index.count() > 0) {
            const row_at = @min(row_n, s.index.count() - 1);
            const bounds = s.index.bounds(source, row_at);
            const col: usize = @intFromFloat(@max(0, @round((m.x - rect.x - 56 + s.scroll_x) / char_w)));
            var pos = @min(bounds[0] + col, bounds[1]);
            while (pos > bounds[0] and pos < source.len and source[pos] & 0xc0 == 0x80) pos -= 1;
            s.moveTo(pos, c.cui_key_mods(ui) & c.CUI_MOD_SHIFT != 0 or s.selecting);
            s.selecting = true;
        }
    }
    if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT)) s.selecting = false;
    return v0 != s.version;
}

fn keys(ui: *c.cui_ctx, s: *State, source_in: []const u8, read_only: bool) void {
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
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_V) and !@import("platform.zig").headless) {
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
        const start = code.lineStart(source, s.caret);
        const col = s.caret - start;
        const next_start = if (c.cui_key_pressed(ui, c.CUI_KEY_UP)) code.lineStart(source, start -| 1) else @min(source.len, code.lineEnd(source, s.caret) + 1);
        s.moveTo(@min(next_start + col, code.lineEnd(source, next_start)), shift);
    }
    if (!read_only) {
        if (c.cui_key_pressed(ui, c.CUI_KEY_BACKSPACE)) _ = s.command(if (ctrl) .delete_word_backward else .delete_backward, s.text(), false);
        if (c.cui_key_pressed(ui, c.CUI_KEY_DELETE)) _ = s.command(if (ctrl) .delete_word_forward else .delete_forward, s.text(), false);
        if (!ctrl and c.cui_key_pressed(ui, c.CUI_KEY_ENTER)) s.newline(s.text(), @min(s.caret, s.text().len));
    }
}

fn search(ui: *c.cui_ctx, s: *State, source: []const u8) void {
    w.row(ui, .{ .gap = 6, .pad_x = 8 });
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
    if (s.index.count() == 0) return;
    const visible: f32 = @max(1, rect.h - 16);
    const total: f32 = @floatFromInt(s.index.count() * line_h);
    s.scroll_y = std.math.clamp(s.scroll_y, 0, @max(0, total - visible));
    if (s.reveal) {
        const caret_row: f32 = @floatFromInt(s.index.rowOf(@min(s.caret, p.source.len)) * line_h);
        if (caret_row < s.scroll_y) s.scroll_y = caret_row;
        if (caret_row + line_h > s.scroll_y + visible) s.scroll_y = caret_row + line_h - visible;
        const row_i = s.index.rowOf(@min(s.caret, p.source.len));
        const caret_col: f32 = @as(f32, @floatFromInt(s.caret -| s.index.bounds(p.source, row_i)[0])) * char_w;
        if (caret_col < s.scroll_x) s.scroll_x = caret_col;
        if (caret_col > s.scroll_x + @max(20, rect.w - 72)) s.scroll_x = caret_col - @max(20, rect.w - 72);
        s.reveal = false;
    }
    c.cui_push_clip(ui, rect);
    defer c.cui_pop_clip(ui);
    c.cui_draw_rect(ui, rect, .{}, w.color(c.CUI_TOKEN_SURFACE));
    c.cui_draw_rect(ui, .{ .x = rect.x, .y = rect.y, .w = 44, .h = rect.h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
    c.cui_draw_line(ui, .{ .x = rect.x + 44, .y = rect.y }, .{ .x = rect.x + 44, .y = rect.y + rect.h }, 1, w.color(c.CUI_TOKEN_BORDER_SUBTLE));
    const first: usize = @intFromFloat(@floor(s.scroll_y / line_h));
    const count: usize = @intFromFloat(@ceil(visible / line_h) + 2);
    const last = @min(s.index.count(), first + count);
    const sel = s.selection();
    const active_row = s.index.rowOf(@min(s.caret, p.source.len));
    for (first..last) |i| {
        const bounds = s.index.bounds(p.source, i);
        const entire_row = s.index.row(p.source, i);
        var col_lo = @min(entire_row.len, @as(usize, @intFromFloat(@floor(s.scroll_x / char_w))));
        while (col_lo > 0 and col_lo < entire_row.len and entire_row[col_lo] & 0xc0 == 0x80) col_lo -= 1;
        const visible_cols: usize = @intFromFloat(@ceil(@max(1, rect.w - 56) / char_w) + 2);
        var col_hi = @min(entire_row.len, col_lo + visible_cols);
        while (col_hi > col_lo and col_hi < entire_row.len and entire_row[col_hi] & 0xc0 == 0x80) col_hi -= 1;
        const row_text = entire_row[col_lo..col_hi];
        const y = rect.y + 8 + @as(f32, @floatFromInt(i * line_h)) - s.scroll_y;
        const x = rect.x + 56 - s.scroll_x;
        const text_x = x + @as(f32, @floatFromInt(col_lo)) * char_w;
        if (p.focused and active_row == i) c.cui_draw_rect(ui, .{ .x = rect.x + 45, .y = y, .w = @max(0, rect.w - 45), .h = line_h }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
        if (sel[1] > bounds[0] and sel[0] < bounds[1]) {
            const lo = @max(sel[0], bounds[0]) - bounds[0];
            const hi = @min(sel[1], bounds[1]) - bounds[0];
            c.cui_draw_rect(ui, .{ .x = x + @as(f32, @floatFromInt(lo)) * char_w, .y = y, .w = @as(f32, @floatFromInt(hi - lo)) * char_w, .h = line_h }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
        }
        var number: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&number, "{d}", .{s.index.lineNumber(i)}) catch "";
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 12, .{ .x = rect.x + 10, .y = y + 1 }, w.color(c.CUI_TOKEN_TEXT_MUTED), label.ptr, @intCast(label.len));
        var tokens: [hl.max_tokens]hl.Token = undefined;
        const n = hl.tokens(row_text, p.lang, &tokens);
        var at: usize = 0;
        for (tokens[0..n]) |tok| {
            segment(ui, text_x, y, row_text, at, tok.start, w.color(c.CUI_TOKEN_FOREGROUND));
            const token_color: c.cui_color = switch (tok.kind) {
                .key, .tag, .variable => design.syntax(ui, .key),
                .string => design.syntax(ui, .string),
                .number => design.syntax(ui, .number),
                .keyword => design.syntax(ui, .keyword),
                .comment => design.syntax(ui, .comment),
                else => w.color(c.CUI_TOKEN_FOREGROUND),
            };
            segment(ui, text_x, y, row_text, tok.start, tok.end, token_color);
            at = tok.end;
        }
        segment(ui, text_x, y, row_text, at, row_text.len, w.color(c.CUI_TOKEN_FOREGROUND));
        if (p.focused and s.caret >= bounds[0] and s.caret <= bounds[1]) {
            const caret_x = x + @as(f32, @floatFromInt(s.caret - bounds[0])) * char_w;
            c.cui_draw_line(ui, .{ .x = caret_x, .y = y }, .{ .x = caret_x, .y = y + 17 }, 1.5, w.color(c.CUI_TOKEN_ACCENT));
        }
    }
    if (total > visible) {
        const thumb = @max(20, visible * visible / total);
        c.cui_draw_rect(ui, .{ .x = rect.x + rect.w - 5, .y = rect.y + 8 + s.scroll_y / (total - visible) * (visible - thumb), .w = 3, .h = thumb }, .{ .tl = 2, .tr = 2, .br = 2, .bl = 2 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
    }
}

fn segment(ui: *c.cui_ctx, x: f32, y: f32, source: []const u8, lo: usize, hi: usize, tint: c.cui_color) void {
    if (lo >= hi) return;
    c.cui_draw_text(ui, c.CUI_FONT_MONO, 13, .{ .x = x + @as(f32, @floatFromInt(lo)) * char_w, .y = y }, tint, source[lo..hi].ptr, @intCast(hi - lo));
}
