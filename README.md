# Kest

A native HTTP client. The interface uses CUI 1.1.0,
pinned to commit `d0383c4d3c00b7769f6b11cefdf581e1800f2da3`; networking, validation,
collections, environment resolution and persistence use Zig 0.17.0.
There is no browser engine, telemetry, account or runtime package manager.

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
separate workspace under `%APPDATA%\kest-demo\<session-id>`; when `RETORT_DATA`
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

The default data folder is `%APPDATA%\retort-cui`. `RETORT_DATA` selects another
folder.

Ctrl+Enter sends or cancels; Ctrl+N creates a request; Ctrl+S saves; Ctrl+D
duplicates; Ctrl+W closes; Ctrl+F searches; Ctrl+B toggles the workspace;
Ctrl+J toggles activity; Ctrl+Tab and Ctrl+Shift+Tab cycle requests;
Ctrl+Shift+P opens the command palette, including saved requests.

The [Kest workspace](docs/ui-redesign.md) uses T3 Code's neutral dark/light palettes, a compact
collection tree table, reorderable document tabs, a joined method/URL composer and direct-entry parameter tables.
Type into the empty final row to add a value; Tab moves between cells.
Wide windows put request and response side by side. Smaller windows stack them;
the Layout menu also offers an explicit choice. Responses open as formatted code,
with JSON tree/raw/minified modes in the format menu and headers in a table.
CUI's document tabs support dragging and Shift+Left/Right to reorder a focused tab;
unsaved tabs still ask before closing. Click a breadcrumb to reveal its collection
or folder. Ctrl+J opens the searchable activity console with level filters, Follow,
Copy and Clear; its input is the existing redacted log. Markdown responses have a
formatted Preview tab (up to 256 KiB; larger documents use the virtualized text
viewer). Layout choice and side-by-side divider position persist across restarts.
All transitions are instant. The request chevron focuses the response.
Below 840 px the collection browser opens as an overlay. The minimum window is
640x420. Row menus and right-click expose collection organization/export actions.
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
supplies `RETORT_DATA=test-output/workspace`. Headless execution refuses to start
without an explicit `RETORT_DATA`.

Render a real application image without opening a window:

```powershell
zig build -Doptimize=ReleaseFast -Ddiagnostics=true --prefix test-output/diagnostics
$env:RETORT_DATA = "$PWD/test-output/screenshot-workspace"
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/workspace.png
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/minimum.png --width=640 --height=420
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/sidebar.png --width=640 --height=420 --sidebar
./test-output/diagnostics/bin/kest.exe --snapshot=test-output/light.png --light
```

`--self-test` additionally exercises real loopback requests and the UI, and prints
the large-editor frame benchmark. Combining it with `--snapshot=...` captures its
actual loopback JSON response. It writes test collections into the supplied
scratch workspace; never point that command at your real data.
It also captures related views beside the requested image, with suffixes such
as `-body.png`, `-light.png`, `-minimum.png` and `-focus.png`.
These flags require `-Ddiagnostics=true`; normal distribution builds omit them.

The existing `tests/performance/startup.ps1` runs the native window on a private
Windows desktop. See [verified coverage](docs/supported_features.md),
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
