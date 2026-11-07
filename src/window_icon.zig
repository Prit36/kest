//! The window's icon. CUI registers its window class without one, so the
//! taskbar and Alt+Tab would show a blank; this hands the window the icon
//! the executable carries (assets/kest.rc, resource 1).
const builtin = @import("builtin");

const win = struct {
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "user32" fn LoadImageW(inst: ?*anyopaque, name: usize, kind: u32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn SendMessageW(hwnd: *anyopaque, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
    extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
};

/// `hwnd` is CUI's window handle, null when there's no window (snapshots).
pub fn apply(hwnd: anytype) void {
    if (builtin.os.tag != .windows) return;
    const h: *anyopaque = @ptrCast(hwnd orelse return);
    const inst = win.GetModuleHandleW(null);
    const image_icon = 1;
    const wm_seticon = 0x0080;
    // ICON_BIG at SM_CXICON, ICON_SMALL at SM_CXSMICON.
    const sizes = [_][3]i32{ .{ 1, 11, 12 }, .{ 0, 49, 50 } };
    for (sizes) |s| {
        const icon = win.LoadImageW(inst, 1, image_icon, win.GetSystemMetrics(s[1]), win.GetSystemMetrics(s[2]), 0) orelse continue;
        _ = win.SendMessageW(h, wm_seticon, @intCast(s[0]), @bitCast(@intFromPtr(icon)));
    }
}
