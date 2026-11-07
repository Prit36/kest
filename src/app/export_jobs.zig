//! Explicit exports run on the store writer, with owned bytes or a pinned
//! completed response. Clearing a tab cannot delete a body being exported.
const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const Job = @import("../network/http_client.zig").Job;
const Export = struct { path: []u8, bytes: ?[]u8 = null, job: ?*Job = null };
pub fn bytes(store: *Store, path: []const u8, text: []const u8) !void {
    const ex = try create(store, path);
    errdefer free(store, ex);
    ex.bytes = try store.gpa.dupe(u8, text);
    try store.submit(ex, write);
}
pub fn response(store: *Store, path: []const u8, job: *Job) !void {
    const ex = try create(store, path);
    errdefer free(store, ex);
    job.retain();
    ex.job = job;
    try store.submit(ex, write);
}
fn create(s: *Store, path: []const u8) !*Export {
    const ex = try s.gpa.create(Export);
    errdefer s.gpa.destroy(ex);
    ex.* = .{ .path = try s.gpa.dupe(u8, path) };
    return ex;
}
fn free(s: *Store, ex: *Export) void {
    s.gpa.free(ex.path);
    if (ex.bytes) |b| s.gpa.free(b);
    if (ex.job) |j| j.destroy();
    s.gpa.destroy(ex);
}
fn write(s: *Store, raw: *anyopaque) !void {
    const ex: *Export = @ptrCast(@alignCast(raw));
    defer free(s, ex);
    if (ex.job) |j| return j.resp.saveTo(ex.path);
    var af = try std.Io.Dir.cwd().createFileAtomic(s.io, ex.path, .{ .replace = true });
    defer af.deinit(s.io);
    try af.file.writeStreamingAll(s.io, ex.bytes.?);
    try af.replace(s.io);
}
