# Kest

A native HTTP client. The interface uses CUI 1.1.0,
pinned to commit `d0383c4d3c00b7769f6b11cefdf581e1800f2da3`; networking, validation,
collections, environment resolution and persistence use Zig 0.17.0.
There is no browser engine, telemetry, account or runtime package manager.
Windows text uses DirectWrite grid fitting with grayscale antialiasing at the
monitor's pixel density. The bundled fonts and CUI layout metrics are retained;
icons and the fallback text path use CUI's original rasterizer.

## Build

On Windows x86-64, with Zig 0.17.0 on PATH:

```powershell
cd kest
zig build -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
```

The first build downloads the pinned CUI source. Subsequent builds use the local
package cache. CMake, a separate C compiler and Node are unnecessary. The app is
`zig-out/bin/kest.exe`; distribute the `zig-out/licenses` directory with it.
The CUI host is Windows-only at present. The engine remains portable; Linux and
macOS hosts have not been implemented or tested.

`ReleaseFast` is the recommended distribution build: Zig optimizes for runtime
speed and the CUI/rendering/image C sources use `-O3`. Executable size is not
the target. Release executables are stripped, and the normal app excludes the
headless UI tests. The bundled loopback fixture server starts only in demo mode. Plain `zig build` remains a debug build.

## Workspace and shortcuts

### Repeatable demo workspace

Double-click `Demo.cmd`, or run `kest.exe --demo` (from source:
`zig build run -Doptimize=ReleaseFast -- --demo`). Every launch creates a fresh,
separate workspace under `%APPDATA%\kest-demo\<session-id>`; when `KEST_DATA`
is set, demo sessions go under that folder's `kest-demo` subdirectory. Your normal
collections and preferences are not loaded or changed. Demo sessions are retained
on disk so you can inspect or export your experiments.

The built-in loopback API starts automatically on a free port and stops with the
app. No internet, account, Python, or other server setup is needed. Five collections
include fictional people/orders, every body type, enabled/disabled rows, a real
sample upload, status codes, redirects, a three-second timeout/cancel example,
Markdown/HTML/image/binary responses, empty folders, and a long nested tree.
Three environments use the same local API with different dummy variable values.
Eight tabs send automatically so real responses, headers, history, and activity
are ready to inspect. All data is fictional; people/order endpoints return fixed
fixtures rather than implementing CRUD. Closing and reopening Demo starts over.

The default data folder is `%APPDATA%\kest-cui`. `KEST_DATA` selects another
folder.

Ctrl+Enter sends or cancels; Ctrl+N creates a request; Ctrl+S saves; Ctrl+D
duplicates; Ctrl+W closes; Ctrl+F searches; Ctrl+B toggles the workspace;
Ctrl+J toggles activity; Ctrl+Tab and Ctrl+Shift+Tab cycle requests;
Ctrl+Shift+P opens the command palette, including saved requests.

Commands and Activity are also available in the top toolbar. The sidebar header
switches Collections/History/Environments and groups creation and collection
import; row menus retain export actions. Editors extend to the bottom of the
window when Activity is closed. Native window position, normal size and maximized
state restore safely within a current monitor's work area.

The [Kest workspace](docs/ui-redesign.md) uses T3 Code's neutral dark/light palettes, a compact
collection tree table, reorderable document tabs, a joined method/URL composer and direct-entry parameter tables.
Save sits beside the URL group and shows pending changes or Saved. The link
control inside the URL group opens current URL/variable details with Copy
resolved URL. Invalid URLs and missing variables show inline feedback. Enter
in the URL sends once; Ctrl+Enter sends or cancels from the workspace. Holding
an execution key does not repeatedly send or toggle cancellation.
Type into the empty final row to add a value; Tab moves between cells.
Enter also advances cells, Shift+Tab goes back, and Up/Down stay in the same
column. Table actions offers Add row and Bulk edit. Row actions appear on hover
or focus; right-click a cell, Alt+Down, or Shift+F10 opens inspection, enable,
duplicate, move and delete actions. Headers keeps configured values separate
from the read-only automatic-header inspector.
Bulk edit supports Apply/Cancel and preserves the table on malformed text or a
row-limit/allocation failure. JSON-quoted keys/values retain exact whitespace and
separators; `# ` disables a row and `@file ` marks an upload field. Query edits
preserve repeated keys, existing percent escapes and explicit empty values,
while protecting literal cell separators from becoming URL structure.
The raw body toolbar keeps Format JSON, Wrap and Find beside the body selector.
Tab/Shift+Tab indent or outdent; Enter carries indentation, including between
JSON brackets. Ctrl+M toggles Tab focus traversal, and Escape returns to the
body selector. Wrap changes presentation only. JSON errors identify a location
without discarding or blocking invalid drafts; template validation follows the
active environment. Body actions includes undo/redo, minify and copy.
Multipart rows show Text/File controls and a file picker; row actions also offer
keyboard access to field type and file selection. Switching formats preserves
all text, form fields and the binary path. URL-encoded forms treat values as
text while retaining multipart file flags for later. Binary mode shows the
selected file name/size, with Change file, Remove and Refresh. Metadata checks
run in the background without reading file contents; Send reads the current
file. Cancelling a picker preserves the draft. Paths can use environment
variables, and missing/unreadable files have actionable feedback.
Wide windows put request and response side by side. Smaller windows stack them;
the Layout menu also offers an explicit choice. Responses open as formatted code,
with JSON tree/raw/minified modes in the format menu and headers in a table.
The response header adapts to panel width; overflow keeps formats and utilities
available. Click the status for duration, byte counts, URL and execution details.
A new send keeps a useful previous response visible with a clear Previous
response notice, while its progress metrics come from the current job. HTTP
4xx/5xx keep their bodies and headers; cancellation, timeout and transport
failures have separate inline states with expandable technical details.
JSON tools require one valid whole document. Malformed JSON remains readable as
original text with a location; incomplete response prefixes are not formatted as
complete JSON. Binary or non-UTF-8 data uses hex even under a text content type.
Response formatting, trees, HTML stripping, image decoding and large text
indexes prepare in the background. Busy or oversized views keep a labeled
original-data fallback; preview limits never rewrite the received bytes.
Received headers use a flat read-only table with selectable previews. Enter
opens inspection; long fields have pages, and copy actions retain full fields,
literal header lines, or the complete header block.
Response actions offers Wrap lines in text views. With wrapping off, original
lines remain intact and scroll horizontally with the trackpad, Shift+wheel or
scrollbar. Page Up/Down navigates text; raw and formatted views keep independent
reading positions. Large wrap/resize work runs in the background and never edits
response bytes.
Find in response searches the current text view. Enter/F3 advances, Shift moves
back, and Escape returns focus to the document. Aa toggles case matching. Find
opens formatted text from a JSON tree and Raw text from a Markdown preview;
HTML text previews search their displayed text. Counts include all available
text, with navigation beyond the bounded match cache. Response and editable-body
Find commands follow the focused editor.
CUI's document tabs support dragging and Shift+Left/Right to reorder a focused tab;
arrows and Home/End switch focused tabs, and Ctrl+Tab cycles requests. The Tabs
menu lists complete request names in a scrolling list. Method labels, dirty dots
and close buttons have separate slots; the active close button stays visible.
All 64 supported open requests can restore across restart, including their views.
Unsaved tabs still ask before closing. Click a breadcrumb to reveal its collection
or folder. Ctrl+J opens the searchable activity console with level filters, Follow,
Copy and Clear; its input is the existing redacted log. Markdown responses have a
formatted Preview tab (up to 256 KiB; larger documents use the virtualized text
viewer). Layout choice and side-by-side divider position persist across restarts.
All transitions are instant. Layout > Focus response (or the command palette) focuses the response; any request section tab restores the editor.
Below 840 px the collection browser opens as an overlay. The minimum window is
640x420. Row menus and right-click expose collection organization/export actions;
drag a folder or request to reorder it or drop it into a folder (Esc cancels).
The request menu includes Save as and Copy as cURL. New/Open requests reveal their
tab and collection location.

## Verification

```powershell
zig build test
zig build test -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
```

Tests use loopback HTTP and scratch folders. CUI UI tests run directly in a
software context: no native window, system clipboard or real input is used.
The test step builds a separate, uninstalled `kest-check` executable and
supplies `KEST_DATA=test-output/workspace`. Headless execution refuses to start
without an explicit `KEST_DATA`.

Render a real application image without opening a window:

```powershell
zig build -Doptimize=ReleaseFast -Ddiagnostics=true --prefix test-output/diagnostics
$env:KEST_DATA = "$PWD/test-output/screenshot-workspace"
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/workspace.png
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/minimum.png --width=640 --height=420
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/sidebar.png --width=640 --height=420 --sidebar
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/light.png --light
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/dpi-125.png --scale=1.25
```

`--self-test` additionally exercises real loopback requests and the UI, and prints
the large-editor frame benchmark. Combining it with `--snapshot=...` captures its
actual loopback JSON response. Each run starts with fresh in-memory tab fixtures.
It writes test collections into the supplied
scratch workspace; never point that command at your real data.
It also captures related views beside the requested image, with suffixes such
as `-body.png`, `-light.png`, `-minimum.png` and `-focus.png`.
These flags require `-Ddiagnostics=true`; normal distribution builds omit them.

The existing `tests/performance/startup.ps1` runs the native window on a private
Windows desktop. `tests/integration/os_input.ps1` does the same and drives the
real window procedure with Windows mouse, keyboard and text messages (tree
dragging, Escape, typing Unicode, IME placement), then checks the files the app saved.
`-Dpi 144` repeats everything after a simulated move to a 150% monitor:

```bash
powershell -File tests/integration/os_input.ps1 -Exe zig-out/bin/kest.exe -Data <empty folder>
```

See [verified coverage](docs/supported_features.md),
and [measurements](docs/performance.md). The [CUI 1.1 update](docs/cui-1.1-update.md)
records component choices, compatibility work and validation.

## Icon

The angular K mark is shared by the app header and Windows icon. Its source is
`assets/kest.svg`; `tools/build-icon.ps1` regenerates the PNG, multi-size ICO and
native vector geometry using Windows System.Drawing. The app needs none of
these development tools at runtime. Windows metadata and the title use Kest.
Native exports use `.kest.json` / `.kest-env.json`.

## Licenses

Kest and CUI are MIT licensed. CUI's embedded Inter/Geist fonts and Lucide icons
have their own licenses, installed with the application.
