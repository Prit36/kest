//! T3 Code's default neutral dark/light palette, mapped to native CUI roles.
//! Source: pingdotgg/t3code, packages/shared/src/themePalettes.ts.
//! Motion stays disabled.
const c = @import("c.zig").c;

fn rgb(value: u32) c.cui_color {
    return .{ .r = @intCast(value >> 16), .g = @intCast((value >> 8) & 255), .b = @intCast(value & 255), .a = 255 };
}
pub fn apply(ui: *c.cui_ctx, dark: bool) void {
    c.cui_set_reduced_motion(ui, true);
    c.cui_set_theme(ui, if (dark) c.CUI_THEME_DARK else c.CUI_THEME_LIGHT);
    const t = c.cui_theme_get(ui);
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
    for (tokens, if (dark) night else day) |token, value| t.*.colors[@intCast(token)] = rgb(value);
    t.*.colors[c.CUI_TOKEN_CONTROL_ON] = t.*.colors[c.CUI_TOKEN_ACCENT];
    t.*.colors[c.CUI_TOKEN_CONTROL_GLYPH] = t.*.colors[c.CUI_TOKEN_ACCENT_FOREGROUND];
    t.*.colors[c.CUI_TOKEN_CONTROL_TRACK] = rgb(if (dark) 0x222222 else 0xd4d4d8);
    t.*.colors[c.CUI_TOKEN_CONTROL_TRACK_HOVER] = rgb(if (dark) 0x363636 else 0xbdbdbd);
    t.*.colors[c.CUI_TOKEN_CONTROL_THUMB] = rgb(0xffffff);
    t.*.colors[c.CUI_TOKEN_CONTROL_THUMB_ON] = rgb(0xffffff);
    t.*.colors[c.CUI_TOKEN_SCRIM] = .{ .r = 0, .g = 0, .b = 0, .a = if (dark) 170 else 84 };
    // Menus/toasts use tone fields in addition to semantic tokens.
    t.*.tone_sky = t.*.colors[c.CUI_TOKEN_INFO];
    t.*.tone_teal = rgb(if (dark) 0x2dd4bf else 0x0f766e);
    t.*.tone_green = t.*.colors[c.CUI_TOKEN_SUCCESS];
    t.*.tone_amber = t.*.colors[c.CUI_TOKEN_WARNING];
    t.*.tone_rose = t.*.colors[c.CUI_TOKEN_DANGER];
    t.*.tone_orchid = rgb(if (dark) 0xf472b6 else 0xbe185d);
    t.*.tone_violet = rgb(if (dark) 0xa78bfa else 0x6d28d9);
    t.*.radius_control = 3;
    t.*.radius_panel = 6;
    t.*.radius_surface = 6;
    t.*.shadow_floating[0] = .{ .y = 8, .blur = 20, .spread = -4, .alpha = if (dark) 0.24 else 0.10 };
    t.*.shadow_floating[1] = .{ .y = 1, .blur = 2, .spread = 0, .alpha = if (dark) 0.30 else 0.08 };
    t.*.control_sm = 28;
    t.*.control_md = 32;
    t.*.control_lg = 38;
    t.*.text_body = 13;
    t.*.text_sm = 12;
    t.*.text_xs = 11;
    t.*.motion = 0;
}

pub fn sidebar(dark: bool) c.cui_color {
    return rgb(if (dark) 0x000000 else 0xfafafa);
}

pub const Syntax = enum { key, string, number, keyword, comment };
pub fn syntax(ui: *c.cui_ctx, role: Syntax) c.cui_color {
    const dark = c.cui_get_theme_mode(ui) == c.CUI_THEME_DARK;
    return rgb(switch (role) {
        .key => if (dark) 0x93c5fd else 0x1d4ed8,
        .string => if (dark) 0x86efac else 0x166534,
        .number => if (dark) 0xfdba74 else 0x9a3412,
        .keyword => if (dark) 0xc4b5fd else 0x6d28d9,
        .comment => if (dark) 0x818181 else 0x71717b,
    });
}
