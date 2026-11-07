/* Exercise the actual bundled fonts, including fractional monitor scales. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "text_win32.h"
#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "third_party/stb_truetype.h"
extern size_t cui__inflate(const void *, size_t, void *, size_t);
#define FONT(n) extern const unsigned char n[]; extern const unsigned int n##_size, n##_packed;
FONT(cui_font_inter_regular)
FONT(cui_font_inter_medium)
FONT(cui_font_geist_medium)
FONT(cui_font_geist_mono)
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "text rendering: line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) {
    const unsigned char *packed[] = { cui_font_inter_regular, cui_font_inter_medium, cui_font_geist_medium, cui_font_geist_mono };
    unsigned sizes[] = { cui_font_inter_regular_size, cui_font_inter_medium_size, cui_font_geist_medium_size, cui_font_geist_mono_size };
    unsigned lengths[] = { cui_font_inter_regular_packed, cui_font_inter_medium_packed, cui_font_geist_medium_packed, cui_font_geist_mono_packed };
    float ems[] = { 11, 12, 13, 13 * 1.25f, 13 * 1.5f, 13 * 1.75f, 26 };
    char invalid[16] = {0};
    CHECK(!kest_font_create(invalid, sizeof invalid));
    kest_font_destroy(NULL);
    for (unsigned f = 0; f < 4; f++) {
        unsigned char *bytes = malloc(sizes[f]);
        CHECK(bytes && cui__inflate(packed[f], lengths[f], bytes, sizes[f]) == sizes[f]);
        stbtt_fontinfo info;
        CHECK(stbtt_InitFont(&info, bytes, 0));
        int glyph = stbtt_FindGlyphIndex(&info, 'H'), space = stbtt_FindGlyphIndex(&info, ' ');
        CHECK(glyph && space);
        /* Repeated load/release also exercises COM loader/stream ownership. */
        for (int cycle = 0; cycle < 8; cycle++) {
            kest_font *font = kest_font_create(bytes, sizes[f]);
            CHECK(font);
            for (unsigned e = 0; e < sizeof ems / sizeof *ems; e++) {
                unsigned sums[3] = {0};
                for (int phase = 0; phase < 3; phase++) {
                    int x, y, w, h; uint8_t *pixels;
                    CHECK(kest_font_bitmap(font, glyph, ems[e], phase / 3.0f, &x, &y, &w, &h, &pixels));
                    CHECK(pixels && w > 0 && h > 0 && w < ems[e] * 2 && h < ems[e] * 2 && y < 0);
                    unsigned max = 0, partial = 0;
                    for (int i = 0; i < w*h; i++) {
                        sums[phase] += pixels[i] * (unsigned)(i + 1);
                        if (pixels[i] > max) max = pixels[i];
                        if (pixels[i] && pixels[i] < 255) partial++;
                    }
                    CHECK(max > 160 && partial); /* visible stems and smooth edges */
                    free(pixels);
                }
                CHECK(sums[0] != sums[1] || sums[1] != sums[2]);
                int x, y, w, h; uint8_t *pixels;
                CHECK(kest_font_bitmap(font, space, ems[e], 0, &x, &y, &w, &h, &pixels));
                CHECK(!pixels && (!w || !h));
            }
            kest_font_destroy(font);
        }
        free(bytes);
    }
    puts("Native font rendering: bundled fonts, fractional DPI, subpixel phases, empty glyphs and lifecycle passed.");
    return 0;
}
