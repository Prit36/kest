# Improvements implementation log

Source: `improvements.md` (identical to the attached document). Work proceeds in
small, separately verified slices. Existing features count as implemented only
after inspection; historical documentation is not fresh verification.

## Ordered work

| Slice | Requirements | Status |
| --- | --- | --- |
| 0. Architecture and baseline | 1, 59; initial inventory for 56 | Initial audit and ReleaseFast baseline complete |
| 1. Request content selection | 4; selection-related parts of 25, 44 | Complete |
| 2. Shared visual primitives | 6, 20, 60 | Shared foundation complete; per-view rollout continues in later slices |
| 3. Shell and pane geometry | 2–3, 5, 8, 12, 15, 17–19, 36, 42–44, 61 | Core phase complete (3a/3b); full component/edge-case audit remains in 14 |
| 4. Document navigation | 7; request switching and tab keyboard behavior | Complete; broader keyboard/data-safety audit remains in 11/14 |
| 5. Request composer | 9–10, 21–22 | Complete; OS/accessibility and data-safety audit remains in 11/12/14 |
| 6. Params and headers | 11, 23–24 | Complete (6a/6b); broad data-safety/native audits remain in 11/12/14 |
| 7. Body editing | Remaining 25, including form/upload/validation | Complete (7a/7b); broad native/data-safety/performance audits remain in 11–14 |
| 8. Response inspection | 13–14, 26–31 | Complete. 8b3c added formatted/minified JSON copy and content-typed save names; raw copy/save already existed |
| 9. Collections | 16, 32–35 | Complete (see completion pass), including drag reordering in the tree |
| 10. Global workflows and secondary views | 37–40, 63 | Palette and close dialog reworked; env picker/dialogs audited by capture. Import measured at 79 ms for 20,000 requests, so no progress UI is needed |
| 11. Keyboard and data safety | 45–48 | Save/Discard/Cancel close, failed-write dirty state, shortcut table verified |
| 12. Themes, accessibility and native behavior | 49–51 | Both themes captured; no screen-reader/IME/OS-input verification possible here |
| 13. Performance | 52–55 | Measured before/after: no regression (see completion pass) |
| 14. Full regression and polish | 41, 56–58, 64–67; all acceptance criteria | Captures reviewed at 1282×832 and 1024×768, both themes; limits listed below |

The document's Parts XIII–XV describe strategy, acceptance and deliverables;
they apply across these slices. Each slice includes relevant verification rather
than deferring all tests to the final pass. Broad window/DPI and accessibility
acceptance remains pending even when individual components pass headless tests.

## Architecture audit

- `main.zig`: startup, native CUI host, application loop, diagnostic entry points.
- `ui/shell.zig`: global toolbar, sidebar split/overlay, shortcuts and
  command palette. `ui/workspace.zig`: native document strip, path bar, request
  composer and adaptive request/response splits.
- `ui/design.zig`: shared dark/light color roles, syntax roles, control and text
  metrics, motion. `ui/widgets.zig` wraps CUI layouts, fields, actions and menus;
  `controls.c` bridges native control behavior. Several UI modules still embed
  geometry literals; normalize by role as the shared primitives are audited.
- `ui/request.zig`, `composer.zig`, `key_value.zig`: method/URL, request sections,
  body and settings, direct-entry/bulk tables. `ui/response*.zig`: response
  navigation, metadata, headers, code/tree/preview views and export actions.
- `ui/sidebar.zig`: native tree table and history/environment navigation;
  `app/tree_ops.zig` and `app/commands.zig` own actions and request activation.
- `app/state.zig`: application state; `app/tab.zig`: per-request editable buffers,
  request pane, body editor and derived response state. `app/persist.zig` handles
  debounce, drafts, preferences, disk refresh and restoration. Storage modules
  serialize collections, requests and workspace independently.
- `ui/editor.zig`/`code_state.zig`: visible-line canvas rendering, indexes, caret,
  selection, bounded undo and search. Large editor indexing and derived response
  buffers merit measured review; do not infer faster performance from styling.
- `ui/dialogs.zig` and import/export modules own secondary workflows;
  `ui/activity.zig` adapts the bounded redacted activity log to CUI's console.
- Pinned CUI 1.1 supplies native widgets and software/OpenGL renderers; Windows
  text uses DirectWrite. Keep this stack and the networking/data semantics.
- `zig build test` combines engine, HTTP, native title/font checks, headless
  pointer/key interactions, persistence, layout, sidebar and memory checks.
  Diagnostic builds support scratch-workspace PNG captures without a server.

## Confirmed gaps and next audit targets

1. Saved requests and imports selected Body through a command-only helper;
   restart restoration and pasted cURL used `Tab.fromRequest` directly and missed
   that helper. Workspace preferences stored no per-request content selection.
2. That helper overlooked query parameters present in the URL when considering
   Headers as the fallback. Loaded editable rows are the correct source here.
3. Body had no configured-content indicator. Request and response counts used
   unparenthesized numbers (fixed in slices 1 and 2).
4. Resolved variables added a permanent row in `composer.zig`; Save was an
   icon within the URL group (fixed in slice 5).
5. Request/response tab rows separately own their bottom separator while CUI
   owns splitters. Verify boundary intersections and device-pixel snapping before
   making shared geometry changes (slice 3).
6. Native document strip/tooltips, sidebar menus and response metadata require
   focused overflow checks; existing implementations are not blanket evidence of
   meeting every requirement.

## Slice 1 behavior

- One default policy now applies to saved loads, history/imports, pasted cURL
  and workspace restoration. A configured body wins, then query rows, then
  headers. Empty POST/PUT/PATCH starts at Body; empty GET starts at Params.
- Method edits follow those defaults until a user explicitly selects a section.
  View changes persist as workspace preferences without dirtying request data.
- Each restorable open tab stores its own optional `requestPane`. Old, missing,
  unknown or wrong-type values safely use the default policy. Draft overlays
  restore their section after loading; external disk refresh preserves the view.
- Body content shows a dot and explanatory tooltip, including form and upload
  content. Params and Headers counts use parentheses. No body, method, URL or
  network execution data is changed by view selection.
- Selection restoration covers open tabs across restart. Remembering a section
  after deliberately closing a request is outside this first slice.

## Slice 2: shared control foundation

- `ui/metrics.h` is the common C/Zig source for spacing, typography, icon,
  radius, control and tab-height roles. `design.zig` exposes these to layouts
  and uses them for CUI's existing theme metrics. Native buttons, inputs,
  selects, tree rows, status badges, splitters, menus and dialogs continue to
  use CUI and the common palette. Their feature-specific layout/interaction
  audits remain in subsequent slices; this is not blanket completion of 20/60.
- A dedicated content-tab primitive replaces action buttons masquerading as
  tabs. Request/response tabs use a flat selected surface, consistent padding,
  baseline and underline. Native document tabs receive the same visual language
  through a local wrapper; CUI still owns selection, close confirmation, dirty
  slots, scrolling, middle-click and keyboard/mouse reordering.
- Request and response strips each have one Tab stop; unmodified Left/Right
  cycles sections and Home/End selects the first/last. Focus follows the active
  section. Modified shortcuts, editor navigation and higher popup/modal layers
  keep their keys. View selection does not dirty request data.
- Shared count formatting uses parentheses. The response content label is now
  Body. Removed the unused alternate tabs wrapper to keep one content-tab path.
- Pixel checks exposed separator overlap at a half-device-pixel bottom edge.
  Underlines now snap *inside* each tab and occupy exactly two physical pixels;
  enclosing strips retain border ownership. App-wide doubled separator/splitter
  ownership is still slice 3, not claimed fixed here.
- `zig build test-controls -Doptimize=ReleaseFast` renders both native document
  and content tabs on a software surface in light/dark at 100/125/150/200%,
  including fractional origins. It checks indicator pixels, height, a single
  focus-order entry, arrow/Home/End navigation, modifier and editor isolation.
  The same test is part of the normal test step.
- Final `zig build test -Doptimize=ReleaseFast` and `zig build test` passed.
  Added real application request/response arrow/Home/End regression checks;
  document overflow, closing, reorder and existing request/data suites pass.
- Built diagnostics into `test-output/improvements-part-2` and ran its full
  self-test/capture suite with explicit scratch KEST_DATA at 1282×832. Inspected
  `workspace-body.png`, `workspace-light.png` and `workspace-minimum.png`
  (640×420). Both tab families have the intended treatment and content remains
  visible. These are current-slice evidence, not full visual acceptance.
- Before/after tab evidence is available in the generated
  `test-output/improvements-part-1/workspace-body.png` and
  `test-output/improvements-part-2/workspace-body.png` captures. Native production
  build/startup/shutdown also passed on a private desktop with scratch data
  (one lifecycle smoke run, exit 0). No performance improvement is claimed.
- Known later work includes shared splitter/baseline boundaries, compact
  response metadata overflow, unsupported preview/view selection behavior,
  document dirty/close-slot behavior and the broader accessibility audit.

## Slice 3a: pane geometry and boundary ownership

- Native splitters keep CUI's drag/hit testing and minimum sizes. A shared local
  adapter gives sidebar, column and stacked dividers one physical-pixel layout
  thickness and snapped painting. Hover draws a short accent directly on the
  current divider, keeping the broad invisible grab area and resize cursor.
  Hover does not add a second seam or paint across tab/header intersections.
- Request/response header separators and the document-row baseline have one
  shared owner. Removed the extra native document baseline and extended native
  tabs to meet the row's baseline. Other app-wide separators remain for 3b and
  feature-specific component passes; no claim of a complete border audit yet.
- Layout uses actual workspace width. Auto switches to columns at 730 logical
  pixels; an explicit Side by side choice can use the safe 320+360px pane minima.
  Below those minima it stacks. The visible Layout menu offers request focus,
  response focus, both panes and a persisted equal-split reset. Focus mode belongs
  to the request session and preserves the editor objects and data.
- Sidebar width is restored in logical pixels on each window resize instead of
  scaling with window width. Dragging respects a 210px minimum and a bounded
  maximum (480px, 40% of the window, and sufficient workspace). Shared geometry
  tokens also define the narrow-window sheet breakpoint and pane minima.
- Breadcrumbs now use unboxed native path segments across the available width,
  with native middle collapse/ancestor menus and a complete-path tooltip. The
  permanent pencil and repeated dirty label are removed; Rename remains in
  Request actions, and document tabs retain the dirty marker. The context row
  uses the compact control height and no extra top inset.
- `geometry_tests.zig` covers 640×420, 1024×768, 1280×800, 1280×832, 1282×832,
  1366×768, 1440×900, 1920×1080 and 2560×1440 in both themes at 100/125/150/200%.
  It checks bounds above the footer, pane minima, actual-width breakpoints and
  constant sidebar width. Pointer tests exercise divider movement, extreme
  minimum/maximum drags, preference updates, caret/selection/buffer preservation,
  and actual Layout focus/reset actions. Explicit-vs-auto layout is also checked.
- Software pixel tests now cover horizontal/vertical splitter thickness at
  fractional origins in both themes/four scales, including hover, in addition
  to the shared tab tests. Full Debug and ReleaseFast suites pass.
- Diagnostic captures live under `test-output/improvements-part-3a`: full
  loopback UI capture suite at 1282×832, including request focus; additional
  `geometry-dark-{100,125,150,200}.png` and corresponding light captures. Inspected
  dark/light main view, 640×420, request focus, and dark 100% / light 200% views.
  The first capture exposed a truncated Layout trigger; its width is corrected.
- Before evidence remains under `test-output/improvements-part-2`. Native
  display/GPU validation and OS input are not proven by these software captures.
  No performance improvement is claimed.
- Production `zig build -Doptimize=ReleaseFast` updated `zig-out/bin/kest.exe`.
  The existing private-desktop harness launched and closed that build with
  scratch data successfully (one run, one idle second, exit 0). This validates
  native lifecycle, not visual GPU output or desktop pointer behavior.
- Follow-up completed in 3b: remove low-value global/footer chrome, consolidate
  collection import/navigation controls, and audit native window restoration.
  Response metadata overflow and collection-row improvements remain their own
  later slices. This is not completion of the entire shell/geometry phase.

## Slice 3b: shell controls and native window restoration

- Removed the generic Ready/shortcut status strip. Activity is available from
  a persistent top-toolbar control and Ctrl+J; Commands is discoverable at both
  compact and wide widths. Wide triggers show labels; compact triggers have
  icons and shortcut tooltips. Active requests add a contextual running count
  without reserving an idle status row. Request Cancel and error toasts remain.
- Removed the duplicate sidebar navigation/Import footer. The header's stable
  navigation dropdown switches Collections, History and Environments. Create
  groups new requests/collections/environments; Collection actions retains file
  and cURL import. Existing row export menus and command-palette actions remain.
  Workspace actions now contains application settings/data-folder actions.
- Editors and the collection browser use the recovered bottom space. Geometry
  checks assert the workspace reaches the window edge when Activity is closed
  and stays above Activity when it is open. At 640×420 the compact Activity view
  uses two log lines; a new check requires the full form/multipart insertion row
  to remain visible with Activity open or closed.
- `windowPlacement` stores normal screen position, outer size, DPI and maximized
  state independently of legacy logical client dimensions. Old preferences
  continue to load. Missing, malformed, out-of-range and incomplete placements
  are ignored safely. A maximized/minimized window does not overwrite the normal
  rectangle or logical client size.
- Windows start hidden with a bounded initial surface, restore onto the nearest
  monitor, scale the saved size for that monitor's DPI, clamp to its work area,
  then show in the saved normal/maximized state. Normal geometry is captured
  from actual native move/resize/DPI events and once more before destruction.
  No polling, new runtime dependency or hidden background service is added.
- `zig build test-window-geometry -Doptimize=ReleaseFast` uses a real HWND on a
  private desktop: oversized/off-screen rescue, legacy size, saved-DPI conversion,
  and normal/maximized/minimized transitions pass. Preference tests prove the
  format round trip (including negative positions) and malformed fallback.
- Final Debug and ReleaseFast full suites passed. Pointer tests verify sidebar
  header navigation/import and compact/wide Commands/Activity activation. Existing
  HTTP, import/export, persistence, dirty-state, editor, nine-size/four-scale and
  rendering checks continue to pass.
- Final captures: `test-output/improvements-part-3b/workspace*.png`, generated by
  the diagnostic app at 1282×832. Inspected body, light, 640×420, sidebar sheet,
  and compact multipart/Activity. The latter exposed the console-height clipping
  issue and was recaptured after the fix. Before evidence is in `part-3a`.
- Production ReleaseFast build updated `zig-out/bin/kest.exe`. Two private-desktop
  launches with scratch data persisted identical normal placement across restart.
  A third launch restored maximized and preserved the original normal rectangle
  and client dimensions. All exited 0. These are lifecycle/persistence checks,
  not performance improvement claims.
- Physical monitor unplugging, mixed-DPI multi-monitor transitions, real desktop
  input and visual GPU output remain unverified on this machine. The native test
  exercises saved-DPI conversion on the current monitor, not a monitor hot-plug.
  Full app-wide layout/overflow acceptance remains for the final audit.
- Next at completion of 3b: document-tab navigation (completed below).

## Slice 4: document navigation

- The horizontal document strip retains native wheel/trackpad scrolling, pointer
  dragging, Shift+Left/Right reordering and middle-click closing. Tabs have bounded
  144–280 logical-pixel widths; the active tab is revealed after switching,
  opening, resizing or width changes. New request, Tabs, Layout and Request
  actions remain outside the scrolling strip, including at minimum window size.
- Method labels have semantic colors and a stable 48-pixel slot (custom methods
  may use up to 84). Request names use the remaining width. Literal `##`/`###`
  render as user text; opaque per-request identities survive name changes.
- Dirty dots occupy a separate, stable slot immediately before the close button.
  The active close button is always visible; inactive buttons appear on hover or
  focus. Dirty close still opens confirmation, and Escape preserves the document
  and edits. Full save/discard/cancel and shutdown policy remain for slice 11.
- Tabs shows a checked, scrolling list of complete request names, wrapped within
  the viewport. Pointer and keyboard selection activate and reveal the request;
  keyboard navigation scrolls highlighted entries into view. Short names use
  native tooltips; names beyond CUI's 256-byte tooltip buffer use one shared,
  bounded, scrollable hover surface, preserving the complete name.
- Native arrows/Home/End remain available on focused documents. Ctrl+Tab and
  Ctrl+Shift+Tab switching, plus closing a focused document, keep subsequent
  document navigation on the new selection without taking focus from editors.
- One shared 64-tab capacity now covers new requests, saved-request opening and
  restoration. Saved requests already open still activate at capacity. Restart
  previously silently dropped tabs after 40; all 64 now restore, with per-request
  views. Filtering blank drafts now maps the selected index into the persisted
  list rather than selecting a different request after restart.
- Added isolated real-CUI document tests across three widths, both themes and
  four scales, plus wheel/trackpad input, dropdown pointer/keyboard navigation,
  focus continuity, dirty-close cancellation, capacity and actual disk reload.
  Native control tests verify literal names, method/marker/close geometry and
  complete hover text beyond the native tooltip limit.
- Capture review caught a selected-background painter covering focused tab text.
  Corrected paint order and added a rendered-pixel regression for focused labels.
  Idle checks also exposed a redundant caret wake after a settled tooltip; the
  steady-caret adapter now removes that wake while preserving pending tooltip,
  popup and scrollbar deadlines. No performance improvement is claimed.
- Final Debug and ReleaseFast full suites passed. Diagnostic self-test/captures
  passed in an explicit scratch workspace. Inspected focused dirty, compact,
  Tabs-menu and light captures in `test-output/improvements-part-4/workspace*.png`.
  Debug/Release logs are `test-output/improvements-part-4-{debug,release}.log`.
- Production ReleaseFast build updated `zig-out/bin/kest.exe`. One launch on a
  private Windows desktop with scratch data reached idle and closed cleanly
  (exit 0). This verifies native startup/shutdown, not a performance improvement.
- Actual OS keyboard/trackpad input, screen readers and multi-monitor behavior
  remain unverified; these interaction checks inject native CUI events. The
  compact composer then truncated long custom methods (fixed in slice 5 below).

## Slice 5: request composer

- One execution row now contains the joined method/URL group, a separate labeled
  Save action and primary Send/Cancel. Save distinguishes an unlinked request,
  pending changes (`Save •`) and a clean linked request (`Saved`). Ctrl+S retains
  the existing save/save-as workflow. The controls share a 38-pixel height and
  bounded widths, leaving the URL the largest individual field at minimum width.
- The method slot remains 112 logical pixels wide through standard selection
  and custom editing. Common methods and PROPFIND fit completely. Arbitrarily
  long custom methods show Custom rather than half a method, with the complete
  literal token in a bounded scrolling menu and native editable field. Keyboard
  menu navigation reveals the chosen row, including Custom method at the end.
  Changing methods preserves URL/body/configuration and explicit pane choice.
- The native URL field retains horizontal scrolling, selection, word navigation,
  undo and paste. Native clipboard tests use an in-memory source; the actual OS
  clipboard is not touched by headless tests. URL text remains the main text role.
  Save and Send sit outside its bounds and cannot overlap trailing text.
- Removed the permanent successful Resolved row. A discoverable link control
  opens a bounded inspector with active environment, complete resolved URL,
  missing names and Copy resolved URL. It wraps/scrolls long values. Substitution,
  trimming, validation and escaping match request preparation; the view rebuilds
  from current URL/environment rather than caching resolved data. Resolved secrets
  are displayed/copied only by explicit inspection and do not enter preferences
  or logs through this surface.
- Missing variables and malformed URLs immediately show a danger outline and
  concise inline explanation, including when an environment row changes or is
  disabled. Send is disabled until valid; Cancel remains usable while running
  even if the edited URL becomes invalid. Invalid custom methods also stop at
  the shared command entry point, including Ctrl+Enter, before starting a job.
- Bare Enter sends only from the URL and never cancels or resends an active
  request. Ctrl+Enter retains send/cancel across the workspace. A shared per-UI
  key guard ignores held Enter/Space repeats for execution controls while leaving
  ordinary editor repeat behavior intact. Review caught native focused buttons
  also reacting to Ctrl+Enter; the shortcut now consumes that event so it cannot
  dispatch a second action through the button. Stable button identities survive
  Send/Cancel and Save/Saved changes.
- Primary-button flattening had also removed native keyboard focus painting.
  Restored a restrained focus border without covering labels. Native hover,
  pressed and disabled responses remain; rendered-pixel and geometry checks
  verify the focused Cancel label, complete method labels and contained actions.
- New isolated composer tests exercise nine standard/custom methods across
  three widths, both themes/four scales; current error geometry; native URL
  selection/undo and >2 KiB edits; method-menu keyboard navigation; actual Save
  disk reload; loopback escaped-variable sends; held URL Enter after completion;
  duplicate starts; focused-button Ctrl+Enter repeat; and both Cancel paths.
  Enter in the body and method editor retains its editing behavior.
- Final `zig build test` and `zig build test -Doptimize=ReleaseFast` passed,
  including native control tests and all existing engine/HTTP, request/response,
  geometry, persistence and memory checks. `zig fmt --check` for changed Zig
  sources and `git diff --check` also passed.
- Built diagnostics into `test-output/improvements-part-5` and ran the full
  self-test/capture suite with explicit scratch KEST_DATA at 1282×832. Reviewed
  `workspace-composer-{compact,custom-method,long-url,resolved,unresolved}.png`
  at 640×420 and `workspace-light.png`. Long custom tokens wrap completely and
  their menu scrolls to the final keyboard action; long URLs stay within the
  scrolling inspector, with Copy outside its scroll region. Before evidence
  remains under `test-output/improvements-part-4/`.
- Production ReleaseFast build updated `zig-out/bin/kest.exe`. The final build
  reached idle and closed cleanly on a private Windows desktop with scratch
  data (exit 0). No performance improvement is claimed.
- Real OS keyboard/clipboard/trackpad input, accessibility/IME behavior and GPU
  visual output remain for the later native/accessibility and final audits.
  Broader save failure, discard and shutdown policy remains in slice 11.
- Next: Params and Headers tables (slice 6).

## Slice 6a: table data foundation

- Split the table pass after inspection found destructive Bulk Apply and query
  delimiter handling beneath the existing presentation. This slice establishes
  data preservation before the compact controls and header inspection in 6b.
- Bulk Apply parses and builds a complete replacement first. Syntax errors,
  row-limit errors and allocation failures preserve original row pointers,
  insertion state, identities, data and pending bulk text. The editor stays open
  with an error and line number; Cancel leaves request data untouched. A failed
  attempt to construct/open a bulk buffer also keeps the table intact.
- Conventional `key: value`, `key=value`, bare flags and `# ` disabled lines
  remain accepted. Ambiguous keys/values use JSON string quoting so whitespace,
  literal leading `#`, separators, escapes, Unicode and embedded line breaks
  survive round trips. `@file ` preserves multipart file flags rather than
  silently converting uploads into text fields. Unsupported null bytes reject
  the apply. Text buffers and the shared 4096-row limit are bounded explicitly.
- Params now distinguish a bare `flag` from `empty=` and even `?=`. Optional
  `hasEquals` metadata in request files retains empty-value intent across clone,
  bulk, duplication, disabled rows and restart; old/malformed metadata safely
  defaults. Existing request formats remain readable and no version bump or
  runtime dependency is introduced.
- Query reconstruction escapes literal `&`/`#` in cells and `=` in keys rather
  than turning cell content into extra parameters or a fragment. Valid percent
  escapes retain their spelling/case, plus signs stay as written, and literal
  percent signs become `%25`. Existing normalization still handles spaces and
  non-ASCII characters on send. Variable expressions remain intact, including
  names containing query delimiters; their existing substitution rules remain.
- Stored query cells retain their original spelling and disabled-row placement
  when they reconstruct the exact stored URL. Legacy/inconsistent enabled rows
  still defer to the URL. Merely opening/switching sections does not rewrite the
  request. Repeated keys, their order, explicit empty values and fragments remain
  represented without collapsing entries.
- Added codec/file-format/query unit checks and isolated table regressions.
  They exercise malformed quoted input, the row cap, every Zig allocation site
  used by a bulk transaction, balanced allocation cleanup, native Apply/Cancel,
  actual draft save/reload in a fresh App, exact header casing/whitespace and
  literal query separators in a real loopback request.
- Final Debug and ReleaseFast full suites passed, including existing engine,
  import/export, HTTP, request/response, geometry, document, composer and memory
  checks. Changed Zig files pass `zig fmt --check`; `git diff --check` passes.
- Built diagnostics into `test-output/improvements-part-6a` and ran the real
  full self-test/capture suite with an explicit scratch workspace. Reviewed
  `workspace-bulk-error.png` at 640×420: the message identifies line 2, the failed
  input stays editable, and Apply/Cancel remain visible. Other table visual
  acceptance stays explicitly pending for 6b.
- Production ReleaseFast build updated `zig-out/bin/kest.exe`. A private-desktop
  launch with scratch data reached idle and closed with exit 0. This is a native
  lifecycle smoke check; no performance improvement is claimed.
- Remaining at completion of 6a (implemented in 6b below): compact empty/filled tables, distinct placeholders,
  efficient Enter/Tab and row navigation, table-specific focus/undo identities,
  row actions/inspection, invalid-cell feedback, generated request-header
  distinction, long-value and virtual-scroll checks, and both themes/four-scale
  visual acceptance. Broader close/save failure policy remains in slice 11.

## Slice 6b: Params and Headers controls

- Replaced the spreadsheet-like repeated Name/Value presentation and duplicate
  toolbar with compact typed headings and distinct example placeholders. Empty
  tables show one editable row; configured rows remain 33 logical pixels with
  a 32-pixel editor and one physical-pixel separator. Values use three shares
  of available width against names' two. Enable and actions columns stay fixed.
- A stable header menu groups Add row, Bulk edit and keyboard help. Add reveals
  the insertion row without persisting a phantom empty record. Request headers
  also expose Automatic request headers. The table scroll region stays inside
  its panel; no idle footer/extra empty grid is reserved.
- Tab/Enter and reverse traversal move between cells, Up/Down keep the column,
  and navigation reveals off-screen/just-added targets. Cell traversal skips
  row chrome and can exit to native focus order. Left/Right, word selection,
  Home/End, native undo, text paste and modified global shortcuts keep their
  existing editing roles.
- Row actions appear on hover or focus, with a visible indicator when a problem
  needs attention. Right-click applies across cells. Alt+Down, Shift+F10 and a
  focused trigger's Down open the menu with keyboard selection. It offers
  inspect/copy, enable/disable, duplicate, move and delete; row identity follows
  movement, and focus follows duplication/deletion rather than another table.
- Params, Headers, form fields and environment variables now have separate
  native editor scopes; environment scopes additionally include their id.
  A new bulk session uses a fresh text-editor identity. Actual event regressions
  prove undo stays inside its section/environment and cancelled bulk sessions
  cannot supply stale undo text to a later session.
- Validation uses current variables without altering data. Invalid header names
  and control characters use danger indicators; missing names, unresolved values
  and ignored Content-Length use explanatory notices. Passive tooltips contain
  static explanations rather than field contents. Full values, including long
  strings, are shown/copied only through explicit row inspection.
- Automatic request-header details are read-only. The transport and inspector
  share the standard User-Agent/Accept/Accept-Encoding defaults. Enabled names
  resolve against current variables and override defaults case-insensitively,
  while preserving configured casing/value spelling. Host and Content-Type use
  current request data; multipart boundaries and Content-Length are explicitly
  described as generated/calculated on send. Redirect behavior is identified.
- A bounded native popup-owner registry closes table menus/inspectors when
  their view disappears. Covered table fields do not process text input.
  Native toast rectangles could intercept bottom menu actions; the frame adapter
  now defers toast presentation during table actions and resumes queued items
  afterward without charging them the paused interval. Native checks verify
  queue preservation, and the pointer-delete regression runs with prior notices.
  Environment dialogs size the new shared table without its old title row.
  Broader app-wide popup/dialog/OS focus acceptance remains in 11/12/14.
- New real-CUI tests cover insertion/traversal, row-menu keyboard and pointer
  paths, enable/duplicate/move/delete, section/environment/bulk undo isolation,
  validation, >2 KiB value editing/inspection, 202-row virtual navigation and
  table geometry across three widths, both themes and four scales. A loopback
  POST verifies configured header casing, suppressed Accept default, generated
  JSON Content-Type and calculated Content-Length despite a supplied 999.
- Native pixel checks verify one-pixel row separators at fractional origins in
  both themes/four scales. Focus/hover action visibility, keyboard cell movement,
  non-secret passive hints, covered-field input and orphan-popup cleanup pass.
- Final Debug and ReleaseFast full suites passed, including engine/HTTP,
  persistence, table data/UI, native controls and idle checks. Changed Zig
  sources pass `zig fmt --check`; `git diff --check` is clean. The final Debug
  log is `test-output/improvements-part-6b-debug.log`.
- Diagnostic self-test/captures passed in an explicit scratch workspace.
  Inspected `workspace-tables-{empty,compact,invalid,inspect,automatic}.png` and
  `workspace-light.png` under `test-output/improvements-part-6b/`. Long-value
  inspection and automatic headers fit 640×420, with actions outside scrolling
  content and no overlapping notification. Light/dark table captures retain
  the compact row geometry and distinct placeholders.
- Production ReleaseFast build updated `zig-out/bin/kest.exe`. The final build
  reached idle and closed cleanly on a private Windows desktop with scratch
  data (exit 0). No performance improvement is claimed.
- Real OS input/clipboard, accessibility/IME and GPU output remain unverified.
  Multipart-specific controls/validation are next in slice 7; broad data-safety
  and native behavior still have their scheduled audits.

## Slice 7a: raw body editor

- Audited requirement 25 against the existing raw code editor and request-body
  engines. Split Part 7 into raw editor behavior (7a) and form/file controls
  (7b), preserving the seven existing body kinds and their payload engines.
- Extracted body controls into `ui/body.zig`. JSON/Text/XML show adjacent Wrap,
  Find and Body actions; JSON also has Format. Other modes no longer show
  misleading raw-text search/copy controls. The compact selector remains above
  the editor, with complete format names in its menu.
- Tab/Shift+Tab indent/outdent selected lines as one undoable edit, retaining
  selection direction; Enter preserves indentation and LF/CRLF, with a separate
  closing line between paired brackets. Two-space tab stops align display and
  navigation. Ctrl+M releases Tab for native focus traversal; Escape focuses
  the body selector. Read-only viewers retain Tab traversal.
- Replaced byte-column hit/caret/selection calculations with shared native font
  advances for UTF-8 and tabs. Up/Down retain the target horizontal position
  through short lines and wrapped rows. CRLF navigation/deletion treats the
  pair as one newline. JSON bracket matching ignores strings and caches by
  source/caret. Focus has a restrained top line, active-row tint and caret.
- Optional soft wrapping prefers whitespace, retains logical line numbering,
  and changes neither text, dirty state nor undo. Wrap index invalidation uses
  source and width; failed indexing leaves consistent empty indexes for retry.
  Its conservative UTF-8 byte budget can wrap fallback glyphs before the full
  width is used. Full grapheme/IME/shaping acceptance remains in slice 12.
- Capture review caught clipped Format/Go to labels and lost string color on
  wrapped rows. Increased the action widths and added native-font fit checks.
  JSON now caches only strings crossing visual rows on source/wrap changes;
  bounded per-row highlighting retains key/string colors and escaped quotes.
  Unit regressions cover wrapped keys, strings and UTF-8 row boundaries.
- JSON diagnostics now invalidate on body kind and active-variable revision.
  Current substitutions are validated, unresolved references show a pending
  notice, and resolved errors are distinguished from source locations. Go to
  focuses a literal-source error. Invalid text remains editable, persistable
  and sendable; formatting does not expand variables or rewrite invalid drafts.
- Undo recording now reserves text capacity before recording and aborts edits
  on record allocation failure. Undo/redo reserve their destination stacks
  before changing text. Indentation/Format undo and redo retain caret/selection.
- Final Debug and ReleaseFast full suites passed with real CUI indentation,
  native Tab opt-out,
  memory-only clipboard copy/cut/paste, UTF-8 navigation, mode/environment error
  invalidation, both-theme/four-scale/three-width wrap geometry, covered-canvas
  input and true disk reload of invalid drafts plus inactive form/file data.
  CRLF deletion/indentation, UTF-8 pointer placement, undo-record allocation
  failures and loopback POST also pass. The server receives the exact invalid
  draft with JSON Content-Type while wrapping is enabled. Logs are
  `test-output/improvements-part-7a-{debug,release}.log`.
- Final diagnostic self-test/captures passed in a scratch workspace. Reviewed
  `workspace-body-wrap-{compact,light}.png`, `workspace-body-invalid.png` at
  640×420 and `workspace-body.png` under `test-output/improvements-part-7a/`.
  Action labels fit; continued strings retain color; error text, Go to and at
  least 32 pixels of editable canvas fit the compact error state. Snapshot-only
  fixture frames let the earlier deliberate formatting-error toast expire;
  ordinary tests keep notifications enabled. `zig fmt --check` and
  `git diff --check` passed.
- Final production ReleaseFast build updated `zig-out/bin/kest.exe`. It reached
  idle and closed cleanly on a private Windows desktop with scratch data
  (exit 0). Existing 4 MiB paint/idle checks pass; this is not a measured
  performance improvement.
- At completion of 7a, multipart file picking/type controls, selected binary
  file name/size/change/remove and validation remained for 7b (completed below). Native
  OS clipboard/IME/accessibility and GPU output retain their later audits.

## Slice 7b: multipart and binary bodies

- Reused the existing seven body modes, multipart/urlencoded encoders, binary
  transport and draft schema. Multipart rows now show explicit Text/File type
  controls and browse buttons for file values. Row menus provide keyboard
  type/picker access; cell traversal still skips row chrome. Type changes keep
  existing values, including switching temporarily to URL-encoded forms, where
  retained file-flagged values are sent as text.
- File selection on an insertion row promotes that row without losing its uid
  or value; changing only the empty insertion row's type creates no persisted
  phantom. A missing field name/file path has a static notice. Full file-row
  inspection adds resolved file name, checked size, availability and Refresh.
- Binary mode shows an editable templated path, Choose/Change file, Remove,
  file name/size and Refresh. It never opens a text editor for file contents.
  Remove affects only the binary path. Empty file mode uses compact space;
  selected files reserve enough height for name and size at 640×420. Populated
  forms now fit the first field plus insertion row at that size; additional rows
  remain scrollable. Capture review removed a clipped metadata sentence and
  repeated size text from the compact binary panel.
- Metadata is asynchronous, event-driven and advisory: 16 cached immutable path
  copies, at most four active workers, one completion wake, no idle polling and
  no content reads. Separate worker/cache references survive edits, eviction
  and tab closure. App shutdown cancels/joins the group before releasing state.
  Refresh and completed sends invalidate cached paths. Current variables are
  resolved before lookup; unresolved references do not start I/O. Actual sends
  still use current files rather than metadata snapshots.
- Stable explanations cover missing, invalid, directory/device, unreadable and
  unavailable paths. Send-time length validation now rejects non-regular files
  before connecting. The automatic-header inspector shares the transport's
  file-name MIME inference. Picker selection/cancel/error is shared by binary
  and multipart controls; cancel/error leaves all configured buffers intact.
- Final ReleaseFast and Debug full suites passed, including async cache
  ownership, eviction and allocation failure recovery; current variables;
  seven-mode draft preservation; pointer/keyboard multipart controls; actual
  binary/form/multipart loopback sends; disabled upload fields; missing and
  directory preflight failures; zero-byte POST with Content-Length 0; and
  fresh-App disk reload of all body stores. The settled file panel starts no
  additional metadata jobs and has no redraw or next wakeup. Logs are
  `test-output/improvements-part-7b-{debug,release}.log`.
- Final diagnostic self-test/capture suite passed in an explicit scratch
  workspace. Reviewed `workspace-upload-{empty,selected,missing,unresolved,
  zero-byte,multipart-empty,multipart-inspect}.png`, mixed-field
  `workspace-upload-multipart-{compact,light}.png` and
  `workspace-upload-binary-{compact,light}.png` under
  `test-output/improvements-part-7b/`. Empty forms have one insertion row;
  compact binary name/size and popup copy actions fit. Ordinary tests retain
  notifications; snapshot fixture frames let the deliberate picker-error toast
  expire before later captures. Formatting and diff checks passed.
- Final production ReleaseFast build updated `zig-out/bin/kest.exe`. It reached
  idle and closed cleanly on a private Windows desktop with scratch data
  (exit 0). Native smoke and existing 4 MiB/idle checks establish lifecycle and
  regression evidence; no performance improvement is claimed.
- Actual OS picker/clipboard input, file-system ACL denial, screen readers/IME
  and GPU visual acceptance remain unverified. Error classification has unit
  coverage; regular/missing/directory/zero-byte checks use real local files.
  Broad native/data-safety/performance audits retain their scheduled slices.

## Slice 8a: response chrome and execution states

- Audited requirements 13–14 and 26–31. Split response work into chrome and
  execution/error presentation (8a), then classification, large-data viewing,
  headers and remaining utilities (8b). Existing response bytes/encoders and
  supported renderers remain authoritative; echo responses are not rewritten.
- Response navigation measures tab/metadata label widths, retaining status and
  adapting format, duration, size and reason phrase to available space. Formats
  move into contextual actions on narrow panels. Headers always shows its count
  when known, including zero. HTTP 2xx/3xx/4xx/5xx use distinct semantics; unknown
  and cancelled outcomes stay neutral. Badge tint/foreground were adjusted to
  pass a numerical 4.5:1 normal/hover contrast target in settled light/dark themes.
- Missing metrics are distinct from measured zero. Durations use ms/seconds/
  minutes and decoded sizes use IEC units. Metric tooltips explain their source.
  Status opens a bounded scrolling inspector with exact counts, full literal
  reason, URL, redirects, connection reuse and transfer state. Contextual menus
  scroll within the viewport and reveal keyboard targets; body modes remember
  Raw when temporarily viewing Headers. Empty/non-HTTP failures omit irrelevant
  body-format/search/copy/save controls.
- A useful previous response and its selection/indexes stay readable while a
  new job runs, under an explicit Previous response notice. Current progress
  reads only immutable request fields and the job's atomic byte count. New
  completion releases the previous owner before showing its own metadata/data.
  Clear previous response leaves the active job intact; retained/export owners
  can continue reading the older body. Empty execution failures are not retained
  as misleading previous HTTP responses.
- Added typed failure and timing-availability fields to completed responses.
  HTTP errors keep their body/header viewers. DNS/refused/lost/TLS/file errors,
  timeout, cancellation and partial transfers have distinct non-modal notices.
  Technical messages are explicitly expandable; cancellation is neutral and
  partial HTTP responses carry a Partial status marker. Cancellation/timeout log
  severity also matches their outcome. Prefix notices use actual received and
  shown counts rather than the old hard-coded 8 MiB assumption.
- Preparation failures now have per-request Not sent state, preserve draft and
  useful prior response data, and reveal technical details without losing error
  context. Visible response panels use the inline notice; hidden panels retain
  a toast. Allocation failure while constructing a request also has a state.
  Owned response popups close on document changes and share notification deferral
  with table popups. The table toast regression now seeds its own notification.
- Debug and ReleaseFast full suites passed with new CUI matrix/ownership/error regressions,
  OOM request preparation, zero/unknown metrics, long literal reason inspection,
  1,200-header layouts, native keyboard overflow reveal/Clear, popup cleanup,
  current-versus-previous metrics and retained-source reference counts. HTTP,
  cancellation, timeout, partial, dropped/refused and preflight cases use real
  local jobs; DNS/TLS/file presentation also has injected structured coverage.
  Production and diagnostic ReleaseFast builds passed. The diagnostic self-test
  and snapshots passed in an isolated workspace; reviewed previous-response,
  cancellation, partial, Not sent, narrow navigation, light HTTP error badge,
  long literal details, scrolling actions and storage-failure captures under
  `test-output/improvements-part-8a/workspace-response-*.png`. A private-desktop
  production startup/shutdown smoke completed with exit 0. Formatting and diff
  whitespace checks passed. Logs: `test-output/improvements-part-8a-debug.log`
  and `test-output/improvements-part-8a-release.log`.
- Fixed a pre-existing spill-allocation failure that could continue consuming
  bytes after the preview limit while silently dropping the remainder. The
  transfer now stops with a storage failure and retains the available prefix.
  A failing-allocator regression checks that no discarded bytes are counted;
  injected UI coverage checks the partial HTTP status and storage notice.
  Save labels and notices promise only available data after a storage failure.
  Partial OS write failures and broader save guarantees remain in the 8b audit.
- Remaining for 8b: whole-document JSON detection, malformed/binary handling,
  bounded/asynchronous large response preparation, detailed response headers,
  wrap/horizontal navigation, search and copy/save utilities. OS input/clipboard,
  real DNS/TLS negotiation, dynamic-theme/IME/accessibility and GPU acceptance
  retain later audits; numerical badge contrast is not app-wide accessibility
  certification. No performance improvement is claimed.

## Slice 8b1: trustworthy response content detection

- Audited existing sniffing, JSON validation/formatting and view preparation.
  Broke 8b into content detection (8b1), bounded background preparation (8b2),
  then response headers and utilities. This slice does not claim to finish
  large-response handling: formatting/tree construction, HTML stripping and
  image decoding still need their UI-thread work addressed in 8b2.
- Completed network workers scan/classify the bounded in-memory body before
  publishing it. UI metadata/view lookups reuse that immutable result. No body
  copy or conversion is needed. Small manually constructed diagnostic responses
  retain a bounded fallback; unprepared large synthetic responses use hex.
- JSON detection requires one valid whole document, including scalar JSON.
  MIME parameters/substrings, opening brackets and embedded fragments cannot
  select JSON tools. Declared malformed JSON remains original text and shows a
  line/column; prefix-only/incomplete bodies do not enable JSON formatting/tree.
  The inspection nesting limit has its own message rather than labeling a
  potentially valid deep document as syntactically invalid.
- Fixed JSON lexing to reject unknown/short/non-hex escapes, raw string controls,
  invalid UTF-8 and overlong/surrogate/out-of-range UTF-8 encodings. Valid escaped
  Unicode, exact number spelling and raw source bytes are preserved. Initialized
  the grammar's nesting bits before bit updates. Pretty/minified response output
  is capped at 16 MiB, discards incomplete derived output, and preserves the
  source on output/allocation failure; formatter allocation errors propagate.
- Binary inspection scans beyond the former 8 KiB sample and overrides text,
  JSON and Markdown MIME hints. A late NUL or invalid UTF-8 uses hex; a plausible
  UTF-8 sequence cut by a preview boundary alone does not make text binary. SVG
  uses the supported XML text view instead of the PNG/JPEG decoder. Markdown
  preview is limited to textual content and retains its declared format.
- Added real loopback malformed/escaped/fragment/scalar/SVG/binary cases plus
  2 MiB valid JSON, late invalid content and late NUL bodies. Worker metadata,
  byte preservation, spill-prefix classification and late-error locations are
  checked in HTTP tests. CUI checks cover actual fallback views/notices, original
  source identity, Ctrl+A and attempted typing into a read-only malformed body.
  Core tests cover depth/output limits, UTF-8 boundary cases, metadata invalidation
  and allocation cleanup. The long overflow-menu regression now uses a complete
  previous JSON response retained after a preparation failure.
- Debug and ReleaseFast full suites and production/diagnostic ReleaseFast builds
  passed. Diagnostic self-test/captures passed in an isolated scratch workspace;
  reviewed malformed text, echoed fragment, binary Markdown hex and JSON-prefix
  notices at 640x420. Captures are under
  `test-output/improvements-part-8b1/workspace-response-*.png`; full-suite logs
  are `test-output/improvements-part-8b1-debug.log` and
  `test-output/improvements-part-8b1-release.log`. Private-desktop production
  startup/shutdown smoke exited 0. Formatting and whitespace checks passed.
  No app-wide performance, accessibility, OS clipboard or large-derived-view
  completion claim is made. Next is 8b2 background preparation and bounded
  fallback behavior, followed by headers and utilities.

## Slice 8b2: bounded background response preparation

- Moved lazy JSON pretty/minify/tree construction, HTML stripping, PNG/JPEG
  CPU decode, large raw line indexes, derived indexes and JSON continuation
  scans to a bounded two-worker service. Tasks borrow immutable response bytes
  through retained HTTP jobs. They never hold tab/UI pointers or duplicate a
  source body to start work. Completed text/index buffers transfer to the UI;
  rendering frames do not repeat their construction.
- Mode changes, Clear and closing tabs immediately abandon their job interests.
  A worker has separate ownership and releases obsolete results/source pins on
  completion. App shutdown joins the group before destroying app state. A full
  pool produces a visible fallback and retries on completion wakes; there is no
  unbounded task queue or polling timer. Allocation/start failures stay settled
  rather than retrying each idle frame; explicit retry controls remain in 8b3.
- Preparation limits are 8 MiB source, 16 MiB formatted output, 200,000 tree
  nodes and 1,000,000 text rows. Raw indexing borrows the source rather than
  making a formatted copy. Busy/failed large text shows at most a clearly
  labeled 64 KiB UTF-8-aligned original prefix; raw copy/save still accesses
  available response data. Small source indexing is bounded to 64 KiB. Large
  read-only JSON no longer runs full bracket pairing on caret moves. Tree key
  and value labels cap display length at UTF-8 boundaries; copy sources stay
  whole. Expand/collapse actions appear only once a tree is available.
- Kept texture creation/destruction on the UI thread. Native image CPU decode
  now checks dimensions/pixel expansion and charges cumulative allocation
  requests against 192 MiB per decode, covering malformed compressed streams
  whose inflated data disagrees with their image header. Worker-side reduction
  caps published previews to 2048 pixels per side (at most 16 MiB RGBA upload).
  A scaled preview explains its original and preview dimensions. Received image
  bytes remain unchanged; partial/corrupt/unsupported/limited images fall back.
- Engine tests cover exact number/string preservation, source borrowing,
  output/node/row limits, all allocation failures for text/tree/raw preparation,
  bounded slots, acquire/publish/take ownership, source lifetime after abandon,
  shutdown joining and start failures. Deterministic gated CUI workers prove
  URL input and pane navigation remain usable while both slots are occupied.
  CUI tests verify worker index/span pointer adoption, 4 MiB strings/HTML,
  no repeat preparation per frame, mode/clear/close source release, and labeled
  output/node/row fallbacks. Existing real HTTP and PNG/HTML tests now explicitly
  await asynchronous view results without making the frame helper itself wait.
- New diagnostic-only image fixtures exercise real PNG reduction, JPEG decode,
  corrupt/partial data and a 1x1 PNG envelope with 256 MiB of inflated IDAT data
  rejected by the allocation budget. Fixture bytes and regeneration instructions
  are in `tests/fixtures/response/`; production builds omit those fixtures.
- Final Debug and ReleaseFast full suites, production/diagnostic ReleaseFast
  builds and isolated diagnostic self-tests passed. Reviewed waiting and
  output/node/row-limit captures at 640x420, plus scaled-image and image-limit
  captures at 1000x800, under
  `test-output/improvements-part-8b2/workspace-preparation-*.png`. Logs:
  `test-output/improvements-part-8b2-debug.log` and
  `test-output/improvements-part-8b2-release.log`. A private-desktop production
  startup/shutdown smoke exited 0. Formatting and diff whitespace checks passed.
  No app-wide performance improvement,
  accessibility, OS input/clipboard or GPU acceptance is claimed. The existing
  bounded inline Markdown renderer still needs the broader performance audit.
- Next 8b3: response headers, wrap/horizontal navigation, search, formatted/raw
  copy and save semantics (including spill/partial-write behavior). That slice
  must preserve background index ownership when adding wrap/resize controls.

## Slice 8b3a: received header inspection and copying

- Audited requirements 14, 24, 28 and 31 and the header workflow in 62. Split
  remaining 8b3 into received headers (8b3a), body navigation/wrapping/search
  (8b3b), then remaining copy/save utilities and IO semantics (8b3c).
- Replaced the old boxed grid, duplicate count, vertical cell dividers and
  persistent copy icons with a flat virtualized read-only table. Geometry and
  hairlines use the shared table metrics. Name/value previews are selectable
  native controls, capped at 512 source bytes with literal ellipsis/escapes.
  Full values no longer appear on hover; tooltips explain inspection/actions.
  Empty responses show a genuine no-headers state and omit irrelevant copy.
- Enter or row actions opens a bounded inspector. Long name/value fields use
  16 KiB pages with byte ranges and previous/next controls, rather than losing
  access beyond a preview. Copy name/value/line actions outside the scroll area
  use full source fields. Row copies retain literal wire-line whitespace and
  casing; all-header copies retain the received CRLF block and duplicates.
- Added read-only Tab/Shift Tab, Up/Down, Page Up/Down and Ctrl Home/End navigation
  with virtual-row reveal. Tab leaves the first/last cell. Native selection and
  Ctrl+A/C work; native read-only Cut copies its selection without deleting data.
  Header-owned menus close when the response execution changes and restore
  focus to Headers, avoiding stale row actions after a replacement. Existing
  ownership cleanup closes inspectors on view/document removal.
- Header display handles control and invalid UTF-8 bytes without sending NUL
  into C strings. Clipboard-safe fields/blocks copy exactly; otherwise actions
  explicitly copy escaped bytes, including backslash disambiguation. Copy
  preparation allocation failures release temporary buffers and report an error.
  No received data is changed by preview, selection, paging or copying.
- Fixed head replacement ownership: prepare the new reason/URL/raw headers and
  parsed slices before committing. An allocation failure leaves the old head
  coherent and readable rather than retaining rows into freed raw storage.
  Each parsed header also retains its literal raw line without another copy.
- Core allocation-failure regressions cover transactional replacement and normal/
  escaped clipboard preparation. HTTP tests check duplicate case/order, empty
  values, literal marker text and exact line whitespace. CUI tests use a real
  1207-header, approximately 50 KiB loopback head, including a 17 KiB value,
  plus synthetic non-UTF-8/NUL input. They verify selected/full/page/row/block
  copies with an in-memory clipboard, read-only input, distant-row navigation,
  Tab exit, inspector bounds, source replacement/focus, empty 204, and both themes
  at four scales/three widths. OS clipboard contents are never touched.
- Final Debug and ReleaseFast full suites and production/diagnostic ReleaseFast
  builds passed. Isolated diagnostic self-tests/captures passed; reviewed compact
  dark/light headers, the paged inspector and the empty 204 state at 640x420 under
  `test-output/improvements-part-8b3a/workspace-headers-*.png`. Logs:
  `test-output/improvements-part-8b3a-debug.log` and
  `test-output/improvements-part-8b3a-release.log`. Private-desktop production
  startup/shutdown smoke exited 0. Formatting and diff whitespace checks passed.
  Remaining body text utilities and copy/
  save/spill-write semantics are pending; native OS clipboard, accessibility,
  GPU acceptance and broad performance audits retain their later phases.

## Slice 8b3b1 behavior — response wrap and horizontal navigation

- Split body utilities into wrapping/navigation (8b3b1), search (8b3b2), then
  remaining copy/save/spill semantics (8b3c). This slice covers requirements
  14/26 reading controls and keeps the larger response phase open.
- Response actions offers checked Wrap lines in applicable text views. The
  preference is per open request and survives response replacement/clear.
  Unwrapped viewers retain actual logical lines, including a 4 MiB single line,
  instead of inserting synthetic 2,000-byte visual breaks. Gutter numbers stay
  separate and continuation rows do not repeat the logical line number.
- The response-only geometry engine indexes UTF-8-aligned byte/x checkpoints
  no larger than 256 bytes. Layout, selection, caret, hit testing and wrapping
  use the same font advances and two-space tab stops. CRLF and original bytes
  stay unchanged. Horizontal positions use double precision before subtracting
  the viewport offset, preserving far-line positioning beyond float precision.
- Paint visits visible rows/checkpoints, and native prefix measurements for
  positioning/hit testing stay within one checkpoint. A pathological dense
  run is capped at 32 painted checkpoints per visible row, with explicit
  disclosure; all source bytes remain available for selection/copy/save.
- Layouts above 4 KiB prepare on the two-slot worker service, with private CUI
  font contexts and no access to the UI context. Reflow retains the immutable
  HTTP source and a shared lease for formatted/stripped buffers, avoiding copies
  or reformatting during resize. Replaced and unused pane layout interests cancel, and
  shutdown joins workers. Initial preparation uses a labeled bounded prefix;
  pending reflow retains the previous usable layout. Work has 16 MiB input,
  1,000,000-row and 1,000,000-checkpoint bounds and cancellation checks.
- Horizontal trackpad/dx, Shift+wheel, ordinary vertical wheel, draggable
  horizontal/vertical thumbs and track clicks are supported. Read-only arrow,
  Home/End, Ctrl Home/End and Page Up/Down navigation retain selection extension.
  Reflow preserves the top visible byte anchor and selection; raw/formatted
  views retain independent reading state through Headers and mode switches.
- Core tests cover 4 MiB true lines, distant Unicode hit testing with measured
  call-size bounds, UTF-8/tab/CRLF wrapping, zero-width checkpoints, invalid
  metrics, every partial allocation, mid-build cancellation, worker start failure
  and deterministic derived-buffer retention during canceled reflow. CUI tests
  cover far selection/copy through an in-memory clipboard, read-only input,
  wheel/trackpad/Shift and both scrollbars, actual Wrap menu activation, Page
  navigation, resize anchors, per-view positions and pending clear ownership.
  A gated busy-slot regression also preserves selection made in the initial
  prefix when the full geometry becomes ready. Geometry checks span both
  themes, four scales and three widths; a settled
  4 MiB response requests no redraw or timed wakeup.
- Debug and ReleaseFast full suites, diagnostic and production ReleaseFast
  builds passed. Diagnostic self-tests/captures passed with scratch KEST_DATA;
  reviewed `test-output/improvements-part-8b3b1/workspace-response-text-`
  `{wrap-dark,wrap-light,distant-end}.png`. Logs are
  `test-output/improvements-part-8b3b1-{debug,release}.log`. The production
  private-desktop startup/shutdown smoke exited 0. Formatting and whitespace
  checks passed. Existing search still needs its separate 8b3b2 audit;
  formatted/raw copy/save semantics remain in 8b3c. OS input/clipboard,
  accessibility, complex-script/grapheme behavior, GPU acceptance and broad
  performance comparisons remain in their later phases.

## Slice 8b3b2 behavior — response Find

- Replaced response-only synchronous search with cancellable background literal
  search on the two-slot preparation service. No full response copies are made:
  workers retain the immutable HTTP execution and derived-text lease and own
  a bounded query snapshot. Clearing, hiding, editing or replacing the source
  drops the old interest; completed stale results are discarded. Source identity,
  exact query bytes and match-case key the cache, independently of text layout.
- A KMP automaton bounds repeated-prefix queries to linear work. Search accepts
  up to 4096 query bytes over 16 MiB of available text. It counts all matches,
  caches one page of at most 10,000, and loads another page for distant ordinal
  navigation. The old first-10,000 navigation ceiling is removed. Literal matches
  keep non-overlap semantics. Match case is optional; insensitive matching folds
  ASCII A-Z and compares other UTF-8 bytes exactly. It does not add regex or full
  Unicode case folding. Spilled bytes outside the received preview are not scanned.
- Automaton state every 256 source bytes permits bounded visible highlighting
  anywhere in the source, regardless of the current match page. Highlighting
  scans the visible byte range plus a checkpoint and query overlap, retains the
  whole-source overlap phase, clips to the content viewport and bounds output.
  It does not rescan a multi-megabyte prefix on every frame. Current selection
  remains distinct from other match highlights. Empty/error states are explicit;
  inactive navigation disables when no matches exist, and an unavailable search
  can retry on query change or reopening Find.
- Find in response preserves the current text view (formatted/minified JSON,
  Raw, original text/XML or HTML text preview). Tree Find opens formatted text;
  Markdown preview Find opens Raw. Large original Pretty views use their own
  reading/search state rather than accidentally hiding controls in Raw state.
  Ctrl+F inside a request body stays scoped there even with a response shown.
  Native query editing, Ctrl+F query selection, Enter/F3, Shift reverse traversal,
  pointer navigation, match-case and Escape focus restoration are exercised.
  Controls use a second row in narrow response panes instead of overlapping.
- Search stays available during initial layout/index preparation and after a
  full-view row-limit failure. Distant results select a bounded original byte
  window with explicit byte offsets and relative line-number labeling. Escape
  retains that reading window and selection for copying. Query/case/clear actions
  preserve received response bytes and request-body data. Wrap/resize/theme/scale
  changes preserve the search index; inline reflow no longer leaves a stale
  Reflowing message on an already prepared frame.
- Engine tests cover repeated-prefix maximum-length queries, UTF-8/literal CRLF,
  non-overlap checkpoint phase, all-match counts and last-match navigation beyond
  cache limits, empty/invalid-limit states and every partial allocation. Worker
  tests verify copied query ownership, retained derived bytes, abandoned interest
  and start-allocation failures. CUI tests search a 4 MiB single line with 65,536
  matches, wrap through first/last pages, sample inactive-highlight pixels and
  exercise the actual response menu. They also cover busy-slot typing, stale
  query changes, query-limit recovery, current raw/formatted/minified/HTML/UTF-8
  sources, a million-row distant-match fallback, clear ownership, body shortcut
  scope, dark/light themes, four scales and stacked/compact column layouts.
  Settled search requests no redraw or timed wakeup; settled layouts do not rebuild.
- Debug and ReleaseFast full suites, diagnostic and production ReleaseFast builds,
  isolated diagnostic capture self-tests and native lifecycle smoke passed.
  Capture review covers formatted and compact controls in both themes, visible
  highlights in a long line and the distant fallback match. Artifacts are under
  `test-output/improvements-part-8b3b2/`; logs are
  `test-output/improvements-part-8b3b2-{debug,release}.log`. Formatting and diff
  whitespace checks passed. Remaining 8b3c covers formatted/raw copy actions and
  save/spill IO semantics. Native OS input/clipboard, accessibility, complex
  scripts/graphemes, GPU acceptance and broad performance comparisons remain
  in later phases; the core response inspection phase stays open.

## Completion pass (slices 8b3c–14)

The earlier log was re-checked rather than trusted: the suite was re-run before
any edit (passed), and the demo workspace was captured at 1282×832 in both
themes. Those captures showed issues the log had not addressed; each fix below
has a regression in `src/workflow_tests.zig` unless noted.

- **Request sections (req. 12).** The floating gear opened a hidden Settings
  pane and the chevron duplicated Layout > Focus response. Settings is now a
  fourth labeled content tab (`Settings •` when any transfer option differs
  from the default) and the chevron is gone; any section tab restores the
  editor after Focus response. Layout menu items show which mode is active.
- **Collection tree (req. 16, 32, 33).** Row `…` buttons appear only on the
  hovered or selected row, or while that row's menu is open; the 28px slot
  stays reserved so names never shift. Right-click still works everywhere.
  Long verbs (PROPFIND) shrink to fit the fixed method slot instead of being
  cut to `PROPFI…`. Rows have a method + full-name tooltip. Search placeholder
  is `Search requests`, Escape clears it, and a matching folder lists all of
  its contents (previously a collapsed match drew as an open, empty folder).
- **Bug found by the new test:** revealing a request (breadcrumb, switching
  tabs) selected it but never scrolled the tree to it once it was beyond the
  first screen (row 998 of 1000 in the stress workspace). CUI only follows
  cursor changes it already knew about, and a freshly shown tree has no
  extent yet. `kest_collection_reveal` now scrolls it into view once the tree
  has been laid out.
- **Close and save safety (req. 48).** Closing a changed request now offers
  Cancel / Discard / Save (Save as… for unsaved drafts; the tab closes only
  after Save as completes, and stays if it is dismissed). Save-and-close waits
  for the background write and keeps the tab if it failed. Any failed write
  of a linked request now marks that tab changed again, so a failed save no
  longer looks saved. The test forces a real failure by replacing the request
  file with a directory.
- **Command palette (req. 38, 45).** Grouped (Request, Tabs, Layout,
  Collections, Environments, Application) with shortcut chips in the app's
  existing `Ctrl S` format; adds close/next/previous tab, find, Copy as cURL,
  Save as, layout focus modes, Manage environments and one entry per
  environment. The test runs `Focus response` through typed search + Enter.
- **Response utilities (8b3c, req. 31).** Copy formatted / minified JSON when
  that view is prepared; Save suggests `.json/.xml/.html/.md/.txt/.bin` from
  the classified content (bytes are unchanged).
- **Composer.** A brand-new empty URL no longer shows the link icon in the
  error colour (the outline already treated empty as "not yet an error").

### Measurements (req. 55)

Pre-overhaul commit `582ae63` built in a temporary worktree vs. this tree,
both ReleaseFast, `tests/performance/startup.ps1 -Runs 5 -IdleSeconds 5`
on a private desktop with empty scratch data:

| | Before | After |
| --- | --- | --- |
| Median time to first idle | 149.6 ms | 145.2 ms |
| Median working set | 58.7 MiB | 58.8 MiB |
| Idle CPU | 0.000 % | 0.000 % |
| Executable size | 2.64 MB | 2.87 MB |

`zig build bench` (1 GiB loopback, 2,000 sequential requests, history) was
equivalent within run-to-run noise. No improvement is claimed; the result is
"no measurable regression" for startup, memory and idle CPU.

Postman import runs on the UI thread. `zig build bench` now times the
detect + parse step (file reading excluded; request files are written by the
existing background store):

| Collection | File size | Detect + parse |
| --- | --- | --- |
| 2,000 requests | 0.6 MiB | 7.5 ms |
| 20,000 requests | 6.4 MiB | 79.4 ms |

That is about one dropped frame at an extreme size, so no progress indicator
was added: it would only flash for a moment.

### Drag reordering in the collection tree (req. 35)

- A press on a folder or request row becomes a drag only after the pointer
  moves more than 5px, so clicks never move anything. Escape cancels until
  the button is released; dragging is off while searching, in dialogs, the
  palette, or with a row menu open, and the actions button never starts one.
- Drop zones: the top or bottom half of a request row inserts before or after
  it (accent insertion line). The middle of a folder drops inside it (accent
  outline); the top or bottom quarter inserts beside it. A collection row
  always takes the item inside. Targets inside the dragged folder and no-op
  drops show no indicator and do nothing.
- Holding the pointer within 32px of the tree's top or bottom edge
  autoscrolls, faster nearer the edge; it stops away from the edge.
- Moves reuse the existing tree operation (`tree.moveAt`, which `moveTo` now
  calls), so file relocation across collections and tab links stay correct.
  Only the changed collection is saved; rows rebuild once.
- `workflow_tests.zig` covers the threshold, reorder before a row, drop into
  a folder, Escape cancel, autoscroll in both directions and invalid targets.
  Captures: `workspace-workflow-drag-{reorder,into}.png`. The autoscroll
  check prints its measurement (e.g. offset 33491 → 33329 px over 12 frames,
  then held once the pointer leaves the edge).

### Real Windows input (req. 50, 51)

`tests/integration/os_input.ps1` starts the real ReleaseFast app, with its
real window and GPU surface, on a private desktop. It sends the Win32
messages Windows delivers for mouse, keyboard and committed text
(`WM_MOUSEMOVE`, `WM_LBUTTONDOWN/UP`, `WM_KEYDOWN/UP`, `WM_CHAR` via
`PostMessageW`) to the app's actual window procedure. It then closes the
window and checks the files the app saved. It passed 3 of 3 runs:

- a press that wobbles 2px is a click and moves nothing;
- dragging Gamma onto the top of Alpha saves `[Folder A, Gamma, Alpha]`;
- dragging Beta onto Folder A's middle saves it inside the folder;
- Escape during a drag leaves everything in place;
- clicking Alpha, clicking the URL, End, then typing saves
  `…/alpha/typed-é日本😀`. That covers ASCII, Latin-1, CJK (the
  characters an IME commits) and an emoji sent as a UTF-16 surrogate pair;
- the app exits with code 0 after `WM_CLOSE`.

It found two real bugs, both fixed and covered by headless regressions:

1. A drop into a collapsed folder opened it and was then closed again in the
   same frame by the tree's open-state sync, hiding the dropped item. The
   move is now applied after that sync.
2. A dropped item is selected without being opened, so clicking it again did
   nothing (CUI reports only selection *changes*). A plain click on a
   request now opens it whenever it isn't the current tab.

The physical cursor is never over a window on a hidden desktop, so Windows
answers each `TrackMouseEvent` with an immediate `WM_MOUSELEAVE`. With
`KEST_SYNTHETIC_POINTER` set (only by the harness), `host.c` ignores that one
notification. Nothing changes otherwise.

What this does not cover, and why:

- **Screen readers.** UI Automation sees the window ("Kest") with 0
  descendant elements: CUI's Win32 backend has no `WM_GETOBJECT` provider.
  Req. 50 asks for screen-reader semantics "where supported by the native
  framework"; CUI does not support them, so adding a provider means
  extending the UI library, not Kest. Accessible names do exist for every
  icon button (CUI labels, tooltips) for when CUI gains that support.
- **IME composition.** Committed IME text arrives as `WM_CHAR` and works (CJK
  above). CUI handles no `WM_IME_*` messages, so the composition and
  candidate windows use Windows' default position rather than following the
  caret. That is also a CUI backend limitation.
- **Pixels.** PrintWindow cannot read the GPU swap chain on a hidden desktop
  (the images are blank), so rendering evidence remains the software-renderer
  captures.
- **Multi-monitor and mixed DPI.** This machine has one 1920×1080 monitor at
  96 DPI. Moving a window across monitors with different scales cannot be
  exercised here; `WM_DPICHANGED` handling exists in CUI and `host.c`.

### Sidebar search highlighting and toasts

- Matched text in tree rows is tinted with the accent colour (clipped to the
  label; lighter tint in the light theme). The workflow test checks that
  exactly the matching row is marked; see
  `workspace-workflow-sidebar-search.png`.
- The empty frame above a "Saved" toast in the palette capture is CUI's
  intended toast stacking: cards behind the newest show only their edge
  (`cui_overlay.c`). It is not a bug.

### Verification

- `zig build test` and `zig build test -Doptimize=ReleaseFast` pass
  (logs: `test-output/finish-{debug,release}.log`), including the new
  workflow suite. `zig fmt --check` on changed files and `git diff --check`
  pass.
- Diagnostic self-test captures in `test-output/finish/` were reviewed:
  `workspace-workflow-{sidebar-hover,sidebar-search,close-prompt,palette}.png`,
  `workspace-settings.png`, `workspace-environment-editor.png`, plus demo
  captures `demo-light.png` (1282×832) and `demo-1024.png` (1024×768).

### Remaining limitations (not done or not verifiable here)

- Real Windows mouse/keyboard/committed-text input is verified by
  `tests/integration/os_input.ps1` (above). Not verifiable here: screen
  readers (CUI exposes no UI Automation tree), IME composition-window
  placement (CUI handles no `WM_IME_*`), real clipboard, GPU pixels on a
  hidden desktop, and mixed-DPI multi-monitor moves (one monitor available).
- Settings text fields only re-sync from `settings` on load; code that
  changes `settings` directly (only test fixtures today) leaves stale text.

## Verification log

- Before edits: `zig build test -Doptimize=ReleaseFast` passed, including real
  loopback HTTP, CUI pointer/key interactions, persistence, font/title bar,
  sidebar, memory lifecycle and large-editor checks.
- Slice 1: `zig build test` and `zig build test -Doptimize=ReleaseFast` passed.
  New checks cover default policy, actual loaded query rows, JSON/form/upload
  content indicators, workspace schema round trips, old/unknown/invalid pane
  values, pointer selection persistence, and per-tab restoration with body text
  preserved. Existing HTTP/import/export/undo/layout checks also pass.
- Built diagnostics with `zig build -Doptimize=ReleaseFast -Ddiagnostics=true
  --prefix test-output/improvements-part-1`. Ran the real application with
  `--self-test --snapshot=... --width=1282 --height=832` in an explicit scratch
  workspace; generated the existing multi-view capture suite.
- Also captured a separate POST/JSON draft restored from an old-format
  workspace with no `requestPane`. It opens directly at Body. Inspected captures
  in light mode at 1282×832 and 640×420, plus the dark body workspace. The payload
  and content indicator render; minimum size stacks the panes. Captured 125%
  as supplementary evidence; the full DPI matrix remains for later slices.
- Captures: `test-output/improvements-part-1/selection-dark.png`,
  `selection-light.png`, `selection-minimum.png`, `selection-125.png`, and
  `workspace*.png`. These are generated scratch artifacts, not committed assets.
- Capture inspection still shows the old boxed breadcrumb, embedded Save icon,
  and legacy response-header label. Those remain explicitly scheduled; this
  slice makes no claim to resolve geometry or complete the overhaul.
- Native smoke: ran the diagnostic executable on a private Windows desktop with
  the existing `tests/performance/startup.ps1` harness (one run, one idle second,
  scratch workspace). Startup and shutdown completed with exit 0. This is a
  lifecycle smoke check, not a before/after performance study.
- The initial restart regression placed its saved-request and unsaved-draft
  probes first to stay inside the then-40-tab restoration cap (raised to 64 in
  slice 4). Run Debug and ReleaseFast suites sequentially: both use
  `test-output/workspace`. Production `zig build -Doptimize=ReleaseFast` also
  completed and updated `zig-out/bin/kest.exe`.
- OS input, screen reader behavior and GPU/display rendering are not established
  by headless checks. No performance improvement is claimed for this slice.
