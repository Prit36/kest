#include <cui/cui.h>
#include <cui/cui_app.h>
#include <cui/cui_render.h>
void kest_host_attach(cui_app *app);
void kest_host_sync_chrome(cui_ctx *ui);
void kest_host_wake(void);
void kest_host_schedule(unsigned ms);
int kest_host_events(void);
const char *kest_clipboard(cui_ctx *ui);
void kest_copy(cui_ctx *ui, const char *text);
const char *kest_editor_text(cui_ctx *ui);
float kest_editor_scroll(cui_ctx *ui, cui_id id);
int kest_editor_focus(cui_ctx *ui, cui_id id);
void kest_editor_register(cui_ctx *ui, cui_id id);
void kest_quiet_caret(cui_ctx *ui);
bool kest_item_begin(cui_ctx *ui, const char *id, bool selected, float height);
void kest_item_end(cui_ctx *ui);
bool kest_control_begin(cui_ctx *ui, const char *id, bool selected, float width, float height, int kind);
int kest_flat_input(cui_ctx *ui, const char *id, char *buf, size_t cap, const cui_input_opts *opts, bool cell);
bool kest_menu_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts, float width, cui_color color);
bool kest_dropdown_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts);
bool kest_reveal(cui_ctx *ui, cui_id scroll_id, cui_id target, bool horizontal);
void kest_focus(cui_ctx *ui, const char *id);
void kest_collection_style(cui_ctx *ui, const char *id, cui_color background);
void kest_collection_top(cui_ctx *ui, const char *id);
void kest_collection_name(cui_ctx *ui, const char *name, const char *method, const char *icon, cui_color color);
bool kest_button_ex(cui_ctx *ui, const char *label, const cui_button_opts *opts);
bool kest_select_ex(cui_ctx *ui, const char *id, const char *const *items, int count, int *index, const cui_select_opts *opts);
cui_texture kest_image_memory(cui_ctx *ui, const unsigned char *bytes, int length, int *out_width, int *out_height);
