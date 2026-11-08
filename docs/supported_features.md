# Kest: verified coverage

This checklist applies to Kest with CUI 1.1.0. The original application's checklist
does not establish coverage for this interface.

**T** = run in engine/HTTP tests. **U** = run through the CUI headless harness.
**S** = actual rendered image inspected. **W** = compiled, not exercised.

## Engine and data

| Feature | Verification |
| --- | --- |
| HTTP/1.1, methods, query/URL sync, headers, body preparation | T; GET/POST and query sync U |
| JSON/text/XML/form/multipart/file bodies | T; seven-mode preservation, JSON editing, byte-exact binary/multipart and URL-encoded POST, empty files and invalid/missing paths U |
| TLS default verification, per-request override | Default and option retained; UI W; prior original-app manual TLS checks not counted here |
| Redirects, cross-host sensitive-header removal | T |
| Cancellation, timeout and response-size limits | T; cancellation U |
| Response memory limit, disk spill and full body saving | T; failed spill allocation stops the transfer T; export-after-clear lifetime U; partial OS write failure remains for the large-data audit |
| Collection files, tree operations, history, environments, drafts | T; saved request/environment, reload and cURL import U |
| Postman/native import and export, cURL parse/generate | T; cURL review/accept U |
| Atomic workspace writes and store writer | T, U |
| Export writer and retained response lifetime | U |
| Path validation and log redaction | T |

## CUI interface

| Feature | Verification |
| --- | --- |
| Kest executable/title/Windows icon | ReleaseFast built; 16-256px ICO frames verified; metadata verified |
| Headless snapshots and UI self-tests | Separate test executable; snapshots require a build with `-Ddiagnostics=true` |
| T3 Code neutral dark/light palettes, blue actions and monochrome K identity | Both S; instant theme changes U; control geometry retained |
| Inset pane tabs and document/collection selection markers | Dark/light S; existing pointer/keyboard interaction checks U |
| Separate code syntax palette and flat primary actions | JSON/body S; mode and editing checks U |
| Short, settling motion in the native interface | motion_scale 0.5; headless motion=0 U; native idle CPU 0.000% after settling |
| Native document tabs, new/close, reorder and overflow reveal | Pointer new/close, active-tab reveal, Shift+arrow reorder and dirty-close confirmation U; mouse dragging W |
| Resizable sidebar; adaptive side-by-side/stacked request-response split | Both layouts S; width-based adaptation U; layout/split preferences round-trip T; divider dragging W; explicit layout picker W |
| Hide/restore request details to focus on response | Layout focus state and response height U; restoring through a section tab U; focused response S |
| Narrow workspace sheet at 640×420 | Toggle U; compact and unobstructed workspace images S |
| Request Params/Body/Headers and settings control | Actual pane/body-type clicks U; params/body/settings S |
| Collection tree drag reordering and drop into folders | Threshold, insertion line, into-folder outline, Escape cancel, edge autoscroll and invalid targets U; both indicators S; reorder, drop into folder, Escape and click threshold through real Win32 messages |
| Real Windows input path | Mouse, keys and committed text (accented, CJK, surrogate-pair emoji) through the real window procedure, saved files checked, IME composition window at the caret, and all of it again after simulated 125%/150% `WM_DPICHANGED` |
| Keyboard-only workflow | Create, edit (method, URL, body type, body), send and inspect a response without a pointer; focus returns after the palette and dialogs, moves to the sidebar toggle when the sidebar hides, stays in the tree after a delete (`src/keyboard_tests.zig`) |
| System appearance | Follows the Windows app theme until an appearance is chosen; honours Windows "Show animations" |
| Screen readers (UI Automation) | `src/a11y.c` publishes named controls with roles (buttons, fields, tabs, tree and tree items, menu buttons), focus and focus events, help text and field values. Read-only: no Invoke/ExpandCollapse patterns |
| Direct-entry tables, empty insertion row and URL sync | Actual key/value typing, continued focus and Tab to value U; populated table S; unused insertion row excluded from request data |
| Minimum-size row visibility and response space | Populated row AND insertion row fully visible U; JSON viewport at least 60 px with empty request details U/S |
| Joined method/URL composer and standard/custom method menu | Actual GET/POST/custom selection and custom typing U; dark/light S |
| Body syntax colors, format/minify, bounded undo/redo | Format, undo and actual pointer/text input U |
| Multipart Text/File controls and file selection | Pointer and keyboard type changes, picker selection/cancel/error adapters U; compact/light forms and file-row inspection S |
| Binary name/size/change/remove and templated paths | Real file metadata, refresh, current environment, zero-byte files, missing/directory handling and draft reload U; compact dark/light S |
| Background file metadata | Bounded cache/worker ownership, allocation failure recovery and settled file-panel no-redraw/no-wakeup U; real ACL denial unverified |
| Editable body search | Match/search controls U; broader body navigation audit pending |
| Response Find | Linear literal query, full available-text counts, capped result pages and checkpointed visible ranges T; query-copy/derived-source ownership, cancellation and allocation failures T; 4 MiB and more than 10,000 matches, Enter/F3/Shift/Escape, case/UTF-8, current formatted/raw/minified/HTML sources, busy input, stale query/clear, row-limit windows, highlight pixels, four scales and two layouts U; formatted dark/light, compact controls, distant match and bounded fallback S |
| Response wrapping and horizontal navigation | 4 MiB true lines, far selection/copy, two-axis wheel/Shift+wheel, draggable scrollbars, Page keys, resize anchors, independent raw/formatted positions, UTF-8/tabs/CRLF, both themes/four scales/three widths and settled no-wakeup U; bounded position metrics, partial-allocation failures and cancellation/retained derived bytes T; compact wrap and distant horizontal end S |
| Formatted response, JSON mode menu, raw and preview | All modes U; actual tree/minified/raw/formatted menu choices U; formatted code S |
| Whole-document response classification | Strict JSON escapes/controls/UTF-8, MIME parsing, depth and prefix limits T; completed worker metadata and 2 MiB valid/late-invalid/late-NUL bodies T; malformed/fragment/scalar, binary Markdown, SVG, original read-only selection and prefix fallback U; malformed text, echoed fragment, binary hex and prefix notice S |
| Background response preparation | Two worker slots, retained source/result ownership, shutdown, start failures and partial-allocation cleanup T; gated busy input/navigation, worker index/span adoption, 4 MiB strings/HTML, mode/clear/close, output/node/row fallbacks U; waiting and output/node/row limit captures S |
| Adaptive response metadata and execution inspector | Geometry across widths/themes/scales, unknown/zero timing/bytes, bounded details and scrolling overflow U; narrow layouts, long literal details, keyboard overflow and light error badge S; settled badge contrast numerically checked U |
| Response execution states and previous-data ownership | Real HTTP errors/redirect, cancel, timeout, partial, dropped/refused connection and preflight failures U; retained selection/source ownership U; previous response, cancel, Not sent and storage failure S; DNS/TLS/storage presentation uses injected structured failures |
| Response header table and inspection | Real 1207-row loopback, duplicates/casing/order/OWS, bounded field pages, read-only selection/Cut, full/escaped and all-header copy through an in-memory clipboard U; keyboard/page/first/last navigation, Tab exit, source replacement focus, popup cleanup, themes/scales U; compact dark/light, paged inspector and empty state S; OS clipboard W |
| Virtualized JSON tree, expand/collapse, formatted/minified | U |
| Binary hex view | U with a real 9 MiB loopback response |
| PNG/JPEG response image | Real loopback PNG U; synthetic 3000x1600 PNG worker decode/reduction and JPEG U; invalid compressed expansion hits allocation limit U; corrupt/partial images fail safely U; scaled image and allocation-limit fallback S |
| HTML text preview | U with a real loopback response |
| Markdown response preview | Real loopback Markdown U; response bytes retained; oversized markup falls back to virtualized text U |
| Native activity console | Bounded ring, redacted adapter, search input, Clear and hidden/reopen U; level filters/Follow/OS copy W; console S |
| Native collection tree table and path bar | Keyboard collapse/expand and pointer breadcrumb reveal/filter reset U; selection and row menus retained; type-ahead compiled |
| Copy body/headers/JSON values and cURL | Headers U through an in-memory clipboard; other actions W; OS clipboard unverified |
| Native file import/upload/save dialogs | Host wiring W; upload selection/cancel/error through injected picker U; actual native dialogs unverified |
| Sidebar empty-state inset, wrapping and non-overlap | Dark/light and 210px/compact-sheet U; history captures S |
| Reset history search/method/status filters | Actual click and recovery of real loopback history U |
| Collection/history/environment browser and row menus | All S; collection keyboard expansion and ancestor reveal U; forty-collection lazy-menu regression U; other row-menu actions W |
| Environment selection and variables | Engine T; actual picker choices U; bounded scrollable menu including duplicate names; compact variables dialog S |
| Import preview, warnings and duplicate detection | Core T; cURL preview/accept U |
| Repeated name-dialog focus, Create/Rename and Enter | Actual typing/Enter across repeated opens U |
| Save as, move-to, delete confirmation and workspace settings | W; environment/settings dialogs correctly offer Close for already-saved edits |
| Ctrl+N/B/Enter and body Ctrl+A/Z | U |
| Other shortcuts and command palette | Compiled, W |
| 4 MiB single-line editor | Measured U; only visible rows/columns drawn |
| Settled UI has no redraw or next wakeup | U, including after notifications expire |

## Deliberate gaps

- Windows host only. Linux/macOS hosts have not been implemented.
- SVG preview is not supported.
- JSON tree Find opens formatted text; the tree itself is not filtered.
- Response Find searches available text (up to 16 MiB, literal queries up to
  4096 bytes). Spilled bytes beyond the available response preview are not
  searched. Case-insensitive matching folds ASCII A-Z; other UTF-8 characters
  match exactly. Full Unicode case folding is absent. Regular expressions have
  no lookaround or backreferences, so matching stays linear in the text.
- Screen readers are checked through the UIA tree they read, not real
  speech output. No complex-script validation. UTF-8 advances align codepoint carets/hit testing; grapheme behavior
  retain their native audit. Response wrap uses native font advances; editable
  request bodies still use conservative byte-budget wrap sizing.
- `zig build test` reports the current engine/HTTP test counts and also runs
  the executable CUI harness and native control/geometry/font checks.
- Current limitations include: no HTTP/2, cookie persistence, proxies or
  browser HTML rendering. These features are outside the current scope.


### Sidebar and workspace interactions

- Rename collection items, environments, and request tabs inline from their menus. F2 renames the focused collection item or current request tab; The current name starts selected; typing replaces it. Enter or clicking away commits, and Escape cancels and returns focus to the item. Empty Enter marks the field invalid; leaving an empty editor keeps the original name. Tab editors expand while editing, and collection rows scroll fully into view.
- Ctrl-click toggles collection rows; Shift-click selects a visible range. Selected rows expose bulk move, Postman/Kest export, and delete actions. Bulk operations visit selected ancestors once. Collections cannot be moved into other collections.
- Deleting collection items or environments offers an eight-second Undo toast. Repeated deletes within that interval are restored together, including the original order and request files.
- Drop one collection/environment/cURL file onto the window to open the existing import preview. Drop one file into the visible Body area to attach it as a binary body. Multiple-file drops are rejected explicitly; open dialogs keep ownership of input.
- Pin/unpin tabs from their context menu. Pins stay at the start of the strip, survive workspace reloads, and are protected from bulk close. Explicit close still works.
- Recently closed lists the last ten closed requests for this session. Ctrl+Shift+T reopens the most recent, retaining request edits. Response data and background work are released when closing.
- The tab strip supports wheel/trackpad scrolling, left/right scroll buttons, active-tab reveal, and the existing Tabs menu.

### Text editing

These apply to the request body editor; the response text view shares the
clicks, scrolling, zoom and bracket outline.

- Double-click selects a word and triple-click a line; dragging afterwards grows
  the selection by whole words or lines.
- Drag selected text to move it; hold Ctrl when dropping to copy instead. Escape
  cancels the drag. Each move is one undo step.
- The wheel glides to its target instead of jumping (immediate with reduced motion).
- Ctrl+wheel, Ctrl+= and Ctrl+- zoom the code font; Ctrl+0 resets it. Settings
  has a Code font size (9-24 px) that persists with the workspace.
- Find has Replace (Ctrl+H), case (Aa), whole word (W) and regular expression
  (.*) toggles. Replacements accept `$0`/`$&`, `$1`-`$99` and `$$`. Replace all
  is one undo step. An invalid pattern says what is wrong and where.
- JSON bodies fold objects and arrays from gutter arrows, the line's marker,
  Ctrl+Shift+- or the context menu (Fold all / Unfold all). Folds follow edits,
  and moving the caret into one opens it. The bracket at the caret and its partner
  are outlined.
- Alt+click adds or removes a caret; Alt+drag selects a column; Ctrl+Alt+Up/Down
  adds a caret on the row above or below. Typing, deleting, arrows, Home/End,
  Cut, Copy and Paste act at every caret as one undo step. A paste with as many
  lines as carets puts one line at each. Escape or a plain click returns to one caret.

### Variables and autocomplete

- Typing `{{` in the URL, any params/headers/form cell or the request body lists
  the selected environment's variables with their values; more letters narrow
  it. Up/Down choose, Enter or Tab inserts (adding `}}` when it is missing),
  Escape closes, and a click inserts too. Ctrl+Space opens the list again.
- `{{name}}` in the URL and table cells is coloured: accent for a variable with
  a value, warning for one that has none.
- Hovering a reference in the URL, a cell or the body shows its value, or says
  it isn't set in the selected environment.
- The header table suggests common header names and, once a name is set, common
  values for it (Content-Type, Accept, Authorization, Cache-Control and more).
- The URL field suggests URLs sent before that contain what was typed, newest
  first.
- A list never shows just because a field was focused; it waits for typing.

### Tables

These apply to params, headers, form fields and environment variables; the
response header table shares the resizable split.

- Drag the boundary between the two headings to resize the columns; a
  double-click resets the split.
- Click a heading to sort by name or value (A to Z, then Z to A). Sorting
  changes the request's order, so a toast offers Undo.
- Each row has a grip. A click picks the row, Ctrl+click adds or removes one,
  and Shift+click picks a range. With rows picked, the heading becomes a bar
  with Enable, Disable, Copy and Delete. Ctrl+C copies them, Ctrl+X cuts them,
  Delete removes them, and Escape lets go. Deleting offers Undo.
- Drag a grip to move its row, or every picked row, elsewhere. A line shows
  where they will land, and Escape cancels.
- Copied rows are tab-separated lines (`name<TAB>value`), so they paste into
  spreadsheets. Pasting several lines or tabbed text into a cell adds rows
  after it, with Undo; a single line still pastes into the cell.
- Response headers keep the order they were received in; that table resizes but
  does not sort.

### Feel and feedback

- The top bar has an Edit menu with Undo, Redo, Cut, Copy, Paste, Delete and
  Select all, each with its shortcut. It acts on the text field or editor
  focused last; with nothing focused, it shows the commands greyed out.
- Resting the pointer on a response's status, time or size opens a card:
  - Status: the code and reason, its class, what it means, and Location or
    Retry-After when the response has them.
  - Time: the exact milliseconds from sending to the last body byte, whether
    the connection was new or reused, and how many redirects were followed.
  - Size: the decoded body and header sizes, Content-Encoding and
    Content-Length when present, and a note when the transfer stopped early.
- Toasts carry a button when there is an obvious next step:
  - A request that couldn't be sent offers Retry.
  - A request finishing in a background tab offers Open (or Retry if it
    failed).
  - A queued export or response save offers Show in folder.
  - Close others / Close to the right offer Reopen.
  - Sorting, pasting and deleting rows, and deleting from the sidebar, keep
    their Undo.
- Response timing has no DNS, connect or TLS breakdown; the time card shows
  the total only.
