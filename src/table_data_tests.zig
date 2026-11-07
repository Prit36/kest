//! Data-safety checks underneath Params/Headers before the table UI pass.
const std = @import("std");
const w = @import("ui/widgets.zig");
const c = w.c;
const App = @import("app/state.zig").App;
const tab = @import("app/tab.zig");
const commands = @import("app/commands.zig");
const request = @import("core/request.zig");
const kv = @import("ui/key_value.zig");

fn check(src: std.builtin.SourceLocation, value: bool) !void {
    if (!value) {
        std.debug.print("Table data regression at {s}:{d}\n", .{ src.file, src.line });
        return error.TableDataRegression;
    }
}
fn equalRow(before: request.KeyValue, after: *tab.Row) bool {
    return std.mem.eql(u8, before.key, after.key.text()) and std.mem.eql(u8, before.value, after.value.text()) and
        before.enabled == after.enabled and before.is_file == after.is_file and (before.value.len > 0 or before.has_equals == after.has_equals);
}

fn model(app: *App) !void {
    const original = [_]request.KeyValue{
        .{ .key = "X-Exact-Case", .value = " leading and trailing " },
        .{ .key = "#literal=name", .value = "one\ntwo" },
        .{ .key = "Upload", .value = "C:\\a b.txt", .enabled = false, .is_file = true },
        .{ .key = "flag" },
        .{ .key = "empty", .has_equals = true },
        .{ .key = "dup", .value = "first" },
        .{ .key = "dup", .value = "second" },
    };
    var values = tab.Table.init(app.gpa);
    defer values.deinit();
    try values.load(&original);
    const insertion = (try values.insertion()).?;
    insertion.key.set("Uncommitted insertion");
    const first = values.rows.items[0];
    const first_uid = first.uid;
    if (values.fromBulk("Good: one\nBad: \"unterminated")) |_| return error.ExpectedBulkFailure else |err| try check(@src(), err == error.InvalidLine);
    try check(@src(), values.rows.items[0] == first and first.uid == first_uid and values.entry == insertion);
    for (original, values.rows.items) |before, after| try check(@src(), equalRow(before, after));
    try check(@src(), values.bulk_problem.line == 2);
    var output_allocator = std.testing.FailingAllocator.init(app.gpa, .{});
    const owned_bulk = try values.toBulk(output_allocator.allocator());
    output_allocator.allocator().free(owned_bulk);
    try check(@src(), output_allocator.allocated_bytes == output_allocator.freed_bytes);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const text = try values.toBulk(arena.allocator());
    try values.fromBulk(text);
    for (original, values.rows.items) |before, after| try check(@src(), equalRow(before, after));
    try check(@src(), values.rows.items[0].uid > first_uid and values.entry == null);
    try values.duplicateAt(4);
    try check(@src(), values.rows.items[5].has_equals);
    // Fail every Zig allocation used by the transaction, including building the
    // replacement rows after parsing. Old row/insertion pointers must survive.
    var reached_success = false;
    var failures: usize = 0;
    for (0..128) |offset| {
        var fault = std.testing.FailingAllocator.init(app.gpa, .{});
        {
            var probe = tab.Table.init(fault.allocator());
            defer probe.deinit();
            _ = try probe.add(original[0]);
            const entry = (try probe.insertion()).?;
            probe.bulk = .{};
            probe.bulk.?.set("Original bulk buffer");
            const old_row = probe.rows.items[0];
            const old_array = probe.rows.items.ptr;
            const old_uid = probe.next_uid;
            fault.fail_index = fault.alloc_index + offset;
            fault.resize_fail_index = fault.resize_index;
            if (probe.fromBulk("one: first\ntwo: second\n# @file upload: /fixture\nempty: \"\"")) |_| {
                try check(@src(), !fault.has_induced_failure and probe.rows.items.len == 4);
                reached_success = true;
            } else |err| {
                failures += 1;
                try check(@src(), err == error.OutOfMemory and fault.has_induced_failure);
                try check(@src(), probe.rows.items.ptr == old_array and probe.rows.items[0] == old_row and probe.next_uid == old_uid);
                try check(@src(), probe.entry == entry and equalRow(original[0], old_row));
                try check(@src(), std.mem.eql(u8, probe.bulk.?.text(), "Original bulk buffer"));
            }
        }
        try check(@src(), fault.allocated_bytes == fault.freed_bytes);
        if (reached_success) break;
    }
    try check(@src(), reached_success and failures >= 5);
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(app.gpa);
    for (0..4097) |_| try many.appendSlice(app.gpa, "key: value\n");
    const row_before_limit = values.rows.items[0];
    if (values.fromBulk(many.items)) |_| return error.ExpectedBulkFailure else |err| try check(@src(), err == error.TooManyRows);
    try check(@src(), values.rows.items[0] == row_before_limit and values.rows.items.len == original.len + 1);
}

fn rect(ui: *c.cui_ctx, t: *tab.Tab, key: [*:0]const u8) c.cui_rect {
    c.cui_push_id_int(ui, @intCast(t.uid));
    defer c.cui_pop_id(ui);
    c.cui_push_id(ui, "headers");
    defer c.cui_pop_id(ui);
    return c.cui_get_rect(ui, c.cui_make_id(ui, key));
}
fn tap(ui: *c.cui_ctx, app: *App, t: *tab.Tab, key: [*:0]const u8, comptime click: anytype) !void {
    const r = rect(ui, t, key);
    try check(@src(), r.w > 0 and r.h > 0);
    click(ui, app, r.x + r.w / 2, r.y + r.h / 2);
}
fn capture(ui: *c.cui_ctx, sw: *c.cui_sw_renderer, app: *App, path: ?[]const u8) !void {
    const source = path orelse return;
    const stem = source[0 .. source.len - std.fs.path.extension(source).len];
    const target = try std.fmt.allocPrint(app.gpa, "{s}-bulk-error.png", .{stem});
    defer app.gpa.free(target);
    try @import("ui_snapshots.zig").capture(ui, sw, app, target);
}
fn wait(ui: *c.cui_ctx, app: *App, t: *tab.Tab, comptime frame: anytype) !void {
    const start = std.Io.Clock.awake.now(app.io);
    while (t.running()) {
        frame(ui, app);
        if (std.Io.Clock.awake.now(app.io).toMilliseconds() - start.toMilliseconds() > 10000) return error.RequestTimedOut;
        try app.io.sleep(.fromMilliseconds(2), .awake);
    }
}
fn noWake(_: *App) void {}
fn noSchedule(_: *App, _: u64) void {}

pub fn run(ui: *c.cui_ctx, app: *App, sw: *c.cui_sw_renderer, snapshot: ?[]const u8, comptime frame: anytype, comptime click: anytype) !void {
    try model(app);
    const original_tabs = app.tabs;
    const original_active = app.active;
    const original_prefs = app.prefs;
    app.tabs = .empty;
    app.active = 0;
    defer {
        while (app.tabs.items.len > 0) commands.closeNow(app, app.tabs.items[app.tabs.items.len - 1]);
        app.tabs.deinit(app.gpa);
        app.tabs = original_tabs;
        app.active = original_active;
        app.prefs = original_prefs;
        c.cui_set_viewport(ui, 1180, 800, 1);
    }
    const t = commands.newTab(app) orelse return error.AllocationFailed;
    const source: request.Request = .{
        .url = "https://example.invalid/p?dup=one&dup=two&flag&empty=&special=a%26b%23c%2F+%26#fragment",
        .params = &.{
            .{ .key = "dup", .value = "one" },
            .{ .key = "off", .value = "", .enabled = false, .has_equals = true },
            .{ .key = "dup", .value = "two" },
            .{ .key = "flag" },
            .{ .key = "empty", .has_equals = true },
            .{ .key = "special", .value = "a&b#c%2F+%26" },
        },
        .headers = &.{ .{ .key = "X-Exact-Case", .value = " original spacing " }, .{ .key = "#Literal", .value = "{{token}}", .enabled = false } },
    };
    try t.fromRequest(source);
    for (source.params, t.params.rows.items) |before, after| try check(@src(), equalRow(before, after));
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const serialized = try (try t.toRequest(a)).toJson(a);
    const restored = try request.Request.parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a, serialized, .{}));
    try t.fromRequest(restored);
    for (source.params, t.params.rows.items) |before, after| try check(@src(), equalRow(before, after));
    t.syncUrlFromParams();
    try check(@src(), std.mem.eql(u8, source.url, t.url.text()));
    const persist = @import("app/persist.zig");
    persist.touchTab(app, t);
    persist.flush(app);
    persist.savePrefs(app);
    app.store.sync();
    {
        var reloaded = App.init(app.gpa, app.io, app.store, app.client, app.tmp_dir, noWake, noSchedule);
        defer reloaded.deinit();
        try persist.load(&reloaded);
        try check(@src(), reloaded.tabs.items.len == 1 and reloaded.current() != null);
        const loaded = reloaded.current().?;
        try check(@src(), std.mem.eql(u8, loaded.url.text(), source.url));
        for (source.params, loaded.params.rows.items) |before, after| try check(@src(), equalRow(before, after));
        for (source.headers, loaded.headers.rows.items) |before, after| try check(@src(), equalRow(before, after));
    }
    // Old files with stale enabled rows continue to follow their actual URL.
    try t.fromRequest(.{ .url = "https://example.invalid/?current=&current=two", .params = &.{.{ .key = "stale", .value = "ignored" }} });
    try check(@src(), t.params.rows.items.len == 2 and t.params.rows.items[0].has_equals);
    try t.fromRequest(source);
    app.prefs.sidebar_open = false;
    app.prefs.log_open = false;
    app.prefs.dark = true;
    t.pane = .headers;
    c.cui_set_viewport(ui, 640, 420, 1);
    for (0..4) |_| frame(ui, app);
    const header = t.headers.rows.items[0];
    kv.openBulk(&t.headers);
    t.headers.bulk.?.set("Good: one\nBad: \"unterminated");
    frame(ui, app);
    try tap(ui, app, t, "apply-bulk", click);
    for (0..3) |_| frame(ui, app);
    try check(@src(), t.headers.bulk != null and t.headers.rows.items[0] == header and equalRow(source.headers[0], header));
    try check(@src(), t.headers.bulk_problem.line == 2 and std.mem.endsWith(u8, t.headers.bulk.?.text(), "unterminated"));
    try capture(ui, sw, app, snapshot);
    try tap(ui, app, t, "cancel-bulk", click);
    try check(@src(), t.headers.bulk == null and equalRow(source.headers[0], header));
    kv.openBulk(&t.headers);
    for (0..2) |_| frame(ui, app);
    try tap(ui, app, t, "apply-bulk", click);
    try check(@src(), t.headers.bulk == null and t.headers.rows.items.len == source.headers.len);
    for (source.headers, t.headers.rows.items) |before, after| try check(@src(), equalRow(before, after));
    // Query edits must not split a literal cell into extra parameters/fragment.
    t.pane = .params;
    t.params.rows.items[5].value.set("literal&fragment#equals=kept%2F+%26");
    t.syncUrlFromParams();
    try check(@src(), std.mem.indexOf(u8, t.url.text(), "special=literal%26fragment%23equals=kept%2F+%26#fragment") != null);
    const request_before_browsing = try (try t.toRequest(a)).toJson(a);
    for (0..2) |_| {
        t.pane = .headers;
        frame(ui, app);
        t.pane = .params;
        frame(ui, app);
    }
    try check(@src(), std.mem.eql(u8, request_before_browsing, try (try t.toRequest(a)).toJson(a)));
    var server: @import("test_server").Server = undefined;
    try server.start(app.io);
    defer server.stop();
    const before_send = t.url.text();
    const query = std.mem.indexOfScalar(u8, before_send, '?').?;
    t.url.set(try std.fmt.allocPrint(a, "{s}{s}", .{ try server.url(a, "/echo"), before_send[query..] }));
    t.method.set("GET");
    t.headers.clear();
    _ = try t.headers.add(.{ .key = "X-Exact-Case", .value = "kept value" });
    commands.send(app, t);
    try wait(ui, app, t, frame);
    try check(@src(), t.shown != null and t.shown.?.resp.status == 200);
    const response = t.shown.?.resp.preview.items;
    try check(@src(), std.mem.indexOf(u8, response, "dup=one&dup=two&flag&empty=&special=literal%26fragment%23equals=kept%2F+%26") != null);
    try check(@src(), std.mem.indexOf(u8, response, "X-Exact-Case: kept value") != null);
    std.debug.print("CUI table data: atomic bulk errors/row limit/allocation failures, quoted/file/disabled round trips, exact query spelling and loopback separators passed\n", .{});
}
