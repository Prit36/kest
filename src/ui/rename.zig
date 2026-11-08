//! Inline rename is a short editing session: replace the name, accept, or cancel.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const state = @import("../app/state.zig");
const tree = @import("../app/tree_ops.zig");
const persist = @import("../app/persist.zig");
pub fn begin(app: *state.App, action: state.NameAction, name: []const u8) void {
    // Starting another rename finishes the previous one first.
    if (app.rename_action != null) commit(app);
    if (!app.rename_text.reserve(name.len)) return;
    if (action == .rename_node) @import("sidebar.zig").revealRename(app, action.rename_node);
    app.rename_action = action;
    app.rename_text.set(name);
    app.rename_session +%= 1;
    app.rename_field = 0;
    app.rename_started = false;
    app.rename_invalid = false;
}
fn commit(app: *state.App) void {
    const name = std.mem.trim(u8, app.rename_text.text(), " \t\r\n");
    // Leaving an empty editor restores the original name.
    if (name.len > 0) switch (app.rename_action orelse return) {
        .rename_node => |n| if (!std.mem.eql(u8, n.name, name)) {
            tree.rename(app, n, name);
        },
        .rename_env => |e| if (!std.mem.eql(u8, e.name, name)) {
            tree.renameEnv(app, e, name);
        },
        .rename_tab => |t| if (!std.mem.eql(u8, t.name, name)) {
            @import("../app/tab.zig").setOwned(app.gpa, &t.name, name) catch return;
            persist.touchTab(app, t);
        },
        else => {},
    };
    app.rename_action = null;
}
/// Runs before the tree/tabs process keys or pointer presses.
pub fn process(ui: *c.cui_ctx, app: *state.App) bool {
    if (app.rename_action == null) return false;
    if (!app.rename_started) return true;
    if (c.cui_key_pressed(ui, c.CUI_KEY_ESCAPE)) {
        c.kest_consume_key(ui, c.CUI_KEY_ESCAPE);
        app.rename_action = null;
        c.kest_set_focus(ui, app.rename_owner);
        return true;
    }
    const enter = c.cui_key_pressed(ui, c.CUI_KEY_ENTER);
    const tab = c.cui_key_pressed(ui, c.CUI_KEY_TAB);
    if (enter or tab) {
        if (enter) c.kest_consume_key(ui, c.CUI_KEY_ENTER);
        // Enter keeps an invalid name editable and selected for replacement.
        if (enter and std.mem.trim(u8, app.rename_text.text(), " \t\r\n").len == 0) {
            app.rename_invalid = true;
            c.kest_rename_select_all(ui, app.rename_field, @intCast(app.rename_text.len));
            return true;
        }
        commit(app);
        if (enter) c.kest_set_focus(ui, app.rename_owner);
        return true;
    }
    const outside = c.kest_left_pressed(ui) and !c.kest_pointer_over(ui, app.rename_field);
    if (outside or c.kest_get_focus(ui) != app.rename_field or app.modal_open or app.palette_open) {
        commit(app);
        return false;
    }
    return true;
}
pub fn field(ui: *c.cui_ctx, app: *state.App, owner: c.cui_id) void {
    const key = w.fmt("inline-rename-{d}", .{app.rename_session});
    const start = !app.rename_started;
    app.rename_field = c.cui_make_id(ui, key);
    app.rename_owner = owner;
    if (!app.rename_text.reserve(@max(4096, app.rename_text.len + 256))) return;
    const flags = c.kest_rename_input(ui, key, app.rename_text.data.ptr, app.rename_text.data.len, start, app.rename_invalid);
    if (flags & c.CUI_CHANGED != 0) {
        app.rename_text.len = std.mem.indexOfScalar(u8, app.rename_text.data, 0) orelse app.rename_text.data.len - 1;
        app.rename_invalid = false;
    }
    if (app.rename_invalid) c.kest_tooltip(ui, "Enter a name, or press Escape to keep the original.");
    app.rename_started = true;
}
