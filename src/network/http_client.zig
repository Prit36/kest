//! Runs requests off the UI thread. A send is one job: a task doing the
//! transfer, and a supervisor that sleeps until it finishes, the user cancels,
//! or the timeout passes, then cancels the transfer through `std.Io`. Nothing
//! polls. Progress wakes the UI at most every 100 ms while bytes arrive.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const transport = @import("transport.zig");
const prepare_mod = @import("prepare.zig");
const req = @import("../core/request.zig");
const variables = @import("../core/variables.zig");
const response = @import("../core/response.zig");

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// From a worker thread: bytes arrived. Must only schedule work.
    on_progress: ?*const fn (ctx: ?*anyopaque, job: *Job) void = null,
    /// From a worker thread, once: the job is finished and may be freed.
    on_done: *const fn (ctx: ?*anyopaque, job: *Job) void,
};

pub const Job = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    io: Io,
    client: *transport.Client,
    arena: std.heap.ArenaAllocator,
    out: transport.Outgoing,
    unresolved: []const []const u8,
    resp: response.Response,
    callbacks: Callbacks,
    timeout_ms: u32,
    /// Set to wake the supervisor: the transfer ended or Cancel was pressed.
    wake: Io.Event = .unset,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    timed_out: bool = false,
    last_progress_ms: i64 = 0,
    start_ms: i64 = 0,
    /// Whoever started the job: the tab it belongs to.
    user_data: ?*anyopaque = null,

    /// From any thread: stops the transfer soon.
    pub fn cancel(j: *Job) void {
        j.cancel_requested.store(true, .release);
        j.wake.set(j.io);
    }

    pub fn destroy(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        j.resp.deinit();
        j.arena.deinit();
        j.gpa.destroy(j);
    }
    pub fn retain(j: *Job) void {
        _ = j.refs.fetchAdd(1, .monotonic);
    }

    /// The elapsed time while it runs.
    pub fn elapsedMs(j: *const Job) i64 {
        return Io.Clock.awake.now(j.io).toMilliseconds() - j.start_ms;
    }
};

pub const StartError = prepare_mod.Error || error{ConcurrencyUnavailable};

pub const Options = struct {
    /// Where bodies that outgrow memory go, for as long as they're shown.
    spill_dir: []const u8,
    memory_limit: usize = response.default_memory_limit,
    user_data: ?*anyopaque = null,
};

/// Prepares and starts `r`. Failures before anything is sent are returned,
/// with the reason in `problem`, whose text lives in `problem_arena`.
pub fn start(gpa: Allocator, io: Io, client: *transport.Client, r: req.Request, vars: []const variables.Var, callbacks: Callbacks, options: Options, problem_arena: Allocator, problem: *prepare_mod.Problem) StartError!*Job {
    const j = try gpa.create(Job);
    errdefer gpa.destroy(j);
    j.* = .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .arena = .init(gpa),
        .out = undefined,
        .unresolved = &.{},
        .resp = response.Response.init(gpa, io, options.spill_dir),
        .callbacks = callbacks,
        .timeout_ms = r.settings.timeout_ms,
        .user_data = options.user_data,
        .start_ms = Io.Clock.awake.now(io).toMilliseconds(),
    };
    errdefer j.arena.deinit();
    j.resp.memory_limit = options.memory_limit;
    j.resp.max_bytes = r.settings.max_response_bytes;
    var inner: prepare_mod.Problem = .{};
    const prepared = prepare_mod.prepare(j.arena.allocator(), io, r, vars, &inner) catch |e| {
        problem.message = problem_arena.dupe(u8, inner.message) catch "";
        return e;
    };
    j.out = prepared.out;
    j.unresolved = prepared.unresolved;
    // The client's group outlives every job: shutting down cancels them all.
    client.jobs.concurrent(io, supervise, .{j}) catch return error.ConcurrencyUnavailable;
    return j;
}

fn supervise(j: *Job) void {
    const io = j.io;
    var result: transport.Result = .{};
    var task = io.concurrent(transfer, .{ j, &result }) catch {
        j.resp.setError("Too many requests are running");
        j.resp.stop = .failed;
        j.resp.failure = .other;
        j.resp.time_ms = @intCast(std.math.clamp(j.elapsedMs(), 0, std.math.maxInt(u32)));
        j.resp.timing_known = true;
        j.callbacks.on_done(j.callbacks.ctx, j);
        return;
    };
    const timeout: Io.Timeout = if (j.timeout_ms == 0) .none else .{ .duration = .{ .raw = .fromMilliseconds(j.timeout_ms), .clock = .awake } };
    j.wake.waitTimeout(io, timeout) catch |e| switch (e) {
        error.Timeout => j.timed_out = true,
        // The app is closing.
        error.Canceled => j.cancel_requested.store(true, .release),
    };
    if (j.timed_out or j.cancel_requested.load(.acquire)) {
        task.cancel(io);
    } else {
        task.await(io);
    }
    finish(j, result);
    j.callbacks.on_done(j.callbacks.ctx, j);
}

fn transfer(j: *Job, result: *transport.Result) void {
    defer j.wake.set(j.io);
    const sink: transport.Sink = .{ .ctx = j, .on_head = onHead, .on_data = onData };
    result.* = j.client.perform(j.arena.allocator(), j.out, sink);
}

fn onHead(ctx: *anyopaque, head: transport.Head) anyerror!void {
    const j: *Job = @ptrCast(@alignCast(ctx));
    try j.resp.onHead(head);
    notify(j, true);
}

fn onData(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const j: *Job = @ptrCast(@alignCast(ctx));
    try j.resp.onData(bytes);
    notify(j, false);
}

fn notify(j: *Job, force: bool) void {
    const f = j.callbacks.on_progress orelse return;
    const now = Io.Clock.awake.now(j.io).toMilliseconds();
    if (!force and now - j.last_progress_ms < 100) return;
    j.last_progress_ms = now;
    f(j.callbacks.ctx, j);
}

fn finish(j: *Job, result: transport.Result) void {
    const r = &j.resp;
    // Publish classification with the completed response, never parse a large
    // body in the UI's class()/navigation lookups. Include final stop state.
    defer r.inspectContent();
    r.closeSpill();
    r.reused_connection = result.reused_connection;
    r.time_ms = @intCast(std.math.clamp(j.elapsedMs(), 0, std.math.maxInt(u32)));
    r.timing_known = true;
    r.failure = result.failure;
    if (j.timed_out) {
        r.stop = .timed_out;
        r.setError(std.fmt.allocPrint(j.arena.allocator(), "No complete answer within {d} ms", .{j.timeout_ms}) catch "Timed out");
        return;
    }
    if (j.cancel_requested.load(.acquire) and result.failure != .none) {
        r.stop = .canceled;
        r.setError("Canceled");
        return;
    }
    switch (result.failure) {
        .none => r.stop = .complete,
        .canceled => {
            r.stop = .canceled;
            r.setError("Canceled");
        },
        .stopped_by_sink => {
            // The size limit, or a disk that filled up.
            if (r.stop == .too_large) {
                r.setError(std.fmt.allocPrint(j.arena.allocator(), "Stopped at the {d} byte response limit", .{r.max_bytes}) catch "Stopped at the response limit");
            } else {
                r.stop = .failed;
                r.setError(std.fmt.allocPrint(j.arena.allocator(), "Couldn't keep the response: {s}", .{result.detail}) catch "Couldn't keep the response");
            }
        },
        else => {
            r.stop = .failed;
            r.setError(explain(j.arena.allocator(), result));
        },
    }
}

fn explain(a: Allocator, res: transport.Result) []const u8 {
    const summary: []const u8 = switch (res.failure) {
        .none, .canceled, .stopped_by_sink => "",
        .invalid_url => "The URL isn't valid",
        .invalid_header => "A header isn't valid",
        .dns => "The host name couldn't be resolved",
        .refused => "The connection was refused",
        .unreachable_host => "The host can't be reached",
        .tls_handshake => "The TLS handshake failed",
        .tls_certificate => "The server's certificate couldn't be verified. If you trust this host, turn off certificate verification in Settings.",
        .too_many_redirects => "Too many redirects",
        .protocol => "The server's answer isn't valid HTTP",
        .connection_lost => "The connection was lost",
        .file => "A file to send couldn't be read",
        .other => "The request failed",
    };
    if (res.detail.len == 0) return summary;
    return std.fmt.allocPrint(a, "{s} ({s})", .{ summary, res.detail }) catch summary;
}
