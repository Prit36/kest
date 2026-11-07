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
    /// Bumped by each change to the text.
    version: u64 = 1,
    indexed_version: u64 = 0,
    /// A viewer's text is someone else's: indexed again when it changes.
    indexed_ptr: usize = 0,
    indexed_len: usize = 0,
    index: lines.Index = .{},
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// The caret moved or the text changed: bring the caret into view.
    reveal: bool = false,
    /// Show this byte at the next frame (a search result).
    reveal_at: ?usize = null,
    selecting: bool = false,
    /// Where Up and Down aim, as a byte column.
    goal_col: ?usize = null,
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

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *State) void {
        s.buffer.deinit();
        s.query.deinit();
        s.index.deinit(s.gpa);
        s.matches.deinit(s.gpa);
        s.clearStack(&s.undo);
        s.clearStack(&s.redo);
        s.undo.deinit(s.gpa);
        s.redo.deinit(s.gpa);
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
        s.caret = 0;
        s.anchor = s.buffer.text().len;
        s.replaceSelection(value, false);
        s.caret = 0;
        s.anchor = 0;
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
                    s.undo_bytes += t.len;
                    joined = true;
                } else |_| {}
            }
        }
        if (!joined) s.record(lo, removed, t);
        if (s.buffer.replace(lo, hi, t) != t.len) return;
        s.clearStack(&s.redo);
        s.caret = lo + t.len;
        s.anchor = s.caret;
        s.typing = typed;
        s.touched();
    }

    fn record(s: *State, lo: usize, removed: []const u8, t: []const u8) void {
        const r = s.gpa.dupe(u8, removed) catch return;
        const ins = s.gpa.dupe(u8, t) catch return s.gpa.free(r);
        const e: Edit = .{ .at = lo, .removed = r, .inserted = ins, .caret_before = s.caret, .anchor_before = s.anchor, .caret_after = lo + t.len };
        s.undo.append(s.gpa, e) catch {
            s.gpa.free(r);
            s.gpa.free(ins);
            return;
        };
        s.undo_bytes += e.size();
        // Always keeps the newest edit, however large.
        while (s.undo_bytes > undo_budget and s.undo.items.len > 1) {
            const old = s.undo.orderedRemove(0);
            s.undo_bytes -= old.size();
            s.gpa.free(old.removed);
            s.gpa.free(old.inserted);
        }
    }

    fn touched(s: *State) void {
        s.version += 1;
        s.reveal = true;
        s.goal_col = null;
    }

    pub fn undoEdit(s: *State) bool {
        const e = s.undo.pop() orelse return false;
        _ = s.buffer.replace(e.at, e.at + e.inserted.len, e.removed);
        s.undo_bytes -= e.size();
        s.redo.append(s.gpa, e) catch {
            s.gpa.free(e.removed);
            s.gpa.free(e.inserted);
        };
        s.caret = e.caret_before;
        s.anchor = e.anchor_before;
        s.typing = false;
        s.touched();
        return true;
    }

    pub fn redoEdit(s: *State) bool {
        const e = s.redo.pop() orelse return false;
        _ = s.buffer.replace(e.at, e.at + e.removed.len, e.inserted);
        s.undo.append(s.gpa, e) catch {
            s.gpa.free(e.removed);
            s.gpa.free(e.inserted);
        };
        s.undo_bytes += e.size();
        s.caret = e.caret_after;
        s.anchor = e.caret_after;
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
            .insert_tab => s.replaceSelection("  ", false),
            else => {},
        }
    }

    /// A new line at the indent of this one, one deeper after an opener.
    pub fn newline(s: *State, from: []const u8, c: usize) void {
        const start = lineStart(from, c);
        var e = start;
        while (e < c and (from[e] == ' ' or from[e] == '\t')) e += 1;
        var buf: [130]u8 = undefined;
        buf[0] = '\n';
        const n = @min(e - start, 120);
        @memcpy(buf[1..][0..n], from[start..][0..n]);
        var len = n + 1;
        if (c > 0 and (from[c - 1] == '{' or from[c - 1] == '[')) {
            buf[len] = ' ';
            buf[len + 1] = ' ';
            len += 2;
        }
        s.replaceSelection(buf[0..len], false);
    }

    /// Finds `query` again if it or the text changed.
    pub fn refreshSearch(s: *State, from: []const u8) void {
        if (s.searched_version == s.version and s.searched_ptr == @intFromPtr(from.ptr) and s.searched_len == from.len) return;
        s.research(from);
    }

    pub fn research(s: *State, from: []const u8) void {
        s.matches_truncated = search.findAll(s.gpa, from, s.query.text(), &s.matches) catch false;
        s.searched_version = s.version;
        s.searched_ptr = @intFromPtr(from.ptr);
        s.searched_len = from.len;
        if (s.match_at >= s.matches.items.len) s.match_at = 0;
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
    i -= 1;
    while (i > 0 and (s[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

pub fn nextChar(s: []const u8, i_in: usize) usize {
    var i = i_in;
    if (i >= s.len) return s.len;
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
    return std.mem.indexOfScalarPos(u8, s, @min(i, s.len), '\n') orelse s.len;
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
