const std = @import("std");
const c = @import("c.zig").c;
pub var window: ?*c.cui_app = null;
pub var context: ?*c.cui_ctx = null;
pub var headless = false;
/// False while the window paints in software and OpenGL is still loading.
pub var renderer_final = true;
pub const dialog = struct {
    pub fn open(gpa: std.mem.Allocator, opts: struct { title: []const u8, extensions: []const []const u8 = &.{} }) !?[][]u8 {
        if (headless) return null;
        const title = try gpa.dupeSentinel(u8, opts.title, 0);
        defer gpa.free(title);
        const filter = try std.mem.joinZ(gpa, ";", opts.extensions);
        defer gpa.free(filter);
        var path: [32768]u8 = undefined;
        if (!c.cui_app_file_dialog(window, &.{ .kind = c.CUI_FILE_OPEN, .title = title, .filter_name = "Files", .filter = filter }, &path, path.len)) return null;
        const out = try gpa.alloc([]u8, 1);
        errdefer gpa.free(out);
        out[0] = try gpa.dupe(u8, std.mem.sliceTo(&path, 0));
        return out;
    }
    pub fn save(gpa: std.mem.Allocator, opts: struct { title: []const u8, name: []const u8 }) !?[]u8 {
        if (headless) return null;
        const title = try gpa.dupeSentinel(u8, opts.title, 0);
        defer gpa.free(title);
        const name = try gpa.dupeSentinel(u8, opts.name, 0);
        defer gpa.free(name);
        var path: [32768]u8 = undefined;
        if (!c.cui_app_file_dialog(window, &.{ .kind = c.CUI_FILE_SAVE, .title = title, .default_name = name }, &path, path.len)) return null;
        return try gpa.dupe(u8, std.mem.sliceTo(&path, 0));
    }
};
