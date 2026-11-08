/* Edit commands shared by CUI text fields (src/vendor/cui_textedit.c) and
 * Kest's own editors. */
#ifndef KEST_EDIT_H
#define KEST_EDIT_H

#include <stdbool.h>
#include "cui/cui.h"

enum {
    KEST_EDIT_NONE = 0,
    KEST_EDIT_UNDO,
    KEST_EDIT_REDO,
    KEST_EDIT_CUT,
    KEST_EDIT_COPY,
    KEST_EDIT_PASTE,
    KEST_EDIT_DELETE,
    KEST_EDIT_SELECT_ALL,
};

/* Runs `command` in the text field `id` on its next frame and focuses it. */
void kest_edit_request(cui_ctx *ui, cui_id id, int command);
/* Adds the field's Undo/Redo/Cut/Copy/Paste/Delete/Select all items to the
 * menu being built. */
void kest_edit_menu_items(cui_ctx *ui, cui_id id);
/* Set before building a text field whose right-click opens its owner's menu
 * instead of the field's own; the field clears it. */
extern bool kest_edit_menu_owned;
/* The text field or editor the app's Edit menu acts on: the one focused
 * last. Fields and editors set it while focused. */
extern cui_id kest_edit_target;
/* Called once a frame before anything is built: the target is dropped once
 * focus moves to something else, unless that is the Edit menu (`keep`, open
 * or not). */
void kest_edit_target_track(cui_ctx *ui, cui_id keep, bool menu_open);

#endif
