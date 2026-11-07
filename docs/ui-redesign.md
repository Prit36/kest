# Kest workspace and visual identity

Kest uses T3 Code's default neutral dark and light palettes, with blue primary
actions and an angular K mark shared by the native header and Windows icon.

[Bruno](https://github.com/usebruno/bruno) informed the request workflow:
its [joined composer](https://github.com/usebruno/bruno/blob/main/packages/bruno-app/src/components/RequestPane/QueryUrl/index.js),
[direct-entry parameter table](https://github.com/usebruno/bruno/blob/main/packages/bruno-app/src/components/RequestPane/QueryParams/index.js)
and [collection interactions](https://github.com/usebruno/bruno/blob/main/packages/bruno-app/src/components/Sidebar/SidebarRowStyles/index.js).
Bruno remains an interaction reference. The colors now follow
[T3 Code's default palette](https://github.com/pingdotgg/t3code/blob/main/packages/shared/src/themePalettes.ts),
mapped to CUI roles. Kest retains its own branding. The native implementation
adds no React, Electron or runtime dependencies.

## Visual system

Dark mode uses T3 Code's black sidebar (#000000), near-black shell (#0a0a0a),
neutral editing surfaces (#111111), light text (#f5f5f5) and blue actions (#346bf1).
Light mode uses its off-white shell (#fcfcfc), white editors, gray sidebar (#fafafa),
dark text (#27272a) and blue actions (#1b4ed8). Borders and hover states stay
neutral. The former tinted steel-blue and warm-paper palette has been removed.
Control tracks, overlays, menus, selections and the Windows icon follow the
same neutral treatment. Code keys, strings, numbers and keywords use distinct,
readable blue, green, orange and purple syntax colors.

Pane tabs use an inset filled selection. Active documents and collection entries
have a short vertical marker. Their labels and backgrounds also change, so
selection remains identifiable through shape and contrast. Primary buttons are
flat. Menus use small corners and short, restrained shadows. The K mark is
vector geometry drawn by CUI. Its SVG source also generates the multi-size ICO
and PNG, so the title bar, taskbar, executable and in-app mark stay consistent.

HTTP methods and response statuses retain semantic colors plus their text labels.
The existing control sizes, editor geometry and keyboard behavior are retained.

## Workspace and controls

The workspace is an edge-to-edge editing surface with a compact collection
browser and flat document tabs. Wide windows show request and response beside
one another. Narrow windows stack them. The Layout menu chooses automatic,
side-by-side or stacked editing; insufficient width always falls back to stacking.
The explicit layout choice and column divider belong to the current session.
The existing saved vertical split and sidebar width are retained.

A single method dropdown is part of the bordered URL group, beside a URL field
and Save action. Standard and custom HTTP methods remain supported. Send is the
primary action. The collection/request breadcrumb replaces a repeated large
request heading and permits renaming. New requests open from the document strip
or Ctrl+N. Selecting or opening a request reveals its document tab and collection
ancestors; manual collection browsing does not get reset on every frame.

Params, headers, form fields and environment variables use aligned table cells.
The final empty row is always editable. Its first keystroke promotes the same
row and identity into request data, retaining focus, selection and undo history.
Tab moves from name to value. Unused insertion rows are excluded from persisted
requests. Enable switches and delete actions belong to populated rows; duplication
is available from their context menu. Bulk edit has explicit Apply and Cancel.

Body types use a dropdown with format/find actions and a compact actions menu,
so controls fit beside the response. Request settings retain their units and TLS
explanation. The request chevron focuses the response; selecting a request pane
restores the editor. Collection actions are available through visible row menus
and right-click. History and environment rows use the same control geometry.

Responses open as formatted, syntax-colored code with line numbers. The response
format menu provides tree, minified and raw views. Response headers have a table
with per-row copying. Preview is directly available for images and HTML; other
preview modes remain in the menu. Status, duration and size sit in the response
tab row beside the format menu, with find, copy and save when the panel is wide
enough (all three stay in the response menu).

Dialogs use concrete Create/Save/Move actions. Name dialogs accept Enter and
focus their field on repeated opens. Environment/settings changes already save
as edited, so those dialogs offer Close. The environment table fits at 640x420.

Transitions, theme changes and the caret are steady: reduced motion is enabled
for every native and headless frame. Nothing starts an animation or polling loop.

## Verification

Debug and ReleaseFast engine/HTTP and CUI interaction checks passed. In-process
pointer/text/key events exercise direct row entry, continued typing, Tab to value,
URL synchronization, standard/custom methods, body types, environment selection,
repeated dialog focus and Enter, overflowing tabs and their close action, response
format selection, header tables, collection activation and response focus.
A forty-collection regression exercises menus without exhausting CUI popup slots;
closed row menus now allocate a popup only when opened. The minimum-size check
requires both the populated table row and its insertion row to be visible.
Existing loopback, undo, import/export, bounded-response and reload checks remain.

Diagnostic captures include actual loopback JSON, populated params, body,
settings, history, environments, focused response, dark/light, stacked and compact
views, response headers and the compact environment dialog. All use explicit
scratch KEST_DATA. See performance.md for the native private-desktop startup,
idle and exit observations and the separate UI CPU sample.

OS clipboard, accessibility, IME/complex scripts and real desktop input remain
unverified; supported_features.md records the existing platform/editor limits.

## Empty-state layout correction

History now distinguishes an unused history from an active filter with no matches.
Both use the same 14px inset and bounded wrapping as collection/environment empty
states. A filtered view offers Reset filters, clearing search, method and status
and explicitly requesting one redraw. Empty views scroll if necessary; their
content does not run underneath the sidebar footer. There is no destructive clear
button when history is empty. The compact filter controls and footer reserve enough label
space at the 210px sidebar minimum.

The headless regression checks title/body separation, left/right bounds, complete
reset-button visibility and actual reset/recovery of loopback history. It runs in
dark/light mode at the minimum sidebar width and inside the 640x420 sheet.
Snapshots include `-history-empty`, `-history-filtered` and
`-history-compact-filtered` beside the normal workspace captures.

## CUI 1.1 follow-up

The UI polish pass gives the collection browser one flexible column, so names
truncate before the fixed 28px action buttons and the buttons follow the right
edge during resizing. Rows use the sidebar surface without table dividers;
request methods have a consistent-width semantic label. Native tree navigation,
selection and menus remain in use. Search resets the grid's actual scroll state.
Dropdown triggers fit compact toolbar rows and bounded labels preserve their
chevrons. Settings descriptions, response messages, header cells and empty states
respect pane widths. Multipart file toggles have a dedicated header and centered
checkbox; running requests show a Cancel tooltip and failed history shows Failed.
The sidebar regression covers long names, grow/shrink cycles, dark/light and the
compact sheet. Diagnostic captures also include multipart at desktop/minimum size.

The current application uses native CUI document tabs, tree table, path bar and
activity console. The original custom document-strip painter has been removed.
Native tabs retain request method/name, stable identity, unsaved state, close
confirmation and overflow reveal, and add keyboard/mouse reordering. The path bar
reveals collections and folders; layout choice and column divider position now
persist. Markdown preview uses the new renderer within a 256 KiB bound. See
[CUI 1.1 update](cui-1.1-update.md) for integration details and validation.
