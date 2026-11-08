//! Variables and autocomplete: `{{` suggestions in the URL, table cells and
//! body; header names and values; past URLs; hover text and colour spans.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const state = @import("app/state.zig");
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const suggest = @import("ui/suggest.zig");

fn check(src: std.builtin.SourceLocation, ok: bool) !void {
    if (ok) return;
    std.debug.print("Variables at {s}:{d}\n", .{ src.file, src.line });
    return error.VariableRegression;
}
fn equal(src: std.builtin.SourceLocation, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print("Variables at {s}:{d}: wanted \"{s}\", got \"{s}\"\n", .{ src.file, src.line, want, got });
    return error.VariableRegression;
}

fn id(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_id {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    return c.cui_make_id(ui, key);
}
/// A table cell: the tab, the table's scope, the row.
fn cell(ui: *c.cui_ctx, t: *tab.Tab, row: u32, key: [*:0]const u8) c.cui_id {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, "headers");
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @intCast(row));
    defer c.cui_pop_id(ui);
    return c.cui_make_id(ui, key);
}
fn focusCell(ui: *c.cui_ctx, t: *tab.Tab, row: u32, key: [*:0]const u8) void {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, "headers");
    defer c.cui_pop_id(ui);
    c.cui_push_id_int(ui, @intCast(row));
    defer c.cui_pop_id(ui);
    c.kest_focus(ui, key);
}
fn typeText(ui: *c.cui_ctx, app: *App, text: [*:0]const u8, comptime frame: anytype) void {
    c.cui_input_text(ui, text);
    frame(ui, app);
    frame(ui, app);
}

fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8, suffix: []const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-variables-{s}.png", .{ stem, suffix });
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime chord: anytype) !void {
    const old_tabs = app.tabs;
    const old_active = app.active;
    const old_prefs = app.prefs;
    const old_env = app.active_env;
    const old_history = app.history.entries.items.len;
    app.tabs = .empty;
    app.active = 0;
    var environment: state.Env = .{ .id = @splat('v'), .name = @constCast("Staging"), .table = .init(app.gpa) };
    defer environment.table.deinit();
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = old_tabs;
        app.active = old_active;
        app.prefs = old_prefs;
        app.active_env = old_env;
        app.vars_dirty = true;
        while (app.history.entries.items.len > old_history) app.history.remove(app.history.entries.items.len - 1);
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    _ = try environment.table.add(.{ .key = "base", .value = "https://first.invalid" });
    _ = try environment.table.add(.{ .key = "base_path", .value = "/v1" });
    _ = try environment.table.add(.{ .key = "token", .value = "abc123" });
    commands.setActiveEnv(app, &environment);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    c.cui_set_viewport(ui, 1000, 700, 1);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    for (0..3) |_| frame(ui, app);

    // Spans and hover text: known names, unknown ones, and nothing else.
    const spans = suggest.marks("{{base}}/x/{{nope}}", app.activeVars());
    try check(@src(), spans.len == 2 and spans[0].start == 0 and spans[0].end == 8 and spans[0].known == 1 and spans[1].known == 0);
    const ctx: suggest.Context = .{ .vars = app.activeVars(), .env_name = "Staging" };
    try equal(@src(), "base = https://first.invalid", suggest.hoverText("{{base}}/x", 3, ctx).?);
    try equal(@src(), "nope is not set in Staging", suggest.hoverText("a {{nope}}", 4, ctx).?);
    try check(@src(), suggest.hoverText("{{base}}/x", 9, ctx) == null);

    // URL: "{{ba" lists base and base_path; Down then Enter takes the second
    // and doesn't send.
    const url_id = id(ui, t, "url");
    t.url.set("");
    t.url.focus();
    frame(ui, app);
    typeText(ui, app, "https://h{{ba", frame);
    try check(@src(), suggest.openFor(url_id));
    for (0..20) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "url-list");
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "https://h{{base_path}}", t.url.text());
    try check(@src(), t.job == null and !suggest.openFor(url_id));
    // Escape closes the list and keeps the text; typing again reopens it.
    typeText(ui, app, "/{{to", frame);
    try check(@src(), suggest.openFor(url_id));
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), !suggest.openFor(url_id));
    try equal(@src(), "https://h{{base_path}}/{{to", t.url.text());
    // Ctrl+Space brings it back without typing a space.
    chord(ui, app, c.CUI_KEY_SPACE, c.CUI_MOD_PRIMARY);
    try check(@src(), suggest.openFor(url_id));
    try equal(@src(), "https://h{{base_path}}/{{to", t.url.text());
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    typeText(ui, app, "k", frame);
    try check(@src(), suggest.openFor(url_id));
    for (0..20) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "url-marks");
    // A click on a suggestion takes it.
    const first = blk: {
        c.cui_push_id_int(ui, @intCast(t.uid));
        defer c.cui_pop_id(ui);
        const pid = c.cui_make_id(ui, "suggestions");
        c.cui_push_id_int(ui, @intCast(pid));
        defer c.cui_pop_id(ui);
        break :blk c.cui_get_rect(ui, c.cui_make_id(ui, "suggestion-0"));
    };
    try check(@src(), first.w > 0);
    c.cui_input_mouse_move(ui, first.x + 10, first.y + first.h / 2);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try equal(@src(), "https://h{{base_path}}/{{token}}", t.url.text());
    try check(@src(), c.kest_get_focus(ui) == url_id);

    // Past URLs: typing part of one offers it, newest first; Tab takes it.
    try app.history.add(.{ .method = "GET", .url = "https://api.invalid/users", .timestamp_ms = 1, .status = 200, .time_ms = 1 });
    try app.history.add(.{ .method = "GET", .url = "https://api.invalid/orders", .timestamp_ms = 2, .status = 200, .time_ms = 1 });
    t.url.set("");
    frame(ui, app);
    typeText(ui, app, "orders", frame);
    try check(@src(), suggest.openFor(url_id));
    chord(ui, app, c.CUI_KEY_TAB, 0);
    try equal(@src(), "https://api.invalid/orders", t.url.text());
    // Focusing a field alone shows nothing.
    t.url.set("https://api");
    focusCell(ui, t, 0, "none");
    frame(ui, app);
    t.url.focus();
    for (0..2) |_| frame(ui, app);
    try check(@src(), !suggest.openFor(url_id));

    // Headers: a name, then a value for it, from the new row's cells. Up
    // and Down move in the list, not between rows.
    t.pane = .headers;
    t.pane_chosen = true;
    for (0..3) |_| frame(ui, app);
    const entry = (try t.headers.insertion()).?;
    const row_uid = entry.uid;
    focusCell(ui, t, row_uid, "key");
    frame(ui, app);
    typeText(ui, app, "cont", frame);
    try check(@src(), suggest.openFor(cell(ui, t, row_uid, "key")));
    chord(ui, app, c.CUI_KEY_DOWN, 0);
    try check(@src(), c.kest_get_focus(ui) == cell(ui, t, row_uid, "key"));
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), t.headers.rows.items.len == 1);
    try equal(@src(), "Content-Type", t.headers.rows.items[0].key.text());
    focusCell(ui, t, row_uid, "value");
    frame(ui, app);
    typeText(ui, app, "app", frame);
    try check(@src(), suggest.openFor(cell(ui, t, row_uid, "value")));
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "application/json", t.headers.rows.items[0].value.text());
    // Variables in a cell too.
    typeText(ui, app, "; {{", frame);
    try check(@src(), suggest.openFor(cell(ui, t, row_uid, "value")));
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "application/json; {{base}}", t.headers.rows.items[0].value.text());

    // The body: "{{to" inside a JSON string suggests token; Enter takes it.
    t.pane = .body;
    t.body_kind = .json;
    t.method.set("POST");
    t.body.setText("{\"a\": \"\"}");
    t.body.moveTo(7, false);
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    c.kest_focus(ui, "body-editor");
    c.cui_pop_id(ui);
    frame(ui, app);
    typeText(ui, app, "{{to", frame);
    try check(@src(), suggest.openFor(id(ui, t, "body-editor")));
    for (0..20) |_| frame(ui, app);
    try capture(ui, sw, app, snapshot, "body-list");
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try equal(@src(), "{\"a\": \"{{token}}\"}", t.body.text());
    try check(@src(), t.body.caret == 16);
    // One undo takes the typing and the insertion back separately.
    try check(@src(), t.body.undoEdit());
    try equal(@src(), "{\"a\": \"{{to\"}", t.body.text());
    std.debug.print("CUI variables: URL/table/body {{{{ suggestions, keys/click/Escape, header names and values, past URLs, colour spans and hover text passed\n", .{});
}
