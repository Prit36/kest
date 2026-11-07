//! One open request: its editable form, and the last response it got.
const std = @import("std");
const ui = @import("../ui/model.zig");
const req = @import("../core/request.zig");
const col = @import("../core/collection.zig");
const url_util = @import("../utils/url.zig");
const http_client = @import("../network/http_client.zig");
const code = @import("../ui/code_state.zig");
const json_tree = @import("../core/json_tree.zig");
const Allocator = std.mem.Allocator;

/// An editable key/value row. Boxed: text fields keep pointers across frames.
pub const Row = struct {
    uid: u32,
    key: ui.TextBuffer = .{},
    value: ui.TextBuffer = .{},
    enabled: bool = true,
    is_file: bool = false,
};

pub const Table = struct {
    gpa: Allocator,
    rows: std.ArrayList(*Row) = .empty,
    next_uid: u32 = 1,
    /// The bulk editor's text while it's open.
    bulk: ?ui.TextBuffer = null,
    /// A real editable insertion row, outside request data until first input.
    /// Promoting the same pointer/uid preserves focus, selection and native undo.
    entry: ?*Row = null,

    pub fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *Table) void {
        t.clear();
        t.rows.deinit(t.gpa);
        if (t.bulk) |*b| b.deinit();
    }

    pub fn clear(t: *Table) void {
        for (t.rows.items) |r| t.free(r);
        t.rows.clearRetainingCapacity();
        if (t.entry) |r| t.free(r);
        t.entry = null;
    }

    pub fn insertion(t: *Table) !?*Row {
        if (t.rows.items.len >= 4096) return null;
        if (t.entry == null) {
            const r = try t.gpa.create(Row);
            r.* = .{ .uid = t.next_uid };
            t.next_uid += 1;
            t.entry = r;
        }
        return t.entry;
    }

    pub fn commitInsertion(t: *Table) !void {
        const r = t.entry orelse return;
        if (t.rows.items.len >= 4096) return error.TooManyRows;
        try t.rows.append(t.gpa, r);
        t.entry = null;
    }

    fn free(t: *Table, r: *Row) void {
        r.key.deinit();
        r.value.deinit();
        t.gpa.destroy(r);
    }

    pub fn add(t: *Table, kv: req.KeyValue) !*Row {
        if (t.rows.items.len >= 4096) return error.TooManyRows;
        const r = try t.gpa.create(Row);
        r.* = .{ .uid = t.next_uid, .enabled = kv.enabled, .is_file = kv.is_file };
        t.next_uid += 1;
        r.key.set(kv.key);
        r.value.set(kv.value);
        try t.rows.append(t.gpa, r);
        return r;
    }

    pub fn removeAt(t: *Table, i: usize) void {
        t.free(t.rows.orderedRemove(i));
    }

    pub fn duplicateAt(t: *Table, i: usize) !void {
        const src = t.rows.items[i];
        const r = try t.add(.{ .key = src.key.text(), .value = src.value.text(), .enabled = src.enabled, .is_file = src.is_file });
        _ = t.rows.pop();
        try t.rows.insert(t.gpa, i + 1, r);
    }

    pub fn load(t: *Table, rows: []const req.KeyValue) !void {
        t.clear();
        for (rows) |kv| _ = try t.add(kv);
    }

    /// As data, in `a`: rows wholly empty are left out.
    pub fn toKeyValues(t: *const Table, a: Allocator) ![]req.KeyValue {
        var out: std.ArrayList(req.KeyValue) = .empty;
        for (t.rows.items) |r| {
            if (r.key.text().len == 0 and r.value.text().len == 0) continue;
            try out.append(a, .{ .key = try a.dupe(u8, r.key.text()), .value = try a.dupe(u8, r.value.text()), .enabled = r.enabled, .is_file = r.is_file });
        }
        return out.items;
    }

    /// One "key: value" a line; a disabled row starts with "# ".
    pub fn toBulk(t: *const Table, a: Allocator, sep: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (t.rows.items) |r| {
            if (r.key.text().len == 0 and r.value.text().len == 0) continue;
            if (!r.enabled) try out.appendSlice(a, "# ");
            try out.appendSlice(a, r.key.text());
            try out.appendSlice(a, sep);
            try out.appendSlice(a, r.value.text());
            try out.append(a, '\n');
        }
        return out.toOwnedSlice(a);
    }

    pub fn fromBulk(t: *Table, text: []const u8) !void {
        t.clear();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            var l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0) continue;
            var enabled = true;
            if (std.mem.startsWith(u8, l, "#")) {
                enabled = false;
                l = std.mem.trimStart(u8, l[1..], " \t");
            }
            const sep = std.mem.indexOfAny(u8, l, ":=") orelse l.len;
            const key = std.mem.trim(u8, l[0..sep], " \t");
            const value = if (sep < l.len) std.mem.trim(u8, l[sep + 1 ..], " \t") else "";
            _ = try t.add(.{ .key = key, .value = value, .enabled = enabled });
        }
    }
};

pub const Link = struct { collection: col.Id, request: col.Id };

pub const RequestPane = enum { params, headers, body, settings };
pub const ResponsePane = enum { pretty, raw, headers, preview };
pub const PrettyMode = enum { tree, text, minified };

/// The viewer's state, for the response on show. Rebuilt lazily per response.
pub const ResponseView = struct {
    gpa: Allocator,
    image: usize = 0,
    image_width: c_int = 0,
    image_height: c_int = 0,
    image_attempted: bool = false,
    format_attempted: bool = false,
    pane: ResponsePane = .pretty,
    pretty_mode: PrettyMode = .text,
    tree: ?json_tree.Tree = null,
    /// Tree couldn't be built (not JSON, or partial): says why.
    tree_failed: bool = false,
    /// Formatted text (the pretty text or minified view).
    formatted: ?[]u8 = null,
    formatted_mode: PrettyMode = .tree,
    /// A hex dump, made only if a binary body is looked at.
    hex: ?[]u8 = null,
    /// The tag-stripped preview of an HTML body.
    stripped: ?[]u8 = null,
    code_pretty: code.State,
    code_raw: code.State,
    query: ui.TextBuffer = .{},
    /// The tree's matching nodes.
    tree_hits: std.ArrayList(u32) = .empty,
    tree_hit_at: usize = 0,
    tree_scroll_to: ?usize = null,
    menu_open: bool = false,
    menu_anchor: ?ui.Rect = null,
    menu_node: u32 = 0,

    pub fn init(gpa: Allocator) ResponseView {
        return .{ .gpa = gpa, .code_pretty = .init(gpa), .code_raw = .init(gpa) };
    }

    /// Forgets what was made from the last response.
    pub fn reset(v: *ResponseView) void {
        v.image_attempted = false;
        v.format_attempted = false;
        if (v.image != 0) {
            if (@import("../ui/platform.zig").context) |ctx| @import("../ui/c.zig").c.cui_image_destroy(ctx, v.image);
            v.image = 0;
        }
        if (v.tree) |*t| t.deinit(v.gpa);
        v.tree = null;
        v.tree_failed = false;
        if (v.formatted) |f| v.gpa.free(f);
        v.formatted = null;
        if (v.hex) |h| v.gpa.free(h);
        v.hex = null;
        if (v.stripped) |h| v.gpa.free(h);
        v.stripped = null;
        v.tree_hits.clearAndFree(v.gpa);
        v.tree_hit_at = 0;
        // Row indexes and search results can dwarf the response itself. A
        // cleared response must also release these derived buffers and scroll.
        v.code_pretty.deinit();
        v.code_pretty = .init(v.gpa);
        v.code_raw.deinit();
        v.code_raw = .init(v.gpa);
    }

    pub fn deinit(v: *ResponseView) void {
        v.reset();
        v.code_pretty.deinit();
        v.code_raw.deinit();
        v.query.deinit();
        v.tree_hits.deinit(v.gpa);
    }
};

pub const Tab = struct {
    gpa: Allocator,
    /// Names its draft file, and its place in the UI's identity.
    id: col.Id,
    uid: u64,
    link: ?Link = null,
    name: []u8,
    description: []u8 = &.{},
    method: ui.TextBuffer = .{},
    url: ui.TextBuffer = .{},
    params: Table,
    headers: Table,
    form: Table,
    body: code.State,
    body_kind: req.BodyKind = .none,
    file_path: ui.TextBuffer = .{},
    settings: req.Settings = .{},
    timeout_text: ui.TextBuffer = .{},
    max_size_text: ui.TextBuffer = .{},
    max_redirects_text: ui.TextBuffer = .{},
    pane: RequestPane = .params,
    /// A session-only view choice; request data and split preference stay intact.
    details_collapsed: bool = false,
    editing_method: bool = false,
    method_open: bool = false,
    custom_method: ui.TextBuffer = .{},
    /// Edits not yet in its file.
    dirty: bool = false,
    /// Edited since the last flush.
    touched: bool = false,
    /// A draft is on disk for it.
    has_draft: bool = false,
    saved_hash: u64 = 0,
    file_mtime: ?i96 = null,
    /// Being sent, and the response on show. Only the UI thread touches these.
    job: ?*http_client.Job = null,
    shown: ?*http_client.Job = null,
    unresolved_note: []u8 = &.{},
    /// The request as sent, for its history entry when the answer comes.
    pending_snapshot: ?[]u8 = null,
    response: ResponseView,
    /// What's wrong with the JSON body, cached per version.
    body_problem_version: u64 = 0,
    body_problem_at: ?usize = null,
    body_problem_text: []u8 = &.{},
    /// Headers table autocomplete: the row whose name is focused.
    last_url: []u8 = &.{},

    pub fn create(gpa: Allocator, id: col.Id, uid: u64) !*Tab {
        const t = try gpa.create(Tab);
        t.* = .{
            .gpa = gpa,
            .id = id,
            .uid = uid,
            .name = try gpa.dupe(u8, "Untitled"),
            .params = .init(gpa),
            .headers = .init(gpa),
            .form = .init(gpa),
            .body = .init(gpa),
            .response = .init(gpa),
        };
        t.method.set("GET");
        t.setSettingsText();
        return t;
    }

    pub fn destroy(t: *Tab) void {
        t.gpa.free(t.name);
        t.gpa.free(t.description);
        t.gpa.free(t.unresolved_note);
        if (t.pending_snapshot) |p| t.gpa.free(p);
        t.gpa.free(t.last_url);
        t.gpa.free(t.body_problem_text);
        t.method.deinit();
        t.url.deinit();
        t.params.deinit();
        t.headers.deinit();
        t.form.deinit();
        t.body.deinit();
        t.file_path.deinit();
        t.timeout_text.deinit();
        t.max_size_text.deinit();
        t.max_redirects_text.deinit();
        t.custom_method.deinit();
        t.response.deinit();
        if (t.shown) |j| j.destroy();
        t.gpa.destroy(t);
    }

    fn setSettingsText(t: *Tab) void {
        var buf: [32]u8 = undefined;
        t.timeout_text.set(std.fmt.bufPrint(&buf, "{d}", .{t.settings.timeout_ms}) catch "30000");
        t.max_size_text.set(std.fmt.bufPrint(&buf, "{d}", .{t.settings.max_response_bytes / (1024 * 1024)}) catch "256");
        t.max_redirects_text.set(std.fmt.bufPrint(&buf, "{d}", .{t.settings.max_redirects}) catch "10");
    }

    /// Replaces its form with `r`, as loaded (not an edit).
    pub fn fromRequest(t: *Tab, r: req.Request) !void {
        try setOwned(t.gpa, &t.name, r.name);
        try setOwned(t.gpa, &t.description, r.description);
        t.method.set(r.method);
        t.url.set(r.url);
        // The URL's query rows, then the disabled ones it can't hold.
        var ar = std.heap.ArenaAllocator.init(t.gpa);
        defer ar.deinit();
        try t.params.load(try url_util.parseParams(ar.allocator(), r.url));
        for (r.params) |p| if (!p.enabled) {
            _ = try t.params.add(p);
        };
        try t.headers.load(r.headers);
        try t.form.load(r.form);
        t.body.setText(r.body_text);
        t.body_kind = r.body_kind;
        t.file_path.set(r.file_path);
        t.settings = r.settings;
        t.setSettingsText();
        try setOwned(t.gpa, &t.last_url, r.url);
        t.touched = false;
    }

    /// As data, in `a`.
    pub fn toRequest(t: *const Tab, a: Allocator) !req.Request {
        return .{
            .name = try a.dupe(u8, t.name),
            .description = try a.dupe(u8, t.description),
            .method = try a.dupe(u8, std.mem.trim(u8, t.method.text(), " ")),
            .url = try a.dupe(u8, t.url.text()),
            .params = try t.params.toKeyValues(a),
            .headers = try t.headers.toKeyValues(a),
            .body_kind = t.body_kind,
            .body_text = try a.dupe(u8, t.body.text()),
            .form = try t.form.toKeyValues(a),
            .file_path = try a.dupe(u8, t.file_path.text()),
            .settings = t.settings,
        };
    }

    /// The URL changed: its query becomes the enabled rows.
    pub fn syncParamsFromUrl(t: *Tab) void {
        if (std.mem.eql(u8, t.last_url, t.url.text())) return;
        setOwned(t.gpa, &t.last_url, t.url.text()) catch return;
        var ar = std.heap.ArenaAllocator.init(t.gpa);
        defer ar.deinit();
        const a = ar.allocator();
        const parsed = url_util.parseParams(a, t.url.text()) catch return;
        // Disabled rows stay, after the rest.
        var disabled: std.ArrayList(req.KeyValue) = .empty;
        for (t.params.rows.items) |r| if (!r.enabled) {
            disabled.append(a, .{ .key = a.dupe(u8, r.key.text()) catch return, .value = a.dupe(u8, r.value.text()) catch return, .enabled = false }) catch return;
        };
        // Same shape: keep the rows (and any focus in them).
        const live = t.liveParamCount();
        if (live == parsed.len) {
            var i: usize = 0;
            for (t.params.rows.items) |r| if (r.enabled) {
                if (!std.mem.eql(u8, r.key.text(), parsed[i].key)) r.key.set(parsed[i].key);
                if (!std.mem.eql(u8, r.value.text(), parsed[i].value)) r.value.set(parsed[i].value);
                i += 1;
            };
            return;
        }
        t.params.load(parsed) catch return;
        for (disabled.items) |d| _ = t.params.add(d) catch return;
    }

    fn liveParamCount(t: *const Tab) usize {
        var n: usize = 0;
        for (t.params.rows.items) |r| {
            if (r.enabled) n += 1;
        }
        return n;
    }

    /// The rows changed: the URL's query is made from them.
    pub fn syncUrlFromParams(t: *Tab) void {
        var ar = std.heap.ArenaAllocator.init(t.gpa);
        defer ar.deinit();
        const a = ar.allocator();
        const rows = t.params.toKeyValues(a) catch return;
        const next = url_util.withParams(a, t.url.text(), rows) catch return;
        if (std.mem.eql(u8, next, t.url.text())) return;
        t.url.set(next);
        setOwned(t.gpa, &t.last_url, next) catch {};
    }

    pub fn running(t: *const Tab) bool {
        return t.job != null;
    }
};

pub fn setOwned(a: Allocator, field: *[]u8, value: []const u8) !void {
    const copy = try a.dupe(u8, value);
    a.free(field.*);
    field.* = copy;
}
