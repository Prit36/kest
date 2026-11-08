//! Text editing in the body editor and response text: click units, moving
//! text by dragging, wheel gliding, and the rest of the editing section.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const code = @import("ui/code_state.zig");
const editor = @import("ui/editor.zig");
const font = @import("ui/code_font.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (!ok) {
        std.debug.print("Text editing regression at {s}:{d}\n", .{ src.file, src.line });
        return error.TextEditingRegression;
    }
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("Text editing at {s}:{d}: wanted \"{s}\", got \"{s}\"\n", .{ src.file, src.line, want, got });
        return error.TextEditingRegression;
    }
}
fn rect(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn focus(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.kest_focus(ui, key);
}

/// Where byte `at` of line `line` (no wrapping, ASCII) sits on screen.
const Spot = struct { x: f32, y: f32 };
fn spot(ui: *c.cui_ctx, t: *tab.Tab, line: usize, column: usize) Spot {
    const r = rect(ui, t, "body-editor");
    const char_w = editor.cellWidth(ui);
    const gutter = editor.gutterWidth(ui, t.body.index.lineNumber(t.body.index.count() - 1)) + @as(f32, if (t.body_kind == .json) 14 else 0);
    return .{ .x = r.x + gutter + 12 + @as(f32, @floatFromInt(column)) * char_w + 1, .y = r.y + 8 + (@as(f32, @floatFromInt(line)) + 0.5) * font.line() - t.body.scroll_y };
}
fn press(ui: *c.cui_ctx, app: *App, at: Spot, comptime frame: anytype) void {
    c.cui_input_mouse_move(ui, at.x, at.y);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
}
fn release(ui: *c.cui_ctx, app: *App, comptime frame: anytype) void {
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
}
fn clicks(ui: *c.cui_ctx, app: *App, at: Spot, n: usize, comptime frame: anytype) void {
    for (0..n) |_| {
        press(ui, app, at, frame);
        release(ui, app, frame);
    }
}
fn dragTo(ui: *c.cui_ctx, app: *App, at: Spot, comptime frame: anytype) void {
    c.cui_input_mouse_move(ui, at.x, at.y);
    frame(ui, app);
    frame(ui, app);
}

fn model(app: *App) !void {
    var s = code.State.init(app.gpa);
    defer s.deinit();
    s.setText("alpha beta, gamma\nsecond line\n");
    // Double click: the word; dragging grows by whole words.
    s.pressAt(s.text(), 8, 2, false);
    try equal(@src(), "beta", s.selected(s.text()));
    s.dragTo(s.text(), 14);
    try equal(@src(), "beta, gamma", s.selected(s.text()));
    s.dragTo(s.text(), 1);
    try equal(@src(), "alpha beta", s.selected(s.text()));
    try check(@src(), s.caret == 0 and s.anchor == 10);
    // At a word's end, that word; off any word, the one character.
    s.pressAt(s.text(), 10, 2, false);
    try equal(@src(), "beta", s.selected(s.text()));
    s.pressAt(s.text(), 11, 2, false);
    try equal(@src(), " ", s.selected(s.text()));
    // Triple click: the line with its newline; dragging adds lines.
    s.pressAt(s.text(), 3, 3, false);
    try equal(@src(), "alpha beta, gamma\n", s.selected(s.text()));
    s.dragTo(s.text(), 20);
    try equal(@src(), "alpha beta, gamma\nsecond line\n", s.selected(s.text()));
    // Moving text is one undoable edit, both ways, and copying keeps the source.
    s.setText("one two three");
    s.anchor = 4;
    s.caret = 8;
    s.moveSelection(13, false);
    try equal(@src(), "one threetwo ", s.text());
    try equal(@src(), "two ", s.selected(s.text()));
    try check(@src(), s.undoEdit());
    try equal(@src(), "one two three", s.text());
    try check(@src(), s.anchor == 4 and s.caret == 8);
    s.moveSelection(0, false);
    try equal(@src(), "two one three", s.text());
    try equal(@src(), "two ", s.selected(s.text()));
    s.moveSelection(13, true);
    try equal(@src(), "two one threetwo ", s.text());
    try equal(@src(), "two ", s.selected(s.text()));
    try check(@src(), s.anchor == 13);
    // Dropping inside the selection changes nothing.
    const version = s.version;
    s.anchor = 0;
    s.caret = 4;
    s.moveSelection(2, false);
    try check(@src(), s.version == version);
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime chord: anytype) !void {
    try model(app);
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        c.cui_set_reduced_motion(ui, true);
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.method.set("POST");
    t.pane = .body;
    t.pane_chosen = true;
    t.body_kind = .text;
    c.cui_set_viewport(ui, 760, 520, 1);
    t.body.setText("first word here\nsecond line\nthird");
    for (0..4) |_| frame(ui, app);
    focus(ui, t, "body-editor");
    frame(ui, app);

    // Double and triple clicks in the real canvas.
    clicks(ui, app, spot(ui, t, 0, 7), 2, frame);
    try equal(@src(), "word", t.body.selected(t.body.text()));
    for (0..30) |_| frame(ui, app);
    clicks(ui, app, spot(ui, t, 1, 2), 3, frame);
    try equal(@src(), "second line\n", t.body.selected(t.body.text()));
    for (0..30) |_| frame(ui, app);

    // Drag "word" to the end of the first line; Escape cancels a drag.
    clicks(ui, app, spot(ui, t, 0, 7), 2, frame);
    for (0..30) |_| frame(ui, app);
    press(ui, app, spot(ui, t, 0, 8), frame);
    dragTo(ui, app, spot(ui, t, 0, 15), frame);
    try check(@src(), t.body.move_drag == .moving and t.body.drop_at == 15);
    release(ui, app, frame);
    try equal(@src(), "first  hereword\nsecond line\nthird", t.body.text());
    try equal(@src(), "word", t.body.selected(t.body.text()));
    chord(ui, app, c.CUI_KEY_Z, c.CUI_MOD_PRIMARY);
    try equal(@src(), "first word here\nsecond line\nthird", t.body.text());
    for (0..30) |_| frame(ui, app);
    t.body.anchor = 6;
    t.body.caret = 10;
    frame(ui, app);
    press(ui, app, spot(ui, t, 0, 7), frame);
    dragTo(ui, app, spot(ui, t, 2, 5), frame);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    release(ui, app, frame);
    try equal(@src(), "first word here\nsecond line\nthird", t.body.text());
    // Ctrl while dropping copies.
    for (0..30) |_| frame(ui, app);
    press(ui, app, spot(ui, t, 0, 7), frame);
    dragTo(ui, app, spot(ui, t, 2, 5), frame);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, c.CUI_MOD_PRIMARY);
    release(ui, app, frame);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, 0);
    try equal(@src(), "first word here\nsecond line\nthirdword", t.body.text());
    // A click inside the selection without moving just places the caret.
    for (0..30) |_| frame(ui, app);
    t.body.anchor = 0;
    t.body.caret = 5;
    frame(ui, app);
    clicks(ui, app, spot(ui, t, 0, 2), 1, frame);
    try check(@src(), t.body.caret == 2 and t.body.anchor == 2);

    // The wheel glides: part way after one frame, there after a few.
    var tall: std.ArrayList(u8) = .empty;
    defer tall.deinit(app.gpa);
    for (0..200) |i| try tall.print(app.gpa, "line {d}\n", .{i});
    t.body.setText(tall.items);
    for (0..3) |_| frame(ui, app);
    // Tests run with reduced motion, where a wheel step lands at once.
    const r = rect(ui, t, "body-editor");
    c.cui_input_mouse_move(ui, r.x + r.w / 2, r.y + r.h / 2);
    frame(ui, app);
    c.cui_input_scroll(ui, 0, -1);
    frame(ui, app);
    try check(@src(), t.body.scroll_y == 60 and t.body.glide.target == null);
    c.cui_input_scroll(ui, 0, -2);
    frame(ui, app);
    try check(@src(), t.body.scroll_y == 180);
    c.cui_input_scroll(ui, 0, 10);
    frame(ui, app);
    try check(@src(), t.body.scroll_y == 0);
    try glide();
    try zoom(ui, app, t, frame, chord);
    try findReplace(ui, app, t, frame, chord);
    try folding(ui, app, t, frame, chord);
    std.debug.print("CUI text editing: word/line clicks, text drag, wheel glide, zoom, find/replace/regex and folding passed\n", .{});
}

/// JSON objects and arrays over several lines fold from the gutter, from
/// their marker, with Ctrl+Shift+- and from the menu; the caret reaching a
/// fold opens it.
fn folding(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype, comptime chord: anytype) !void {
    t.body_kind = .json;
    t.body.setText("{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": 3\n}");
    t.body.moveTo(0, false);
    focus(ui, t, "body-editor");
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.body.folds.regions.items.len == 2);
    // The arrow beside line 2 folds "a"; rows 3 and 4 hide.
    const r = rect(ui, t, "body-editor");
    const arrow: Spot = .{ .x = r.x + 6, .y = spot(ui, t, 1, 0).y };
    clicks(ui, app, arrow, 1, frame);
    try check(@src(), t.body.folds.anyFolded() and t.body.folds.rows(t.body.index.count()) == 5);
    // Line 5 ("],") now shows third; a click there lands on it.
    for (0..30) |_| frame(ui, app);
    clicks(ui, app, spot(ui, t, 2, 3), 1, frame);
    try check(@src(), t.body.index.lineNumber(t.body.index.rowOf(t.body.caret)) == 5);
    // Up skips the hidden rows.
    chord(ui, app, c.CUI_KEY_UP, 0);
    try check(@src(), t.body.index.lineNumber(t.body.index.rowOf(t.body.caret)) == 2);
    // Moving into the fold opens it.
    t.body.moveTo(16, false);
    frame(ui, app);
    try check(@src(), !t.body.folds.anyFolded());
    // Ctrl+Shift+- folds where the caret is and keeps the caret in sight.
    chord(ui, app, c.CUI_KEY_MINUS, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    try check(@src(), t.body.folds.anyFolded());
    try check(@src(), t.body.index.lineNumber(t.body.index.rowOf(t.body.caret)) == 2);
    chord(ui, app, c.CUI_KEY_MINUS, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    try check(@src(), !t.body.folds.anyFolded());
    // Folds follow edits above them and survive undo.
    t.body.folds.fold(app.gpa, t.body.folds.regionOnRow(1).?.open);
    frame(ui, app);
    t.body.moveTo(1, false);
    t.body.replaceSelection(" ", true);
    frame(ui, app);
    try check(@src(), t.body.folds.anyFolded() and t.body.folds.rows(t.body.index.count()) == 5);
    try check(@src(), t.body.undoEdit());
    frame(ui, app);
    try check(@src(), t.body.folds.anyFolded());
    // The bracket at the caret and its partner are found.
    t.body.folds.unfoldAll();
    t.body.moveTo(0, false);
    frame(ui, app);
    try check(@src(), t.body.marked != null and t.body.marked.?[1] == t.body.text().len - 1);
    t.body_kind = .text;
    frame(ui, app);
    try check(@src(), t.body.folds.regions.items.len == 0);
}

/// Ctrl+H opens Find with Replace; the options, Replace, Replace all and
/// group references act on the body, each one undoable edit.
fn findReplace(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype, comptime chord: anytype) !void {
    t.body.setText("id=1 id=22 idx=3 ID=4");
    focus(ui, t, "body-editor");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_H, c.CUI_MOD_PRIMARY);
    try check(@src(), t.body.search_open and t.body.replace_open);
    try check(@src(), rect(ui, t, "replace").w > 0 and rect(ui, t, "find-regex").w > 0);
    t.body.query.set("id");
    frame(ui, app);
    try check(@src(), t.body.matches.items.len == 4);
    t.body.search_word = true;
    frame(ui, app);
    try check(@src(), t.body.matches.items.len == 3);
    t.body.search_case = true;
    frame(ui, app);
    try check(@src(), t.body.matches.items.len == 2);
    // Replace one: the selection is a match, so it goes, and the next is picked.
    t.body.replacement.set("key");
    t.body.gotoMatch(0);
    frame(ui, app);
    focus(ui, t, "replace");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "key=1 id=22 idx=3 ID=4", t.body.text());
    try equal(@src(), "id", t.body.selected(t.body.text()));
    try check(@src(), t.body.anchor == 6);
    // Replace all with regex groups, one undo step.
    t.body.setText("id=1 id=22 idx=3 ID=4");
    t.body.search_case = false;
    t.body.search_word = false;
    t.body.search_regex = true;
    t.body.query.set("(\\w+)=(\\d+)");
    t.body.replacement.set("$2:$1");
    frame(ui, app);
    try check(@src(), t.body.matches.items.len == 4);
    chord(ui, app, c.CUI_KEY_ENTER, c.CUI_MOD_PRIMARY | c.CUI_MOD_ALT);
    try equal(@src(), "1:id 22:id 3:idx 4:ID", t.body.text());
    try check(@src(), t.body.undoEdit());
    try equal(@src(), "id=1 id=22 idx=3 ID=4", t.body.text());
    // A malformed pattern says where, and finds nothing.
    t.body.query.set("(\\w+");
    frame(ui, app);
    try check(@src(), t.body.matches.items.len == 0 and t.body.search_problem.len > 0);
    // Escape closes Find and returns to the text.
    focus(ui, t, "find");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), !t.body.search_open);
    c.cui_push_id_int(ui, @intCast(t.uid));
    const editor_id = c.cui_make_id(ui, "body-editor");
    c.cui_pop_id(ui);
    try check(@src(), c.kest_editor_focus(ui, editor_id) != 0);
    t.body.search_regex = false;
    t.body.replace_open = false;
    // Ctrl+F with a word selected looks for that word.
    t.body.anchor = 5;
    t.body.caret = 7;
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_F, c.CUI_MOD_PRIMARY);
    try equal(@src(), "id", t.body.query.text());
    t.body.search_open = false;
}

/// Ctrl+= and Ctrl+- step the code font, Ctrl+wheel over a view too, and
/// Ctrl+0 resets it; rows grow with it and clicks still land.
fn zoom(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype, comptime chord: anytype) !void {
    app.prefs.editor_font_size = font.default;
    t.body.setText("first word here\nsecond line\nthird");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_EQUAL, c.CUI_MOD_PRIMARY);
    try check(@src(), app.prefs.editor_font_size == 14 and font.size == 14);
    chord(ui, app, c.CUI_KEY_EQUAL, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    chord(ui, app, c.CUI_KEY_MINUS, c.CUI_MOD_PRIMARY);
    try check(@src(), app.prefs.editor_font_size == 14);
    const r = rect(ui, t, "body-editor");
    c.cui_input_mouse_move(ui, r.x + r.w / 2, r.y + r.h / 2);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, c.CUI_MOD_PRIMARY);
    c.cui_input_scroll(ui, 0, 4);
    frame(ui, app);
    frame(ui, app);
    c.cui_input_key(ui, c.CUI_KEY_NONE, false, 0);
    try check(@src(), app.prefs.editor_font_size == 18 and font.line() == 28 and t.body.scroll_y == 0);
    for (0..30) |_| frame(ui, app);
    clicks(ui, app, spot(ui, t, 1, 3), 2, frame);
    try equal(@src(), "second", t.body.selected(t.body.text()));
    for (0..30) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_0, c.CUI_MOD_PRIMARY);
    try check(@src(), app.prefs.editor_font_size == font.default and font.line() == 20);
    for (0..40) |_| chord(ui, app, c.CUI_KEY_MINUS, c.CUI_MOD_PRIMARY);
    try check(@src(), app.prefs.editor_font_size == font.min);
    chord(ui, app, c.CUI_KEY_0, c.CUI_MOD_PRIMARY);
}

/// With motion on, a wheel step eases over a few frames and stops there;
/// steps taken during a glide add up.
fn glide() !void {
    const ui = c.cui_create(&.{}) orelse return error.ContextFailed;
    defer c.cui_destroy(ui);
    c.cui_set_viewport(ui, 200, 200, 1);
    c.cui_set_reduced_motion(ui, false);
    var g: @import("ui/glide.zig").Glide = .{};
    var y: f32 = 0;
    for (0..2) |_| {
        c.cui_begin_frame(ui, 1.0 / 60.0);
        c.cui_end_frame(ui);
    }
    g.push(y, 60);
    c.cui_begin_frame(ui, 1.0 / 60.0);
    g.step(ui, &y, 1000);
    c.cui_end_frame(ui);
    try check(@src(), y > 0 and y < 60 and g.target.? == 60);
    g.push(y, 60);
    try check(@src(), g.target.? == 120);
    var frames: usize = 0;
    while (g.target != null and frames < 60) : (frames += 1) {
        c.cui_begin_frame(ui, 1.0 / 60.0);
        g.step(ui, &y, 100);
        c.cui_end_frame(ui);
    }
    // Held at the end of the document, settled within half a second.
    try check(@src(), y == 100 and frames < 30);
}
