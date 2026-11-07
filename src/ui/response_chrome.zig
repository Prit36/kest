//! Responsive response navigation and execution metadata.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const Response = @import("../core/response.zig").Response;
const states = @import("../core/response_status.zig");
const metrics = @import("../utils/metrics.zig");
const commands = @import("../app/commands.zig");

pub const Summary = struct { short: []const u8, full: []const u8, duration: []const u8, size: []const u8, token: c_int };
pub fn token(tone: states.Tone) c_int {
    return switch (tone) {
        .neutral => c.CUI_TOKEN_FOREGROUND,
        .success => c.CUI_TOKEN_SUCCESS,
        .info => c.CUI_TOKEN_INFO,
        .warning => c.CUI_TOKEN_WARNING,
        .danger => c.CUI_TOKEN_DANGER,
    };
}
pub fn statusTint(ui: *c.cui_ctx, foreground: c_int) c.cui_color {
    // The stronger dark tint remains subtle; light mode needs less tint to
    // preserve the label's contrast, especially for warning amber.
    return w.tinted(ui, foreground, 0.06 + 0.08 * w.design.blend);
}
fn httpToken(status: u16) c_int {
    const value = w.statusToken(status);
    return if (value == c.CUI_TOKEN_TEXT_SECONDARY) c.CUI_TOKEN_FOREGROUND else value;
}
fn duration(ms: u64) []const u8 {
    var buf: [48]u8 = undefined;
    return w.z(metrics.duration(&buf, ms));
}
fn bytes(n: u64) []const u8 {
    var buf: [48]u8 = undefined;
    return w.z(metrics.bytes(&buf, n));
}
pub fn hasSize(r: *const Response) bool {
    return r.status > 0 or r.total.load(.monotonic) > 0;
}

pub fn summaryData(t: *const tab.Tab) ?Summary {
    if (t.job) |job| {
        const total = job.resp.total.load(.monotonic);
        return .{ .short = "Sending", .full = "Sending", .duration = duration(@intCast(@max(0, job.elapsedMs()))), .size = if (total > 0) bytes(total) else "\u{2014}", .token = c.CUI_TOKEN_INFO };
    }
    if (t.start_failure != .none) return .{ .short = "Not sent", .full = "Not sent", .duration = "\u{2014}", .size = "\u{2014}", .token = token(states.startIssue(t.start_failure).?.tone) };
    const r = if (t.shown) |job| &job.resp else return null;
    const partial = r.status > 0 and r.stop != .complete;
    const label = if (r.status > 0) w.fmt("{d}{s}", .{ r.status, if (partial) " Partial" else "" }) else switch (r.stop) {
        .canceled => "Cancelled",
        .timed_out => "Timed out",
        .complete => "No response",
        else => "Failed",
    };
    const full = if (r.status > 0 and r.reason.len > 0 and r.reason.len <= 80) w.fmt("{d} {s}{s}", .{ r.status, r.reason, if (partial) " \u{b7} partial" else "" }) else label;
    return .{ .short = label, .full = full, .duration = if (r.timing_known) duration(r.time_ms) else "\u{2014}", .size = if (hasSize(r)) bytes(r.total.load(.monotonic)) else "\u{2014}", .token = if (r.status >= 500 and r.status < 600) c.CUI_TOKEN_DANGER else if (partial) c.CUI_TOKEN_WARNING else if (r.status > 0) httpToken(r.status) else if (r.stop == .canceled or r.stop == .complete) c.CUI_TOKEN_FOREGROUND else c.CUI_TOKEN_DANGER };
}

fn textWidth(ui: *c.cui_ctx, label: []const u8, medium: bool) f32 {
    return c.cui_measure_text(ui, if (medium) c.CUI_FONT_MEDIUM else c.CUI_FONT_BODY, 12, label.ptr, @intCast(label.len)).width;
}
fn body(t: *tab.Tab, pane: tab.ResponsePane) void {
    t.response.pane = pane;
    t.response.body_pane = pane;
}
fn previewSupported(r: *const Response) bool {
    const cls = r.class();
    return cls == .image or cls == .html or (cls == .text and @import("response.zig").isMarkdown(r));
}
fn formatLabel(t: *const tab.Tab, r: *const Response) []const u8 {
    if (t.response.pane == .raw) return if (r.class() == .binary or r.class() == .image) "Hex" else "Raw";
    if (r.class() == .json) return switch (t.response.pretty_mode) {
        .tree => "Tree",
        .minified => "Minified",
        .text => "JSON",
    };
    return if (r.class() == .binary or r.class() == .image) "Hex" else if (r.class() == .html) "HTML" else if (r.class() == .xml) "XML" else "Text";
}
fn item(ui: *c.cui_ctx, label: [*:0]const u8, opts: c.cui_menu_item_opts, scrolling: bool) bool {
    return if (scrolling) c.kest_scrolling_menu_item(ui, label, &opts, "response-action-list") else c.cui_menu_item_ex(ui, label, &opts);
}
fn formatItems(ui: *c.cui_ctx, t: *tab.Tab, r: *const Response, scrolling: bool) void {
    if (r.class() == .json) {
        inline for (.{ .{ "Formatted JSON", tab.PrettyMode.text }, .{ "JSON tree", tab.PrettyMode.tree }, .{ "Minified JSON", tab.PrettyMode.minified } }) |choice| {
            if (item(ui, choice[0], .{ .checked = t.response.pane == .pretty and t.response.pretty_mode == choice[1] }, scrolling)) {
                body(t, .pretty);
                t.response.pretty_mode = choice[1];
            }
        }
    } else if (r.class() != .binary and r.class() != .image) {
        if (item(ui, "Text view", .{ .checked = t.response.pane == .pretty }, scrolling)) body(t, .pretty);
    }
    if (item(ui, if (r.class() == .binary or r.class() == .image) "Hex view" else "Raw text", .{ .checked = t.response.pane == .raw }, scrolling)) body(t, .raw);
    if (previewSupported(r) and item(ui, "Preview", .{ .checked = t.response.pane == .preview }, scrolling)) t.response.pane = .preview;
}

pub fn navigation(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    if (t.response.pane == .raw or t.response.pane == .pretty) t.response.body_pane = t.response.pane;
    const r: ?*Response = if (t.shown) |job| &job.resp else null;
    const bounds = c.cui_get_rect(ui, c.cui_make_id(ui, "response-panel"));
    const width = if (bounds.w > 0) bounds.w else 360;
    const preview = r != null and previewSupported(r.?);
    if (t.response.pane == .preview and !preview) t.response.pane = t.response.body_pane;
    const header_label = if (r) |resp| w.fmt("Headers ({d})", .{resp.headers.items.len}) else "Headers";
    const data = summaryData(t);
    const tabs_width = textWidth(ui, "Body", true) + textWidth(ui, header_label, true) + 44 + (if (preview) textWidth(ui, "Preview", true) + 22 else @as(f32, 0));
    var room = @max(0, width - tabs_width - 10 - 28 - 12);
    const status_width = if (data) |value| textWidth(ui, value.short, true) + 20 + (if (t.running()) @as(f32, 20) else 0) else 0;
    room = @max(0, room - status_width);
    const body_view = t.response.pane == .pretty or t.response.pane == .raw;
    const inline_format = r != null and r.?.preview.items.len > 0 and body_view and room >= 100;
    if (inline_format) room -= 100;
    const show_duration = data != null and room >= textWidth(ui, data.?.duration, false) + 12;
    if (show_duration) room -= textWidth(ui, data.?.duration, false) + 12;
    const show_size = data != null and room >= textWidth(ui, data.?.size, false) + 12;
    if (show_size) room -= textWidth(ui, data.?.size, false) + 12;
    const full_status = data != null and textWidth(ui, data.?.full, true) - textWidth(ui, data.?.short, true) <= room;
    w.row(ui, .{ .id = "response-navigation", .height = w.px(w.design.control.tab_height), .width = w.fill, .pad_left = 4, .pad_right = 6, .gap = 2, .@"align" = c.CUI_ALIGN_CENTER });
    const keys = [_][*:0]const u8{ "response-body", "response-headers", "response-preview" };
    const current: usize = if (t.response.pane == .headers) 1 else if (t.response.pane == .preview) 2 else 0;
    const next = w.tabNavigation(ui, keys[0..if (preview) @as(usize, 3) else 2], current);
    if (next != current) t.response.pane = switch (next) {
        1 => .headers,
        2 => .preview,
        else => t.response.body_pane,
    };
    if (w.contentTab(ui, "response-body", "Body", t.response.pane == .pretty or t.response.pane == .raw)) t.response.pane = t.response.body_pane;
    if (w.contentTab(ui, "response-headers", header_label, t.response.pane == .headers)) {
        if (t.response.pane == .pretty or t.response.pane == .raw) t.response.body_pane = t.response.pane;
        t.response.pane = .headers;
    }
    if (preview and w.contentTab(ui, "response-preview", "Preview", t.response.pane == .preview)) t.response.pane = .preview;
    c.cui_spacer(ui);
    if (data) |value| {
        w.row(ui, .{ .id = "response-summary", .gap = 10, .@"align" = c.CUI_ALIGN_CENTER });
        const label = if (full_status) value.full else value.short;
        const badge_width = textWidth(ui, label, true) + 20 + (if (t.running()) @as(f32, 20) else 0);
        w.row(ui, .{ .id = "response-status-frame", .height = w.px(24), .radius = 3, .bg = statusTint(ui, value.token) });
        const clicked = c.kest_control_begin(ui, "response-status", false, badge_width, 24, 3);
        if (t.running()) c.cui_spinner(ui, 12);
        w.text(ui, label, .{ .size = 12, .font = c.CUI_FONT_MEDIUM, .color = w.color(value.token), .nowrap = true });
        c.kest_item_end(ui);
        c.cui_tooltip(ui, if (t.running()) "Current request is running; click for execution details" else if (t.start_failure != .none) "Request was not sent; click for details" else if (r != null and r.?.status > 0) w.z(states.category(r.?.status)) else "Execution outcome; click for details");
        if (clicked) c.cui_popover_open(ui, "response-details");
        w.end(ui);
        if (show_duration) {
            w.row(ui, .{ .id = "response-duration" });
            w.text(ui, value.duration, .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
            c.cui_tooltip(ui, if (t.running()) "Elapsed time for the current request" else "Total request duration, including redirects; a dash means no measurement");
            w.end(ui);
        }
        if (show_size) {
            w.row(ui, .{ .id = "response-size" });
            w.text(ui, value.size, .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .nowrap = true });
            c.cui_tooltip(ui, "Decoded response byte count; body warnings describe preview and storage limits");
            w.end(ui);
        }
        w.end(ui);
    }
    if (inline_format) {
        if (w.menu(ui, w.fmt("{s}###response-format", .{formatLabel(t, r.?)}), 96, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
            formatItems(ui, t, r.?, false);
            c.cui_menu_end(ui);
        }
        c.kest_popup_track(ui, "###response-format");
    }
    var clear = false;
    if (data != null) {
        w.row(ui, .{ .id = "response-actions", .width = w.px(28), .height = w.px(28) });
        if (c.kest_dropdown_begin(ui, "Response actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END, .width = 260 })) {
            c.kest_document_list_begin(ui, "response-action-list", @min(480, c.cui_viewport_size(ui).y - 40));
            if (item(ui, "Execution details", .{}, true)) c.cui_popover_open(ui, "response-details");
            if (r) |resp| if (resp.status > 0 or resp.preview.items.len > 0) {
                if (!inline_format and resp.preview.items.len > 0) {
                    formatItems(ui, t, resp, true);
                    c.cui_menu_separator(ui);
                }
                if (resp.preview.items.len > 0 and resp.class() != .binary and resp.class() != .image) {
                    const text_mode = t.response.pane == .raw or (t.response.pane == .pretty and !(resp.class() == .json and t.response.pretty_mode == .tree)) or (t.response.pane == .preview and (resp.class() == .html or resp.preview.items.len > 256 * 1024));
                    if (text_mode and item(ui, "Wrap lines", .{ .checked = t.response.wrap_response }, true)) t.response.wrap_response = !t.response.wrap_response;
                    if (item(ui, "Find in response", .{ .icon = c.CUI_ICON_SEARCH, .shortcut = "Ctrl F" }, true)) find(t);
                    if (item(ui, if (resp.isPartial()) "Copy raw body prefix" else "Copy raw body", .{}, true)) w.copy(ui, resp.preview.items);
                    // The formatted text is offered only once prepared for the
                    // view being shown, so the copy matches what is on screen.
                    if (resp.class() == .json and t.response.pane == .pretty and t.response.pretty_mode != .tree and t.response.formatted_mode == t.response.pretty_mode) if (t.response.formatted) |formatted| {
                        if (item(ui, if (t.response.pretty_mode == .minified) "Copy minified JSON" else "Copy formatted JSON", .{}, true)) w.copy(ui, formatted);
                    };
                }
                if (resp.headers.items.len > 0 and item(ui, if (@import("../core/header_text.zig").clipboardSafe(resp.raw_headers)) "Copy response headers" else "Copy escaped response headers", .{}, true)) @import("response_headers.zig").copyAll(ui, resp);
                if (item(ui, if (resp.spill_failed) "Save available response..." else "Save response...", .{}, true)) @import("response.zig").save(app, resp);
                if (resp.class() == .json and t.response.pane == .pretty and t.response.pretty_mode == .tree and t.response.tree != null) {
                    if (item(ui, "Expand all", .{}, true)) if (t.response.tree) |*tr| tr.setAll(app.gpa, false) catch {};
                    if (item(ui, "Collapse all", .{}, true)) if (t.response.tree) |*tr| tr.setAll(app.gpa, true) catch {};
                }
            };
            c.cui_menu_separator(ui);
            if (item(ui, if (t.running()) "Clear previous response" else "Clear response", .{}, true)) clear = true;
            c.cui_scroll_end(ui);
            c.cui_menu_end(ui);
        }
        c.kest_popup_track(ui, "Response actions");
        w.end(ui);
    }
    w.end(ui);
    if (clear) commands.clearResponse(t);
    details(ui, t);
}

fn field(ui: *c.cui_ctx, name: []const u8, value: []const u8) void {
    w.column(ui, .{ .width = w.fill, .gap = 2, .pad_bottom = 6 });
    w.text(ui, name, .{ .size = 12, .font = c.CUI_FONT_MEDIUM });
    w.text(ui, value, .{ .width = w.fill, .size = 12, .font = c.CUI_FONT_MONO, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
}
fn details(ui: *c.cui_ctx, t: *tab.Tab) void {
    if (t.shown == null and t.job == null and t.start_failure == .none) {
        c.cui_popover_close(ui, "response-details");
        return;
    }
    if (!c.kest_inspector_begin(ui, "response-details", "response-status", 520)) return;
    w.text(ui, if (t.running()) "Current request details" else "Execution details", .{ .size = 13, .font = c.CUI_FONT_MEDIUM });
    c.kest_document_list_begin(ui, "response-detail-content", @min(260, c.cui_viewport_size(ui).y - 152));
    if (t.job) |job| {
        field(ui, "State", "Sending; prior response content is separate");
        field(ui, "Elapsed", duration(@intCast(@max(0, job.elapsedMs()))));
        field(ui, "Received so far", bytes(job.resp.total.load(.monotonic)));
        field(ui, "Request URL", job.out.url);
    } else if (t.start_failure != .none) {
        field(ui, "State", "Not sent");
        field(ui, "Details", t.start_failure_text);
    } else if (t.shown) |job| {
        const r = &job.resp;
        field(ui, "HTTP outcome", states.category(r.status));
        if (r.status > 0) field(ui, "Status", w.fmt("{d} {s}", .{ r.status, r.reason }));
        if (states.issue(r)) |issue| {
            field(ui, "Transfer", issue.title);
            field(ui, "Explanation", issue.hint);
        } else field(ui, "Transfer", "Complete");
        field(ui, "Duration", if (r.timing_known) w.fmt("{s} ({d} ms)", .{ duration(r.time_ms), r.time_ms }) else "Not measured");
        field(ui, "Decoded body received", if (hasSize(r)) w.fmt("{s} ({d} bytes)", .{ bytes(r.total.load(.monotonic)), r.total.load(.monotonic) }) else "Unknown; no HTTP response");
        field(ui, "Headers", w.fmt("{d}", .{r.headers.items.len}));
        if (r.content_type.len > 0) field(ui, "Content-Type", r.content_type);
        if (r.url.len > 0) field(ui, "Response URL", r.url);
        field(ui, "Redirects followed", w.fmt("{d}", .{r.redirects}));
        if (r.status > 0) field(ui, "Connection", if (r.reused_connection) "Reused" else "New");
        if (r.isPartial()) field(ui, "Preview", w.fmt("{d} of {d} received bytes shown; {s}", .{ r.preview.items.len, r.total.load(.monotonic), if (r.spill_path != null and !r.spill_failed) "save keeps the full received body" else "only available data can be saved" }));
    }
    c.cui_scroll_end(ui);
    _ = w.menuItem(ui, "Close");
    c.cui_menu_end(ui);
}

pub fn find(t: *tab.Tab) void {
    @import("response_search.zig").open(t);
}
