//! `--demo --bench` (diagnostics builds): what the interactions people repeat
//! most cost, on the demo workspace, headless. Each sample is one frame on the
//! UI thread (build, layout and draw-list generation; the GPU's rendering is
//! not included). A 4 MiB JSON response measures preparation, scrolling, pane
//! and tab switches, and what it keeps in memory while shown and once closed.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const shell = @import("ui/shell.zig");
const workspace = @import("ui/workspace.zig");
const commands = @import("app/commands.zig");
const App = @import("app/state.zig").App;

fn frame(ui: *c.cui_ctx, app: *App) u64 {
    const start = std.Io.Clock.Timestamp.now(app.io, .awake);
    c.cui_begin_frame(ui, 1.0 / 60.0);
    shell.view(ui, app);
    c.kest_end_frame(ui);
    c.kest_quiet_caret(ui);
    return @intCast(start.untilNow(app.io).raw.toNanoseconds());
}

/// Lets background preparation (formatting, trees, indexes) finish and adopt.
fn settle(ui: *c.cui_ctx, app: *App) void {
    for (0..40) |_| {
        _ = frame(ui, app);
        app.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

const Stats = struct {
    samples: std.ArrayList(u64) = .empty,
    fn add(s: *Stats, gpa: std.mem.Allocator, ns: u64) void {
        s.samples.append(gpa, ns) catch {};
    }
    fn report(s: *Stats, gpa: std.mem.Allocator, name: []const u8) void {
        defer s.samples.deinit(gpa);
        const items = s.samples.items;
        if (items.len == 0) return;
        std.mem.sort(u64, items, {}, std.sort.asc(u64));
        var total: u64 = 0;
        for (items) |v| total += v;
        const ms = struct {
            fn f(v: u64) f64 {
                return @as(f64, @floatFromInt(v)) / 1e6;
            }
        }.f;
        std.debug.print("bench {s:<28} n={d:>4}  mean {d:>7.3} ms  median {d:>7.3} ms  p95 {d:>7.3} ms  max {d:>7.3} ms\n", .{
            name,                              items.len,
            ms(total / items.len),             ms(items[items.len / 2]),
            ms(items[(items.len * 95) / 100]), ms(items[items.len - 1]),
        });
    }
};

pub fn run(app: *App, port: u16) !void {
    const gpa = app.gpa;
    const sw = c.cui_sw_create() orelse return error.RendererFailed;
    defer c.cui_sw_destroy(sw);
    const ui = c.cui_create(&.{ .renderer = c.cui_sw_iface(sw), .theme = c.CUI_THEME_DARK, .accent = c.CUI_ACCENT_BLUE }) orelse return error.ContextFailed;
    @import("ui/platform.zig").context = ui;
    defer {
        for (app.tabs.items) |t| t.response.reset();
        @import("ui/platform.zig").context = null;
        c.cui_destroy(ui);
    }
    c.cui_set_reduced_motion(ui, true);
    c.cui_set_viewport(ui, 1280, 800, 1);
    // Warm every tab once so glyphs and prepared views exist.
    for (0..app.tabs.items.len) |i| {
        commands.activate(app, i);
        settle(ui, app);
    }
    commands.activate(app, 0);
    settle(ui, app);

    memory("demo warmed");
    const rounds = 30;
    var idle: Stats = .{};
    for (0..300) |_| idle.add(gpa, frame(ui, app));
    idle.report(gpa, "idle frame");

    var hover: Stats = .{};
    for (0..300) |i| {
        c.cui_input_mouse_move(ui, 300 + @as(f32, @floatFromInt(i % 600)), 120 + @as(f32, @floatFromInt((i * 7) % 600)));
        hover.add(gpa, frame(ui, app));
    }
    hover.report(gpa, "pointer move");
    c.cui_input_mouse_leave(ui);

    var tabs: Stats = .{};
    var tabs_settle: Stats = .{};
    for (0..rounds) |_| for (0..app.tabs.items.len) |i| {
        commands.activate(app, i);
        tabs.add(gpa, frame(ui, app));
        var total: u64 = 0;
        for (0..4) |_| total += frame(ui, app);
        tabs_settle.add(gpa, total);
    };
    tabs.report(gpa, "tab switch (1st frame)");
    tabs_settle.report(gpa, "tab switch (+4 frames)");

    var panes: Stats = .{};
    commands.activate(app, 1);
    settle(ui, app);
    for (0..rounds) |_| for ([_]@import("app/tab.zig").ResponsePane{ .pretty, .raw, .headers, .pretty }) |pane| {
        app.current().?.response.pane = pane;
        panes.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    };
    panes.report(gpa, "response pane switch");

    var requests: Stats = .{};
    for (0..rounds) |_| for ([_]@import("app/tab.zig").RequestPane{ .params, .headers, .body, .settings }) |pane| {
        app.current().?.pane = pane;
        requests.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    };
    requests.report(gpa, "request pane switch");

    var layouts: Stats = .{};
    for (0..rounds) |_| for ([_]workspace.Layout{ .columns, .stacked }) |layout| {
        workspace.layout = layout;
        layouts.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    };
    workspace.layout = .auto;
    layouts.report(gpa, "layout switch");

    var sidebar: Stats = .{};
    for (0..rounds) |_| for ([_]@import("app/state.zig").SidebarMode{ .history, .environments, .collections }) |mode| {
        app.mode = mode;
        sidebar.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    };
    sidebar.report(gpa, "sidebar mode switch");

    var toggles: Stats = .{};
    for (0..rounds * 2) |_| {
        app.prefs.sidebar_open = !app.prefs.sidebar_open;
        toggles.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    }
    toggles.report(gpa, "sidebar toggle");

    var resize: Stats = .{};
    for (0..rounds * 4) |i| {
        c.cui_set_viewport(ui, 1000 + @as(f32, @floatFromInt((i * 37) % 900)), 700 + @as(f32, @floatFromInt((i * 23) % 400)), 1);
        resize.add(gpa, frame(ui, app));
    }
    c.cui_set_viewport(ui, 1280, 800, 1);
    resize.report(gpa, "window resize");

    app.prefs.follow_system = false;
    var theme: Stats = .{};
    for (0..rounds) |_| {
        app.prefs.dark = !app.prefs.dark;
        theme.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    }
    theme.report(gpa, "theme switch");

    // A 4 MiB JSON response: sending, first view, tab switches and scrolling.
    memory("before the large request");
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/demo/large", .{port});
    defer gpa.free(url);
    const big = commands.openUnsaved(app, .{ .name = "Large", .url = url }) orelse return error.BenchTabFailed;
    commands.send(app, big);
    const sent = std.Io.Clock.Timestamp.now(app.io, .awake);
    while (big.running()) {
        _ = frame(ui, app);
        app.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    memory("large: received, before preparing");
    const big_index = app.active;
    var first_view: Stats = .{};
    var frames_to_ready: usize = 0;
    var ready_ns: u64 = 0;
    while (frames_to_ready < 5000) : (frames_to_ready += 1) {
        first_view.add(gpa, frame(ui, app));
        if (big.response.tree != null or big.response.formatted != null) break;
        app.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    ready_ns = @intCast(sent.untilNow(app.io).raw.toNanoseconds());
    std.debug.print("bench large JSON: send+prepare {d:.1} ms, {d} frames until the prepared view\n", .{ @as(f64, @floatFromInt(ready_ns)) / 1e6, frames_to_ready });
    settle(ui, app);
    first_view.report(gpa, "large: frames while preparing");
    memory("large response shown");
    breakdown(big);
    var big_idle: Stats = .{};
    for (0..200) |_| big_idle.add(gpa, frame(ui, app));
    big_idle.report(gpa, "large: idle frame");
    var big_scroll: Stats = .{};
    c.cui_input_mouse_move(ui, 1000, 500);
    for (0..300) |i| {
        c.cui_input_scroll(ui, 0, if ((i / 100) % 2 == 0) -3 else 3);
        big_scroll.add(gpa, frame(ui, app));
    }
    big_scroll.report(gpa, "large: scroll");
    var big_panes: Stats = .{};
    for (0..10) |_| for ([_]@import("app/tab.zig").ResponsePane{ .raw, .headers, .pretty }) |pane| {
        big.response.pane = pane;
        big_panes.add(gpa, frame(ui, app));
        settle(ui, app);
    };
    big_panes.report(gpa, "large: pane switch");
    var big_tabs: Stats = .{};
    for (0..rounds) |_| for ([_]usize{ 0, big_index }) |i| {
        commands.activate(app, i);
        big_tabs.add(gpa, frame(ui, app));
        _ = frame(ui, app);
    };
    big_tabs.report(gpa, "large: tab switch");
    memory("large: after raw/headers views");
    breakdown(big);
    commands.closeNow(app, big);
    settle(ui, app);
    memory("large tab closed");
}

const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set: usize,
    working_set: usize,
    quota_peak_paged_pool: usize,
    quota_paged_pool: usize,
    quota_peak_non_paged_pool: usize,
    quota_non_paged_pool: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
};
extern "kernel32" fn K32GetProcessMemoryInfo(process: std.os.windows.HANDLE, counters: *ProcessMemoryCounters, cb: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;

fn memory(label: []const u8) void {
    var m = std.mem.zeroes(ProcessMemoryCounters);
    m.cb = @sizeOf(ProcessMemoryCounters);
    _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &m, m.cb);
    std.debug.print("memory {s:<34} private {d:>7.1} MB  working set {d:>7.1} MB\n", .{ label, @as(f64, @floatFromInt(m.private_usage)) / 1048576.0, @as(f64, @floatFromInt(m.working_set)) / 1048576.0 });
}

fn breakdown(t: *@import("app/tab.zig").Tab) void {
    const v = &t.response;
    const MB = 1048576.0;
    if (t.shown) |job| std.debug.print("  body preview: len {d:.1} MB cap {d:.1} MB\n", .{ @as(f64, @floatFromInt(job.resp.preview.items.len)) / MB, @as(f64, @floatFromInt(job.resp.preview.capacity)) / MB });
    if (v.tree) |tree| std.debug.print("  tree nodes: {d} (cap {d}) = {d:.1} MB; rows cap {d:.1} MB\n", .{ tree.nodes.items.len, tree.nodes.capacity, @as(f64, @floatFromInt(tree.nodes.capacity * 24)) / MB, @as(f64, @floatFromInt(tree.rows.capacity * 4)) / MB });
    if (v.formatted) |f| std.debug.print("  formatted: {d:.1} MB\n", .{@as(f64, @floatFromInt(f.len)) / MB});
    std.debug.print("  geometry: pretty {d:.1} MB raw {d:.1} MB; continued strings {d}\n", .{ geometryMB(&v.code_pretty), geometryMB(&v.code_raw), v.code_pretty.continued_strings.capacity });
    std.debug.print("  raw index: starts cap {d:.1} MB lines cap {d:.1} MB; pretty index: starts cap {d:.1} MB lines cap {d:.1} MB (rows {d})\n", .{
        @as(f64, @floatFromInt(v.code_raw.index.starts.capacity * 4)) / MB,    @as(f64, @floatFromInt(v.code_raw.index.lines.capacity * 4)) / MB,
        @as(f64, @floatFromInt(v.code_pretty.index.starts.capacity * 4)) / MB, @as(f64, @floatFromInt(v.code_pretty.index.lines.capacity * 4)) / MB,
        v.code_pretty.index.starts.items.len,
    });
}

fn geometryMB(s: *const @import("ui/code_state.zig").State) f64 {
    const g = s.geometry orelse return 0;
    const bytes = g.index.starts.capacity * 4 + g.index.lines.capacity * 4 + g.widths.capacity * 8 + g.row_checkpoints.capacity * 4 + g.starts.capacity * 4 + g.xs.capacity * 8 + g.strings.capacity * @sizeOf(@TypeOf(g.strings.items[0]));
    return @as(f64, @floatFromInt(bytes)) / 1048576.0;
}
