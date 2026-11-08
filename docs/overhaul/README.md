# Kest UI/UX overhaul — summary

This is the deliverable set requested by `improvements.md` §66: audit
summary, fix summary, verification results and remaining limitations. The slice-by-slice engineering log, with every test
and measurement, is [`docs/improvements-progress.md`](../improvements-progress.md).

## Audit summary — what was wrong

From the supplied screenshot:

- The path bar was a boxed control with an always-visible pencil, adding a
  row of chrome above the composer.
- Save was an icon squeezed inside the URL field; the URL field also carried
  a permanent "Resolved: …" line below it.
- Request settings hid behind a floating gear, and a chevron duplicated the
  Layout menu's "focus response".
- Request and response tabs were drawn by different components with
  different heights, baselines and selected states; counts were bare numbers
  ("Headers 3").
- Some borders met at half-pixel edges and doubled where panes joined.
- The document strip clipped names with no overflow menu; long method verbs
  were cut (`PROPFI…`).
- A footer status bar and a sidebar footer repeated shortcuts and actions
  that already existed elsewhere.
- Row actions (`…`) showed on every tree row at once, adding noise.

Found in the code and other screens:

- A saved request restored on restart opened at Headers even when it had a
  body (content selection was applied only on one command path).
- Revealing a request deep in a long tree selected it without scrolling to it.
- Closing a changed tab had no Save option; a failed save looked saved.
- The command palette had no grouping or shortcut hints.
- No real-Windows input path was tested; the IME candidate window appeared at
  a default spot rather than the caret.
- Screen readers saw an empty window (CUI publishes no UI Automation tree).
- Keyboard focus was left on closed palettes/dialogs and hidden sidebars, so
  Tab restarted at the first control.
- The app ignored the Windows light/dark setting and the "Show animations"
  setting.

## Fix summary — what changed

- **Shared design system** (`ui/metrics.h`, `design.zig`): one set of spacing,
  type, icon, radius and control-height roles used by C and Zig; one
  content-tab primitive for request and response; counts in parentheses;
  borders snapped to device pixels with one owner per edge.
- **Shell and layout**: compact global toolbar (environment, Commands,
  Activity, appearance); status bar and sidebar footer removed, their actions
  moved to the toolbar, palette and menus; adaptive request/response split
  (side by side or stacked) with Layout menu focus modes; sidebar width,
  split, open tabs and window placement persisted and clamped to the screen.
- **Navigation**: document strip with an overflow "Tabs (n)" menu, full-name
  tooltips and dirty markers; a plain path breadcrumb that reveals the item in
  the tree.
- **Request composer**: method, URL, a separate Save/Saved button and Send in
  one row; resolved URL and variables moved into an Inspect URL popover;
  Settings became a labelled section tab (`Settings •` when changed).
- **Params, headers, body**: direct-entry tables with bulk edit and row
  actions; body editor with format/wrap/find, Tab-moves-focus (Ctrl M);
  multipart and binary bodies with file details; the body opens first when a
  request has one.
- **Response inspector**: one metadata row (status, time, size), Body/Headers
  tabs, JSON text/tree/minified views, background preparation for large
  bodies, Find, wrap, copy formatted/minified/raw, and save with a
  content-typed file name.
- **Collections**: hover-only row actions, search with highlighting, drag
  reordering and drop into folders, reveal-and-scroll.
- **Safety**: Save / Discard / Cancel on close; a failed write keeps the tab
  dirty.
- **Native quality**: IME window at the caret; UI Automation provider with
  names, roles, focus and values; Windows theme and animation settings
  followed; focus returns after palettes and dialogs and stays useful when
  the sidebar hides or the selected item is deleted.

## Verification results

| Area | How |
| --- | --- |
| Unit, interaction and workflow suites | `zig build test` and `zig build test -Doptimize=ReleaseFast`, both passing |
| Window sizes | 640×420, 1024×768, 1280×800, 1280×832, 1282×832, 1366×768, 1440×900, 1920×1080, 2560×1440 × both themes × 100/125/150/200 % (`geometry_tests.zig`) |
| Real Windows input | On a private desktop at 100/125/150/200 %: click threshold, drag reorder/into folder/Escape, typed ASCII/accented/CJK/emoji, IME position, Ctrl C/Ctrl V through the real clipboard (previous contents restored), UI Automation tree, and the window following a Windows light/dark switch live |
| Keyboard only | `src/keyboard_tests.zig`: create, set method and body type, type body, send, inspect and find in the response, palette/sidebar/delete focus — no pointer input |
| Request flows | Loopback server: GET/POST, all seven body modes, redirects, errors, cancel, 9 MiB responses, HTML/PNG preview, cURL import, workspace reload |
| Performance | Startup 139.8 ms to first idle, 59.3 MiB, 0 % idle CPU (before: 149.6 ms, 58.7 MiB); 4 MiB single-line editor frames under 2 ms |
| Visual | The self-test capture suite, reviewed in both themes |

## Remaining limitations

These could not be verified on this machine; none is claimed as done.

- **Spoken output of a real screen reader.** Narrator/NVDA were not driven;
  the tests check the UI Automation tree those readers consume. The provider
  is read-only (no Invoke or ExpandCollapse patterns), so readers announce
  controls and focus while activation uses the keyboard.
- **GPU-rendered pixels of the real window.** Windows cannot read back the GPU
  surface of a window on a hidden desktop; screenshots come from the
  software renderer, which shares all layout and drawing code.
- **A second physical monitor.** One monitor is attached; monitor changes are
  exercised by sending the real `WM_DPICHANGED` at 125/150/200 %.
- **The Windows theme switch** is simulated by a harness-only message that
  replaces the registry value and then takes the real `WM_SETTINGCHANGE` path;
  the user's Windows setting was not changed.
