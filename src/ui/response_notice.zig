//! Concise non-modal execution messages with explicit technical disclosure.
const w = @import("widgets.zig");
const c = w.c;
const Tab = @import("../app/tab.zig").Tab;
const Issue = @import("../core/response_status.zig").Issue;

pub fn view(ui: *c.cui_ctx, t: *Tab, issue: Issue, detail: []const u8, full: bool) void {
    const bounds = c.cui_get_rect(ui, c.cui_make_id(ui, "response-content"));
    if (full) c.cui_scroll_begin(ui, &.{ .id = "response-notice-scroll", .width = w.fill, .height = w.fill });
    w.column(ui, .{ .id = "response-notice", .width = w.fill, .pad_x = 12, .pad_y = 6, .gap = 4 });
    w.row(ui, .{ .width = w.fill, .min_height = 28, .gap = 8, .@"align" = c.CUI_ALIGN_CENTER });
    w.text(ui, issue.title, .{ .width = w.fill, .font = c.CUI_FONT_MEDIUM, .size = 13, .color = w.color(@import("response_chrome.zig").token(issue.tone)) });
    if (w.action(ui, "response-error-details", "Details", if (t.response.error_details_open) c.CUI_ICON_CHEVRON_UP else c.CUI_ICON_CHEVRON_DOWN, t.response.error_details_open, 88, 28, 3)) {
        t.response.error_details_open = !t.response.error_details_open;
        c.cui_request_redraw(ui);
    }
    c.cui_tooltip(ui, "Show or hide execution details");
    w.end(ui);
    if (full or bounds.h >= 160) w.text(ui, issue.hint, .{ .width = w.fill, .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
    if (t.response.error_details_open) {
        if (!full) c.cui_scroll_begin(ui, &.{ .id = "response-technical", .width = w.fill, .height = w.px(@min(140, @max(32, bounds.h * 0.4))) });
        w.text(ui, if (detail.len > 0) detail else issue.hint, .{ .width = w.fill, .font = c.CUI_FONT_MONO, .size = 12, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
        if (!full) c.cui_scroll_end(ui);
    }
    w.end(ui);
    if (full) c.cui_scroll_end(ui);
}
