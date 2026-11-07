# Kest measurements

Measured on the Windows development machine on 2026-11-07, with Zig 0.17.0.
The initial measurements use `-Doptimize=ReleaseFast`, including the
diagnostic harness. The current distribution build prioritizes runtime speed:
Zig uses `ReleaseFast`, and CUI, both renderers, the host and image decoder use
`-O3`. The earlier size experiment below uses `ReleaseSmall`.
These are observed runs, not guarantees. The machine's OS caches were warm.

## Workspace memory and interaction optimization

The November 7 performance pass replaces per-field OS page allocations with
the C heap, releases response row indexes and search buffers on clear, limits
retained frame scratch to 256 KiB, and releases restoration scratch after each
tab. History parsing reuses at most 512 KiB of scratch between entries. JSON
tree toggles update the affected rows rather than rebuilding the entire list;
collapsing locates the subtree boundary with binary search, with a remaining
linear move of the row indices after it. Expand-all still walks the document.

The pass also fixes tab allocations leaked by missing saved-request links,
invalidates cached text/search indexes on source-length changes, and refreshes
the editor's source pointer after edits that can reallocate its buffer.

The native workload is reproducible with `tests/performance/workspace.ps1`:
40 restored drafts, each with 100 header pairs and a 256 KiB text body.
The same generated input was copied into separate before/after directories.
Three sequential runs per executable used the existing private-desktop harness
and three seconds of idle observation, with warm OS caches.

| Native workload | Before | After |
| --- | --- | --- |
| Median working set | 101.2 MiB | 71.1 MiB |
| Median private bytes | 127.8 MiB | 97.6 MiB |
| Median time to first idle | 157.0 ms | 156.9 ms |
| Observed normalized idle CPU, all runs | 0.000% | 0.000% |

Memory improved in this workload; these startup samples do **not** demonstrate
a startup speed improvement. All six processes exited 0. Working set is measured
after startup settles, rather than peak restoration memory. These measurements
predate the final history-scratch reuse and editor-pointer fix; the workload has
no history and does not edit text. GPU rendering and full native click latency
remain outside the headless frame measurements.

Added regression coverage compares incremental JSON toggles with a complete
rebuild, including hidden and empty containers. The CUI harness checks that
response clearing releases index/search capacity, supports repeated resets,
and refreshes search when the source length changes at the same address.
The final Debug and ReleaseFast checks passed all 89 engine/HTTP tests and
the CUI harness. The final ReleaseFast 200-frame UI sample measured 0.174 ms
median and 0.348 ms p99, with settled redraw false and no scheduled wakeup.
These frame timings exclude rasterization, GPU submission and display.

```powershell
powershell -NoProfile -File tests/performance/workspace.ps1 -Data test-output/my-perf-workspace
powershell -NoProfile -File tests/performance/startup.ps1 -Exe zig-out/bin/kest.exe -Data test-output/my-perf-workspace -Runs 3 -IdleSeconds 3
```

## CUI 1.1 distribution

The current production executable is 2,570,240 bytes. Debug and ReleaseFast
checks pass, including the native component integration harness. The final
ReleaseFast 200-frame 4 MiB sample measured 0.177 ms median and 0.365 ms p99;
settled redraw was false and no wakeup was scheduled. The isolated upstream
editor measurement and its limitations are recorded in the
[CUI 1.1 update](cui-1.1-update.md).

Three native private-desktop runs of the current build measured 151.4 / 129.8 /
129.8 ms to first idle, 58.3 / 57.5 / 57.5 MiB working set and 0.000% normalized
idle CPU over three seconds per run. All exited 0. These observations are not a
controlled comparison against the earlier revisions below.

## Earlier speed-focused distribution (before CUI 1.1)

The recommended command is `zig build -Doptimize=ReleaseFast`. That revision's
Kest executable was 2,437,120 bytes; executable size is not the optimization
target. The reviewed build is `zig-out/bin/kest.exe`. Its Windows product name,
description and original filename were checked, and its embedded 32px K icon
was extracted and verified. The source ICO contains 16/20/24/32/40/48/64/128/256px
frames generated from the same SVG polygons used by the in-app mark.
It retains all production features and excludes the headless harness, loopback
test server and snapshot-only code. The test step compiles a separate diagnostic
executable. Developer snapshots require `-Ddiagnostics=true`.

The Debug and ReleaseFast test steps passed, including all 88 engine/HTTP tests
and the extended CUI interaction harness. The final ReleaseFast harness's 200-frame
UI CPU sample measured 0.158 ms median and 0.362 ms p99, using the workload and
exclusions described below. This is an observed sample, not proof that `-O3`
outperforms every other compiler setting.

One private-desktop check of this production build measured 131.7 ms to first
idle, 118.7 MiB working set, 137.8 MiB private bytes and 0.000% normalized idle CPU
over three seconds; exit code 0. The headless harness separately confirmed
settled redraw=false and no scheduled CUI wakeup. These are observational runs,
not a controlled memory comparison with earlier revisions.

The [workspace redesign](ui-redesign.md) uses short motion that always settles
(CUI tokens at half duration), keeps all network and disk work on the existing
worker paths, and adds no periodic animation or polling work. With motion on, two
private-desktop runs reached first idle in 138-168 ms at 0.000% idle CPU. Measurements of earlier revisions
below remain historical baselines, not controlled before/after comparisons.

## Earlier size experiment

The initial ReleaseFast executable, including diagnostics and using `-O2` for
CUI, was 2,845,696 bytes. The separate ReleaseSmall experiment produced 1,549,312
bytes after removing diagnostics and using `-Os` for C. All 88 engine/HTTP tests
and the CUI harness passed, with a UI CPU frame sample of 0.232 ms median and
0.418 ms p99. A single private-desktop run observed 183.9 ms to first idle and
0.000% idle CPU over three seconds. That experiment is not the selected build;
runtime speed now takes priority over a 1 MB executable budget.

## Native application

`tests/performance/startup.ps1` created a private Windows desktop, started the
real executable there, measured idle, posted close messages to its windows and
checked exit. It never switched the developer's desktop or sent real input.
`KEST_DATA` pointed to `test-output/native-idle`.

| Run | Time to first idle | Working set | Private bytes | Idle CPU |
| --- | --- | --- | --- | --- |
| 1 | 198.0 ms | 117.8 MiB | 137.1 MiB | 0.000% |
| 2 | 122.5 ms | 57.5 MiB | 84.5 MiB | 0.000% |
| 3 | 121.8 ms | 57.5 MiB | 83.2 MiB | 0.000% |

A final three-run repeat after the preview and compact-layout changes measured
140.0 / 118.8 / 121.7 ms to first idle, 57.4 / 57.5 / 57.4 MiB working set,
and 0.000% idle CPU in every run. Each exited with code 0.

All runs exited with code 0. Idle was observed for three seconds per run, after
500 ms of settling; CPU is normalized over all processors. This short observation
cannot prove the process will never wake. The headless test separately asserts
`cui_needs_redraw == false` and `cui_next_wakeup < 0` after transient UI expires.
`WaitForInputIdle` is a startup proxy, not a pixel presentation timestamp.

These native runs predate the current `-O3` distribution build.

## UI frame cost

The executable self-test times 200 CUI frames at 1180×800 and scale 1, with the
pointer moving, a real JSON response present and a 4 MiB single-line request
body in the editor. It includes building widgets, layout and generating draw
geometry. It excludes software rasterization, GPU submission, vsync and display.

The initial ReleaseFast self-test measured **0.094 ms median, 0.102 ms p99**.
Earlier release runs ranged from 0.092 to 0.118 ms median and 0.102 to 0.316 ms
p99. One-time row indexing, JSON parsing and image decoding are outside
these steady-frame numbers. No claim of an end-to-end frame rate is made.

The editor keeps a row-start index, virtualizes rows and columns, and reuses the
index until the text changes. CUI's standard wrapping textarea is used only for
the small bulk-edit and cURL dialogs.

## Engine and storage

These are runs of the copied engine, not evidence of a new faster transport.

| Work | Observed result |
| --- | --- |
| Load the tree for 10,000 saved requests | 9.1 ms; 1.26 MiB retained; request files loaded lazily |
| Flatten all 10,101 tree rows | 0.259 ms |
| Filter tree by name | 0.268 ms |
| Read one request | 0.228 ms |
| 1 GiB response over loopback | 1,518 ms; 15.81 MiB maximum held by the measured allocator; remainder on disk |
| Endless response, 64 MiB limit | Stopped at 64 MiB in 100 ms |
| 2,000 sequential loopback requests | 134 ms; 1,999 reused connections; 0.11 MiB held after both 100 and 2,000 requests |
| 100,000 history additions, retaining 1,000 | 97.6 ms; 0.11 MiB retained |

The engine benchmark's 8 MiB JSON tree takes about 43 ms to build and 28.38 MiB
for 959,752 nodes. That initial parse can hitch. The application limits trees to
one million nodes and otherwise uses text. The benchmark also deliberately
constructs a 64 MiB tree unreachable through the app's 8 MiB preview limit;
its 295.9 MiB process peak should not be read as idle application memory.

## Reproduce

```powershell
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast --summary all
zig build bench -Doptimize=ReleaseFast
powershell -NoProfile -File tests/performance/startup.ps1 -Exe zig-out/bin/kest.exe -Data test-output/native-idle -Runs 3 -IdleSeconds 3
```

The UI harness additionally checks pointer/text editing, undo, query sync, real
GET/POST/cancellation, every JSON response mode, raw search, tree expansion,
exports after clearing both in-memory and spilled responses, HTML/PNG previews,
cURL import and workspace reload. None of these tests opens a native window.

Cold starts, prolonged native interaction, IME/accessibility, other operating
systems and real native frame throughput have not been measured.
