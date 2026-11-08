//! Regular expressions for Find and Replace. A pattern compiles to a small
//! program that a Pike VM runs: every possible match advances together, one
//! character at a time, so time stays linear in the text however the
//! pattern is written. Matching is leftmost-first, as in most editors.
//!
//! Supported: literals, `.` (not a newline), classes `[a-z]` `[^...]`,
//! `\d \w \s` and their negations, `\b \B`, `^ $` at line starts and ends,
//! groups `( )` and `(?: )`, `|`, and `* + ? {m} {m,} {m,n}`, each lazy with
//! a trailing `?`. Escapes `\n \r \t \f \v \xHH \u{...}` and `\` before
//! punctuation. Text is UTF-8: `.` and classes take whole characters.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct { case_sensitive: bool = false };
pub const Error = error{ OutOfMemory, Syntax, Canceled };
/// Where a pattern went wrong, and what.
pub const Problem = struct { at: usize = 0, message: []const u8 = "" };

/// Programs past this many steps are refused: `(a{1000}){1000}` and kin.
const max_ops = 20_000;
const max_repeat = 1000;
const none = std.math.maxInt(u32);

const Range = struct { lo: u21, hi: u21 };
const Assert = enum { line_start, line_end, word, not_word };
const Op = union(enum) {
    char: u21,
    any,
    class: struct { start: u32, len: u32, negated: bool },
    split: struct { x: u32, y: u32 },
    jmp: u32,
    save: u32,
    assert: Assert,
    match,
};

pub const Regex = struct {
    ops: []Op,
    ranges: []Range,
    /// Capture slots: two per group, group 0 being the whole match.
    slots: u32,
    case_sensitive: bool,

    pub fn compile(a: Allocator, pattern: []const u8, options: Options, problem: *Problem) Error!Regex {
        var p: Parser = .{ .a = a, .src = pattern, .problem = problem, .fold = !options.case_sensitive };
        defer p.nodes.deinit(a);
        defer p.kids.deinit(a);
        errdefer p.ranges.deinit(a);
        const root = try p.alternation();
        if (p.at < pattern.len) return p.fail(p.at, "Unmatched )");
        var e: Emitter = .{ .a = a, .p = &p, .problem = problem };
        errdefer e.ops.deinit(a);
        try e.emit(.{ .save = 0 });
        try e.node(root);
        try e.emit(.{ .save = 1 });
        try e.emit(.match);
        return .{
            .ops = try e.ops.toOwnedSlice(a),
            .ranges = try p.ranges.toOwnedSlice(a),
            .slots = 2 * (p.groups + 1),
            .case_sensitive = options.case_sensitive,
        };
    }

    pub fn deinit(re: *Regex, a: Allocator) void {
        a.free(re.ops);
        a.free(re.ranges);
    }

    pub fn groups(re: *const Regex) u32 {
        return re.slots / 2 - 1;
    }

    /// The first match starting at or after `from`, its groups in `caps`
    /// (start and end per group; `none` for a group that didn't take part).
    /// `anchored` only tries `from` itself.
    pub fn find(re: *const Regex, vm: *Vm, text: []const u8, from: usize, anchored: bool, caps: []u32) Error!bool {
        return vm.run(re, text, from, anchored, caps);
    }
};

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: struct { start: u32, len: u32, negated: bool },
    assert: Assert,
    group: struct { inner: u32, index: ?u32 },
    concat: struct { start: u32, len: u32 },
    alt: struct { start: u32, len: u32 },
    repeat: struct { inner: u32, min: u32, max: ?u32, greedy: bool },
};

const Parser = struct {
    a: Allocator,
    src: []const u8,
    at: usize = 0,
    problem: *Problem,
    fold: bool,
    nodes: std.ArrayList(Node) = .empty,
    kids: std.ArrayList(u32) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    groups: u32 = 0,

    fn fail(p: *Parser, at: usize, message: []const u8) Error {
        p.problem.* = .{ .at = at, .message = message };
        return error.Syntax;
    }
    fn add(p: *Parser, n: Node) Error!u32 {
        try p.nodes.append(p.a, n);
        return @intCast(p.nodes.items.len - 1);
    }
    fn list(p: *Parser, items: []const u32) Error![2]u32 {
        const start: u32 = @intCast(p.kids.items.len);
        try p.kids.appendSlice(p.a, items);
        return .{ start, @intCast(items.len) };
    }
    fn peek(p: *Parser) ?u8 {
        return if (p.at < p.src.len) p.src[p.at] else null;
    }

    fn alternation(p: *Parser) Error!u32 {
        var branches: std.ArrayList(u32) = .empty;
        defer branches.deinit(p.a);
        try branches.append(p.a, try p.sequence());
        while (p.peek() == '|') {
            p.at += 1;
            try branches.append(p.a, try p.sequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        const l = try p.list(branches.items);
        return p.add(.{ .alt = .{ .start = l[0], .len = l[1] } });
    }

    fn sequence(p: *Parser) Error!u32 {
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(p.a);
        while (p.peek()) |byte| {
            if (byte == '|' or byte == ')') break;
            try items.append(p.a, try p.repeated());
        }
        if (items.items.len == 0) return p.add(.empty);
        if (items.items.len == 1) return items.items[0];
        const l = try p.list(items.items);
        return p.add(.{ .concat = .{ .start = l[0], .len = l[1] } });
    }

    fn repeated(p: *Parser) Error!u32 {
        var inner = try p.atom();
        var quantified = false;
        while (p.peek()) |byte| {
            var min: u32 = 0;
            var max: ?u32 = null;
            const quantifier_at = p.at;
            switch (byte) {
                '*' => p.at += 1,
                '+' => {
                    p.at += 1;
                    min = 1;
                },
                '?' => {
                    p.at += 1;
                    max = 1;
                },
                '{' => {
                    const bounds = p.braces() orelse break;
                    min = bounds[0];
                    max = bounds[1];
                },
                else => break,
            }
            if (quantified) return p.fail(quantifier_at, "Nothing to repeat");
            quantified = true;
            switch (p.nodes.items[inner]) {
                .empty, .assert => return p.fail(quantifier_at, "Nothing to repeat"),
                else => {},
            }
            var greedy = true;
            if (p.peek() == '?') {
                p.at += 1;
                greedy = false;
            }
            inner = try p.add(.{ .repeat = .{ .inner = inner, .min = min, .max = max, .greedy = greedy } });
        }
        return inner;
    }

    /// `{m}`, `{m,}` or `{m,n}`; anything else leaves `{` a literal.
    fn braces(p: *Parser) ?struct { u32, ?u32 } {
        var at = p.at + 1;
        const lo = number(p.src, &at) orelse return null;
        var hi: ?u32 = lo;
        if (at < p.src.len and p.src[at] == ',') {
            at += 1;
            hi = number(p.src, &at);
        }
        if (at >= p.src.len or p.src[at] != '}') return null;
        if (lo > max_repeat or (hi != null and (hi.? > max_repeat or hi.? < lo))) return null;
        p.at = at + 1;
        return .{ lo, hi };
    }

    fn atom(p: *Parser) Error!u32 {
        const byte = p.peek() orelse return p.add(.empty);
        const start = p.at;
        switch (byte) {
            '(' => {
                p.at += 1;
                var index: ?u32 = null;
                if (std.mem.startsWith(u8, p.src[p.at..], "?:")) {
                    p.at += 2;
                } else if (p.peek() == '?') {
                    return p.fail(p.at, "Only (?: ) groups are supported");
                } else {
                    p.groups += 1;
                    index = p.groups;
                }
                const inner = try p.alternation();
                if (p.peek() != ')') return p.fail(start, "Unclosed group");
                p.at += 1;
                return p.add(.{ .group = .{ .inner = inner, .index = index } });
            },
            '[' => return p.class(),
            '.' => {
                p.at += 1;
                return p.add(.any);
            },
            '^' => {
                p.at += 1;
                return p.add(.{ .assert = .line_start });
            },
            '$' => {
                p.at += 1;
                return p.add(.{ .assert = .line_end });
            },
            '*', '+', '?' => return p.fail(start, "Nothing to repeat"),
            '\\' => {
                p.at += 1;
                const e = p.peek() orelse return p.fail(start, "Pattern ends with \\");
                switch (e) {
                    'b' => {
                        p.at += 1;
                        return p.add(.{ .assert = .word });
                    },
                    'B' => {
                        p.at += 1;
                        return p.add(.{ .assert = .not_word });
                    },
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        p.at += 1;
                        const r0: u32 = @intCast(p.ranges.items.len);
                        try p.shorthand(std.ascii.toLower(e));
                        return p.add(.{ .class = .{ .start = r0, .len = @as(u32, @intCast(p.ranges.items.len)) - r0, .negated = std.ascii.isUpper(e) } });
                    },
                    else => return p.add(.{ .char = p.fold1(try p.escape(start)) }),
                }
            },
            else => return p.add(.{ .char = p.fold1(p.literal()) }),
        }
    }

    fn fold1(p: *Parser, cp: u21) u21 {
        return if (p.fold) lower(cp) else cp;
    }

    /// One UTF-8 character of the pattern.
    fn literal(p: *Parser) u21 {
        const d = decode(p.src, p.at);
        p.at += d.len;
        return d.cp;
    }

    /// After a backslash: the character it stands for.
    fn escape(p: *Parser, start: usize) Error!u21 {
        const e = p.src[p.at];
        p.at += 1;
        switch (e) {
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'f' => return 0x0c,
            'v' => return 0x0b,
            '0' => return 0,
            'x' => {
                if (p.at + 2 > p.src.len) return p.fail(start, "\\x needs two hex digits");
                const v = std.fmt.parseInt(u8, p.src[p.at .. p.at + 2], 16) catch return p.fail(start, "\\x needs two hex digits");
                p.at += 2;
                return v;
            },
            'u' => {
                if (p.peek() != '{') return p.fail(start, "Write \\u{hex}");
                const close = std.mem.indexOfScalarPos(u8, p.src, p.at, '}') orelse return p.fail(start, "Write \\u{hex}");
                const v = std.fmt.parseInt(u21, p.src[p.at + 1 .. close], 16) catch return p.fail(start, "Write \\u{hex}");
                p.at = close + 1;
                return v;
            },
            else => {
                if (std.ascii.isAlphanumeric(e)) return p.fail(start, "Unknown escape");
                p.at -= 1;
                return p.literal();
            },
        }
    }

    fn shorthand(p: *Parser, kind: u8) Error!void {
        const set: []const Range = switch (kind) {
            'd' => &.{.{ .lo = '0', .hi = '9' }},
            'w' => &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0x80, .hi = 0x10ffff } },
            else => &.{ .{ .lo = '\t', .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } },
        };
        try p.ranges.appendSlice(p.a, set);
    }

    fn class(p: *Parser) Error!u32 {
        const start = p.at;
        p.at += 1;
        var negated = false;
        if (p.peek() == '^') {
            p.at += 1;
            negated = true;
        }
        const r0 = p.ranges.items.len;
        var first = true;
        while (true) {
            const byte = p.peek() orelse return p.fail(start, "Unclosed [");
            if (byte == ']' and !first) break;
            first = false;
            var lo: u21 = undefined;
            if (byte == '\\') {
                const escape_at = p.at;
                p.at += 1;
                const e = p.peek() orelse return p.fail(start, "Unclosed [");
                switch (e) {
                    'd', 'w', 's' => {
                        p.at += 1;
                        try p.shorthand(e);
                        continue;
                    },
                    'D', 'W', 'S' => {
                        p.at += 1;
                        var tmp: Parser = .{ .a = p.a, .src = "", .problem = p.problem, .fold = false };
                        defer tmp.ranges.deinit(p.a);
                        try tmp.shorthand(std.ascii.toLower(e));
                        try complement(p.a, tmp.ranges.items, &p.ranges);
                        continue;
                    },
                    'b' => {
                        p.at += 1;
                        lo = 0x08;
                    },
                    else => lo = try p.escape(escape_at),
                }
            } else lo = p.literal();
            var hi = lo;
            if (p.peek() == '-' and p.at + 1 < p.src.len and p.src[p.at + 1] != ']') {
                const dash = p.at;
                p.at += 1;
                if (p.peek() == '\\') {
                    const escape_at = p.at;
                    p.at += 1;
                    if (p.peek() == null) return p.fail(start, "Unclosed [");
                    hi = try p.escape(escape_at);
                } else hi = p.literal();
                if (hi < lo) return p.fail(dash, "Range out of order");
            }
            try p.ranges.append(p.a, .{ .lo = lo, .hi = hi });
        }
        p.at += 1;
        // Case-insensitive classes also hold the other case of each letter.
        if (p.fold) {
            const end = p.ranges.items.len;
            for (r0..end) |i| {
                const r = p.ranges.items[i];
                const lo = @max(r.lo, 'A');
                const hi = @min(r.hi, 'Z');
                if (lo <= hi) try p.ranges.append(p.a, .{ .lo = lo + 32, .hi = hi + 32 });
                const lo2 = @max(r.lo, 'a');
                const hi2 = @min(r.hi, 'z');
                if (lo2 <= hi2) try p.ranges.append(p.a, .{ .lo = lo2 - 32, .hi = hi2 - 32 });
            }
        }
        return p.add(.{ .class = .{ .start = @intCast(r0), .len = @intCast(p.ranges.items.len - r0), .negated = negated } });
    }
};

/// Every character not in `set` (sorted, not overlapping).
fn complement(a: Allocator, set: []const Range, out: *std.ArrayList(Range)) Error!void {
    var next: u21 = 0;
    for (set) |r| {
        if (r.lo > next) try out.append(a, .{ .lo = next, .hi = r.lo - 1 });
        next = if (r.hi == 0x10ffff) 0x10ffff else r.hi + 1;
        if (r.hi == 0x10ffff) return;
    }
    try out.append(a, .{ .lo = next, .hi = 0x10ffff });
}

fn number(src: []const u8, at: *usize) ?u32 {
    const start = at.*;
    while (at.* < src.len and std.ascii.isDigit(src[at.*])) at.* += 1;
    if (at.* == start or at.* - start > 6) return null;
    return std.fmt.parseInt(u32, src[start..at.*], 10) catch null;
}

const Emitter = struct {
    a: Allocator,
    p: *const Parser,
    problem: *Problem,
    ops: std.ArrayList(Op) = .empty,

    fn emit(e: *Emitter, op: Op) Error!void {
        if (e.ops.items.len >= max_ops) {
            e.problem.* = .{ .at = 0, .message = "Pattern is too large" };
            return error.Syntax;
        }
        try e.ops.append(e.a, op);
    }
    fn here(e: *const Emitter) u32 {
        return @intCast(e.ops.items.len);
    }

    fn node(e: *Emitter, index: u32) Error!void {
        switch (e.p.nodes.items[index]) {
            .empty => {},
            .char => |cp| try e.emit(.{ .char = cp }),
            .any => try e.emit(.any),
            .class => |k| try e.emit(.{ .class = .{ .start = k.start, .len = k.len, .negated = k.negated } }),
            .assert => |kind| try e.emit(.{ .assert = kind }),
            .group => |g| {
                if (g.index) |n| try e.emit(.{ .save = 2 * n });
                try e.node(g.inner);
                if (g.index) |n| try e.emit(.{ .save = 2 * n + 1 });
            },
            .concat => |l| for (e.p.kids.items[l.start..][0..l.len]) |kid| try e.node(kid),
            .alt => |l| {
                const kids = e.p.kids.items[l.start..][0..l.len];
                var jumps: std.ArrayList(u32) = .empty;
                defer jumps.deinit(e.a);
                for (kids, 0..) |kid, i| {
                    if (i + 1 < kids.len) {
                        const split = e.here();
                        try e.emit(.{ .split = .{ .x = split + 1, .y = 0 } });
                        try e.node(kid);
                        try jumps.append(e.a, e.here());
                        try e.emit(.{ .jmp = 0 });
                        e.ops.items[split].split.y = e.here();
                    } else try e.node(kid);
                }
                for (jumps.items) |j| e.ops.items[j] = .{ .jmp = e.here() };
            },
            .repeat => |r| {
                for (0..r.min) |_| try e.node(r.inner);
                if (r.max) |max| {
                    // Each optional copy may stop the whole run.
                    var exits: std.ArrayList(u32) = .empty;
                    defer exits.deinit(e.a);
                    for (r.min..max) |_| {
                        try exits.append(e.a, e.here());
                        try e.emit(.{ .split = .{ .x = 0, .y = 0 } });
                        try e.node(r.inner);
                    }
                    const out = e.here();
                    for (exits.items) |s| e.ops.items[s] = .{ .split = if (r.greedy) .{ .x = s + 1, .y = out } else .{ .x = out, .y = s + 1 } };
                } else {
                    const loop = e.here();
                    try e.emit(.{ .split = .{ .x = 0, .y = 0 } });
                    try e.node(r.inner);
                    try e.emit(.{ .jmp = loop });
                    const out = e.here();
                    e.ops.items[loop] = .{ .split = if (r.greedy) .{ .x = loop + 1, .y = out } else .{ .x = out, .y = loop + 1 } };
                }
            },
        }
    }
};

/// The scratch memory of a search, kept across calls: one per searcher.
pub const Vm = struct {
    a: Allocator,
    /// Threads now and next: their program counters and capture slots.
    pcs: [2]std.ArrayList(u32) = .{ .empty, .empty },
    caps: [2]std.ArrayList(u32) = .{ .empty, .empty },
    /// When each op was last added, to add it once per position.
    seen: std.ArrayList(u32) = .empty,
    generation: u32 = 0,
    stack: std.ArrayList(Frame) = .empty,
    work: std.ArrayList(u32) = .empty,
    /// Checked every 64 KiB of text, so a worker can stop a long scan.
    cancel: ?*const std.atomic.Value(bool) = null,

    const Frame = struct { pc: u32, slot: u32 = none, value: u32 = 0 };

    pub fn init(a: Allocator) Vm {
        return .{ .a = a };
    }
    pub fn deinit(vm: *Vm) void {
        for (&vm.pcs) |*l| l.deinit(vm.a);
        for (&vm.caps) |*l| l.deinit(vm.a);
        vm.seen.deinit(vm.a);
        vm.stack.deinit(vm.a);
        vm.work.deinit(vm.a);
    }

    fn run(vm: *Vm, re: *const Regex, text: []const u8, from: usize, anchored: bool, out: []u32) Error!bool {
        const slots = re.slots;
        std.debug.assert(out.len >= slots);
        const known = vm.seen.items.len;
        if (re.ops.len > known) {
            try vm.seen.resize(vm.a, re.ops.len);
            @memset(vm.seen.items[known..], 0);
        }
        if (vm.generation == 0 or vm.generation > std.math.maxInt(u32) - 4) {
            @memset(vm.seen.items, 0);
            vm.generation = 1;
        }
        try vm.work.resize(vm.a, slots);
        var cur: usize = 0;
        vm.pcs[0].clearRetainingCapacity();
        vm.caps[0].clearRetainingCapacity();
        vm.generation += 1;
        var matched = false;
        var pos = from;
        var steps: usize = 0;
        @memset(vm.work.items, none);
        try vm.add(re, text, cur, 0, pos);
        while (true) {
            // With nothing alive, an unanchored search still moves on.
            if (vm.pcs[cur].items.len == 0 and (matched or anchored)) break;
            const d: Decoded = if (pos < text.len) decode(text, pos) else .{ .cp = 0, .len = 0 };
            const next = 1 - cur;
            vm.pcs[next].clearRetainingCapacity();
            vm.caps[next].clearRetainingCapacity();
            vm.generation += 1;
            const threads = vm.pcs[cur].items.len;
            for (0..threads) |i| {
                const pc = vm.pcs[cur].items[i];
                const caps = vm.caps[cur].items[i * slots ..][0..slots];
                const ok = switch (re.ops[pc]) {
                    .match => {
                        @memcpy(out[0..slots], caps);
                        matched = true;
                        break;
                    },
                    .char => |want| d.len > 0 and (if (re.case_sensitive) d.cp == want else lower(d.cp) == want),
                    .any => d.len > 0 and d.cp != '\n',
                    .class => |k| d.len > 0 and (inClass(re, k.start, k.len, d.cp) != k.negated),
                    else => unreachable,
                };
                if (ok) {
                    @memcpy(vm.work.items, caps);
                    try vm.add(re, text, next, pc + 1, pos + d.len);
                }
            }
            if (d.len == 0) break;
            steps +%= 1;
            if (steps & 0xffff == 0) if (vm.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
            pos += d.len;
            if (!matched and !anchored) {
                @memset(vm.work.items, none);
                try vm.add(re, text, next, 0, pos);
            }
            cur = next;
        }
        return matched;
    }

    /// Follows jumps, splits, saves and assertions from `start`, adding the
    /// threads that wait on a character, in priority order.
    fn add(vm: *Vm, re: *const Regex, text: []const u8, list: usize, start: u32, pos: usize) Error!void {
        vm.stack.clearRetainingCapacity();
        try vm.stack.append(vm.a, .{ .pc = start });
        while (vm.stack.pop()) |frame| {
            if (frame.slot != none) {
                vm.work.items[frame.slot] = frame.value;
                continue;
            }
            var pc = frame.pc;
            while (true) {
                if (vm.seen.items[pc] == vm.generation) break;
                vm.seen.items[pc] = vm.generation;
                switch (re.ops[pc]) {
                    .jmp => |to| pc = to,
                    .split => |s| {
                        try vm.stack.append(vm.a, .{ .pc = s.y });
                        pc = s.x;
                    },
                    .save => |slot| {
                        try vm.stack.append(vm.a, .{ .pc = 0, .slot = slot, .value = vm.work.items[slot] });
                        vm.work.items[slot] = @intCast(pos);
                        pc += 1;
                    },
                    .assert => |kind| {
                        if (!holds(text, pos, kind)) break;
                        pc += 1;
                    },
                    else => {
                        try vm.pcs[list].append(vm.a, pc);
                        try vm.caps[list].appendSlice(vm.a, vm.work.items);
                        break;
                    },
                }
            }
        }
    }
};

fn inClass(re: *const Regex, start: u32, len: u32, cp: u21) bool {
    for (re.ranges[start..][0..len]) |r| if (cp >= r.lo and cp <= r.hi) return true;
    return false;
}

fn holds(text: []const u8, pos: usize, kind: Assert) bool {
    return switch (kind) {
        .line_start => pos == 0 or text[pos - 1] == '\n',
        .line_end => pos == text.len or text[pos] == '\n' or (text[pos] == '\r' and (pos + 1 == text.len or text[pos + 1] == '\n')),
        .word, .not_word => blk: {
            const before = pos > 0 and wordByte(text[pos - 1]);
            const after = pos < text.len and wordByte(text[pos]);
            break :blk (before != after) == (kind == .word);
        },
    };
}

/// Word characters: ASCII letters, digits, `_`, and anything not ASCII.
pub fn wordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn lower(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

const Decoded = struct { cp: u21, len: usize };
/// One character at `at`; a malformed byte stands alone.
fn decode(text: []const u8, at: usize) Decoded {
    const n = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .cp = text[at], .len = 1 };
    if (at + n > text.len) return .{ .cp = text[at], .len = 1 };
    const cp = std.unicode.utf8Decode(text[at .. at + n]) catch return .{ .cp = text[at], .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Writes `template` with `$0`/`$&` (the match), `$1`-`$99` (groups) and
/// `$$`; in a regex search `\n`, `\t` and `\\` too.
pub fn expand(a: Allocator, out: *std.ArrayList(u8), template: []const u8, text: []const u8, caps: []const u32) Error!void {
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const byte = template[i];
        if (byte == '\\' and i + 1 < template.len) {
            switch (template[i + 1]) {
                'n' => try out.append(a, '\n'),
                't' => try out.append(a, '\t'),
                'r' => try out.append(a, '\r'),
                '\\' => try out.append(a, '\\'),
                else => {
                    try out.append(a, byte);
                    continue;
                },
            }
            i += 1;
            continue;
        }
        if (byte != '$' or i + 1 >= template.len) {
            try out.append(a, byte);
            continue;
        }
        const next = template[i + 1];
        if (next == '$') {
            try out.append(a, '$');
            i += 1;
            continue;
        }
        var group: ?usize = null;
        if (next == '&') {
            group = 0;
            i += 1;
        } else if (std.ascii.isDigit(next)) {
            var n: usize = next - '0';
            i += 1;
            if (i + 1 < template.len and std.ascii.isDigit(template[i + 1]) and (n * 10 + template[i + 1] - '0') * 2 < caps.len) {
                n = n * 10 + template[i + 1] - '0';
                i += 1;
            }
            group = n;
        }
        if (group) |g| {
            if (2 * g + 1 < caps.len and caps[2 * g] != none and caps[2 * g + 1] != none) try out.appendSlice(a, text[caps[2 * g]..caps[2 * g + 1]]);
        } else try out.append(a, byte);
    }
}

const t = std.testing;

fn firstMatch(pattern: []const u8, text: []const u8, options: Options) !?[2]usize {
    var problem: Problem = .{};
    var re = try Regex.compile(t.allocator, pattern, options, &problem);
    defer re.deinit(t.allocator);
    var vm = Vm.init(t.allocator);
    defer vm.deinit();
    var caps: [64]u32 = undefined;
    if (!try re.find(&vm, text, 0, false, &caps)) return null;
    return .{ caps[0], caps[1] };
}

fn expectMatch(pattern: []const u8, text: []const u8, want: ?[]const u8) !void {
    const got = try firstMatch(pattern, text, .{ .case_sensitive = true });
    if (want) |w| {
        const r = got orelse {
            std.debug.print("{s} did not match {s}\n", .{ pattern, text });
            return error.TestExpectedEqual;
        };
        try t.expectEqualStrings(w, text[r[0]..r[1]]);
    } else try t.expect(got == null);
}

test "literals, classes, anchors and quantifiers" {
    try expectMatch("b+", "abbbc", "bbb");
    try expectMatch("b+?", "abbbc", "b");
    try expectMatch("a.c", "xxabc", "abc");
    try expectMatch("a.c", "a\nc", null);
    try expectMatch("[a-c]+", "zzcabz", "cab");
    try expectMatch("[^a-c]+", "abxyc", "xy");
    try expectMatch("\\d{2,3}", "a1234", "123");
    try expectMatch("\\d{2}", "a1", null);
    try expectMatch("x{2,}", "xxxxy", "xxxx");
    try expectMatch("^b", "a\nb", "b");
    try expectMatch("a$", "a\r\nb", "a");
    try expectMatch("\\bcat\\b", "concat cat", "cat");
    try t.expectEqual(@as(usize, 7), (try firstMatch("\\bcat\\b", "concat cat", .{})).?[0]);
    try expectMatch("cat|dog", "hotdog", "dog");
    try expectMatch("(?:ab)+", "ababab", "ababab");
    try expectMatch("colou?r", "color", "color");
    try expectMatch("a{", "a{", "a{");
    try expectMatch("\\$\\.\\[", "x$.[", "$.[");
    try expectMatch("[\\d.]+", "v1.25!", "1.25");
    try expectMatch("[\\D]+", "12ab3", "ab");
    try expectMatch("\\u{e9}", "caf\u{e9}", "\u{e9}");
    try expectMatch("caf.", "caf\u{e9}!", "caf\u{e9}");
    try expectMatch("[\u{e0}-\u{ff}]", "voil\u{e0}", "\u{e0}");
    // Leftmost first: the earliest start, then the preferred branch.
    try expectMatch("a|ab", "ab", "a");
    try expectMatch("(a|ab)c", "abc", "abc");
    // Nested empty loops end.
    try expectMatch("(a*)*b", "aaab", "aaab");
    try expectMatch("(a|)*", "aa", "aa");
}

test "case folding" {
    const r = (try firstMatch("hello [a-c]", "Say HELLO B", .{})).?;
    try t.expectEqual(@as(usize, 4), r[0]);
    try t.expect((try firstMatch("hello", "HELLO", .{ .case_sensitive = true })) == null);
}

test "errors say where" {
    var problem: Problem = .{};
    for ([_][]const u8{ "(ab", "ab)", "[ab", "*a", "a**", "\\q", "[z-a]", "(?=a)", "(a{1000}){1000}" }) |bad| {
        try t.expectError(error.Syntax, Regex.compile(t.allocator, bad, .{}, &problem));
        try t.expect(problem.message.len > 0);
    }
    try t.expectError(error.Syntax, Regex.compile(t.allocator, "ab)", .{}, &problem));
    try t.expectEqual(@as(usize, 2), problem.at);
}

test "groups and replacement templates" {
    var problem: Problem = .{};
    var re = try Regex.compile(t.allocator, "(\\w+)@(\\w+)", .{}, &problem);
    defer re.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), re.groups());
    var vm = Vm.init(t.allocator);
    defer vm.deinit();
    var caps: [6]u32 = undefined;
    const text = "mail: ann@example now";
    try t.expect(try re.find(&vm, text, 0, false, &caps));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try expand(t.allocator, &out, "$2 at $1 ($&) $$5 $9\\t!", text, &caps);
    try t.expectEqualStrings("example at ann (ann@example) $5 \t!", out.items);
    // An optional group that didn't take part writes nothing.
    var opt = try Regex.compile(t.allocator, "a(x)?b", .{}, &problem);
    defer opt.deinit(t.allocator);
    var caps2: [4]u32 = undefined;
    try t.expect(try opt.find(&vm, "ab", 0, false, &caps2));
    out.clearRetainingCapacity();
    try expand(t.allocator, &out, "[$1]", "ab", &caps2);
    try t.expectEqualStrings("[]", out.items);
}

test "linear time on a pattern that makes backtrackers explode" {
    var problem: Problem = .{};
    var re = try Regex.compile(t.allocator, "(a*)*b", .{}, &problem);
    defer re.deinit(t.allocator);
    var vm = Vm.init(t.allocator);
    defer vm.deinit();
    const text = try t.allocator.alloc(u8, 200_000);
    defer t.allocator.free(text);
    @memset(text, 'a');
    var caps: [4]u32 = undefined;
    try t.expect(!try re.find(&vm, text, 0, true, &caps));
}
