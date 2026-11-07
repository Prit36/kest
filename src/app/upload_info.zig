//! Bounded, event-driven file metadata. No stat/open runs on the UI thread.
//! Cache ownership is separate from worker ownership; edits/closed tabs cannot
//! leave workers holding pointers into mutable UI buffers or destroyed rows.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Status = enum { checking, ready, missing, denied, not_file, invalid, unavailable };
pub const Info = struct { status: Status = .checking, size: u64 = 0 };
pub const Wake = struct { ctx: *anyopaque, call: *const fn (*anyopaque) void };
pub const capacity = 16;
pub const max_running = 4;

const Job = struct {
    gpa: Allocator,
    owner: *Cache,
    path: []u8,
    wake: Wake,
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    result: Info = .{},
    stamp: u64,

    fn release(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        j.gpa.free(j.path);
        j.gpa.destroy(j);
    }
};

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    group: Io.Group = .init,
    running: std.atomic.Value(u32) = .init(0),
    entries: [capacity]?*Job = @splat(null),
    clock: u64 = 0,
    /// Diagnostic counters; neither starts a timer nor causes redraws.
    started: u64 = 0,

    pub fn init(gpa: Allocator, io: Io) Cache {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(cache: *Cache) void {
        cache.group.cancel(cache.io);
        for (&cache.entries) |*entry| if (entry.*) |job| {
            job.release();
            entry.* = null;
        };
    }

    pub fn invalidate(cache: *Cache, path: []const u8) void {
        for (&cache.entries) |*entry| if (entry.*) |job| {
            if (std.mem.eql(u8, job.path, path)) {
                entry.* = null;
                job.release();
            }
        };
    }

    pub fn lookup(cache: *Cache, path: []const u8, wake: Wake) Info {
        if (path.len == 0 or path.len > Io.Dir.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return .{ .status = .invalid };
        cache.clock +%= 1;
        var slot: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (cache.entries, 0..) |entry, i| {
            if (entry) |job| {
                if (std.mem.eql(u8, job.path, path)) {
                    job.stamp = cache.clock;
                    return if (job.done.load(.acquire)) job.result else .{};
                }
                if (job.stamp < oldest) {
                    oldest = job.stamp;
                    slot = i;
                }
            } else {
                slot = i;
                oldest = 0;
            }
        }
        // A completion wakes the UI, where the current query can try again.
        if (cache.running.load(.acquire) >= max_running) return .{};
        const job = cache.gpa.create(Job) catch return .{ .status = .unavailable };
        const owned = cache.gpa.dupe(u8, path) catch {
            cache.gpa.destroy(job);
            return .{ .status = .unavailable };
        };
        job.* = .{ .gpa = cache.gpa, .owner = cache, .path = owned, .wake = wake, .stamp = cache.clock };
        if (cache.entries[slot]) |old| old.release();
        cache.entries[slot] = job;
        _ = cache.running.fetchAdd(1, .acq_rel);
        cache.group.concurrent(cache.io, inspect, .{job}) catch {
            _ = cache.running.fetchSub(1, .acq_rel);
            job.result = .{ .status = .unavailable };
            job.done.store(true, .release);
            job.release();
            return .{ .status = .unavailable };
        };
        cache.started += 1;
        return if (job.done.load(.acquire)) job.result else .{};
    }
};

fn inspect(job: *Job) void {
    defer job.release();
    job.result = read(job.owner.io, job.path);
    job.done.store(true, .release);
    _ = job.owner.running.fetchSub(1, .acq_rel);
    job.wake.call(job.wake.ctx);
}

fn read(io: Io, path: []const u8) Info {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return .{ .status = failure(err) };
    if (stat.kind != .file) return .{ .status = .not_file };
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| return .{ .status = failure(err) };
    defer file.close(io);
    return .{ .status = .ready, .size = stat.size };
}

fn failure(err: anyerror) Status {
    return switch (err) {
        error.FileNotFound, error.NetworkNotFound, error.NotDir => .missing,
        error.AccessDenied, error.PermissionDenied => .denied,
        error.IsDir, error.NoDevice, error.PipeBusy => .not_file,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => .invalid,
        else => .unavailable,
    };
}

pub fn message(status: Status) []const u8 {
    return switch (status) {
        .checking => "Checking file...",
        .ready => "Size at last check; file is read again when sending.",
        .missing => "File not found. Choose another file or correct the path.",
        .denied => "The file cannot be opened for reading.",
        .not_file => "Choose a regular file, not a directory or device.",
        .invalid => "The file path is not valid.",
        .unavailable => "Could not check this file. Refresh to try again.",
    };
}

test "file metadata errors use stable explanations without paths or OS details" {
    const t = std.testing;
    try t.expectEqual(Status.denied, failure(error.AccessDenied));
    try t.expectEqual(Status.denied, failure(error.PermissionDenied));
    try t.expectEqual(Status.missing, failure(error.FileNotFound));
    try t.expectEqual(Status.not_file, failure(error.IsDir));
    try t.expectEqual(Status.invalid, failure(error.BadPathName));
    try t.expectEqual(Status.unavailable, failure(error.Canceled));
    try t.expect(std.mem.indexOf(u8, message(.denied), "cannot be opened") != null);
}
