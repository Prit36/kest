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

Pane and document tabs share a flat selected surface and a restrained underline.
Collection entries retain a short vertical marker. Labels and backgrounds also
change, so selection remains identifiable through shape and contrast. Primary buttons are
flat. Menus use small corners and short, restrained shadows. The K mark is
vector geometry drawn by CUI. Its SVG source also generates the multi-size ICO
and PNG, so the title bar, taskbar, executable and in-app mark stay consistent.

HTTP methods and response statuses retain semantic colors plus their text labels.
Shared spacing, text, icon, radius and control metrics live in `ui/metrics.h`,
which Zig exposes through `ui/design.zig`; CUI theme roles use the same values.
Content strips have one Tab stop. Left/Right cycle sections, Home/End select
their first/last section, and focus follows selection. Document tabs retain
CUI's native closing, scrolling and reordering behavior. The underline snaps
inside the tab to avoid crossing its strip's baseline at fractional coordinates.

Document tabs use separate method, request-name, dirty-marker and close slots.
Widths range from 144 to 280 logical pixels and shrink within that range to keep
the selected tab visible beside fixed workspace actions. Standard methods have
a stable label width; custom methods can use more space. Full names appear on
hover and in the bounded, scrolling Tabs menu; unusually long hover text uses a
scrollable surface. Literal `##` and `###` in names do not change tab identities.
The active close button stays visible and inactive buttons appear on hover or
focus. Native middle-click close, dirty confirmation and keyboard reordering
remain available. Ctrl+Tab switching preserves document-strip keyboard focus.
The shared 64-request capacity also applies to saved-request opening and restart
restoration; omitted empty drafts cannot shift the restored selected request.

## Workspace and controls

The workspace is an edge-to-edge editing surface with a compact collection
browser and flat document tabs. Wide windows show request and response beside
one another. Narrow windows stack them. The Layout menu chooses automatic,
side-by-side or stacked editing; insufficient width always falls back to stacking.
Layout uses available workspace width and offers request/response focus, both
panes and equal-split reset. Layout choice and split positions persist; focus
mode belongs to each open request's session. Sidebar width stays fixed across
window resizing and respects bounded minimum/maximum sizes. Pane dividers and
header boundaries use shared physical-pixel painting with one owner per edge.

The top toolbar exposes Commands and Activity at all supported widths. Activity
also opens with Ctrl+J; active requests show a contextual running count. The
generic status/shortcut footer is removed. Sidebar navigation, creation and
collection import live in its header; existing row export actions remain.
The compact console uses two log lines so multipart insertion stays visible.
Native window restoration preserves normal position/size/DPI and maximized
state, clamps stale bounds to a current monitor's work area, and keeps minimized
or maximized sizes out of the normal-window preference.

A single method dropdown is part of the URL group. The method slot stays 112
logical pixels wide across selection and custom editing. Standard methods and
PROPFIND display fully; longer custom tokens use a complete value in a bounded
scrolling menu and an editable, horizontally scrolling field. The URL takes the
remaining group width. Save is a separate secondary action beside the group,
showing a dirty dot or Saved. All execution-row controls share a 38-pixel height.
Send is the primary action and switches to Cancel while running. URL Enter sends
once; Ctrl+Enter sends/cancels from the workspace. Key repeats cannot dispatch
again, and a focused execution button cannot also activate from the shortcut.
Native focus, hover, pressed and disabled states remain visible.

The link control inside the URL group opens current URL details, showing the
environment, resolved/escaped URL, missing variable names and Copy resolved URL.
Successful resolution takes no extra toolbar row. Malformed URLs and unresolved
variables show a danger border and inline explanation; Send stays disabled until
valid, while Cancel stays available for an active request. The inspector resolves
the current text/environment with the same rules as request preparation; it
stores no resolved values or secrets in preferences or logs.

The collection/request breadcrumb replaces a repeated large
request heading using unboxed navigable segments; Rename is in Request actions.
New requests open from the document strip
or Ctrl+N. Selecting or opening a request reveals its document tab and collection
ancestors; manual collection browsing does not get reset on every frame.

Params, headers, form fields and environment variables use aligned table cells.
The final empty row is always editable. Its first keystroke promotes the same
row and identity into request data, retaining focus, selection and undo history.
Tab/Enter advance through name/value cells; Shift+Tab reverses, and Up/Down stay
in the same column. Navigation reveals virtualized targets and can leave the
table. Unused insertion rows are excluded from persisted requests. Compact
Parameter/Header/Field/Variable headings use distinct example placeholders;
values receive more width than names. Empty tables contain one clean editable
row. Each fixed-height row owns one physical-pixel bottom separator.

The header menu groups Add row and Bulk edit. Populated-row actions appear on
hover/focus, with right-click across the cell and Alt+Down/Shift+F10 access.
Their menu provides inspection, enable/disable, duplication, movement and
deletion. Full name/value inspection is explicit and scrollable; passive hints
contain no values. Invalid headers/control characters and unresolved variables
have current, non-destructive indicators. Configured header counts exclude
automatic headers, which have a separate read-only inspector using the actual
transport defaults and current case-insensitive overrides. Content-Length is
clearly marked as managed on send.

Params, Headers and form fields have distinct focus/undo/scroll scopes, and
environment tables include the environment id. Each newly opened bulk session
gets fresh text-editor undo state. Table-owned menus close if their view stops
rendering. Bulk edit has explicit Apply and Cancel.
Bulk replacement is transactional: a failed parse/allocation leaves the table
and editor text intact. Conventional lines accept JSON-quoted keys/values when
needed for exact round trips, plus disabled and upload flags. Query cells retain
repeated keys, raw spelling and `flag` versus `empty=`; rebuilding the URL protects
literal cell delimiters and percent signs. Stored cells are preferred only when
they describe the same URL, so old files continue to follow their actual URL.

Body types use a dropdown with Format JSON, Wrap, Find and a compact actions
menu. Raw-editor controls disappear for forms, files and no-body mode. Text/XML
keep editing and search without JSON-only formatting. The canvas retains native
font advances for UTF-8 caret/hit testing and two-space tab stops. Tab/Shift+Tab
indent/outdent a selection as one undoable edit; Enter retains LF/CRLF and
indentation, including a separate closing-bracket line. JSON bracket matching
ignores quoted strings. Ctrl+M toggles Tab focus traversal; Escape returns to the
selector. A restrained top focus line accompanies the active row and caret.
Soft wrap prefers whitespace, keeps logical line numbers on first visual rows,
and rebuilds only when source or wrap width changes; text/undo are unchanged.
JSON caches only strings crossing those visual rows, preserving key/value
colors without retaining every token or recoloring the document on idle frames.
The row index conservatively budgets UTF-8 bytes, so fallback glyphs may wrap
before the available width is exhausted. Unicode shaping, grapheme/IME behavior
and actual OS clipboard remain for the native/accessibility audit.

JSON errors are advisory and preserve invalid editable/sendable drafts. Go to
focuses the source location. Validation caches include body kind and current
environment revision; substituted errors are labeled Resolved JSON and do not
claim an offset in the template. Missing variables show a validation-pending
notice. Diagnostics contain static parser messages rather than source values.
Formatting remains a lossless, undoable operation on the configured text.
Multipart fields use a compact Text/File control, a browse button for file
values, and keyboard-accessible type/picker items in row actions. Values and
file flags survive body-type changes. URL-encoded forms treat their retained
values as text. Empty forms show one insertion row; populated forms have room
for two rows at minimum size, with virtual scrolling for the rest. File-row
inspection adds resolved file name, checked size and availability.

Binary mode has an editable templated path, Change/Choose file, Remove, and
file name/size details. Refresh explicitly rechecks metadata; completed sends
invalidate their cached paths. A bounded cache holds 16 checks with at most four
concurrent workers. Workers own immutable path copies and wake the UI once;
idle frames do not start file I/O. No file contents are read for presentation.
Missing/unresolved/invalid/non-regular/unreadable paths have static explanations.
The transport rejects non-regular files before connecting and retains normal
send-time file reads. Picker cancel/error preserves existing draft data.
Native OS picker operation and actual ACL-denial behavior remain unverified;
headless checks inject picker results and exercise real regular/missing files.
Request settings retain their units and TLS
explanation. Layout > Focus response focuses the response; selecting a request pane
restores the editor. Collection actions are available through row menus shown on the hovered or selected row
and right-click. History and environment rows use the same control geometry.

Responses open as formatted, syntax-colored code with line numbers. The response
format menu provides tree, minified and raw views. Response headers use a flat,
read-only virtualized table with selectable 512-byte previews and row actions.
There is no repeated header count, outer box, or full-value hover tooltip.
Preview is available for supported image, HTML and Markdown
responses. The response row measures its tab/metadata labels before choosing
what fits. Status stays visible; format, duration, size and a full reason phrase
use the remaining room. Formats move to the contextual menu when needed. Find,
copy and save stay in that menu. A bounded scrolling menu reveals keyboard
targets, including the last item in the longer JSON-tree menu. Status opens a
bounded scrolling execution inspector; metric tooltips explain measurements.

Status colors distinguish 2xx/3xx/4xx/5xx; cancelled/unknown outcomes use neutral
foreground. Settled status badge normal/hover colors pass the 4.5:1 numerical
contrast target in both themes. A measured zero remains 0 ms/0 B; missing timing
or size uses a dash. Duration uses ms, seconds or minutes; decoded sizes use IEC
units, with exact milliseconds/byte counts in details. HTTP errors remain valid
responses with readable bodies/headers. Transport failure categories are stored
separately rather than inferred from error strings.

Sending retains useful previous response data and view state under a Previous
response notice. Current elapsed/byte metrics read only the running job's
immutable/atomic fields. Completion releases the previous owner and resets
derived views for the new response. Clearing previous data does not cancel an
active job. Preflight failures preserve prior response data, mark the attempt
Not sent and display a concise inline explanation. A toast is used when the
response panel is hidden. Cancellation, timeout, partial transfers and execution
failures have non-modal, distinct notices with explicit technical disclosure.
Menus/inspectors close when their request disappears and defer notifications
that could otherwise intercept popup actions.

Completed request workers classify the entire in-memory response before
publishing it. JSON requires a single valid whole document, including strict
string escapes, controls and UTF-8. A MIME hint or JSON fragment is insufficient.
Malformed declared JSON has an inline location and uses the original text;
incomplete prefixes and the 4096-level inspection limit have distinct fallback
notices. Binary detection scans all available bytes and overrides text MIME
hints; non-UTF-8 data goes to hex. SVG uses XML, and binary data cannot enter
Markdown preview. No content detection rewrites response bytes. Pretty/minified
JSON output has a 16 MiB expansion limit and falls back to the source on failure.
Derived views now prepare lazily on at most two workers: JSON formatting and
trees, HTML stripping, image decoding, large raw indexes, and derived text
indexes/JSON continuation spans. Workers retain immutable HTTP jobs and never
touch tabs or CUI. The UI adopts completed indexes and creates image textures;
mode changes, Clear and tab closure abandon obsolete work without waiting.
Completion wakes the UI; there is no polling timer or unbounded task queue.

Preparation bounds are 8 MiB input, 16 MiB formatted output, 200,000 tree nodes
and 1,000,000 text rows. A busy index or resource failure shows a labeled original
prefix of at most 64 KiB, with raw copy/save access to available response bytes.
Small text indexes remain synchronous and bounded; read-only bracket matching
does not rescan JSON over 256 KiB. Tree labels cap their displayed bytes at UTF-8
boundaries while their copy source remains whole. Markdown retains its existing
256 KiB inline-render limit; its broader rendering/performance audit remains.

PNG/JPEG CPU decode checks dimensions/pixels and has a per-decode cumulative
allocation budget, including malformed compressed streams. Image previews reduce
to at most 2048 pixels per side on the worker, keeping UI uploads within 16 MiB.
The UI explains scaling; original response bytes are retained for saving.
Remaining copy/save semantics follow in 8b3c.

The 8b3a header slice preserves received order, casing, duplicate rows and raw
line spacing. Enter opens a bounded inspector; 16 KiB pages provide access to
entire long fields. Full name/value/line copy stays outside its scroll area.
All-header copy preserves CRLF and original bytes for text-safe headers. NUL or
invalid UTF-8 receives explicitly labeled escaped copy actions; control bytes
are escaped for display. Native read-only controls support selection and copy,
while typing, paste and Cut never change the received data. Tab, vertical/page
navigation and Ctrl Home/End reveal virtualized rows; Tab exits the cell sequence.
Header-owned menus close on source replacement and return keyboard focus to
the Headers tab. Inspectors also close when their tab/view disappears. Remaining
copy/save utilities follow in 8b3c.

The 8b3b1 text slice adds contextual Wrap lines and true unwrapped logical
lines. Native font metrics produce visual rows and byte/x checkpoints; large
reflows run on the existing bounded worker service using private font contexts.
Derived buffers retain shared immutable ownership through resize, replacement
and clear. Visible painting and hit testing measure bounded chunks rather than
multi-megabyte prefixes. Two-axis/Shift wheel input and draggable scrollbars
reach distant text, with Page keys and Ctrl Home/End for keyboard navigation.
Reflow keeps the visible byte anchor and selection, and raw/formatted viewers
keep separate reading state. Input and clipboard checks use the CUI harness;
native OS input, clipboard and complex-script acceptance remain later audits.

The 8b3b2 Find slice searches the current formatted, minified, original or HTML
text source. JSON tree Find switches to formatted text; Markdown preview Find
switches to Raw. A focused request body keeps its own Find command even with a
response shown. Search controls appear only when invoked, adapt to narrow panes,
support native query editing, match-case, Enter/F3 and reverse navigation, and
return focus to the document on Escape. Counts include all available text;
10,000-entry pages bound the match cache while preserving navigation to every
match. Linear search runs on retained immutable worker input with cancellation.
Automaton checkpoints support bounded visible highlighting beyond the cached
page, including long lines and queries crossing view/line cuts. A distant match
can reveal a labeled byte window if full text layout exceeds its row limit.
Search does not rebuild on wrap/theme/scale changes. Native OS clipboard,
accessibility and full Unicode/grapheme acceptance remain separate audits.

Dialogs use concrete Create/Save/Move actions. Name dialogs accept Enter and
focus their field on repeated opens. Environment/settings changes already save
as edited, so those dialogs offer Close. The environment table fits at 640x420.

Motion is brief and always settles. The native app runs CUI's motion tokens at
half their default duration (`design.motion_scale = 0.5`): hover fades take about
70 ms, menus and popovers about 140 ms, dialogs about 170 ms, and exits are faster
than entrances. Kest's own tabs, rows and icon buttons fade their hover with the
same token as CUI buttons. Appearance changes cross-fade the palette in about
180 ms. The caret stays steady, and nothing loops: an idle window schedules no
frames (0.000% idle CPU on a private desktop). Headless frames keep motion off,
so snapshots and interaction checks stay deterministic.

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
Composer checks cover stable geometry across three widths, both themes/four
scales, long URL scrolling, native selection/undo, mock clipboard paste, current
environment substitutions, inline errors, real Save persistence, method-menu
keyboard selection and loopback execution. Held-key and focused-button shortcut
regressions verify one dispatch per execution press. Custom-method and long-URL
popups stay inside the minimum window. Focused-button text has a pixel check.

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
content stays inside the collection browser. There is no destructive clear
button when history is empty. The compact filter controls reserve enough label
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
