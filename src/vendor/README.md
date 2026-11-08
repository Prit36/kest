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
CUI's bundled fonts as their fallbacks. The Windows font files are mapped
read-only (`kest_file_map`) rather than read into memory, and unmapped when the
context's fonts are destroyed. Font metrics, kerning, layout, icons and
cache keys remain CUI's. If a native face or glyph cannot be rendered, the
original stb rasterization is used.

## `cui_textedit.c`

Local changes: a boxed field's outline strengthens fully on hover, so fields
read as editable rather than clickable; an edit menu in every text field. A right-click focuses the
field and places the caret (keeping a selection it lands in), then opens Undo,
Redo, Cut, Copy, Paste, Delete and Select all (Copy and Select all for
read-only fields; nothing that copies a password). A chosen command is kept
until the field's next frame and runs through the same code as its shortcut.
A caller can set `kest_edit_menu_owned` so that its own menu answers the
right-click instead; table cells do, and `kest_edit_menu_items` adds the
cell's edit commands to the top of the row menu. The interface is
`src/kest_edit.h`.

## `cui_overlay.c`

Local changes: a context menu (opened at the pointer) closes on a press
anywhere outside it, including on the view it was opened on; a menu trigger
still toggles its own menu. Menus also close when the window loses focus. A
tooltip on a wide or tall anchor (a tree row, a field) appears at the pointer
instead of centered over the anchor, and so does one whose anchor the pointer
is not on. A one-line toast centers its icon, title and buttons vertically,
and toast buttons stay out of the Tab order so keyboard focus is never
trapped in a toast.

## `cui_draw.c`

Local changes: outlines up to three device pixels wide are snapped to whole
device pixels, so all four sides of a border or focus ring are equally sharp at
fractional display scales. A focus ring that would be cut off by a clipping
box (an icon inside the URL bar, a cell) is drawn just inside its control
instead, with a background line that keeps it visible on filled buttons.

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
