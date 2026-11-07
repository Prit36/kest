#include <cui/cui.h>
#include <cui/cui_app.h>
#include <cui/cui_render.h>
void retort_host_attach(cui_app *app);
void retort_host_wake(void);
void retort_host_schedule(unsigned ms);
int retort_host_events(void);
const char *retort_clipboard(cui_ctx *ui);
void retort_copy(cui_ctx *ui, const char *text);
const char *retort_editor_text(cui_ctx *ui);
float retort_editor_scroll(cui_ctx *ui, cui_id id);
int retort_editor_focus(cui_ctx *ui, cui_id id);
void retort_editor_register(cui_ctx *ui, cui_id id);
void retort_quiet_caret(cui_ctx *ui);
bool retort_item_begin(cui_ctx *ui, const char *id, bool selected, float height);
void retort_item_end(cui_ctx *ui);
bool retort_control_begin(cui_ctx *ui, const char *id, bool selected, float width, float height, int kind);
int retort_flat_input(cui_ctx *ui, const char *id, char *buf, size_t cap, const cui_input_opts *opts, bool cell);
bool retort_menu_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts, float width, cui_color color);
bool retort_dropdown_begin(cui_ctx *ui, const char *label, const cui_menu_opts *opts);
bool retort_reveal(cui_ctx *ui, const char *scroll_id, cui_id target, bool horizontal);
void retort_focus(cui_ctx *ui, const char *id);
bool retort_button_ex(cui_ctx *ui, const char *label, const cui_button_opts *opts);
bool retort_select_ex(cui_ctx *ui, const char *id, const char *const *items, int count, int *index, const cui_select_opts *opts);
cui_texture retort_image_memory(cui_ctx *ui, const unsigned char *bytes, int length, int *out_width, int *out_height);
