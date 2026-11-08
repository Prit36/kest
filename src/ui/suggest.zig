//! Suggestions while typing, `{{variable}}` colouring and hover values for
//! single-line fields and the body editor. One list shows at a time, for the
//! focused field. Its keys (Up, Down, Enter, Tab, Escape) and clicks are taken
//! at the start of the frame, before tables and Send see them, and applied
//! when that field draws.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const completion = @import("../core/completion.zig");
const variables = @import("../core/variables.zig");
const TextBuffer = @import("model.zig").TextBuffer;
const Var = variables.Var;

pub const Fallback = completion.Fallback;

/// What a field suggests besides variables, and what it can look up.
pub const Context = struct {
    vars: []const Var = &.{},
    /// Shown in a hover over a variable that has no value.
    env_name: ?[]const u8 = null,
    fallback: Fallback = .none,
};

const Pending = union(enum) { none, up, down, take, dismiss, click: usize };

const State = struct {
    /// The field the list belongs to (its CUI id).
    field: c.cui_id = 0,
    shown: bool = false,
    highlight: usize = 0,
    /// Set once the field has been typed in (or Ctrl+Space): focusing a
    /// field alone shows nothing.
    typed: bool = false,
    /// Escape hides the list until the text or caret changes.
    dismissed: u64 = 0,
    pending: Pending = .none,
    rows: [completion.max_items]c.cui_id = @splat(0),
    row_count: usize = 0,
    /// The pointer moving over a row highlights it; resting there doesn't
    /// undo the keyboard's choice.
    mouse: c.cui_vec2 = .{},
};
var st: State = .{};

/// Takes the open list's keys and clicks before anything else sees them.
pub fn capture(ui: *c.cui_ctx) void {
    st.pending = .none;
    if (!st.shown or st.field == 0) return;
    if (c.kest_left_pressed(ui)) {
        const m = c.cui_mouse_pos(ui);
        for (st.rows[0..st.row_count], 0..) |id, i| {
            const r = c.cui_get_rect(ui, id);
            if (m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h) {
                st.pending = .{ .click = i };
                c.kest_consume_click(ui);
                // The press landed on no control, which drops focus: the
                // field keeps it.
                c.kest_set_focus(ui, st.field);
                return;
            }
        }
    }
    if (c.kest_get_focus(ui) != st.field) return;
    const mods = c.cui_key_mods(ui);
    if (mods & (c.CUI_MOD_PRIMARY | c.CUI_MOD_ALT) != 0) return;
    const keys = [_]struct { key: c.cui_key, act: Pending }{
        .{ .key = c.CUI_KEY_DOWN, .act = .down },
        .{ .key = c.CUI_KEY_UP, .act = .up },
        .{ .key = c.CUI_KEY_ENTER, .act = .take },
        .{ .key = c.CUI_KEY_TAB, .act = .take },
        .{ .key = c.CUI_KEY_ESCAPE, .act = .dismiss },
    };
    for (keys) |k| if (c.cui_key_pressed(ui, k.key)) {
        if (k.key == c.CUI_KEY_TAB and mods & c.CUI_MOD_SHIFT != 0) continue;
        st.pending = k.act;
        c.kest_consume_key(ui, k.key);
        return;
    };
}

/// Whether a list is open for `id` (tests, and fields that want to know).
pub fn openFor(id: c.cui_id) bool {
    return st.shown and st.field == id;
}

fn stamp(text: []const u8, caret: usize) u64 {
    var h = std.hash.Wyhash.init(caret);
    h.update(text);
    return h.final();
}

/// The colour spans for the references in `text`.
pub fn marks(text: []const u8, vars: []const Var) []c.kest_mark {
    var out: std.ArrayList(c.kest_mark) = .empty;
    var i: usize = 0;
    while (variables.nextReference(text, i)) |r| : (i = r.end) {
        out.append(w.arena.allocator(), .{ .start = @intCast(r.start), .end = @intCast(r.end), .known = @intFromBool(variables.lookup(vars, r.name) != null) }) catch break;
    }
    return out.items;
}

/// What a hover over the reference at byte `at` says, if there is one.
pub fn hoverText(text: []const u8, at: usize, ctx: Context) ?[]const u8 {
    var i: usize = 0;
    while (variables.nextReference(text, i)) |r| : (i = r.end) {
        if (at < r.start) return null;
        if (at >= r.end) continue;
        if (variables.lookup(ctx.vars, r.name)) |value| {
            const shown = if (value.len > 240) w.fmt("{s}\u{2026}", .{value[0..240]}) else value;
            return w.fmt("{s} = {s}", .{ r.name, if (value.len == 0) "(empty)" else shown });
        }
        return if (ctx.env_name) |env| w.fmt("{s} is not set in {s}", .{ r.name, env }) else w.fmt("{s} is not set: no environment selected", .{r.name});
    }
    return null;
}

/// Puts the item at `index` in place. Returns the new text and caret.
fn take(p: completion.Proposal, text: []const u8, index: usize) ?struct { text: []u8, caret: usize } {
    if (index >= p.items.len) return null;
    const done = completion.accept(w.arena.allocator(), text, p, p.items[index]) catch return null;
    st.typed = false;
    st.shown = false;
    st.highlight = 0;
    return .{ .text = done.text, .caret = done.caret };
}

/// The list's work for a focused field once it has drawn: pending keys,
/// then whether to show. Returns an edit to make, if one was taken.
fn step(ui: *c.cui_ctx, id: c.cui_id, text: []const u8, caret: usize, changed: bool, ctx: Context) union(enum) { none, list: completion.Proposal, edit: struct { text: []u8, caret: usize } } {
    if (st.field != id) st = .{ .field = id };
    if (changed) st.typed = true;
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_SPACE)) {
        c.kest_consume_key(ui, c.CUI_KEY_SPACE);
        st.typed = true;
        st.dismissed = 0;
    }
    const proposal = (completion.propose(w.arena.allocator(), text, caret, ctx.vars, ctx.fallback) catch null) orelse {
        st.shown = false;
        return .none;
    };
    if (st.highlight >= proposal.items.len) st.highlight = 0;
    if (st.shown) switch (st.pending) {
        .none => {},
        .down => st.highlight = (st.highlight + 1) % proposal.items.len,
        .up => st.highlight = if (st.highlight == 0) proposal.items.len - 1 else st.highlight - 1,
        .take => if (take(proposal, text, st.highlight)) |e| return .{ .edit = .{ .text = e.text, .caret = e.caret } },
        .click => |i| if (take(proposal, text, i)) |e| return .{ .edit = .{ .text = e.text, .caret = e.caret } },
        .dismiss => st.dismissed = stamp(text, caret),
    };
    st.pending = .none;
    st.shown = st.typed and st.dismissed != stamp(text, caret);
    return if (st.shown) .{ .list = proposal } else .none;
}

/// Draws the list under `at`.
fn list(ui: *c.cui_ctx, p: completion.Proposal, at: c.cui_vec2) void {
    // Tab takes a suggestion instead of moving on.
    c.kest_keep_tab(ui, st.field);
    const width: f32 = @min(420, @max(240, c.cui_viewport_size(ui).x - at.x - 16));
    if (!c.kest_suggest_begin(ui, "suggestions", at, width)) return;
    defer c.kest_suggest_end(ui);
    const m = c.cui_mouse_pos(ui);
    st.row_count = 0;
    for (p.items, 0..) |item, i| {
        const key = w.fmt("suggestion-{d}", .{i});
        const id = c.cui_make_id(ui, w.z(key));
        const r = c.cui_get_rect(ui, id);
        if (r.w > 0 and m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h and (m.x != st.mouse.x or m.y != st.mouse.y)) st.highlight = i;
        const selected = i == st.highlight;
        w.row(ui, .{ .id = w.z(key), .width = w.fill, .height = w.px(26), .pad_x = 8, .gap = 12, .radius = 4, .@"align" = c.CUI_ALIGN_CENTER, .bg = if (selected) w.color(c.CUI_TOKEN_ACCENT_SUBTLE) else .{} });
        w.text(ui, item.label, .{ .font = c.CUI_FONT_MONO, .size = c.KEST_TEXT_SECONDARY, .nowrap = true });
        if (item.detail.len > 0) {
            const detail = if (item.detail.len > 80) w.fmt("{s}\u{2026}", .{item.detail[0..80]}) else item.detail;
            w.text(ui, detail, .{ .size = c.KEST_TEXT_SECONDARY, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .nowrap = true, .width = w.fill, .@"align" = c.CUI_TEXT_RIGHT });
        }
        w.end(ui);
        st.rows[i] = id;
        st.row_count = i + 1;
    }
    st.mouse = m;
    w.text(ui, "Enter or Tab to insert \u{00b7} Esc to close", .{ .size = c.KEST_TEXT_CAPTION, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .width = w.fill, .nowrap = true });
}

/// After a single-line field (`key`, in the same id scope) has drawn:
/// colours its references, explains them on hover and runs its list.
/// Returns true when a suggestion was taken into `buffer`.
pub fn field(ui: *c.cui_ctx, key: [*:0]const u8, buffer: *TextBuffer, flags: c_int, ctx: Context) bool {
    const id = c.cui_make_id(ui, key);
    const text = buffer.text();
    if (std.mem.indexOf(u8, text, "{{") != null) {
        const spans = marks(text, ctx.vars);
        if (spans.len > 0) c.kest_input_marks(ui, key, spans.ptr, @intCast(spans.len));
        const at = c.kest_input_offset_at(ui, key, buffer.data.ptr);
        if (at >= 0) if (hoverText(text, @intCast(at), ctx)) |tip| c.kest_tooltip_for(ui, id, w.z(tip));
    }
    var below: c.cui_vec2 = .{};
    const caret = c.kest_input_caret(ui, key, buffer.data.ptr, &below);
    if (caret < 0) {
        if (st.field == id) {
            st = .{};
            c.kest_suggest_close(ui, "suggestions");
        }
        return false;
    }
    switch (step(ui, id, text, @intCast(caret), flags & c.CUI_CHANGED != 0, ctx)) {
        .none => c.kest_suggest_close(ui, "suggestions"),
        .list => |p| list(ui, p, below),
        .edit => |e| {
            buffer.set(e.text);
            c.kest_input_set_caret(ui, key, @intCast(e.caret));
            c.kest_suggest_close(ui, "suggestions");
            c.cui_request_redraw(ui);
            return true;
        },
    }
    return false;
}

/// The body editor's turn: `id` is its canvas, `caret` and `text` its
/// state after this frame's keys, `below` the point under the caret.
/// Returns an edit to apply when a suggestion was taken.
pub fn editor(ui: *c.cui_ctx, id: c.cui_id, focused: bool, text: []const u8, caret: usize, changed: bool, below: c.cui_vec2, ctx: Context) ?struct { start: usize, end: usize, insert: []const u8, caret: usize } {
    if (!focused) {
        if (st.field == id) {
            st = .{};
            c.kest_suggest_close(ui, "suggestions");
        }
        return null;
    }
    // Only inside `{{`: the body has no other suggestions.
    const inside = completion.variableAt(text, caret) != null;
    if (!inside) {
        if (st.field == id) {
            st.shown = false;
            st.typed = false;
        }
        c.kest_suggest_close(ui, "suggestions");
        return null;
    }
    const proposal_before = completion.propose(w.arena.allocator(), text, caret, ctx.vars, .none) catch null;
    switch (step(ui, id, text, caret, changed, ctx)) {
        .none => c.kest_suggest_close(ui, "suggestions"),
        .list => |p| list(ui, p, below),
        .edit => |e| {
            c.kest_suggest_close(ui, "suggestions");
            const p = proposal_before orelse return null;
            // The edit replaces the name; give it back as a span.
            const insert = e.text[p.start .. e.text.len - (text.len - p.end)];
            return .{ .start = p.start, .end = p.end, .insert = insert, .caret = e.caret };
        },
    }
    return null;
}
