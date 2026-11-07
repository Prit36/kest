//! Sends one request and prints what happened: a check of real TLS, by hand.
//!   zig build smoke -- https://example.com [--insecure]
const std = @import("std");
const lib = @import("retort");
const Io = std.Io;

const Done = struct {
    ev: Io.Event = .unset,
    io: Io,
    fn onDone(ctx: ?*anyopaque, _: *lib.http_client.Job) void {
        const d: *Done = @ptrCast(@alignCast(ctx.?));
        d.ev.set(d.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const url = if (args.len > 1) args[1] else return error.NeedAUrl;
    const insecure = args.len > 2 and std.mem.eql(u8, args[2], "--insecure");
    var client = lib.transport.Client.init(init.gpa, init.io);
    defer client.deinit();
    var done: Done = .{ .io = init.io };
    var problem: lib.prepare.Problem = .{};
    const job = try lib.http_client.start(init.gpa, init.io, &client, .{ .url = url, .settings = .{ .verify_tls = !insecure } }, &.{}, .{ .ctx = &done, .on_done = Done.onDone }, .{ .spill_dir = "." }, init.arena.allocator(), &problem);
    defer job.destroy();
    try done.ev.wait(init.io);
    const r = &job.resp;
    std.debug.print("status {d} {s}\nstop {s}\nbytes {d}\ntime {d} ms\ntype {s}\nerror {s}\n", .{ r.status, r.reason, @tagName(r.stop), r.total.load(.monotonic), r.time_ms, r.content_type, r.error_text });
}
