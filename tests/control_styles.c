/* Render and exercise shared tabs without a native window or real OS input. */
#include "host.h"
#include "cui_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "control styles: line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static const char *keys[] = { "first", "second", "third" };
static const char *document_label = "A literal ## and ### request with a deliberately long, complete name";
static const char *document_tooltip =
    "GET A literal ## and ### request with a deliberately long, complete name. "
    "This request name continues beyond the native tooltip's fixed buffer. "
    "Every part of the name must remain readable rather than silently losing its tail. "
    "A bounded scrollable hover surface retains the complete UTF-8 content, "
    "including this final suffix: COMPLETE REQUEST NAME.";
static int frame(cui_ctx *ui, int selected) {
    cui_begin_frame(ui, 1.0f / 60);
    cui_theme_get(ui)->colors[CUI_TOKEN_ACCENT] = (cui_color){ 255, 0, 255, 255 };
    selected = kest_tab_navigation(ui, keys, 3, selected);
    cui_column_begin(ui, &(cui_box){ .pad_left = 0.25f, .pad_top = 0.25f });
    cui_row_begin(ui, &(cui_box){ .height = CUI_PX(KEST_CONTENT_TAB_HEIGHT) });
    for (int i = 0; i < 3; i++) {
        if (kest_content_tab_begin(ui, keys[i], selected == i)) selected = i;
        cui_text(ui, i == 0 ? "Params" : i == 1 ? "Body" : "Headers");
        kest_item_end(ui);
    }
    cui_box_end(ui);
    cui_separator(ui);
    kest_doc_tab docs[] = {
        { .title = "GET request", .label = document_label, .method = "GET", .method_color = CUI_COLOR_SUCCESS, .dirty = true,
          .tooltip = document_tooltip },
        { .title = "POST request", .label = "Request", .method = "OPTIONS", .method_color = CUI_COLOR_INFO }
    };
    int document = 0;
    kest_doc_tabs_ex(ui, "docs", docs, 2, &document);
    cui_box_end(ui);
    cui_end_frame(ui);
    return selected;
}

static int accent_height(const unsigned char *pixels, int width, int height, int x, int y, int radius) {
    int count = 0;
    for (int row = y - radius; row <= y + radius; row++) {
        if (row < 0 || row >= height) continue;
        const unsigned char *p = pixels + (row * width + x) * 4;
        if (p[0] == 255 && p[1] == 0 && p[2] == 255) count++;
    }
    return count;
}

static void split_frame(cui_ctx *ui, bool stacked, float *ratio) {
    cui_begin_frame(ui, 1.0f / 60);
    cui_theme_get(ui)->colors[CUI_TOKEN_BORDER] = (cui_color){255, 0, 255, 255};
    cui_theme_get(ui)->colors[CUI_TOKEN_ACCENT] = (cui_color){255, 0, 255, 255};
    cui_column_begin(ui, &(cui_box){ .width = CUI_FILL, .height = CUI_FILL, .pad_left = 0.25f, .pad_top = 0.25f });
    cui_split_begin(ui, "split", ratio, &(cui_split_opts){ .vertical = stacked, .min_first = 40, .min_second = 40, .width = CUI_FILL, .height = CUI_FILL });
    cui_column_begin(ui, &(cui_box){ .width = CUI_FILL, .height = CUI_FILL, .bg = CUI_COLOR_SURFACE });
    cui_text(ui, "First pane");
    kest_separator(ui, "first-boundary", false);
    cui_box_end(ui);
    kest_split_next(ui, "split", stacked);
    cui_column_begin(ui, &(cui_box){ .width = CUI_FILL, .height = CUI_FILL, .bg = CUI_COLOR_SURFACE });
    cui_text(ui, "Second pane");
    kest_separator(ui, "second-boundary", false);
    cui_box_end(ui);
    cui_split_end(ui);
    cui_box_end(ui);
    cui_end_frame(ui);
}

static void idle_frame(cui_ctx *ui, char *text) {
    cui_begin_frame(ui, 1.0f / 60);
    cui_column_begin(ui, &(cui_box){ .width = CUI_FILL, .height = CUI_FILL });
    cui_input_ex(ui, "idle-field", text, 32, &(cui_input_opts){ .width = CUI_PX(200) });
    cui_button_ex(ui, "Tooltip anchor", &(cui_button_opts){ .tooltip = "A tooltip while an input retains focus" });
    cui_scroll_begin(ui, &(cui_scroll_opts){ .id = "idle-scroll", .width = CUI_PX(200), .height = CUI_PX(32) });
    cui_text(ui, "Scrollable\ncontent\nwith\na\nfade\ndeadline");
    cui_scroll_end(ui);
    cui_box_end(ui);
    cui_end_frame(ui);
    kest_quiet_caret(ui);
}

static bool composer_frame(cui_ctx *ui, const char *method, char *url, size_t cap, bool disabled) {
    cui_begin_frame(ui, 1.0f / 60);
    cui_row_begin(ui, &(cui_box){ .width = CUI_PX(520), .height = CUI_PX(38), .gap = 8, .align = CUI_ALIGN_CENTER });
    if (kest_method_menu_begin(ui, method, CUI_COLOR_SUCCESS)) cui_menu_end(ui);
    kest_flat_input(ui, "composer-url", url, cap, &(cui_input_opts){ .width = CUI_FILL, .size = CUI_SIZE_LG }, false);
    kest_request_button(ui, "Save •###composer-save", &(cui_button_opts){ .width = CUI_PX(KEST_COMPOSER_SAVE) });
    bool clicked = kest_request_button(ui, "Cancel###composer-send", &(cui_button_opts){ .variant = CUI_BUTTON_DANGER, .disabled = disabled, .width = CUI_PX(KEST_COMPOSER_SEND), .icon_right = CUI_ICON_SQUARE });
    cui_box_end(ui);
    cui_end_frame(ui);
    return clicked;
}

static const char *composer_clipboard(void *user) { (void)user; return "https://pasted.invalid/path?one=two"; }

static int composer_checks(cui_ctx *ui, cui_sw_renderer *sw) {
    const char *methods[] = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "PROPFIND", "A-VERY-LONG-###-CUSTOM-METHOD" };
    float scales[] = { 1, 1.25f, 1.5f, 2 };
    char url[8192] = "https://example.invalid/";
    cui_input_mouse_move(ui, -10, -10);
    for (int dark = 0; dark < 2; dark++) for (int scale = 0; scale < 4; scale++) {
        cui_set_theme(ui, dark ? CUI_THEME_DARK : CUI_THEME_LIGHT);
        cui_set_viewport(ui, 640, 240, scales[scale]);
        for (int m = 0; m < 9; m++) {
            composer_frame(ui, methods[m], url, sizeof url, false);
            composer_frame(ui, methods[m], url, sizeof url, false);
            bool label_found = false;
            for (int i = 0; i < ui->node_count; i++) {
                cui_node *n = &ui->nodes[i];
                if (n->id == cui_make_id(ui, "###http-method")) {
                    CHECK(n->rect.w == KEST_COMPOSER_METHOD && n->rect.h == KEST_CONTROL_LARGE);
                    for (int child = n->first; child >= 0; child = ui->nodes[child].next) {
                        cui_node *label = &ui->nodes[child];
                        if (!label->text || label->font == CUI_FONT_ICONS) continue;
                        const char *expected = m == 8 ? "Custom" : methods[m];
                        CHECK(label->text_len == (int)strlen(expected) && !memcmp(label->text, expected, strlen(expected)));
                        CHECK(label->rect.w + 0.1f >= cui__text_width(ui, label->font, label->font_size, label->text, label->text_len, false));
                        label_found = true;
                    }
                }
                if (n->id == cui_make_id(ui, "###composer-send") || n->id == cui_make_id(ui, "###composer-save")) {
                    CHECK(n->rect.h == KEST_CONTROL_LARGE);
                    for (int child = n->first; child >= 0; child = ui->nodes[child].next) {
                        cui_rect r = ui->nodes[child].rect;
                        CHECK(r.x >= n->rect.x && r.x + r.w <= n->rect.x + n->rect.w + 0.1f);
                    }
                }
            }
            CHECK(label_found);
        }
    }
    cui_set_viewport(ui, 640, 240, 1);
    for (int i = (int)strlen(url); i < 4000; i++) url[i] = 'x';
    url[4000] = 0;
    kest_focus(ui, "composer-url");
    cui_input_key(ui, CUI_KEY_END, true, 0); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_key(ui, CUI_KEY_END, false, 0); composer_frame(ui, "GET", url, sizeof url, false);
    cui_edit_state *edit = cui_state(ui, cui_make_id(ui, "composer-url"), sizeof *edit);
    CHECK(edit->scroll_x > 0 && edit->cursor == 4000);
    /* Exercise native clipboard plumbing with an in-memory source only. */
    ui->platform.get_clipboard = composer_clipboard;
    cui_input_key(ui, CUI_KEY_A, true, CUI_MOD_PRIMARY); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_key(ui, CUI_KEY_A, false, 0); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_key(ui, CUI_KEY_V, true, CUI_MOD_PRIMARY); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_key(ui, CUI_KEY_V, false, 0); composer_frame(ui, "GET", url, sizeof url, false);
    CHECK(!strcmp(url, composer_clipboard(NULL)));
    ui->platform.get_clipboard = NULL;
    kest_focus(ui, "###composer-send"); ui->focus_visible = true;
    composer_frame(ui, "GET", url, sizeof url, false);
    bool focus_ring = false;
    for (int i = 0; i < ui->node_count; i++) if (ui->nodes[i].id == ui->focus) focus_ring = ui->nodes[i].paint != NULL;
    CHECK(focus_ring);
    const cui_draw_data *data = cui_get_draw_data(ui);
    unsigned char *pixels = calloc((size_t)data->width_px * data->height_px, 4);
    CHECK(pixels);
    cui_sw_render(sw, data, pixels, data->width_px, data->height_px, data->width_px * 4, CUI_SW_RGBA);
    cui_rect send = cui_get_rect(ui, cui_make_id(ui, "###composer-send"));
    const unsigned char *bg = pixels + (((int)send.y + 7) * data->width_px + (int)send.x + 7) * 4;
    int text_pixels = 0;
    for (int y = (int)send.y + 9; y < (int)(send.y + send.h) - 9; y++)
        for (int x = (int)send.x + 12; x < (int)(send.x + send.w) - 12; x++) {
            const unsigned char *p = pixels + (y * data->width_px + x) * 4;
            text_pixels += p[0] != bg[0] || p[1] != bg[1] || p[2] != bg[2];
        }
    CHECK(text_pixels > 20);
    free(pixels);
    cui_input_key(ui, CUI_KEY_ENTER, true, 0); CHECK(composer_frame(ui, "GET", url, sizeof url, false));
    cui_input_key(ui, CUI_KEY_ENTER, true, 0); CHECK(!composer_frame(ui, "GET", url, sizeof url, false));
    cui_input_key(ui, CUI_KEY_ENTER, false, 0); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_key(ui, CUI_KEY_SPACE, true, 0); CHECK(composer_frame(ui, "GET", url, sizeof url, false));
    cui_input_key(ui, CUI_KEY_SPACE, true, 0); CHECK(!composer_frame(ui, "GET", url, sizeof url, false));
    cui_input_key(ui, CUI_KEY_SPACE, false, 0); composer_frame(ui, "GET", url, sizeof url, false);
    cui_input_mouse_move(ui, send.x + send.w / 2, send.y + send.h / 2);
    composer_frame(ui, "GET", url, sizeof url, true);
    cui_input_mouse_button(ui, CUI_MOUSE_LEFT, true); CHECK(!composer_frame(ui, "GET", url, sizeof url, true));
    cui_input_mouse_button(ui, CUI_MOUSE_LEFT, false); CHECK(!composer_frame(ui, "GET", url, sizeof url, true));
    return 0;
}

static void table_frame(cui_ctx *ui, char *key, char *value, bool details) {
    cui_begin_frame(ui, 1.0f / 60);
    cui_theme_get(ui)->colors[CUI_TOKEN_BORDER_SUBTLE] = (cui_color){255, 0, 255, 255};
    cui_push_id(ui, "table-fixture");
    const unsigned ids[] = { 1 };
    kest_table_navigation(ui, ids, 1);
    cui_column_begin(ui, &(cui_box){ .width = CUI_PX(500), .pad_left = 0.25f, .pad_top = 0.25f });
    cui_push_id_int(ui, 1);
    kest_table_row_begin(ui, 0);
    kest_table_input(ui, "key", key, 128, &(cui_input_opts){ .width = CUI_FILL, .placeholder = "e.g. Accept" });
    kest_table_input(ui, "value", value, 128, &(cui_input_opts){ .width = CUI_FILL, .placeholder = "e.g. application/json" });
    if (kest_table_menu_begin(ui, "row-actions", true, NULL, CUI_COLOR_TEXT_SECONDARY)) cui_menu_end(ui);
    cui_box_end(ui);
    cui_pop_id(ui);
    cui_box_end(ui);
    if (details) {
        cui_popover_open(ui, "details");
        if (kest_table_details_begin(ui, "details")) {
            cui_text(ui, "Explicit row details");
            cui_menu_item_ex(ui, "Close", NULL);
            cui_menu_end(ui);
        }
    }
    cui_pop_id(ui);
    kest_end_frame(ui);
    kest_quiet_caret(ui);
}

static int table_checks(cui_ctx *ui, cui_sw_renderer *sw) {
    float scales[] = {1, 1.25f, 1.5f, 2};
    char key[128] = "Accept", value[128] = "private-value-never-in-a-passive-tooltip";
    cui_input_mouse_move(ui, -10, -10);
    for (int dark = 0; dark < 2; dark++) for (int scale = 0; scale < 4; scale++) {
        cui_set_theme(ui, dark ? CUI_THEME_DARK : CUI_THEME_LIGHT);
        cui_set_viewport(ui, 640, 240, scales[scale]);
        table_frame(ui, key, value, false); table_frame(ui, key, value, false);
        cui_push_id(ui, "table-fixture"); cui_push_id_int(ui, 1);
        cui_id row_id = cui_make_id(ui, "kv-row"), action_id = cui_make_id(ui, "row-actions");
        cui_pop_id(ui); cui_pop_id(ui);
        for (int i = 0; i < ui->node_count; i++) if (ui->nodes[i].id == action_id) CHECK(ui->nodes[i].opacity == 0);
        cui_rect row = cui_get_rect(ui, row_id);
        const cui_draw_data *data = cui_get_draw_data(ui);
        unsigned char *pixels = calloc((size_t)data->width_px * data->height_px, 4);
        CHECK(pixels);
        cui_sw_render(sw, data, pixels, data->width_px, data->height_px, data->width_px * 4, CUI_SW_RGBA);
        CHECK(accent_height(pixels, data->width_px, data->height_px, (int)((row.x + 7) * scales[scale]), (int)((row.y + row.h) * scales[scale]), 4) == 1);
        free(pixels);
    }
    cui_set_viewport(ui, 640, 240, 1);
    cui_push_id(ui, "table-fixture"); cui_push_id_int(ui, 1);
    kest_focus(ui, "key");
    cui_id key_id = cui_make_id(ui, "key"), value_id = cui_make_id(ui, "value"), action_id = cui_make_id(ui, "row-actions");
    cui_pop_id(ui); cui_pop_id(ui);
    table_frame(ui, key, value, false);
    cui_input_key(ui, CUI_KEY_TAB, true, 0); table_frame(ui, key, value, false);
    CHECK(ui->focus == value_id);
    cui_input_key(ui, CUI_KEY_TAB, false, 0); table_frame(ui, key, value, false);
    cui_input_key(ui, CUI_KEY_TAB, true, CUI_MOD_SHIFT); table_frame(ui, key, value, false);
    CHECK(ui->focus == key_id);
    cui_input_key(ui, CUI_KEY_TAB, false, 0); cui_input_key(ui, CUI_KEY_NONE, false, 0); table_frame(ui, key, value, false);
    cui_rect action = cui_get_rect(ui, action_id);
    cui_input_mouse_move(ui, action.x + action.w / 2, action.y + action.h / 2);
    for (int i = 0; i < 45; i++) table_frame(ui, key, value, false);
    bool safe_hint = false;
    for (int i = 0; i < ui->node_count; i++) {
        cui_node *n = &ui->nodes[i];
        int root = i;
        while (ui->nodes[root].parent >= 0) root = ui->nodes[root].parent;
        if (ui->nodes[root].id != 0x7001718u || !n->text) continue;
        CHECK(!strstr(n->text, value));
        if (strstr(n->text, "Row actions")) safe_hint = true;
    }
    CHECK(safe_hint);
    for (int i = 0; i < ui->node_count; i++) if (ui->nodes[i].id == action_id) CHECK(ui->nodes[i].opacity == 1);
    table_frame(ui, key, value, true);
    cui_input_text(ui, "X"); table_frame(ui, key, value, true);
    CHECK(!strcmp(key, "Accept")); /* an open inspector owns keyboard input */
    cui_toast_ex(ui, "Queued notification", &(cui_toast_opts){ .duration = 0.1f });
    table_frame(ui, key, value, true);
    CHECK(ui->toast_count == 1);
    ui->toasts[0].age = 0.09f;
    table_frame(ui, key, value, false);
    CHECK(ui->toast_count == 1 && ui->toasts[0].age <= 0.091f);
    cui_push_id(ui, "table-fixture");
    CHECK(!cui_popover_is_open(ui, "details")); /* no orphan popup after hiding a table */
    cui_pop_id(ui);
    return 0;
}

int main(void) {
    cui_sw_renderer *sw = cui_sw_create();
    CHECK(sw);
    cui_ctx *ui = cui_create(&(cui_ctx_desc){ .renderer = cui_sw_iface(sw) });
    CHECK(ui);
    cui_set_reduced_motion(ui, true);
    const float scales[] = { 1, 1.25f, 1.5f, 2 };
    for (int dark = 0; dark < 2; dark++) for (int s = 0; s < 4; s++) {
        cui_set_theme(ui, dark ? CUI_THEME_DARK : CUI_THEME_LIGHT);
        float scale = scales[s];
        cui_set_viewport(ui, 640, 240, scale);
        frame(ui, 0); frame(ui, 0);
        const cui_draw_data *data = cui_get_draw_data(ui);
        int width = data->width_px, height = data->height_px;
        unsigned char *pixels = calloc((size_t)width * height, 4);
        CHECK(pixels);
        cui_sw_render(sw, data, pixels, width, height, width * 4, CUI_SW_RGBA);
        cui_rect tab = cui_get_rect(ui, cui_make_id(ui, keys[0]));
        CHECK(fabsf(tab.h - KEST_CONTENT_TAB_HEIGHT) < 0.01f);
        int x = (int)((tab.x + tab.w * 0.5f) * scale);
        int bottom = (int)roundf((tab.y + tab.h) * scale);
        CHECK(accent_height(pixels, width, height, x, bottom, 5) == 2);
        cui_push_id(ui, "docs");
        cui_rect doc = cui_get_rect(ui, cui_make_id(ui, "GET request"));
        cui_pop_id(ui);
        CHECK(doc.w > 0 && doc.h > 0);
        CHECK(doc.w >= 144 && doc.w <= 280);
        cui_push_id(ui, "docs");
        cui_id document = cui_make_id(ui, "GET request");
        cui_pop_id(ui);
        cui_rect close = cui_get_rect(ui, document ^ 0xC105Eu);
        cui_rect dot = cui_get_rect(ui, document ^ 0xD17u);
        CHECK(dot.x >= doc.x && dot.x + dot.w <= close.x);
        int methods = 0, names = 0, visible_close = 0;
        for (int n = 0; n < ui->node_count; n++) {
            cui_node *node = &ui->nodes[n];
            if (node->text == document_label) { CHECK(node->text_len == (int)strlen(document_label)); names++; }
            if (node->text && node->font == CUI_FONT_MONO) {
                /* Methods take their own width: no padded slot before the name. */
                float text_w = cui_measure_text(ui, node->font, node->font_size, node->text, node->text_len).width;
                CHECK(node->rect.w >= text_w - 0.5f && node->rect.w <= ceilf(text_w) + 0.5f && node->rect.w <= KEST_METHOD_MAX);
                methods++;
            }
            if (node->parent >= 0 && ui->nodes[node->parent].id == (document ^ 0xC105Eu) && node->font == CUI_FONT_ICONS)
                visible_close += node->opacity == 1;
        }
        CHECK(methods == 2 && names == 1 && visible_close == 1);
        x = (int)((doc.x + doc.w * 0.5f) * scale);
        bottom = (int)roundf((doc.y + doc.h) * scale);
        CHECK(accent_height(pixels, width, height, x, bottom, 5) == 2);
        free(pixels);
    }
    cui_push_id(ui, "docs");
    cui_rect info = cui_get_rect(ui, cui_make_id(ui, "GET request"));
    cui_pop_id(ui);
    cui_input_mouse_move(ui, info.x + info.w / 2, info.y + info.h / 2);
    for (int i = 0; i < 40; i++) frame(ui, 0);
    bool full_tooltip = false;
    for (int i = 0; i < ui->node_count; i++) {
        cui_node *n = &ui->nodes[i];
        if (n->text && n->text_len == (int)strlen(document_tooltip) && !memcmp(n->text, document_tooltip, strlen(document_tooltip))) full_tooltip = true;
    }
    CHECK(full_tooltip);
    for (int i = 0; i < ui->float_count; i++) {
        cui_rect r = ui->nodes[ui->float_roots[i]].rect;
        CHECK(r.x >= 0 && r.y >= 0 && r.x + r.w <= 640 && r.y + r.h <= 240);
    }
    cui_input_mouse_move(ui, -10, -10);
    cui_input_key(ui, CUI_KEY_ESCAPE, true, 0); frame(ui, 0);
    cui_input_key(ui, CUI_KEY_ESCAPE, false, 0); frame(ui, 0);
    cui_push_id(ui, "docs");
    kest_focus(ui, "GET request");
    cui_id focused_doc = cui_make_id(ui, "GET request");
    cui_pop_id(ui);
    ui->focus_visible = true;
    frame(ui, 0);
    const cui_draw_data *focused_data = cui_get_draw_data(ui);
    unsigned char *focused_pixels = calloc((size_t)focused_data->width_px * focused_data->height_px, 4);
    CHECK(focused_pixels);
    cui_sw_render(sw, focused_data, focused_pixels, focused_data->width_px, focused_data->height_px, focused_data->width_px * 4, CUI_SW_RGBA);
    cui_rect focused_rect = cui_get_rect(ui, focused_doc);
    cui_color surface = cui_token_color(ui, CUI_TOKEN_SURFACE);
    int visible_text = 0;
    for (int y = (int)((focused_rect.y + 8) * 2); y < (int)((focused_rect.y + focused_rect.h - 8) * 2); y++)
        for (int x = (int)((focused_rect.x + 10) * 2); x < (int)((focused_rect.x + 100) * 2); x++) {
            const unsigned char *p = focused_pixels + (y * focused_data->width_px + x) * 4;
            visible_text += p[0] != surface.r || p[1] != surface.g || p[2] != surface.b;
        }
    CHECK(visible_text > 20);
    free(focused_pixels);
    for (int dark = 0; dark < 2; dark++) for (int s = 0; s < 4; s++) for (int stacked = 0; stacked < 2; stacked++) {
        cui_set_theme(ui, dark ? CUI_THEME_DARK : CUI_THEME_LIGHT);
        float scale = scales[s], ratio = 0.413f;
        cui_set_viewport(ui, 640, 240, scale);
        cui_input_mouse_move(ui, -10, -10);
        split_frame(ui, stacked, &ratio); split_frame(ui, stacked, &ratio);
        for (int hovered = 0; hovered < 2; hovered++) {
            if (hovered) {
                cui_rect grip = cui_get_rect(ui, cui_make_id(ui, "split") ^ 0x77u);
                cui_input_mouse_move(ui, grip.x + grip.w / 2, grip.y + grip.h / 2);
                split_frame(ui, stacked, &ratio); split_frame(ui, stacked, &ratio);
            }
            const cui_draw_data *data = cui_get_draw_data(ui);
            int width = data->width_px, height = data->height_px;
            unsigned char *pixels = calloc((size_t)width * height, 4);
            CHECK(pixels);
            cui_sw_render(sw, data, pixels, width, height, width * 4, CUI_SW_RGBA);
            cui_rect line = cui_get_rect(ui, cui_make_id(ui, "split") ^ 0x78u);
            CHECK(fabsf((stacked ? line.h : line.w) * scale - 1) < 0.01f);
            int x = (int)((line.x + line.w * 0.5f) * scale);
            int y = (int)((line.y + line.h * 0.5f) * scale);
            int colored = 0;
            for (int offset = -4; offset <= 4; offset++) {
                int px = x + (stacked ? 0 : offset), py = y + (stacked ? offset : 0);
                const unsigned char *p = pixels + (py * width + px) * 4;
                if (p[0] == 255 && p[1] == 0 && p[2] == 255) colored++;
            }
            CHECK(colored == 1);
            free(pixels);
        }
    }
    cui_set_viewport(ui, 640, 240, 1);
    kest_focus(ui, keys[0]);
    cui_input_key(ui, CUI_KEY_RIGHT, true, 0);
    CHECK(frame(ui, 0) == 1);
    CHECK(ui->focus == cui_make_id(ui, keys[1]) && ui->focus_visible);
    int tab_stops = 0;
    for (int i = 0; i < ui->focus_count; i++) for (int k = 0; k < 3; k++)
        if (ui->focus_order[i] == cui_make_id(ui, keys[k])) tab_stops++;
    CHECK(tab_stops == 1);
    for (int i = 0; i < ui->node_count; i++) {
        cui_node *n = &ui->nodes[i];
        if (n->id == cui_make_id(ui, keys[0])) CHECK(!(n->flags & CUI_NF_FOCUSABLE));
        if (n->id == cui_make_id(ui, keys[1])) CHECK(n->flags & CUI_NF_FOCUSABLE);
    }
    cui_input_key(ui, CUI_KEY_RIGHT, false, 0);
    frame(ui, 1);
    cui_input_key(ui, CUI_KEY_END, true, 0);
    CHECK(frame(ui, 1) == 2);
    cui_input_key(ui, CUI_KEY_END, false, 0); frame(ui, 2);
    cui_input_key(ui, CUI_KEY_RIGHT, true, 0);
    CHECK(frame(ui, 2) == 0); /* wrap */
    cui_input_key(ui, CUI_KEY_RIGHT, false, 0); frame(ui, 0);
    cui_input_key(ui, CUI_KEY_RIGHT, true, CUI_MOD_CTRL);
    CHECK(frame(ui, 0) == 0); /* modified shortcuts belong to the application */
    cui_input_key(ui, CUI_KEY_RIGHT, false, 0); frame(ui, 0);
    kest_focus(ui, "unrelated-editor");
    cui_input_key(ui, CUI_KEY_RIGHT, true, 0);
    CHECK(frame(ui, 0) == 0);
    cui_input_key(ui, CUI_KEY_RIGHT, false, 0); frame(ui, 0);
    cui_input_key(ui, CUI_KEY_RIGHT, true, 0);
    cui_begin_frame(ui, 1.0f / 60);
    kest_focus(ui, keys[0]);
    /* Dialogs are built after the workspace: previous-frame modal coverage
       must protect underlying tab focus before the dialog is built again. */
    ui->prev_modal_layer = cui_make_id(ui, "dialog");
    CHECK(kest_tab_navigation(ui, keys, 3, 0) == 0);
    ui->prev_modal_layer = 0;
    cui_id popup = cui_make_id(ui, "menu");
    cui__popup_set(ui, popup, true);
    CHECK(kest_tab_navigation(ui, keys, 3, 0) == 0);
    cui__popup_set(ui, popup, false);
    cui_end_frame(ui);
    CHECK(table_checks(ui, sw) == 0);
    CHECK(composer_checks(ui, sw) == 0);
    char text[32] = "Focused field";
    kest_focus(ui, "idle-field");
    idle_frame(ui, text); idle_frame(ui, text);
    cui_rect hint = cui_get_rect(ui, cui_make_id(ui, "Tooltip anchor"));
    cui_input_mouse_move(ui, hint.x + hint.w / 2, hint.y + hint.h / 2);
    idle_frame(ui, text); idle_frame(ui, text);
    CHECK(cui_next_wakeup(ui) >= 0); /* retain the tooltip's initial deadline */
    for (int i = 0; i < 80; i++) idle_frame(ui, text);
    CHECK(cui_next_wakeup(ui) < 0); /* no perpetual caret timer once it is shown */
    cui_scroll_state *scroll = cui_state(ui, cui_make_id(ui, "idle-scroll"), sizeof *scroll);
    scroll->last_activity = ui->time;
    ui->wakeup = 0.1f;
    kest_quiet_caret(ui);
    CHECK(cui_next_wakeup(ui) == 0.1f); /* preserve real scrollbar deadlines */
    for (int i = 0; i < 100; i++) idle_frame(ui, text);
    CHECK(cui_next_wakeup(ui) < 0);
    cui_destroy(ui);
    cui_sw_destroy(sw);
    fprintf(stderr, "Shared controls: tab indicators and one-pixel splitters in both themes/four scales, native documents and keyboard navigation passed.\n");
    return 0;
}
