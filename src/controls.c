/* App-specific controls on CUI's existing input, focus and popup machinery.
 * No dependency sources are patched. No animation state is introduced. */
#include "host.h"
#include <stdio.h>
#include "cui_internal.h"
void kest_focus(cui_ctx *ui, const char *id) { ui->focus = cui_make_id(ui, id); }
void kest_input_select_all(cui_ctx *ui, const char *key, int length) {
    if (ui->focus != cui_make_id(ui, key) || !ui->edit) return;
    ui->edit->anchor = 0;
    ui->edit->cursor = length;
    ui->edit->scroll_x = 0;
    ui->edit->selecting = false;
    cui_request_redraw(ui);
}
bool kest_focus_within(cui_ctx *ui, const char *key) {
    if (!kest_editor_focus(ui, ui->focus)) return false;
    cui_id parent = cui_make_id(ui, key);
    for (int i = 0; i < ui->node_count; ++i) if (ui->nodes[i].id == ui->focus) {
        for (int at = i; at >= 0; at = ui->nodes[at].parent) if (ui->nodes[at].id == parent) return true;
    }
    return false;
}

/* Focus bookkeeping for overlays and hidden panes (shell.zig). */
cui_id kest_get_focus(cui_ctx *ui) { return ui->focus; }
void kest_set_focus(cui_ctx *ui, cui_id id) { ui->focus = id; }
cui_id kest_last_id(cui_ctx *ui) { return ui->last_id; }
/* `id` took part in the previous frame's keyboard focus order. */
bool kest_was_focusable(cui_ctx *ui, cui_id id) {
    for (int i = 0; i < ui->prev_focus_count; i++) if (ui->prev_focus_order[i] == id) return true;
    return false;
}

/* Keyboard focus is on `key` or inside it (any control, not only text). */
bool kest_focus_inside(cui_ctx *ui, const char *key) {
    if (!ui->focus) return false;
    cui_id parent = cui_make_id(ui, key);
    if (ui->focus == parent) return true;
    for (int i = 0; i < ui->node_count; ++i) if (ui->nodes[i].id == ui->focus) {
        for (int at = i; at >= 0; at = ui->nodes[at].parent) if (ui->nodes[at].id == parent) return true;
        return false;
    }
    return false;
}

/* Test diagnostics: the text inside the focused node (empty when none). */
static void focus_text(cui_ctx *ui, int index, char *out, size_t cap, size_t *len, int depth) {
    if (depth > 16 || *len + 2 >= cap) return;
    cui_node *n = &ui->nodes[index];
    if (n->text && n->text_len > 0 && n->font != CUI_FONT_ICONS) {
        if (*len) out[(*len)++] = ' ';
        size_t take = (size_t)n->text_len < cap - 1 - *len ? (size_t)n->text_len : cap - 1 - *len;
        memcpy(out + *len, n->text, take); *len += take; out[*len] = 0;
    }
    for (int ch = n->first; ch >= 0; ch = ui->nodes[ch].next) focus_text(ui, ch, out, cap, len, depth + 1);
}
const char *kest_focus_label(cui_ctx *ui) {
    static char text[256];
    size_t len = 0;
    text[0] = 0;
    if (!ui->focus) return text;
    cui_rect r = cui_get_rect(ui, ui->focus);
    len = (size_t)snprintf(text, sizeof text, "@%.0f,%.0f %.0fx%.0f", r.x, r.y, r.w, r.h);
    for (int i = 0; i < ui->node_count; ++i) if (ui->nodes[i].id == ui->focus) { focus_text(ui, i, text, 120, &len, 0); break; }
    return text;
}

void kest_collection_top(cui_ctx *ui, const char *key) {
    /* The pinned CUI grid owns a separate scroll state from its public id. */
    cui_scroll_state *s = cui_state(ui, cui_make_id(ui, key) ^ 0x5C011u, sizeof *s);
    s->x = s->tx = s->y = s->ty = 0;
    cui_request_redraw(ui);
}


/* Scrolls the collection tree so `index` is visible, as CUI does for its own
 * keyboard cursor (rows start below the grid's fixed 40px header offset).
 * Returns false until the tree has been laid out once: a fresh scroll state
 * has no extent yet and CUI would clamp any offset back to the top. */
bool kest_collection_reveal(cui_ctx *ui, const char *key, int index, float row_h) {
    if (index < 0 || row_h <= 0) return true;
    cui_scroll_state *s = cui_state(ui, cui_make_id(ui, key) ^ 0x5C011u, sizeof *s);
    if (s->view_h <= 0 || s->content_h <= 0) return false;
    float head = 40.0f, view = s->view_h;
    float top = head + index * row_h, bottom = top + row_h;
    float target = s->ty;
    if (top - head < target) target = top - head;
    if (bottom > target + view) target = bottom - view;
    if (target != s->ty) {
        s->y = s->ty = target;
        cui_request_redraw(ui);
    }
    return true;
}

/* Keep the native tree's navigation/selection, with browser-like rows.
 * All geometry changes are local; dependency sources stay untouched. */
void kest_collection_style(cui_ctx *ui, const char *key, cui_color background) {
    cui_id id = cui_make_id(ui, key);
    for (int i = cui__current(ui); i >= 0; i = ui->nodes[i].parent) {
        cui_node *n = &ui->nodes[i];
        if (n->id == id) {
            n->border = 0; n->radius = CUI_CORNERS(0);
            n->bg = cui_color_of(ui, background);
            break;
        }
    }
    /* A single-column browser needs no column title. Collapse the grid's sticky
     * header and the leaf reserving its place, leaving a small top inset. */
    cui_id head = id ^ 0x4EADu;
    for (int i = ui->node_count - 1; i >= 0; i--) {
        cui_node *n = &ui->nodes[i];
        if (n->id != head) continue;
        n->h = CUI_PX(0); n->bg.a = 0; n->paint = NULL; n->paint_data = NULL;
        n->flags |= CUI_NF_CLIP;
        int holder = n->parent;
        if (holder < 0) break;
        for (int j = i + 1; j < ui->node_count; j++) {
            cui_node *leaf = &ui->nodes[j];
            if (leaf->parent == ui->nodes[holder].parent && j > holder) {
                leaf->h = CUI_PX(4);
                break;
            }
        }
        break;
    }
}

static cui_id collection_row_id;
/* The name node marked last, so tests can confirm a match was tinted. */
static int collection_match_label = -1;
bool kest_collection_name_marked(cui_ctx *ui) {
    return collection_match_label >= 0 && collection_match_label < ui->node_count && ui->nodes[collection_match_label].paint != NULL;
}
/* Search matches are tinted behind the name text (painted before the
 * glyphs), clipped to the label so an ellipsis never shows a stray tint. */
typedef struct { float x, w; } kest_match_paint;
static void paint_match(cui_ctx *ui, cui_node *n, void *raw) {
    kest_match_paint *m = raw;
    float x = n->rect.x + m->x, end = CUI_MIN(x + m->w, n->rect.x + n->rect.w);
    if (end <= x) return;
    float h = CUI_MIN(n->rect.h, 18.0f);
    cui_draw_rect(ui, (cui_rect){x - 1, n->rect.y + (n->rect.h - h) / 2, end - x + 2, h}, CUI_CORNERS(2), cui_alpha(CUI_C(ui, ACCENT), ui->mode == CUI_THEME_DARK ? 0.32f : 0.22f));
}
static void mark_match(cui_ctx *ui, int label, const char *name, int start, int length) {
    if (label < 0 || start < 0 || length <= 0) return;
    cui_node *n = &ui->nodes[label];
    if (n->paint) return;
    float size = n->font_size > 0 ? n->font_size : KEST_TEXT_BODY;
    kest_match_paint *m = cui__frame_alloc(ui, sizeof *m);
    if (!m) return;
    m->x = start > 0 ? cui_measure_text(ui, n->font, size, name, start).width : 0;
    m->w = cui_measure_text(ui, n->font, size, name + start, length).width;
    n->paint = paint_match; n->paint_data = m;
}
void kest_collection_row_selected(cui_ctx *ui) { kest_a11y_selected(ui, collection_row_id); }
void kest_collection_name(cui_ctx *ui, const char *name, const char *method, const char *icon, cui_color color, int match_start, int match_length) {
    int row = cui__current(ui);
    if (row >= 0) { ui->nodes[row].paint = NULL; ui->nodes[row].paint_data = NULL; }
    collection_row_id = row >= 0 ? ui->nodes[row].id : 0;
    cui_tree_table_name(ui, method ? method : name, method ? NULL : icon);
    {
        char spoken[192];
        if (method) snprintf(spoken, sizeof spoken, "%s %s", method, name);
        else snprintf(spoken, sizeof spoken, "%s %s", icon && strcmp(icon, CUI_ICON_FOLDER) == 0 ? "Folder" : "Collection", name);
        kest_a11y_label_id(ui, collection_row_id, KEST_A11Y_TREE_ITEM, spoken, NULL);
    }
    int label = ui->last_node;
    if (method) {
        /* The slot stays 44px so names align; long verbs such as PROPFIND
         * shrink to fit instead of being cut to "PROPFI...". */
        float size = 10;
        size_t length = strlen(method);
        float width = cui_measure_text(ui, CUI_FONT_MONO, size, method, (int)length).width;
        if (width > 42 && width > 0) size = CUI_MAX(7.0f, floorf(size * 42 / width * 2) / 2);
        ui->nodes[label].text_color = cui_color_of(ui, color);
        ui->nodes[label].font = CUI_FONT_MONO;
        ui->nodes[label].font_size = size;
        ui->nodes[label].w = CUI_PX(44);
        ui->nodes[label].flags |= CUI_NF_KEEP_W;
        cui__leaf(ui, 0, CUI_PX(8), CUI_PX(1));
        cui_text_opts opts = {0}; opts.nowrap = true; opts.size = 12;
        cui_text_ex(ui, name, &opts);
        label = ui->last_node;
    }
    ui->nodes[label].w = CUI_FILL;
    ui->nodes[label].min_w = 1;
    int cell = cui__current(ui);
    if (cell >= 0) ui->nodes[cell].pad[1] = 4;
    mark_match(ui, label, name, match_start, match_length);
    collection_match_label = label;
}

/* Whether the tree row being built is under the pointer. Reads the grid's
 * own hover tween, so actions appear exactly where the row highlights. */
bool kest_collection_row_hot(cui_ctx *ui) {
    if (!collection_row_id) return false;
    float *hover = cui_state(ui, collection_row_id, sizeof(float));
    return *hover > 0.01f;
}

/* Last frame's rectangle of the tree row being built (zero before layout). */
cui_rect kest_collection_row_rect(cui_ctx *ui) {
    if (!collection_row_id) return (cui_rect){0};
    return cui_get_rect(ui, collection_row_id);
}

/* Drag reordering: an insertion line above (0) or below (2) the row, or an
 * outline around it (1) when the item will go inside a folder. */
static void paint_drop(cui_ctx *ui, cui_node *n, void *raw) {
    int where = *(int *)raw;
    cui_rect r = n->rect;
    cui_color accent = CUI_C(ui, ACCENT);
    if (where == 1) {
        cui_draw_rect(ui, (cui_rect){r.x + 2, r.y + 1, r.w - 4, r.h - 2}, CUI_CORNERS(4), cui_alpha(accent, 0.16f));
        cui_draw_rect(ui, (cui_rect){r.x + 2, r.y + 1, 2, r.h - 2}, CUI_CORNERS(1), accent);
        return;
    }
    float y = where == 0 ? r.y : r.y + r.h - 2;
    cui_draw_rect(ui, (cui_rect){r.x + 4, y, r.w - 8, 2}, CUI_CORNERS(1), accent);
}
static int collection_drop_row = -1;
void kest_collection_drop(cui_ctx *ui, int where) {
    int row = cui__current(ui);
    collection_drop_row = -1;
    if (row < 0 || where < 0 || where > 2) return;
    int *data = cui__frame_alloc(ui, sizeof *data);
    if (!data) return;
    *data = where;
    ui->nodes[row].paint = paint_drop;
    ui->nodes[row].paint_data = data;
    ui->nodes[row].flags |= CUI_NF_PAINT_AFTER;
    collection_drop_row = row;
}
/* Whether the last frame built a drop indicator (for tests). */
bool kest_collection_drop_shown(cui_ctx *ui) {
    return collection_drop_row >= 0 && collection_drop_row < ui->node_count && ui->nodes[collection_drop_row].paint == paint_drop;
}
void kest_collection_drop_clear(void) { collection_drop_row = -1; }

float kest_collection_scroll_y(cui_ctx *ui, const char *key) {
    return ((cui_scroll_state *)cui_state(ui, cui_make_id(ui, key) ^ 0x5C011u, sizeof(cui_scroll_state)))->ty;
}
/* Autoscroll while dragging near the tree's top or bottom edge. */
void kest_collection_scroll_by(cui_ctx *ui, const char *key, float dy) {
    cui_scroll_state *s = cui_state(ui, cui_make_id(ui, key) ^ 0x5C011u, sizeof *s);
    float max = s->content_h - s->view_h;
    if (max <= 0) return;
    float target = CUI_MAX(0.0f, CUI_MIN(max, s->ty + dy));
    if (target != s->ty) {
        s->y = s->ty = target;
        cui_request_redraw(ui);
    }
}

typedef struct { int kind; bool selected; float hover; bool focus; } kest_control_paint;
static void paint_control(cui_ctx *ui, cui_node *n, void *raw) {
    kest_control_paint *p = raw;
    cui_rect r = n->rect;
    if ((p->kind == 1 || p->kind == 2) && p->selected) {
        cui_draw_rect(ui, r, CUI_CORNERS(0), CUI_C(ui, SURFACE));
        /* Accent edges align to physical pixels even on fractional DPI. The
           enclosing strip owns its baseline; tabs never draw panel borders. */
        float scale = ui->scale > 0 ? ui->scale : 1;
        float x = ceilf(r.x * scale) / scale;
        float end = floorf((r.x + r.w) * scale) / scale;
        float bottom = floorf((r.y + r.h) * scale) / scale;
        cui_draw_rect(ui, (cui_rect){x, bottom - 2 / scale, end - x, 2 / scale}, CUI_CORNERS(0), CUI_C(ui, ACCENT));
    } else if (p->kind == 2 && p->hover > 0.01f) {
        cui_draw_rect(ui, r, CUI_CORNERS(0), cui_alpha(CUI_C(ui, HOVER), p->hover));
    } else if (p->kind == 0 && p->selected) {
        cui_draw_rect(ui, (cui_rect){r.x, r.y + 7, 2, r.h - 14}, CUI_CORNERS(1), CUI_C(ui, ACCENT));
    }
    if (p->focus) {
        float pixel = 1 / (ui->scale > 0 ? ui->scale : 1);
        cui_draw_rect_border(ui, r, CUI_CORNERS(p->kind == 0 ? KEST_RADIUS_CONTROL : 0), (cui_color){0}, CUI_C(ui, FOCUS_RING), pixel);
    }
}

bool kest_control_begin(cui_ctx *ui, const char *key, bool selected, float width, float height, int kind) {
    cui_id id = cui_make_id(ui, key);
    int flags = kind == 2 && !selected ? CUI_IF_KEEP_FOCUS : CUI_IF_FOCUSABLE;
    cui_interact hit = cui__interact(ui, id, flags);
    if (kind == 2 && hit.hovered && ui->mpressed[CUI_MOUSE_LEFT]) {
        ui->focus = id;
        ui->focus_visible = false;
    }
    /* Hover fades with CUI's own hover token, so app controls answer exactly
     * like CUI buttons; with motion off the tween snaps. */
    float *hover = cui_state(ui, id ^ 0x40E7u, sizeof(float));
    cui__tween(ui, hover, hit.hovered ? 1.0f : 0.0f, CUI__T_HOVER);
    cui_box box = {0};
    box.id = key;
    box.width = width < 0 ? CUI_FILL : width > 0 ? CUI_PX(width) : CUI_FIT;
    box.height = CUI_PX(height);
    box.clip = true;
    box.dir = CUI_ROW; box.align = CUI_ALIGN_CENTER;
    box.gap = KEST_SPACE_NORMAL; box.pad_x = kind == 0 ? KEST_SPACE_COMPACT : (kind == 3 && width > 0 && width <= 36) ? 0 : 10;
    if (kind == 3) box.justify = CUI_JUSTIFY_CENTER;
    box.radius = kind == 3 || kind == 0 ? KEST_RADIUS_CONTROL : 0;
    if ((kind == 0 || kind == 3) && selected) box.bg = CUI_C(ui, ACTIVE);
    else if (*hover > 0.01f && kind != 2) box.bg = cui_alpha(CUI_C(ui, HOVER), *hover);
    if (hit.focus_visible && kind != 2 && !(kind == 0 && selected)) { box.border = 1; box.border_color = CUI_C(ui, FOCUS_RING); }
    cui_box_begin(ui, &box);
    int at = ui->last_node;
    cui__mark_interactive(ui, at, flags);
    if (kind == 2 || (kind == 0 && selected)) {
        kest_control_paint *p = CUI_PAINT_DATA(ui, kest_control_paint);
        p->kind = kind; p->selected = selected; p->hover = *hover; p->focus = hit.focus_visible;
        ui->nodes[at].paint = paint_control;
        ui->nodes[at].paint_data = p;
    }
    if (hit.hovered) cui__set_cursor(ui, CUI_CURSOR_HAND);
    return hit.clicked;
}

bool kest_content_tab_begin(cui_ctx *ui, const char *key, bool selected) {
    /* One Tab stop per strip; arrows move focus and activate another section. */
    bool open = kest_control_begin(ui, key, selected, 0, KEST_CONTENT_TAB_HEIGHT, 2);
    kest_a11y_label_id(ui, cui_make_id(ui, key), KEST_A11Y_TAB, NULL, NULL);
    return open;
}

int kest_tab_navigation(cui_ctx *ui, const char *const *keys, int count, int selected) {
    if (count <= 0 || ui->mods) return selected;
    int layer_z = 0;
    for (int i = 0; i < ui->popup_count; i++)
        if (ui->popups[i].id == ui->current_layer) layer_z = ui->popups[i].z;
    for (int i = 0; i < ui->popup_count; i++)
        if (ui->popups[i].open && ui->popups[i].z > layer_z) return selected;
    if (ui->modal_layer && ui->modal_layer != ui->current_layer) return selected;
    if (ui->prev_modal_layer && ui->prev_modal_layer != ui->current_layer) return selected;
    int focused = -1;
    for (int i = 0; i < count; i++) if (ui->focus == cui_make_id(ui, keys[i])) { focused = i; break; }
    if (focused < 0) return selected;
    int to = focused;
    if (cui_key_pressed(ui, CUI_KEY_LEFT)) to = (focused + count - 1) % count;
    if (cui_key_pressed(ui, CUI_KEY_RIGHT)) to = (focused + 1) % count;
    if (cui_key_pressed(ui, CUI_KEY_HOME)) to = 0;
    if (cui_key_pressed(ui, CUI_KEY_END)) to = count - 1;
    if (to != focused) {
        ui->focus = cui_make_id(ui, keys[to]);
        ui->focus_visible = true;
        selected = to;
    }
    ui->kpressed[CUI_KEY_LEFT] = ui->kpressed[CUI_KEY_RIGHT] = 0;
    ui->kpressed[CUI_KEY_HOME] = ui->kpressed[CUI_KEY_END] = 0;
    return selected;
}

static void paint_document_dirty(cui_ctx *ui, cui_node *n, void *data) {
    (void)data;
    cui_draw_circle(ui, (cui_vec2){ n->rect.x + n->rect.w / 2, n->rect.y + n->rect.h / 2 }, 2.5f, CUI_C(ui, TEXT_SECONDARY));
}

cui_doc_tabs_result kest_doc_tabs_ex(cui_ctx *ui, const char *key, const kest_doc_tab *tabs, int count, int *selected) {
    cui_id *last_active = cui_state(ui, cui_make_id(ui, key) ^ 0x464F43u, sizeof(cui_id));
    cui_push_id(ui, key);
    cui_id details = cui_make_id(ui, "document-title-details") ^ 0x4C4Du;
    bool navigating = ui->mods || cui_key_pressed(ui, CUI_KEY_LEFT) || cui_key_pressed(ui, CUI_KEY_RIGHT) || cui_key_pressed(ui, CUI_KEY_HOME) || cui_key_pressed(ui, CUI_KEY_END) || cui_key_pressed(ui, CUI_KEY_TAB) || cui_key_pressed(ui, CUI_KEY_DELETE) || cui_key_pressed(ui, CUI_KEY_ESCAPE);
    if (navigating) cui__popup_set(ui, details, false);
    if (count > 0 && *selected >= 0 && *selected < count) {
        cui_id active = cui_make_id(ui, tabs[*selected].title);
        if (*last_active && ui->focus == *last_active && *last_active != active) {
            ui->focus = active; ui->focus_visible = true;
        }
    }
    cui_pop_id(ui);
    cui_doc_tab *native = cui__frame_alloc(ui, sizeof *native * (size_t)CUI_MAX(count, 1));
    for (int k = 0; k < count; k++) native[k] = (cui_doc_tab){ .title = tabs[k].title, .icon = tabs[k].method, .tooltip = tabs[k].tooltip && strlen(tabs[k].tooltip) < 256 ? tabs[k].tooltip : NULL, .dirty = tabs[k].dirty };
    int first = ui->node_count;
    int drawn_selected = *selected;
    cui_doc_tabs_result result = cui_doc_tabs_ex(ui, key, native, count, selected, NULL);
    cui_id strip = cui_make_id(ui, key) ^ 0xD0C7u;
    cui_rect viewport = cui__prev_rect(ui, strip);
    float max_width = viewport.w > 0 ? CUI_MAX(KEST_DOCUMENT_TAB_MIN, CUI_MIN(KEST_DOCUMENT_TAB_MAX, viewport.w - 2 * KEST_SPACE_COMPACT)) : KEST_DOCUMENT_TAB_MAX;
    /* The containing document row owns the single full-width baseline. */
    for (int i = first; i < ui->node_count; i++) if (ui->nodes[i].id == strip) {
        ui->nodes[i].paint = NULL; ui->nodes[i].paint_data = NULL;
    }
    cui_push_id(ui, key);
    cui_id *detail_anchor = cui_state(ui, details ^ 0x414Eu, sizeof(cui_id));
    int cursor = first;
    for (int k = 0; k < count; k++) {
        cui_id id = cui_make_id(ui, tabs[k].title);
        if (ui->hot == id) *detail_anchor = id;
        for (int i = cursor; i < ui->node_count; i++) if (ui->nodes[i].id == id) {
            cursor = i + 1;
            cui_node *n = &ui->nodes[i];
            n->h = CUI_PX(KEST_CONTENT_TAB_HEIGHT);
            n->min_w = KEST_DOCUMENT_TAB_MIN; n->max_w = max_width; n->gap = KEST_SPACE_COMPACT;
            n->border = 0; n->radius = CUI_CORNERS(0);
            if (k == drawn_selected) {
                kest_control_paint *p = CUI_PAINT_DATA(ui, kest_control_paint);
                p->kind = 1; p->selected = true; p->hover = 0; p->focus = ui->focus == id && ui->focus_visible;
                n->flags &= ~(uint32_t)CUI_NF_PAINT_AFTER;
                n->paint = paint_control; n->paint_data = p;
            }
            cui_id close_id = id ^ 0xC105Eu;
            int close_node = -1;
            {
                const char *label = tabs[k].label ? tabs[k].label : tabs[k].title;
                char spoken[192];
                snprintf(spoken, sizeof spoken, "%s%s%s%s", tabs[k].method ? tabs[k].method : "", tabs[k].method ? " " : "", label, tabs[k].dirty ? ", unsaved changes" : "");
                kest_a11y_label_id(ui, id, KEST_A11Y_TAB, spoken, NULL);
                snprintf(spoken, sizeof spoken, "Close %s", label);
                kest_a11y_label_id(ui, close_id, KEST_A11Y_BUTTON, spoken, NULL);
            }
            for (int child = n->first; child >= 0; child = ui->nodes[child].next) {
                cui_node *item = &ui->nodes[child];
                if (item->text && item->font == CUI_FONT_ICONS && tabs[k].method) {
                    item->font = CUI_FONT_MONO; item->font_size = KEST_TEXT_CAPTION;
                    item->text_len = (int)strlen(tabs[k].method);
                    item->text_color = cui_color_of(ui, tabs[k].method_color);
                    float width = cui__text_width(ui, item->font, item->font_size, item->text, item->text_len, false);
                    item->w = CUI_PX(CUI_MAX(KEST_METHOD_WIDTH, CUI_MIN(KEST_METHOD_MAX, width)));
                    item->min_w = item->w.value; item->flags |= CUI_NF_CLIP | CUI_NF_KEEP_W;
                } else if (item->text) {
                    if (tabs[k].label) { item->text = tabs[k].label; item->text_len = (int)strlen(tabs[k].label); }
                    item->w = CUI_FILL; item->min_w = 1;
                } else if (item->id == close_id) {
                    close_node = child;
                    bool show = k == drawn_selected || ui->hot == id || ui->hot == close_id || ui->focus == id;
                    for (int leaf = item->first; leaf >= 0; leaf = ui->nodes[leaf].next) {
                        cui_node *part = &ui->nodes[leaf];
                        part->opacity = part->font == CUI_FONT_ICONS && show ? 1 : 0;
                    }
                }
            }
            /* The dirty marker has a stable slot outside the close hit target. */
            cui__open(ui, i);
            int dot = cui__leaf(ui, id ^ 0xD17u, CUI_PX(KEST_DIRTY_SLOT), CUI_PX(KEST_DIRTY_SLOT));
            ui->nodes[dot].self_align = CUI_ALIGN_CENTER;
            ui->nodes[dot].paint = tabs[k].dirty ? paint_document_dirty : NULL;
            cui__close(ui);
            /* Put the marker immediately before the native close slot. Native
               identities and hit regions remain intact; only sibling order changes. */
            if (close_node >= 0) {
                int before = -1;
                for (int child = ui->nodes[i].first; child >= 0 && child != close_node; child = ui->nodes[child].next) before = child;
                if (before >= 0) ui->nodes[before].next = dot;
                else ui->nodes[i].first = dot;
                ui->nodes[dot].next = close_node;
                ui->nodes[close_node].next = -1;
                ui->nodes[i].last = close_node;
            }
            break;
        }
    }
    if (count > 0 && *selected >= 0 && *selected < count) {
        int active = result.move_from >= 0 ? drawn_selected : *selected;
        *last_active = cui_make_id(ui, tabs[active].title);
    }
    int detail_index = -1;
    for (int k = 0; k < count; k++) if (cui_make_id(ui, tabs[k].title) == *detail_anchor) detail_index = k;
    /* CUI's small tooltip has a 256-byte buffer. Longer names use one shared,
       bounded hover surface; never one popup allocation per open request. */
    if (!navigating && detail_index >= 0 && tabs[detail_index].tooltip && strlen(tabs[detail_index].tooltip) >= 256) {
        ui->last_id = *detail_anchor;
        if (cui_hover_card_begin(ui, "document-title-details", &(cui_hover_card_opts){ .width = CUI_MIN(520, ui->vw - 32), .delay = 0.55f })) {
            kest_document_list_begin(ui, "document-title-content", CUI_MIN(240, ui->vh - 120));
            cui_text_ex(ui, tabs[detail_index].tooltip, &(cui_text_opts){ .width = CUI_FILL, .size = KEST_TEXT_SECONDARY });
            cui_scroll_end(ui);
            cui_hover_card_end(ui);
        }
    } else cui__popup_set(ui, details, false);
    cui_pop_id(ui);
    return result;
}

bool kest_scrolling_menu_item(cui_ctx *ui, const char *label, const cui_menu_item_opts *opts, const char *scroll) {
    bool chosen = cui_menu_item_ex(ui, label, opts);
    if (ui->pb_depth > 0) {
        cui__popup_build *b = &ui->pb_stack[ui->pb_depth - 1];
        cui__menu_nav *nav = cui_state(ui, b->id ^ 0x4E4156u, sizeof *nav);
        if (nav->keyboard && nav->highlight == b->item_index - 1) kest_reveal(ui, cui_make_id(ui, scroll), cui_make_id(ui, label), false);
    }
    return chosen;
}

bool kest_document_menu_item(cui_ctx *ui, const char *identity, const char *label, bool checked, const char *scroll) {
    int first = ui->node_count;
    bool chosen = kest_scrolling_menu_item(ui, identity, &(cui_menu_item_opts){ .checked = checked }, scroll);
    cui_id id = cui_make_id(ui, identity);
    for (int i = first; i < ui->node_count; i++) {
        cui_node *n = &ui->nodes[i];
        if (n->id == id) { n->h = CUI_FIT; n->min_h = 32; n->pad[0] = n->pad[2] = 6; n->flags |= CUI_NF_CLIP; }
        if (n->text && n->font != CUI_FONT_ICONS) {
            n->text = label; n->text_len = (int)strlen(label);
            n->flags |= CUI_NF_WRAP; n->min_w = 1;
        }
    }
    ui->last_id = id;
    cui_tooltip(ui, label);
    return chosen;
}

void kest_document_list_begin(cui_ctx *ui, const char *key, float max_height) {
    cui_scroll_begin(ui, &(cui_scroll_opts){ .id = key, .width = CUI_FILL, .height = CUI_PX(max_height) });
    cui_node *n = &ui->nodes[cui__current(ui)];
    n->h = CUI_FIT; n->max_h = max_height;
}

typedef struct { bool horizontal, handle; int divider; cui_color color; } kest_boundary_paint;
static void paint_boundary(cui_ctx *ui, cui_node *n, void *raw) {
    kest_boundary_paint *p = raw;
    cui_rect r = n->rect;
    if (p->handle && p->divider >= 0) r = ui->nodes[p->divider].rect;
    float scale = ui->scale > 0 ? ui->scale : 1;
    float x = ceilf(r.x * scale) / scale, y = ceilf(r.y * scale) / scale;
    if (p->horizontal) y = floorf(r.y * scale) / scale;
    else x = floorf(r.x * scale) / scale;
    float end_x = floorf((r.x + r.w) * scale) / scale;
    float end_y = floorf((r.y + r.h) * scale) / scale;
    if (p->handle) {
        if (ui->hot != n->id && ui->active != n->id) return;
        /* A short grip at the center cannot paint over header intersections. */
        if (p->horizontal) { x = roundf((r.x + r.w * 0.5f - 16) * scale) / scale; end_x = x + 32; }
        else { y = roundf((r.y + r.h * 0.5f - 16) * scale) / scale; end_y = y + 32; }
    }
    cui_rect line = p->horizontal ? (cui_rect){x, y, end_x - x, 1 / scale} : (cui_rect){x, y, 1 / scale, end_y - y};
    cui_draw_rect(ui, line, CUI_CORNERS(0), p->color);
}

static kest_boundary_paint *boundary(cui_ctx *ui, int node, bool horizontal, bool handle) {
    kest_boundary_paint *p = CUI_PAINT_DATA(ui, kest_boundary_paint);
    p->horizontal = horizontal; p->handle = handle; p->divider = -1;
    p->color = handle ? CUI_C(ui, ACCENT) : CUI_C(ui, BORDER);
    ui->nodes[node].paint = paint_boundary; ui->nodes[node].paint_data = p;
    ui->nodes[node].bg.a = 0;
    return p;
}

void kest_separator(cui_ctx *ui, const char *key, bool vertical) {
    float pixel = 1 / (ui->scale > 0 ? ui->scale : 1);
    int node = cui__leaf(ui, cui_make_id(ui, key), vertical ? CUI_PX(pixel) : CUI_FILL, vertical ? CUI_FILL : CUI_PX(pixel));
    boundary(ui, node, !vertical, false);
}

void kest_split_next(cui_ctx *ui, const char *key, bool vertical) {
    cui_split_next(ui);
    cui_id id = cui_make_id(ui, key);
    float pixel = 1 / (ui->scale > 0 ? ui->scale : 1);
    int handle = -1;
    for (int i = ui->node_count - 1; i >= 0; i--) {
        cui_node *n = &ui->nodes[i];
        if (n->id == (id ^ 0x78u)) {
            if (vertical) n->h = CUI_PX(pixel); else n->w = CUI_PX(pixel);
            boundary(ui, i, vertical, false);
            if (handle >= 0) boundary(ui, handle, vertical, true)->divider = i;
            break;
        }
        if (n->id == (id ^ 0x77u)) handle = i;
    }
}

cui_path_bar_result kest_path_bar_ex(cui_ctx *ui, const char *key, const char *const *segments, int count, const cui_path_bar_opts *opts) {
    int first = ui->node_count;
    cui_path_bar_result result = cui_path_bar_ex(ui, key, segments, count, opts);
    cui_id id = cui_make_id(ui, key);
    for (int i = first; i < ui->node_count; i++) if (ui->nodes[i].id == id) {
        ui->nodes[i].border = 0; ui->nodes[i].bg.a = 0;
        ui->nodes[i].radius = CUI_CORNERS(0);
        break;
    }
    return result;
}

int kest_flat_input(cui_ctx *ui, const char *key, char *buf, size_t cap, const cui_input_opts *opts, bool cell) {
    cui_id id = cui_make_id(ui, key);
    if (opts && opts->autofocus) ui->focus = id;
    int first = ui->node_count;
    int flags = cui__text_field(ui, id, buf, cap, opts, false, 1, NULL);
    kest_a11y_label_id(ui, id, KEST_A11Y_EDIT, opts ? (opts->label ? opts->label : opts->placeholder) : NULL, buf);
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

static bool table_keys_allowed(cui_ctx *ui) {
    if (ui->prev_modal_layer && ui->prev_modal_layer != ui->current_layer) return false;
    int z = 0;
    for (int i = 0; i < ui->popup_count; i++) if (ui->popups[i].id == ui->current_layer) z = ui->popups[i].z;
    for (int i = 0; i < ui->popup_count; i++) if (ui->popups[i].open && ui->popups[i].z > z) return false;
    return true;
}

typedef struct { cui_id slots[32]; bool toasts_paused; } table_popup_owners;
#define KEST_TABLE_POPUPS 0x4B565055u
static void table_popup_register(cui_ctx *ui, cui_id id) {
    table_popup_owners *owners = cui_state(ui, KEST_TABLE_POPUPS, sizeof *owners);
    for (int i = 0; i < ui->popup_count; i++) if (ui->popups[i].id == id) owners->slots[i] = id;
}
void kest_table_popup_cleanup(cui_ctx *ui) {
    cui_state_entry *entry = cui__state_entry(ui, KEST_TABLE_POPUPS);
    if (entry->size != sizeof(table_popup_owners)) return;
    table_popup_owners *owners = entry->data;
    for (int i = 0; i < ui->popup_count; i++) {
        cui_popup *p = &ui->popups[i];
        if (p->open && owners->slots[i] == p->id && p->last_frame < ui->frame && p->opened_frame < ui->frame) {
            p->open = false; p->s.x = p->s.v = 0;
            cui_request_redraw(ui);
        }
    }
}

void kest_end_frame(cui_ctx *ui) {
    kest_table_popup_cleanup(ui);
    cui_state_entry *entry = cui__state_entry(ui, KEST_TABLE_POPUPS);
    if (entry->size != sizeof(table_popup_owners)) { cui_end_frame(ui); return; }
    table_popup_owners *owners = entry->data;
    bool table_open = false;
    for (int i = 0; i < ui->popup_count; i++)
        if (ui->popups[i].open && owners->slots[i] == ui->popups[i].id) table_open = true;
    /* CUI's toast surface is above menus and owns its whole rectangle. Defer
       its presentation while a table action is active, preserving every item.
       On resume do not charge the closing frame's potentially long idle dt to
       queued notifications. Other frames retain native timing unchanged. */
    int count = ui->toast_count;
    float dt = ui->dt;
    if (table_open) ui->toast_count = 0;
    else if (owners->toasts_paused) ui->dt = 0;
    cui_end_frame(ui);
    ui->dt = dt;
    if (table_open) ui->toast_count = count;
    owners->toasts_paused = table_open;
}

int kest_table_input(cui_ctx *ui, const char *key, char *buf, size_t cap, const cui_input_opts *opts) {
    cui_id id = cui_make_id(ui, key), focused = ui->focus;
    bool covered = !table_keys_allowed(ui);
    cui_input_opts input = *opts;
    if (covered) input.autofocus = false;
    if (covered && focused == id) ui->focus = 0;
    int result = kest_flat_input(ui, key, buf, cap, &input, true);
    if (covered && focused == id) ui->focus = focused;
    if (!covered && ui->focus == id) ui->tab_owner = id;
    return result;
}

int kest_table_bulk_input(cui_ctx *ui, char *buf, size_t cap, bool focus) {
    int first = ui->node_count;
    int result = cui_textarea_ex(ui, "bulk", buf, cap, &(cui_input_opts){ .height = -1, .autofocus = focus, .placeholder = "key: value\n# disabled: value\nQuote exact strings when needed" });
    ui->nodes[first].min_h = KEST_TABLE_ROW;
    return result;
}

static cui_id table_cell_id(cui_ctx *ui, unsigned row, int column) {
    cui_push_id_int(ui, (int)row);
    cui_id id = cui_make_id(ui, column ? "value" : "key");
    cui_pop_id(ui);
    return id;
}

void kest_table_focus(cui_ctx *ui, unsigned row, int column, int index) {
    ui->focus = table_cell_id(ui, row, column);
    ui->focus_visible = true;
    ui->tab_owner = ui->focus;
    cui_scroll_state *s = cui_state(ui, cui_make_id(ui, "kv-rows"), sizeof *s);
    float top = (float)index * KEST_TABLE_STRIDE;
    s->content_h = CUI_MAX(s->content_h, top + KEST_TABLE_STRIDE);
    if (top < s->ty) s->ty = top;
    else if (top + KEST_TABLE_STRIDE > s->ty + s->view_h) s->ty = CUI_MAX(0, top + KEST_TABLE_STRIDE - s->view_h);
    s->y = s->ty;
}

int kest_table_navigation(cui_ctx *ui, const unsigned *rows, int count) {
    if (!table_keys_allowed(ui) || (ui->mods & ~CUI_MOD_SHIFT)) return -1;
    bool tab = cui_key_pressed(ui, CUI_KEY_TAB), enter = cui_key_pressed(ui, CUI_KEY_ENTER);
    bool up = cui_key_pressed(ui, CUI_KEY_UP), down = cui_key_pressed(ui, CUI_KEY_DOWN);
    if (!tab && !enter && !up && !down) return -1;
    int current = -1;
    for (int i = 0; i < count && current < 0; i++) for (int col = 0; col < 2; col++)
        if (ui->focus == table_cell_id(ui, rows[i], col)) { current = i * 2 + col; break; }
    if (current < 0) return -1;
    int target = current + (up ? -2 : down ? 2 : (ui->mods & CUI_MOD_SHIFT) ? -1 : 1);
    if (target >= 0 && target < count * 2) kest_table_focus(ui, rows[target / 2], target % 2, target / 2);
    else if (tab || enter) {
        /* Exit the cell sequence through native focus order, skipping the row's
           checkbox/actions. Those remain available by pointer and Alt+Down. */
        int at = -1, direction = target < 0 ? -1 : 1;
        for (int i = 0; i < ui->prev_focus_count; i++) if (ui->prev_focus_order[i] == ui->focus) at = i;
        for (int step = 1; at >= 0 && step < ui->prev_focus_count; step++) {
            int i = (at + direction * step + ui->prev_focus_count) % ui->prev_focus_count;
            if (ui->prev_modal_layer && ui->prev_focus_layers[i] != ui->prev_modal_layer) continue;
            cui_id candidate = ui->prev_focus_order[i];
            bool owned = false;
            for (int r = 0; r < count && !owned; r++) {
                cui_push_id_int(ui, (int)rows[r]);
                const char *keys[] = { "key", "value", "###enabled", "###file", "row-actions", "field-type", "choose-field-file" };
                for (int k = 0; k < 7; k++) if (candidate == (cui_make_id(ui, keys[k]) ^ ((k == 2 || k == 3) ? 0xC0EC0001u : 0))) owned = true;
                cui_pop_id(ui);
            }
            if (!owned) { ui->focus = candidate; ui->focus_visible = true; ui->tab_owner = 0; break; }
        }
    }
    ui->kpressed[CUI_KEY_TAB] = ui->kpressed[CUI_KEY_ENTER] = 0;
    ui->kpressed[CUI_KEY_UP] = ui->kpressed[CUI_KEY_DOWN] = 0;
    return target >= 0 && target < count * 2 ? target : -1;
}

/* Close only header-owned surfaces when the immutable shown source changes.
   Unrelated request editors/popups keep their focus and lifetime. */
static void close_header_popup(cui_ctx *ui, cui_id id, cui_id restore_focus) {
    cui_popup *popup = cui__popup_get(ui, id, false);
    if (popup && popup->open) {
        bool topmost = true;
        for (int i = 0; i < ui->popup_count; ++i)
            if (ui->popups[i].open && ui->popups[i].z > popup->z) topmost = false;
        if (ui->prev_modal_layer == id || (!ui->prev_modal_layer && topmost)) {
            ui->focus = restore_focus; ui->focus_visible = true; ui->tab_owner = 0;
        }
        popup->open = false; popup->s.x = popup->s.v = 0;
        cui_request_redraw(ui);
    }
}
void kest_response_header_source(cui_ctx *ui, const void *source, int count) {
    typedef struct { const void *source; int count; } header_source;
    header_source *last = cui_state(ui, cui_make_id(ui, "response-header-source"), sizeof *last);
    if (last->source && last->source != source) {
        cui_id restore_focus = cui_make_id(ui, "response-headers");
        close_header_popup(ui, cui_make_id(ui, "table-actions") ^ 0x3E40u, restore_focus);
        close_header_popup(ui, cui_make_id(ui, "response-header-details"), restore_focus);
        for (int i = 0; i < last->count; ++i) {
            cui_push_id_int(ui, i);
            close_header_popup(ui, cui_make_id(ui, "row-actions") ^ 0x3E40u, restore_focus);
            cui_pop_id(ui);
        }
    }
    last->source = source; last->count = count;
}

/* Immutable received rows use consecutive identities. No per-frame id array. */
int kest_response_header_navigation(cui_ctx *ui, int count) {
    if (!table_keys_allowed(ui)) return -1;
    bool tab = cui_key_pressed(ui, CUI_KEY_TAB);
    bool up = cui_key_pressed(ui, CUI_KEY_UP), down = cui_key_pressed(ui, CUI_KEY_DOWN);
    bool page_up = cui_key_pressed(ui, CUI_KEY_PAGE_UP), page_down = cui_key_pressed(ui, CUI_KEY_PAGE_DOWN);
    bool home = ui->mods == CUI_MOD_PRIMARY && cui_key_pressed(ui, CUI_KEY_HOME);
    bool end = ui->mods == CUI_MOD_PRIMARY && cui_key_pressed(ui, CUI_KEY_END);
    if ((!home && !end && (ui->mods & ~CUI_MOD_SHIFT)) || (!tab && !up && !down && !page_up && !page_down && !home && !end)) return -1;
    int current = -1;
    for (int i = 0; i < count && current < 0; ++i) for (int col = 0; col < 2; ++col)
        if (ui->focus == table_cell_id(ui, (unsigned)i, col)) { current = i * 2 + col; break; }
    if (current < 0) return -1;
    cui_scroll_state *s = cui_state(ui, cui_make_id(ui, "response-header-rows"), sizeof *s);
    int page = CUI_MAX(1, (int)(s->view_h / KEST_TABLE_STRIDE));
    int target = home ? current % 2 : end ? (count - 1) * 2 + current % 2 :
        current + (page_up ? -page * 2 : page_down ? page * 2 : up ? -2 : down ? 2 : (ui->mods & CUI_MOD_SHIFT) ? -1 : 1);
    if (!tab) target = CUI_CLAMP(target / 2, 0, count - 1) * 2 + current % 2;
    if (target < 0 || target >= count * 2) {
        /* Leave cell ownership before fields build again. Otherwise their
           native tab_owner would trap Tab at the table's first/last cell. */
        int at = -1, direction = target < 0 ? -1 : 1;
        for (int i = 0; i < ui->prev_focus_count; ++i) if (ui->prev_focus_order[i] == ui->focus) at = i;
        for (int step = 1; at >= 0 && step < ui->prev_focus_count; ++step) {
            int i = (at + direction * step + ui->prev_focus_count) % ui->prev_focus_count;
            if (ui->prev_modal_layer && ui->prev_focus_layers[i] != ui->prev_modal_layer) continue;
            ui->focus = ui->prev_focus_order[i]; ui->focus_visible = true;
            ui->tab_owner = 0; ui->kpressed[CUI_KEY_TAB] = 0;
            break;
        }
        return -1;
    }
    ui->focus = table_cell_id(ui, (unsigned)(target / 2), target % 2);
    ui->focus_visible = true; ui->tab_owner = ui->focus;
    float top = (float)(target / 2) * KEST_TABLE_STRIDE;
    s->content_h = CUI_MAX(s->content_h, top + KEST_TABLE_STRIDE);
    if (top < s->ty) s->ty = top;
    else if (top + KEST_TABLE_STRIDE > s->ty + s->view_h) s->ty = CUI_MAX(0, top + KEST_TABLE_STRIDE - s->view_h);
    s->y = s->ty;
    ui->kpressed[CUI_KEY_TAB] = ui->kpressed[CUI_KEY_UP] = ui->kpressed[CUI_KEY_DOWN] = 0;
    ui->kpressed[CUI_KEY_PAGE_UP] = ui->kpressed[CUI_KEY_PAGE_DOWN] = 0;
    if (home) ui->kpressed[CUI_KEY_HOME] = 0;
    if (end) ui->kpressed[CUI_KEY_END] = 0;
    return target;
}

static void paint_table_row(cui_ctx *ui, cui_node *n, void *raw) {
    (void)raw;
    float scale = ui->scale > 0 ? ui->scale : 1;
    float y = floorf((n->rect.y + n->rect.h) * scale) / scale - 1 / scale;
    cui_draw_rect(ui, (cui_rect){n->rect.x, y, n->rect.w, 1 / scale}, CUI_CORNERS(0), CUI_C(ui, BORDER_SUBTLE));
}

void kest_table_row_begin(cui_ctx *ui) {
    cui_id id = cui_make_id(ui, "kv-row");
    cui_rect r = cui__prev_rect(ui, id);
    bool hovered = ui->hot_layer == ui->current_layer && cui__rect_contains(r, ui->mx, ui->my);
    bool focused = ui->focus == cui_make_id(ui, "key") || ui->focus == cui_make_id(ui, "value");
    cui_row_begin(ui, &(cui_box){ .id = "kv-row", .height = CUI_PX(KEST_TABLE_STRIDE), .width = CUI_FILL, .align = CUI_ALIGN_CENTER, .bg = hovered ? CUI_C(ui, HOVER) : focused ? CUI_C(ui, SURFACE_MUTED) : (cui_color){0} });
    ui->nodes[ui->last_node].paint = paint_table_row;
    ui->nodes[ui->last_node].flags |= CUI_NF_PAINT_AFTER;
}

bool kest_table_menu_begin(cui_ctx *ui, const char *key, bool row, const char *notice, cui_color color) {
    cui_id id = cui_make_id(ui, key), pid = id ^ 0x3E40u;
    cui_popup *popup = cui__popup_get(ui, pid, false);
    bool allowed = table_keys_allowed(ui) || (popup && popup->open);
    cui_rect bounds = cui__prev_rect(ui, cui_make_id(ui, "kv-row"));
    bool hover = ui->hot_layer == ui->current_layer && cui__rect_contains(bounds, ui->mx, ui->my);
    bool cell_focus = ui->focus == cui_make_id(ui, "key") || ui->focus == cui_make_id(ui, "value") || ui->focus == (cui_make_id(ui, "###enabled") ^ 0xC0EC0001u);
    bool keyboard = ((!popup || !popup->open) && ui->focus == id && ui->mods == 0 && cui_key_pressed(ui, CUI_KEY_DOWN)) ||
        (row && (cell_focus || ui->focus == id) && ((ui->mods == CUI_MOD_ALT && cui_key_pressed(ui, CUI_KEY_DOWN)) || (ui->mods == CUI_MOD_SHIFT && cui_key_pressed(ui, CUI_KEY_F10))));
    bool context = row && hover && ui->mpressed[CUI_MOUSE_RIGHT];
    int first = ui->node_count;
    bool clicked = kest_control_begin(ui, key, false, KEST_TABLE_ACTIONS, row ? KEST_TABLE_ROW : KEST_TABLE_HEADER, 3);
    cui_icon(ui, notice ? CUI_ICON_TRIANGLE_ALERT : CUI_ICON_ELLIPSIS, KEST_ICON_SMALL, color);
    kest_item_end(ui);
    ui->nodes[first].opacity = !row || notice || hover || cell_focus || ui->focus == id || (popup && popup->open) ? 1 : 0;
    cui_tooltip(ui, notice ? notice : row ? "Row actions (Alt Down or Shift F10)" : "Table actions");
    kest_a11y_label_id(ui, id, KEST_A11Y_MENU_BUTTON, row ? "Row actions" : "Table actions", NULL);
    kest_a11y_help_id(ui, id, notice);
    bool activate = clicked && !(popup && popup->open && (cui_key_pressed(ui, CUI_KEY_ENTER) || cui_key_pressed(ui, CUI_KEY_SPACE)));
    if (allowed && (activate || keyboard || context)) {
        bool open = keyboard || context || !(popup && popup->open);
        if (open) cui__close_all_popups(ui);
        cui__popup_set(ui, pid, open);
        popup = cui__popup_get(ui, pid, false);
        if (popup) { popup->at_mouse = context; popup->mouse = (cui_vec2){ui->mx, ui->my}; }
        if (keyboard) {
            ui->focus = id; ui->focus_visible = true; ui->kpressed[CUI_KEY_DOWN] = ui->kpressed[CUI_KEY_F10] = 0;
            cui__menu_nav *nav = cui_state(ui, pid ^ 0x4E4156u, sizeof *nav);
            nav->highlight = 0; nav->keyboard = true;
        }
    }
    bool open = cui__popup_begin(ui, pid, id, CUI_PLACE_BOTTOM_END, 220, 6, 0, true);
    table_popup_register(ui, pid);
    return open;
}

bool kest_table_details_begin(cui_ctx *ui, const char *key) {
    return kest_inspector_begin(ui, key, "table-actions", 520);
}

bool kest_inspector_begin(cui_ctx *ui, const char *key, const char *anchor, float width) {
    cui_id id = cui_make_id(ui, key);
    bool open = cui__popup_begin(ui, id, cui_make_id(ui, anchor), CUI_PLACE_BOTTOM_END, CUI_MIN(width, ui->vw - 32), 12, 8, true);
    table_popup_register(ui, id);
    return open;
}

void kest_popup_track(cui_ctx *ui, const char *trigger) {
    table_popup_register(ui, cui_make_id(ui, trigger) ^ 0x3E40u);
}

/* CUI has 32 popup slots. A closed, never-used row menu must not reserve one:
 * a long collection tree can otherwise prevent the method/body pickers opening.
 * Keep CUI's keyboard/menu behavior, and create a slot only on activation. */
bool kest_dropdown_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts) {
    cui_menu_opts defaults = {0};
    if (!opts) opts = &defaults;
    cui_id popup_id = cui_make_id(ui, label) ^ 0x3E40u;
    cui_popup *popup = cui__popup_get(ui, popup_id, false);
    cui_button_opts button = {0};
    button.size = CUI_SIZE_SM;
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
    kest_a11y_label_id(ui, anchor, KEST_A11Y_MENU_BUTTON, label, NULL);
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

bool kest_menu_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts, float width, float height, cui_color color) {
    int first = ui->node_count;
    bool open = kest_dropdown_begin(ui, label, opts);
    /* cui_menu_begin constructs its trigger first, followed by its label/icon. */
    if (first < ui->node_count) {
        cui_node *n = &ui->nodes[first];
        if (width > 0) n->w = CUI_PX(width);
        n->h = CUI_PX(height);
        n->border = 0; n->radius = CUI_CORNERS(KEST_RADIUS_CONTROL);
        for (int i = first + 1; i < ui->node_count && ui->nodes[i].parent == first; i++)
            ui->nodes[i].text_color = cui_color_of(ui, color);
        if (width > 0) {
            n->flags |= CUI_NF_CLIP;
            for (int i = first + 1; i < ui->node_count && ui->nodes[i].parent == first; i++) {
                cui_node *child = &ui->nodes[i];
                if (child->text && child->font != CUI_FONT_ICONS) { child->w = CUI_FILL; child->min_w = 1; }
            }
        }
    }
    return open;
}

bool kest_method_menu_begin(cui_ctx *ui, const char *method, cui_color color) {
    int first = ui->node_count;
    bool open = kest_menu_begin(ui, "HTTP method###http-method", &(cui_menu_opts){ .width = 240, .variant = CUI_BUTTON_GHOST }, KEST_COMPOSER_METHOD, KEST_CONTROL_LARGE, color);
    cui_node *n = &ui->nodes[first];
    n->pad[1] = n->pad[3] = 8; n->gap = 6;
    float size = KEST_TEXT_SECONDARY * ui->theme.font_scale;
    float width = cui__text_width(ui, CUI_FONT_MONO, size, method, (int)strlen(method), false);
    for (int child = n->first; child >= 0; child = ui->nodes[child].next) {
        cui_node *label = &ui->nodes[child];
        if (!label->text || label->font == CUI_FONT_ICONS) continue;
        /* Arbitrary custom tokens must not grow the toolbar or show half a
           method. The menu retains the full value and its editable field. */
        label->text = width <= KEST_COMPOSER_METHOD - 38 ? method : "Custom";
        label->text_len = (int)strlen(label->text);
        label->font = CUI_FONT_MONO; label->font_size = size;
    }
    return open;
}

void kest_url_invalid(cui_ctx *ui, bool invalid) {
    int group = cui__current(ui);
    if (invalid && group >= 0) ui->nodes[group].border_color = CUI_C(ui, DANGER);
}

bool kest_button_ex(cui_ctx *ui, const char *label, const cui_button_opts *opts) {
    int first = ui->node_count;
    bool clicked = cui_button_ex(ui, label, opts);
    /* Icon-only buttons ("###key") are named by their tooltip. */
    kest_a11y_label_id(ui, ui->nodes[first].id, KEST_A11Y_BUTTON, NULL, NULL);
    if (opts) kest_a11y_help_id(ui, ui->nodes[first].id, opts->tooltip);
    if (opts && (opts->variant == CUI_BUTTON_PRIMARY || opts->variant == CUI_BUTTON_DANGER)) {
        ui->nodes[first].paint = NULL;
        ui->nodes[first].paint_data = NULL;
        if (ui->focus == ui->nodes[first].id && ui->focus_visible && !opts->disabled) {
            kest_control_paint *p = CUI_PAINT_DATA(ui, kest_control_paint);
            *p = (kest_control_paint){ .kind = 3, .focus = true };
            ui->nodes[first].paint = paint_control;
            ui->nodes[first].paint_data = p;
        }
    }
    return clicked;
}

static bool request_key_once(cui_ctx *ui, cui_key key) {
    typedef struct { uint64_t frame; bool held, pressed; } request_key_state;
    /* Shared by shell, URL field and execution buttons, independent of the
       active request's id scope. Editing elsewhere retains native key repeat. */
    cui_id id = cui__hash(&key, sizeof key, 0x5245514Bu);
    request_key_state *s = cui_state(ui, id, sizeof *s);
    if (s->frame != ui->frame) {
        s->frame = ui->frame;
        s->pressed = cui_key_pressed(ui, key) && !s->held;
        s->held = cui_key_down(ui, key);
    }
    return s->pressed;
}

bool kest_request_enter(cui_ctx *ui) { return request_key_once(ui, CUI_KEY_ENTER); }

bool kest_request_shortcut(cui_ctx *ui) {
    bool first = kest_request_enter(ui);
    if (!cui_shortcut(ui, CUI_MOD_PRIMARY, CUI_KEY_ENTER)) return false;
    /* The global shortcut owns this event, including repeat events. Native
       focused buttons must not activate a second time from the same Enter. */
    ui->kpressed[CUI_KEY_ENTER] = 0;
    return first;
}

bool kest_request_button(cui_ctx *ui, const char *label, const cui_button_opts *opts) {
    cui_button_opts button = *opts;
    button.size = CUI_SIZE_MD;
    bool enter = kest_request_enter(ui), space = request_key_once(ui, CUI_KEY_SPACE);
    uint8_t old_enter = ui->kpressed[CUI_KEY_ENTER], old_space = ui->kpressed[CUI_KEY_SPACE];
    if (!enter || ui->mods) ui->kpressed[CUI_KEY_ENTER] = 0;
    if (!space || ui->mods) ui->kpressed[CUI_KEY_SPACE] = 0;
    int first = ui->node_count;
    bool clicked = kest_button_ex(ui, label, &button);
    ui->kpressed[CUI_KEY_ENTER] = old_enter; ui->kpressed[CUI_KEY_SPACE] = old_space;
    ui->nodes[first].h = CUI_PX(KEST_CONTROL_LARGE);
    ui->nodes[first].pad[1] = ui->nodes[first].pad[3] = 10;
    return clicked;
}

bool kest_select_ex(cui_ctx *ui, const char *key, const char *const *items, int count, int *index, const cui_select_opts *opts) {
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

bool kest_reveal(cui_ctx *ui, cui_id id, cui_id target, bool horizontal) {
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
