const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const response = @import("../core/response.zig");
const json = @import("../utils/json.zig");
const editor = @import("editor.zig");
const platform = @import("platform.zig");

pub fn view(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    w.column(ui, .{ .id = "response-panel", .width = w.fill, .height = w.fill, .clip = true });
    defer w.end(ui);
    @import("response_chrome.zig").navigation(ui, app, t);
    c.cui_separator(ui);
    const job = t.shown orelse {
        empty(ui, t.running());
        return;
    };
    const resp = &job.resp;
    w.column(ui, .{ .id = "response-content", .width = w.fill, .height = w.fill, .clip = true });
    if (resp.error_text.len > 0 or resp.stop != .complete or resp.spill_path != null) {
        w.column(ui, .{ .pad_x = 12, .pad_y = 6, .gap = 4 });
        if (resp.error_text.len > 0) w.text(ui, resp.error_text, .{ .size = 12, .color = w.color(c.CUI_TOKEN_DANGER) });
        if (resp.stop != .complete) w.text(ui, w.fmt("Incomplete response: {s}", .{@tagName(resp.stop)}), .{ .size = 12, .color = w.color(c.CUI_TOKEN_WARNING) });
        if (resp.spill_path != null) w.muted(ui, "Showing the first 8 MiB. Save response keeps the entire body.");
        w.end(ui);
    }
    content(ui, app, t, resp);
    w.end(ui);
    @import("response_chrome.zig").footer(ui, app, t, resp);
}

fn content(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response) void {
    const cls = resp.class();
    switch (t.response.pane) {
        .headers => @import("response_headers.zig").view(ui, resp),
        .raw => if (cls == .binary or cls == .image) hex(ui, resp) else {
            _ = editor.view(ui, "raw-view", &t.response.code_raw, resp.preview.items, true, .plain);
        },
        .pretty => {
            if (cls == .binary or cls == .image) {
                hex(ui, resp);
                return;
            }
            if (cls == .json) {
                if (t.response.pretty_mode == .tree) {
                    tree(ui, app, t, resp);
                    return;
                }
                if (!t.response.format_attempted or t.response.formatted_mode != t.response.pretty_mode) {
                    if (t.response.formatted) |old| app.gpa.free(old);
                    const formatted = json.format(app.gpa, resp.preview.items, if (t.response.pretty_mode == .minified) 0 else 2) catch null;
                    t.response.formatted = if (formatted) |result| switch (result) {
                        .ok => |bytes| bytes,
                        .problem => null,
                    } else null;
                    t.response.formatted_mode = t.response.pretty_mode;
                    t.response.format_attempted = true;
                    t.response.code_pretty.version += 1;
                }
            }
            _ = editor.view(ui, "pretty-view", &t.response.code_pretty, t.response.formatted orelse resp.preview.items, true, if (cls == .json) .json else if (cls == .xml or cls == .html) .xml else .plain);
        },
        .preview => preview(ui, app, t, resp),
    }
}

fn empty(ui: *c.cui_ctx, running: bool) void {
    c.cui_spacer(ui);
    w.column(ui, .{ .gap = 8, .@"align" = c.CUI_ALIGN_CENTER, .pad_x = 20 });
    if (c.cui_viewport_size(ui).y >= 600) c.cui_icon(ui, c.CUI_ICON_ARROW_RIGHT, 24, w.color(c.CUI_TOKEN_TEXT_MUTED));
    w.text(ui, if (running) "Sending request..." else "No response yet", .{ .size = 13, .font = c.CUI_FONT_MEDIUM, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY), .@"align" = c.CUI_TEXT_CENTER });
    if (c.cui_viewport_size(ui).y >= 600) w.text(ui, if (running) "You can keep working while the request runs." else "Send your request to see the response here.", .{ .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_MUTED), .@"align" = c.CUI_TEXT_CENTER });
    w.end(ui);
    c.cui_spacer(ui);
}

fn hex(ui: *c.cui_ctx, resp: *response.Response) void {
    _ = c.cui_hex_view_ex(ui, "binary", resp.preview.items.ptr, resp.preview.items.len, null, &.{ .height = -1 });
}

fn tree(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response) void {
    const v = &t.response;
    if (v.tree == null and !v.tree_failed) v.tree = @import("../core/json_tree.zig").Tree.build(app.gpa, resp.preview.items, 1_000_000) catch blk: {
        v.tree_failed = true;
        break :blk null;
    };
    const tr = if (v.tree) |*value| value else {
        _ = editor.view(ui, "tree-fallback", &v.code_pretty, resp.preview.items, true, .json);
        return;
    };
    var first: c_int = 0;
    var last: c_int = 0;
    c.cui_virtual_list_begin(ui, "json-rows", @intCast(tr.rows.items.len), 26, w.fill, &first, &last);
    var toggle: ?u32 = null;
    for (@as(usize, @intCast(first))..@as(usize, @intCast(last))) |i| {
        const index = tr.rows.items[i];
        const n = tr.nodes.items[index];
        c.cui_push_id_int(ui, @intCast(index));
        w.row(ui, .{ .height = w.px(26), .pad_left = 16 + @as(f32, @floatFromInt(@min(n.depth, 24))) * 16, .gap = 6 });
        if (tr.isContainer(index)) {
            if (w.icon(ui, if (tr.isCollapsed(index)) c.CUI_ICON_CHEVRON_RIGHT else c.CUI_ICON_CHEVRON_DOWN, "Expand or collapse")) toggle = index;
        } else {
            w.column(ui, .{ .width = w.px(28) });
            w.end(ui);
        }
        const key = tr.key(index);
        const val = tr.value(index);
        if (key.len > 0) w.text(ui, w.fmt("{s}:", .{key}), .{ .font = c.CUI_FONT_MONO, .size = 12, .nowrap = true, .color = @import("design.zig").syntax(ui, .key) });
        w.text(ui, val[0..@min(1000, val.len)], .{ .font = c.CUI_FONT_MONO, .size = 12, .nowrap = true, .width = w.fill, .color = if (n.kind == .string) @import("design.zig").syntax(ui, .string) else if (n.kind == .number) @import("design.zig").syntax(ui, .number) else w.color(c.CUI_TOKEN_FOREGROUND) });
        if (c.cui_context_menu_begin(ui, "json-menu")) {
            if (w.menuItem(ui, "Copy value")) w.copy(ui, tr.sourceOf(index));
            if (w.menuItem(ui, "Copy key")) w.copy(ui, key);
            c.cui_context_menu_end(ui);
        }
        w.end(ui);
        c.cui_pop_id(ui);
    }
    c.cui_virtual_list_end(ui);
    if (toggle) |index| tr.toggle(app.gpa, index) catch {};
}

fn preview(ui: *c.cui_ctx, app: *App, t: *tab.Tab, resp: *response.Response) void {
    if (isMarkdown(resp)) {
        if (resp.preview.items.len == 0) {
            w.empty(ui, "Empty Markdown response", "The response body has no content.");
            return;
        }
        // Markdown lays out the entire document. Keep large responses on the
        // virtualized text path rather than parsing megabytes on every frame.
        if (resp.preview.items.len <= 256 * 1024) {
            c.cui_scroll_begin(ui, &.{ .id = "markdown-preview", .height = w.fill, .width = w.fill, .pad = 16 });
            const result = c.cui_markdown_ex(ui, "response-markdown", resp.preview.items.ptr, &.{ .length = @intCast(resp.preview.items.len), .size = 13 });
            if (result.link) |link| {
                const url = std.mem.span(link);
                if (std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://")) {
                    if (!platform.headless) _ = c.cui_app_open_url(link);
                } else app.toast(.info, "Link", "Only HTTP and HTTPS links can be opened from response previews.");
            }
            c.cui_scroll_end(ui);
            return;
        }
        w.muted(ui, "Large Markdown response shown as text (preview limit: 256 KiB).");
    }
    switch (resp.class()) {
        .html => {
            if (t.response.stripped == null) t.response.stripped = strip(app.gpa, resp.preview.items) catch null;
            _ = editor.view(ui, "html-preview", &t.response.code_pretty, t.response.stripped orelse "", true, .plain);
        },
        .image => {
            // Decode only on demand, with CUI's own PNG/JPEG support.
            if (!t.response.image_attempted) {
                t.response.image = c.retort_image_memory(ui, resp.preview.items.ptr, @intCast(resp.preview.items.len), &t.response.image_width, &t.response.image_height);
                t.response.image_attempted = true;
            }
            if (t.response.image != 0) {
                const paint = ImagePaint{ .texture = t.response.image, .width = @floatFromInt(t.response.image_width), .height = @floatFromInt(t.response.image_height) };
                _ = c.cui_canvas(ui, "image-preview", w.fill, w.fill, paintImage, &paint, @sizeOf(ImagePaint));
            } else w.empty(ui, "Image cannot be previewed", "Save the body to open it in an image viewer.");
        },
        .binary => hex(ui, resp),
        else => _ = editor.view(ui, "text-preview", &t.response.code_pretty, resp.preview.items, true, .plain),
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
fn strip(a: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
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
pub fn save(app: *App, resp: *response.Response) void {
    const path = (platform.dialog.save(app.gpa, .{ .title = "Save response", .name = "response.bin" }) catch null) orelse return;
    defer app.gpa.free(path);
    const job: *@import("../network/http_client.zig").Job = @fieldParentPtr("resp", resp);
    @import("../app/export_jobs.zig").response(app.store, path, job) catch |e| {
        app.toast(.danger, "Could not save", @errorName(e));
        return;
    };
    app.toast(.info, "Save queued", std.fs.path.basename(path));
}

pub fn isMarkdown(resp: *const response.Response) bool {
    const end = std.mem.indexOfScalar(u8, resp.content_type, ';') orelse resp.content_type.len;
    const mime = std.mem.trim(u8, resp.content_type[0..end], " \t");
    return std.ascii.eqlIgnoreCase(mime, "text/markdown") or std.ascii.eqlIgnoreCase(mime, "text/x-markdown");
}
