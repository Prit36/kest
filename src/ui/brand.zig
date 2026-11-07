//! Kest's angular mark, sharing geometry with the executable's SVG/ICO.
const w = @import("widgets.zig");
const c = w.c;
const geometry = @import("brand_geometry.zig");

pub fn view(ui: *c.cui_ctx) void {
    _ = c.cui_canvas(ui, "kest-mark", w.px(20), w.px(20), paint, null, 0);
    w.text(ui, "kest", .{ .font = c.CUI_FONT_MEDIUM, .size = 15, .nowrap = true });
}
fn paint(ui: ?*c.cui_ctx, r: c.cui_rect, _: ?*anyopaque) callconv(.c) void {
    for (geometry.polygons) |shape| {
        var points: [4]c.cui_vec2 = undefined;
        for (shape, &points) |point, *dest| dest.* = .{ .x = r.x + point[0] / 32 * r.w, .y = r.y + point[1] / 32 * r.h };
        c.cui_draw_polygon(ui, &points, points.len, w.color(c.CUI_TOKEN_FOREGROUND));
    }
}
