/* Native glyph coverage and DirectWrite-style text blending.
 *
 * Glyphs are rasterized by DirectWrite into an RGBA atlas: with ClearType each
 * channel holds the coverage of one subpixel (in the panel's order), otherwise
 * all three hold the same grayscale coverage. Coverage is linear; the renderers
 * apply DirectWrite's contrast enhancement and gamma alpha correction at blend
 * time, from the system's rendering parameters, because the correction depends
 * on the text color. Font bytes remain owned by CUI. */
#ifndef KEST_TEXT_WIN32_H
#define KEST_TEXT_WIN32_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct kest_font kest_font;
kest_font *kest_font_create(const void *bytes, size_t size);
void kest_font_destroy(kest_font *font);
/* RGBA coverage, 4 bytes a pixel, w*h pixels (free with free()). */
int kest_font_bitmap(kest_font *font, unsigned glyph, float size, float shift,
                     int *x, int *y, int *w, int *h, uint8_t **pixels);

/* The system's text rendering settings, read once. KEST_TEXT=grayscale turns
 * subpixel rendering off; KEST_TEXT=legacy also skips the gamma correction. */
typedef struct kest_text_params {
    float gamma_ratios[4];      /* DirectWrite alpha correction for the system gamma */
    float cleartype_contrast;   /* IDWriteRenderingParams::GetEnhancedContrast */
    float grayscale_contrast;   /* IDWriteRenderingParams1::GetGrayscaleEnhancedContrast */
    bool cleartype;             /* subpixel coverage in the atlas */
    bool corrected;             /* apply contrast/gamma correction when blending */
} kest_text_params;
const kest_text_params *kest_text_params_get(void);

/* DirectWrite's blend (after Windows Terminal's dwrite_helpers.hlsl, MIT):
 * turns linear glyph coverage `cov` into the per-channel alpha for text of
 * straight color (r, g, b) at opacity `a`. Must match the GL shader. */
static inline float kest__sat(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
static inline void kest_text_alpha(const kest_text_params *p, float r, float g, float b, float a, float cov[3]) {
    if (!p->corrected) { for (int i = 0; i < 3; i++) cov[i] = kest__sat(cov[i]) * a; return; }
    const float *q = p->gamma_ratios;
    float light = kest__sat(3.0f - 4.0f * (0.30f * r + 0.59f * g + 0.11f * b));
    if (p->cleartype) {
        float k = p->cleartype_contrast * light;
        float f[3] = { r, g, b };
        for (int i = 0; i < 3; i++) {
            float c = cov[i] * (k + 1.0f) / (cov[i] * k + 1.0f);
            c = c + c * (1.0f - c) * ((q[0] * f[i] + q[1]) * c + (q[2] * f[i] + q[3]));
            cov[i] = kest__sat(c) * a;
        }
    } else {
        float k = p->grayscale_contrast * light;
        float intensity = 0.25f * r + 0.5f * g + 0.25f * b;
        float c = cov[1] * (k + 1.0f) / (cov[1] * k + 1.0f);
        c = kest__sat(c + c * (1.0f - c) * ((q[0] * intensity + q[1]) * c + (q[2] * intensity + q[3]))) * a;
        cov[0] = cov[1] = cov[2] = c;
    }
}
#endif
