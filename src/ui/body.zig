//! Request body modes and controls; switching mode retains every draft buffer.
const std = @import("std");
const w = @import("widgets.zig");
const c = w.c;
const App = @import("../app/state.zig").App;
const tab = @import("../app/tab.zig");
const commands = @import("../app/commands.zig");
const persist = @import("../app/persist.zig");
const editor = @import("editor.zig");

pub fn view(ui: *c.cui_ctx, app: *App, t: *tab.Tab) void {
    const raw = t.body_kind == .json or t.body_kind == .text or t.body_kind == .xml;
    w.row(ui, .{ .id = "body-toolbar", .gap = 4, .pad_x = 12, .height = w.px(36), .width = w.fill });
    const kinds = [_][]const u8{ "No body", "JSON", "Text", "XML", "Form", "Multipart", "File" };
    const names = [_][]const u8{ "No body", "JSON", "Text", "XML", "Form URL encoded", "Multipart form", "Binary / file" };
    if (w.menu(ui, w.fmt("{s}###body-kind", .{kinds[@intCast(@backingInt(t.body_kind))]}), 126, w.color(c.CUI_TOKEN_TEXT_SECONDARY))) {
        for (names, 0..) |label, i| {
            if (c.cui_menu_item_ex(ui, w.z(label), &.{ .checked = @backingInt(t.body_kind) == i })) {
                t.body_kind = @fromBackingInt(@intCast(i));
                persist.touchTab(app, t);
            }
        }
        c.cui_menu_end(ui);
    }
    c.cui_spacer(ui);
    if (t.body_kind == .json) {
        const wide = c.cui_get_rect(ui, c.cui_make_id(ui, "body-toolbar")).w >= 480;
        if (w.action(ui, "format-body", if (wide) "Format" else "", c.CUI_ICON_LIST, false, if (wide) 88 else 28, 28, 3)) commands.formatBody(app, t, 2);
        c.cui_tooltip(ui, "Format JSON");
    }
    if (raw) {
        if (w.action(ui, "wrap-body", "Wrap", null, t.body.word_wrap, 48, 28, 3)) {
            t.body.word_wrap = !t.body.word_wrap;
            t.body.reveal = true;
        }
        c.cui_tooltip(ui, "Wrap long lines without changing the body");
        if (w.action(ui, "find-body", "", c.CUI_ICON_SEARCH, false, 28, 28, 3)) {
            t.body.search_open = !t.body.search_open;
            t.body.query.focus();
        }
        c.cui_tooltip(ui, "Find in body");
        w.row(ui, .{ .id = "body-actions", .width = w.px(28), .height = w.px(28) });
        if (c.kest_dropdown_begin(ui, "Body actions", &.{ .icon = c.CUI_ICON_ELLIPSIS, .icon_only = true, .placement = c.CUI_PLACE_BOTTOM_END, .width = 260 })) {
            if (t.body_kind == .json) {
                if (w.menuItem(ui, "Format JSON")) commands.formatBody(app, t, 2);
                if (w.menuItem(ui, "Minify JSON")) commands.formatBody(app, t, 0);
            }
            if (c.cui_menu_item_ex(ui, "Undo", &.{ .disabled = t.body.undo.items.len == 0 }) and t.body.undoEdit()) persist.touchTab(app, t);
            if (c.cui_menu_item_ex(ui, "Redo", &.{ .disabled = t.body.redo.items.len == 0 }) and t.body.redoEdit()) persist.touchTab(app, t);
            if (w.menuItem(ui, "Copy body")) w.copy(ui, t.body.text());
            c.cui_menu_separator(ui);
            if (c.cui_menu_item_ex(ui, "Tab moves focus (Ctrl M)", &.{ .checked = t.body.tab_moves_focus })) t.body.tab_moves_focus = !t.body.tab_moves_focus;
            w.text(ui, "Tab / Shift Tab: indent / outdent\nEnter: auto-indent\nEscape: focus body type", .{ .width = w.fill, .size = 11, .color = w.color(c.CUI_TOKEN_TEXT_SECONDARY) });
            c.cui_menu_end(ui);
        }
        w.end(ui);
    }
    w.end(ui);
    switch (t.body_kind) {
        .none => w.empty(ui, "This request has no body", "Choose JSON, text, a form, or a file from the menu above."),
        .json, .text, .xml => {
            commands.bodyProblem(app, t);
            if (t.body_problem_text.len > 0) {
                w.row(ui, .{ .id = "body-validation", .width = w.fill, .pad_x = 12, .pad_y = 4, .gap = 4 });
                w.text(ui, t.body_problem_text, .{ .width = w.fill, .size = 12, .color = w.color(if (t.body_problem_pending) c.CUI_TOKEN_WARNING else c.CUI_TOKEN_DANGER) });
                if (t.body_problem_at) |at| if (w.action(ui, "body-problem-location", "Go to", null, false, 64, 24, 3)) {
                    t.body.moveTo(at, false);
                    c.kest_focus(ui, "body-editor");
                };
                w.end(ui);
            }
            if (editor.view(ui, "body-editor", &t.body, t.body.text(), false, if (t.body_kind == .json) .json else if (t.body_kind == .xml) .xml else .plain)) {
                persist.touchTab(app, t);
                commands.bodyProblem(app, t);
                c.cui_request_redraw(ui);
            }
        },
        .form_urlencoded, .multipart => if (@import("key_value.zig").view(ui, &t.form, t.body_kind == .multipart, "Form fields", .{ .kind = .form, .vars = app.activeVars(), .app = app })) persist.touchTab(app, t),
        .file => if (@import("upload.zig").binary(ui, app, t)) persist.touchTab(app, t),
    }
}
