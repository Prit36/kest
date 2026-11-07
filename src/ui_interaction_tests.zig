//! Real pointer and keyboard events. No native window or system clipboard.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const commands = @import("app/commands.zig");

fn expect(value: bool) !void {
    if (!value) return error.InteractionCheckFailed;
}
fn rect(ui: *c.cui_ctx, uid: ?u64, key: [*:0]const u8) c.cui_rect {
    if (uid) |n| c.cui_push_id_int(ui, @intCast(n));
    defer if (uid != null) c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn menuRect(ui: *c.cui_ctx, uid: ?u64, trigger: [*:0]const u8, label: [*:0]const u8) c.cui_rect {
    if (uid) |n| c.cui_push_id_int(ui, @intCast(n));
    defer if (uid != null) c.cui_pop_id(ui);
    const popup = c.cui_make_id(ui, trigger) ^ 0x3e40;
    c.cui_push_id_int(ui, @bitCast(popup));
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, label));
}
fn tap(ui: *c.cui_ctx, app: *App, r: c.cui_rect, comptime click: anytype) !void {
    try expect(r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}

pub fn run(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype, comptime chord: anytype) !void {
    const original = app.current().?;
    const uid = original.uid;
    const tree = @import("app/tree_ops.zig");
    // More visible menu triggers than CUI has popup slots. Closed menus must
    // not reserve slots and disable the method/body/environment controls.
    var stress: [40]*@import("core/collection.zig").Node = undefined;
    var stress_count: usize = 0;
    defer for (stress[0..stress_count]) |node| tree.deleteNode(app, node);
    for (&stress, 0..) |*slot, i| {
        slot.* = tree.newCollection(app, w.fmt("Menu check {d}", .{i})) orelse return error.AllocationFailed;
        stress_count += 1;
    }
    c.cui_set_viewport(ui, 1180, 800, 1);
    for (0..4) |_| frame(ui, app);
    try tap(ui, app, rect(ui, uid, "###http-method"), click);
    try tap(ui, app, menuRect(ui, uid, "###http-method", "POST"), click);
    try expect(std.mem.eql(u8, original.method.text(), "POST"));
    try tap(ui, app, rect(ui, uid, "###http-method"), click);
    try tap(ui, app, menuRect(ui, uid, "###http-method", "Custom method..."), click);
    frame(ui, app);
    try expect(original.editing_method);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "PROPFIND");
    frame(ui, app);
    try expect(std.mem.eql(u8, original.method.text(), "PROPFIND"));
    try tap(ui, app, rect(ui, uid, "standard-methods"), click);
    try tap(ui, app, rect(ui, uid, "###http-method"), click);
    try tap(ui, app, menuRect(ui, uid, "###http-method", "GET"), click);
    try expect(!original.editing_method and std.mem.eql(u8, original.method.text(), "GET"));

    try tap(ui, app, rect(ui, uid, "pane-body"), click);
    try expect(original.pane == .body);
    try tap(ui, app, rect(ui, uid, "###body-kind"), click);
    try tap(ui, app, menuRect(ui, uid, "###body-kind", "JSON"), click);
    try expect(original.pane == .body and original.body_kind == .json);
    const toolbar = rect(ui, uid, "body-toolbar");
    const format = rect(ui, uid, "format-body");
    try expect(format.w > 0 and format.x + format.w <= toolbar.x + toolbar.w);
    try tap(ui, app, rect(ui, uid, "request-options"), click);
    try expect(original.pane == .settings);
    try tap(ui, app, rect(ui, uid, "pane-params"), click);

    // Use an already-created environment, through the actual global picker.
    try tap(ui, app, rect(ui, null, "###active-environment"), click);
    try tap(ui, app, menuRect(ui, null, "###active-environment", "No environment"), click);
    try expect(app.active_env == null);
    try tap(ui, app, rect(ui, null, "###active-environment"), click);
    const environment = app.envs.items[0];
    try tap(ui, app, menuRect(ui, null, "###active-environment", w.fmt("{s}###env-{s}", .{ environment.name, environment.id })), click);
    try expect(app.active_env != null);
    for (stress[0..stress_count]) |node| tree.deleteNode(app, node);
    stress_count = 0;
    for (0..3) |_| frame(ui, app);

    // A second open of the same dialog must focus the existing text field.
    const before = app.collections.items.len;
    @import("ui/dialogs.zig").askName(app, .new_collection, "");
    frame(ui, app);
    c.cui_input_text(ui, "Keyboard collection");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try expect(!app.modal_open and app.collections.items.len == before + 1);
    const collection = app.collections.items[app.collections.items.len - 1];
    @import("ui/dialogs.zig").askName(app, .{ .rename_node = collection }, collection.name);
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_A, c.CUI_MOD_PRIMARY);
    c.cui_input_text(ui, "Keyboard renamed");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try expect(!app.modal_open and std.mem.eql(u8, collection.name, "Keyboard renamed"));

    // Opening/cycling an overflowing document strip reveals the active request.
    const tab_count = app.tabs.items.len;
    for (0..6) |_| try tap(ui, app, rect(ui, null, "new-document"), click);
    for (0..4) |_| frame(ui, app);
    try expect(app.tabs.items.len == tab_count + 6);
    const active = app.current().?;
    const active_rect = rect(ui, active.uid, "document-tab");
    const scroll = rect(ui, null, "document-scroll");
    try expect(active_rect.x >= scroll.x - 1 and active_rect.x + active_rect.w <= scroll.x + scroll.w + 1);
    try tap(ui, app, rect(ui, active.uid, "close-document"), click);
    try expect(app.tabs.items.len == tab_count + 5);
    while (app.tabs.items.len > tab_count) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
    for (app.tabs.items, 0..) |t, i| if (t == original) {
        commands.activate(app, i);
        break;
    };
    original.pane = .params;
    original.body_kind = .none;
    for (0..4) |_| frame(ui, app);
    std.debug.print("CUI controls: method/custom method, body selector, environment picker, repeated dialog focus/Enter, tab overflow/reveal and close passed\n", .{});
}

pub fn response(ui: *c.cui_ctx, app: *App, comptime frame: anytype, comptime click: anytype) !void {
    const t = app.current().?;
    for (0..3) |_| frame(ui, app);
    try tap(ui, app, rect(ui, t.uid, "response-headers"), click);
    try expect(t.response.pane == .headers and t.shown.?.resp.headers.items.len > 0);
    try expect(rect(ui, t.uid, "response-header-rows").h > 50);
    try tap(ui, app, rect(ui, t.uid, "response-body"), click);
    try tap(ui, app, rect(ui, t.uid, "###response-format"), click);
    try tap(ui, app, menuRect(ui, t.uid, "###response-format", "JSON tree"), click);
    try expect(t.response.pretty_mode == .tree and t.response.tree != null);
    try tap(ui, app, rect(ui, t.uid, "###response-format"), click);
    try tap(ui, app, menuRect(ui, t.uid, "###response-format", "Minified JSON"), click);
    try expect(t.response.pretty_mode == .minified and std.mem.indexOfScalar(u8, t.response.formatted.?, '\n') == null);
    try tap(ui, app, rect(ui, t.uid, "###response-format"), click);
    try tap(ui, app, menuRect(ui, t.uid, "###response-format", "Raw text"), click);
    try expect(t.response.pane == .raw and rect(ui, t.uid, "raw-view").h > 50);
    try tap(ui, app, rect(ui, t.uid, "###response-format"), click);
    try tap(ui, app, menuRect(ui, t.uid, "###response-format", "Formatted JSON"), click);
    try expect(t.response.pane == .pretty and t.response.pretty_mode == .text);
    std.debug.print("CUI response controls: header table, JSON tree/minified/raw/formatted menu selections passed\n", .{});
}
