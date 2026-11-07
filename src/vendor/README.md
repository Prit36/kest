# CUI text integration

`cui_text.c` is the MIT-licensed text module from the pinned CUI commit
`d0383c4d3c00b7769f6b11cefdf581e1800f2da3`. Its license is in `CUI-LICENSE`.
The build compiles this file instead of the dependency's text module; the
downloaded package cache is never modified.

Local changes include the `text_win32.h` adapter, an adjusted stb include path,
one native font handle per loaded font, destruction before font bytes are freed,
and DirectWrite coverage in the glyph atlas. Font metrics, kerning, layout,
icons, cache keys, and texture upload remain CUI's. If a native face or glyph
cannot be rendered, the original stb rasterization is used.

When updating CUI, compare this file against the new upstream text module and
reapply these changes. Run `zig build test` and inspect dark/light snapshots at
100%, 125%, 150%, and 200% using the diagnostic `--scale` argument.
