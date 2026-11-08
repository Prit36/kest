#include <cui/cui.h>
#include <cui/cui_app.h>
#include <cui/cui_render.h>
#include "ui/metrics.h"
#include "kest_edit.h"
void kest_host_attach(cui_app *app);
typedef struct kest_window_geometry {
    int x, y, width, height;
    unsigned dpi;
    float client_width, client_height;
    bool positioned, maximized;
} kest_window_geometry;
bool kest_host_get_geometry(kest_window_geometry *geometry);
void kest_host_restore_geometry(const kest_window_geometry *geometry, bool show);
void kest_host_sync_chrome(cui_ctx *ui);
void kest_host_wake(void);
/* Windows settings, cached and refreshed on WM_SETTINGCHANGE.
 * kest_system_dark: -1 unknown, 0 light apps, 1 dark apps. */
int kest_system_dark(void);
bool kest_system_reduced_motion(void);
void kest_host_schedule(unsigned ms);
int kest_host_events(void);
const char *kest_clipboard(cui_ctx *ui);
void kest_copy(cui_ctx *ui, const char *text);
const char *kest_editor_text(cui_ctx *ui);
float kest_editor_scroll(cui_ctx *ui, cui_id id);
cui_vec2 kest_editor_scroll_axes(cui_ctx *ui, cui_id id);
int kest_editor_focus(cui_ctx *ui, cui_id id);
void kest_editor_register(cui_ctx *ui, cui_id id);
void kest_editor_tabs(cui_ctx *ui, cui_id id, int capture);
bool kest_has_node(cui_ctx *ui, cui_id id);
void kest_quiet_caret(cui_ctx *ui);
bool kest_item_begin(cui_ctx *ui, const char *id, bool selected, float height);
void kest_item_end(cui_ctx *ui);
bool kest_control_begin(cui_ctx *ui, const char *id, bool selected, float width, float height, int kind);
bool kest_content_tab_begin(cui_ctx *ui, const char *id, bool selected);
int kest_tab_navigation(cui_ctx *ui, const char *const *keys, int count, int selected);
typedef struct kest_doc_tab {
    const char *title; /* Stable native identity, independent of user text. */
    const char *label, *method, *tooltip;
    cui_color method_color;
    bool dirty, editing;
} kest_doc_tab;
cui_doc_tabs_result kest_doc_tabs_ex(cui_ctx *ui, const char *id, const kest_doc_tab *tabs, int count, int *selected);
bool kest_document_menu_item(cui_ctx *ui, const char *identity, const char *label, bool checked, const char *scroll);
bool kest_scrolling_menu_item(cui_ctx *ui, const char *label, const cui_menu_item_opts *opts, const char *scroll);
void kest_document_list_begin(cui_ctx *ui, const char *id, float max_height);
void kest_resize_guide(cui_ctx *ui, float x, float y, float h, bool active);
void kest_separator(cui_ctx *ui, const char *id, bool vertical);
void kest_split_next(cui_ctx *ui, const char *id, bool vertical);
cui_path_bar_result kest_path_bar_ex(cui_ctx *ui, const char *id, const char *const *segments, int count, const cui_path_bar_opts *opts);
int kest_flat_input(cui_ctx *ui, const char *id, char *buf, size_t cap, const cui_input_opts *opts, bool cell);
int kest_table_input(cui_ctx *ui, const char *id, char *buf, size_t cap, const cui_input_opts *opts);
int kest_table_bulk_input(cui_ctx *ui, char *buf, size_t cap, bool focus);
int kest_table_navigation(cui_ctx *ui, const unsigned *rows, int count);
int kest_response_header_navigation(cui_ctx *ui, int count);
void kest_response_header_source(cui_ctx *ui, const void *source, int count);
void kest_table_focus(cui_ctx *ui, unsigned row, int column, int index);
enum { KEST_ROW_SELECTED = 1, KEST_ROW_DROP_ABOVE = 2, KEST_ROW_DROP_BELOW = 4 };
void kest_table_row_begin(cui_ctx *ui, int flags);
void kest_set_cursor(cui_ctx *ui, cui_cursor cursor);
/* Whether the pointer is over the row being built (last frame's rect). */
bool kest_row_hovered(cui_ctx *ui);
bool kest_table_menu_begin(cui_ctx *ui, const char *id, bool row, const char *notice, cui_color color);
bool kest_context_menu_begin(cui_ctx *ui, const char *key, cui_id anchor);
bool kest_popup_open(cui_ctx *ui, cui_id pid);
bool kest_right_pressed(cui_ctx *ui, cui_id id);
int kest_click_count(cui_ctx *ui);
void kest_wake_after(cui_ctx *ui, float seconds);
float kest_tween(cui_ctx *ui, float *x, float target, float duration);
bool kest_pointer_over(cui_ctx *ui, cui_id id);
bool kest_left_pressed(cui_ctx *ui);
bool kest_table_details_begin(cui_ctx *ui, const char *id);
bool kest_inspector_begin(cui_ctx *ui, const char *id, const char *anchor, float width);
void kest_popup_track(cui_ctx *ui, const char *trigger);
void kest_table_popup_cleanup(cui_ctx *ui);
void kest_end_frame(cui_ctx *ui);
bool kest_menu_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts, float width, float height, cui_color color);
bool kest_method_menu_begin(cui_ctx *ui, const char *method, cui_color color);
void kest_url_invalid(cui_ctx *ui, bool invalid);
bool kest_request_button(cui_ctx *ui, const char *label, const cui_button_opts *opts);
bool kest_request_enter(cui_ctx *ui);
bool kest_request_shortcut(cui_ctx *ui);
bool kest_dropdown_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts);
bool kest_submenu_begin(cui_ctx *ui, const char *label, const char *icon);
void kest_submenu_end(cui_ctx *ui);
bool kest_reveal(cui_ctx *ui, cui_id scroll_id, cui_id target, bool horizontal);
void kest_focus(cui_ctx *ui, const char *id);
void kest_input_select_all(cui_ctx *ui, const char *id, int length);
bool kest_focus_within(cui_ctx *ui, const char *id);
bool kest_focus_inside(cui_ctx *ui, const char *key);
const char *kest_focus_label(cui_ctx *ui);
cui_id kest_get_focus(cui_ctx *ui);
void kest_set_focus(cui_ctx *ui, cui_id id);
cui_id kest_last_id(cui_ctx *ui);
bool kest_was_focusable(cui_ctx *ui, cui_id id);
void kest_collection_style(cui_ctx *ui, const char *id, cui_color background);
void kest_collection_top(cui_ctx *ui, const char *id);
bool kest_collection_reveal(cui_ctx *ui, const char *id, int index, float row_h);
void kest_collection_name(cui_ctx *ui, const char *name, const char *method, const char *icon, cui_color color, int match_start, int match_length);
bool kest_collection_name_marked(cui_ctx *ui);
bool kest_collection_row_hot(cui_ctx *ui);
cui_rect kest_collection_row_rect(cui_ctx *ui);
void kest_collection_drop(cui_ctx *ui, int where);
bool kest_collection_drop_shown(cui_ctx *ui);
void kest_collection_drop_clear(void);
float kest_collection_scroll_y(cui_ctx *ui, const char *key);
void kest_collection_scroll_by(cui_ctx *ui, const char *key, float dy);
bool kest_button_ex(cui_ctx *ui, const char *label, const cui_button_opts *opts);
bool kest_select_ex(cui_ctx *ui, const char *id, const char *const *items, int count, int *index, const cui_select_opts *opts);
/* Screen readers (a11y.c): roles Kest gives the controls it labels. */
enum { KEST_A11Y_AUTO = 0, KEST_A11Y_BUTTON = 1, KEST_A11Y_EDIT = 2, KEST_A11Y_TAB = 3, KEST_A11Y_TREE_ITEM = 4, KEST_A11Y_MENU_BUTTON = 5, KEST_A11Y_MENU_ITEM = 6, KEST_A11Y_TREE = 7 };
void kest_a11y_label(cui_ctx *ui, int role, const char *name, const char *value);
void kest_a11y_label_id(cui_ctx *ui, cui_id id, int role, const char *name, const char *value);
void kest_a11y_selected(cui_ctx *ui, cui_id id);
void kest_a11y_help_id(cui_ctx *ui, cui_id id, const char *text);
void kest_collection_row_tooltip(cui_ctx *ui, const char *text);
void kest_collection_row_selected(cui_ctx *ui);
void kest_tooltip(cui_ctx *ui, const char *text);
void kest_a11y_frame(cui_ctx *ui, void *window);
bool kest_a11y_get_object(void *window, uintptr_t wp, intptr_t lp, intptr_t *result);
/* failure: 0 success, 1 invalid/unsupported, 2 resource limit, 3 allocation. */
unsigned char *kest_image_decode(const unsigned char *bytes, int length, int *out_width, int *out_height, int *source_width, int *source_height, int *failure);
void kest_image_free(unsigned char *rgba);

void kest_documents_scroll(cui_ctx *ui, cui_id strip, float delta);

void kest_collection_replace_name(cui_ctx *ui);
int kest_rename_input(cui_ctx *ui, const char *key, char *buf, size_t cap, bool start, bool invalid);
void kest_rename_select_all(cui_ctx *ui, cui_id id, int length);

cui_vec2 kest_file_drop_position(cui_ctx *ui);

bool kest_document_rename_begin(cui_ctx *ui, cui_id tab);
void kest_document_rename_end(cui_ctx *ui);

void kest_consume_key(cui_ctx *ui, cui_key key);

/* {{variable}} spans in a single-line field just built, painted in colour. */
typedef struct kest_mark { int start, end, known; } kest_mark;
void kest_input_marks(cui_ctx *ui, const char *key, const kest_mark *marks, int count);
/* The focused field's caret: its byte offset, or -1, and where under it a list goes. */
int kest_input_caret(cui_ctx *ui, const char *key, const char *buf, cui_vec2 *below);
/* The byte under the pointer in a field, or -1 off its text. */
int kest_input_offset_at(cui_ctx *ui, const char *key, const char *buf);
void kest_input_set_caret(cui_ctx *ui, const char *key, int pos);
/* A suggestion list at a point, not taking focus. */
bool kest_suggest_begin(cui_ctx *ui, const char *key, cui_vec2 at, float width);
void kest_suggest_end(cui_ctx *ui);
/* The open suggestion list's popup, which leaves its field focused. */
extern cui_id kest_suggest_popup;
void kest_suggest_close(cui_ctx *ui, const char *key);
void kest_consume_click(cui_ctx *ui);
/* The focused field types Tab next frame (a list under it takes Tab). */
void kest_keep_tab(cui_ctx *ui, cui_id id);
void kest_tooltip_for(cui_ctx *ui, cui_id anchor, const char *text);
/* Makes the box `key`, already built in this scope, answer the pointer
 * (without taking focus or clicks) and become the anchor of what follows,
 * such as a hover card. False when there is no such box. */
bool kest_hoverable(cui_ctx *ui, const char *key);
/* The hover card `key` for the anchor `anchor` (from kest_hoverable or a
 * control). Close it with cui_hover_card_end when this returns true. */
bool kest_hover_card_begin(cui_ctx *ui, const char *key, cui_id anchor, float width);
