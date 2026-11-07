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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var test_mode = false;
    var demo_mode = false;
    var show_sidebar = false;
    var light = false;
    var snapshot: ?[]const u8 = null;
    var width: f32 = 1180;
    var height: f32 = 800;
    var scale: f32 = 1;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--self-test")) test_mode = true;
        if (std.mem.eql(u8, arg, "--demo")) demo_mode = true;
        if (std.mem.eql(u8, arg, "--sidebar")) show_sidebar = true;
        if (std.mem.eql(u8, arg, "--light")) light = true;
        if (std.mem.startsWith(u8, arg, "--snapshot=")) snapshot = arg[11..];
        if (std.mem.startsWith(u8, arg, "--width=")) width = std.fmt.parseFloat(f32, arg[8..]) catch 1180;
        if (std.mem.startsWith(u8, arg, "--height=")) height = std.fmt.parseFloat(f32, arg[9..]) catch 800;
        if (std.mem.startsWith(u8, arg, "--scale=")) scale = std.fmt.parseFloat(f32, arg[8..]) catch return error.InvalidSnapshotScale;
    }
    platform.headless = test_mode or snapshot != null;
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
            if (light) app.prefs.dark = false;
            if (!test_mode) shell.narrow_open = show_sidebar;
            try @import("headless.zig").run(&app, test_mode, snapshot, width, height, scale);
        }
        return;
    }
    const window = c.cui_app_create(&.{ .title = if (demo_mode) "Kest (Demo)" else "Kest", .width = @intFromFloat(app.prefs.window_width), .height = @intFromFloat(app.prefs.window_height), .min_width = 640, .min_height = 420, .theme = if (app.prefs.dark) c.CUI_THEME_DARK else c.CUI_THEME_LIGHT, .accent = c.CUI_ACCENT_BLUE }) orelse return error.WindowCreationFailed;
    platform.window = window;
    platform.context = c.cui_app_ui(window);
    defer {
        // Texture lifetime ends with the context, after model cleanup.
        for (app.tabs.items) |t| t.response.reset();
        platform.context = null;
        platform.window = null;
        c.cui_app_destroy(window);
    }
    c.kest_host_attach(window);
    @import("window_icon.zig").apply(c.cui_app_native_window(window));
    while (c.cui_app_frame(window)) {
        const events = c.kest_host_events();
        if (events & 1 != 0 or events & 4 != 0) persist.flush(&app);
        if (events & 2 != 0) persist.refreshFromDisk(&app);
        const size = c.cui_app_size(window);
        if (app.prefs.window_width != size.x or app.prefs.window_height != size.y) {
            app.prefs.window_width = size.x;
            app.prefs.window_height = size.y;
            persist.prefsChanged(&app);
        }
        shell.view(platform.context.?, &app);
        c.cui_end_frame(platform.context);
        c.kest_quiet_caret(platform.context);
    }
}
