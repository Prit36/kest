//! The data folder: reads, atomic writes, and a background writer so the UI
//! never waits on a disk. Writes to one path coalesce: only the latest bytes
//! are written. Paths are relative to the data folder and checked: nothing a
//! file says can make the app read or write outside it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Whether `rel` stays inside the folder: no absolute paths, drives or "..".
pub fn safeRelative(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, rel, ':') != null) return false;
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

pub const max_file = 256 * 1024 * 1024;

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    /// The folder's absolute path.
    path: []const u8,
    lock: Io.Mutex = .init,
    wake: Io.Condition = .init,
    /// In order of first request; one entry per path.
    pending: std.ArrayList(Pending) = .empty,
    tasks: std.ArrayList(WriterTask) = .empty,
    busy: bool = false,
    stopping: bool = false,
    task: ?Io.Future(void) = null,
    /// The last write that failed (for a warning), owned; cleared when read.
    failure: ?[]u8 = null,
    /// The relative path of that write, owned; read with `takeFailedPath`.
    failure_path: ?[]u8 = null,
    /// Called from the writer's thread when `failure` is set.
    on_failure: ?*const fn (ctx: ?*anyopaque) void = null,
    on_failure_ctx: ?*anyopaque = null,

    const Pending = struct {
        path: []u8,
        /// Null: delete the file, or with `tree` the folder.
        bytes: ?[]u8,
        tree: bool = false,
    };
    const WriterTask = struct { ctx: *anyopaque, run: *const fn (*Store, *anyopaque) anyerror!void };

    /// Explicit exports use the same writer as workspace writes. At most eight
    /// exports can wait; file paths come only from an explicit save operation.
    pub fn submit(s: *Store, ctx: *anyopaque, run: *const fn (*Store, *anyopaque) anyerror!void) !void {
        s.lock.lockUncancelable(s.io);
        if (s.tasks.items.len >= 8) {
            s.lock.unlock(s.io);
            return error.WriterQueueFull;
        }
        s.tasks.append(s.gpa, .{ .ctx = ctx, .run = run }) catch |e| {
            s.lock.unlock(s.io);
            return e;
        };
        s.wake.signal(s.io);
        s.lock.unlock(s.io);
        if (s.task == null) s.flushNow();
    }

    pub fn open(gpa: Allocator, io: Io, path: []const u8) !Store {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
        return .{ .gpa = gpa, .io = io, .dir = dir, .path = path };
    }

    /// Starts the writer. Before this (and in tests) writes happen at once.
    pub fn startWriter(s: *Store) !void {
        s.task = try s.io.concurrent(writerLoop, .{s});
    }

    /// Finishes every write, then stops. Called on the way out.
    pub fn close(s: *Store) void {
        if (s.task) |*task| {
            s.lock.lockUncancelable(s.io);
            s.stopping = true;
            s.wake.signal(s.io);
            s.lock.unlock(s.io);
            task.await(s.io);
            s.task = null;
        }
        s.flushNow();
        s.pending.deinit(s.gpa);
        s.tasks.deinit(s.gpa);
        if (s.failure) |f| s.gpa.free(f);
        if (s.failure_path) |f| s.gpa.free(f);
        s.dir.close(s.io);
    }

    /// Takes a copy of `bytes`; the write happens soon, off this thread.
    pub fn write(s: *Store, rel: []const u8, bytes: []const u8) void {
        const copy = s.gpa.dupe(u8, bytes) catch return s.noteFailure(rel, error.OutOfMemory);
        s.enqueue(rel, copy, false);
    }

    /// Takes ownership of `bytes`.
    pub fn writeOwned(s: *Store, rel: []const u8, bytes: []u8) void {
        s.enqueue(rel, bytes, false);
    }

    pub fn delete(s: *Store, rel: []const u8) void {
        s.enqueue(rel, null, false);
    }

    pub fn deleteTree(s: *Store, rel: []const u8) void {
        s.enqueue(rel, null, true);
    }

    fn enqueue(s: *Store, rel: []const u8, bytes: ?[]u8, tree: bool) void {
        if (!safeRelative(rel)) {
            if (bytes) |b| s.gpa.free(b);
            return s.noteFailure(rel, error.UnsafePath);
        }
        s.lock.lockUncancelable(s.io);
        for (s.pending.items) |*p| {
            if (!std.mem.eql(u8, p.path, rel)) continue;
            if (p.bytes) |old| s.gpa.free(old);
            p.bytes = bytes;
            p.tree = tree;
            s.lock.unlock(s.io);
            return;
        }
        const path = s.gpa.dupe(u8, rel) catch {
            s.lock.unlock(s.io);
            if (bytes) |b| s.gpa.free(b);
            return s.noteFailure(rel, error.OutOfMemory);
        };
        s.pending.append(s.gpa, .{ .path = path, .bytes = bytes, .tree = tree }) catch {
            s.lock.unlock(s.io);
            s.gpa.free(path);
            if (bytes) |b| s.gpa.free(b);
            return s.noteFailure(rel, error.OutOfMemory);
        };
        s.wake.signal(s.io);
        s.lock.unlock(s.io);
        if (s.task == null) s.flushNow();
    }

    fn writerLoop(s: *Store) void {
        const prev = s.io.swapCancelProtection(.blocked);
        defer _ = s.io.swapCancelProtection(prev);
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (true) {
            while (s.pending.items.len == 0 and s.tasks.items.len == 0) {
                s.busy = false;
                if (s.stopping) return;
                s.wake.waitUncancelable(s.io, &s.lock);
            }
            s.busy = true;
            if (s.pending.items.len == 0) {
                const task = s.tasks.orderedRemove(0);
                s.lock.unlock(s.io);
                task.run(s, task.ctx) catch |e| s.noteFailure("export", e);
                s.lock.lockUncancelable(s.io);
                continue;
            }
            const job = s.pending.orderedRemove(0);
            s.lock.unlock(s.io);
            s.perform(job);
            s.lock.lockUncancelable(s.io);
        }
    }

    /// Everything pending, on this thread.
    fn flushNow(s: *Store) void {
        while (true) {
            s.lock.lockUncancelable(s.io);
            if (s.pending.items.len == 0) {
                if (s.tasks.items.len > 0) {
                    const task = s.tasks.orderedRemove(0);
                    s.lock.unlock(s.io);
                    task.run(s, task.ctx) catch |e| s.noteFailure("export", e);
                    continue;
                }
                s.lock.unlock(s.io);
                return;
            }
            const job = s.pending.orderedRemove(0);
            s.lock.unlock(s.io);
            s.perform(job);
        }
    }

    fn perform(s: *Store, job: Pending) void {
        defer s.gpa.free(job.path);
        defer if (job.bytes) |b| s.gpa.free(b);
        if (job.bytes) |b| {
            s.writeAtomic(job.path, b) catch |e| s.noteFailure(job.path, e);
        } else if (job.tree) {
            s.dir.deleteTree(s.io, job.path) catch |e| s.noteFailure(job.path, e);
        } else {
            s.dir.deleteFile(s.io, job.path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => s.noteFailure(job.path, e),
            };
        }
    }

    /// A reader sees the old file or the new one, never part of one: the
    /// bytes go to a temporary file, which then replaces the old.
    pub fn writeAtomic(s: *Store, rel: []const u8, bytes: []const u8) !void {
        if (!safeRelative(rel)) return error.UnsafePath;
        var af = try s.dir.createFileAtomic(s.io, rel, .{ .make_path = true, .replace = true });
        defer af.deinit(s.io);
        try af.file.writeStreamingAll(s.io, bytes);
        try af.replace(s.io);
    }

    fn noteFailure(s: *Store, rel: []const u8, e: anyerror) void {
        const text = std.fmt.allocPrint(s.gpa, "Couldn't save {s}: {s}", .{ rel, @errorName(e) }) catch return;
        const path = s.gpa.dupe(u8, rel) catch null;
        s.lock.lockUncancelable(s.io);
        if (s.failure) |old| s.gpa.free(old);
        s.failure = text;
        if (s.failure_path) |old| s.gpa.free(old);
        s.failure_path = path;
        s.lock.unlock(s.io);
        if (s.on_failure) |f| f(s.on_failure_ctx);
    }

    /// The last failure, now the caller's to free.
    pub fn takeFailure(s: *Store) ?[]u8 {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const f = s.failure;
        s.failure = null;
        return f;
    }

    /// Whether the most recent unreported failure was a write of `rel`.
    pub fn lastFailureIs(s: *Store, rel: []const u8) bool {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        return if (s.failure_path) |p| std.mem.eql(u8, p, rel) else false;
    }

    /// The path whose write failed last, now the caller's to free.
    pub fn takeFailedPath(s: *Store) ?[]u8 {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const f = s.failure_path;
        s.failure_path = null;
        return f;
    }

    /// Waits for what's queued: tests, and before reading back.
    pub fn sync(s: *Store) void {
        if (s.task == null) return s.flushNow();
        while (true) {
            s.lock.lockUncancelable(s.io);
            const done = s.pending.items.len == 0 and s.tasks.items.len == 0 and !s.busy;
            s.lock.unlock(s.io);
            if (done) return;
            s.io.sleep(.fromMilliseconds(2), .awake) catch return;
        }
    }

    /// The file's bytes, or null if it isn't there. Other errors are returned.
    pub fn read(s: *Store, a: Allocator, rel: []const u8) !?[]u8 {
        if (!safeRelative(rel)) return error.UnsafePath;
        return s.dir.readFileAlloc(s.io, rel, a, .limited(max_file)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    /// A file's modification time (ns), or null if it isn't there.
    pub fn mtime(s: *Store, rel: []const u8) ?i96 {
        const st = s.dir.statFile(s.io, rel, .{}) catch return null;
        return st.mtime.toNanoseconds();
    }

    /// Whether a write to this path is still queued.
    pub fn isPending(s: *Store, rel: []const u8) bool {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        for (s.pending.items) |p| if (std.mem.eql(u8, p.path, rel)) return true;
        return s.busy;
    }
};

const t = std.testing;

fn tempStore(tmp: *std.testing.TmpDir, buf: []u8) !Store {
    const n = try tmp.dir.realPath(t.io, buf);
    return Store.open(t.allocator, t.io, buf[0..n]);
}

test "paths can't leave the folder" {
    try t.expect(safeRelative("collections/abc/collection.json"));
    try t.expect(!safeRelative("../evil"));
    try t.expect(!safeRelative("a/../../evil"));
    try t.expect(!safeRelative("a\\..\\evil"));
    try t.expect(!safeRelative("/etc/passwd"));
    try t.expect(!safeRelative("\\windows"));
    try t.expect(!safeRelative("C:\\windows"));
    try t.expect(!safeRelative(""));
    try t.expect(!safeRelative("a/./b"));
}

test "writes are atomic, coalesce, and survive a reopen" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var s = try tempStore(&tmp, &buf);
    try s.startWriter();
    for (0..50) |i| {
        var line: [32]u8 = undefined;
        s.write("a/b/c.json", try std.fmt.bufPrint(&line, "version {d}", .{i}));
    }
    s.write("other.json", "x");
    s.close();

    var again = try tempStore(&tmp, &buf);
    defer again.close();
    const c = (try again.read(t.allocator, "a/b/c.json")).?;
    defer t.allocator.free(c);
    try t.expectEqualStrings("version 49", c);
    try t.expect(again.mtime("a/b/c.json") != null);
    try t.expect(try again.read(t.allocator, "missing.json") == null);
    try t.expect(again.mtime("missing.json") == null);
}

test "delete, and a delete after a queued write wins" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var s = try tempStore(&tmp, &buf);
    defer s.close();
    s.write("f.json", "1");
    s.delete("f.json");
    s.delete("never-there.json");
    s.sync();
    try t.expect(try s.read(t.allocator, "f.json") == null);
    s.write("d/e/f.json", "1");
    s.deleteTree("d");
    s.sync();
    try t.expect(try s.read(t.allocator, "d/e/f.json") == null);
    try t.expect(s.takeFailure() == null);
}

test "an unsafe path is refused and reported" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var s = try tempStore(&tmp, &buf);
    defer s.close();
    s.write("../outside.json", "x");
    const f = s.takeFailure().?;
    defer t.allocator.free(f);
    try t.expect(std.mem.indexOf(u8, f, "UnsafePath") != null);
    try t.expectError(error.UnsafePath, s.read(t.allocator, "../outside.json"));
    try t.expect(tmp.parent_dir.statFile(t.io, "outside.json", .{}) == error.FileNotFound);
}
