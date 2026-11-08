//! UI ownership transfer for background results. Texture creation is UI-only;
//! CPU decode, derived text, indexes and JSON continuation scans are worker-only.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const prep = @import("../app/response_prepare.zig");
pub const Status = enum { ready, waiting, failed };

fn cached(v: *const tab.ResponseView, kind: prep.Kind) bool {
    const mode: tab.PrettyMode = if (kind == .minified) .minified else .text;
    return switch (kind) {
        .tree => v.tree != null,
        .html => v.stripped != null,
        .image => v.image != 0,
        .pretty, .minified => v.formatted != null and v.formatted_mode == mode,
        .raw => v.raw_index_ready,
    };
}

pub fn settled(v: *const tab.ResponseView, wanted: ?prep.Kind) bool {
    if (v.code_raw.layout_pending or v.code_pretty.layout_pending) return false;
    if (v.code_raw.search_pending or v.code_pretty.search_pending) return false;
    if (v.raw_index_requested and !v.raw_index_ready and v.raw_index_failure == null) return false;
    const kind = wanted orelse return true;
    if (kind == .raw) return v.raw_index_ready or v.raw_index_failure != null;
    return cached(v, kind) or (v.preparation_kind == kind and v.preparation_failure != null);
}

pub fn cancelUnless(v: *tab.ResponseView, wanted: ?prep.Kind) void {
    if (v.preparation) |job| if (wanted == null or job.kind != wanted.?) {
        job.abandon();
        v.preparation = null;
    };
}

pub fn ensure(ui: *c.cui_ctx, app: *App, t: *tab.Tab, kind: prep.Kind) Status {
    const v = &t.response;
    cancelUnless(v, kind);
    const mode: tab.PrettyMode = if (kind == .minified) .minified else .text;
    if (cached(v, kind)) return .ready;
    if (v.preparation) |job| {
        // A decoded image becomes a texture of the renderer in use; while
        // startup still paints in software, keep it until OpenGL takes over.
        if (kind == .image and !@import("platform.zig").renderer_final) return .waiting;
        var result = job.take() orelse return .waiting;
        defer result.deinit(app.gpa);
        job.release();
        v.preparation = null;
        switch (result) {
            .text => |text| {
                adopt(&v.code_pretty, text);
                if (kind == .html) {
                    if (v.stripped_owner) |owner| owner.release() else if (v.stripped) |old| app.gpa.free(old);
                    v.stripped_owner = text.owner;
                    v.stripped = text.bytes;
                } else {
                    if (v.formatted_owner) |owner| owner.release() else if (v.formatted) |old| app.gpa.free(old);
                    v.formatted_owner = text.owner;
                    v.formatted = text.bytes;
                    v.formatted_mode = mode;
                    v.format_attempted = true;
                }
                result = .none;
            },
            .tree => |tree| {
                v.tree = tree;
                result = .none;
            },
            .pixels => |pixels| {
                v.image = c.cui_image_create(ui, @intCast(pixels.width), @intCast(pixels.height), pixels.rgba);
                v.image_width = @intCast(pixels.width);
                v.image_height = @intCast(pixels.height);
                v.image_source_width = pixels.source_width;
                v.image_source_height = pixels.source_height;
                v.image_attempted = true;
                if (v.image == 0) v.preparation_failure = .unavailable;
            },
            .failure => |failure| v.preparation_failure = failure,
            .none, .layout, .search => v.preparation_failure = .unavailable,
        }
        return if (v.preparation_failure == null) .ready else .failed;
    }
    if (v.preparation_kind == kind and v.preparation_failure != null) return .failed;
    v.preparation_kind = kind;
    v.preparation_failure = null;
    v.preparation = app.response_preparation.start(t.shown.?, kind, .{ .decode = decode }, .{ .ctx = app, .call = wake }) catch |err| {
        if (err == error.Busy) return .waiting;
        v.preparation_failure = if (err == error.InputLimit) .input_limit else if (err == error.Incomplete) .incomplete else .unavailable;
        return .failed;
    };
    return .waiting;
}

pub fn cancelRaw(v: *tab.ResponseView) void {
    if (v.raw_index_job) |job| job.abandon();
    v.raw_index_job = null;
    v.raw_index_requested = false;
}

/// Indexes borrowed source bytes. Owns only the derived index; the immutable
/// HTTP source stays pinned by the job until it transfers to its shown owner.
pub fn ensureRaw(app: *App, t: *tab.Tab) Status {
    const v = &t.response;
    v.raw_index_requested = true;
    if (v.raw_index_ready) return .ready;
    if (v.raw_index_failure != null) return .failed;
    if (v.raw_index_job) |job| {
        var result = job.take() orelse return .waiting;
        defer result.deinit(app.gpa);
        job.release();
        v.raw_index_job = null;
        switch (result) {
            .text => |text| {
                adopt(&v.code_raw, text);
                v.raw_index_ready = true;
                result = .none;
            },
            .failure => |failure| v.raw_index_failure = failure,
            else => v.raw_index_failure = .unavailable,
        }
        return if (v.raw_index_ready) .ready else .failed;
    }
    v.raw_index_job = app.response_preparation.start(t.shown.?, .raw, null, .{ .ctx = app, .call = wake }) catch |err| {
        if (err == error.Busy) return .waiting;
        v.raw_index_failure = if (err == error.InputLimit) .input_limit else .unavailable;
        return .failed;
    };
    return .waiting;
}

fn adopt(state: *@import("code_state.zig").State, text: prep.Text) void {
    state.clearLayout();
    state.index.deinit(state.gpa);
    state.continued_strings.deinit(state.gpa);
    state.index = text.index;
    state.continued_strings = text.strings;
    state.version +%= 1;
    state.indexed_version = state.version;
    state.indexed_ptr = @intFromPtr(text.bytes.ptr);
    state.indexed_len = text.bytes.len;
    state.index_generation +%= 1;
    state.syntax_generation = if (text.json_syntax) state.index_generation else 0;
    state.caret = @min(state.caret, text.bytes.len);
    state.anchor = @min(state.anchor, text.bytes.len);
    state.marked = null;
    state.marked_version = 0;
    state.reveal = true;
}

fn wake(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.wake();
}
fn decode(_: ?*anyopaque, source: []const u8) prep.Decoded {
    var width: c_int = 0;
    var height: c_int = 0;
    var source_width: c_int = 0;
    var source_height: c_int = 0;
    var failure: c_int = 0;
    const rgba = c.kest_image_decode(source.ptr, @intCast(source.len), &width, &height, &source_width, &source_height, &failure) orelse return .{ .failure = if (failure == 2) .image_limit else if (failure == 3) .unavailable else .invalid };
    return .{ .pixels = .{ .rgba = rgba, .width = @intCast(width), .height = @intCast(height), .source_width = @intCast(source_width), .source_height = @intCast(source_height), .free = freePixels } };
}
fn freePixels(rgba: [*]u8) void {
    c.kest_image_free(rgba);
}

pub fn message(v: *const tab.ResponseView) []const u8 {
    return switch (v.preparation_failure orelse return "Preparing response view in the background. Original data remains available.") {
        .input_limit => "Response exceeds the 8 MiB preparation limit. Showing original data.",
        .output_limit => "Formatted JSON exceeds the 16 MiB output limit. Showing original text.",
        .node_limit => "JSON exceeds the 200,000-node tree limit. Showing original text.",
        .index_limit => "Response exceeds the 1,000,000-row viewing limit. Showing an original-text prefix.",
        .image_limit => "Image exceeds preview limits. Save the body to inspect the original image.",
        .incomplete => "A complete image is needed for preview. Save the available data to inspect it.",
        .invalid => "This response view could not be prepared. Original data remains available.",
        .unavailable => "Response view could not be prepared with available resources. Original data remains available.",
        .canceled => "Response view preparation was cancelled. Original data remains available.",
    };
}
