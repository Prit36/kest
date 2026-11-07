/* The sole CUI-internal boundary, pinned to the dependency commit.
 * Workers post a message; only the UI thread ever touches a CUI context. */
#include "host.h"
#include "cui_internal.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static HWND window;
static WNDPROC previous;
static int events;
#define KEST_WAKE (WM_APP + 73)
#define KEST_FLUSH 0x5254
static LRESULT CALLBACK dispatch(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == KEST_WAKE) return 0;
    if (msg == WM_TIMER && wp == KEST_FLUSH) {
        KillTimer(h, KEST_FLUSH);
        events |= 1;
        return 0;
    }
    if (msg == WM_ACTIVATE) events |= LOWORD(wp) ? 2 : 4;
    return CallWindowProcW(previous, h, msg, wp, lp);
}
void kest_host_attach(cui_app *app) {
    window = (HWND)cui_app_native_window(app);
    previous = (WNDPROC)SetWindowLongPtrW(window, GWLP_WNDPROC, (LONG_PTR)dispatch);
}
void kest_host_wake(void) { if (window) PostMessageW(window, KEST_WAKE, 0, 0); }
void kest_host_schedule(unsigned ms) { if (window) SetTimer(window, KEST_FLUSH, ms, NULL); }
int kest_host_events(void) { int result = events; events = 0; return result; }
const char *kest_clipboard(cui_ctx *ui) {
    return ui->platform.get_clipboard ? ui->platform.get_clipboard(ui->platform.user) : "";
}
void kest_copy(cui_ctx *ui, const char *text) {
    if (ui->platform.set_clipboard) ui->platform.set_clipboard(ui->platform.user, text);
}
const char *kest_editor_text(cui_ctx *ui) { return ui->text_in; }
int kest_editor_focus(cui_ctx *ui, cui_id id) { return ui->focus == id && !ui->prev_modal_layer; }
void kest_editor_register(cui_ctx *ui, cui_id id) {
    cui__interact(ui, id, CUI_IF_FOCUSABLE | CUI_IF_TEXT);
    cui__mark_interactive(ui, ui->last_node, CUI_IF_FOCUSABLE | CUI_IF_TEXT);
    if (ui->focus == id) ui->edit_prev = true;
}
float kest_editor_scroll(cui_ctx *ui, cui_id id) {
    if (ui->hot != id) return 0;
    float dy = ui->scroll_dy;
    ui->scroll_dy = 0;
    return dy;
}
void kest_quiet_caret(cui_ctx *ui) {
    /* Text input uses a steady caret. Toast deadlines and tooltip deadlines
     * still wake once; an otherwise idle editor has no blink timer. */
    if (ui->edit && ui->toast_count == 0 && ui->hover_id_for_tooltip == 0)
        ui->wakeup = -1;
}
bool kest_item_begin(cui_ctx *ui, const char *key, bool selected, float height) {
    cui_id id = cui_make_id(ui, key);
    cui_interact hit = cui__interact(ui, id, CUI_IF_FOCUSABLE);
    cui_box box = {0};
    box.id = key; box.width = CUI_FILL; box.height = CUI_PX(height);
    box.dir = CUI_ROW; box.align = CUI_ALIGN_CENTER;
    box.gap = 8; box.pad_x = 8; box.radius = 6;
    if (selected) box.bg = CUI_TOKEN_COLOR(CUI_TOKEN_ACTIVE);
    else if (hit.hovered) box.bg = CUI_COLOR_HOVER;
    if (hit.focus_visible) { box.border = 1; box.border_color = CUI_COLOR_ACCENT; }
    cui_box_begin(ui, &box);
    cui__mark_interactive(ui, ui->last_node, CUI_IF_FOCUSABLE);
    if (hit.hovered) cui__set_cursor(ui, CUI_CURSOR_HAND);
    return hit.clicked;
}
void kest_item_end(cui_ctx *ui) {
    cui_id id = ui->nodes[cui__current(ui)].id;
    cui_box_end(ui);
    ui->last_id = id;
}
