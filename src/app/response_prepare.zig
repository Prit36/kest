//! Lazy, bounded derived response views. Workers own retained immutable HTTP
//! jobs, never tabs/CUI contexts. Clearing a view drops its interest immediately;
//! the worker releases its separate ownership on completion. No polling timer.
const std = @import("std");
const http = @import("../network/http_client.zig");
const json = @import("../utils/json.zig");
const lines = @import("../utils/lines.zig");
const highlight = @import("../utils/highlight.zig");
const text_layout = @import("../core/text_layout.zig");
const response_search = @import("../core/response_search.zig");
const Tree = @import("../core/json_tree.zig").Tree;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_running = 2;
pub const max_input = 8 * 1024 * 1024;
pub const max_output = 16 * 1024 * 1024;
pub const max_nodes = 200_000;
pub const max_rows = 1_000_000;
pub const inline_limit = 64 * 1024;
pub const Kind = enum { pretty, minified, tree, html, image, raw };
pub const Failure = enum { input_limit, output_limit, node_limit, index_limit, image_limit, invalid, unavailable, incomplete, canceled };
pub const Wake = struct { ctx: *anyopaque, call: *const fn (*anyopaque) void };

pub const Pixels = struct {
    rgba: [*]u8,
    width: u32,
    height: u32,
    source_width: u32,
    source_height: u32,
    free: *const fn ([*]u8) void,
};
pub const Decoded = union(enum) { pixels: Pixels, failure: Failure };
pub const Decoder = struct { ctx: ?*anyopaque = null, decode: *const fn (?*anyopaque, []const u8) Decoded };

/// Immutable derived bytes shared with a reflow worker. Resizing never copies
/// or reformats the body, and clearing a tab cannot invalidate worker input.
pub const Bytes = struct {
    gpa: Allocator,
    bytes: []u8,
    refs: std.atomic.Value(u32) = .init(1),

    fn own(a: Allocator, bytes: []u8) !*Bytes {
        const value = try a.create(Bytes);
        value.* = .{ .gpa = a, .bytes = bytes };
        return value;
    }
    pub fn retain(value: *Bytes) void {
        _ = value.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(value: *Bytes) void {
        if (value.refs.fetchSub(1, .acq_rel) != 1) return;
        value.gpa.free(value.bytes);
        value.gpa.destroy(value);
    }
};

pub const Text = struct {
    bytes: []u8,
    owns_bytes: bool = true,
    owner: ?*Bytes = null,
    index: lines.Index = .{},
    strings: std.ArrayList(highlight.CrossRowString) = .empty,
    json_syntax: bool,

    pub fn deinit(value: *Text, a: Allocator) void {
        if (value.owner) |owner| owner.release() else if (value.owns_bytes) a.free(value.bytes);
        value.index.deinit(a);
        value.strings.deinit(a);
    }
};
pub const Result = union(enum) {
    none,
    text: Text,
    tree: Tree,
    pixels: Pixels,
    layout: text_layout.Layout,
    search: response_search.Result,
    failure: Failure,

    pub fn deinit(value: *Result, a: Allocator) void {
        switch (value.*) {
            .text => |*text| text.deinit(a),
            .tree => |*tree| tree.deinit(a),
            .pixels => |pixels| pixels.free(pixels.rgba),
            .layout => |*layout| layout.deinit(a),
            .search => |*search| search.deinit(a),
            else => {},
        }
        value.* = .none;
    }
};

pub const Job = struct {
    gpa: Allocator,
    owner: *Service,
    source: *http.Job,
    kind: Kind,
    decoder: ?Decoder,
    wake: Wake,
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    canceled: std.atomic.Value(bool) = .init(false),
    result: Result = .none,
    reflow: ?struct { text: []const u8, bytes: ?*Bytes, config: text_layout.Config, factory: text_layout.Factory } = null,
    lookup: ?struct { text: []const u8, bytes: ?*Bytes, query: []u8, options: response_search.Options, seek: response_search.Seek } = null,

    pub fn abandon(job: *Job) void {
        job.canceled.store(true, .release);
        job.release();
    }

    pub fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        job.result.deinit(job.gpa);
        if (job.reflow) |request| if (request.bytes) |bytes| bytes.release();
        if (job.lookup) |request| {
            if (request.bytes) |bytes| bytes.release();
            job.gpa.free(request.query);
        }
        job.source.destroy();
        job.gpa.destroy(job);
    }

    /// UI owner only; after the acquire the worker never touches the result.
    pub fn take(job: *Job) ?Result {
        if (!job.done.load(.acquire)) return null;
        const result = job.result;
        job.result = .none;
        return result;
    }
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    group: Io.Group = .init,
    running: std.atomic.Value(u32) = .init(0),
    started: u64 = 0,

    pub fn init(gpa: Allocator, io: Io) Service {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(service: *Service) void {
        // CPU work has fixed input/output/node/image bounds. Cancellation waits
        // for that work, so no worker/wake can outlive the app or the service.
        service.group.cancel(service.io);
    }

    /// Called on UI thread. Busy callers retry on a worker's completion wake.
    /// No source body copy, task queue, or automatic retry after allocation fail.
    pub fn start(service: *Service, source: *http.Job, kind: Kind, decoder: ?Decoder, wake: Wake) !*Job {
        if (source.resp.preview.items.len > max_input) return error.InputLimit;
        if (kind == .image and (source.resp.isPartial() or source.resp.stop != .complete)) return error.Incomplete;
        if (service.running.load(.acquire) >= max_running) return error.Busy;
        const job = try service.gpa.create(Job);
        job.* = .{ .gpa = service.gpa, .owner = service, .source = source, .kind = kind, .decoder = decoder, .wake = wake };
        return service.launch(job);
    }

    pub fn layout(service: *Service, source: *http.Job, text: []const u8, bytes: ?*Bytes, config: text_layout.Config, factory: text_layout.Factory, wake: Wake) !*Job {
        if (text.len > max_output) return error.InputLimit;
        if (service.running.load(.acquire) >= max_running) return error.Busy;
        const job = try service.gpa.create(Job);
        job.* = .{ .gpa = service.gpa, .owner = service, .source = source, .kind = .raw, .decoder = null, .wake = wake, .reflow = .{ .text = text, .bytes = bytes, .config = config, .factory = factory } };
        return service.launch(job);
    }

    pub fn find(service: *Service, source: *http.Job, text: []const u8, bytes: ?*Bytes, query: []const u8, options: response_search.Options, seek: response_search.Seek, wake: Wake) !*Job {
        if (text.len > response_search.max_input) return error.InputLimit;
        if (query.len > response_search.max_query) return error.QueryLimit;
        if (service.running.load(.acquire) >= max_running) return error.Busy;
        const job = try service.gpa.create(Job);
        const owned_query = service.gpa.dupe(u8, query) catch |err| {
            service.gpa.destroy(job);
            return err;
        };
        job.* = .{ .gpa = service.gpa, .owner = service, .source = source, .kind = .raw, .decoder = null, .wake = wake, .lookup = .{ .text = text, .bytes = bytes, .query = owned_query, .options = options, .seek = seek } };
        return service.launch(job);
    }

    fn launch(service: *Service, job: *Job) !*Job {
        job.source.retain();
        if (job.reflow) |request| if (request.bytes) |bytes| bytes.retain();
        if (job.lookup) |request| if (request.bytes) |bytes| bytes.retain();
        _ = service.running.fetchAdd(1, .acq_rel);
        service.group.concurrent(service.io, run, .{job}) catch {
            _ = service.running.fetchSub(1, .acq_rel);
            job.refs.store(1, .monotonic);
            job.release();
            return error.ConcurrencyUnavailable;
        };
        service.started += 1;
        return job;
    }
};

fn run(job: *Job) void {
    defer job.release();
    var result: Result = if (job.canceled.load(.acquire)) .{ .failure = .canceled } else if (job.reflow != null) reflow(job) else if (job.lookup != null) runSearch(job) else prepare(job.gpa, job.source.resp.preview.items, job.kind, job.decoder);
    if (job.canceled.load(.acquire)) {
        result.deinit(job.gpa);
        result = .{ .failure = .canceled };
    }
    job.result = result;
    job.done.store(true, .release);
    _ = job.owner.running.fetchSub(1, .acq_rel);
    job.wake.call(job.wake.ctx);
}

fn runSearch(job: *Job) Result {
    const request = job.lookup.?;
    const result = response_search.build(job.gpa, request.text, request.query, request.options, request.seek, &job.canceled) catch |err| return .{ .failure = if (err == error.Canceled) .canceled else if (err == error.InputLimit or err == error.QueryLimit) .input_limit else .unavailable };
    return .{ .search = result };
}

fn reflow(job: *Job) Result {
    const request = job.reflow.?;
    const ctx = request.factory.open(request.factory.ctx) orelse return .{ .failure = .unavailable };
    defer request.factory.close(ctx);
    const geometry = text_layout.Layout.build(job.gpa, request.text, request.config, .{ .ctx = ctx, .width = request.factory.width }, &job.canceled) catch |err| return .{ .failure = switch (err) {
        error.TooManyRows, error.TooManyCheckpoints => .index_limit,
        error.Canceled => .canceled,
        else => .unavailable,
    } };
    return .{ .layout = geometry };
}

fn prepare(a: Allocator, source: []const u8, kind: Kind, decoder: ?Decoder) Result {
    switch (kind) {
        .tree => return .{ .tree = Tree.build(a, source, max_nodes) catch |err| return .{ .failure = switch (err) {
            error.TooLarge => .node_limit,
            error.NotJson => .invalid,
            else => .unavailable,
        } } },
        .image => {
            const decoded = if (decoder) |d| d.decode(d.ctx, source) else return .{ .failure = .unavailable };
            return switch (decoded) {
                .pixels => |pixels| .{ .pixels = pixels },
                .failure => |failure| .{ .failure = failure },
            };
        },
        .pretty, .minified, .html, .raw => {
            const bytes = if (kind == .raw) @constCast(source) else if (kind == .html) strip(a, source) catch return .{ .failure = .unavailable } else blk: {
                const result = json.formatLimited(a, source, if (kind == .minified) 0 else 2, max_output) catch |err| return .{ .failure = if (err == error.OutputTooLarge) .output_limit else .unavailable };
                break :blk switch (result) {
                    .ok => |text| text,
                    .problem => return .{ .failure = .invalid },
                };
            };
            var result: Text = .{ .bytes = bytes, .owns_bytes = kind != .raw, .json_syntax = kind == .pretty or kind == .minified };
            if (result.owns_bytes) result.owner = Bytes.own(a, bytes) catch {
                a.free(bytes);
                return .{ .failure = .unavailable };
            };
            result.index.buildLimited(a, bytes, max_rows) catch |err| {
                result.deinit(a);
                return .{ .failure = if (err == error.TooManyRows) .index_limit else .unavailable };
            };
            if (result.json_syntax) highlight.jsonContinuations(a, bytes, result.index.starts.items, &result.strings) catch {
                result.deinit(a);
                return .{ .failure = .unavailable };
            };
            // The text is shown for as long as the response is: keep no growth slack.
            result.index.trim(a);
            @import("../utils/fit.zig").list(highlight.CrossRowString, a, &result.strings);
            return .{ .text = result };
        },
    }
}

fn strip(a: Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, source.len);
    var inside = false;
    for (source) |ch| {
        if (ch == '<') {
            inside = true;
            continue;
        }
        if (ch == '>') {
            inside = false;
            try out.append(a, '\n');
            continue;
        }
        if (!inside) try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

test "bounded preparation keeps exact JSON and builds indexes once" {
    const t = std.testing;
    var pretty = prepare(t.allocator, "{\"n\":1.10,\"s\":\"x\\n\"}", .pretty, null);
    defer pretty.deinit(t.allocator);
    try t.expect(pretty == .text);
    try t.expect(std.mem.indexOf(u8, pretty.text.bytes, "1.10") != null);
    try t.expect(pretty.text.index.count() == 4 and pretty.text.json_syntax);
    var mini = prepare(t.allocator, pretty.text.bytes, .minified, null);
    defer mini.deinit(t.allocator);
    try t.expectEqualStrings("{\"n\":1.10,\"s\":\"x\\n\"}", mini.text.bytes);
    var html = prepare(t.allocator, "<p>Original text</p>", .html, null);
    defer html.deinit(t.allocator);
    try t.expectEqualStrings("\nOriginal text\n", html.text.bytes);
    try t.expect(!html.text.json_syntax);
    var invalid = prepare(t.allocator, "[1,]", .tree, null);
    defer invalid.deinit(t.allocator);
    try t.expect(invalid.failure == .invalid);
}

fn allocationExercise(a: Allocator, kind: Kind) !void {
    var result = prepare(a, "{\"a\":[1,2,3],\"s\":\"original\"}", kind, null);
    defer result.deinit(a);
    if (result == .failure) return if (result.failure == .unavailable) error.OutOfMemory else error.UnexpectedFailure;
}

test "all derived text and tree allocation failures release partial results" {
    for ([_]Kind{ .pretty, .minified, .html, .tree, .raw }) |kind|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{kind});
}

test "output expansion and tree node limits preserve the source" {
    const t = std.testing;
    var deep: [7001]u8 = undefined;
    @memset(deep[0..3500], '[');
    deep[3500] = '0';
    @memset(deep[3501..], ']');
    var expanded = prepare(t.allocator, &deep, .pretty, null);
    defer expanded.deinit(t.allocator);
    try t.expect(expanded.failure == .output_limit and deep[3500] == '0');
    const source = try t.allocator.alloc(u8, max_nodes * 2 + 3);
    defer t.allocator.free(source);
    source[0] = '[';
    for (0..max_nodes) |i| @memcpy(source[1 + i * 2 ..][0..2], "0,");
    @memcpy(source[source.len - 2 ..], "0]");
    var tree = prepare(t.allocator, source, .tree, null);
    defer tree.deinit(t.allocator);
    try t.expect(tree.failure == .node_limit and source[0] == '[');
    const newlines = try t.allocator.alloc(u8, max_rows + 1);
    defer t.allocator.free(newlines);
    @memset(newlines, '\n');
    var rows = prepare(t.allocator, newlines, .raw, null);
    defer rows.deinit(t.allocator);
    try t.expect(rows.failure == .index_limit and newlines[0] == '\n');
}

fn noDone(_: ?*anyopaque, _: *http.Job) void {}
fn testSource(a: Allocator) !*http.Job {
    const job = try a.create(http.Job);
    job.* = .{ .gpa = a, .io = std.testing.io, .client = undefined, .arena = .init(a), .out = .{ .method = "GET", .url = "https://response.invalid/fixture" }, .unresolved = &.{}, .resp = .init(a, std.testing.io, "."), .callbacks = .{ .on_done = noDone }, .timeout_ms = 0 };
    errdefer job.destroy();
    try job.resp.onData("{}");
    return job;
}

const Gate = struct {
    entered: Io.Event = .unset,
    proceed: Io.Event = .unset,
    wakes: std.atomic.Value(u32) = .init(0),

    fn decode(ctx: ?*anyopaque, _: []const u8) Decoded {
        const gate: *Gate = @ptrCast(@alignCast(ctx.?));
        gate.entered.set(std.testing.io);
        gate.proceed.wait(std.testing.io) catch return .{ .failure = .canceled };
        const rgba = std.testing.allocator.dupe(u8, &.{ 255, 0, 0, 255 }) catch return .{ .failure = .unavailable };
        return .{ .pixels = .{ .rgba = rgba.ptr, .width = 1, .height = 1, .source_width = 1, .source_height = 1, .free = free } };
    }
    fn free(rgba: [*]u8) void {
        std.testing.allocator.free(rgba[0..4]);
    }
    fn wake(ctx: *anyopaque) void {
        const gate: *Gate = @ptrCast(@alignCast(ctx));
        _ = gate.wakes.fetchAdd(1, .monotonic);
    }
};

test "worker slots, abandoned interest, retained sources and result transfer" {
    const t = std.testing;
    var service = Service.init(t.allocator, t.io);
    defer service.deinit();
    const source = try testSource(t.allocator);
    defer source.destroy();
    var gate: Gate = .{};
    defer gate.proceed.set(t.io);
    const decoder: Decoder = .{ .ctx = &gate, .decode = Gate.decode };
    const wake: Wake = .{ .ctx = &gate, .call = Gate.wake };
    const one = try service.start(source, .image, decoder, wake);
    const two = try service.start(source, .image, decoder, wake);
    try gate.entered.wait(t.io);
    try t.expectEqual(@as(u32, 2), service.running.load(.acquire));
    try t.expectEqual(@as(u32, 3), source.refs.load(.acquire));
    try t.expectError(error.Busy, service.start(source, .pretty, null, wake));
    try t.expect(one.take() == null);
    one.abandon();
    gate.proceed.set(t.io);
    try service.group.await(t.io);
    try t.expectEqual(@as(u32, 2), source.refs.load(.acquire));
    try t.expectEqual(@as(u32, 2), gate.wakes.load(.acquire));
    var result = two.take().?;
    two.release();
    defer result.deinit(t.allocator);
    try t.expect(result == .pixels and result.pixels.rgba[0] == 255);
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
    try t.expectEqual(@as(u32, 0), service.running.load(.acquire));
}

test "shutdown joins workers after a source and view owner are gone" {
    const t = std.testing;
    var service = Service.init(t.allocator, t.io);
    const source = try testSource(t.allocator);
    var gate: Gate = .{};
    const job = try service.start(source, .image, .{ .ctx = &gate, .decode = Gate.decode }, .{ .ctx = &gate, .call = Gate.wake });
    try gate.entered.wait(t.io);
    source.destroy();
    job.abandon();
    service.deinit();
    try t.expectEqual(@as(u32, 0), service.running.load(.acquire));
    try t.expectEqual(@as(u32, 1), gate.wakes.load(.acquire));
}

test "preparation start failures do not retain or copy the response" {
    const t = std.testing;
    const source = try testSource(t.allocator);
    defer source.destroy();
    var fault = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var service = Service.init(fault.allocator(), t.io);
    defer service.deinit();
    var gate: Gate = .{};
    const wake: Wake = .{ .ctx = &gate, .call = Gate.wake };
    try t.expectError(error.OutOfMemory, service.start(source, .pretty, null, wake));
    source.resp.stop = .canceled;
    try t.expectError(error.Incomplete, service.start(source, .image, null, wake));
    try source.resp.preview.resize(t.allocator, max_input + 1);
    try t.expectError(error.InputLimit, service.start(source, .pretty, null, wake));
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
    try t.expectEqual(@as(u64, 0), service.started);
}

const LayoutGate = struct {
    entered: Io.Event = .unset,
    proceed: Io.Event = .unset,
    closed: std.atomic.Value(u32) = .init(0),
    fn open(raw: ?*anyopaque) ?*anyopaque {
        const gate: *LayoutGate = @ptrCast(@alignCast(raw.?));
        gate.entered.set(std.testing.io);
        gate.proceed.wait(std.testing.io) catch return null;
        return raw;
    }
    fn width(_: ?*anyopaque, text: []const u8) f64 {
        return @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len);
    }
    fn close(raw: *anyopaque) void {
        const gate: *LayoutGate = @ptrCast(@alignCast(raw));
        _ = gate.closed.fetchAdd(1, .monotonic);
    }
    fn factory(gate: *LayoutGate) text_layout.Factory {
        return .{ .ctx = gate, .open = open, .width = width, .close = close };
    }
};

test "reflow retains derived bytes across UI replacement and releases canceled work" {
    const t = std.testing;
    var service = Service.init(t.allocator, t.io);
    defer service.deinit();
    const source = try testSource(t.allocator);
    defer source.destroy();
    const owner = try Bytes.own(t.allocator, try t.allocator.dupe(u8, "derived \xc3\xa9 text"));
    var gate: LayoutGate = .{};
    defer gate.proceed.set(t.io);
    var wakes: Gate = .{};
    const job = try service.layout(source, owner.bytes, owner, .{ .char_width = 1, .wrap_width = 5 }, gate.factory(), .{ .ctx = &wakes, .call = Gate.wake });
    try gate.entered.wait(t.io);
    try t.expectEqual(@as(u32, 2), owner.refs.load(.acquire));
    owner.release(); // UI replaces its formatted result while worker is live.
    job.abandon();
    try t.expectEqual(@as(u32, 1), owner.refs.load(.acquire));
    try t.expectEqualStrings("derived \xc3\xa9 text", owner.bytes);
    gate.proceed.set(t.io);
    try service.group.await(t.io);
    try t.expectEqual(@as(u32, 1), gate.closed.load(.acquire));
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
    try t.expectEqual(@as(u32, 1), wakes.wakes.load(.acquire));
    // A second completed result borrows original HTTP bytes with no copy.
    var second_gate: LayoutGate = .{};
    second_gate.proceed.set(t.io);
    const second = try service.layout(source, source.resp.preview.items, null, .{ .char_width = 1 }, second_gate.factory(), .{ .ctx = &wakes, .call = Gate.wake });
    try service.group.await(t.io);
    var result = second.take().?;
    second.release();
    defer result.deinit(t.allocator);
    try t.expect(result == .layout and result.layout.index.count() == 1 and result.layout.widest == 2);
    var fault = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var failed_service = Service.init(fault.allocator(), t.io);
    defer failed_service.deinit();
    try t.expectError(error.OutOfMemory, failed_service.layout(source, source.resp.preview.items, null, .{}, second_gate.factory(), .{ .ctx = &wakes, .call = Gate.wake }));
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
}

test "search freezes the query and retains derived bytes until result transfer or abandon" {
    const t = std.testing;
    var service = Service.init(t.allocator, t.io);
    defer service.deinit();
    const source = try testSource(t.allocator);
    defer source.destroy();
    const bytes = try Bytes.own(t.allocator, try t.allocator.dupe(u8, "Needle original needle"));
    var query: [6]u8 = "needle".*;
    var wakes: Gate = .{};
    const wake: Wake = .{ .ctx = &wakes, .call = Gate.wake };
    const job = try service.find(source, bytes.bytes, bytes, &query, .{}, .{ .near = 0 }, wake);
    @memset(&query, 'x');
    bytes.release();
    try service.group.await(t.io);
    var result = job.take().?;
    job.release();
    defer result.deinit(t.allocator);
    try t.expect(result == .search and result.search.index.total == 2);
    try t.expectEqualStrings("needle", result.search.index.query);
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
    const abandoned = try service.find(source, source.resp.preview.items, null, "{", .{}, .{ .near = 0 }, wake);
    abandoned.abandon();
    try service.group.await(t.io);
    try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
    for (0..2) |failure| {
        var fault = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var failing = Service.init(fault.allocator(), t.io);
        defer failing.deinit();
        try t.expectError(error.OutOfMemory, failing.find(source, source.resp.preview.items, null, "{", .{}, .{ .near = 0 }, wake));
        try t.expectEqual(@as(u32, 1), source.refs.load(.acquire));
        try t.expectEqual(fault.allocated_bytes, fault.freed_bytes);
    }
}
