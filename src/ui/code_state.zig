//! A code view's text state: caret, selection, undo, and every edit command.
//! Indexes rows per edit and keeps bounded undo for responsive large payloads.
const std = @import("std");

const ui = @import("model.zig");
const lines = @import("../utils/lines.zig");
const search = @import("../utils/search.zig");
const Allocator = std.mem.Allocator;

/// Undo stops growing past this: the oldest edits go first.
const undo_budget = 16 * 1024 * 1024;

const Edit = struct {
    at: usize,
    removed: []u8,
    inserted: []u8,
    caret_before: usize,
    anchor_before: usize,
    caret_after: usize,
    anchor_after: usize,

    fn size(e: Edit) usize {
        return e.removed.len + e.inserted.len;
    }
};

pub const State = struct {
    gpa: Allocator,
    buffer: ui.TextBuffer = .{},
    caret: usize = 0,
    anchor: usize = 0,
    marked: ?[2]usize = null,
    marked_version: u64 = 0,
    marked_caret: usize = 0,
    marked_ptr: usize = 0,
    /// Bumped by each change to the text.
    version: u64 = 1,
    indexed_version: u64 = 0,
    /// A viewer's text is someone else's: indexed again when it changes.
    indexed_ptr: usize = 0,
    indexed_len: usize = 0,
    index: lines.Index = .{},
    index_generation: u64 = 0,
    syntax_generation: u64 = 0,
    continued_strings: std.ArrayList(@import("../utils/highlight.zig").CrossRowString) = .empty,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Response-only immutable spatial index; editable bodies use index above.
    geometry: ?@import("../core/text_layout.zig").Layout = null,
    layout_job: ?*@import("../app/response_prepare.zig").Job = null,
    layout_config: ?@import("../core/text_layout.zig").Config = null,
    layout_failure: bool = false,
    layout_ptr: usize = 0,
    layout_len: usize = 0,
    layout_visible: bool = false,
    layout_pending: bool = false,
    precise_x: f64 = 0,
    precise_goal: ?f64 = null,
    scroll_drag: enum { none, horizontal, vertical } = .none,
    drag_offset: f32 = 0,
    layout_fallback: ?*State = null,
    layout_fallback_offset: usize = 0,
    /// The caret moved or the text changed: bring the caret into view.
    reveal: bool = false,
    /// Show this byte at the next frame (a search result).
    reveal_at: ?usize = null,
    selecting: bool = false,
    /// What a drag selects by: characters, or whole words or lines after a
    /// double or triple click. `unit_range` is what the click selected.
    unit: Unit = .char,
    unit_range: [2]usize = .{ 0, 0 },
    /// Dragging the selection to move it: pressed inside it, then moved.
    move_drag: enum { none, pending, moving, cancelled } = .none,
    press_x: f32 = 0,
    press_y: f32 = 0,
    /// Where the dragged text would land.
    drop_at: usize = 0,
    /// Wheel scrolling on its way.
    glide: @import("glide.zig").Glide = .{},
    glide_x: @import("glide.zig").Glide = .{},
    /// Where Up and Down aim, as a byte column.
    goal_col: ?usize = null,
    /// Raw body editor preferences; these never change request bytes.
    word_wrap: bool = false,
    tab_moves_focus: bool = false,
    goal_x: ?f32 = null,
    undo: std.ArrayList(Edit) = .empty,
    redo: std.ArrayList(Edit) = .empty,
    undo_bytes: usize = 0,
    /// Typing joins the last edit while this holds.
    typing: bool = false,
    list_id: u64 = 0,
    search_open: bool = false,
    query: ui.TextBuffer = .{},
    matches: std.ArrayList(search.Match) = .empty,
    match_at: usize = 0,
    matches_truncated: bool = false,
    searched_version: u64 = 0,
    searched_ptr: usize = 0,
    searched_len: usize = 0,
    search_job: ?*@import("../app/response_prepare.zig").Job = null,
    search_index: ?@import("../core/response_search.zig").Index = null,
    search_key: [@import("../core/response_search.zig").max_query]u8 = undefined,
    search_key_len: usize = 0,
    search_case: bool = false,
    /// Whole words only, and the query as a regular expression.
    search_word: bool = false,
    search_regex: bool = false,
    /// A malformed regular expression: what's wrong, and where.
    search_problem: []const u8 = "",
    search_problem_at: usize = 0,
    searched_options: search.Options = .{},
    /// The query the matches are for, by hash: it can change without an edit.
    searched_query: u64 = 0,
    /// The Replace row under Find, and what replaces each match.
    replace_open: bool = false,
    replacement: ui.TextBuffer = .{},
    search_key_case: bool = false,
    search_visible: bool = false,
    search_pending: bool = false,
    search_failure: ?enum { query_limit, input_limit, unavailable } = null,
    search_page_start: u32 = 0,
    search_selected: u32 = 0,
    search_target: ?u32 = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *State) void {
        s.clearResponseSearch();
        s.clearLayout();
        if (s.layout_fallback) |fallback| {
            fallback.deinit();
            s.gpa.destroy(fallback);
        }
        s.buffer.deinit();
        s.query.deinit();
        s.replacement.deinit();
        s.index.deinit(s.gpa);
        s.continued_strings.deinit(s.gpa);
        s.matches.deinit(s.gpa);
        s.clearStack(&s.undo);
        s.clearStack(&s.redo);
        s.undo.deinit(s.gpa);
        s.redo.deinit(s.gpa);
    }

    pub fn clearResponseSearch(s: *State) void {
        if (s.search_job) |job| job.abandon();
        s.search_job = null;
        if (s.search_index) |*index| index.deinit(s.gpa);
        s.search_index = null;
        s.matches.clearRetainingCapacity();
        s.search_pending = false;
        s.search_failure = null;
        s.search_target = null;
        s.search_selected = 0;
        s.search_page_start = 0;
    }

    pub fn clearLayout(s: *State) void {
        if (s.layout_job) |job| job.abandon();
        s.layout_job = null;
        if (s.geometry) |*geometry| geometry.deinit(s.gpa);
        s.geometry = null;
        s.layout_config = null;
        s.layout_failure = false;
        s.layout_pending = false;
        s.layout_ptr = 0;
        s.layout_len = 0;
        s.precise_goal = null;
        s.scroll_drag = .none;
    }

    fn clearStack(s: *State, stack: *std.ArrayList(Edit)) void {
        for (stack.items) |e| {
            s.gpa.free(e.removed);
            s.gpa.free(e.inserted);
        }
        stack.clearRetainingCapacity();
    }

    pub fn text(s: *const State) []const u8 {
        return s.buffer.text();
    }

    /// Replaces everything, forgetting undo: a tab loaded, a body reset.
    pub fn setText(s: *State, value: []const u8) void {
        if (!s.buffer.reserve(value.len)) return;
        _ = s.buffer.replace(0, s.buffer.text().len, value);
        s.buffer.want_caret = null;
        s.caret = 0;
        s.anchor = 0;
        s.marked = null;
        s.scroll_x = 0;
        s.version += 1;
        s.undo_bytes = 0;
        s.clearStack(&s.undo);
        s.clearStack(&s.redo);
    }

    /// An edit that undo can take back: a Format, say.
    pub fn replaceAll(s: *State, value: []const u8) void {
        const version = s.version;
        s.change(0, s.buffer.text().len, value, false);
        if (s.version == version) return;
        s.caret = 0;
        s.anchor = 0;
        if (s.undo.items.len > 0) {
            s.undo.items[s.undo.items.len - 1].caret_after = 0;
            s.undo.items[s.undo.items.len - 1].anchor_after = 0;
        }
        s.reveal = true;
    }

    pub fn selection(s: *const State) [2]usize {
        return .{ @min(s.caret, s.anchor), @max(s.caret, s.anchor) };
    }

    pub fn selected(s: *const State, from: []const u8) []const u8 {
        const r = s.selection();
        return from[@min(r[0], from.len)..@min(r[1], from.len)];
    }

    /// Replaces the selection with `t`, recording it for undo.
    pub fn replaceSelection(s: *State, t: []const u8, typed: bool) void {
        const r = s.selection();
        s.change(r[0], r[1], t, typed);
    }

    fn change(s: *State, lo: usize, hi: usize, t: []const u8, typed: bool) void {
        if (!s.buffer.reserve(s.buffer.len - (hi - lo) + t.len)) return;
        const before = s.buffer.text();
        const removed = before[lo..hi];
        if (removed.len == 0 and t.len == 0) return;
        const joinable = typed and s.typing and removed.len == 0 and t.len < 16 and std.mem.indexOfScalar(u8, t, '\n') == null;
        var joined = false;
        if (joinable and s.undo.items.len > 0) {
            const last = &s.undo.items[s.undo.items.len - 1];
            if (last.removed.len == 0 and last.at + last.inserted.len == lo) {
                if (s.gpa.realloc(last.inserted, last.inserted.len + t.len)) |grown| {
                    @memcpy(grown[last.inserted.len..], t);
                    last.inserted = grown;
                    last.caret_after = lo + t.len;
                    last.anchor_after = lo + t.len;
                    s.undo_bytes += t.len;
                    joined = true;
                } else |_| {}
            }
        }
        if (!joined and !s.record(lo, removed, t)) return;
        if (s.buffer.replace(lo, hi, t) != t.len) return;
        s.clearStack(&s.redo);
        s.caret = lo + t.len;
        s.anchor = s.caret;
        s.typing = typed;
        s.touched();
    }

    fn record(s: *State, lo: usize, removed: []const u8, t: []const u8) bool {
        const r = s.gpa.dupe(u8, removed) catch return false;
        const ins = s.gpa.dupe(u8, t) catch {
            s.gpa.free(r);
            return false;
        };
        const e: Edit = .{ .at = lo, .removed = r, .inserted = ins, .caret_before = s.caret, .anchor_before = s.anchor, .caret_after = lo + t.len, .anchor_after = lo + t.len };
        s.undo.append(s.gpa, e) catch {
            s.gpa.free(r);
            s.gpa.free(ins);
            return false;
        };
        s.undo_bytes += e.size();
        // Always keeps the newest edit, however large.
        while (s.undo_bytes > undo_budget and s.undo.items.len > 1) {
            const old = s.undo.orderedRemove(0);
            s.undo_bytes -= old.size();
            s.gpa.free(old.removed);
            s.gpa.free(old.inserted);
        }
        return true;
    }

    fn touched(s: *State) void {
        s.version += 1;
        s.reveal = true;
        s.goal_col = null;
        s.goal_x = null;
        s.precise_goal = null;
    }

    pub fn undoEdit(s: *State) bool {
        if (s.undo.items.len == 0) return false;
        const next = s.undo.items[s.undo.items.len - 1];
        if (!s.buffer.reserve(s.buffer.len - next.inserted.len + next.removed.len)) return false;
        s.redo.ensureUnusedCapacity(s.gpa, 1) catch return false;
        const e = s.undo.pop() orelse return false;
        _ = s.buffer.replace(e.at, e.at + e.inserted.len, e.removed);
        s.undo_bytes -= e.size();
        s.redo.appendAssumeCapacity(e);
        s.caret = e.caret_before;
        s.anchor = e.anchor_before;
        s.typing = false;
        s.touched();
        return true;
    }

    pub fn redoEdit(s: *State) bool {
        if (s.redo.items.len == 0) return false;
        const next = s.redo.items[s.redo.items.len - 1];
        if (!s.buffer.reserve(s.buffer.len - next.removed.len + next.inserted.len)) return false;
        s.undo.ensureUnusedCapacity(s.gpa, 1) catch return false;
        const e = s.redo.pop() orelse return false;
        _ = s.buffer.replace(e.at, e.at + e.removed.len, e.inserted);
        s.undo.appendAssumeCapacity(e);
        s.undo_bytes += e.size();
        s.caret = e.caret_after;
        s.anchor = e.anchor_after;
        s.typing = false;
        s.touched();
        return true;
    }

    /// Moves the caret; `extend` keeps the anchor.
    pub fn moveTo(s: *State, to: usize, extend: bool) void {
        s.caret = to;
        if (!extend) s.anchor = to;
        s.typing = false;
        s.reveal = true;
        s.goal_x = null;
        s.precise_goal = null;
    }

    /// A press at `pos` after `clicks` clicks: one places the caret (Shift
    /// extends), two select the word, three the line. Dragging afterwards
    /// grows the selection by the same unit.
    pub fn pressAt(s: *State, from: []const u8, pos: usize, clicks: c_int, extend: bool) void {
        s.unit = switch (clicks) {
            0, 1 => .char,
            2 => .word,
            else => .line,
        };
        if (s.unit == .char) {
            s.moveTo(pos, extend);
            return;
        }
        s.unit_range = unitRange(from, pos, s.unit);
        s.moveTo(s.unit_range[1], false);
        s.anchor = s.unit_range[0];
    }

    /// The pointer dragged to `pos` with the button held.
    pub fn dragTo(s: *State, from: []const u8, pos: usize) void {
        if (s.unit == .char) return s.moveTo(pos, true);
        const r = unitRange(from, pos, s.unit);
        if (r[0] < s.unit_range[0]) {
            s.moveTo(r[0], false);
            s.anchor = s.unit_range[1];
        } else {
            s.moveTo(@max(r[1], s.unit_range[1]), false);
            s.anchor = s.unit_range[0];
        }
    }

    /// Moves the selected text to `to`, or copies it there, as one edit
    /// that undo takes back. The moved text stays selected.
    pub fn moveSelection(s: *State, to_in: usize, copy: bool) void {
        const from = s.text();
        const r = s.selection();
        const to = @min(to_in, from.len);
        if (r[1] <= r[0] or (to >= r[0] and to <= r[1])) return;
        const piece = from[r[0]..r[1]];
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        const version = s.version;
        var start: usize = undefined;
        if (copy) {
            start = to;
            out.appendSlice(s.gpa, piece) catch return;
            s.change(to, to, out.items, false);
        } else if (to < r[0]) {
            start = to;
            out.appendSlice(s.gpa, piece) catch return;
            out.appendSlice(s.gpa, from[to..r[0]]) catch return;
            s.change(to, r[1], out.items, false);
        } else {
            start = to - piece.len;
            out.appendSlice(s.gpa, from[r[1]..to]) catch return;
            out.appendSlice(s.gpa, piece) catch return;
            s.change(r[0], to, out.items, false);
        }
        if (version == s.version) return;
        s.anchor = start;
        s.caret = start + piece.len;
        if (s.undo.items.len > 0) {
            s.undo.items[s.undo.items.len - 1].caret_after = s.caret;
            s.undo.items[s.undo.items.len - 1].anchor_after = s.anchor;
        }
    }

    /// Runs one editing command against `from`, which is the buffer unless
    /// read-only. Returns whether the text changed.
    pub fn command(s: *State, cmd: ui.Command, from: []const u8, read_only: bool) bool {
        const c = @min(s.caret, from.len);
        const has_sel = s.caret != s.anchor;
        const v0 = s.version;
        switch (cmd) {
            .move_left => s.moveTo(if (has_sel) s.selection()[0] else prevChar(from, c), false),
            .move_right => s.moveTo(if (has_sel) s.selection()[1] else nextChar(from, c), false),
            .select_left => s.moveTo(prevChar(from, c), true),
            .select_right => s.moveTo(nextChar(from, c), true),
            .move_word_left => s.moveTo(prevWord(from, c), false),
            .move_word_right => s.moveTo(nextWord(from, c), false),
            .select_word_left => s.moveTo(prevWord(from, c), true),
            .select_word_right => s.moveTo(nextWord(from, c), true),
            .move_line_start => s.moveTo(lineStart(from, c), false),
            .move_line_end => s.moveTo(lineEnd(from, c), false),
            .select_line_start => s.moveTo(lineStart(from, c), true),
            .select_line_end => s.moveTo(lineEnd(from, c), true),
            .select_all => {
                s.caret = from.len;
                s.anchor = 0;
                s.typing = false;
            },
            else => if (!read_only) s.editCommand(cmd, from, c, has_sel),
        }
        return s.version != v0;
    }

    fn editCommand(s: *State, cmd: ui.Command, from: []const u8, c: usize, has_sel: bool) void {
        switch (cmd) {
            .delete_backward => if (has_sel) s.replaceSelection("", false) else s.change(prevChar(from, c), c, "", false),
            .delete_forward => if (has_sel) s.replaceSelection("", false) else s.change(c, nextChar(from, c), "", false),
            .delete_word_backward => if (has_sel) s.replaceSelection("", false) else s.change(prevWord(from, c), c, "", false),
            .delete_word_forward => if (has_sel) s.replaceSelection("", false) else s.change(c, nextWord(from, c), "", false),
            .delete_to_line_start => s.change(lineStart(from, c), c, "", false),
            .delete_to_line_end => s.change(c, lineEnd(from, c), "", false),
            .insert_newline, .insert_line_break => s.newline(from, c),
            .insert_tab => s.indent(false),
            else => {},
        }
    }

    /// A new line at the indent of this one, one deeper after an opener.
    pub fn newline(s: *State, from: []const u8, c: usize) void {
        const at = @min(c, s.selection()[0]);
        const start = lineStart(from, at);
        var e = start;
        while (e < at and (from[e] == ' ' or from[e] == '\t')) e += 1;
        const crlf = std.mem.indexOf(u8, from, "\r\n") != null;
        const nl: []const u8 = if (crlf) "\r\n" else "\n";
        const deeper = at > 0 and (from[at - 1] == '{' or from[at - 1] == '[');
        const hi = @min(s.selection()[1], from.len);
        const paired = deeper and hi < from.len and ((from[at - 1] == '{' and from[hi] == '}') or (from[at - 1] == '[' and from[hi] == ']'));
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        out.appendSlice(s.gpa, nl) catch return;
        out.appendSlice(s.gpa, from[start..e]) catch return;
        if (deeper) out.appendSlice(s.gpa, "  ") catch return;
        const caret = at + out.items.len;
        if (paired) {
            out.appendSlice(s.gpa, nl) catch return;
            out.appendSlice(s.gpa, from[start..e]) catch return;
        }
        const version = s.version;
        s.replaceSelection(out.items, false);
        if (version != s.version) {
            s.caret = caret;
            s.anchor = caret;
            if (s.undo.items.len > 0) {
                s.undo.items[s.undo.items.len - 1].caret_after = caret;
                s.undo.items[s.undo.items.len - 1].anchor_after = caret;
            }
        }
    }

    /// One undoable indentation edit, retaining selection direction and lines.
    pub fn indent(s: *State, outdent: bool) void {
        const from = s.text();
        const sel = s.selection();
        if (!outdent and sel[0] == sel[1]) {
            s.replaceSelection("  ", false);
            return;
        }
        const lo = lineStart(from, sel[0]);
        const last = if (sel[1] > sel[0] and sel[1] == lineStart(from, sel[1])) sel[1] - 1 else sel[1];
        const hi = lineEndRaw(from, last);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        var caret = s.caret;
        var anchor = s.anchor;
        var at = lo;
        while (at <= hi) {
            const end = @min(hi, lineEndRaw(from, at));
            var removed: usize = 0;
            if (outdent) {
                if (at < end and from[at] == '\t') {
                    removed = 1;
                } else while (removed < 2 and at + removed < end and from[at + removed] == ' ') : (removed += 1) {}
            } else out.appendSlice(s.gpa, "  ") catch return;
            if (s.caret >= at) caret = if (outdent) caret - @min(removed, s.caret - at) else caret + 2;
            if (s.anchor >= at) anchor = if (outdent) anchor - @min(removed, s.anchor - at) else anchor + 2;
            out.appendSlice(s.gpa, from[at + removed .. end]) catch return;
            if (end == hi) break;
            out.append(s.gpa, '\n') catch return;
            at = end + 1;
        }
        if (std.mem.eql(u8, out.items, from[lo..hi])) return;
        const version = s.version;
        s.change(lo, hi, out.items, false);
        if (version != s.version) {
            s.caret = caret;
            s.anchor = anchor;
            if (s.undo.items.len > 0) {
                s.undo.items[s.undo.items.len - 1].caret_after = caret;
                s.undo.items[s.undo.items.len - 1].anchor_after = anchor;
            }
        }
    }

    pub fn searchOptions(s: *const State) search.Options {
        return .{ .case_sensitive = s.search_case, .whole_word = s.search_word, .regex = s.search_regex };
    }

    /// Finds `query` again if it, its options or the text changed.
    pub fn refreshSearch(s: *State, from: []const u8) void {
        if (s.searched_version == s.version and s.searched_ptr == @intFromPtr(from.ptr) and s.searched_len == from.len and std.meta.eql(s.searched_options, s.searchOptions()) and s.searched_query == std.hash.Wyhash.hash(0, s.query.text())) return;
        s.research(from);
    }

    pub fn research(s: *State, from: []const u8) void {
        var problem: @import("../utils/regex.zig").Problem = .{};
        s.search_problem = "";
        s.searched_options = s.searchOptions();
        s.searched_query = std.hash.Wyhash.hash(0, s.query.text());
        s.matches_truncated = search.findWith(s.gpa, from, s.query.text(), s.searched_options, &s.matches, &problem) catch |err| blk: {
            s.matches.clearRetainingCapacity();
            if (err == error.Syntax) {
                s.search_problem = problem.message;
                s.search_problem_at = problem.at;
            }
            break :blk false;
        };
        s.searched_version = s.version;
        s.searched_ptr = @intFromPtr(from.ptr);
        s.searched_len = from.len;
        if (s.match_at >= s.matches.items.len) s.match_at = 0;
    }

    /// Replaces the selection if it is a match, then selects the next match.
    /// Returns whether anything was replaced.
    pub fn replaceOne(s: *State) bool {
        var problem: @import("../utils/regex.zig").Problem = .{};
        var finder = search.Finder.init(s.gpa, s.query.text(), s.searchOptions(), &problem) catch return false;
        defer finder.deinit();
        const from = s.text();
        const sel = s.selection();
        var replaced = false;
        if (sel[1] > sel[0] and (finder.exact(from, .{ .start = @intCast(sel[0]), .end = @intCast(sel[1]) }) catch false)) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(s.gpa);
            finder.replacement(&out, from, s.replacement.text()) catch return false;
            const version = s.version;
            s.replaceSelection(out.items, false);
            replaced = version != s.version;
        }
        // The next match after the caret, wrapping around.
        const text_now = s.text();
        const next = (finder.next(text_now, s.caret) catch null) orelse (finder.next(text_now, 0) catch null);
        if (next) |m| {
            s.anchor = m.start;
            s.caret = m.end;
            s.reveal = true;
            s.typing = false;
        }
        s.research(text_now);
        if (next) |m| for (s.matches.items, 0..) |item, i| if (item.start == m.start) {
            s.match_at = i;
            break;
        };
        return replaced;
    }

    /// Replaces every match as one edit that undo takes back. Returns how
    /// many were replaced.
    pub fn replaceAllMatches(s: *State) usize {
        var problem: @import("../utils/regex.zig").Problem = .{};
        var finder = search.Finder.init(s.gpa, s.query.text(), s.searchOptions(), &problem) catch return 0;
        defer finder.deinit();
        const from = s.text();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        var count: usize = 0;
        var lo: usize = 0;
        var copied: usize = 0;
        var at: usize = 0;
        while (finder.next(from, at) catch null) |m| {
            if (count == 0) {
                lo = m.start;
                copied = m.start;
            }
            out.appendSlice(s.gpa, from[copied..m.start]) catch return 0;
            finder.replacement(&out, from, s.replacement.text()) catch return 0;
            copied = m.end;
            at = m.end;
            count += 1;
        }
        if (count == 0) return 0;
        const version = s.version;
        s.change(lo, copied, out.items, false);
        if (version == s.version) return 0;
        s.anchor = lo;
        s.caret = lo;
        if (s.undo.items.len > 0) {
            s.undo.items[s.undo.items.len - 1].caret_after = lo;
            s.undo.items[s.undo.items.len - 1].anchor_after = lo;
        }
        s.research(s.text());
        return count;
    }

    pub fn gotoMatch(s: *State, delta: i32) void {
        const n = s.matches.items.len;
        if (n == 0) return;
        const at: i64 = @as(i64, @intCast(s.match_at)) + delta;
        s.match_at = @intCast(@mod(at, @as(i64, @intCast(n))));
        const m = s.matches.items[s.match_at];
        s.anchor = m.start;
        s.caret = m.end;
        s.reveal = true;
    }
};

pub fn prevChar(s: []const u8, i_in: usize) usize {
    var i = @min(i_in, s.len);
    if (i == 0) return 0;
    if (i >= 2 and s[i - 2] == '\r' and s[i - 1] == '\n') return i - 2;
    i -= 1;
    while (i > 0 and (s[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

pub fn nextChar(s: []const u8, i_in: usize) usize {
    var i = i_in;
    if (i >= s.len) return s.len;
    if (i + 1 < s.len and s[i] == '\r' and s[i + 1] == '\n') return i + 2;
    i += 1;
    while (i < s.len and (s[i] & 0xc0) == 0x80) i += 1;
    return i;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

pub fn prevWord(s: []const u8, i_in: usize) usize {
    var i = @min(i_in, s.len);
    while (i > 0 and !isWord(s[i - 1])) i -= 1;
    while (i > 0 and isWord(s[i - 1])) i -= 1;
    return i;
}

pub fn nextWord(s: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < s.len and !isWord(s[i])) i += 1;
    while (i < s.len and isWord(s[i])) i += 1;
    return i;
}

pub fn lineStart(s: []const u8, i: usize) usize {
    const at = @min(i, s.len);
    return if (std.mem.lastIndexOfScalar(u8, s[0..at], '\n')) |p| p + 1 else 0;
}

pub fn lineEnd(s: []const u8, i: usize) usize {
    const end = lineEndRaw(s, i);
    return if (end < s.len and end > 0 and s[end - 1] == '\r') end - 1 else end;
}

fn lineEndRaw(s: []const u8, i: usize) usize {
    return std.mem.indexOfScalarPos(u8, s, @min(i, s.len), '\n') orelse s.len;
}

pub const Unit = enum { char, word, line };

/// The word or line at `pos`; off a word, the character there.
pub fn unitRange(s: []const u8, pos: usize, unit: Unit) [2]usize {
    switch (unit) {
        .char => return .{ pos, pos },
        .word => {
            const r = wordAt(s, pos);
            if (r[1] > r[0]) return r;
            return .{ @min(pos, s.len), nextChar(s, pos) };
        },
        .line => {
            const end = lineEndRaw(s, pos);
            return .{ lineStart(s, pos), if (end < s.len) end + 1 else end };
        },
    }
}

/// The word around `i`, for a double click.
pub fn wordAt(s: []const u8, i_in: usize) [2]usize {
    const i = @min(i_in, s.len);
    var lo = i;
    var hi = i;
    while (lo > 0 and isWord(s[lo - 1])) lo -= 1;
    while (hi < s.len and isWord(s[hi])) hi += 1;
    return .{ lo, hi };
}
