const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const response = @import("../core/response.zig");
const preparation = @import("response_preparation.zig");
const prep = @import("../app/response_prepare.zig");
const text_view = @import("response_text.zig");
const platform = @import("platform.zig");

pub fn view(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    text_view.beginFrame(&t.response);
    defer text_view.endFrame(&t.response);
    w.column(ui, .{ .id = "response-panel", .width = w.fill, .height = w.fill, .clip = true });
    defer w.end(ui);
    @import("response_chrome.zig").navigation(ui, app, t);
    w.separator(ui, "response-navigation-boundary");
    const states = @import("../core/response_status.zig");
    if (states.startIssue(t.start_failure)) |issue| @import("response_notice.zig").view(ui, t, issue, t.start_failure_text, t.shown == null);
    const job = t.shown orelse {
        if (t.start_failure == .none) empty(ui, t.running());
        return;
    };
    const resp = &job.resp;
    preparation.cancelUnless(&t.response, wanted(t, resp));
    if (t.response.pane == .headers or resp.class() == .binary or resp.class() == .image) preparation.cancelRaw(&t.response);
    w.column(ui, .{ .id = "response-content", .width = w.fill, .height = w.fill, .clip = true });
    if (t.running() or t.start_failure != .none) {
        w.column(ui, .{ .id = "response-previous", .width = w.fill, .pad_x = 12, .pad_y = 6, .bg = w.color(c.CUI_TOKEN_SURFACE_MUTED) });
        w.text(ui, if (t.running()) "Previous response" else "Previous response · new request not sent", .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        w.end(ui);
    } else if (states.issue(resp)) |issue| @import("response_notice.zig").view(ui, t, issue, resp.error_text, resp.status == 0 and resp.preview.items.len == 0);
    if (resp.isPartial()) {
        w.column(ui, .{ .id = "response-preview-notice", .width = w.fill, .pad_x = 12, .pad_y = 4 });
        w.text(ui, w.fmt("Showing {d} of {d} received bytes", .{ resp.preview.items.len, resp.total.load(.monotonic) }), .{ .width = w.fill, .size = c.KEST_TEXT_CAPTION, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        w.end(ui);
    }
    // A failed request has no body: the alert is the whole answer.
    if (resp.status == 0 and resp.preview.items.len == 0) {
        w.end(ui);
        return;
    }
    if (resp.status > 0 and resp.preview.items.len == 0 and resp.stop == .complete and t.response.pane != .headers) {
        w.empty(ui, "Empty response body");
        w.end(ui);
        return;
    }
    content(ui, app, t, resp);
    w.end(ui);
}

fn content(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response) void {
    const cls = resp.class();
    const info = resp.info();
    if (t.response.pane != .headers) {
        if (info.json_problem) |problem| {
            contentNotice(ui, w.fmt("Invalid JSON at line {d}, column {d}: {s}. Showing original text.", .{ problem.line, problem.column, problem.message }));
        } else if (info.json_incomplete) {
            contentNotice(ui, "JSON formatting is unavailable for an incomplete body. Showing original text.");
        } else if (info.json_limited) contentNotice(ui, "JSON nesting exceeds the inspection limit (4096 levels). Showing original text.");
    }
    switch (t.response.pane) {
        .headers => @import("response_headers.zig").view(ui, t, resp),
        .raw => if (cls == .binary or cls == .image) hex(ui, resp) else {
            original(ui, app, t, resp, "raw-view", true, .plain);
        },
        .pretty => {
            if (cls == .binary or cls == .image) {
                hex(ui, resp);
                return;
            }
            if (cls == .json) {
                if (t.response.pretty_mode == .tree and !t.response.tree_failed) {
                    const status = preparation.ensure(ui, app, t, .tree);
                    if (status == .ready) {
                        preparation.cancelRaw(&t.response);
                        @import("json_view.zig").view(ui, app, t, &t.response.tree.?);
                        return;
                    }
                    // Too many nodes to fold: formatted text from now on.
                    if (status == .failed and t.response.preparation_failure == .node_limit) {
                        t.response.tree_failed = true;
                    } else {
                        contentNotice(ui, preparation.message(&t.response));
                        original(ui, app, t, resp, "tree-fallback", false, .plain);
                        return;
                    }
                }
                if (t.response.tree_failed and t.response.pretty_mode == .tree) contentNotice(ui, "JSON has more than 200,000 values, too many to fold. Showing formatted text.");
                const status = preparation.ensure(ui, app, t, if (t.response.pretty_mode == .minified) .minified else .pretty);
                if (status != .ready) {
                    contentNotice(ui, preparation.message(&t.response));
                    original(ui, app, t, resp, "pretty-view", false, .plain);
                    return;
                }
                preparation.cancelRaw(&t.response);
                text_view.view(ui, app, t, "pretty-view", &t.response.code_pretty, t.response.formatted.?, t.response.formatted_owner, .json);
                return;
            }
            original(ui, app, t, resp, "pretty-view", false, if (cls == .xml or cls == .html) .xml else .plain);
        },
        .preview => preview(ui, app, t, resp),
    }
}

fn contentNotice(ui: *c.cui_ctx, text: []const u8) void {
    w.column(ui, .{ .id = "response-content-notice", .width = w.fill, .pad_x = 12, .pad_y = 6 });
    w.text(ui, text, .{ .width = w.fill, .size = c.KEST_TEXT_SECONDARY, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    w.end(ui);
}

fn original(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response, id: [*:0]const u8, raw: bool, lang: @import("../utils/highlight.zig").Lang) void {
    const source = resp.preview.items;
    const state = if (raw) &t.response.code_raw else &t.response.code_pretty;
    if (source.len <= prep.inline_limit) {
        text_view.view(ui, app, t, id, state, source, null, lang);
        return;
    }
    const status = preparation.ensureRaw(app, t);
    var length = source.len;
    if (status != .ready) {
        length = @min(source.len, prep.inline_limit);
        while (length > 0 and length < source.len and source[length] & 0xc0 == 0x80) length -= 1;
        w.column(ui, .{ .id = "response-index-notice", .width = w.fill, .pad_x = 12, .pad_y = 4 });
        const reason = if (status == .waiting) "Preparing text index." else switch (t.response.raw_index_failure orelse .unavailable) {
            .index_limit => "Text exceeds the 1,000,000-row viewing limit.",
            .input_limit => "Text exceeds the 8 MiB indexing limit.",
            else => "Text index could not be prepared.",
        };
        w.text(ui, w.fmt("{s} Viewing {d} of {d} bytes.", .{ reason, length, source.len }), .{ .width = w.fill, .size = c.KEST_TEXT_CAPTION, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        w.end(ui);
        text_view.pendingView(ui, app, t, id, state, source, lang);
        return;
    }
    text_view.view(ui, app, t, id, state, source[0..length], null, lang);
}

fn empty(ui: *c.cui_ctx, running: bool) void {
    c.cui_spacer(ui);
    w.column(ui, .{ .width = w.fill, .gap = 10, .@"align" = c.CUI_ALIGN_CENTER, .pad_x = 20 });
    if (running) {
        c.cui_spinner(ui, 14);
        w.text(ui, "Sending request...", .{ .size = c.KEST_TEXT_BODY, .nowrap = true, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    }
    w.end(ui);
    c.cui_spacer(ui);
}

fn hex(ui: *c.cui_ctx, resp: *response.Response) void {
    _ = c.cui_hex_view_ex(ui, "binary", resp.preview.items.ptr, resp.preview.items.len, null, &.{ .height = -1 });
}

fn preview(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response) void {
    if (resp.class() == .text and isMarkdown(resp)) {
        if (resp.preview.items.len == 0) {
            w.empty(ui, "Empty response body");
            return;
        }
        // Markdown lays out the entire document. Keep large responses on the
        // virtualized text path rather than parsing megabytes on every frame.
        if (resp.preview.items.len <= 256 * 1024) {
            c.cui_scroll_begin(ui, &.{ .id = "markdown-preview", .height = w.fill, .width = w.fill, .pad = 16 });
            const result = c.cui_markdown_ex(ui, "response-markdown", resp.preview.items.ptr, &.{ .length = @intCast(resp.preview.items.len), .size = c.KEST_TEXT_BODY });
            if (result.link) |link| {
                const url = std.mem.span(link);
                if (std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://")) {
                    if (!platform.headless) _ = c.cui_app_open_url(link);
                } else app.toast(.info, "Link", "Only HTTP and HTTPS links can be opened from response previews.");
            }
            c.cui_scroll_end(ui);
            return;
        }
    }
    switch (resp.class()) {
        .html => {
            const status = preparation.ensure(ui, app, t, .html);
            if (status != .ready) {
                contentNotice(ui, preparation.message(&t.response));
                original(ui, app, t, resp, "html-preview", false, .plain);
            } else {
                preparation.cancelRaw(&t.response);
                text_view.view(ui, app, t, "html-preview", &t.response.code_pretty, t.response.stripped.?, t.response.stripped_owner, .plain);
            }
        },
        .image => {
            const status = preparation.ensure(ui, app, t, .image);
            if (status == .waiting) {
                contentNotice(ui, preparation.message(&t.response));
                hex(ui, resp);
                return;
            }
            if (t.response.image != 0) {
                if (t.response.image_source_width != @as(u32, @intCast(t.response.image_width)) or t.response.image_source_height != @as(u32, @intCast(t.response.image_height)))
                    contentNotice(ui, w.fmt("Scaled from {d} x {d} to {d} x {d}", .{ t.response.image_source_width, t.response.image_source_height, t.response.image_width, t.response.image_height }));
                const paint = ImagePaint{ .texture = t.response.image, .width = @floatFromInt(t.response.image_width), .height = @floatFromInt(t.response.image_height) };
                _ = c.cui_canvas(ui, "image-preview", w.fill, w.fill, paintImage, &paint, @sizeOf(ImagePaint));
            } else w.empty(ui, "Image cannot be previewed");
        },
        .binary => hex(ui, resp),
        else => original(ui, app, t, resp, "text-preview", false, .plain),
    }
}
const ImagePaint = struct { texture: usize, width: f32, height: f32 };
fn paintImage(ui: ?*c.cui_ctx, rect: c.cui_rect, raw: ?*anyopaque) callconv(.c) void {
    const image: *const ImagePaint = @ptrCast(@alignCast(raw.?));
    const scale = @min(1, @min(rect.w / image.width, rect.h / image.height));
    const width = image.width * scale;
    const height = image.height * scale;
    c.cui_draw_image(ui, image.texture, .{ .x = rect.x + (rect.w - width) / 2, .y = rect.y + (rect.h - height) / 2, .w = width, .h = height }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{}, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}
pub fn wanted(t: *const tab.Tab, resp: *const response.Response) ?prep.Kind {
    const cls = resp.class();
    if (t.response.pane == .raw and cls != .binary and cls != .image and resp.preview.items.len > prep.inline_limit) return .raw;
    if (t.response.pane == .pretty and resp.class() == .json) return switch (t.response.pretty_mode) {
        .tree => if (t.response.tree_failed) .pretty else .tree,
        .text => .pretty,
        .minified => .minified,
    };
    if (t.response.pane == .preview) return switch (resp.class()) {
        .html => .html,
        .image => .image,
        .text => if (isMarkdown(resp) and resp.preview.items.len <= 256 * 1024) null else if (resp.preview.items.len > prep.inline_limit) .raw else null,
        else => null,
    };
    if (t.response.pane == .pretty and cls != .binary and cls != .image and resp.preview.items.len > prep.inline_limit) return .raw;
    return null;
}
pub fn save(app: *App, resp: *response.Response) void {
    // Suggest an extension matching the received content; bytes are unchanged.
    const name = switch (resp.class()) {
        .json => "response.json",
        .xml => "response.xml",
        .html => "response.html",
        .text => if (isMarkdown(resp)) "response.md" else "response.txt",
        else => "response.bin",
    };
    const path = (platform.dialog.save(app.gpa, .{ .title = "Save response", .name = name }) catch null) orelse return;
    defer app.gpa.free(path);
    const job: *@import("../network/http_client.zig").Job = @fieldParentPtr("resp", resp);
    @import("../app/export_jobs.zig").response(app.store, path, job) catch |e| {
        app.toast(.danger, "Could not save", @errorName(e));
        return;
    };
    app.toastAction(.info, "Save queued", std.fs.path.basename(path), .{ .show = path });
}

pub fn isMarkdown(resp: *const response.Response) bool {
    const end = std.mem.indexOfScalar(u8, resp.content_type, ';') orelse resp.content_type.len;
    const mime = std.mem.trim(u8, resp.content_type[0..end], " \t");
    return std.ascii.eqlIgnoreCase(mime, "text/markdown") or std.ascii.eqlIgnoreCase(mime, "text/x-markdown");
}
