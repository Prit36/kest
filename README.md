# Kest

A native HTTP client, evolved from Retort in a separate, independently buildable folder.
The original NanoUI application is untouched. The interface uses CUI 1.1.0,
pinned to commit `d0383c4d3c00b7769f6b11cefdf581e1800f2da3`; networking, validation,
collections, environment resolution and persistence remain in Zig 0.17.0.
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
macOS hosts have not been migrated or tested.

`ReleaseFast` is the recommended distribution build: Zig optimizes for runtime
speed and the CUI/rendering/image C sources use `-O3`. Executable size is not
the target. Release executables are stripped, and the normal app excludes the
headless UI tests and loopback server. Plain `zig build` remains a debug build.

## Workspace and shortcuts

The default data folder is `%APPDATA%\retort-cui`. `RETORT_DATA` selects another
folder. These legacy names stay compatible with existing CUI workspaces after
the Kest rename. Nothing reads or changes the original `%APPDATA%\retort` automatically.
To use an existing workspace, close both apps and copy its files to the new data
folder. The collection, environment, history, draft and workspace formats are
the same. Use a copy while evaluating this version.

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
tab and collection location. The data formats and native worker architecture stay
compatible with the migration described below.

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
[migration analysis](docs/migration.md) and [measurements](docs/performance.md). The [CUI 1.1 update](docs/cui-1.1-update.md)
records component choices, compatibility work and validation.

## Icon

The angular K mark is shared by the app header and Windows icon. Its source is
`assets/kest.svg`; `tools/build-icon.ps1` regenerates the PNG, multi-size ICO and
native vector geometry using Windows System.Drawing. The app needs none of
these development tools at runtime. Windows metadata and the title use Kest.
Native exports use `.kest.json` / `.kest-env.json`; their internal format identifiers
remain compatible with existing Retort files.

## Licenses

Kest retains Retort's MIT license; CUI is also MIT licensed. CUI's embedded Inter/Geist fonts and Lucide icons
have their own licenses, installed with the application. `src/ui/code_state.zig`
retains Retort's editor model; it has no NanoUI dependency. The downloaded CUI
package is never edited.
