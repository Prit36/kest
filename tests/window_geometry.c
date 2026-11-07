/* Real HWND geometry tests on a private desktop; nothing appears to the user. */
#include "host.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "window geometry: line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static int visible_in_work_area(HWND window) {
    RECT r;
    MONITORINFO monitor = { .cbSize = sizeof monitor };
    if (!GetWindowRect(window, &r) || !GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) return 0;
    return r.left >= monitor.rcWork.left && r.top >= monitor.rcWork.top && r.right <= monitor.rcWork.right && r.bottom <= monitor.rcWork.bottom;
}

int main(void) {
    HDESK original = GetThreadDesktop(GetCurrentThreadId());
    wchar_t name[80];
    swprintf(name, 80, L"kest-geometry-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    CHECK(desktop && SetThreadDesktop(desktop));
    cui_app *app = cui_app_create(&(cui_app_desc){ .title = "Geometry check", .hidden = true,
        .width = 900, .height = 600, .min_width = 640, .min_height = 420, .renderer = CUI_RENDERER_SOFTWARE });
    CHECK(app);
    HWND window = cui_app_native_window(app);
    kest_host_attach(app);
    kest_window_geometry stale = { .x = -900000, .y = 900000, .width = 64000, .height = 64000, .dpi = 96, .positioned = true };
    kest_host_restore_geometry(&stale, false);
    CHECK(!IsWindowVisible(window));
    CHECK(visible_in_work_area(window));
    kest_window_geometry legacy = { .client_width = 900, .client_height = 600 };
    kest_host_restore_geometry(&legacy, true);
    CHECK(visible_in_work_area(window));
    kest_window_geometry normal;
    CHECK(kest_host_get_geometry(&normal));
    CHECK(normal.positioned && !normal.maximized && normal.client_width > 0 && normal.client_height > 0);
    /* Same logical outer size saved at twice the current DPI restores exactly. */
    if (normal.dpi <= 384) {
        kest_window_geometry scaled = normal;
        scaled.width *= 2; scaled.height *= 2; scaled.dpi *= 2;
        kest_host_restore_geometry(&scaled, false);
        kest_window_geometry restored;
        CHECK(kest_host_get_geometry(&restored));
        CHECK(abs(restored.width - normal.width) <= 1 && abs(restored.height - normal.height) <= 1);
    }
    kest_window_geometry maximized = normal;
    maximized.maximized = true;
    kest_host_restore_geometry(&maximized, true);
    CHECK(IsZoomed(window));
    kest_window_geometry observed;
    CHECK(kest_host_get_geometry(&observed));
    CHECK(observed.maximized && observed.width == normal.width && observed.height == normal.height);
    ShowWindow(window, SW_MINIMIZE);
    CHECK(IsIconic(window));
    CHECK(kest_host_get_geometry(&observed));
    CHECK(observed.maximized && observed.width == normal.width && observed.client_height == normal.client_height);
    ShowWindow(window, SW_RESTORE);
    CHECK(IsZoomed(window));
    ShowWindow(window, SW_RESTORE);
    CHECK(!IsZoomed(window) && !IsIconic(window));
    CHECK(kest_host_get_geometry(&observed));
    CHECK(observed.width == normal.width && observed.height == normal.height);
    CHECK(visible_in_work_area(window));
    cui_app_destroy(app);
    CHECK(SetThreadDesktop(original));
    CloseDesktop(desktop);
    puts("Native geometry: off-screen/oversized clamp, legacy size, DPI conversion, normal/maximized/minimized restore passed on a private desktop.");
    return 0;
}
