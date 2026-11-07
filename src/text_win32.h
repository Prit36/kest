/* Native grayscale glyph coverage; font bytes remain owned by CUI. */
#ifndef KEST_TEXT_WIN32_H
#define KEST_TEXT_WIN32_H
#include <stddef.h>
#include <stdint.h>
typedef struct kest_font kest_font;
kest_font *kest_font_create(const void *bytes, size_t size);
void kest_font_destroy(kest_font *font);
int kest_font_bitmap(kest_font *font, unsigned glyph, float size, float shift,
                     int *x, int *y, int *w, int *h, uint8_t **pixels);
#endif
