# Kest: verified coverage

This checklist applies to Kest with CUI 1.1.0. The original application's checklist
does not establish coverage for this interface.

**T** = run in engine/HTTP tests. **U** = run through the CUI headless harness.
**S** = actual rendered image inspected. **W** = compiled, not exercised.

## Engine and data

| Feature | Verification |
| --- | --- |
| HTTP/1.1, methods, query/URL sync, headers, body preparation | T; GET/POST and query sync U |
| JSON/text/XML/form/multipart/file bodies | T; JSON editing and POST U |
| TLS default verification, per-request override | Default and option retained; UI W; prior original-app manual TLS checks not counted here |
| Redirects, cross-host sensitive-header removal | T |
| Cancellation, timeout and response-size limits | T; cancellation U |
| Response memory limit, disk spill and full body saving | T; export-after-clear lifetime U |
| Collection files, tree operations, history, environments, drafts | T; saved request/environment, reload and cURL import U |
| Postman/native import and export, cURL parse/generate | T; cURL review/accept U |
| Atomic workspace writes and store writer | T, U |
| Export writer and retained response lifetime | U |
| Path validation and log redaction | T |

## CUI interface

| Feature | Verification |
| --- | --- |
| Kest executable/title/Windows icon | ReleaseFast built; 16-256px ICO frames verified; metadata and private-desktop check documented in performance.md |
| Headless snapshots and UI self-tests | Separate test executable; snapshots require a build with `-Ddiagnostics=true` |
| T3 Code neutral dark/light palettes, blue actions and monochrome K identity | Both S; instant theme changes U; control geometry retained |
| Inset pane tabs and document/collection selection markers | Dark/light S; existing pointer/keyboard interaction checks U |
| Separate code syntax palette and flat primary actions | JSON/body S; mode and editing checks U |
| Short, settling motion in the native interface | motion_scale 0.5; headless motion=0 U; native idle CPU 0.000% after settling |
| Native document tabs, new/close, reorder and overflow reveal | Pointer new/close, active-tab reveal, Shift+arrow reorder and dirty-close confirmation U; mouse dragging W |
| Resizable sidebar; adaptive side-by-side/stacked request-response split | Both layouts S; width-based adaptation U; layout/split preferences round-trip T; divider dragging W; explicit layout picker W |
| Hide/restore request details to focus on response | Actual chevron clicks and response height U; focused response S |
| Narrow workspace sheet at 640×420 | Toggle U; compact and unobstructed workspace images S |
| Request Params/Body/Headers and settings control | Actual pane/body-type clicks U; params/body/settings S |
| Direct-entry tables, empty insertion row and URL sync | Actual key/value typing, continued focus and Tab to value U; populated table S; unused insertion row excluded from request data |
| Minimum-size row visibility and response space | Populated row AND insertion row fully visible U; JSON viewport at least 60 px with empty request details U/S |
| Joined method/URL composer and standard/custom method menu | Actual GET/POST/custom selection and custom typing U; dark/light S |
| Body syntax colors, format/minify, bounded undo/redo | Format, undo and actual pointer/text input U |
| Body and response search | Response match U; search controls drawn; navigation W |
| Formatted response, JSON mode menu, raw and preview | All modes U; actual tree/minified/raw/formatted menu choices U; formatted code S |
| Response header table with row copying | Real loopback headers U/S; OS clipboard W |
| Virtualized JSON tree, expand/collapse, formatted/minified | U |
| Binary hex view | U with a real 9 MiB loopback response |
| PNG/JPEG response image | PNG decode U, aspect-preserving canvas; JPEG compiled, not exercised |
| HTML text preview | U with a real loopback response |
| Markdown response preview | Real loopback Markdown U; response bytes retained; oversized markup falls back to virtualized text U |
| Native activity console | Bounded ring, redacted adapter, search input, Clear and hidden/reopen U; level filters/Follow/OS copy W; console S |
| Native collection tree table and path bar | Keyboard collapse/expand and pointer breadcrumb reveal/filter reset U; selection and row menus retained; type-ahead compiled |
| Copy body/headers/JSON values and cURL | W; system clipboard intentionally never touched |
| Native file import/upload/save dialogs | W; dialogs never opened on the developer desktop |
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
- SVG preview and header-name autocomplete are not supported.
- JSON search opens Raw; the tree itself is not filtered.
- No OS clipboard or real input testing. No screen-reader/IME/complex-script
  validation. Byte-based editor column geometry is a known limitation.
- Current runs contain 71 engine tests, 17 HTTP tests and the additional executable CUI harness.
- Current limitations include: no HTTP/2, cookie persistence, proxies, browser
  HTML rendering, or tree drag/drop. These features are outside the current scope.
