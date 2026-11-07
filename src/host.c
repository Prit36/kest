/* The sole CUI-internal boundary, pinned to the dependency commit.
 * Workers post a message; only the UI thread ever touches a CUI context. */
#include "host.h"
#include "cui_internal.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
static HWND window;
static WNDPROC previous;
static int events;
static COLORREF caption_color, caption_text;
static BOOL caption_dark;
static bool caption_valid;
static kest_window_geometry normal_geometry;
static bool normal_valid, last_maximized;

static unsigned window_dpi(void) {
    typedef UINT (WINAPI *get_dpi_fn)(HWND);
    static get_dpi_fn get_dpi;
    static bool resolved;
    if (!resolved) {
        get_dpi = (get_dpi_fn)(void *)GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
        resolved = true;
    }
    unsigned actual = get_dpi ? get_dpi(window) : 0;
    if (actual) return actual;
    HDC dc = GetDC(window);
    unsigned dpi = dc ? (unsigned)GetDeviceCaps(dc, LOGPIXELSX) : 96;
    if (dc) ReleaseDC(window, dc);
    return dpi ? dpi : 96;
}

static void remember_normal_geometry(void) {
    if (!window || IsIconic(window) || IsZoomed(window)) return;
    RECT rect, client;
    if (!GetWindowRect(window, &rect) || !GetClientRect(window, &client)) return;
    if (client.right <= 0 || client.bottom <= 0) return;
    unsigned dpi = window_dpi();
    normal_geometry = (kest_window_geometry){
        .x = rect.left, .y = rect.top, .width = rect.right - rect.left, .height = rect.bottom - rect.top,
        .dpi = dpi, .client_width = client.right * 96.0f / dpi, .client_height = client.bottom * 96.0f / dpi,
        .positioned = true
    };
    normal_valid = true;
}
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
    LRESULT result = CallWindowProcW(previous, h, msg, wp, lp);
    if (msg == WM_WINDOWPOSCHANGED || msg == WM_EXITSIZEMOVE || msg == WM_DPICHANGED) {
        remember_normal_geometry();
        if (!IsIconic(h)) last_maximized = IsZoomed(h) != 0;
    }
    return result;
}
void kest_host_attach(cui_app *app) {
    window = (HWND)cui_app_native_window(app);
    previous = (WNDPROC)SetWindowLongPtrW(window, GWLP_WNDPROC, (LONG_PTR)dispatch);
    caption_valid = false;
    normal_valid = false;
    last_maximized = false;
    remember_normal_geometry();
}

bool kest_host_get_geometry(kest_window_geometry *out) {
    if (!window || !out) return false;
    remember_normal_geometry();
    if (!normal_valid) return false;
    *out = normal_geometry;
    out->maximized = IsIconic(window) ? last_maximized : IsZoomed(window) != 0;
    return true;
}

static void client_to_outer(RECT *rect, unsigned dpi) {
    typedef BOOL (WINAPI *adjust_fn)(LPRECT, DWORD, BOOL, DWORD, UINT);
    adjust_fn adjust = (adjust_fn)(void *)GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi");
    DWORD style = (DWORD)GetWindowLongPtrW(window, GWL_STYLE);
    DWORD ex_style = (DWORD)GetWindowLongPtrW(window, GWL_EXSTYLE);
    if (!adjust || !adjust(rect, style, FALSE, ex_style, dpi)) AdjustWindowRectEx(rect, style, FALSE, ex_style);
}

void kest_host_restore_geometry(const kest_window_geometry *saved, bool show) {
    if (!window || !saved) return;
    RECT original;
    if (!GetWindowRect(window, &original)) return;
    bool positioned = saved->positioned && saved->x >= -1000000 && saved->x <= 1000000 && saved->y >= -1000000 && saved->y <= 1000000 && saved->width > 0 && saved->width <= 64000 && saved->height > 0 && saved->height <= 64000;
    RECT target = positioned ? (RECT){saved->x, saved->y, saved->x + saved->width, saved->y + saved->height} : original;
    MONITORINFO monitor = { .cbSize = sizeof monitor };
    if (!GetMonitorInfoW(MonitorFromRect(&target, MONITOR_DEFAULTTONEAREST), &monitor)) {
        if (show) ShowWindow(window, SW_SHOWNORMAL);
        return;
    }
    RECT work = monitor.rcWork;
    /* Move the hidden window onto the target monitor before reading its DPI.
       CUI processes WM_DPICHANGED; then the final size is calculated there. */
    SetWindowPos(window, NULL, work.left, work.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    unsigned dpi = window_dpi();
    int width, height;
    if (positioned) {
        unsigned old_dpi = saved->dpi >= 48 && saved->dpi <= 768 ? saved->dpi : 96;
        width = MulDiv(saved->width, dpi, old_dpi);
        height = MulDiv(saved->height, dpi, old_dpi);
    } else {
        float cw = saved->client_width >= 640 && saved->client_width <= 8000 ? saved->client_width : 1280;
        float ch = saved->client_height >= 420 && saved->client_height <= 8000 ? saved->client_height : 800;
        RECT client = {0, 0, (LONG)(cw * dpi / 96), (LONG)(ch * dpi / 96)};
        client_to_outer(&client, dpi);
        width = client.right - client.left; height = client.bottom - client.top;
    }
    RECT minimum = {0, 0, MulDiv(640, dpi, 96), MulDiv(420, dpi, 96)};
    client_to_outer(&minimum, dpi);
    width = CUI_MIN(CUI_MAX(width, minimum.right - minimum.left), work.right - work.left);
    height = CUI_MIN(CUI_MAX(height, minimum.bottom - minimum.top), work.bottom - work.top);
    int x = positioned ? saved->x : original.left, y = positioned ? saved->y : original.top;
    x = CUI_MAX(work.left, CUI_MIN(x, work.right - width));
    y = CUI_MAX(work.top, CUI_MIN(y, work.bottom - height));
    SetWindowPos(window, NULL, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    remember_normal_geometry();
    if (show) ShowWindow(window, saved->maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
    last_maximized = show && saved->maximized;
}
static cui_color over(cui_color base, cui_color scrim) {
    unsigned a = scrim.a, inv = 255 - a;
    return (cui_color){ (base.r * inv + scrim.r * a + 127) / 255,
                        (base.g * inv + scrim.g * a + 127) / 255,
                        (base.b * inv + scrim.b * a + 127) / 255, 255 };
}
void kest_host_sync_chrome(cui_ctx *ui) {
    if (!window) return;
    cui_color bg = CUI_C(ui, BACKGROUND), fg = CUI_C(ui, FOREGROUND);
    /* Read this frame's actual animated scrims, including sheets, the palette
     * and closing dialogs. Kest's scrims are all black, so their order does
     * not affect the composite. Menus and tooltips have no blocker flag. */
    for (int i = 0; i < ui->float_count; i++) {
        cui_node *n = &ui->nodes[ui->float_roots[i]];
        if (!(n->flags & CUI_NF_BLOCKER)) continue;
        bg = over(bg, n->bg);
        fg = over(fg, n->bg);
    }
    COLORREF color = RGB(bg.r, bg.g, bg.b), text = RGB(fg.r, fg.g, fg.b);
    BOOL dark = fg.r + fg.g + fg.b > bg.r + bg.g + bg.b;
    if (!caption_valid || dark != caption_dark) {
        /* 20 is supported on current Windows 10/11; older Windows 10 uses 19. */
        if (FAILED(DwmSetWindowAttribute(window, 20, &dark, sizeof dark)))
            DwmSetWindowAttribute(window, 19, &dark, sizeof dark);
        caption_dark = dark;
    }
    /* Custom caption/text colors are available on Windows 11. Older systems
     * retain the native caption with the matching light/dark appearance. */
    if (!caption_valid || color != caption_color) {
        DwmSetWindowAttribute(window, 35, &color, sizeof color);
        caption_color = color;
    }
    if (!caption_valid || text != caption_text) {
        DwmSetWindowAttribute(window, 36, &text, sizeof text);
        caption_text = text;
    }
    caption_valid = true;
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
bool kest_has_node(cui_ctx *ui, cui_id id) {
    for (int i = 0; i < ui->node_count; ++i) if (ui->nodes[i].id == id) return true;
    return false;
}
int kest_editor_focus(cui_ctx *ui, cui_id id) {
    if (ui->focus != id || ui->prev_modal_layer) return 0;
    for (int i = 0; i < ui->popup_count; ++i) if (ui->popups[i].open) return 0;
    return 1;
}
void kest_editor_tabs(cui_ctx *ui, cui_id id, int capture) {
    if (kest_editor_focus(ui, id)) ui->tab_owner = capture ? id : 0;
}
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
cui_vec2 kest_editor_scroll_axes(cui_ctx *ui, cui_id id) {
    cui_vec2 delta = {0};
    if (ui->hot != id || ui->prev_modal_layer) return delta;
    for (int i = 0; i < ui->popup_count; ++i) if (ui->popups[i].open) return delta;
    delta.x = ui->scroll_dx;
    delta.y = ui->scroll_dy;
    if (ui->mods & CUI_MOD_SHIFT) { delta.x += delta.y; delta.y = 0; }
    ui->scroll_dx = ui->scroll_dy = 0;
    return delta;
}
void kest_quiet_caret(cui_ctx *ui) {
    kest_table_popup_cleanup(ui);
    /* Text input uses a steady caret. Toast deadlines and tooltip deadlines
     * still wake once; an otherwise idle editor has no blink timer. */
    bool settled_tooltip = ui->tooltip_id && ui->tooltip_id == ui->hot && ui->time - ui->hover_start >= 0.7;
    if (ui->edit && ui->toast_count == 0 && (ui->hover_id_for_tooltip == 0 || settled_tooltip)) {
        /* Keep real popup grace periods and scrollbar fade deadlines. Only the
           otherwise redundant caret wake-up may be discarded. */
        for (int i = 0; i < ui->popup_count; i++) if (ui->popups[i].open) return;
        for (int i = 0; i < ui->node_count; i++) {
            cui_node *n = &ui->nodes[i];
            if (!(n->flags & (CUI_NF_SCROLL_X | CUI_NF_SCROLL_Y))) continue;
            cui_state_entry *entry = cui__state_entry(ui, n->id);
            if (entry->size != sizeof(cui_scroll_state)) continue;
            cui_scroll_state *scroll = entry->data;
            if (scroll->last_activity > 0 && ui->time - scroll->last_activity < 0.9) return;
        }
        ui->wakeup = -1;
    }
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
