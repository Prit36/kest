/* DirectWrite grid fitting at the actual device-pixel size. The resulting
 * grayscale atlas works identically in CUI's GL and software renderers. */
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <dwrite.h>
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

int kest_font_bitmap(kest_font *f, unsigned glyph, float size, float shift,
                     int *x, int *y, int *w, int *h, uint8_t **pixels) {
    *pixels = NULL;
    if (!f || glyph > 65535) return 0;
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
    if (count > UINT32_MAX / 3) goto fail;
    uint8_t *rgb = malloc(count * 3), *gray = malloc(count);
    if (!rgb || !gray) { free(rgb); free(gray); goto fail; }
    hr = IDWriteGlyphRunAnalysis_CreateAlphaTexture(analysis, DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, rgb, (UINT32)(count * 3));
    if (FAILED(hr)) { free(rgb); free(gray); goto fail; }
    /* Collapse the three samples to neutral coverage: no RGB panel-order
     * assumption or colored fringes, including on transparent surfaces. */
    for (size_t i = 0; i < count; i++) gray[i] = (uint8_t)(((unsigned)rgb[i*3] + rgb[i*3+1] + rgb[i*3+2] + 1) / 3);
    free(rgb); *pixels = gray;
    IDWriteGlyphRunAnalysis_Release(analysis); return 1;
fail:
    IDWriteGlyphRunAnalysis_Release(analysis); return 0;
}
