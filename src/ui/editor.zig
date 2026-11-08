//! Virtualized editor with a row index and bounded undo.
//! Painting visits visible rows; source/wrap changes rebuild the cached index.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const code = @import("code_state.zig");
const hl = @import("../utils/highlight.zig");
const State = code.State;
const design = @import("design.zig");
const Paint = struct { state: *State, source: []const u8, lang: hl.Lang, focused: bool, char_w: f32, gutter: f32, fold_w: f32 };
const font = @import("code_font.zig");
const suggest = @import("suggest.zig");
// Use the same font advance for text, token origins, hit testing and caret.
pub fn cellWidth(ui: *c.cui_ctx) f32 {
    return c.cui_measure_text(ui, c.CUI_FONT_MONO, font.size, "M", 1).width;
}
// The gutter fits the widest line number, so short documents keep code close
// to their numbers and long ones never overlap. Code starts 12px after it.
pub fn gutterWidth(ui: *c.cui_ctx, lines: usize) f32 {
    var digits: f32 = 1;
    var n = lines;
    while (n >= 10) : (n /= 10) digits += 1;
    const digit_w = c.cui_measure_text(ui, c.CUI_FONT_MONO, font.small(), "0", 1).width;
    return @round(@max(2, digits) * digit_w + 20);
}
const code_gap = 12;
/// Room at the gutter's left for fold arrows, in a JSON editor.
const fold_column = 14;

fn foldWidth(lang: hl.Lang, read_only: bool) f32 {
    return if (lang == .json and !read_only) fold_column else 0;
}

/// Folds or unfolds the region at the caret (Ctrl+Shift+-). Folding over
/// the caret moves it to the region's first line.
pub fn toggleFoldAtCaret(s: *State) void {
    const r = s.folds.regionAround(&s.index, s.caret) orelse return;
    s.folds.toggle(s.gpa, r.open);
    keepCaretShown(s);
}

/// After folding: a caret inside a fold moves to the fold's first line,
/// so it isn't unfolded again straight away.
pub fn keepCaretShown(s: *State) void {
    const row = s.index.rowOf(@min(s.caret, s.text().len));
    for (s.folds.regions.items) |r| {
        if (s.folds.isFolded(r.open) and row > r.open_row and row < r.close_row) {
            s.moveTo(r.open + 1, false);
            return;
        }
    }
}

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
    if (s.multi()) return multiItems(ui, s, source, read_only);
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
    }
    // Delete lives in the Edit menu and on the key; the context menu keeps
    // to the commands people reach for with the mouse.
    if (menuItem(ui, "Select all", "Ctrl A", source.len > 0)) {
        _ = s.command(.select_all, source, read_only);
        s.precise_goal = null;
    }
}

/// What the app's Edit menu knows about the editor focused last; the
/// editor refreshes it every frame it has focus.
pub const Target = struct { id: c.cui_id, read_only: bool, selected: bool, can_undo: bool, can_redo: bool, length: usize, multi: bool };
pub var edit_target: ?Target = null;
/// A command chosen from the Edit menu, run by that editor on its next frame.
var pending: ?struct { id: c.cui_id, command: c_int } = null;

/// The Edit menu's items for `t`; a choice runs on the editor's next frame.
pub fn targetItems(ui: *c.cui_ctx, t: Target) void {
    const items = [_]struct { label: [*:0]const u8, shortcut: [*:0]const u8, command: c_int, enabled: bool, writes: bool }{
        .{ .label = "Undo", .shortcut = "Ctrl Z", .command = c.KEST_EDIT_UNDO, .enabled = t.can_undo, .writes = true },
        .{ .label = "Redo", .shortcut = "Ctrl Y", .command = c.KEST_EDIT_REDO, .enabled = t.can_redo and !t.multi, .writes = true },
        .{ .label = "", .shortcut = "", .command = 0, .enabled = false, .writes = true },
        .{ .label = "Cut", .shortcut = "Ctrl X", .command = c.KEST_EDIT_CUT, .enabled = t.selected or t.multi, .writes = true },
        .{ .label = "Copy", .shortcut = "Ctrl C", .command = c.KEST_EDIT_COPY, .enabled = t.selected or t.multi, .writes = false },
        .{ .label = "Paste", .shortcut = "Ctrl V", .command = c.KEST_EDIT_PASTE, .enabled = true, .writes = true },
        .{ .label = "Delete", .shortcut = "Del", .command = c.KEST_EDIT_DELETE, .enabled = t.selected and !t.multi, .writes = true },
        .{ .label = "", .shortcut = "", .command = 0, .enabled = false, .writes = false },
        .{ .label = "Select all", .shortcut = "Ctrl A", .command = c.KEST_EDIT_SELECT_ALL, .enabled = t.length > 0 and !t.multi, .writes = false },
    };
    for (items) |item| {
        if (t.read_only and item.writes) continue;
        if (item.command == 0) {
            c.cui_menu_separator(ui);
            continue;
        }
        if (menuItem(ui, item.label, item.shortcut, item.enabled)) pending = .{ .id = t.id, .command = item.command };
    }
}

/// Runs an Edit menu command as its shortcut would.
fn run(ui: *c.cui_ctx, s: *State, source: []const u8, read_only: bool, command: c_int) void {
    const range = s.selection();
    const selected = range[1] > range[0];
    switch (command) {
        c.KEST_EDIT_UNDO => if (!read_only) {
            _ = s.undoEdit();
        },
        c.KEST_EDIT_REDO => if (!read_only and !s.multi()) {
            _ = s.redoEdit();
        },
        c.KEST_EDIT_CUT, c.KEST_EDIT_COPY => {
            if (s.multi()) {
                if (s.copyAll(w.arena.allocator(), source)) |joined| w.copy(ui, joined) else |_| {}
                if (command == c.KEST_EDIT_CUT and !read_only) s.editAll(.{ .insert = "" });
            } else if (selected) {
                w.copy(ui, s.selected(source));
                if (command == c.KEST_EDIT_CUT and !read_only) s.replaceSelection("", false);
            }
        },
        c.KEST_EDIT_PASTE => if (!read_only) {
            const clip = c.kest_clipboard(ui);
            if (clip != null) {
                if (s.multi()) pasteAll(s, std.mem.span(clip)) else s.replaceSelection(std.mem.span(clip), false);
            }
        },
        c.KEST_EDIT_DELETE => if (!read_only and selected) s.replaceSelection("", false),
        c.KEST_EDIT_SELECT_ALL => {
            _ = s.command(.select_all, source, read_only);
            s.precise_goal = null;
        },
        else => {},
    }
    s.reveal = true;
}

/// The editing commands with several carets: each acts at every one.
fn multiItems(ui: *c.cui_ctx, s: *State, source: []const u8, read_only: bool) void {
    if (!read_only) {
        if (menuItem(ui, "Undo", "Ctrl Z", s.undo.items.len > 0)) _ = s.undoEdit();
        c.cui_menu_separator(ui);
        if (menuItem(ui, "Cut", "Ctrl X", true)) {
            if (s.copyAll(w.arena.allocator(), source)) |joined| w.copy(ui, joined) else |_| {}
            s.editAll(.{ .insert = "" });
        }
    }
    if (menuItem(ui, "Copy", "Ctrl C", true)) {
        if (s.copyAll(w.arena.allocator(), source)) |joined| w.copy(ui, joined) else |_| {}
    }
    if (!read_only and menuItem(ui, "Paste", "Ctrl V", true)) {
        const clip = c.kest_clipboard(ui);
        if (clip != null) pasteAll(s, std.mem.span(clip));
    }
    c.cui_menu_separator(ui);
    if (menuItem(ui, w.fmt("Keep one caret ({d} now)", .{s.extra.items.len + 1}), "Esc", true)) s.collapse();
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
    if (!read_only and s.folds.regions.items.len > 0) {
        if (extra == null) c.cui_menu_separator(ui);
        if (w.submenu(ui, "Folding", null)) {
            const here = s.folds.regionAround(&s.index, s.caret);
            const folded_here = if (here) |r| s.folds.isFolded(r.open) else false;
            if (menuItem(ui, if (folded_here) "Unfold" else "Fold", "Ctrl Shift -", here != null)) toggleFoldAtCaret(s);
            if (menuItem(ui, "Fold all", "", true)) {
                s.folds.foldAll(s.gpa);
                keepCaretShown(s);
            }
            if (menuItem(ui, "Unfold all", "", s.folds.anyFolded())) s.folds.unfoldAll();
            w.submenuEnd(ui);
        }
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
    if (s.search_open) {
        search(ui, id, s, source, read_only);
        if (!read_only) source = s.text();
    }
    const identity = c.cui_make_id(ui, id);
    const previous = c.cui_get_rect(ui, identity);
    const fold_w = foldWidth(lang, read_only);
    const gutter0 = fold_w + gutterWidth(ui, if (s.index.count() > 0) s.index.lineNumber(s.index.count() - 1) else 1);
    const wrap_at: usize = if (s.word_wrap and previous.w > 0) @intFromFloat(@max(4, @floor((previous.w - gutter0 - code_gap - 16) / char_w))) else @import("../utils/lines.zig").default_wrap;
    index(s, source, wrap_at);
    if (pending) |p| if (p.id == identity) {
        pending = null;
        run(ui, s, source, read_only, p.command);
        if (!read_only) source = s.text();
        c.kest_focus(ui, id);
    };
    const focused = c.kest_editor_focus(ui, identity) != 0;
    if (focused) {
        const range = s.selection();
        c.kest_edit_target = identity;
        edit_target = .{ .id = identity, .read_only = read_only, .selected = range[1] > range[0], .can_undo = s.undo.items.len > 0, .can_redo = s.redo.items.len > 0, .length = source.len, .multi = s.multi() };
    }
    // Escape drops a text drag; the release that follows does nothing.
    if (s.move_drag != .none and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        s.move_drag = .cancelled;
        c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
    }
    if (focused) {
        if (!read_only and c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_M)) s.tab_moves_focus = !s.tab_moves_focus;
        c.kest_editor_tabs(ui, identity, @intFromBool(!read_only and !s.tab_moves_focus));
        keys(ui, s, source, read_only, char_w);
        if (fold_w > 0 and c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_MINUS)) toggleFoldAtCaret(s);
        if (!read_only) source = s.text();
    }
    if (c.kest_right_pressed(ui, identity) and previous.w > 0) {
        index(s, source, wrap_at);
        rightClick(ui, id, s, hit(ui, s, source, previous, gutter0, char_w));
    }
    _ = contextMenu(ui, id, s, source, read_only, extra);
    if (!read_only) source = s.text();
    index(s, source, wrap_at);
    if (fold_w > 0) {
        s.folds.update(s.gpa, source, &s.index, s.index_generation);
        // The caret went somewhere folded: open what hides it.
        if (s.folds.anyFolded() and s.folds.reveal(s.index.rowOf(@min(s.caret, source.len)))) s.folds.update(s.gpa, source, &s.index, s.index_generation);
    } else if (s.folds.regions.items.len > 0 or s.folds.anyFolded()) s.folds.clear();
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
    const wheel = c.kest_editor_scroll(ui, identity);
    if (!font.ctrlWheel(c.cui_key_mods(ui) & c.CUI_MOD_PRIMARY != 0, wheel)) s.glide.push(s.scroll_y, -wheel * font.line() * 3);
    if (s.glide.target != null) {
        const total: f32 = @as(f32, @floatFromInt(s.folds.rows(s.index.count()))) * font.line();
        s.glide.step(ui, &s.scroll_y, if (previous.h > 0) total - @max(1, previous.h - 16) else total);
    }
    const gutter = fold_w + gutterWidth(ui, if (s.index.count() > 0) s.index.lineNumber(s.index.count() - 1) else 1);
    const paint = Paint{ .state = s, .source = source, .lang = lang, .focused = focused, .char_w = char_w, .gutter = gutter, .fold_w = fold_w };
    const result = c.cui_canvas(ui, id, w.fill, w.fill, draw, &paint, @sizeOf(Paint));
    const rect = result.rect;
    c.kest_editor_register(ui, identity);
    c.kest_editor_tabs(ui, identity, @intFromBool(!read_only and !s.tab_moves_focus));
    const fold_click = result.pressed and c.kest_left_pressed(ui) and rect.w > 0 and foldClick(ui, s, source, rect, gutter, fold_w, char_w);
    if (result.pressed and rect.w > 0 and !fold_click and s.move_drag != .cancelled) if (hit(ui, s, source, rect, gutter, char_w)) |pos| {
        pointer(ui, s, source, pos, read_only, c.cui_mouse_pos(ui).x - rect.x - gutter - code_gap + s.scroll_x, char_w);
    };
    if (fold_click) s.move_drag = .cancelled;
    if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT)) {
        // An Alt+click that never dragged adds (or removes) a caret.
        if (s.column == .pending) s.toggleCaret(s.drop_at);
        s.column = .none;
        switch (s.move_drag) {
            .moving => s.moveSelection(s.drop_at, c.cui_key_mods(ui) & c.CUI_MOD_PRIMARY != 0),
            // A click inside the selection that never moved places the caret.
            .pending => s.moveTo(s.drop_at, false),
            .none, .cancelled => {},
        }
        s.move_drag = .none;
        s.selecting = false;
    }
    if (!read_only and rect.w > 0) if (hints) |h| variableHelp(ui, s, identity, focused, rect, gutter, char_w, v0 != s.version, h);
    return v0 != s.version;
}

/// Variables, set by the body before drawing its editor: hovering a
/// `{{name}}` shows its value, and typing `{{` suggests names.
pub var hints: ?suggest.Context = null;

fn variableHelp(ui: *c.cui_ctx, s: *State, identity: c.cui_id, focused: bool, rect: c.cui_rect, gutter: f32, char_w: f32, changed: bool, h: suggest.Context) void {
    const source = s.text();
    const m = c.cui_mouse_pos(ui);
    if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT) and m.x >= rect.x + gutter and m.x < rect.x + rect.w and m.y >= rect.y and m.y < rect.y + rect.h and std.mem.indexOf(u8, source, "{{") != null) {
        if (hit(ui, s, source, rect, gutter, char_w)) |pos| if (suggest.hoverText(source, pos, h)) |tip| c.kest_tooltip_for(ui, identity, w.z(tip));
    }
    if (s.index.count() == 0) return;
    const caret = @min(s.caret, source.len);
    const row = s.index.rowOf(caret);
    const bounds = s.index.bounds(source, row);
    const x = rect.x + gutter + code_gap - s.scroll_x + advance(ui, source[bounds[0]..@max(bounds[0], @min(caret, bounds[1]))], char_w);
    const y = rect.y + 8 + @as(f32, @floatFromInt(s.folds.visualOf(row) + 1)) * font.line() - s.scroll_y + 4;
    const below: c.cui_vec2 = .{ .x = @max(rect.x, x - 10), .y = @min(y, rect.y + rect.h) };
    if (suggest.editor(ui, identity, focused and !s.multi() and s.anchor == s.caret, source, caret, changed, below, h)) |e| {
        s.anchor = e.start;
        s.caret = e.end;
        s.replaceSelection(e.insert, false);
        s.moveTo(e.caret, false);
        c.cui_request_redraw(ui);
    }
}

/// The left button is down over the text at `pos`. A press starts a
/// selection, by words or lines after a double or triple click; a press
/// inside the selection may instead drag it somewhere else.
fn pointer(ui: *c.cui_ctx, s: *State, source: []const u8, pos: usize, read_only: bool, text_x: f32, char_w: f32) void {
    const mouse = c.cui_mouse_pos(ui);
    if (s.column != .none) return columnDrag(ui, s, source, pos, text_x, char_w);
    if (!s.selecting and s.move_drag == .none) {
        const range = s.selection();
        const clicks = c.kest_click_count(ui);
        const shift = c.cui_key_mods(ui) & c.CUI_MOD_SHIFT != 0;
        // Alt+click adds a caret; Alt+drag selects a column.
        if (!read_only and c.cui_key_mods(ui) & c.CUI_MOD_ALT != 0) {
            s.column = .pending;
            s.column_row = s.folds.visualOf(s.index.rowOf(pos));
            s.column_x = text_x;
            s.drop_at = pos;
            s.selecting = true;
            return;
        }
        if (!read_only and clicks <= 1 and !shift and !s.multi() and range[1] > range[0] and pos >= range[0] and pos < range[1]) {
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

/// An Alt+drag: one selection per row between where it began and the
/// pointer, each from the starting column to the pointer's.
fn columnDrag(ui: *c.cui_ctx, s: *State, source: []const u8, pos: usize, text_x: f32, char_w: f32) void {
    const row_now = s.folds.visualOf(s.index.rowOf(pos));
    if (s.column == .pending) {
        if (row_now == s.column_row and @abs(text_x - s.column_x) < char_w / 2) return;
        s.column = .dragging;
    }
    const top = @min(row_now, s.column_row);
    const bottom = @max(row_now, s.column_row);
    var all: std.ArrayList(code.Sel) = .empty;
    defer all.deinit(s.gpa);
    var main: usize = 0;
    for (top..bottom + 1) |visual| {
        const row = s.folds.rowAt(visual);
        const bounds = s.index.bounds(source, row);
        const text = source[bounds[0]..bounds[1]];
        const from = bounds[0] + byteAt(ui, text, @max(0, s.column_x), char_w);
        const to = bounds[0] + byteAt(ui, text, @max(0, text_x), char_w);
        if (visual == row_now) main = all.items.len;
        all.append(s.gpa, .{ .anchor = from, .caret = to }) catch return;
    }
    s.setSelections(all.items, main);
}

/// The caret one row up or down from `pos`, at the same distance in.
fn vertical(ui: *c.cui_ctx, s: *State, source: []const u8, pos: usize, up: bool, char_w: f32) usize {
    const row = s.index.rowOf(pos);
    const bounds = s.index.bounds(source, row);
    const x = advance(ui, source[bounds[0]..@min(pos, bounds[1])], char_w);
    const visual = s.folds.visualOf(row);
    const target = s.folds.rowAt(if (up) visual -| 1 else @min(visual + 1, s.folds.rows(s.index.count()) - 1));
    if (target == row) return pos;
    const next = s.index.bounds(source, target);
    return next[0] + byteAt(ui, source[next[0]..next[1]], x, char_w);
}

/// Pastes at every caret: a line each when the clipboard holds as many
/// lines as there are carets, else the whole of it at each.
pub fn pasteAll(s: *State, clip: []const u8) void {
    const count = s.extra.items.len + 1;
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(s.gpa);
    var lines = std.mem.splitScalar(u8, clip, '\n');
    while (lines.next()) |line| pieces.append(s.gpa, std.mem.trimEnd(u8, line, "\r")) catch return;
    if (pieces.items.len == count) s.editAll(.{ .each = pieces.items }) else s.editAll(.{ .insert = clip });
}

/// Keys while there are several carets: edits and moves act at each.
fn multiKeys(ui: *c.cui_ctx, s: *State, source: []const u8, read_only: bool, char_w: f32) void {
    const mods = c.cui_key_mods(ui);
    const shift = mods & c.CUI_MOD_SHIFT != 0;
    const ctrl = mods & c.CUI_MOD_PRIMARY != 0;
    if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
        s.collapse();
        return;
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_A)) {
        s.collapse();
        _ = s.command(.select_all, source, read_only);
        return;
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_C) or (!read_only and c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_X))) {
        if (s.copyAll(w.arena.allocator(), source)) |joined| w.copy(ui, joined) else |_| {}
        if (!read_only and c.cui_key_pressed(ui, c.CUI_KEY_X)) s.editAll(.{ .insert = "" });
        return;
    }
    if (!read_only) {
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_V)) {
            const clip = c.kest_clipboard(ui);
            if (clip != null) pasteAll(s, std.mem.span(clip));
            return;
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_Z)) {
            _ = s.undoEdit();
            return;
        }
        if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_Y) or c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_Z)) {
            _ = s.redoEdit();
            return;
        }
        const entered = c.kest_editor_text(ui);
        if (!ctrl and entered != null and entered[0] != 0) s.editAll(.{ .insert = std.mem.span(entered) });
        if (c.cui_key_pressed(ui, c.CUI_KEY_BACKSPACE)) s.editAll(if (ctrl) .delete_word_backward else .delete_backward);
        if (c.cui_key_pressed(ui, c.CUI_KEY_DELETE)) s.editAll(if (ctrl) .delete_word_forward else .delete_forward);
        if (!ctrl and c.cui_key_pressed(ui, c.CUI_KEY_ENTER)) s.editAll(.{ .insert = "\n" });
        if (!ctrl and !s.tab_moves_focus and c.cui_key_pressed(ui, c.CUI_KEY_TAB)) s.editAll(.{ .insert = "  " });
    }
    const now = s.text();
    if (c.cui_key_pressed(ui, c.CUI_KEY_LEFT)) s.commandAll(if (ctrl) (if (shift) .select_word_left else .move_word_left) else (if (shift) .select_left else .move_left), now);
    if (c.cui_key_pressed(ui, c.CUI_KEY_RIGHT)) s.commandAll(if (ctrl) (if (shift) .select_word_right else .move_word_right) else (if (shift) .select_right else .move_right), now);
    if (c.cui_key_pressed(ui, c.CUI_KEY_HOME)) s.commandAll(if (shift) .select_line_start else .move_line_start, now);
    if (c.cui_key_pressed(ui, c.CUI_KEY_END)) s.commandAll(if (shift) .select_line_end else .move_line_end, now);
    const up = c.cui_key_pressed(ui, c.CUI_KEY_UP);
    if ((up or c.cui_key_pressed(ui, c.CUI_KEY_DOWN)) and mods & c.CUI_MOD_ALT == 0) {
        var all: std.ArrayList(code.Sel) = .empty;
        defer all.deinit(s.gpa);
        s.selections(&all) catch return;
        var main: usize = 0;
        for (all.items, 0..) |*x, i| {
            if (x.caret == s.caret) main = i;
            const to = vertical(ui, s, now, x.caret, up, char_w);
            x.* = .{ .caret = to, .anchor = if (shift) x.anchor else to };
        }
        s.setSelections(all.items, main);
    }
}

/// Ctrl+Alt+Up or Down: a caret on the row above the first caret, or
/// below the last.
fn addCaretVertically(ui: *c.cui_ctx, s: *State, source: []const u8, up: bool, char_w: f32) void {
    var all: std.ArrayList(code.Sel) = .empty;
    defer all.deinit(s.gpa);
    s.selections(&all) catch return;
    const edge = if (up) all.items[0] else all.items[all.items.len - 1];
    const to = vertical(ui, s, source, edge.caret, up, char_w);
    if (to == edge.caret) return;
    all.append(s.gpa, .{ .caret = to, .anchor = to }) catch return;
    s.setSelections(all.items, all.items.len - 1);
}

/// The byte under the mouse in the editor's rectangle.
fn hit(ui: *c.cui_ctx, s: *State, source: []const u8, rect: c.cui_rect, gutter: f32, char_w: f32) ?usize {
    if (s.index.count() == 0) return null;
    const m = c.cui_mouse_pos(ui);
    const row_n: usize = @intFromFloat(@max(0, @floor((m.y - rect.y - 8 + s.scroll_y) / font.line())));
    const row_at = s.folds.rowAt(@min(row_n, s.folds.rows(s.index.count()) - 1));
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
    if (!read_only and ctrl and mods & c.CUI_MOD_ALT != 0) {
        if (c.cui_key_pressed(ui, c.CUI_KEY_UP)) addCaretVertically(ui, s, source, true, char_w);
        if (c.cui_key_pressed(ui, c.CUI_KEY_DOWN)) addCaretVertically(ui, s, source, false, char_w);
    }
    if (s.multi()) return multiKeys(ui, s, source, read_only, char_w);
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
            if (s.folds.anyFolded()) s.folds.update(s.gpa, source, &s.index, s.index_generation);
            const row = s.index.rowOf(s.caret);
            const bounds = s.index.bounds(source, row);
            const aim = s.goal_x orelse advance(ui, source[bounds[0]..@min(s.caret, bounds[1])], char_w);
            const visual = s.folds.visualOf(row);
            const target = s.folds.rowAt(if (c.cui_key_pressed(ui, c.CUI_KEY_UP)) visual -| 1 else @min(visual + 1, s.folds.rows(s.index.count()) - 1));
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

fn toggle(ui: *c.cui_ctx, key: [*:0]const u8, label: []const u8, on: *bool, hint: [*:0]const u8) void {
    if (w.action(ui, key, label, null, on.*, 28, 28, 0)) on.* = !on.*;
    c.kest_tooltip(ui, hint);
}

/// Find, and in an editor Replace: match case, whole words and regular
/// expressions. Enter finds the next match and Shift+Enter the one before;
/// in the Replace field Enter replaces one and Ctrl+Alt+Enter all.
pub fn search(ui: *c.cui_ctx, canvas: [*:0]const u8, s: *State, source: []const u8, read_only: bool) void {
    const find_focus = c.kest_editor_focus(ui, c.cui_make_id(ui, "find")) != 0;
    const replace_focus = c.kest_editor_focus(ui, c.cui_make_id(ui, "replace")) != 0;
    const mods = c.cui_key_mods(ui);
    w.column(ui, .{ .id = "editor-search", .gap = 4, .pad_x = 8, .pad_y = 6, .width = w.fill });
    defer w.end(ui);
    w.row(ui, .{ .gap = 4, .width = w.fill, .@"align" = c.CUI_ALIGN_CENTER });
    if (!read_only and w.icon(ui, if (s.replace_open) c.CUI_ICON_CHEVRON_DOWN else c.CUI_ICON_CHEVRON_RIGHT, "Toggle Replace (Ctrl+H)")) s.replace_open = !s.replace_open;
    _ = w.field(ui, "find", &s.query, .{ .placeholder = if (s.search_regex) "Find (regular expression)" else "Find in document", .width = w.fill, .size = c.CUI_SIZE_SM });
    toggle(ui, "find-case", "Aa", &s.search_case, "Match case");
    toggle(ui, "find-word", "W", &s.search_word, "Whole word");
    toggle(ui, "find-regex", ".*", &s.search_regex, "Regular expression");
    s.refreshSearch(source);
    const n = s.matches.items.len;
    const caption = if (s.search_problem.len > 0) "Invalid" else if (s.query.text().len == 0) "" else if (n == 0) "No matches" else w.fmt("{d} of {d}{s}", .{ @min(s.match_at + 1, n), n, if (s.matches_truncated) "+" else "" });
    w.text(ui, caption, .{ .width = w.px(84), .size = c.KEST_TEXT_CAPTION, .nowrap = true, .color = w.color(if (s.search_problem.len > 0) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_TEXT_SECONDARY) });
    c.cui_push_disabled(ui, n == 0);
    if (w.icon(ui, c.CUI_ICON_CHEVRON_UP, "Previous match (Shift+Enter)")) s.gotoMatch(-1);
    if (w.icon(ui, c.CUI_ICON_CHEVRON_DOWN, "Next match (Enter)")) s.gotoMatch(1);
    c.cui_pop_disabled(ui);
    var close = w.icon(ui, c.CUI_ICON_X, "Close (Escape)");
    w.end(ui);
    if (s.search_problem.len > 0) w.text(ui, w.fmt("{s} at character {d}", .{ s.search_problem, s.search_problem_at + 1 }), .{ .width = w.fill, .size = c.KEST_TEXT_CAPTION, .color = w.color(c.CUI_TOKEN_DANGER) });
    if (s.replace_open and !read_only) {
        w.row(ui, .{ .gap = 4, .width = w.fill, .@"align" = c.CUI_ALIGN_CENTER });
        w.row(ui, .{ .width = w.px(28), .height = w.px(1) });
        w.end(ui);
        _ = w.field(ui, "replace", &s.replacement, .{ .placeholder = if (s.search_regex) "Replace ($1 for a group)" else "Replace", .width = w.fill, .size = c.CUI_SIZE_SM });
        c.cui_push_disabled(ui, n == 0);
        if (w.button(ui, "Replace", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_SECONDARY })) _ = s.replaceOne();
        if (w.button(ui, "Replace all", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_SECONDARY })) _ = s.replaceAllMatches();
        c.cui_pop_disabled(ui);
        w.end(ui);
    }
    const enter = c.cui_key_pressed(ui, c.CUI_KEY_ENTER);
    if (find_focus and enter and mods & c.CUI_MOD_PRIMARY == 0) s.gotoMatch(if (mods & c.CUI_MOD_SHIFT != 0) -1 else 1);
    if (replace_focus and enter and !read_only) {
        if (mods & c.CUI_MOD_PRIMARY != 0 and mods & c.CUI_MOD_ALT != 0) _ = s.replaceAllMatches() else if (mods == 0) _ = s.replaceOne();
    }
    if ((find_focus or replace_focus) and c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
        close = true;
    }
    if (close) {
        s.search_open = false;
        c.kest_focus(ui, canvas);
    }
}

/// Opens Find (and Replace) on an editor. A short one-line selection
/// becomes the query.
pub fn openSearch(s: *State, replace: bool) void {
    s.search_open = true;
    if (replace) s.replace_open = true;
    const picked = s.selected(s.text());
    if (picked.len > 0 and picked.len <= 256 and std.mem.indexOfScalar(u8, picked, '\n') == null) s.query.set(picked);
    s.query.focus();
}

fn draw(ui_opt: ?*c.cui_ctx, rect: c.cui_rect, raw: ?*anyopaque) callconv(.c) void {
    const ui = ui_opt.?;
    const p: *const Paint = @ptrCast(@alignCast(raw.?));
    const s = p.state;
    const char_w = p.char_w;
    const gutter = p.gutter;
    if (s.index.count() == 0) return;
    const visible: f32 = @max(1, rect.h - 16);
    const shown = s.folds.rows(s.index.count());
    const total: f32 = @as(f32, @floatFromInt(shown)) * font.line();
    s.scroll_y = std.math.clamp(s.scroll_y, 0, @max(0, total - visible));
    if (s.reveal) {
        s.glide.stop();
        const caret_row: f32 = @as(f32, @floatFromInt(s.folds.visualOf(s.index.rowOf(@min(s.caret, p.source.len))))) * font.line();
        if (caret_row < s.scroll_y) s.scroll_y = caret_row;
        if (caret_row + font.line() > s.scroll_y + visible) s.scroll_y = caret_row + font.line() - visible;
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
    // Drawn after the content, inside the clip, so all four sides show.
    defer if (p.focused) w.focusFrame(ui, rect);
    const first: usize = @intFromFloat(@floor(s.scroll_y / font.line()));
    const count: usize = @intFromFloat(@ceil(visible / font.line()) + 2);
    const last = @min(shown, first + count);
    const sel = s.selection();
    const active_row = s.index.rowOf(@min(s.caret, p.source.len));
    for (first..last) |visual| {
        const i = s.folds.rowAt(visual);
        const bounds = s.index.bounds(p.source, i);
        const entire_row = s.index.row(p.source, i);
        const col_lo = byteAt(ui, entire_row, @max(0, s.scroll_x - char_w), char_w);
        const col_hi = code.nextChar(entire_row, byteAt(ui, entire_row, s.scroll_x + @max(1, rect.w - gutter - code_gap) + char_w, char_w));
        const y = rect.y + 8 + @as(f32, @floatFromInt(visual)) * font.line() - s.scroll_y;
        const x = rect.x + gutter + code_gap - s.scroll_x;
        if (p.focused and active_row == i) c.cui_draw_rect(ui, .{ .x = rect.x + gutter + 1, .y = y, .w = @max(0, rect.w - gutter - 1), .h = font.line() }, .{}, w.color(c.CUI_TOKEN_SURFACE_MUTED));
        if (s.marked) |pair| for (pair) |pos| {
            if (pos >= bounds[0] and pos < bounds[1]) {
                const mark_x = advance(ui, entire_row[0 .. pos - bounds[0]], char_w);
                c.cui_draw_rect_border(ui, .{ .x = x + mark_x - 0.5, .y = y + 1, .w = char_w + 1, .h = font.line() - 2 }, .{ .tl = 2, .tr = 2, .br = 2, .bl = 2 }, w.color(c.CUI_TOKEN_ACCENT_SUBTLE), w.tinted(ui, c.CUI_TOKEN_ACCENT, 0.7), 1);
            }
        };
        if (s.search_open and s.matches.items.len > 0) {
            var m = @import("../utils/search.zig").firstAfter(s.matches.items, bounds[0]);
            while (m < s.matches.items.len and s.matches.items[m].start < bounds[1]) : (m += 1) {
                const item = s.matches.items[m];
                const hit_x = advance(ui, entire_row[0 .. @max(item.start, bounds[0]) - bounds[0]], char_w);
                const hit_end = advance(ui, entire_row[0 .. @min(item.end, bounds[1]) - bounds[0]], char_w);
                c.cui_draw_rect(ui, .{ .x = x + hit_x, .y = y, .w = @max(2, hit_end - hit_x), .h = font.line() }, .{}, w.tinted(ui, c.CUI_TOKEN_WARNING, if (m == s.match_at) 0.4 else 0.18));
            }
        }
        if (sel[1] > bounds[0] and sel[0] < bounds[1]) {
            const lo = @max(sel[0], bounds[0]) - bounds[0];
            const hi = @min(sel[1], bounds[1]) - bounds[0];
            const selection_x = advance(ui, entire_row[0..lo], char_w);
            const selection_end = advance(ui, entire_row[0..hi], char_w);
            c.cui_draw_rect(ui, .{ .x = x + selection_x, .y = y, .w = selection_end - selection_x, .h = font.line() }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
        }
        if (s.multi()) drawExtras(ui, s, p.focused, entire_row, bounds, x, y, char_w);
        var number: [16]u8 = undefined;
        const label = if (s.index.isContinued(i)) "" else std.fmt.bufPrint(&number, "{d}", .{s.index.lineNumber(i)}) catch "";
        const label_w = c.cui_measure_text(ui, c.CUI_FONT_MONO, font.small(), label.ptr, @intCast(label.len)).width;
        c.cui_draw_text(ui, c.CUI_FONT_MONO, font.small(), .{ .x = rect.x + gutter - 10 - label_w, .y = y + 1 }, w.color(if (p.focused and active_row == i) c.CUI_TOKEN_TEXT_SECONDARY else c.CUI_TOKEN_TEXT_MUTED), label.ptr, @intCast(label.len));
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
        if (p.fold_w > 0) if (s.folds.regionOnRow(i)) |r| {
            const folded = s.folds.isFolded(r.open);
            c.cui_draw_icon(ui, if (folded) c.CUI_ICON_CHEVRON_RIGHT else c.CUI_ICON_CHEVRON_DOWN, .{ .x = rect.x + 2, .y = y + (font.line() - 12) / 2, .w = 12, .h = 12 }, 11, w.color(if (folded) c.CUI_TOKEN_TEXT_SECONDARY else c.CUI_TOKEN_TEXT_MUTED));
            if (folded) {
                const chip = foldChip(ui, s, p.source, i, x, y, char_w);
                c.cui_draw_rect(ui, chip, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_SURFACE_MUTED));
                const marker = foldLabel(r);
                c.cui_draw_text(ui, c.CUI_FONT_BODY, font.small(), .{ .x = chip.x + 5, .y = chip.y + (chip.h - font.small()) / 2 - 1 }, w.color(c.CUI_TOKEN_TEXT_SECONDARY), marker.ptr, @intCast(marker.len));
            }
        };
        if (s.move_drag == .moving and (s.drop_at < s.selection()[0] or s.drop_at > s.selection()[1]) and s.drop_at >= bounds[0] and s.drop_at <= bounds[1] and (s.drop_at < bounds[1] or i + 1 == s.index.count() or s.index.bounds(p.source, i + 1)[0] > s.drop_at)) {
            const drop_x = x + advance(ui, entire_row[0..@min(s.drop_at - bounds[0], entire_row.len)], char_w);
            c.cui_draw_line(ui, .{ .x = drop_x, .y = y }, .{ .x = drop_x, .y = y + font.caret() }, 2, w.color(c.CUI_TOKEN_TEXT_SECONDARY));
        }
        if (p.focused and i == active_row) {
            const caret_x = x + advance(ui, entire_row[0..@min(s.caret -| bounds[0], entire_row.len)], char_w);
            c.cui_draw_line(ui, .{ .x = caret_x, .y = y }, .{ .x = caret_x, .y = y + font.caret() }, 1.5, w.color(c.CUI_TOKEN_ACCENT));
        }
    }
    if (total > visible) {
        const thumb = @max(20, visible * visible / total);
        c.cui_draw_rect(ui, .{ .x = rect.x + rect.w - 5, .y = rect.y + 8 + s.scroll_y / (total - visible) * (visible - thumb), .w = 3, .h = thumb }, .{ .tl = 2, .tr = 2, .br = 2, .bl = 2 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
    }
}

/// The other carets' selections and carets on one row.
fn drawExtras(ui: *c.cui_ctx, s: *const State, focused: bool, row: []const u8, bounds: [2]usize, x: f32, y: f32, char_w: f32) void {
    const items = s.extra.items;
    // Sorted and apart, so their ends ascend too.
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (items[mid].hi() < bounds[0]) lo = mid + 1 else hi = mid;
    }
    while (lo < items.len and items[lo].lo() <= bounds[1]) : (lo += 1) {
        const sel = items[lo];
        if (sel.hi() > bounds[0] and sel.lo() < bounds[1]) {
            const a = advance(ui, row[0 .. @max(sel.lo(), bounds[0]) - bounds[0]], char_w);
            const b = advance(ui, row[0 .. @min(sel.hi(), bounds[1]) - bounds[0]], char_w);
            c.cui_draw_rect(ui, .{ .x = x + a, .y = y, .w = b - a, .h = font.line() }, .{}, w.color(c.CUI_TOKEN_ACCENT_SUBTLE));
        }
        if (focused and sel.caret >= bounds[0] and sel.caret <= bounds[1]) {
            const caret_x = x + advance(ui, row[0..@min(sel.caret - bounds[0], row.len)], char_w);
            c.cui_draw_line(ui, .{ .x = caret_x, .y = y }, .{ .x = caret_x, .y = y + font.caret() }, 1.5, w.color(c.CUI_TOKEN_ACCENT));
        }
    }
}

fn foldLabel(r: @import("folding.zig").Region) []const u8 {
    const hidden = r.close_row - r.open_row - 1;
    return w.fmt("\u{2026} {d} {s}", .{ hidden, if (hidden == 1) "line" else "lines" });
}

/// The marker after a folded row's text; clicking it unfolds.
fn foldChip(ui: *c.cui_ctx, s: *State, source: []const u8, row: usize, x: f32, y: f32, char_w: f32) c.cui_rect {
    const end = x + advance(ui, s.index.row(source, row), char_w) + char_w;
    const label = foldLabel(s.folds.regionOnRow(row).?);
    const width = c.cui_measure_text(ui, c.CUI_FONT_BODY, font.small(), label.ptr, @intCast(label.len)).width + 10;
    return .{ .x = end, .y = y + 2, .w = width, .h = font.line() - 4 };
}

/// A press on a fold arrow, or on a folded row's marker, toggles the fold.
fn foldClick(ui: *c.cui_ctx, s: *State, source: []const u8, rect: c.cui_rect, gutter: f32, fold_w: f32, char_w: f32) bool {
    if (fold_w == 0 or s.index.count() == 0) return false;
    const m = c.cui_mouse_pos(ui);
    const visual: usize = @intFromFloat(@max(0, @floor((m.y - rect.y - 8 + s.scroll_y) / font.line())));
    if (visual >= s.folds.rows(s.index.count())) return false;
    const row = s.folds.rowAt(visual);
    const r = s.folds.regionOnRow(row) orelse return false;
    var on = m.x < rect.x + fold_w + 2;
    if (!on and s.folds.isFolded(r.open)) {
        const y = rect.y + 8 + @as(f32, @floatFromInt(visual)) * font.line() - s.scroll_y;
        const chip = foldChip(ui, s, source, row, rect.x + gutter + code_gap - s.scroll_x, y, char_w);
        on = m.x >= chip.x and m.x < chip.x + chip.w and m.y >= chip.y and m.y < chip.y + chip.h;
    }
    if (!on) return false;
    s.folds.toggle(s.gpa, r.open);
    keepCaretShown(s);
    return true;
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
        c.cui_draw_text(ui, c.CUI_FONT_MONO, font.size, .{ .x = x + advance(ui, source[0..at], char_w), .y = y }, tint, source[at..stop].ptr, @intCast(stop - at));
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
        if (stop > at) width += c.cui_measure_text(ui, c.CUI_FONT_MONO, font.size, source[at..stop].ptr, @intCast(stop - at)).width;
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
