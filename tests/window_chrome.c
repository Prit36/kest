/* Verify the OS receives caption colors, rather than only testing UI tokens. */
#include "host.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "window chrome: line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static void frame(cui_ctx *ui, int overlay, bool open) {
    cui_begin_frame(ui, 1.0f / 60);
    if (overlay == 1 && cui_dialog_begin(ui, "Dialog", &open, NULL)) cui_dialog_end(ui);
    if (overlay == 2 && cui_sheet_begin(ui, "Sheet", &open, NULL)) cui_sheet_end(ui);
    if (overlay == 3) cui_command_palette(ui, &open, NULL, 0);
    cui_end_frame(ui);
    kest_host_sync_chrome(ui);
}
static COLORREF caption(HWND window, DWORD attribute) {
    COLORREF color = 0;
    DwmGetWindowAttribute(window, attribute, &color, sizeof color);
    return color;
}
int main(void) {
    cui_app *app = cui_app_create(&(cui_app_desc){ .title = "Kest chrome test", .hidden = true,
        .renderer = CUI_RENDERER_SOFTWARE, .theme = CUI_THEME_LIGHT });
    CHECK(app);
    kest_host_attach(app);
    HWND window = cui_app_native_window(app);
    cui_ctx *ui = cui_app_ui(app);
    cui_set_reduced_motion(ui, true);
    COLORREF supported;
    bool custom = SUCCEEDED(DwmGetWindowAttribute(window, 35, &supported, sizeof supported));
    for (int dark = 0; dark <= 1; dark++) {
        cui_set_theme(ui, dark ? CUI_THEME_DARK : CUI_THEME_LIGHT);
        cui_theme *theme = cui_theme_get(ui);
        theme->colors[CUI_TOKEN_BACKGROUND] = (cui_color){ dark ? 10 : 252, dark ? 10 : 252, dark ? 10 : 252, 255 };
        theme->colors[CUI_TOKEN_FOREGROUND] = (cui_color){ dark ? 245 : 39, dark ? 245 : 39, dark ? 245 : 42, 255 };
        theme->colors[CUI_TOKEN_SCRIM] = (cui_color){ 0, 0, 0, dark ? 170 : 84 };
        frame(ui, 0, false);
        BOOL actual_dark = !dark;
        if (SUCCEEDED(DwmGetWindowAttribute(window, 20, &actual_dark, sizeof actual_dark))) CHECK(actual_dark == dark);
        if (!custom) continue; /* Windows 10 has light/dark captions only. */
        COLORREF base = caption(window, 35), text = caption(window, 36);
        CHECK(base == (dark ? RGB(10,10,10) : RGB(252,252,252)));
        CHECK(text == (dark ? RGB(245,245,245) : RGB(39,39,42)));
        for (int overlay = 1; overlay <= 3; overlay++) {
            frame(ui, overlay, true);
            COLORREF dimmed = caption(window, 35);
            CHECK(GetRValue(dimmed) < GetRValue(base));
            CHECK(GetRValue(caption(window, 36)) < GetRValue(text));
            /* Palette uses a lighter scrim than dialogs and sheets. */
            CHECK(GetRValue(dimmed) == (overlay == 3 ? (dark ? 5 : 194) : (dark ? 3 : 169)));
            frame(ui, overlay, false);
            CHECK(caption(window, 35) == base);
            CHECK(caption(window, 36) == text);
        }
    }
    cui_app_destroy(app);
    puts("Native title bar: theme changes, dialog, sheet, palette and restoration passed.");
    return 0;
}
