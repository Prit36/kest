//! T3 Code's default neutral dark/light palette, mapped to native CUI roles.
//! Source: pingdotgg/t3code, packages/shared/src/themePalettes.ts.
//! Motion is short and settles: CUI's durations run at `motion_scale`, so
//! hover fades take ~70 ms and menus/dialogs ~150 ms. Headless frames stay still.
const c = @import("c.zig").c;

pub const space = struct {
    pub const micro: f32 = c.KEST_SPACE_MICRO;
    pub const tight: f32 = c.KEST_SPACE_TIGHT;
    pub const compact: f32 = c.KEST_SPACE_COMPACT;
    pub const normal: f32 = c.KEST_SPACE_NORMAL;
    pub const group: f32 = c.KEST_SPACE_GROUP;
    pub const section: f32 = c.KEST_SPACE_SECTION;
};
pub const control = struct {
    pub const small: f32 = c.KEST_CONTROL_SMALL;
    pub const normal: f32 = c.KEST_CONTROL_NORMAL;
    pub const large: f32 = c.KEST_CONTROL_LARGE;
    pub const tab_height: f32 = c.KEST_CONTENT_TAB_HEIGHT;
    pub const document_strip: f32 = c.KEST_DOCUMENT_STRIP_HEIGHT;
    pub const icon: f32 = c.KEST_ICON_SMALL;
};
pub const text = struct {
    pub const body: f32 = c.KEST_TEXT_BODY;
    pub const secondary: f32 = c.KEST_TEXT_SECONDARY;
    pub const caption: f32 = c.KEST_TEXT_CAPTION;
};
pub const geometry = struct {
    pub const sidebar_min: f32 = 210;
    pub const sidebar_max: f32 = 480;
    pub const sidebar_sheet: f32 = 840;
    pub const workspace_min: f32 = 520;
    pub const columns_min: f32 = 730;
    pub const request_min: f32 = 320;
    pub const response_min: f32 = 360;
};

/// Multiplier on CUI's motion tokens. Below 1 is faster than CUI's defaults.
pub const motion_scale: f32 = 0.5;
/// 1 = dark, 0 = light. Eases between palettes when the appearance changes.
pub var blend: f32 = 1;

fn rgb(value: u32) c.cui_color {
    return .{ .r = @intCast(value >> 16), .g = @intCast((value >> 8) & 255), .b = @intCast(value & 255), .a = 255 };
}
fn channel(a: u32, b: u32, t: f32) u8 {
    const x: f32 = @floatFromInt(a);
    const y: f32 = @floatFromInt(b);
    return @intFromFloat(@round(x + (y - x) * t));
}
/// Light value `day` blended toward dark value `night` by the current blend.
fn pick(day: u32, night: u32) c.cui_color {
    return .{ .r = channel(day >> 16, night >> 16, blend), .g = channel((day >> 8) & 255, (night >> 8) & 255, blend), .b = channel(day & 255, night & 255, blend), .a = 255 };
}
fn pickf(day: f32, night: f32) f32 {
    return day + (night - day) * blend;
}
pub fn apply(ui: *c.cui_ctx, dark: bool) void {
    const still = @import("platform.zig").headless;
    c.cui_set_reduced_motion(ui, still);
    c.cui_set_theme(ui, if (dark) c.CUI_THEME_DARK else c.CUI_THEME_LIGHT);
    const t = c.cui_theme_get(ui);
    t.*.motion = if (still) 0 else motion_scale;
    blend = @import("std").math.clamp(c.cui_animate_spring(ui, c.cui_make_id(ui, "kest-appearance"), if (dark) 1 else 0, 0.36, 0), 0, 1);
    const tokens = [_]c_int{
        c.CUI_TOKEN_BACKGROUND,    c.CUI_TOKEN_SURFACE,           c.CUI_TOKEN_SURFACE_RAISED,
        c.CUI_TOKEN_SURFACE_MUTED, c.CUI_TOKEN_FOREGROUND,        c.CUI_TOKEN_TEXT_SECONDARY,
        c.CUI_TOKEN_TEXT_MUTED,    c.CUI_TOKEN_BORDER,            c.CUI_TOKEN_BORDER_SUBTLE,
        c.CUI_TOKEN_BORDER_STRONG, c.CUI_TOKEN_ACCENT,            c.CUI_TOKEN_ACCENT_STRONG,
        c.CUI_TOKEN_ACCENT_SUBTLE, c.CUI_TOKEN_ACCENT_FOREGROUND, c.CUI_TOKEN_SUCCESS,
        c.CUI_TOKEN_WARNING,       c.CUI_TOKEN_DANGER,            c.CUI_TOKEN_INFO,
        c.CUI_TOKEN_HOVER,         c.CUI_TOKEN_ACTIVE,            c.CUI_TOKEN_FOCUS_RING,
    };
    const night = [_]u32{
        0x0a0a0a, 0x111111, 0x111111, 0x141414, 0xf5f5f5, 0xa3a3a3,
        0x818181, 0x191919, 0x141414, 0x363636, 0x346bf1, 0x3061d9,
        0x121b34, 0xffffff, 0x34d399, 0xffb900, 0xff6467, 0x51a2ff,
        0x141414, 0x1a1b1b, 0x346bf1,
    };
    const day = [_]u32{
        0xfcfcfc, 0xffffff, 0xfcfcfc, 0xfafafa, 0x27272a, 0x71717b,
        0x71717b, 0xe4e4e7, 0xe4e4e7, 0xd4d4d8, 0x1b4ed8, 0x3160db,
        0xe0e6f7, 0xffffff, 0x047857, 0xbb4d00, 0xc10007, 0x1b4ed8,
        0xf4f4f5, 0xe4e4e7, 0x1b4ed8,
    };
    for (tokens, day, night) |token, light_value, dark_value| t.*.colors[@intCast(token)] = pick(light_value, dark_value);
    t.*.colors[c.CUI_TOKEN_CONTROL_ON] = t.*.colors[c.CUI_TOKEN_ACCENT];
    t.*.colors[c.CUI_TOKEN_CONTROL_GLYPH] = t.*.colors[c.CUI_TOKEN_ACCENT_FOREGROUND];
    t.*.colors[c.CUI_TOKEN_CONTROL_TRACK] = pick(0xd4d4d8, 0x222222);
    t.*.colors[c.CUI_TOKEN_CONTROL_TRACK_HOVER] = pick(0xbdbdbd, 0x363636);
    t.*.colors[c.CUI_TOKEN_CONTROL_THUMB] = rgb(0xffffff);
    t.*.colors[c.CUI_TOKEN_CONTROL_THUMB_ON] = rgb(0xffffff);
    t.*.colors[c.CUI_TOKEN_SCRIM] = .{ .r = 0, .g = 0, .b = 0, .a = @intFromFloat(@round(pickf(84, 170))) };
    // Menus/toasts use tone fields in addition to semantic tokens.
    t.*.tone_sky = t.*.colors[c.CUI_TOKEN_INFO];
    t.*.tone_teal = pick(0x0f766e, 0x2dd4bf);
    t.*.tone_green = t.*.colors[c.CUI_TOKEN_SUCCESS];
    t.*.tone_amber = t.*.colors[c.CUI_TOKEN_WARNING];
    t.*.tone_rose = t.*.colors[c.CUI_TOKEN_DANGER];
    t.*.tone_orchid = pick(0xbe185d, 0xf472b6);
    t.*.tone_violet = pick(0x6d28d9, 0xa78bfa);
    t.*.radius_control = c.KEST_RADIUS_CONTROL;
    t.*.radius_panel = c.KEST_RADIUS_PANEL;
    t.*.radius_surface = c.KEST_RADIUS_PANEL;
    t.*.shadow_floating[0] = .{ .y = 8, .blur = 20, .spread = -4, .alpha = pickf(0.10, 0.24) };
    t.*.shadow_floating[1] = .{ .y = 1, .blur = 2, .spread = 0, .alpha = pickf(0.08, 0.30) };
    t.*.control_sm = control.small;
    t.*.control_md = control.normal;
    t.*.control_lg = control.large;
    t.*.text_body = text.body;
    t.*.text_sm = text.secondary;
    t.*.text_xs = text.caption;
}

pub fn sidebar() c.cui_color {
    return pick(0xfafafa, 0x000000);
}

pub const Syntax = enum { key, string, number, keyword, comment };
pub fn syntax(ui: *c.cui_ctx, role: Syntax) c.cui_color {
    _ = ui;
    return switch (role) {
        .key => pick(0x1d4ed8, 0x93c5fd),
        .string => pick(0x166534, 0x86efac),
        .number => pick(0x9a3412, 0xfdba74),
        .keyword => pick(0x6d28d9, 0xc4b5fd),
        .comment => pick(0x71717b, 0x818181),
    };
}
