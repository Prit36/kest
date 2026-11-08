/* Startup without waiting for the GPU driver.
 *
 * Loading the OpenGL driver is most of a cold start: ChoosePixelFormat alone
 * loads the vendor's ICD (about 100 ms on current NVIDIA drivers), and making
 * the first context current costs tens of milliseconds more. Kest therefore
 * opens its window on CUI's software renderer and paints the first frame with
 * it. Only then does a worker thread create the OpenGL 3.3 context and compile
 * CUI's shaders against a hidden helper window (loading the driver holds the
 * loader lock, which would slow creating and showing the window if it ran
 * alongside). Interaction meanwhile renders in software. The UI thread adopts that
 * context: it gives its own window the same pixel format, makes the context
 * current there and switches CUI to the GL renderer, which re-uploads the
 * glyph atlas. Creating a context on a helper window and using it with the
 * real one is allowed for any window with the same pixel format on the same
 * device; Qt's Windows backend does the same.
 *
 * If the worker cannot prepare a context, the UI thread tries CUI's own
 * synchronous path once, and stays on the software renderer when that fails
 * too: the same result as before, only later. */
#include "host.h"
#include "platform/cui_platform.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>

typedef HGLRC (WINAPI *kest_create_context_fn)(HDC, HGLRC, const int *);
typedef BOOL (WINAPI *kest_swap_interval_fn)(int);
enum { KEST_GPU_IDLE, KEST_GPU_RUNNING, KEST_GPU_READY, KEST_GPU_FAILED, KEST_GPU_DONE };

static volatile LONG gpu_state = KEST_GPU_IDLE;
static HWND gpu_notify;                   /* woken once the worker is done */
static HANDLE gpu_thread;
static HGLRC gpu_context;                 /* owned here from adoption until release */
static cui_gl_renderer *gpu_renderer;
static int gpu_format;
static PIXELFORMATDESCRIPTOR gpu_pfd;

/* The pixel format CUI's Win32 backend asks for. */
static void gpu_describe(PIXELFORMATDESCRIPTOR *pfd) {
    memset(pfd, 0, sizeof *pfd);
    pfd->nSize = sizeof *pfd;
    pfd->nVersion = 1;
    pfd->dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd->iPixelType = PFD_TYPE_RGBA;
    pfd->cColorBits = 32;
    pfd->cAlphaBits = 8;
    pfd->iLayerType = PFD_MAIN_PLANE;
}

static bool gpu_build(HDC dc) {
    PIXELFORMATDESCRIPTOR pfd;
    gpu_describe(&pfd);
    int format = ChoosePixelFormat(dc, &pfd);
    if (!format || !DescribePixelFormat(dc, format, sizeof pfd, &pfd) || !SetPixelFormat(dc, format, &pfd)) return false;
    HGLRC legacy = wglCreateContext(dc);
    if (!legacy) return false;
    if (!wglMakeCurrent(dc, legacy)) { wglDeleteContext(legacy); return false; }
    kest_create_context_fn create = (kest_create_context_fn)(void *)wglGetProcAddress("wglCreateContextAttribsARB");
    /* WGL_CONTEXT_MAJOR/MINOR_VERSION_ARB 3.3, WGL_CONTEXT_PROFILE_MASK_ARB core */
    const int attrs[] = { 0x2091, 3, 0x2092, 3, 0x9126, 0x00000001, 0 };
    HGLRC context = create ? create(dc, NULL, attrs) : NULL;
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(legacy);
    if (!context) return false;
    if (!wglMakeCurrent(dc, context)) { wglDeleteContext(context); return false; }
    cui_gl_renderer *renderer = cui_gl_create(cui__plat_gl_proc);
    if (!renderer) {
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(context);
        return false;
    }
    /* Finish the driver's own setup here rather than on the first frame. */
    glFinish();
    wglMakeCurrent(NULL, NULL);
    gpu_context = context;
    gpu_renderer = renderer;
    gpu_format = format;
    gpu_pfd = pfd;
    return true;
}

static DWORD WINAPI gpu_worker(void *unused) {
    (void)unused;
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW wc = { .style = CS_OWNDC, .lpfnWndProc = DefWindowProcW, .hInstance = instance, .lpszClassName = L"KestGpuProbe" };
    RegisterClassW(&wc);
    HWND helper = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                                  0, 0, 16, 16, NULL, NULL, instance, NULL);
    HDC dc = helper ? GetDC(helper) : NULL;
    bool ok = dc && gpu_build(dc);
    if (dc) ReleaseDC(helper, dc);
    if (helper) DestroyWindow(helper);
    InterlockedExchange(&gpu_state, ok ? KEST_GPU_READY : KEST_GPU_FAILED);
    PostMessageW(gpu_notify, WM_NULL, 0, 0);   /* the UI thread adopts on its next frame */
    return 0;
}

static bool gpu_software_requested(void) {
    char renderer[16];
    DWORD n = GetEnvironmentVariableA("CUI_RENDERER", renderer, sizeof renderer);
    return n && n < sizeof renderer && strcmp(renderer, "software") == 0;
}

static void gpu_join(void) {
    if (!gpu_thread) return;
    WaitForSingleObject(gpu_thread, INFINITE);
    CloseHandle(gpu_thread);
    gpu_thread = NULL;
}

/* The worker's renderer replaces the software one, at the start of a frame
 * on the UI thread. */
static int gpu_switch(cui_app *app, cui_gl_renderer *renderer) {
    app->gl = renderer;
    cui_renderer_iface iface = cui_gl_iface(renderer);
    cui_set_renderer(app->ui, &iface);   /* frees the software atlas; GL re-uploads it */
    app->software = false;
    if (app->sw) cui_sw_destroy(app->sw);
    app->sw = NULL;
    free(app->sw_pixels);
    app->sw_pixels = NULL;
    app->sw_w = app->sw_h = 0;
    cui_request_redraw(app->ui);
    return 1;
}

int kest_gpu_adopt(cui_app *app) {
    HWND window = (HWND)cui_app_native_window(app);
    LONG state = InterlockedCompareExchange(&gpu_state, 0, 0);
    if (state == KEST_GPU_DONE) return 1;
    if (state == KEST_GPU_IDLE) {
        if (gpu_software_requested()) { gpu_state = KEST_GPU_DONE; return 1; }
        /* The first frame paints first: loading the driver holds the loader
         * lock, which would otherwise delay creating and showing the window. */
        if (!app->presented_once) return 0;
        gpu_notify = window;
        gpu_state = KEST_GPU_RUNNING;
        /* Commit 256 KiB; the stack still grows to the image's 16 MiB reservation. */
        gpu_thread = CreateThread(NULL, 256 * 1024, gpu_worker, NULL, 0, NULL);
        if (gpu_thread) return 0;
        state = gpu_state = KEST_GPU_FAILED;
    }
    if (state == KEST_GPU_RUNNING) return 0;
    gpu_join();
    gpu_state = KEST_GPU_DONE;
    if (state == KEST_GPU_READY) {
        HDC dc = GetDC(window);   /* the window's own DC (CS_OWNDC), which CUI also holds */
        bool ok = dc && SetPixelFormat(dc, gpu_format, &gpu_pfd) && wglMakeCurrent(dc, gpu_context);
        if (dc) ReleaseDC(window, dc);
        if (ok) {
            kest_swap_interval_fn swap = (kest_swap_interval_fn)(void *)wglGetProcAddress("wglSwapIntervalEXT");
            if (swap) swap(1);
            return gpu_switch(app, gpu_renderer);
        }
        /* The objects die with the context; the renderer's memory is freed. */
        wglDeleteContext(gpu_context);
        gpu_context = NULL;
        free(gpu_renderer);
        gpu_renderer = NULL;
        return 1;
    }
    /* The worker failed: CUI's own path, as before. */
    if (cui__plat_gl_create(app, true)) {
        cui_gl_renderer *renderer = cui_gl_create(cui__plat_gl_proc);
        if (renderer) return gpu_switch(app, renderer);
    }
    return 1;
}

void kest_gpu_release(void) {
    gpu_join();
    if (gpu_context) {
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(gpu_context);
        gpu_context = NULL;
    }
    gpu_renderer = NULL;   /* destroyed with the app */
}
