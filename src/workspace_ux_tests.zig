//! Workspace interactions exercised through real frames and persisted data.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const commands = @import("app/commands.zig");
const tree = @import("app/tree_ops.zig");
const sidebar = @import("ui/sidebar.zig");
fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Workspace UX regression at {s}:{d}\n", .{ src.file, src.line });
        return error.WorkspaceUXRegression;
    }
}
pub fn run(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, comptime frame: anytype, comptime chord: anytype) !void {
    tree.finishDelete(app); // Do not undo cleanup performed by earlier suites.
    const original = app.current().?;
    app.mode = .collections;
    app.prefs.sidebar_open = true;
    c.cui_set_viewport(ui, 1280, 800, 1);
    const collection = tree.newCollection(app, "Workspace UX checks") orelse return error.AllocationFailed;
    defer {
        tree.deleteNode(app, collection);
        tree.finishDelete(app);
    }
    const folder = tree.newFolder(app, collection, "Destination") orelse return error.AllocationFailed;
    const first = tree.addRequest(app, collection, .{ .name = "First", .url = "https://example.invalid/one" }) orelse return error.AllocationFailed;
    const second = tree.addRequest(app, collection, .{ .name = "Second", .url = "https://example.invalid/two" }) orelse return error.AllocationFailed;
    app.store.sync();
    app.rows_dirty = true;
    sidebar.reveal(app, first);
    for (0..4) |_| frame(ui, app);
    // F2 begins editing inside the tree, with no dialog; Enter commits.
    c.kest_focus(ui, "collection-rows");
    chord(ui, app, c.CUI_KEY_F2, 0);
    try @import("ui_snapshots.zig").capture(ui, sw, app, "test-output/rename-sidebar.png");
    try check(@src(), app.rename_action != null and !app.modal_open);
    const tab_count_before_rename = app.tabs.items.len;
    c.cui_input_text(ui, "Renamed inline");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), app.rename_action == null and std.mem.eql(u8, first.name, "Renamed inline"));
    try check(@src(), app.tabs.items.len == tab_count_before_rename);
    try check(@src(), c.kest_get_focus(ui) == c.cui_make_id(ui, "collection-rows"));
    // Escape restores the old name and returns keyboard control to the tree.
    chord(ui, app, c.CUI_KEY_F2, 0);
    c.cui_input_text(ui, "Discard this");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), app.rename_action == null and std.mem.eql(u8, first.name, "Renamed inline"));
    // Pointer selection inside the editor must never arm tree dragging.
    chord(ui, app, c.CUI_KEY_F2, 0);
    const edit = c.cui_get_rect(ui, app.rename_field);
    try check(@src(), edit.w >= 100 and edit.h <= 26);
    c.cui_input_mouse_move(ui, edit.x + 12, edit.y + edit.h / 2);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_move(ui, edit.x + 55, edit.y + edit.h / 2);
    frame(ui, app);
    try check(@src(), !sidebar.dragActive() and sidebar.pressedNode() == null);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    // Clicking outside commits without forcing focus back into the editor.
    @import("ui/rename.zig").begin(app, .{ .rename_node = first }, first.name);
    for (0..2) |_| frame(ui, app);
    c.cui_input_text(ui, "Commit on blur");
    frame(ui, app);
    c.cui_input_mouse_move(ui, 600, 700);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, true);
    frame(ui, app);
    c.cui_input_mouse_button(ui, c.CUI_MOUSE_LEFT, false);
    frame(ui, app);
    try check(@src(), app.rename_action == null and std.mem.eql(u8, first.name, "Commit on blur"));
    tree.rename(app, first, "Renamed inline");
    c.cui_input_mouse_move(ui, -100, -100);
    // Long names stay editable in a narrow sidebar in both themes; dimensions
    // and rendered artifacts are checked instead of only checking the model.
    const old_width = app.prefs.sidebar_width;
    const old_dark = app.prefs.dark;
    app.prefs.sidebar_width = 210;
    for ([_]bool{ true, false }) |dark| {
        app.prefs.dark = dark;
        @import("ui/rename.zig").begin(app, .{ .rename_node = first }, first.name);
        for (0..3) |_| frame(ui, app);
        const narrow = c.cui_get_rect(ui, app.rename_field);
        try check(@src(), narrow.w >= 80 and narrow.h <= 26 and narrow.x + narrow.w <= 210 and narrow.y >= 119 and narrow.y + narrow.h <= 800);
        c.cui_input_text(ui, "A long request name that must remain fully editable without moving the row");
        for (0..2) |_| frame(ui, app);
        try @import("ui_snapshots.zig").capture(ui, sw, app, if (dark) "test-output/rename-sidebar-narrow-dark.png" else "test-output/rename-sidebar-narrow-light.png");
        chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    }
    app.prefs.sidebar_width = old_width;
    app.prefs.dark = old_dark;
    // Empty Enter is visibly invalid; Escape restores the original.
    @import("ui/rename.zig").begin(app, .{ .rename_node = first }, first.name);
    for (0..2) |_| frame(ui, app);
    chord(ui, app, c.CUI_KEY_BACKSPACE, 0);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), app.rename_action != null and app.rename_invalid);
    chord(ui, app, c.CUI_KEY_ESCAPE, 0);
    try check(@src(), std.mem.eql(u8, first.name, "Renamed inline"));
    // Range/toggle selection and bulk move preserve order and hierarchy.
    sidebar.select(app, first, false, false);
    sidebar.select(app, second, false, true);
    try check(@src(), app.selection.items.len == 2);
    sidebar.select(app, second, true, false);
    try check(@src(), app.selection.items.len == 1);
    sidebar.select(app, second, true, false);
    var export_arena = std.heap.ArenaAllocator.init(app.gpa);
    defer export_arena.deinit();
    var missing: std.ArrayList([]const u8) = .empty;
    const exported = try @import("app/import_ops.zig").selectionDocument(app, export_arena.allocator(), &missing);
    try check(@src(), exported.countRequests() == 2 and missing.items.len == 0);
    sidebar.moveSelection(app, folder);
    try check(@src(), first.parent == folder and second.parent == folder);
    // Selecting an ancestor and child deletes each subtree once; Undo restores
    // exact pointers, order, and the saved request files.
    sidebar.select(app, folder, false, false);
    sidebar.select(app, first, true, false);
    sidebar.deleteSelection(app);
    try check(@src(), collection.children.items.len == 0 and app.deleted.items.len > 0);
    tree.undoDelete(app);
    try check(@src(), folder.parent == collection and folder.children.items[0] == first and folder.children.items[1] == second);
    app.store.sync();
    var ar = std.heap.ArenaAllocator.init(app.gpa);
    defer ar.deinit();
    const loaded = try @import("storage/collection_store.zig").loadRequest(app.store, ar.allocator(), &collection.id, &first.id);
    try check(@src(), std.mem.eql(u8, loaded.name, "Renamed inline"));
    const env = tree.addEnvironment(app, "Undo environment") orelse return error.AllocationFailed;
    commands.setActiveEnv(app, env);
    tree.deleteEnv(app, env);
    try check(@src(), app.active_env == null);
    tree.undoDelete(app);
    try check(@src(), app.active_env == env);
    tree.deleteEnv(app, env);
    tree.finishDelete(app);
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    t.url.set("https://example.invalid/reopen");
    for (0..3) |_| frame(ui, app);
    t.url.focus();
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_F2, 0);
    try @import("ui_snapshots.zig").capture(ui, sw, app, "test-output/rename-tab.png");
    try check(@src(), app.rename_action != null and !app.modal_open);
    for (0..2) |_| frame(ui, app);
    const tab_editor = c.cui_get_rect(ui, app.rename_field);
    try check(@src(), tab_editor.w >= 160 and tab_editor.h <= 26);
    c.cui_input_text(ui, "Inline tab name");
    frame(ui, app);
    chord(ui, app, c.CUI_KEY_ENTER, 0);
    try check(@src(), std.mem.eql(u8, t.name, "Inline tab name"));
    commands.togglePin(app, t);
    try check(@src(), t.pinned and app.tabs.items[0] == t);
    try check(@src(), !commands.closeIfSaved(app, t));
    commands.togglePin(app, t);
    commands.closeNow(app, t);
    chord(ui, app, c.CUI_KEY_T, c.CUI_MOD_PRIMARY | c.CUI_MOD_SHIFT);
    try check(@src(), app.current() == t and std.mem.eql(u8, t.url.text(), "https://example.invalid/reopen"));
    // A drop in Body attaches the file without loading its contents.
    t.pane = .body;
    t.details_collapsed = false;
    for (0..3) |_| frame(ui, app);
    c.cui_push_id_int(ui, @intCast(t.uid));
    const area = c.cui_get_rect(ui, c.cui_make_id(ui, "request-body-drop"));
    c.cui_pop_id(ui);
    try check(@src(), area.h > 0);
    const paths = [_][*c]const u8{"C:/tmp/body.bin"};
    c.cui_input_file_drop(ui, &paths, 1, area.x + 10, area.y + 10);
    frame(ui, app);
    try check(@src(), t.body_kind == .file and std.mem.eql(u8, t.file_path.text(), "C:/tmp/body.bin"));
    commands.closeNow(app, t);
    const imports = [_][*c]const u8{"tests/fixtures/postman_v21.json"};
    c.cui_input_file_drop(ui, &imports, 1, 5, 5);
    frame(ui, app);
    try check(@src(), app.modal_open and app.modal == .import_preview and app.preview != null);
    app.modal_open = false;
    if (app.preview) |preview| App.freePreview(app.gpa, preview);
    app.preview = null;
    for (app.tabs.items, 0..) |tab, i| if (tab == original) {
        commands.activate(app, i);
        break;
    };
    app.selection.clearRetainingCapacity();
    app.selected = null;
    std.debug.print("CUI workspace UX: F2 inline commit, range/toggle selection, bulk move/delete/Undo, request-file recovery, pinned bulk-close protection, Ctrl Shift T and file-body drop passed\n", .{});
}
