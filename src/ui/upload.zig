//! Shared file selection and explicit metadata for binary/multipart bodies.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const TextBuffer = @import("model.zig").TextBuffer;
const variables = @import("../core/variables.zig");
const metadata = @import("../app/upload_info.zig");
const prepare = @import("../network/prepare.zig");
pub const Path = struct { resolved: []const u8 = "", problem: ?[]const u8 = null };

pub fn resolve(a: std.mem.Allocator, configured: []const u8, vars: []const variables.Var) Path {
    if (configured.len == 0) return .{ .problem = "Choose a file or enter its path" };
    var from: usize = 0;
    while (variables.nextReference(configured, from)) |ref| : (from = ref.end) {
        if (variables.lookup(vars, ref.name) == null) return .{ .problem = "Unresolved file-path variable; inspect the active environment" };
    }
    const path = if (variables.nextReference(configured, 0) != null) variables.resolve(a, configured, vars) catch return .{ .problem = "Couldn't resolve the file path" } else configured;
    if (path.len == 0) return .{ .problem = "The file path resolves to an empty value" };
    if (path.len >= std.Io.Dir.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return .{ .problem = "The file path is not valid" };
    return .{ .resolved = path };
}

fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.wake();
}

pub fn info(app: *App, path: []const u8, refresh: bool) metadata.Info {
    if (refresh) app.uploads.invalidate(path);
    return app.uploads.lookup(path, .{ .ctx = app, .call = wake });
}

/// Cancel/error leaves the configured value and all draft buffers untouched.
pub fn choose(app: *App, target: *TextBuffer) bool {
    const selected = pick(app) catch {
        app.toast(.warning, "File picker unavailable", "Couldn't open the file picker. You can enter a path directly.");
        return false;
    } orelse return false;
    defer app.gpa.free(selected);
    if (!target.reserve(selected.len)) {
        app.toast(.warning, "File path was kept", "Couldn't store the new file path");
        return false;
    }
    app.uploads.invalidate(selected);
    if (std.mem.eql(u8, target.text(), selected)) return false;
    target.set(selected);
    return true;
}

fn pick(app: *App) !?[]u8 {
    if (app.choose_upload) |picker| return picker(app.gpa);
    const paths = try @import("platform.zig").dialog.open(app.gpa, .{ .title = "Choose upload file" }) orelse return null;
    defer app.gpa.free(paths);
    if (paths.len == 0) return null;
    for (paths[1..]) |path| app.gpa.free(path);
    return paths[0];
}

pub fn details(ui: *c.cui_ctx, app: *App, configured: []const u8, vars: []const variables.Var) void {
    const path = resolve(w.arena.allocator(), configured, vars);
    if (path.problem) |problem| {
        w.text(ui, problem, .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(c.CUI_TOKEN_WARNING) });
        return;
    }
    w.row(ui, .{ .width = w.fill, .gap = 6, .min_height = 28 });
    w.text(ui, prepare.basename(path.resolved), .{ .width = w.fill, .font = c.CUI_FONT_MEDIUM, .size = c.KEST_TEXT_BODY });
    const refresh = w.action(ui, "refresh-file-info", "", c.CUI_ICON_ROTATE_CCW, false, 28, 28, 3);
    c.kest_tooltip(ui, "Refresh");
    w.end(ui);
    const result = info(app, path.resolved, refresh);
    if (result.status == .ready) {
        w.row(ui, .{ .id = "upload-size", .width = w.fill });
        w.text(ui, w.bytes(result.size), .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        w.end(ui);
    }
    if (result.status != .ready) w.text(ui, metadata.message(result.status), .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(if (result.status == .checking) c.CUI_TOKEN_TEXT_SECONDARY else c.CUI_TOKEN_DANGER) });
}

pub fn binary(ui: *c.cui_ctx, app: *App, t: *@import("../app/tab.zig").Tab) bool {
    var changed = false;
    w.row(ui, .{ .id = "upload-controls", .width = w.fill, .height = w.px(36), .pad_left = 4, .pad_right = 12, .gap = 6 });
    changed = w.flatField(ui, "file-path", &t.file_path, .{ .width = w.fill, .placeholder = "File path" }, false);
    if (w.action(ui, "choose-upload", if (t.file_path.len == 0) "Choose file" else "Change file", c.CUI_ICON_FOLDER_OPEN, false, 112, 32, 3)) changed = choose(app, &t.file_path) or changed;
    if (t.file_path.len > 0) {
        if (w.action(ui, "remove-upload", "", c.CUI_ICON_X, false, 28, 32, 3)) {
            t.file_path.clear();
            changed = true;
        }
        c.kest_tooltip(ui, "Remove file");
    }
    w.end(ui);
    w.column(ui, .{ .id = "upload-metadata", .width = w.fill, .height = w.fill, .pad_x = 12, .pad_top = 4, .pad_bottom = 8 });
    c.cui_scroll_begin(ui, &.{ .id = "upload-details", .width = w.fill, .height = w.fill, .gap = 4 });
    if (t.file_path.len > 0) details(ui, app, t.file_path.text(), app.activeVars());
    c.cui_scroll_end(ui);
    w.end(ui);
    if (changed) c.cui_request_redraw(ui);
    return changed;
}
