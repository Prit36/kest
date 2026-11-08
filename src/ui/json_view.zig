//! The JSON response viewer: formatted JSON that folds. Each row is a node
//! of `json_tree.Tree` written as formatted JSON. A collapsed container says
//! how many children it holds, a long string opens in place, and a search
//! highlights or filters by text or JSONPath. Painting and hit testing visit
//! only the rows on screen.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const json_tree = @import("../core/json_tree.zig");
const json_path = @import("../core/json_path.zig");
const Tree = json_tree.Tree;
const State = @import("json_state.zig").State;
const App = @import("../app/state.zig").App;
const Tab = @import("../app/tab.zig").Tab;
const editor = @import("editor.zig");

pub const canvas_id = "json-rows";
const line_h: f32 = 20;
const pad_y: f32 = 6;
/// Room left of the root's text for its fold arrow.
const pad_x: f32 = 26;
const bar: f32 = 12;
const size: f32 = 13;
/// Strings shown whole at once, and how much of each.
const open_limit = 32;
const card_delay = 0.45;
const card_lines = 16;

const Extra = struct { row: usize, lines: u32 };

/// Where rows go. Rows are one line tall, except strings shown whole.
const Geo = struct {
    rect: c.cui_rect,
    char_w: f32,
    indent: f32,
    rows: usize,
    /// Rows taller than a line, in row order.
    extras: []const Extra,
    scroll_y: f32,

    fn right(g: Geo) f32 {
        return g.rect.x + g.rect.w - bar - 6;
    }
    fn textX(g: Geo, depth: u16) f32 {
        return g.rect.x + pad_x + @as(f32, @floatFromInt(@min(depth, 48))) * g.indent;
    }
    fn total(g: Geo) f32 {
        var sum = pad_y * 2 + @as(f32, @floatFromInt(g.rows)) * line_h;
        for (g.extras) |e| sum += @as(f32, @floatFromInt(e.lines - 1)) * line_h;
        return sum;
    }
    fn maxScroll(g: Geo) f32 {
        return @max(0, g.total() - g.rect.h);
    }
    /// The top of `row` before scrolling.
    fn top(g: Geo, row: usize) f32 {
        var y = pad_y + @as(f32, @floatFromInt(row)) * line_h;
        for (g.extras) |e| {
            if (e.row >= row) break;
            y += @as(f32, @floatFromInt(e.lines - 1)) * line_h;
        }
        return y;
    }
    fn screenTop(g: Geo, row: usize) f32 {
        return g.rect.y + g.top(row) - g.scroll_y;
    }
    fn lines(g: Geo, row: usize) u32 {
        for (g.extras) |e| if (e.row == row) return e.lines;
        return 1;
    }
    /// The row at `y` before scrolling, if one is there.
    fn rowAt(g: Geo, y: f32) ?usize {
        if (y < pad_y or g.rows == 0) return null;
        var base_y = pad_y;
        var base_row: usize = 0;
        for (g.extras) |e| {
            const start = base_y + @as(f32, @floatFromInt(e.row - base_row)) * line_h;
            if (y < start) break;
            const end = start + @as(f32, @floatFromInt(e.lines)) * line_h;
            if (y < end) return e.row;
            base_y = end;
            base_row = e.row + 1;
        }
        const row = base_row + @as(usize, @intFromFloat(@floor((y - base_y) / line_h)));
        return if (row < g.rows) row else null;
    }
    const Thumb = struct { track: c.cui_rect, thumb: c.cui_rect };
    fn scrollbar(g: Geo) ?Thumb {
        const max = g.maxScroll();
        if (max <= 0) return null;
        const track: c.cui_rect = .{ .x = g.rect.x + g.rect.w - bar, .y = g.rect.y + 4, .w = bar, .h = @max(1, g.rect.h - 8) };
        const h = @min(track.h, @max(24, track.h * g.rect.h / g.total()));
        return .{ .track = track, .thumb = .{ .x = track.x + 3, .y = track.y + g.scroll_y / max * (track.h - h), .w = 6, .h = h } };
    }
};

fn advance(ui: *c.cui_ctx, cw: f32, text: []const u8) f32 {
    for (text) |b| if (b >= 0x80) return c.cui_measure_text(ui, c.CUI_FONT_MONO, size, text.ptr, @intCast(text.len)).width;
    return cw * @as(f32, @floatFromInt(text.len));
}

/// How many bytes of `text` fit in `room`, in whole characters.
fn fit(ui: *c.cui_ctx, cw: f32, text: []const u8, room: f32) usize {
    var x: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(text.len, i + len);
        const advance_by = if (text[i] < 0x80) cw else c.cui_measure_text(ui, c.CUI_FONT_MONO, size, text[i..end].ptr, @intCast(end - i)).width;
        if (x + advance_by > room) return i;
        x += advance_by;
        i = end;
    }
    return text.len;
}

/// A string shown whole, cut into lines that fit `room`; at least one
/// character per line.
fn nextLine(ui: *c.cui_ctx, cw: f32, text: []const u8, room: f32) usize {
    const n = fit(ui, cw, text, room);
    if (n > 0 or text.len == 0) return n;
    return @min(text.len, std.unicode.utf8ByteSequenceLength(text[0]) catch 1);
}

fn countLines(ui: *c.cui_ctx, cw: f32, text: []const u8, room: f32) u32 {
    var rest = text;
    var count: u32 = 0;
    while (rest.len > 0) : (count += 1) rest = rest[nextLine(ui, cw, rest, room)..];
    return @max(1, count);
}

/// One row, measured: what is drawn where.
const Parts = struct {
    x: f32,
    value_x: f32,
    /// The value's first line as drawn.
    shown: []const u8 = "",
    value_end: f32,
    /// A string too long for its line.
    long: bool = false,
    open: bool = false,
    chip: ?c.cui_rect = null,
    hidden: usize = 0,
    lines: u32 = 1,
};

fn chipLabel(hidden: usize) [:0]const u8 {
    return w.fmt("{d} more", .{hidden});
}
fn chipWidth(ui: *c.cui_ctx, label: []const u8) f32 {
    return c.cui_measure_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_CAPTION, label.ptr, @intCast(label.len)).width + 12;
}

fn measure(ui: *c.cui_ctx, g: Geo, tr: *const Tree, s: *const State, node: u32) Parts {
    const n = tr.nodes.items[node];
    const x = g.textX(n.depth);
    const key = tr.key(node);
    const value_x = if (key.len > 0) x + advance(ui, g.char_w, key) + 2 * g.char_w else x;
    var p: Parts = .{ .x = x, .value_x = value_x, .value_end = value_x };
    if (n.kind == .close or tr.isContainer(node)) return p;
    const full = tr.value(node);
    const comma: f32 = if (n.comma) g.char_w else 0;
    const room = g.right() - value_x - comma;
    const whole = advance(ui, g.char_w, full[0..@min(full.len, 4096)]);
    if (n.kind != .string or (full.len <= 4096 and whole <= room)) {
        p.shown = full;
        p.value_end = value_x + whole;
        return p;
    }
    p.long = true;
    if (s.isOpenString(node)) {
        p.open = true;
        const line_room = g.right() - value_x;
        p.lines = countLines(ui, g.char_w, full, line_room);
        p.shown = full[0..nextLine(ui, g.char_w, full, line_room)];
        p.value_end = value_x + advance(ui, g.char_w, p.shown);
        return p;
    }
    // The start, an ellipsis, and a chip saying how much more there is.
    const guess = fit(ui, g.char_w, full, @max(0, room));
    p.hidden = std.unicode.utf8CountCodepoints(full[guess..]) catch full.len - guess;
    const chip_w = chipWidth(ui, chipLabel(p.hidden));
    const cut = fit(ui, g.char_w, full, @max(0, room - chip_w - g.char_w - 6));
    p.hidden = std.unicode.utf8CountCodepoints(full[cut..]) catch full.len - cut;
    p.shown = full[0..cut];
    p.value_end = value_x + advance(ui, g.char_w, p.shown) + g.char_w;
    p.chip = .{ .x = p.value_end + 4, .y = 0, .w = chipWidth(ui, chipLabel(p.hidden)), .h = 16 };
    return p;
}

fn geometry(ui: *c.cui_ctx, tr: *const Tree, s: *const State, rect: c.cui_rect, cw: f32) Geo {
    var g: Geo = .{ .rect = rect, .char_w = cw, .indent = 2 * cw, .rows = tr.rows.items.len, .extras = &.{}, .scroll_y = s.scroll_y };
    if (s.open_strings.items.len == 0 or rect.w <= 0) return g;
    var extras: std.ArrayList(Extra) = .empty;
    for (s.open_strings.items) |node| {
        const row = tr.rowOf(node) orelse continue;
        const parts = measure(ui, g, tr, s, node);
        if (parts.lines > 1) extras.append(w.arena.allocator(), .{ .row = row, .lines = parts.lines }) catch break;
    }
    g.extras = extras.items;
    return g;
}

const Zone = enum { arrow, chip, value, row, scrollbar };
const Target = struct { node: u32 = 0, row: usize = 0, zone: Zone, long: bool = false, open: bool = false };

fn hitTest(ui: *c.cui_ctx, g: Geo, tr: *const Tree, s: *const State, mouse: c.cui_vec2) ?Target {
    if (g.scrollbar()) |sb| if (inside(sb.track, mouse)) return .{ .zone = .scrollbar };
    const row = g.rowAt(mouse.y - g.rect.y + g.scroll_y) orelse return null;
    const node = tr.rows.items[row];
    const n = tr.nodes.items[node];
    const parts = measure(ui, g, tr, s, node);
    var target: Target = .{ .node = node, .row = row, .zone = .row, .long = parts.long, .open = parts.open };
    if (tr.isContainer(node) and tr.childCount(node) > 0 and n.kind != .close and mouse.x >= parts.x - 22 and mouse.x < parts.x - 2) {
        target.zone = .arrow;
    } else if (parts.chip) |chip| {
        const y = g.screenTop(row) + 2;
        if (inside(.{ .x = chip.x, .y = y, .w = chip.w, .h = chip.h }, mouse)) target.zone = .chip;
    }
    if (target.zone == .row and mouse.x >= parts.value_x and (mouse.x < parts.value_end or parts.open)) target.zone = .value;
    return target;
}

fn inside(r: c.cui_rect, m: c.cui_vec2) bool {
    return m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h;
}

fn select(s: *State, node: u32, reveal: bool) void {
    s.selected = node;
    if (reveal) s.reveal = true;
}

/// A new tree (a new response): open it to the chosen depth.
fn adopt(app: *App, tr: *Tree, s: *State) void {
    const owner = @intFromPtr(tr.nodes.items.ptr) +% tr.nodes.items.len;
    if (s.owner == owner) return;
    s.reset(app.gpa);
    s.owner = owner;
    if (app.prefs.json_depth > 0) tr.setLevel(app.gpa, app.prefs.json_depth) catch {};
}

/// Opens the search bar over the JSON viewer.
pub fn openFind(s: *State) void {
    s.find_open = true;
    s.query.focus();
}

fn closeFind(ui: *c.cui_ctx, app: *App, tr: *Tree, s: *State) void {
    s.find_open = false;
    clearSearch(app, tr, s);
    c.kest_focus(ui, canvas_id);
}

fn clearSearch(app: *App, tr: *Tree, s: *State) void {
    s.searched.clearRetainingCapacity();
    s.searched_owner = 0;
    s.problem = "";
    if (tr.hits.items.len > 0) tr.setHits(app.gpa, &.{}) catch {};
    if (tr.filtered) tr.setFiltered(app.gpa, false) catch {};
}

fn research(app: *App, tr: *Tree, s: *State) void {
    const q = s.query.text();
    if (s.searched_owner == s.owner and s.searched_case == s.case_sensitive and std.mem.eql(u8, s.searched.items, q)) return;
    s.searched.clearRetainingCapacity();
    s.searched.appendSlice(app.gpa, q) catch {};
    s.searched_case = s.case_sensitive;
    s.searched_owner = s.owner;
    s.problem = "";
    var found: []u32 = &.{};
    var owned = false;
    defer if (owned) app.gpa.free(found);
    if (q.len > 0) {
        if (json_path.isPath(q)) {
            var problem: json_path.Problem = .{};
            if (json_path.evaluate(app.gpa, tr, q, &problem)) |list| {
                found = list;
                owned = true;
            } else |err| if (err == error.InvalidPath) {
                s.problem = problem.message;
                s.problem_at = problem.at;
            }
        } else if (tr.findText(app.gpa, q, s.case_sensitive)) |list| {
            found = list;
            owned = true;
        } else |_| {}
    }
    tr.setHits(app.gpa, found) catch {};
    s.hit_at = 0;
    const hits = tr.hits.items;
    if (hits.len == 0) return;
    // The first hit at or after the selection.
    if (s.selected) |selected| {
        s.hit_at = std.sort.lowerBound(u32, hits, selected, order);
        if (s.hit_at >= hits.len) s.hit_at = 0;
    }
    select(s, hits[s.hit_at], true);
}

fn order(want: u32, item: u32) std.math.Order {
    return std.math.order(want, item);
}

fn step(tr: *const Tree, s: *State, delta: i32) void {
    const hits = tr.hits.items;
    if (hits.len == 0) return;
    s.hit_at = @intCast(@mod(@as(i64, @intCast(s.hit_at)) + delta, @as(i64, @intCast(hits.len))));
    select(s, hits[s.hit_at], true);
}

fn caption(tr: *const Tree, s: *const State) []const u8 {
    if (s.problem.len > 0) return "Invalid path";
    if (s.query.text().len == 0) return "";
    if (tr.hits.items.len == 0) return "No matches";
    return w.fmt("{d} / {d}", .{ s.hit_at + 1, tr.hits.items.len });
}

fn smallIcon(ui: *c.cui_ctx, key: [*:0]const u8, glyph: [*:0]const u8, hint: [*:0]const u8) bool {
    w.row(ui, .{ .id = key, .width = w.px(28), .height = w.px(28) });
    defer w.end(ui);
    return w.icon(ui, glyph, hint);
}

fn findBar(ui: *c.cui_ctx, app: *App, tr: *Tree, s: *State) void {
    const select_query = s.query.want_focus;
    const query_focus = c.kest_editor_focus(ui, c.cui_make_id(ui, "json-find")) != 0;
    w.column(ui, .{ .id = "json-search", .width = w.fill, .pad_x = 8, .pad_y = 6, .gap = 4 });
    w.row(ui, .{ .width = w.fill, .gap = 4, .@"align" = c.CUI_ALIGN_CENTER });
    _ = s.query.reserve(512);
    _ = w.field(ui, "json-find", &s.query, .{ .placeholder = "Find text, or filter with $.path", .width = w.fill, .size = c.CUI_SIZE_SM });
    if (select_query) c.kest_input_select_all(ui, "json-find", @intCast(s.query.text().len));
    if (w.action(ui, "json-find-case", "Aa", null, s.case_sensitive, 28, 28, 0)) s.case_sensitive = !s.case_sensitive;
    c.kest_tooltip(ui, "Match case");
    if (w.action(ui, "json-find-filter", "", c.CUI_ICON_FILTER, s.filter, 28, 28, 0)) s.filter = !s.filter;
    c.kest_tooltip(ui, "Show only matches");
    research(app, tr, s);
    w.text(ui, caption(tr, s), .{ .width = w.px(80), .size = c.KEST_TEXT_CAPTION, .nowrap = true, .color = w.color(if (s.problem.len > 0) c.CUI_TOKEN_DANGER else c.CUI_TOKEN_TEXT_SECONDARY) });
    c.cui_push_disabled(ui, tr.hits.items.len == 0);
    if (smallIcon(ui, "json-find-prev", c.CUI_ICON_CHEVRON_UP, "Previous match (Shift+Enter)")) step(tr, s, -1);
    if (smallIcon(ui, "json-find-next", c.CUI_ICON_CHEVRON_DOWN, "Next match (Enter)")) step(tr, s, 1);
    c.cui_pop_disabled(ui);
    var close = smallIcon(ui, "json-find-close", c.CUI_ICON_X, "Close search (Escape)");
    w.end(ui);
    if (s.problem.len > 0) w.text(ui, w.fmt("{s} at character {d}", .{ s.problem, s.problem_at + 1 }), .{ .width = w.fill, .size = c.KEST_TEXT_CAPTION, .color = w.color(c.CUI_TOKEN_DANGER) });
    w.end(ui);
    const within = query_focus or c.kest_focus_within(ui, "json-search");
    if (within) {
        const mods = c.cui_key_mods(ui);
        if ((query_focus and c.cui_key_pressed(ui, c.CUI_KEY_ENTER) and mods & c.CUI_MOD_PRIMARY == 0) or c.cui_key_pressed(ui, c.CUI_KEY_F3)) step(tr, s, if (mods & c.CUI_MOD_SHIFT != 0) -1 else 1);
        if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) close = true;
    }
    if (close) closeFind(ui, app, tr, s);
}

/// The row to move from: the selection's, or the nearest one shown.
fn currentRow(tr: *const Tree, s: *const State) usize {
    const selected = s.selected orelse return 0;
    if (tr.rowOf(selected)) |row| return row;
    return @min(tr.rows.items.len - 1, std.sort.lowerBound(u32, tr.rows.items, selected, order) -| 1);
}

/// The nearest row at or past `row` (`dir` 1) or before it (-1) that isn't
/// a closing bracket.
fn landing(tr: *const Tree, row_in: usize, dir: i2) usize {
    const rows = tr.rows.items;
    var row = @min(row_in, rows.len - 1);
    while (tr.nodes.items[rows[row]].kind == .close) {
        if (dir > 0) {
            if (row + 1 >= rows.len) return landing(tr, row, -1);
            row += 1;
        } else {
            if (row == 0) return 0;
            row -= 1;
        }
    }
    return row;
}

fn toggleNode(app: *App, tr: *Tree, s: *State, node: u32) void {
    if (tr.isContainer(node)) {
        if (tr.childCount(node) > 0) tr.toggle(app.gpa, node) catch {};
    } else s.toggleString(app.gpa, node, open_limit);
}

fn keys(ui: *c.cui_ctx, app: *App, tr: *Tree, s: *State, g: Geo, parts_of: anytype) void {
    if (tr.rows.items.len == 0) return;
    const mods = c.cui_key_mods(ui);
    const row = currentRow(tr, s);
    const node = tr.rows.items[row];
    const page: usize = @intFromFloat(@max(1, @floor(g.rect.h / line_h) - 1));
    var next: ?usize = null;
    if (c.cui_key_pressed(ui, c.CUI_KEY_DOWN)) next = if (s.selected == null) 0 else landing(tr, row + 1, 1);
    if (c.cui_key_pressed(ui, c.CUI_KEY_UP)) next = landing(tr, row -| 1, -1);
    if (c.cui_key_pressed(ui, c.CUI_KEY_PAGE_DOWN)) next = landing(tr, row + page, 1);
    if (c.cui_key_pressed(ui, c.CUI_KEY_PAGE_UP)) next = landing(tr, row -| page, -1);
    if (c.cui_key_pressed(ui, c.CUI_KEY_HOME)) next = 0;
    if (c.cui_key_pressed(ui, c.CUI_KEY_END)) next = landing(tr, tr.rows.items.len - 1, -1);
    const parts: Parts = parts_of.of(node);
    if (c.cui_key_pressed(ui, c.CUI_KEY_RIGHT)) {
        if (tr.isContainer(node) and tr.nodes.items[node].kind != .close) {
            if (!tr.isOpen(node)) toggleNode(app, tr, s, node) else if (tr.childCount(node) > 0) next = row + 1;
        } else if (parts.long and !parts.open) s.toggleString(app.gpa, node, open_limit);
    }
    if (c.cui_key_pressed(ui, c.CUI_KEY_LEFT)) {
        if (tr.isContainer(node) and tr.isOpen(node) and !tr.isHeld(node) and tr.childCount(node) > 0) {
            tr.toggle(app.gpa, node) catch {};
        } else if (parts.open) {
            s.toggleString(app.gpa, node, open_limit);
        } else {
            // From a closing bracket or a child, to the container.
            const up = if (tr.nodes.items[node].kind == .close) parentOfClose(tr, node) else tr.parentOf(node);
            if (up) |parent| if (tr.rowOf(parent)) |r| {
                next = r;
            };
        }
    }
    if (c.cui_key_pressed(ui, c.CUI_KEY_ENTER) or c.cui_key_pressed(ui, c.CUI_KEY_SPACE)) {
        if (s.selected == null) next = 0 else if (tr.isContainer(node) or parts.long) toggleNode(app, tr, s, node);
    }
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY, c.CUI_KEY_C)) copyValue(ui, tr, node);
    if (c.cui_shortcut(ui, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT, c.CUI_KEY_C)) w.copy(ui, tr.path(w.arena.allocator(), node) catch "");
    if (mods & c.CUI_MOD_ALT != 0) levelKeys(ui, app, tr);
    if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE) and s.find_open) closeFind(ui, app, tr, s);
    if (next) |r| select(s, tr.rows.items[@min(r, tr.rows.items.len - 1)], true);
}

fn levelKeys(ui: *c.cui_ctx, app: *App, tr: *Tree) void {
    const digits = [_]c_int{ c.CUI_KEY_0, c.CUI_KEY_1, c.CUI_KEY_2, c.CUI_KEY_3, c.CUI_KEY_4, c.CUI_KEY_5, c.CUI_KEY_6, c.CUI_KEY_7, c.CUI_KEY_8, c.CUI_KEY_9 };
    for (digits, 0..) |key, level| if (c.cui_shortcut(ui, c.CUI_MOD_ALT, @intCast(key))) {
        tr.setLevel(app.gpa, if (level == 0) std.math.maxInt(u16) else @intCast(level)) catch {};
    };
}

/// The container a closing bracket ends.
fn parentOfClose(tr: *const Tree, close: u32) ?u32 {
    const depth = tr.nodes.items[close].depth;
    var j = close;
    while (j > 0) {
        j -= 1;
        const n = tr.nodes.items[j];
        if (n.depth == depth and n.kind != .close and tr.isContainer(j)) return j;
    }
    return null;
}

fn copyValue(ui: *c.cui_ctx, tr: *const Tree, node: u32) void {
    if (tr.nodes.items[node].kind == .close) return;
    w.copy(ui, tr.plainValue(w.arena.allocator(), node) catch tr.sourceOf(node));
}

fn menu(ui: *c.cui_ctx, app: *App, tr: *Tree, s: *State, anchor: c.cui_id, long: bool, open: bool) void {
    if (!c.kest_context_menu_begin(ui, "json-menu", anchor)) return;
    defer c.cui_context_menu_end(ui);
    if (s.selected) |node| if (tr.nodes.items[node].kind != .close) {
        const key = tr.key(node);
        const string = tr.nodes.items[node].kind == .string;
        if (c.cui_menu_item_ex(ui, "Copy value", &.{ .shortcut = "Ctrl C" })) copyValue(ui, tr, node);
        if (string and w.menuItem(ui, "Copy as JSON")) w.copy(ui, tr.sourceOf(node));
        if (key.len >= 2 and w.menuItem(ui, "Copy key")) w.copy(ui, json_tree.unescape(w.arena.allocator(), key) catch tr.innerKey(node));
        if (c.cui_menu_item_ex(ui, "Copy path", &.{ .shortcut = "Ctrl Shift C" })) w.copy(ui, tr.path(w.arena.allocator(), node) catch "");
        if (long and w.menuItem(ui, if (open) "Shorten string" else "Show whole string")) s.toggleString(app.gpa, node, open_limit);
        if (tr.isContainer(node) and tr.childCount(node) > 0) {
            c.cui_menu_separator(ui);
            if (w.menuItem(ui, "Expand children")) tr.setSubtree(app.gpa, node, false) catch {};
            if (w.menuItem(ui, "Collapse children")) tr.setSubtree(app.gpa, node, true) catch {};
        }
        c.cui_menu_separator(ui);
    };
    levelItems(ui, app, tr);
    c.cui_menu_separator(ui);
    if (c.cui_menu_item_ex(ui, "Find in JSON", &.{ .shortcut = "Ctrl F" })) openFind(s);
}

/// Expand all, Collapse all and levels between, for menus.
pub fn levelItems(ui: *c.cui_ctx, app: *App, tr: *Tree) void {
    if (c.cui_menu_item_ex(ui, "Expand all", &.{ .shortcut = "Alt 0" })) tr.setAll(app.gpa, false) catch {};
    if (c.cui_menu_item_ex(ui, "Collapse all", &.{ .shortcut = "Alt 1" })) tr.setAll(app.gpa, true) catch {};
    if (tr.max_depth >= 2 and c.cui_menu_item_ex(ui, "Expand to level 2", &.{ .shortcut = "Alt 2" })) tr.setLevel(app.gpa, 2) catch {};
    if (tr.max_depth >= 3 and c.cui_menu_item_ex(ui, "Expand to level 3", &.{ .shortcut = "Alt 3" })) tr.setLevel(app.gpa, 3) catch {};
}

const PartsOf = struct {
    ui: *c.cui_ctx,
    g: Geo,
    tr: *const Tree,
    s: *const State,
    fn of(p: PartsOf, node: u32) Parts {
        return measure(p.ui, p.g, p.tr, p.s, node);
    }
};

const Card = struct { node: u32, row: usize, mouse: c.cui_vec2 };
const Paint = struct {
    tree: *const Tree,
    state: *const State,
    geo: Geo,
    focused: bool,
    hover_row: ?usize,
    card: ?Card,
    /// Plain text to highlight; empty for a JSONPath.
    query: []const u8,
    case_sensitive: bool,
};

pub fn view(ui: *c.cui_ctx, app: *App, t: *Tab, tr: *Tree) void {
    const s = &t.response.json;
    adopt(app, tr, s);
    if (s.find_open) findBar(ui, app, tr, s) else if (tr.hits.items.len > 0 or tr.filtered) clearSearch(app, tr, s);
    const filter = s.find_open and s.filter and s.query.text().len > 0 and s.problem.len == 0;
    if (tr.filtered != filter) tr.setFiltered(app.gpa, filter) catch {};
    const identity = c.cui_make_id(ui, canvas_id);
    const prev = c.cui_get_rect(ui, identity);
    const cw = editor.cellWidth(ui);
    // Input is read against last frame's layout, which is what's on screen.
    const before = geometry(ui, tr, s, prev, cw);
    const focused = c.kest_editor_focus(ui, identity) != 0;
    const mouse = c.cui_mouse_pos(ui);
    const over = prev.w > 0 and c.kest_pointer_over(ui, identity);
    const target = if (over) hitTest(ui, before, tr, s, mouse) else null;
    var long = false;
    var open = false;
    if (c.kest_right_pressed(ui, identity)) if (target) |hit| if (hit.zone != .scrollbar) select(s, hit.node, false);
    if (s.selected) |node| if (tr.rowOf(node) != null) {
        const parts = measure(ui, before, tr, s, node);
        long = parts.long;
        open = parts.open;
    };
    menu(ui, app, tr, s, identity, long, open);
    if (over and c.kest_left_pressed(ui)) if (target) |hit| press(ui, app, tr, s, before, hit, mouse);
    if (s.dragging) {
        if (!c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT)) {
            s.dragging = false;
        } else if (before.scrollbar()) |sb| {
            s.scroll_y = std.math.clamp((mouse.y - sb.track.y - s.drag_offset) / @max(1, sb.track.h - sb.thumb.h), 0, 1) * before.maxScroll();
        }
    }
    if (focused and !s.dragging) keys(ui, app, tr, s, before, PartsOf{ .ui = ui, .g = before, .tr = tr, .s = s });
    const wheel = c.kest_editor_scroll_axes(ui, identity);
    s.scroll_y -= wheel.y * line_h * 3;
    // A selection out of sight, maybe inside collapsed containers.
    if (s.reveal) if (s.selected) |node| if (tr.rowOf(node) == null and !tr.filtered) tr.reveal(app.gpa, node) catch {};
    var g = geometry(ui, tr, s, prev, cw);
    if (s.reveal) {
        if (s.selected) |node| if (tr.rowOf(node)) |row| {
            const top = g.top(row);
            const bottom = top + @as(f32, @floatFromInt(g.lines(row))) * line_h;
            if (top - pad_y < s.scroll_y) s.scroll_y = top - pad_y;
            if (bottom + pad_y > s.scroll_y + prev.h and prev.h > 0) s.scroll_y = @min(top - pad_y, bottom + pad_y - prev.h);
        };
        s.reveal = false;
    }
    s.scroll_y = std.math.clamp(s.scroll_y, 0, g.maxScroll());
    g.scroll_y = s.scroll_y;
    const card = hoverCard(ui, tr, s, target, over, mouse);
    const query = s.query.text();
    const paint: Paint = .{
        .tree = tr,
        .state = s,
        .geo = g,
        .focused = focused,
        .hover_row = if (target) |hit| (if (hit.zone != .scrollbar and !s.dragging) hit.row else null) else null,
        .card = card,
        .query = if (s.find_open and !json_path.isPath(query)) query else "",
        .case_sensitive = s.case_sensitive,
    };
    _ = c.cui_canvas(ui, canvas_id, w.fill, w.fill, draw, &paint, @sizeOf(Paint));
    c.kest_editor_register(ui, identity);
    c.kest_editor_tabs(ui, identity, 0);
    footer(ui, app, tr, s);
}

fn press(ui: *c.cui_ctx, app: *App, tr: *Tree, s: *State, g: Geo, hit: Target, mouse: c.cui_vec2) void {
    if (hit.zone == .scrollbar) {
        const sb = g.scrollbar() orelse return;
        s.dragging = true;
        s.drag_offset = if (inside(sb.thumb, mouse)) mouse.y - sb.thumb.y else sb.thumb.h / 2;
        return;
    }
    select(s, hit.node, false);
    switch (hit.zone) {
        .arrow => toggleNode(app, tr, s, hit.node),
        .chip => s.toggleString(app.gpa, hit.node, open_limit),
        else => if (c.kest_click_count(ui) >= 2 and (tr.isContainer(hit.node) or hit.long)) toggleNode(app, tr, s, hit.node),
    }
}

/// A shortened string's whole text, after the pointer rests on it.
fn hoverCard(ui: *c.cui_ctx, tr: *const Tree, s: *State, target: ?Target, over: bool, mouse: c.cui_vec2) ?Card {
    const hit = target orelse {
        s.hover = null;
        return null;
    };
    if (!over or hit.zone != .value or !hit.long or hit.open or c.cui_mouse_down(ui, c.CUI_MOUSE_LEFT) or tr.nodes.items[hit.node].kind != .string) {
        s.hover = null;
        return null;
    }
    const now = c.cui_time(ui);
    if (s.hover != hit.node) {
        s.hover = hit.node;
        s.hover_since = now;
    }
    const waited: f32 = @floatCast(now - s.hover_since);
    if (waited < card_delay) {
        c.kest_wake_after(ui, card_delay - waited + 0.02);
        return null;
    }
    return .{ .node = hit.node, .row = hit.row, .mouse = mouse };
}

fn footer(ui: *c.cui_ctx, app: *App, tr: *const Tree, s: *State) void {
    const node = s.selected orelse return;
    if (node >= tr.nodes.items.len or tr.nodes.items[node].kind == .close) return;
    if (s.path_of != node) {
        s.path.clearRetainingCapacity();
        if (tr.path(app.gpa, node)) |text| {
            defer app.gpa.free(text);
            s.path.appendSlice(app.gpa, text) catch {};
        } else |_| {}
        s.path_of = node;
    }
    const n = tr.nodes.items[node];
    const about = switch (n.kind) {
        .object => w.fmt("object · {d} {s}", .{ tr.childCount(node), if (tr.childCount(node) == 1) "key" else "keys" }),
        .array => w.fmt("array · {d} {s}", .{ tr.childCount(node), if (tr.childCount(node) == 1) "item" else "items" }),
        .string => w.fmt("string · {d} chars", .{std.unicode.utf8CountCodepoints(tr.innerValue(node)) catch tr.innerValue(node).len}),
        .number => "number",
        .boolean => "boolean",
        else => "null",
    };
    w.row(ui, .{ .id = "json-footer", .width = w.fill, .pad_x = 12, .pad_y = 3, .gap = 12, .@"align" = c.CUI_ALIGN_CENTER, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED) });
    w.text(ui, s.path.items, .{ .width = w.fill, .font = c.CUI_FONT_MONO, .size = c.KEST_TEXT_CAPTION, .nowrap = true, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.text(ui, about, .{ .size = c.KEST_TEXT_CAPTION, .nowrap = true, .color = w.color(c.CUI_TOKEN_TEXT_MUTED) });
    w.end(ui);
}

fn summary(tr: *const Tree, node: u32) []const u8 {
    const count = tr.childCount(node);
    return if (tr.nodes.items[node].kind == .object)
        w.fmt("{d} {s}", .{ count, if (count == 1) "key" else "keys" })
    else
        w.fmt("{d} {s}", .{ count, if (count == 1) "item" else "items" });
}

fn put(ui: *c.cui_ctx, x: f32, y: f32, value: []const u8, tint: c.cui_color) void {
    if (value.len == 0) return;
    c.cui_draw_text(ui, c.CUI_FONT_MONO, size, .{ .x = x, .y = y }, tint, value.ptr, @intCast(value.len));
}

/// Marks where the search text is within `value`, drawn at `x`.
fn mark(ui: *c.cui_ctx, p: *const Paint, x: f32, y: f32, value: []const u8) void {
    if (p.query.len == 0) return;
    var from: usize = 0;
    while (from < value.len) {
        const at = from + (json_tree.locate(value[from..], p.query, p.case_sensitive) orelse return);
        const x0 = x + advance(ui, p.geo.char_w, value[0..at]);
        const x1 = x0 + advance(ui, p.geo.char_w, value[at .. at + p.query.len]);
        c.cui_draw_rect(ui, .{ .x = x0, .y = y, .w = x1 - x0, .h = line_h }, .{}, w.tinted(ui, c.CUI_TOKEN_WARNING, 0.3));
        from = at + p.query.len;
    }
}

fn valueTint(ui: *c.cui_ctx, kind: json_tree.Kind) c.cui_color {
    return switch (kind) {
        .string => w.design.syntax(ui, .string),
        .number => w.design.syntax(ui, .number),
        .boolean, .null_ => w.design.syntax(ui, .keyword),
        else => w.color(c.CUI_TOKEN_FOREGROUND),
    };
}

fn draw(raw_ui: ?*c.cui_ctx, rect: c.cui_rect, raw: ?*anyopaque) callconv(.c) void {
    const ui = raw_ui.?;
    const p: *const Paint = @ptrCast(@alignCast(raw.?));
    var g = p.geo;
    g.rect = rect;
    const tr = p.tree;
    c.cui_push_clip(ui, rect);
    defer c.cui_pop_clip(ui);
    c.cui_draw_rect(ui, rect, .{}, w.color(c.CUI_TOKEN_SURFACE));
    const hairline = 1 / @max(1, c.cui_dpi_scale(ui));
    if (p.focused) c.cui_draw_line(ui, .{ .x = rect.x, .y = rect.y + 0.5 }, .{ .x = rect.x + rect.w, .y = rect.y + 0.5 }, hairline, w.color(c.CUI_TOKEN_FOCUS_RING));
    if (tr.rows.items.len == 0) {
        const label = "No matches";
        c.cui_draw_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_SECONDARY, .{ .x = rect.x + pad_x, .y = rect.y + pad_y + 2 }, w.color(c.CUI_TOKEN_TEXT_SECONDARY), label.ptr, @intCast(label.len));
        return;
    }
    var row = g.rowAt(g.scroll_y) orelse 0;
    while (row < tr.rows.items.len and g.screenTop(row) < rect.y + rect.h) : (row += 1) drawRow(ui, p, g, row);
    if (g.scrollbar()) |sb| c.cui_draw_rect(ui, sb.thumb, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_BORDER_STRONG));
    if (p.card) |card| drawCard(ui, p, g, card);
}

fn drawRow(ui: *c.cui_ctx, p: *const Paint, g: Geo, row: usize) void {
    const tr = p.tree;
    const s = p.state;
    const node = tr.rows.items[row];
    const n = tr.nodes.items[node];
    const y = g.screenTop(row);
    const lines = g.lines(row);
    const height = @as(f32, @floatFromInt(lines)) * line_h;
    const band: c.cui_rect = .{ .x = g.rect.x, .y = y, .w = g.rect.w - bar, .h = height };
    const fg = w.color(c.CUI_TOKEN_FOREGROUND);
    const cw = g.char_w;
    if (s.selected == node) {
        c.cui_draw_rect(ui, band, .{}, if (p.focused) w.color(c.CUI_TOKEN_ACCENT_SUBTLE) else w.color(c.CUI_TOKEN_SURFACE_MUTED));
    } else if (tr.hits.items.len > 0 and p.query.len == 0 and tr.hit_set.isSet(node)) {
        // JSONPath results are whole rows.
        const current = tr.hits.items[@min(s.hit_at, tr.hits.items.len - 1)] == node;
        c.cui_draw_rect(ui, band, .{}, w.tinted(ui, c.CUI_TOKEN_WARNING, if (current) 0.22 else 0.12));
    } else if (p.hover_row == row) {
        c.cui_draw_rect(ui, band, .{}, w.tinted(ui, c.CUI_TOKEN_FOREGROUND, 0.04));
    }
    // Indent guides, one per containing level.
    for (0..@min(n.depth, 48)) |level| {
        const gx = g.textX(@intCast(level)) + cw * 0.5;
        c.cui_draw_line(ui, .{ .x = gx, .y = y }, .{ .x = gx, .y = y + height }, 1, w.color(c.CUI_TOKEN_BORDER_SUBTLE));
    }
    const parts = measure(ui, g, tr, s, node);
    const ty = y + 1;
    var x = parts.x;
    const container = tr.isContainer(node) and n.kind != .close;
    if (container and tr.childCount(node) > 0) {
        const glyph = if (tr.isOpen(node)) c.CUI_ICON_CHEVRON_DOWN else c.CUI_ICON_CHEVRON_RIGHT;
        const tint = if (tr.isHeld(node)) w.color(c.CUI_TOKEN_BORDER_STRONG) else w.color(c.CUI_TOKEN_TEXT_SECONDARY);
        c.cui_draw_icon(ui, glyph, .{ .x = x - 19, .y = y + 3, .w = 14, .h = 14 }, 13, tint);
    }
    const key = tr.key(node);
    if (key.len > 0) {
        if (key.len >= 2) mark(ui, p, x + cw, y, key[1 .. key.len - 1]);
        put(ui, x, ty, key, w.design.syntax(ui, .key));
        x += advance(ui, cw, key);
        put(ui, x, ty, ": ", fg);
        x = parts.value_x;
    }
    if (n.kind == .close) {
        put(ui, x, ty, tr.value(node), fg);
        if (n.comma) put(ui, x + cw, ty, ",", fg);
        return;
    }
    if (container) {
        const bracket = tr.value(node);
        const close = tr.nodes.items[node + n.skip];
        const close_text = tr.value(node + n.skip);
        if (close.key_len == 0) {
            put(ui, x, ty, bracket, fg);
            put(ui, x + cw, ty, close_text, fg);
            if (close.comma) put(ui, x + 2 * cw, ty, ",", fg);
        } else if (tr.isOpen(node)) {
            put(ui, x, ty, bracket, fg);
        } else {
            put(ui, x, ty, bracket, fg);
            x += cw + 4;
            const label = summary(tr, node);
            const lw = c.cui_measure_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_CAPTION, label.ptr, @intCast(label.len)).width;
            c.cui_draw_rect(ui, .{ .x = x, .y = y + 3, .w = lw + 10, .h = 14 }, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_SURFACE_MUTED));
            c.cui_draw_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_CAPTION, .{ .x = x + 5, .y = y + 3 }, w.color(c.CUI_TOKEN_TEXT_SECONDARY), label.ptr, @intCast(label.len));
            x += lw + 14;
            put(ui, x, ty, close_text, fg);
            if (close.comma) put(ui, x + cw, ty, ",", fg);
        }
        return;
    }
    const tint = valueTint(ui, n.kind);
    if (parts.open) {
        // The whole string, line after line.
        var rest = tr.value(node);
        var line_y = ty;
        const room = g.right() - parts.value_x;
        var first = true;
        while (rest.len > 0) {
            const len = nextLine(ui, cw, rest, room);
            const chunk = rest[0..len];
            if (line_y + line_h >= g.rect.y and line_y <= g.rect.y + g.rect.h) {
                mark(ui, p, parts.value_x + (if (first) cw else 0), line_y - 1, if (first and chunk.len > 0) chunk[1..] else chunk);
                put(ui, parts.value_x, line_y, chunk, tint);
            }
            rest = rest[len..];
            first = false;
            if (rest.len == 0) {
                const end = parts.value_x + advance(ui, cw, chunk);
                if (n.comma) put(ui, end, line_y, ",", fg);
            }
            line_y += line_h;
        }
        return;
    }
    if (n.kind == .string and parts.shown.len > 1) mark(ui, p, x + cw, y, parts.shown[1..]) else mark(ui, p, x, y, parts.shown);
    put(ui, x, ty, parts.shown, tint);
    if (parts.chip) |chip| {
        put(ui, x + advance(ui, cw, parts.shown), ty, "…", tint);
        const label = chipLabel(parts.hidden);
        c.cui_draw_rect(ui, .{ .x = chip.x, .y = y + 2, .w = chip.w, .h = chip.h }, .{ .tl = 3, .tr = 3, .br = 3, .bl = 3 }, w.color(c.CUI_TOKEN_SURFACE_MUTED));
        c.cui_draw_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_CAPTION, .{ .x = chip.x + 6, .y = y + 3 }, w.color(c.CUI_TOKEN_TEXT_SECONDARY), label.ptr, @intCast(label.len));
        if (n.comma) put(ui, chip.x + chip.w + 2, ty, ",", fg);
    } else if (n.comma) put(ui, parts.value_end, ty, ",", fg);
}

fn drawCard(ui: *c.cui_ctx, p: *const Paint, g: Geo, card: Card) void {
    const tr = p.tree;
    const body = tr.plainValue(w.arena.allocator(), card.node) catch return;
    const cw = g.char_w * 12 / 13;
    const width = @min(560, g.rect.w - 24);
    if (width < 120) return;
    const room = width - 20;
    // Lines as written, then wrapped to the card.
    var lines: std.ArrayList([]const u8) = .empty;
    var rest = body;
    var truncated = false;
    while (true) {
        if (lines.items.len == card_lines) {
            truncated = true;
            break;
        }
        const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const piece = rest[0..newline];
        var len = fit(ui, cw, piece, room);
        if (len == 0 and piece.len > 0) len = @min(piece.len, std.unicode.utf8ByteSequenceLength(piece[0]) catch 1);
        lines.append(w.arena.allocator(), std.mem.trimEnd(u8, piece[0..len], "\r")) catch return;
        if (len < piece.len) {
            rest = rest[len..];
        } else if (newline < rest.len) {
            rest = rest[newline + 1 ..];
        } else break;
    }
    const hint = if (truncated) "Shortened here. Double-click the string to show all of it." else "Double-click the string to show it in place.";
    const height = @as(f32, @floatFromInt(lines.items.len)) * 17 + 34;
    const row_top = g.screenTop(card.row);
    var y = row_top + line_h + 4;
    if (y + height > g.rect.y + g.rect.h) y = @max(g.rect.y + 4, row_top - height - 4);
    const x = std.math.clamp(card.mouse.x - 24, g.rect.x + 8, g.rect.x + g.rect.w - width - bar - 4);
    const box: c.cui_rect = .{ .x = x, .y = y, .w = width, .h = height };
    const radius: c.cui_corners = .{ .tl = 6, .tr = 6, .br = 6, .bl = 6 };
    c.cui_draw_shadow(ui, box, radius, 12, 0, .{ .x = 0, .y = 4 }, w.tinted(ui, c.CUI_TOKEN_FOREGROUND, 0.12));
    c.cui_draw_rect_border(ui, box, radius, w.color(c.CUI_TOKEN_SURFACE), w.color(c.CUI_TOKEN_BORDER), 1);
    for (lines.items, 0..) |line, i| {
        if (line.len == 0) continue;
        c.cui_draw_text(ui, c.CUI_FONT_MONO, 12, .{ .x = x + 10, .y = y + 8 + @as(f32, @floatFromInt(i)) * 17 }, w.color(c.CUI_TOKEN_FOREGROUND), line.ptr, @intCast(line.len));
    }
    c.cui_draw_text(ui, c.CUI_FONT_BODY, c.KEST_TEXT_CAPTION, .{ .x = x + 10, .y = y + height - 20 }, w.color(c.CUI_TOKEN_TEXT_MUTED), hint.ptr, @intCast(hint.len));
}
