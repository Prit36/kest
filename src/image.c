/* Decode only on demand; refuse image expansion past 64 MiB before allocating. */
#include "host.h"
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_MAX_DIMENSIONS 8192
#include "third_party/stb_image.h"
cui_texture retort_image_memory(cui_ctx *ui, const unsigned char *bytes, int length, int *out_width, int *out_height) {
    int width, height, channels;
    if (!stbi_info_from_memory(bytes, length, &width, &height, &channels)) return 0;
    if (width <= 0 || height <= 0 || (size_t)width * (size_t)height > 16 * 1024 * 1024) return 0;
    unsigned char *rgba = stbi_load_from_memory(bytes, length, &width, &height, &channels, 4);
    if (!rgba) return 0;
    cui_texture image = cui_image_create(ui, width, height, rgba);
    *out_width = width;
    *out_height = height;
    stbi_image_free(rgba);
    return image;
}
