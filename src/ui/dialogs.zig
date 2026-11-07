const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const state = @import("../app/state.zig");
const App = state.App;
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const tree = @import("../app/tree_ops.zig");
const imports = @import("../app/import_ops.zig");

pub fn askName(app: *App, action: state.NameAction, value: []const u8) void {
    app.name_action = action;
    app.name_text.set(value);
    app.name_text.focus();
    app.name_error = "";
    app.modal = .name;
    app.modal_open = true;
}
pub fn view(ui: *c.cui_ctx, app: *App) void {
    if (!app.modal_open) {
        // A Save as begun from a close prompt was dismissed: keep the tab.
        app.close_after_save = null;
        return;
    }
    const title: []const u8 = switch (app.modal) {
        .name => switch (app.name_action) {
            .new_collection => "New collection",
            .new_folder => "New folder",
            .new_request => "New request",
            .new_env => "New environment",
            .describe_node => "Description",
            else => "Rename",
        },
        .confirm => app.confirm_title,
        .import_preview => "Review import",
        .import_curl => "Import cURL",
        .save_as => "Save request",
        .move_to => "Move to",
        .environment => "Environment variables",
        .settings => "Workspace settings",
        .none => return,
    };
    const modal = app.modal;
    if (!c.cui_dialog_begin(ui, w.z(title), &app.modal_open, &.{ .width = if (modal == .environment) 600 else 480 })) return;
    defer c.cui_dialog_end(ui);
    var submit = false;
    switch (modal) {
        .name => {
            _ = w.field(ui, "name", &app.name_text, .{ .placeholder = "Name", .width = w.fill });
            submit = c.cui_key_pressed(ui, c.CUI_KEY_ENTER) and c.cui_key_mods(ui) == 0 and c.cui_wants_keyboard(ui);
            if (app.name_error.len > 0) w.text(ui, app.name_error, .{ .color = w.color(c.CUI_TOKEN_DANGER) });
        },
        .confirm => w.text(ui, app.confirm_detail, .{}),
        .import_curl => {
            if (app.curl_text.reserve(@max(4096, app.curl_text.len + 4096))) {
                _ = c.cui_textarea_ex(ui, "curl-command", app.curl_text.data.ptr, app.curl_text.data.len, &.{ .placeholder = "curl https://...", .height = 180 });
                app.curl_text.len = std.mem.indexOfScalar(u8, app.curl_text.data, 0) orelse 0;
            }
        },
        .import_preview => if (app.preview) |p| {
            w.text(ui, p.file_name, .{ .font = c.CUI_FONT_MEDIUM });
            if (p.document) |d| {
                w.text(ui, w.fmt("{d} requests  /  {d} duplicates", .{ d.countRequests(), p.duplicates_inside }), .{});
                var target: c_int = if (p.target) |i| @intCast(i + 1) else 0;
                const labels = w.arena.allocator().alloc([]const u8, app.collections.items.len + 1) catch unreachable;
                labels[0] = "New collection";
                for (app.collections.items, 1..) |item, i| labels[i] = item.name;
                if (w.select(ui, "import-target", labels, &target, w.fill)) {
                    p.target = if (target == 0) null else @intCast(target - 1);
                    imports.refreshDuplicates(app, p);
                }
            }
            if (p.environment) |e| w.text(ui, w.fmt("{s}: {d} variables", .{ e.name, e.vars.len }), .{});
            if (p.name_taken) w.text(ui, "This name already exists. A separate imported copy will be created.", .{ .size = 12, .color = w.color(c.CUI_TOKEN_WARNING) });
            c.cui_scroll_begin(ui, &.{ .id = "import-warnings", .height = w.px(@min(150, @as(f32, @floatFromInt(p.warnings.len * 36)))), .gap = 4 });
            for (p.warnings) |warning| w.text(ui, warning, .{ .size = 12, .color = w.color(c.CUI_TOKEN_WARNING) });
            c.cui_scroll_end(ui);
        },
        .save_as => {
            _ = w.field(ui, "save-name", &app.save_name, .{ .label = "Request name" });
            targets(ui, app, false);
            if (app.collections.items.len == 0) w.muted(ui, "Saving creates your first collection.");
        },
        .move_to => targets(ui, app, true),
        .environment => if (app.editing_env) |e| {
            w.row(ui, .{ .width = w.fill, .gap = 8 });
            c.cui_icon(ui, c.CUI_ICON_DATABASE, 15, w.color(if (app.active_env == e) c.CUI_TOKEN_ACCENT else c.CUI_TOKEN_TEXT_MUTED));
            w.text(ui, e.name, .{ .font = c.CUI_FONT_MEDIUM, .width = w.fill, .nowrap = true });
            if (app.active_env == e) w.text(ui, "Active", .{ .size = 12, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_SUCCESS), .nowrap = true }) else if (w.button(ui, "Use this environment", .{ .size = c.CUI_SIZE_SM, .variant = c.CUI_BUTTON_SECONDARY })) commands.setActiveEnv(app, e);
            w.end(ui);
            // Fit the table to its header, rows and insertion row,
            // bounded by the window, rather than reserving a fixed empty block.
            const rows: f32 = @floatFromInt(e.table.rows.items.len + 1);
            const wanted = 12 + c.KEST_TABLE_HEADER + 1 + rows * c.KEST_TABLE_STRIDE;
            w.column(ui, .{ .height = w.px(@max(64, @min(wanted, @min(320, c.cui_viewport_size(ui).y - 250)))) });
            c.cui_push_id(ui, w.z(&e.id));
            if (@import("key_value.zig").view(ui, &e.table, false, "Environment variables", .{})) {
                app.vars_dirty = true;
                persist.saveEnv(app, e);
            }
            c.cui_pop_id(ui);
            w.end(ui);
            w.text(ui, "Use {{name}} in URLs, headers and bodies. Changes save as you type.", .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .width = w.fill });
        },
        .settings => {
            if (c.cui_switch_ex(ui, "Save edits automatically", &app.prefs.autosave, &.{})) persist.prefsChanged(app);
            if (c.cui_switch_ex(ui, "Dark appearance", &app.prefs.dark, &.{})) persist.prefsChanged(app);
            if (w.field(ui, "retention", &app.retention_text, .{ .label = "History entries to keep (1-10000)" })) {
                app.prefs.retention = std.math.clamp(std.fmt.parseInt(u32, app.retention_text.text(), 10) catch 1000, 1, 10000);
                app.history.setRetention(app.prefs.retention);
                app.history_dirty = true;
                persist.prefsChanged(app);
            }
        },
        .none => {},
    }
    c.cui_dialog_footer_begin(ui);
    if (modal == .environment or modal == .settings) {
        if (w.button(ui, "Close", .{ .variant = c.CUI_BUTTON_PRIMARY })) app.modal_open = false;
        c.cui_dialog_footer_end(ui);
        return;
    }
    if (w.button(ui, "Cancel", .{ .variant = c.CUI_BUTTON_GHOST })) app.modal_open = false;
    // Closing a request with edits offers Save beside Discard and Cancel.
    const closing: ?*@import("../app/tab.zig").Tab = if (modal == .confirm) switch (app.pending) {
        .close_tab => |t| t,
        else => null,
    } else null;
    var save_close = false;
    const label: []const u8 = switch (modal) {
        .confirm => app.confirm_ok,
        .import_preview => "Import",
        .import_curl => "Review import",
        .save_as => "Save request",
        .move_to => "Move",
        .name => switch (app.name_action) {
            .new_collection, .new_folder, .new_request, .new_env => "Create",
            else => "Save",
        },
        else => "Done",
    };
    const ok = w.button(ui, label, .{ .variant = if (modal == .confirm) (if (closing != null) c.CUI_BUTTON_OUTLINE else c.CUI_BUTTON_DANGER) else c.CUI_BUTTON_PRIMARY });
    if (closing != null and w.button(ui, if (closing.?.link == null) "Save as..." else "Save", .{ .variant = c.CUI_BUTTON_PRIMARY })) save_close = true;
    c.cui_dialog_footer_end(ui);
    if (save_close) {
        app.modal_open = false;
        app.pending = .none;
        commands.saveAndClose(app, closing.?);
        return;
    }
    if (ok or submit) {
        app.modal_open = false;
        accept(app, modal);
    }
}

fn targets(ui: *c.cui_ctx, app: *App, moving: bool) void {
    c.cui_scroll_begin(ui, &.{ .id = "target-folders", .height = w.px(180), .gap = 2 });
    defer c.cui_scroll_end(ui);
    if (moving) {
        for (app.move_targets.items) |r| {
            if (w.action(ui, w.z(&r.node.id), r.node.name, c.CUI_ICON_FOLDER, app.save_target == r.node, -1, 30, 0)) app.save_target = r.node;
        }
    } else for (app.collections.items) |item| {
        if (w.action(ui, w.z(&item.id), item.name, c.CUI_ICON_FOLDER, app.save_target == item, -1, 30, 0)) app.save_target = item;
    }
}

fn accept(app: *App, modal: state.Modal) void {
    switch (modal) {
        .name => {
            const name = std.mem.trim(u8, app.name_text.text(), " \t\r\n");
            if (name.len == 0 and app.name_action != .describe_node) {
                app.name_error = "Enter a name.";
                app.modal_open = true;
                return;
            }
            switch (app.name_action) {
                .new_collection => app.selected = tree.newCollection(app, name),
                .new_folder => |parent| _ = tree.newFolder(app, parent, name),
                .new_request => |parent| if (tree.addRequest(app, parent, .{ .name = name })) |n| {
                    app.store.sync();
                    commands.openRequest(app, n);
                },
                .rename_node => |n| tree.rename(app, n, name),
                .describe_node => |n| {
                    @import("../core/collection.zig").setString(app.gpa, &n.description, name) catch {};
                    persist.saveTree(app, n.root());
                },
                .new_env => if (tree.addEnvironment(app, name)) |e| {
                    app.editing_env = e;
                    app.modal = .environment;
                    app.modal_open = true;
                },
                .rename_env => |e| tree.renameEnv(app, e, name),
                .rename_tab => |t| {
                    @import("../app/tab.zig").setOwned(app.gpa, &t.name, name) catch {};
                    persist.touchTab(app, t);
                },
            }
        },
        .confirm => commands.acceptPending(app),
        .import_curl => imports.previewText(app, app.curl_text.text(), "Pasted cURL"),
        .import_preview => imports.accept(app),
        .save_as => if (app.current()) |t| {
            const parent = app.save_target orelse (if (app.collections.items.len > 0) app.collections.items[0] else tree.newCollection(app, "My collection")) orelse return;
            tree.saveTabAs(app, t, tree.containerOf(parent), app.save_name.text());
            if (app.close_after_save == t) {
                app.close_after_save = null;
                if (!t.dirty and t.link != null) commands.closeNow(app, t);
            }
        },
        .move_to => if (app.move_node) |n| {
            if (app.save_target) |target| tree.moveTo(app, n, target);
        },
        else => {},
    }
}
