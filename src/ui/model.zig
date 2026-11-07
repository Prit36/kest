//! UI-independent editable buffers used by the existing application model.
const std = @import("std");
const c = @import("c.zig").c;
// Fields are often only a few bytes. Sharing heap pages avoids a virtual
// allocation and a committed OS page for every method, key and value.
const a = std.heap.c_allocator;
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const TextBuffer = struct {
    data: []u8 = &.{},
    len: usize = 0,
    want_focus: bool = false,
    want_caret: ?usize = null,
    pub fn deinit(b: *TextBuffer) void {
        a.free(b.data);
        b.* = .{};
    }
    pub fn text(b: *const TextBuffer) []const u8 {
        return b.data[0..b.len];
    }
    pub fn reserve(b: *TextBuffer, n: usize) bool {
        if (n > 32 * 1024 * 1024) return false;
        if (b.data.len >= n + 1) return true;
        b.data = a.realloc(b.data, @max(n + 1, @min(32 * 1024 * 1024 + 1, @max(256, b.data.len * 2)))) catch return false;
        b.data[b.len] = 0;
        return true;
    }
    pub fn set(b: *TextBuffer, value: []const u8) void {
        if (!b.reserve(value.len)) return;
        @memcpy(b.data[0..value.len], value);
        b.len = value.len;
        b.data[b.len] = 0;
    }
    pub fn clear(b: *TextBuffer) void {
        b.set("");
    }
    pub fn focus(b: *TextBuffer) void {
        b.want_focus = true;
    }
    pub fn replace(b: *TextBuffer, lo: usize, hi: usize, value: []const u8) usize {
        const next = b.len - (hi - lo) + value.len;
        if (!b.reserve(next)) return 0;
        const tail = b.len - hi;
        if (lo + value.len > hi) std.mem.copyBackwards(u8, b.data[lo + value.len ..][0..tail], b.data[hi..][0..tail]) else std.mem.copyForwards(u8, b.data[lo + value.len ..][0..tail], b.data[hi..][0..tail]);
        @memcpy(b.data[lo..][0..value.len], value);
        b.len = next;
        b.data[next] = 0;
        return value.len;
    }
};
pub const Command = enum {
    move_left,
    move_right,
    select_left,
    select_right,
    move_word_left,
    move_word_right,
    select_word_left,
    select_word_right,
    move_line_start,
    move_line_end,
    select_line_start,
    select_line_end,
    select_all,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    delete_to_line_start,
    delete_to_line_end,
    insert_newline,
    insert_line_break,
    insert_tab,
};
pub const Status = enum { success, warning, danger, info };
pub const Toast = struct { status: Status, title: []const u8, message: []const u8, duration: u32 };
pub const Toaster = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Toast) = .empty,
    pub fn push(s: *Toaster, msg: Toast) void {
        if (s.items.items.len >= 8) return;
        var m = msg;
        m.title = s.gpa.dupe(u8, msg.title[0..@min(msg.title.len, 128)]) catch return;
        m.message = s.gpa.dupe(u8, msg.message[0..@min(msg.message.len, 1024)]) catch {
            s.gpa.free(m.title);
            return;
        };
        s.items.append(s.gpa, m) catch {
            s.gpa.free(m.title);
            s.gpa.free(m.message);
        };
    }
    pub fn deinit(s: *Toaster) void {
        s.clear();
        s.items.deinit(s.gpa);
    }
    fn clear(s: *Toaster) void {
        for (s.items.items) |m| {
            s.gpa.free(m.title);
            s.gpa.free(m.message);
        }
        s.items.clearRetainingCapacity();
    }
    pub fn view(s: *Toaster, ui: *c.cui_ctx) void {
        for (s.items.items) |m| {
            const title = s.gpa.dupeSentinel(u8, m.title, 0) catch continue;
            defer s.gpa.free(title);
            const message = s.gpa.dupeSentinel(u8, m.message, 0) catch continue;
            defer s.gpa.free(message);
            _ = c.cui_toast_ex(ui, title, &.{ .description = message, .duration = @floatFromInt(m.duration), .tone = switch (m.status) {
                .success => c.CUI_TONE_SUCCESS,
                .warning => c.CUI_TONE_WARNING,
                .danger => c.CUI_TONE_DANGER,
                .info => c.CUI_TONE_INFO,
            } });
        }
        s.clear();
    }
};
