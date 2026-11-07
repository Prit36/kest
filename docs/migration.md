# Migration analysis

## What changed

Retort already separated its HTTP engine and data formats from its UI. Rewriting
the engine in C would add risk without improving the framework integration.
This migration copies that engine into a standalone folder and replaces the
NanoUI application/window/widgets with CUI, called through Zig's build-time
`translate-c` bindings. There is no NanoUI link or runtime dependency.

The CUI source is pinned and hash verified. CUI's C99 sources are compiled by
Zig and linked statically. System OpenGL is preferred; CUI supplies a software
fallback. Embedded font subsets and icons avoid font downloads or asset loads.
Font licenses are installed with the executable.

Distribution builds omit the headless harness, its loopback test server and
snapshot-only code. `zig build test` compiles a separate diagnostic executable;
`-Ddiagnostics=true` explicitly enables snapshots in a developer build. Release
executables are stripped. The recommended distribution build is `ReleaseFast`,
with `-O3` for all CUI, renderer, host and image C sources. Runtime speed takes
priority over executable size. No production feature is removed by these choices.

The application layer keeps the existing commands, request state, environment
variables, collection operations, drafts and completion queue. Its small editable
buffer and notification types now belong to `ui/model.zig`. The prior body
editor's row index and bounded undo stack remain, with a new CUI canvas renderer.

## UI decisions

The CUI application is named Kest. It retains the Retort data-folder/format
identifiers for compatibility, with a new executable, title, mark and resource metadata.

See the [workspace redesign](ui-redesign.md) for reference analysis, spacing,
motion policy and the added interaction checks.

- A quiet top bar contains the app identity, environment and global actions.
- Document tabs show the method and unsaved state and handle close requests.
- Collections, history and environments share a searchable workspace sidebar.
- CUI owns splitters, menus, dialogs, command palette, focus and theme colors.
- At narrow widths the sidebar becomes a sheet, preserving editor space.
- Response status, duration and bytes share a compact footer below the viewer.
- JSON opens as formatted code in the virtualized canvas editor; a format menu also provides the virtualized tree, minified and raw views.
- Activity remains bounded and uses only `core/log.zig`'s redacted output.

## Performance boundaries

No network work runs on the UI thread. Request workers push finished jobs to
`App.done` and wake the Win32 loop with a posted message. The window sleeps when
settled. Save debounce uses one one-shot native timer that removes itself on
delivery; it is not a polling loop. Disk refresh happens on activation.

Workspace writes and explicit exports use the store writer. A response export
retains the completed job until its bytes or spill file have been saved, so
clearing or closing the tab cannot invalidate it. Only eight exports can wait.

The canvas indexes each document once per version and paints visible rows and
columns. It does not feed a multi-megabyte document into CUI's wrapping textarea
or code-block widget. Rows wrap at 2,000 bytes; horizontal caret following makes
the rest of a long row reachable. JSON token coloring is restricted to visible
text. A steady caret removes periodic blink wakeups. Transient toasts/tooltips
retain their own finite deadlines.

Response previews remain capped at 8 MiB; larger bodies spill to temporary files.
JSON trees cap at one million nodes and fall back to text. Image decoding runs
on demand, rejects dimensions above 8,192 and decoded images above 64 MiB, and
caches both success and failure. Formatted JSON and invalid-format results are
cached per response and mode. Editable buffers cap at 32 MiB. Search, history,
undo, notifications and activity have fixed bounds inherited from or added to
Retort.

`src/host.c` and `src/controls.c` contain the CUI-internal boundary: editor input,
focus, flat table fields, interactive rows/tabs, scroll reveal, lazy popup creation,
clipboard services and steady-caret scheduling. Updating CUI requires reviewing
both files and running the headless and private-desktop checks. This host currently uses
Win32 messages and timers; it intentionally rejects other targets at build time.

## Differences and remaining checks

The feature checklist distinguishes tested engine behavior from drawn UI and
unexercised OS dialogs. The CUI interface does not yet include the original
SVG preview or header-name suggestions. PNG/JPEG are decoded; other image
formats can be saved. JSON search uses the raw view rather than a filtered tree.
The custom editor has UTF-8-aware edit boundaries, but column hit testing uses
fixed byte-based advances; complex scripts, IME composition and grapheme cluster
selection have not been verified. This is a material difference from the original
DirectWrite renderer. CUI's embedded fonts cover Latin subsets; broad font
fallback and screen-reader behavior need a separate platform pass.

Native focus/input, file dialogs and long interactive sessions still need manual
testing. No developer screen, keyboard or system clipboard was used during this
migration. The real native window is checked only on a private desktop.

Sources inspected: the checked-in NanoUI v0.12.0 package; Retort's feature and
architecture documents; the pinned [CUI source](https://github.com/yappologistic/CUI/tree/145407d7296554a1f2a2909fcc4769d75774716f)
and its app, component, layout, editor, canvas and renderer implementations.
