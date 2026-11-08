/* DirectWrite glyph coverage at the actual device-pixel size: ClearType
 * subpixel coverage where the system smooths text with ClearType, grayscale
 * otherwise. Blending (contrast and gamma) happens in the renderers. */
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <stdlib.h>
#include <string.h>
#include "text_win32.h"

typedef struct {
    IDWriteFontFileStream iface;
    LONG refs;
    const void *bytes;
    UINT64 size;
} kest_stream;
typedef struct {
    IDWriteFontFileLoader iface;
    LONG refs;
    const void *bytes;
    UINT64 size;
} kest_loader;
struct kest_font {
    IDWriteFactory *factory;
    IDWriteFontFace *face;
    kest_loader *loader;
};

static ULONG STDMETHODCALLTYPE stream_add(IDWriteFontFileStream *self) {
    return InterlockedIncrement(&((kest_stream *)self)->refs);
}
static ULONG STDMETHODCALLTYPE stream_release(IDWriteFontFileStream *self) {
    LONG refs = InterlockedDecrement(&((kest_stream *)self)->refs);
    if (!refs) free(self);
    return refs;
}
static HRESULT STDMETHODCALLTYPE stream_query(IDWriteFontFileStream *self, REFIID id, void **out) {
    *out = NULL;
    if (!IsEqualIID(id, &IID_IUnknown) && !IsEqualIID(id, &IID_IDWriteFontFileStream)) return E_NOINTERFACE;
    *out = self; stream_add(self); return S_OK;
}
static HRESULT STDMETHODCALLTYPE stream_read(IDWriteFontFileStream *self, const void **out, UINT64 offset, UINT64 size, void **context) {
    kest_stream *s = (kest_stream *)self;
    *out = NULL; *context = NULL;
    if (offset > s->size || size > s->size - offset) return E_FAIL;
    *out = (const char *)s->bytes + (size_t)offset;
    return S_OK;
}
static void STDMETHODCALLTYPE stream_fragment(IDWriteFontFileStream *self, void *context) { (void)self; (void)context; }
static HRESULT STDMETHODCALLTYPE stream_size(IDWriteFontFileStream *self, UINT64 *size) {
    *size = ((kest_stream *)self)->size; return S_OK;
}
static HRESULT STDMETHODCALLTYPE stream_time(IDWriteFontFileStream *self, UINT64 *time) { (void)self; *time = 0; return E_NOTIMPL; }
static const IDWriteFontFileStreamVtbl stream_vtable = {
    stream_query, stream_add, stream_release, stream_read, stream_fragment, stream_size, stream_time
};
static ULONG STDMETHODCALLTYPE loader_add(IDWriteFontFileLoader *self) {
    return InterlockedIncrement(&((kest_loader *)self)->refs);
}
static ULONG STDMETHODCALLTYPE loader_release(IDWriteFontFileLoader *self) {
    LONG refs = InterlockedDecrement(&((kest_loader *)self)->refs);
    if (!refs) free(self);
    return refs;
}
static HRESULT STDMETHODCALLTYPE loader_query(IDWriteFontFileLoader *self, REFIID id, void **out) {
    *out = NULL;
    if (!IsEqualIID(id, &IID_IUnknown) && !IsEqualIID(id, &IID_IDWriteFontFileLoader)) return E_NOINTERFACE;
    *out = self; loader_add(self); return S_OK;
}
static HRESULT STDMETHODCALLTYPE loader_stream(IDWriteFontFileLoader *self, const void *key, UINT32 key_size, IDWriteFontFileStream **out) {
    (void)key; (void)key_size;
    kest_loader *l = (kest_loader *)self;
    *out = NULL;
    kest_stream *s = calloc(1, sizeof *s);
    if (!s) return E_OUTOFMEMORY;
    s->iface.lpVtbl = &stream_vtable; s->refs = 1; s->bytes = l->bytes; s->size = l->size;
    *out = &s->iface; return S_OK;
}
static const IDWriteFontFileLoaderVtbl loader_vtable = { loader_query, loader_add, loader_release, loader_stream };

void kest_font_destroy(kest_font *f) {
    if (!f) return;
    if (f->face) IDWriteFontFace_Release(f->face);
    if (f->factory && f->loader) IDWriteFactory_UnregisterFontFileLoader(f->factory, &f->loader->iface);
    if (f->loader) loader_release(&f->loader->iface);
    if (f->factory) IDWriteFactory_Release(f->factory);
    free(f);
}
kest_font *kest_font_create(const void *bytes, size_t size) {
    if (!bytes || size < 12) return NULL;
    kest_font *f = calloc(1, sizeof *f);
    if (!f) return NULL;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, &IID_IDWriteFactory, (IUnknown **)&f->factory))) goto fail;
    f->loader = calloc(1, sizeof *f->loader);
    if (!f->loader) goto fail;
    f->loader->iface.lpVtbl = &loader_vtable; f->loader->refs = 1;
    f->loader->bytes = bytes; f->loader->size = size;
    if (FAILED(IDWriteFactory_RegisterFontFileLoader(f->factory, &f->loader->iface))) goto fail;
    IDWriteFontFile *file = NULL;
    const UINT32 key = 0;
    if (FAILED(IDWriteFactory_CreateCustomFontFileReference(f->factory, &key, sizeof key, &f->loader->iface, &file))) goto fail;
    BOOL supported; DWRITE_FONT_FILE_TYPE file_type; DWRITE_FONT_FACE_TYPE face_type; UINT32 faces;
    HRESULT hr = IDWriteFontFile_Analyze(file, &supported, &file_type, &face_type, &faces);
    if (SUCCEEDED(hr) && supported && faces)
        hr = IDWriteFactory_CreateFontFace(f->factory, face_type, 1, &file, 0, DWRITE_FONT_SIMULATIONS_NONE, &f->face);
    IDWriteFontFile_Release(file);
    if (FAILED(hr) || !f->face) goto fail;
    return f;
fail:
    kest_font_destroy(f); return NULL;
}

static kest_text_params text_params;
static bool text_params_ready;
static bool text_bgr;

/* DirectWrite's alpha correction ratios for gamma 1.0..2.2 (from Windows
 * Terminal's dwrite_helpers.cpp, MIT; the values DirectWrite itself uses). */
static void gamma_ratios(float gamma, float out[4]) {
    static const float table[13][4] = {
        { 0.0000f, 0.0000f, 0.0000f, 0.0000f }, { 0.0166f, -0.0807f, 0.2227f, -0.0751f },
        { 0.0350f, -0.1760f, 0.4325f, -0.1370f }, { 0.0543f, -0.2821f, 0.6302f, -0.1876f },
        { 0.0739f, -0.3963f, 0.8167f, -0.2287f }, { 0.0933f, -0.5161f, 0.9926f, -0.2616f },
        { 0.1121f, -0.6395f, 1.1588f, -0.2877f }, { 0.1300f, -0.7649f, 1.3159f, -0.3080f },
        { 0.1469f, -0.8911f, 1.4644f, -0.3234f }, { 0.1627f, -1.0170f, 1.6051f, -0.3347f },
        { 0.1773f, -1.1420f, 1.7385f, -0.3426f }, { 0.1908f, -1.2652f, 1.8650f, -0.3476f },
        { 0.2031f, -1.3864f, 1.9851f, -0.3501f },
    };
    int i = (int)(gamma * 10.0f + 0.5f);
    i = (i < 10 ? 10 : i > 22 ? 22 : i) - 10;
    const float norm13 = (float)(65536.0 / (255.0 * 255.0) * 4.0) / 4.0f;
    const float norm24 = (float)(256.0 / 255.0 * 4.0) / 4.0f;
    out[0] = norm13 * table[i][0]; out[1] = norm24 * table[i][1];
    out[2] = norm13 * table[i][2]; out[3] = norm24 * table[i][3];
}

const kest_text_params *kest_text_params_get(void) {
    if (text_params_ready) return &text_params;
    text_params_ready = true;
    float gamma = 1.8f, contrast = 0.5f, gray_contrast = 1.0f;
    IDWriteFactory *factory = NULL;
    if (SUCCEEDED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory))) {
        IDWriteRenderingParams *params = NULL;
        if (SUCCEEDED(IDWriteFactory_CreateRenderingParams(factory, &params))) {
            gamma = IDWriteRenderingParams_GetGamma(params);
            contrast = IDWriteRenderingParams_GetEnhancedContrast(params);
            IDWriteRenderingParams1 *params1 = NULL;
            if (SUCCEEDED(IDWriteRenderingParams_QueryInterface(params, &IID_IDWriteRenderingParams1, (void **)&params1))) {
                gray_contrast = IDWriteRenderingParams1_GetGrayscaleEnhancedContrast(params1);
                IDWriteRenderingParams1_Release(params1);
            }
            IDWriteRenderingParams_Release(params);
        }
        IDWriteFactory_Release(factory);
    }
    BOOL smoothing = TRUE;
    UINT type = 2 /* FE_FONTSMOOTHINGCLEARTYPE */, orientation = 1 /* RGB */;
    SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0);
    SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &type, 0);
    SystemParametersInfoW(0x2012 /* SPI_GETFONTSMOOTHINGORIENTATION */, 0, &orientation, 0);
    gamma_ratios(gamma, text_params.gamma_ratios);
    text_params.cleartype_contrast = contrast;
    text_params.grayscale_contrast = gray_contrast;
    text_params.cleartype = smoothing && type == 2;
    text_params.corrected = true;
    text_bgr = orientation == 0;
    const char *mode = getenv("KEST_TEXT");
    if (mode && (!strcmp(mode, "grayscale") || !strcmp(mode, "legacy"))) text_params.cleartype = false;
    if (mode && !strcmp(mode, "legacy")) text_params.corrected = false;
    return &text_params;
}

int kest_font_bitmap(kest_font *f, unsigned glyph, float size, float shift,
                     int *x, int *y, int *w, int *h, uint8_t **pixels) {
    *pixels = NULL;
    if (!f || glyph > 65535) return 0;
    const kest_text_params *params = kest_text_params_get();
    UINT16 index = (UINT16)glyph;
    FLOAT advance = 0;
    DWRITE_GLYPH_OFFSET offset = {0};
    DWRITE_GLYPH_RUN run = { f->face, size, 1, &index, &advance, &offset, FALSE, 0 };
    IDWriteGlyphRunAnalysis *analysis = NULL;
    HRESULT hr = IDWriteFactory_CreateGlyphRunAnalysis(f->factory, &run, 1, NULL,
        DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL, shift, 0, &analysis);
    if (FAILED(hr)) return 0;
    RECT bounds;
    hr = IDWriteGlyphRunAnalysis_GetAlphaTextureBounds(analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds);
    if (FAILED(hr)) goto fail;
    *x = bounds.left; *y = bounds.top; *w = bounds.right - bounds.left; *h = bounds.bottom - bounds.top;
    if (*w <= 0 || *h <= 0) { IDWriteGlyphRunAnalysis_Release(analysis); return 1; }
    size_t count = (size_t)*w * (size_t)*h;
    if (count > UINT32_MAX / 4) goto fail;
    uint8_t *rgb = malloc(count * 3), *out = malloc(count * 4);
    if (!rgb || !out) { free(rgb); free(out); goto fail; }
    hr = IDWriteGlyphRunAnalysis_CreateAlphaTexture(analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, rgb, (UINT32)(count * 3));
    if (FAILED(hr)) { free(rgb); free(out); goto fail; }
    for (size_t i = 0; i < count; i++) {
        uint8_t r = rgb[i*3], g = rgb[i*3+1], b = rgb[i*3+2];
        uint8_t mean = (uint8_t)(((unsigned)r + g + b + 1) / 3);
        if (!params->cleartype) r = g = b = mean;
        else if (text_bgr) { uint8_t t = r; r = b; b = t; }
        out[i*4] = r; out[i*4+1] = g; out[i*4+2] = b; out[i*4+3] = mean;
    }
    free(rgb); *pixels = out;
    IDWriteGlyphRunAnalysis_Release(analysis); return 1;
fail:
    IDWriteGlyphRunAnalysis_Release(analysis); return 0;
}
