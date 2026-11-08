//! Native CUI host; the Zig HTTP engine and store own all background work.
const std = @import("std");
const c = @import("ui/c.zig").c;
const w = @import("ui/widgets.zig");
const platform = @import("ui/platform.zig");
const shell = @import("ui/shell.zig");
const App = @import("app/state.zig").App;
const persist = @import("app/persist.zig");
const commands = @import("app/commands.zig");
const Store = @import("storage/store.zig").Store;
const transport = @import("network/transport.zig");

fn wake(_: *App) void {
    c.kest_host_wake();
}
fn schedule(_: *App, ms: u64) void {
    c.kest_host_schedule(@intCast(ms));
}
fn storeFailed(_: ?*anyopaque) void {
    c.kest_host_wake();
}
fn readClipboard(a: std.mem.Allocator) ?[]u8 {
    if (platform.headless) return null;
    const text = c.kest_clipboard(platform.context);
    return if (text != null) a.dupe(u8, std.mem.span(text)) catch null else null;
}

fn syncWindowGeometry(app: *App) void {
    var geometry: c.kest_window_geometry = undefined;
    if (!c.kest_host_get_geometry(&geometry)) return;
    const placement: @import("storage/workspace_store.zig").WindowPlacement = .{
        .x = geometry.x,
        .y = geometry.y,
        .width = @intCast(geometry.width),
        .height = @intCast(geometry.height),
        .dpi = geometry.dpi,
        .maximized = geometry.maximized,
    };
    if (app.prefs.window_placement == null or !std.meta.eql(app.prefs.window_placement.?, placement) or
        app.prefs.window_width != geometry.client_width or app.prefs.window_height != geometry.client_height)
    {
        app.prefs.window_placement = placement;
        app.prefs.window_width = geometry.client_width;
        app.prefs.window_height = geometry.client_height;
        persist.prefsChanged(app);
    }
}

/// On Windows, std.Thread passes its stack size to the kernel as the size to
/// commit up front, so every I/O worker (the store writer, each request and
/// each response preparation) would pin 16 MiB of private memory for its
/// lifetime, and the pool keeps idle workers. Commit a small initial stack
/// instead: the executable's 16 MiB reservation is unchanged, so a thread
/// still grows on demand to the same maximum depth.
fn limitThreadStacks(io: std.Io) void {
    if (@import("builtin").os.tag != .windows) return;
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata orelse return));
    threaded.stack_size = 256 * 1024;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    limitThreadStacks(io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var test_mode = false;
    var demo_mode = false;
    var bench = false;
    var show_sidebar = false;
    var light = false;
    var snapshot: ?[]const u8 = null;
    var width: f32 = 1180;
    var height: f32 = 800;
    var scale: f32 = 1;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--self-test")) test_mode = true;
        if (std.mem.eql(u8, arg, "--demo")) demo_mode = true;
        if (std.mem.eql(u8, arg, "--bench")) bench = true;
        if (std.mem.eql(u8, arg, "--sidebar")) show_sidebar = true;
        if (std.mem.eql(u8, arg, "--light")) light = true;
        if (std.mem.startsWith(u8, arg, "--snapshot=")) snapshot = arg[11..];
        if (std.mem.startsWith(u8, arg, "--width=")) width = std.fmt.parseFloat(f32, arg[8..]) catch 1180;
        if (std.mem.startsWith(u8, arg, "--height=")) height = std.fmt.parseFloat(f32, arg[9..]) catch 800;
        if (std.mem.startsWith(u8, arg, "--scale=")) scale = std.fmt.parseFloat(f32, arg[8..]) catch return error.InvalidSnapshotScale;
    }
    platform.headless = test_mode or bench or snapshot != null;
    if (bench and !demo_mode) return error.BenchNeedsDemo;
    if (!@import("build_options").diagnostics and platform.headless) return error.DiagnosticsNotEnabled;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width < 640 or height < 420 or width > 8192 or height > 8192) return error.InvalidSnapshotDimensions;
    if (!std.math.isFinite(scale) or scale < 1 or scale > 4 or width * scale > 8192 or height * scale > 8192) return error.InvalidSnapshotScale;
    if (platform.headless and init.environ_map.get("KEST_DATA") == null) return error.ScratchKEST_DATARequired;
    const data = if (demo_mode) blk: {
        const base = init.environ_map.get("KEST_DATA") orelse init.environ_map.get("APPDATA") orelse return error.AppDataUnavailable;
        const id = @import("core/collection.zig").newId(io);
        break :blk try std.fs.path.join(gpa, &.{ base, "kest-demo", &id });
    } else if (init.environ_map.get("KEST_DATA")) |d| try gpa.dupe(u8, d) else blk: {
        const base = init.environ_map.get("APPDATA") orelse return error.AppDataUnavailable;
        break :blk try std.fs.path.join(gpa, &.{ base, "kest-cui" });
    };
    defer gpa.free(data);
    var demo_server: @import("demo_server").Server = undefined;
    if (demo_mode) try demo_server.start(io);
    defer if (demo_mode) demo_server.stop();
    var store = try Store.open(gpa, io, data);
    try store.startWriter();
    defer store.close();
    store.on_failure = storeFailed;
    store.dir.deleteTree(io, "tmp") catch {};
    try store.dir.createDirPath(io, "tmp");
    const tmp = try std.fs.path.join(gpa, &.{ data, "tmp" });
    defer gpa.free(tmp);
    var client = transport.Client.init(gpa, io);
    var app = App.init(gpa, io, &store, &client, tmp, wake, schedule);
    // Client stops before App is destroyed; queued completions still own tabs.
    defer {
        client.deinit();
        commands.drainDone(&app);
        persist.flush(&app);
        persist.savePrefs(&app);
        app.deinit();
    }
    app.read_clipboard = readClipboard;
    persist.load(&app) catch |e| app.toast(.danger, "Could not load workspace", @errorName(e));
    @import("ui/workspace.zig").layout = app.prefs.editor_layout;
    @import("ui/workspace.zig").column_ratio = app.prefs.column_split;
    shell.sidebar_ratio = app.prefs.sidebar_width / @max(640, app.prefs.window_width);
    w.arena = .init(gpa);
    defer w.arena.deinit();
    if (demo_mode) {
        try @import("demo.zig").populate(&app, demo_server.port);
        try @import("demo.zig").warm(&app);
        if (platform.headless) try @import("demo.zig").validate(&app);
    }
    if (platform.headless) {
        if (comptime @import("build_options").diagnostics) {
            if (light) {
                app.prefs.dark = false;
                app.prefs.follow_system = false;
            }
            if (!test_mode) shell.narrow_open = show_sidebar;
            if (bench) return @import("bench.zig").run(&app, demo_server.port);
            try @import("headless.zig").run(&app, test_mode, snapshot, width, height, scale);
        }
        return;
    }
    shell.followSystemAppearance(&app);
    // Restore and clamp before showing. Avoid allocating an enormous initial
    // surface for stale preferences from a monitor that is no longer attached.
    const window = c.cui_app_create(&.{ .title = if (demo_mode) "Kest (Demo)" else "Kest", .width = @intFromFloat(@min(1280, app.prefs.window_width)), .height = @intFromFloat(@min(800, app.prefs.window_height)), .hidden = true, .min_width = 640, .min_height = 420, .theme = if (app.prefs.dark) c.CUI_THEME_DARK else c.CUI_THEME_LIGHT, .accent = c.CUI_ACCENT_BLUE, .renderer = c.CUI_RENDERER_SOFTWARE }) orelse return error.WindowCreationFailed;
    platform.window = window;
    platform.context = c.cui_app_ui(window);
    defer {
        syncWindowGeometry(&app);
        // Texture lifetime ends with the context, after model cleanup.
        for (app.tabs.items) |t| t.response.reset();
        platform.context = null;
        platform.window = null;
        c.cui_app_destroy(window);
        c.kest_gpu_release();
    }
    c.kest_host_attach(window);
    @import("window_icon.zig").apply(c.cui_app_native_window(window));
    var geometry: c.kest_window_geometry = std.mem.zeroes(c.kest_window_geometry);
    geometry.client_width = app.prefs.window_width;
    geometry.client_height = app.prefs.window_height;
    if (app.prefs.window_placement) |placement| {
        geometry.x = placement.x;
        geometry.y = placement.y;
        geometry.width = @intCast(placement.width);
        geometry.height = @intCast(placement.height);
        geometry.dpi = placement.dpi;
        geometry.maximized = placement.maximized;
        geometry.positioned = true;
    }
    c.kest_host_restore_geometry(&geometry, true);
    platform.renderer_final = false;
    while (c.cui_app_frame(window)) {
        c.kest_host_reveal(window);
        if (!platform.renderer_final) platform.renderer_final = c.kest_gpu_adopt(window) != 0;
        const events = c.kest_host_events();
        if (events & 1 != 0 or events & 4 != 0) persist.flush(&app);
        if (events & 2 != 0) persist.refreshFromDisk(&app);
        if (events & 8 != 0) syncWindowGeometry(&app);
        shell.view(platform.context.?, &app);
        c.kest_end_frame(platform.context);
        c.kest_host_sync_chrome(platform.context);
        c.kest_quiet_caret(platform.context);
        c.kest_host_wait_if_minimized();
    }
}
