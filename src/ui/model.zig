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
/// What a toast's button does; the shell carries it out.
pub const ToastAction = union(enum) {
    none,
    /// Send the tab with this uid again.
    retry: u64,
    /// Switch to the tab with this uid.
    open: u64,
    /// Show the folder holding this file (the path is owned by the toaster).
    show: []const u8,
    /// Reopen this many closed tabs.
    reopen: u64,

    pub fn label(action: ToastAction) ?[*:0]const u8 {
        return switch (action) {
            .none => null,
            .retry => "Retry",
            .open => "Open",
            .show => "Show in folder",
            .reopen => "Reopen",
        };
    }
};
pub const Toast = struct { status: Status, title: []const u8, message: []const u8, duration: u32, action: ToastAction = .none };
pub const Toaster = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Toast) = .empty,
    /// Shown toasts whose button may still be clicked, oldest first.
    live: std.ArrayList(struct { handle: c_int, action: ToastAction }) = .empty,
    pub fn push(s: *Toaster, msg: Toast) void {
        if (s.items.items.len >= 8) return;
        var m = msg;
        m.title = s.gpa.dupe(u8, msg.title[0..@min(msg.title.len, 128)]) catch return;
        m.message = s.gpa.dupe(u8, msg.message[0..@min(msg.message.len, 1024)]) catch {
            s.gpa.free(m.title);
            return;
        };
        if (msg.action == .show) {
            m.action = .{ .show = s.gpa.dupe(u8, msg.action.show) catch "" };
            if (m.action.show.len == 0) m.action = .none;
        }
        s.items.append(s.gpa, m) catch {
            s.gpa.free(m.title);
            s.gpa.free(m.message);
            s.release(m.action);
        };
    }
    /// Frees what an action taken from `clicked` owns.
    pub fn release(s: *Toaster, action: ToastAction) void {
        if (action == .show) s.gpa.free(action.show);
    }
    pub fn deinit(s: *Toaster) void {
        s.clear();
        s.items.deinit(s.gpa);
        for (s.live.items) |l| s.release(l.action);
        s.live.deinit(s.gpa);
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
            const title = s.gpa.dupeSentinel(u8, m.title, 0) catch {
                s.release(m.action);
                continue;
            };
            defer s.gpa.free(title);
            const message = s.gpa.dupeSentinel(u8, m.message, 0) catch {
                s.release(m.action);
                continue;
            };
            defer s.gpa.free(message);
            const label = m.action.label();
            const handle = c.cui_toast_ex(ui, title, &.{ .description = message, .duration = @floatFromInt(if (label != null) @max(m.duration, 8) else m.duration), .action = label, .show_timer = label != null, .tone = switch (m.status) {
                .success => c.CUI_TONE_SUCCESS,
                .warning => c.CUI_TONE_WARNING,
                .danger => c.CUI_TONE_DANGER,
                .info => c.CUI_TONE_INFO,
            } });
            if (label == null) continue;
            if (s.live.items.len >= 8) s.release(s.live.orderedRemove(0).action);
            s.live.append(s.gpa, .{ .handle = handle, .action = m.action }) catch s.release(m.action);
        }
        s.clear();
    }
    /// The action of a toast button clicked since the last call, if any; the
    /// toast closes. Pass it to `release` once done.
    pub fn clicked(s: *Toaster, ui: *c.cui_ctx) ?ToastAction {
        for (s.live.items, 0..) |l, i| {
            if (!c.cui_toast_action_clicked(ui, l.handle)) continue;
            c.cui_toast_dismiss(ui, l.handle);
            return s.live.orderedRemove(i).action;
        }
        return null;
    }
};
