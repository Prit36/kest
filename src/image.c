/* Worker-only CPU decode. Refuse expansion past 64 MiB before allocating;
   publish at most a 2048px preview so UI texture upload is bounded to 16 MiB. */
#include "host.h"
#include <stdlib.h>
/* Charge cumulative allocation requests rather than tracking live blocks:
   decoded pixels may be freed by the UI thread. This also bounds malformed
   compressed streams whose inflated data disagrees with their dimensions. */
static __declspec(thread) size_t kest_decode_remaining;
static __declspec(thread) int kest_decode_failure;
static void *kest_decode_malloc(size_t size) {
    if (size > kest_decode_remaining) { kest_decode_failure = 2; return NULL; }
    kest_decode_remaining -= size;
    void *result = malloc(size);
    if (!result) kest_decode_failure = 3;
    return result;
}
static void *kest_decode_realloc(void *ptr, size_t size) {
    if (size > kest_decode_remaining) { kest_decode_failure = 2; return NULL; }
    kest_decode_remaining -= size;
    void *result = realloc(ptr, size);
    if (!result) kest_decode_failure = 3;
    return result;
}
#define STBI_MALLOC(n) kest_decode_malloc(n)
#define STBI_REALLOC(p,n) kest_decode_realloc(p,n)
#define STBI_FREE(p) free(p)
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_MAX_DIMENSIONS 8192
#include "third_party/stb_image.h"
unsigned char *kest_image_decode(const unsigned char *bytes, int length, int *out_width, int *out_height, int *source_width, int *source_height, int *failure) {
    kest_decode_remaining = 192 * 1024 * 1024;
    kest_decode_failure = 1;
    *failure = 1;
    int width, height, channels;
    if (!bytes || length <= 0) return NULL;
    if (!stbi_info_from_memory(bytes, length, &width, &height, &channels)) { *failure = kest_decode_failure; return NULL; }
    if (width <= 0 || height <= 0 || (size_t)width * (size_t)height > 16 * 1024 * 1024) { *failure = 2; return NULL; }
    unsigned char *rgba = stbi_load_from_memory(bytes, length, &width, &height, &channels, 4);
    if (!rgba) { *failure = kest_decode_failure; return NULL; }
    *source_width = width;
    *source_height = height;
    if (width > 2048 || height > 2048) {
        int longest = width > height ? width : height;
        int preview_width = width * 2048 / longest;
        int preview_height = height * 2048 / longest;
        if (preview_width < 1) preview_width = 1;
        if (preview_height < 1) preview_height = 1;
        unsigned char *preview = (unsigned char *)STBI_MALLOC((size_t)preview_width * preview_height * 4);
        if (!preview) { *failure = kest_decode_failure; stbi_image_free(rgba); return NULL; }
        for (int y = 0; y < preview_height; ++y) {
            size_t row = (size_t)(y * height / preview_height) * width;
            for (int x = 0; x < preview_width; ++x) {
                size_t src = row + (size_t)(x * width / preview_width);
                size_t dst = (size_t)y * preview_width + x;
                memcpy(preview + dst * 4, rgba + src * 4, 4);
            }
        }
        stbi_image_free(rgba);
        rgba = preview;
        width = preview_width;
        height = preview_height;
    }
    *out_width = width;
    *out_height = height;
    *failure = 0;
    return rgba;
}
void kest_image_free(unsigned char *rgba) { stbi_image_free(rgba); }
