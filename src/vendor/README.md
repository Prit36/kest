# CUI vendored modules

These files are MIT-licensed modules from the pinned CUI commit
`d0383c4d3c00b7769f6b11cefdf581e1800f2da3`; the license is in `CUI-LICENSE`.
The build compiles them instead of the dependency's copies; the downloaded
package cache is never modified.

## `cui_text.c`

Local changes: the `text_win32.h` adapter, an adjusted stb include path, one
native font handle per loaded font, destruction before font bytes are freed,
DirectWrite coverage in the glyph atlas, an RGBA atlas (one coverage value per
ClearType subpixel), and the Windows UI fonts (Segoe UI, Segoe UI Semibold,
Cascadia Mono or Consolas) in the body, medium, display and mono roles, with
CUI's bundled fonts as their fallbacks. Font metrics, kerning, layout, icons and
cache keys remain CUI's. If a native face or glyph cannot be rendered, the
original stb rasterization is used.

## `cui_render_gl.c` and `cui_render_sw.c`

Local changes: include paths, and text blending. Glyph coverage is read from the
RGBA atlas and turned into per-channel alpha with DirectWrite's contrast
enhancement and gamma alpha correction (`kest_text_alpha` in `text_win32.h`,
after Windows Terminal's `dwrite_helpers.hlsl`, MIT). The GL renderer blends
ClearType text with dual-source blending (`GL_ONE, GL_ONE_MINUS_SRC1_COLOR`);
every other shape writes its alpha to the second output, which is equivalent to
CUI's original premultiplied blending. The software renderer does the same per
pixel.

## Updating CUI

Compare these files against the new upstream modules and reapply the changes.
Run `zig build test` and inspect dark/light snapshots at 100%, 125%, 150% and
200% using the diagnostic `--scale` argument.
