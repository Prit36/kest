/* App-specific controls on CUI's existing input, focus and popup machinery.
 * No dependency sources are patched. No animation state is introduced. */
#include "host.h"
#include "cui_internal.h"
void retort_focus(cui_ctx *ui, const char *id) { ui->focus = cui_make_id(ui, id); }

typedef struct { int kind; bool selected, hovered; } retort_control_paint;
static void paint_control(cui_ctx *ui, cui_node *n, void *raw) {
    retort_control_paint *p = raw;
    cui_rect r = n->rect;
    if (p->kind == 1) {
        cui_draw_rect(ui, (cui_rect){r.x + r.w - 1, r.y, 1, r.h}, CUI_CORNERS(0), CUI_C(ui, BORDER_SUBTLE));
        if (p->selected)
            cui_draw_rect(ui, (cui_rect){r.x + 1, r.y + 11, 2, r.h - 22}, CUI_CORNERS(1), CUI_C(ui, ACCENT));
    } else if (p->kind == 2 && (p->selected || p->hovered)) {
        cui_draw_rect(ui, (cui_rect){r.x + 3, r.y + 5, r.w - 6, r.h - 10}, CUI_CORNERS(3), p->selected ? CUI_C(ui, ACTIVE) : CUI_C(ui, HOVER));
    } else if (p->kind == 0 && p->selected) {
        cui_draw_rect(ui, (cui_rect){r.x, r.y + 7, 2, r.h - 14}, CUI_CORNERS(1), CUI_C(ui, ACCENT));
    }
}

bool retort_control_begin(cui_ctx *ui, const char *key, bool selected, float width, float height, int kind) {
    cui_id id = cui_make_id(ui, key);
    cui_interact hit = cui__interact(ui, id, CUI_IF_FOCUSABLE);
    cui_box box = {0};
    box.id = key;
    box.width = width < 0 ? CUI_FILL : width > 0 ? CUI_PX(width) : CUI_FIT;
    box.height = CUI_PX(height);
    box.dir = CUI_ROW; box.align = CUI_ALIGN_CENTER;
    box.gap = 8; box.pad_x = kind == 0 ? 6 : (kind == 3 && width > 0 && width <= 36) ? 0 : 10;
    if (kind == 3) box.justify = CUI_JUSTIFY_CENTER;
    box.radius = kind == 3 || kind == 0 ? 3 : 0;
    if (kind == 1 && selected) box.bg = CUI_C(ui, SURFACE);
    else if (kind == 0 && selected) box.bg = CUI_C(ui, ACTIVE);
    else if (kind == 3 && selected) box.bg = CUI_C(ui, ACTIVE);
    else if (hit.hovered && kind != 2) box.bg = CUI_C(ui, HOVER);
    if (hit.focus_visible) { box.border = 1; box.border_color = CUI_C(ui, FOCUS_RING); }
    cui_box_begin(ui, &box);
    int at = ui->last_node;
    cui__mark_interactive(ui, at, CUI_IF_FOCUSABLE);
    if (kind == 1 || kind == 2 || (kind == 0 && selected)) {
        retort_control_paint *p = CUI_PAINT_DATA(ui, retort_control_paint);
        p->kind = kind; p->selected = selected; p->hovered = hit.hovered;
        ui->nodes[at].paint = paint_control;
        ui->nodes[at].paint_data = p;
    }
    if (hit.hovered) cui__set_cursor(ui, CUI_CURSOR_HAND);
    return hit.clicked;
}

int retort_flat_input(cui_ctx *ui, const char *key, char *buf, size_t cap, const cui_input_opts *opts, bool cell) {
    cui_id id = cui_make_id(ui, key);
    if (opts && opts->autofocus) ui->focus = id;
    int first = ui->node_count;
    int flags = cui__text_field(ui, id, buf, cap, opts, false, 1, NULL);
    cui_node *n = &ui->nodes[first];
    n->min_w = 1;
    n->pad[1] = n->pad[3] = cell ? 10 : 8;
    if (cell && ui->focus == id) {
        n->bg = CUI_C(ui, SURFACE_RAISED);
        n->border = 1; n->border_color = CUI_C(ui, ACCENT);
    }
    if (!cell && ui->focus == id && n->parent >= 0 && ui->nodes[n->parent].border > 0)
        ui->nodes[n->parent].border_color = CUI_C(ui, ACCENT);
    return flags;
}

/* CUI has 32 popup slots. A closed, never-used row menu must not reserve one:
 * a long collection tree can otherwise prevent the method/body pickers opening.
 * Keep CUI's keyboard/menu behavior, and create a slot only on activation. */
bool retort_dropdown_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts) {
    cui_menu_opts defaults = {0};
    if (!opts) opts = &defaults;
    cui_id popup_id = cui_make_id(ui, label) ^ 0x3E40u;
    cui_popup *popup = cui__popup_get(ui, popup_id, false);
    cui_button_opts button = {0};
    button.variant = opts->variant; button.icon = opts->icon;
    button.selected = popup && popup->open;
    bool clicked;
    if (opts->icon_only) {
        button.tooltip = label;
        clicked = cui_icon_button_ex(ui, opts->icon ? opts->icon : CUI_ICON_ELLIPSIS, &button);
    } else {
        button.icon_right = CUI_ICON_CHEVRON_DOWN;
        clicked = cui_button_ex(ui, label, &button);
    }
    ui->nodes[ui->last_node].scale = 1;
    cui_id anchor = ui->last_id;
    bool focused = ui->focus == anchor && ui->focus_visible;
    bool keyboard = focused && (cui_key_pressed(ui, CUI_KEY_ENTER) || cui_key_pressed(ui, CUI_KEY_SPACE));
    if (clicked && !(popup && popup->open && keyboard)) {
        bool was_open = popup && popup->open;
        cui__popup_set(ui, popup_id, !was_open);
        popup = cui__popup_get(ui, popup_id, false);
        if (popup) popup->at_mouse = false;
    }
    if ((!popup || !popup->open) && focused && cui_key_pressed(ui, CUI_KEY_DOWN))
        cui__popup_set(ui, popup_id, true);
    return cui__popup_begin(ui, popup_id, anchor, opts->placement, opts->width, 6, 0, true);
}

bool retort_menu_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts, float width, cui_color color) {
    int first = ui->node_count;
    bool open = retort_dropdown_begin(ui, label, opts);
    /* cui_menu_begin constructs its trigger first, followed by its label/icon. */
    if (first < ui->node_count) {
        cui_node *n = &ui->nodes[first];
        if (width > 0) n->w = CUI_PX(width);
        n->h = CUI_PX(32);
        n->border = 0; n->radius = CUI_CORNERS(4);
        for (int i = first + 1; i < ui->node_count && ui->nodes[i].parent == first; i++)
            ui->nodes[i].text_color = cui_color_of(ui, color);
    }
    return open;
}

bool retort_button_ex(cui_ctx *ui, const char *label, const cui_button_opts *opts) {
    int first = ui->node_count;
    bool clicked = cui_button_ex(ui, label, opts);
    if (opts && (opts->variant == CUI_BUTTON_PRIMARY || opts->variant == CUI_BUTTON_DANGER)) {
        ui->nodes[first].paint = NULL;
        ui->nodes[first].paint_data = NULL;
    }
    return clicked;
}

bool retort_select_ex(cui_ctx *ui, const char *key, const char *const *items, int count, int *index, const cui_select_opts *opts) {
    int first = ui->node_count;
    bool changed = cui_select_ex(ui, key, items, count, index, opts);
    /* The app's selects have no external label. Keep sufficient room for the
       full method/status text in the minimum-width history filter row. */
    if (!opts || !opts->label) {
        ui->nodes[first].pad[1] = ui->nodes[first].pad[3] = 8;
        ui->nodes[first].gap = 6;
    }
    return changed;
}

bool retort_reveal(cui_ctx *ui, const char *key, cui_id target, bool horizontal) {
    cui_id id = cui_make_id(ui, key);
    cui_rect viewport = cui__prev_rect(ui, id), item = cui__prev_rect(ui, target);
    if (viewport.w <= 0 || viewport.h <= 0 || item.w <= 0 || item.h <= 0) return false;
    cui_scroll_state *st = cui_state(ui, id, sizeof *st);
    if (horizontal) {
        if (item.x < viewport.x) st->tx -= viewport.x - item.x;
        else if (item.x + item.w > viewport.x + viewport.w) st->tx += item.x + item.w - viewport.x - viewport.w;
        st->tx = cui__clampf(st->tx, 0, CUI_MAX(0, st->content_w - st->view_w));
        st->x = st->tx;
    } else {
        if (item.y < viewport.y) st->ty -= viewport.y - item.y;
        else if (item.y + item.h > viewport.y + viewport.h) st->ty += item.y + item.h - viewport.y - viewport.h;
        st->ty = cui__clampf(st->ty, 0, CUI_MAX(0, st->content_h - st->view_h));
        st->y = st->ty;
    }
    return true;
}
