//! True logical lines or viewport-width visual rows, with bounded byte/x
//! checkpoints. No text is copied. A native metrics adapter can be private to
//! the worker; all output is immutable geometry with no UI/context pointers.
const std = @import("std");
const lines = @import("../utils/lines.zig");
const hl = @import("../utils/highlight.zig");
const Allocator = std.mem.Allocator;
pub const checkpoint_bytes = 256;
pub const max_rows = 1_000_000;
pub const max_checkpoints = 1_000_000;
pub const Config = struct {
    wrap_width: f64 = 0,
    char_width: f64 = 8,
    /// The font size widths were measured at.
    font_size: f32 = 13,
    lang: hl.Lang = .plain,

    pub fn eql(a: Config, b: Config) bool {
        return a.wrap_width == b.wrap_width and a.char_width == b.char_width and a.font_size == b.font_size and a.lang == b.lang;
    }
};
pub const Metrics = struct {
    ctx: ?*anyopaque = null,
    width: *const fn (?*anyopaque, []const u8) f64,
};
pub const Factory = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (?*anyopaque) ?*anyopaque,
    width: *const fn (?*anyopaque, []const u8) f64,
    close: *const fn (*anyopaque) void,
};
pub const Error = error{ OutOfMemory, TooManyRows, TooManyCheckpoints, InvalidMetrics, Canceled };

pub const Layout = struct {
    config: Config,
    index: lines.Index = .{},
    widths: std.ArrayList(f64) = .empty,
    row_checkpoints: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    xs: std.ArrayList(f64) = .empty,
    strings: std.ArrayList(hl.CrossRowString) = .empty,
    widest: f64 = 0,

    pub fn deinit(layout: *Layout, a: Allocator) void {
        layout.index.deinit(a);
        layout.widths.deinit(a);
        layout.row_checkpoints.deinit(a);
        layout.starts.deinit(a);
        layout.xs.deinit(a);
        layout.strings.deinit(a);
    }

    pub fn build(a: Allocator, source: []const u8, config: Config, metrics: Metrics, cancel: ?*const std.atomic.Value(bool)) Error!Layout {
        if (!std.math.isFinite(config.char_width) or config.char_width <= 0 or !std.math.isFinite(config.wrap_width) or config.wrap_width < 0) return error.InvalidMetrics;
        var out: Layout = .{ .config = config };
        errdefer out.deinit(a);
        out.index.wrap_at = if (config.wrap_width > 0) @intFromFloat(config.wrap_width) else std.math.maxInt(u32);
        out.index.prefer_words = config.wrap_width > 0;
        var line_start: usize = 0;
        var line: u32 = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
            const line_end = if (nl < source.len and nl > line_start and source[nl - 1] == '\r') nl - 1 else nl;
            var start = line_start;
            var first = true;
            while (true) {
                try canceled(cancel);
                if (out.index.starts.items.len >= max_rows) return error.TooManyRows;
                var end = line_end;
                if (config.wrap_width > 0 and start < line_end) {
                    end = try fit(source, start, line_end, config, metrics, cancel);
                    if (end < line_end) if (std.mem.lastIndexOfAny(u8, source[start..end], " \t")) |space| {
                        end = start + space + 1;
                    };
                }
                try out.index.starts.append(a, @intCast(start));
                try out.index.lines.append(a, if (first) line else line | (@as(u32, 1) << 31));
                try out.row_checkpoints.append(a, @intCast(out.starts.items.len));
                var x: f64 = 0;
                var at = start;
                while (true) {
                    try canceled(cancel);
                    if (out.starts.items.len >= max_checkpoints) return error.TooManyCheckpoints;
                    try out.starts.append(a, @intCast(at));
                    try out.xs.append(a, x);
                    const next = chunkEnd(source, at, end);
                    x += try advance(source, start, at, next, x, config.char_width, metrics);
                    if (next >= end) break;
                    at = next;
                }
                try out.widths.append(a, x);
                out.widest = @max(out.widest, x);
                out.index.longest = @max(out.index.longest, end - start);
                if (end >= line_end) break;
                start = end;
                first = false;
            }
            if (nl == source.len) break;
            line_start = nl + 1;
            line += 1;
        }
        if (config.lang == .json) try hl.jsonContinuations(a, source, out.starts.items, &out.strings);
        return out;
    }

    pub fn checkpoints(layout: *const Layout, row: usize) [2]usize {
        return .{ layout.row_checkpoints.items[row], if (row + 1 < layout.row_checkpoints.items.len) layout.row_checkpoints.items[row + 1] else layout.starts.items.len };
    }

    pub fn atX(layout: *const Layout, row: usize, x: f64) usize {
        const bounds = layout.checkpoints(row);
        var lo = bounds[0];
        var hi = bounds[1];
        while (hi > lo) {
            const mid = lo + (hi - lo) / 2;
            if (layout.xs.items[mid] < x) lo = mid + 1 else hi = mid;
        }
        if (lo < bounds[1] and layout.xs.items[lo] == x) return lo;
        return @max(bounds[0], lo -| 1);
    }

    pub fn atByte(layout: *const Layout, row: usize, pos: usize) usize {
        const bounds = layout.checkpoints(row);
        var lo = bounds[0];
        var hi = bounds[1];
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (layout.starts.items[mid] <= pos) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn chunkBounds(layout: *const Layout, index: *const lines.Index, source: []const u8, row: usize, checkpoint: usize) [2]usize {
        const bounds = layout.checkpoints(row);
        return .{ layout.starts.items[checkpoint], if (checkpoint + 1 < bounds[1]) layout.starts.items[checkpoint + 1] else index.bounds(source, row)[1] };
    }

    pub fn position(layout: *const Layout, index: *const lines.Index, source: []const u8, row: usize, pos: usize, metrics: Metrics) f64 {
        const bounds = index.bounds(source, row);
        const byte = std.math.clamp(pos, bounds[0], bounds[1]);
        const cp = layout.atByte(row, byte);
        const base = layout.xs.items[cp];
        return base + (advance(source, bounds[0], layout.starts.items[cp], byte, base, layout.config.char_width, metrics) catch 0);
    }

    pub fn byteAt(layout: *const Layout, index: *const lines.Index, source: []const u8, row: usize, x: f64, metrics: Metrics) usize {
        const cp = layout.atX(row, @max(0, x));
        const bounds = layout.chunkBounds(index, source, row, cp);
        var lo = bounds[0];
        var hi = bounds[1];
        while (hi > lo) {
            var mid = lo + (hi - lo) / 2;
            while (mid > lo and mid < source.len and source[mid] & 0xc0 == 0x80) mid -= 1;
            const next = nextChar(source, mid, bounds[1]);
            const left = layout.position(index, source, row, mid, metrics);
            const right = layout.position(index, source, row, next, metrics);
            if (x < (left + right) / 2) hi = mid else lo = next;
        }
        return lo;
    }
};

fn canceled(cancel: ?*const std.atomic.Value(bool)) Error!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}
fn nextChar(source: []const u8, at: usize, end: usize) usize {
    if (at >= end) return end;
    const count = std.unicode.utf8ByteSequenceLength(source[at]) catch 1;
    return @min(end, at + count);
}
fn chunkEnd(source: []const u8, at: usize, end: usize) usize {
    var cut = @min(end, at + checkpoint_bytes);
    while (cut > at and cut < end and source[cut] & 0xc0 == 0x80) cut -= 1;
    return if (cut > at) cut else nextChar(source, at, end);
}

fn fit(source: []const u8, start: usize, end: usize, config: Config, metrics: Metrics, cancel: ?*const std.atomic.Value(bool)) Error!usize {
    var at = start;
    var x: f64 = 0;
    while (at < end) {
        try canceled(cancel);
        const next = chunkEnd(source, at, end);
        const width = try advance(source, start, at, next, x, config.char_width, metrics);
        if (x + width > config.wrap_width) {
            var lo = at;
            var hi = next;
            while (hi > lo) {
                var mid = lo + (hi - lo) / 2;
                while (mid > lo and source[mid] & 0xc0 == 0x80) mid -= 1;
                const after = nextChar(source, mid, next);
                const used = try advance(source, start, at, after, x, config.char_width, metrics);
                if (x + used <= config.wrap_width) lo = after else hi = mid;
            }
            return if (lo > start) lo else nextChar(source, start, end);
        }
        x += width;
        at = next;
    }
    return end;
}

/// Metrics match the editor: two-space tab stops and invisible CR. Prefix
/// context retains native kerning at checkpoint boundaries. Each call visits
/// at most one checkpoint, including in paint/hit testing of enormous lines.
pub fn advance(source: []const u8, row_start: usize, start: usize, end: usize, initial_x: f64, char_width: f64, metrics: Metrics) Error!f64 {
    var at = start;
    var x = initial_x;
    while (at < end) {
        if (source[at] == '\t') {
            x = (@floor(x / (char_width * 2)) + 1) * char_width * 2;
            at += 1;
            continue;
        }
        if (source[at] == '\r') {
            at += 1;
            continue;
        }
        const stop = at + (std.mem.indexOfAny(u8, source[at..end], "\t\r") orelse (end - at));
        var ascii = true;
        for (source[at..stop]) |byte| if (byte >= 0x80) {
            ascii = false;
            break;
        };
        if (ascii) {
            x += @as(f64, @floatFromInt(stop - at)) * char_width;
        } else {
            var context = at;
            if (at > row_start and source[at - 1] != '\t' and source[at - 1] != '\r') {
                context -= 1;
                while (context > row_start and source[context] & 0xc0 == 0x80) context -= 1;
            }
            const prefix = if (context < at) metrics.width(metrics.ctx, source[context..at]) else 0;
            const measured = metrics.width(metrics.ctx, source[context..stop]) - prefix;
            if (!std.math.isFinite(measured)) return error.InvalidMetrics;
            x += @max(0, measured);
        }
        at = stop;
    }
    return x - initial_x;
}

fn mono(_: ?*anyopaque, source: []const u8) f64 {
    return @floatFromInt(std.unicode.utf8CountCodepoints(source) catch source.len);
}

test "unwrapped long lines retain logical rows and bounded checkpoints" {
    const t = std.testing;
    const source = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    defer t.allocator.free(source);
    @memset(source, 'x');
    var layout = try Layout.build(t.allocator, source, .{ .char_width = 1 }, .{ .width = mono }, null);
    defer layout.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), layout.index.count());
    try t.expectEqual(@as(f64, @floatFromInt(source.len)), layout.widest);
    try t.expectEqual(source.len, layout.byteAt(&layout.index, source, 0, @floatFromInt(source.len), .{ .width = mono }));
    try t.expectEqual(@as(usize, 1_234_567), layout.byteAt(&layout.index, source, 0, 1_234_567, .{ .width = mono }));
    try t.expectEqual(@as(usize, source.len / checkpoint_bytes), layout.starts.items.len);
}

test "wrap preserves bytes, CRLF, UTF-8 boundaries and logical line numbers" {
    const t = std.testing;
    const source = "word word\r\na\xc3\xa9\xc3\xa9\xc3\xa9z\n";
    var layout = try Layout.build(t.allocator, source, .{ .char_width = 1, .wrap_width = 5 }, .{ .width = mono }, null);
    defer layout.deinit(t.allocator);
    try t.expectEqual(@as(usize, 4), layout.index.count());
    try t.expectEqualStrings("word ", layout.index.row(source, 0));
    try t.expectEqualStrings("word", layout.index.row(source, 1));
    try t.expect(layout.index.isContinued(1) and layout.index.lineNumber(2) == 2 and layout.index.lineNumber(3) == 3);
    for (layout.widths.items) |width| try t.expect(width <= 5);
    for (layout.starts.items) |at| if (at < source.len) try t.expect(source[at] & 0xc0 != 0x80);
}

fn allocationExercise(a: Allocator) !void {
    var layout = try Layout.build(a, "{\"s\":\"abcdef abcdef abcdef\",\"n\":1}\r\n", .{ .char_width = 1, .wrap_width = 8, .lang = .json }, .{ .width = mono }, null);
    defer layout.deinit(a);
}
test "layout releases every partial allocation and rejects invalid metrics or cancellation" {
    const t = std.testing;
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
    var cancel: std.atomic.Value(bool) = .init(true);
    try t.expectError(error.Canceled, Layout.build(t.allocator, "abc", .{}, .{ .width = mono }, &cancel));
    try t.expectError(error.InvalidMetrics, Layout.build(t.allocator, "abc", .{ .char_width = 0 }, .{ .width = mono }, null));
    try t.expectError(error.InvalidMetrics, Layout.build(t.allocator, "abc", .{ .wrap_width = std.math.nan(f64) }, .{ .width = mono }, null));
}

const Counter = struct {
    bytes: usize = 0,
    largest: usize = 0,
    fn width(raw: ?*anyopaque, source: []const u8) f64 {
        const value: *Counter = @ptrCast(@alignCast(raw.?));
        value.bytes += source.len;
        value.largest = @max(value.largest, source.len);
        return mono(null, source);
    }
};
fn zeroWidth(_: ?*anyopaque, _: []const u8) f64 {
    return 0;
}
fn cancelWidth(raw: ?*anyopaque, source: []const u8) f64 {
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw.?));
    flag.store(true, .release);
    return mono(null, source);
}
test "far Unicode hit testing only measures a checkpoint and dense text preserves access" {
    const t = std.testing;
    const source = try t.allocator.alloc(u8, 1024 * 1024);
    defer t.allocator.free(source);
    for (0..source.len / 2) |i| @memcpy(source[i * 2 ..][0..2], "\xc3\xa9");
    var layout = try Layout.build(t.allocator, source, .{ .char_width = 1 }, .{ .width = mono }, null);
    defer layout.deinit(t.allocator);
    var counter: Counter = .{};
    const measured: Metrics = .{ .ctx = &counter, .width = Counter.width };
    try t.expectEqual(@as(f64, 450001), layout.position(&layout.index, source, 0, 900002, measured));
    try t.expectEqual(@as(usize, 900002), layout.byteAt(&layout.index, source, 0, 450001, measured));
    try t.expect(counter.largest <= checkpoint_bytes + 4 and counter.bytes < 8192);
    var dense = try Layout.build(t.allocator, source, .{ .char_width = 1 }, .{ .width = zeroWidth }, null);
    defer dense.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), dense.atX(0, 0));
    try t.expectEqual(@as(usize, 1), dense.index.count());
    try t.expectEqual(source.len, dense.index.bounds(source, 0)[1]);
    var cancel: std.atomic.Value(bool) = .init(false);
    try t.expectError(error.Canceled, Layout.build(t.allocator, source, .{ .char_width = 1 }, .{ .ctx = &cancel, .width = cancelWidth }, &cancel));
}
