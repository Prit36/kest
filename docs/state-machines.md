# Kest state machines

This file lists every state machine in Kest that holds state across frames or
threads. Some are explicit (an `enum` or a tagged union). Others are implicit:
a set of flags, optionals and pointers that only make sense in certain
combinations. For each machine it gives the states, the invariants and a
transition table. It then lists the invalid states and transitions the code
could actually reach, with evidence, how each was fixed, and the regression
test that covers it.

Keep this file in step with the code. When you change a transition, update its
table. When you fix or find a bug, update [Findings](#findings).

Conventions:

- **UI thread**: the thread that runs `shell.view`. Every `App` field is owned
  by the UI thread unless the field's row says otherwise.
- **Worker**: a task on `std.Io` (HTTP jobs, response preparation, upload
  metadata, the store writer).
- A frame runs `drainDone`, then the sidebar and workspace, then the dialogs,
  the palette, the toasts and `deletionToast`, in that order
  ([shell.zig:68-130](../src/ui/shell.zig:68)). Several findings depend on
  this order.
- Frames are driven by events and nothing polls. A deadline that passes while
  no frame runs is first seen by the next frame, after that frame has already
  handled its input.

## Contents

1. [HTTP send job](#1-http-send-job)
2. [Tab response slot](#2-tab-response-slot)
3. [Response view preparation](#3-response-view-preparation)
4. [Tab document persistence](#4-tab-document-persistence)
5. [Tab lifecycle (open, closed, destroyed)](#5-tab-lifecycle)
6. [Modal dialogs, close prompt and Save as](#6-modal-dialogs-close-prompt-and-save-as)
7. [Inline rename session](#7-inline-rename-session)
8. [Delete and Undo window](#8-delete-and-undo-window)
9. [Store writer](#9-store-writer)
10. [Refresh from disk](#10-refresh-from-disk)
11. [Import preview](#11-import-preview)
12. [Request history and its menus](#12-request-history-and-its-menus)
13. [Upload metadata cache](#13-upload-metadata-cache)
14. [Connection pool](#14-connection-pool)
15. [Pointer gestures (sidebar drag, editor drag)](#15-pointer-gestures)
16. [Findings](#findings)
17. [Issues (grouped fixes)](#issues)
18. [Risks noted but not confirmed](#risks-noted-but-not-confirmed)

---

## 1. HTTP send job

Code: [http_client.zig](../src/network/http_client.zig) and
[commands.zig `send`/`finished`](../src/app/commands.zig:281).

The `Job` is shared by reference count (`refs`). Its owners are the request
worker, the tab (as `job` and then as `shown`), response-preparation jobs and
export jobs. Only the worker writes `resp` until `on_done`. After that, `resp`
is immutable apart from `closeSpill`.

| State | Meaning |
|---|---|
| `Preparing` | `start` is preparing `out` on the UI thread. A failure returns an error and no job exists. |
| `Supervising` | The supervisor waits on `wake` with the timeout. The transfer task runs `client.perform`. |
| `Stopping` | Cancel, the timeout or shutdown happened: `task.cancel` is in progress. |
| `Finished` | `finish` set `resp.stop` and `error_text`, and `inspectContent` ran. |
| `Queued` | `on_done` appended the job to `app.done` under `done_lock`. |
| `Adopted` / `Orphaned` | `finished` gave the job to its tab as `shown`, or destroyed it because `user_data == null`. |

| From | Event | To | Notes |
|---|---|---|---|
| — | `send` with a valid method and a prepared request | Supervising | `t.job = job`. `send` returns early while `t.job != null`. |
| — | prepare error / `ConcurrencyUnavailable` | (none) | `startFailed`: `t.start_failure` is set. |
| Supervising | transfer ends (`wake` set by `transfer`'s defer) | Finished | `task.await` |
| Supervising | Cancel (`cancel_requested`, `wake`) | Stopping → Finished | |
| Supervising | timeout elapses | Stopping → Finished | `timed_out = true` |
| Supervising | `client.jobs.cancel` (shutdown) | Stopping → Finished | `error.Canceled` from the wait → `cancel_requested` |
| Finished | `on_done` | Queued | worker thread |
| Queued | `drainDone` (top of frame) | Adopted / Orphaned | |
| Supervising | the tab is closed (`closeNow`) | Supervising | `user_data = null`, `cancel()`, `t.job = null`, so the job ends Orphaned. |

How `finish` classifies the outcome. The first matching row wins.

| Condition | `resp.stop` |
|---|---|
| `timed_out` **and** `result.failure != .none` | `timed_out` |
| `cancel_requested` **and** `result.failure != .none` | `canceled` |
| `failure == .none` | `complete` |
| `failure == .canceled` | `canceled` |
| `failure == .stopped_by_sink` | `too_large` if the sink set it, else `failed` |
| anything else | `failed` |

Invariants:

- **J1** At most one running job per tab: `t.job != null` ⇒ `send` does nothing.
- **J2** `job.user_data` is either the tab whose `job` field holds the job, or
  null. `closeNow` clears both together.
- **J3** A transfer that returned with no failure is reported `complete`, even
  if a deadline or a Cancel raced it. Before **SM-6**, the timeout row did not
  check this.
- **J4** The UI reads only the atomic `resp.total`, `elapsedMs` and the
  immutable `out` of a running job.

## 2. Tab response slot

Code: `Tab.job`, `Tab.shown`, `Tab.start_failure` in
[tab.zig](../src/app/tab.zig:519). The status bar renders this machine
([response_chrome.zig `summaryData`](../src/ui/response_chrome.zig:43)).

States are the combinations of (`job`, `start_failure`, `shown`):

| State | `job` | `start_failure` | `shown` |
|---|---|---|---|
| Empty | null | none | null |
| NotSent | null | ≠ none | any |
| Sending | set | none | null |
| Sending over previous | set | none | set (labelled "previous") |
| Shown | null | none | set |

| From | Event | To |
|---|---|---|
| any but Sending | `send` succeeds | Sending / Sending over previous. An empty failed `shown` is dropped first (`discardEmptyFailure`). |
| any but Sending | `send` fails before sending | NotSent |
| Sending* | `finished` | Shown. The old `shown` is destroyed and `response.reset()` runs. |
| Sending* | Cancel | Shown, with `stop = canceled`. No history entry if there was no status. |
| any | `clearResponse` | Empty, or Sending if a job is still running |
| any | `closeNow` | the tab is closed with an Empty slot; a running job is orphaned |

Invariants:

- **R1** `job != null` ⇒ `start_failure == .none`. `send` clears it only after
  the job has started.
- **R2** `shown` is never a running job. It is only assigned in `finished`.

## 3. Response view preparation

Code: [response_prepare.zig](../src/app/response_prepare.zig) (the workers) and
[response_preparation.zig `ensure`](../src/ui/response_preparation.zig:38)
(the UI glue). There is one machine per `ResponseView` and it covers the
pretty, minified, tree, html and image views. A parallel machine handles the
raw index (`raw_index_*`).

| State | Fields |
|---|---|
| Idle | `preparation == null`, `preparation_failure == null`, nothing cached for the kind |
| Waiting | `preparation` set with the wanted kind |
| Busy | the Service has `max_running` jobs. Nothing is started, the state stays Idle and returns `.waiting`, and a completion wake retries |
| Ready | the derived result is cached (`tree`, `formatted` + `formatted_mode`, `stripped`, `image`) |
| Failed(kind) | `preparation_kind == kind` and `preparation_failure != null` |

| From | Event | To |
|---|---|---|
| Idle | `ensure(kind)` and the service accepts the job | Waiting |
| Idle | `ensure` with `Busy` | Idle (retried on the next wake) |
| Idle | `ensure` with an input limit, an incomplete image or OOM | Failed |
| Waiting | the worker is done and `take()` returns a result | Ready / Failed |
| Waiting | `ensure(other kind)` | `abandon()`, then Idle for the new kind |
| any | `ResponseView.reset` (new response, clear, close) | every job abandoned and every cache freed: Idle |

Invariants:

- **P1** A job holds a reference to its source `http.Job` until it is released,
  and so does every export. Clearing a tab never frees bytes a worker is
  reading.
- **P2** An abandoned job's result is never adopted: `take` is only called on
  the current `preparation`.

No reachable violation found. The existing tests cover abandon, busy slots and
shutdown joins.

## 4. Tab document persistence

Code: [persist.zig `touchTab`/`flushTab`/`writeFailed`](../src/app/persist.zig:223),
[tree_ops.zig `saveTabAs`](../src/app/tree_ops.zig:62).

This is an implicit machine over `link` (a saved home), `touched` (edited since
the last flush), `dirty` (differs from `saved_hash`, or the last write failed)
and `has_draft` (a draft file was written and not yet dropped).

| From | Event | To |
|---|---|---|
| any | edit → `touchTab` | `touched`, `dirty`, flush scheduled |
| touched, linked, autosave | `flushTab` | file written if the hash changed; `!dirty`, `!has_draft` |
| touched, linked, no autosave | `flushTab` | `dirty = hash ≠ saved_hash`; a draft is written when dirty, dropped otherwise |
| touched, unlinked | `flushTab` | the same: a draft is written when dirty, dropped otherwise |
| linked | `save` (forced flush) | file written; `saved_hash = h`; `!dirty`; draft dropped |
| unlinked | Save as → `saveTabAs` | linked to a new node; `!dirty`, `!touched`, draft deleted |
| linked | background write fails → `writeFailed` | `dirty`, `saved_hash = 0` (not `touched`, so autosave does not retry in a loop) |
| linked, clean | another program changes the file → `refreshTab` | reloaded, `saved_hash` updated |
| linked, dirty | another program changes the file | kept as it is, with a warning toast |
| linked | its request is deleted (`closeTabsOf`) | unlinked and `touchTab`; recorded in `app.unlinked` |
| unlinked (by a delete) | Undo (`relinkTabs`) | linked again and `touchTab` |
| has_draft | `closeNow` | draft file deleted, `!has_draft` |

Invariants:

- **D1** `has_draft` ⇔ a draft file exists for `t.id`, or its write is queued.
  Before **SM-7**, `closeNow` broke this.
- **D2** Closing asks first iff `dirty or (link == null and has_draft)`
  ([commands.zig `unsaved`](../src/app/commands.zig:75)).
- **D3** A tab that a delete unlinked is linked again by Undo of that delete.
  Before **SM-3**, Undo did not do this.

## 5. Tab lifecycle

Code: [commands.zig](../src/app/commands.zig) (`newTab`, `openRequest`,
`closeNow`, `reopenClosed`, `togglePin`, `moveTab`).

States: **Open** (in `app.tabs`), **Closed** (in `app.closed_tabs`, at most 10,
kept with its edits), **Destroyed**.

| From | Event | To |
|---|---|---|
| — | `newTab` / `openRequest` / `openUnsaved` / restore at startup | Open (refused at 64 tabs) |
| Open | `closeNow` (from `requestClose`, `closeIfSaved`, the close prompt's Discard, or Save and close) | Closed. The job is orphaned, the response freed and the draft deleted. |
| Closed | `reopenClosed`, when no open tab links the same request | Open (unpinned, appended) |
| Closed | `reopenClosed`, when an open tab links the same request | Destroyed; the open tab is activated |
| Closed | an 11th close | the oldest closed tab is Destroyed |
| Open/Closed | app exit | Destroyed |

Invariants:

- **T1** At most one *open* tab per saved request (`link.request`).
  `openRequest` activates an existing tab instead of opening another, and
  `tabOf` (rename, move, delete) relies on this. Before **SM-2**, reopening a
  closed tab broke it.
- **T2** Pinned tabs come before unpinned ones. `togglePin` and `moveTab`
  keep this, and `reopenClosed` unpins.
- **T3** `active < tabs.len` whenever `tabs.len > 0`. `current()` clamps it as
  well.
- **T4** Something that refers to a tab across frames, or across a menu or a
  toast, refers to it by `uid`, not by index (`menu_tab`, toast actions,
  `save_tab`). `Pending.close_tab` and `close_after_save` hold pointers but
  are only compared or used while the modal is open.

## 6. Modal dialogs, close prompt and Save as

Code: `App.modal`, `modal_open`, `pending`, `name_action`,
`close_after_save` and `save_tab` in [state.zig](../src/app/state.zig);
[dialogs.zig](../src/ui/dialogs.zig).

`modal` is an explicit enum: `none, name, confirm, import_preview, import_curl,
save_as, move_to, environment, settings`. It is meaningful only while
`modal_open` is true. Shortcuts, file drops, tree drags and disk refreshes of
the tree are suppressed while a modal is open.

The close-a-changed-tab flow:

| From | Event | To |
|---|---|---|
| Open tab T, unsaved | `requestClose(T)` (Ctrl+W, the tab's X, the tab menu's Close or Close all) | `confirm`, with `pending = close_tab(T)` |
| `confirm` | Discard (`acceptPending`) | `closeNow(T)` |
| `confirm` | Save, T linked | write, `store.sync()`, then `closeNow(T)`, or keep T if the write failed |
| `confirm` | Save as..., T unlinked | `save_as`, with `save_tab = T.uid` and `close_after_save = T` |
| `save_as` | primary button → `acceptSaveAs` | saves **the tab with `save_tab`**, then `closeNow` if it is `close_after_save` |
| `save_as` | Cancel or Escape | modal closed. The next frame clears `close_after_save` and `save_tab`; T stays open |

Invariants:

- **M1** The Save as dialog saves the tab it was opened for. That tab can be
  in the background: the X and the tab menu close tabs that are not in front.
  Before **SM-1**, the dialog saved `app.current()` instead.
- **M2** `close_after_save != null` ⇒ `modal_open and modal == .save_as`.
  `dialogs.view` clears it on the first frame with no modal open.
- **M3** `pending != .none` ⇒ `modal == .confirm`. `Pending.delete_history` is
  never constructed (dead state).

## 7. Inline rename session

Code: [rename.zig](../src/ui/rename.zig). This is an implicit machine over
`rename_action` (`null` / `Some`) and `rename_started`.

| From | Event | To |
|---|---|---|
| Idle | `begin` (F2, menu Rename) | Pending (`!started`) |
| Pending | the field is first drawn | Editing |
| Editing | Enter or Tab with a non-empty name | commit, Idle |
| Editing | Enter with an empty name | Editing, marked invalid |
| Editing | Escape | Idle, no change |
| Editing | a click outside, focus lost, a modal or the palette opens | commit, Idle |
| any | `begin` of another rename | commit, then Pending |
| any | the target is deleted (`deleteNode`, `deleteEnv`), its tab is closed, or the tree is reloaded | Idle (`rename_action = null`) |

No reachable violation found: every operation that frees a rename target
clears `rename_action`.

## 8. Delete and Undo window

Code: [tree_ops.zig](../src/app/tree_ops.zig:221),
[shell.zig `deletionToast`](../src/ui/shell.zig:427).

The state is `deleted` (detached nodes with their parent and index),
`deleted_envs`, `unlinked` (tabs whose links the deletes cleared, by uid) and
`undo_until`.

| State | Condition |
|---|---|
| Idle | all three lists empty |
| Window | lists non-empty, `now < undo_until` |
| Expired | lists non-empty, `now ≥ undo_until`, not yet finalized because no frame has run since |

| From | Event | To |
|---|---|---|
| Idle / Window | `deleteNode` / `deleteEnv` | Window (stacked). `undo_until = now + 8 s` |
| Expired | `deleteNode` / `deleteEnv` | **finalize everything first**, then Window holding only the new delete |
| Window | Undo (the toast action) | Idle: nodes reinserted, environments restored, tabs relinked |
| Window → Expired | time passes | Expired |
| Expired | `deletionToast` at the end of a frame | `finishDelete`: files deleted, nodes and environments freed, `unlinked` cleared |
| any | `refreshTrees` reloads a collection | `finishDelete` (undo records may point into the replaced tree) |
| any | exit | `finishDelete` in `App.deinit` |

Invariants:

- **U1** Undo restores only what was deleted in the current window. Before
  **SM-5**, `deleteNode` finalized expired *node* deletes but not expired
  *environment* deletes.
- **U2** Undo is the inverse of the delete for every observable link,
  including tabs. Before **SM-3**, it was not for tabs.
- **U3** A node in `deleted` is detached (`parent == null` or removed from
  `collections`) and is freed only by `finishDelete`.

## 9. Store writer

Code: [store.zig](../src/storage/store.zig).

The state is `pending` (one entry per path, in the order each path was first
requested; a later write to the same path replaces the bytes in place),
`tasks` (at most 8 exports), `busy`, `stopping`, and the last failure.

| From | Event | To |
|---|---|---|
| Idle | `write` / `writeOwned` / `delete` / `deleteTree` | Pending (coalesced by path) |
| Pending | the writer takes the first entry | Busy, performed outside the lock |
| Busy | the write finishes or fails | Pending / Idle. A failure sets `failure` and `failure_path` |
| any | `sync()` | waits until `pending`, `tasks` and `busy` are all empty |
| any | `close()` | `stopping`, the writer drains and joins, then `flushNow` |

The UI takes `failure` and `failure_path` once per frame. `saveAndClose`
checks `lastFailureIs(path)` after `sync()`, before that frame-level
consumption.

## 10. Refresh from disk

Code: [persist.zig `refreshTrees`/`refreshTab`](../src/app/persist.zig:345).
Runs when the window is activated.

- A tree whose file changed is replaced by a fresh parse and the old one is
  freed. Before that, `selected`, `selection`, `rename_action` and the undo
  records (`finishDelete`) are cleared. The refresh is skipped while a modal
  or the tree menu is open, because those hold node pointers.
- A linked tab reloads its file only when it is clean. When it is dirty, a
  toast warns and the tab is kept.

## 11. Import preview

`preview: ?*ImportPreview` plus `modal == .import_preview`. `previewText`
creates a preview and replaces any old one. `accept` writes and frees it.
Cancel leaves it allocated until the next preview or exit (bounded, one at a
time). `target` is an index into `collections`, which cannot change while the
modal is open.

## 12. Request history and its menus

Code: [history.zig](../src/core/history.zig),
[sidebar.zig `history`](../src/ui/sidebar.zig:436).

Entries are appended newest last. `trim` drops the oldest once there are more
than `retention`, which shifts every index by one. Every entry gets an `id`
from `next_id` when it is added. Ids are not saved, and they stay with their
entry when indexes shift.

| From | Event | To |
|---|---|---|
| N entries | a request finishes (`finished`) | N+1, or N with every index shifted when at `retention` |
| any | `deleteHistory(index)` / `clearHistory` (after a confirm) | |
| row menu open for entry E | a request finishes and trims | the menu stays open **for E** (its id scope is `historyRowKey(E)`) |

Invariant:

- **H1** A history row's id scope, and with it its context menu, is keyed by
  the entry's `id`, never its index. Before **SM-4**, the menu was keyed by
  index and moved to the next entry when the history was trimmed.

## 13. Upload metadata cache

Code: [upload_info.zig](../src/app/upload_info.zig). Each of 16 slots is
empty, or a job for a path that is `checking` (`!done`) or done (`ready`,
`missing`, `denied`, `not_file`, `invalid`, `unavailable`). A lookup reuses
the slot for its path, or evicts the least recently used slot (a running job
keeps its own reference). `invalidate(path)` empties the slot after a send
that streamed the file. At most 4 checks run at once. Beyond that, a lookup
returns `checking` and a completion wake retries it. No violation found.

## 14. Connection pool

Code: [transport.zig `Client`](../src/network/transport.zig:125). Each
connection is in one of three states: in use by an exchange, idle in `idle`
(under `lock`, expired after `idle_lifetime_ms`), or destroyed. A pooled
connection that turns out stale before any response is retried once on a new
connection.

## 15. Pointer gestures

- Sidebar drag ([sidebar.zig](../src/ui/sidebar.zig:255)): module-level
  `press: ?{node}`, `dragging`, `drag_cancelled`. The states are Idle,
  Pressed, Dragging and Cancelled (Escape), and every one goes back to Idle
  on release. A drop is applied after the tree syncs its open and closed
  state. Dragging is disabled while there is a filter, a modal, the palette,
  a menu or a rename.
- Body editor ([code_state.zig](../src/ui/code_state.zig:97)):
  `move_drag: none → pending → moving → none`, with `cancelled` on Escape or a
  fold click. `column: none → pending → dragging → none` for Alt-drag column
  selection.

---

## Findings

Each confirmed bug below was reached by real code paths. Each regression
test fails if its fix is reverted: all six were checked by reintroducing the
bugs together and running the suite.

| # | Impact | Summary | Status |
|---|---|---|---|
| SM-1 | **High** | Save as from a background tab's close prompt saved the tab in front instead | Fixed |
| SM-2 | **High** | Reopening a closed tab could give one saved request two editors | Fixed |
| SM-4 | **Medium** | The history menu acted on a different entry after a retention trim | Fixed |
| SM-3 | Medium | Undo of a delete left the restored requests' tabs unlinked | Fixed |
| SM-5 | Low–Medium | Undo of a node delete brought back an expired environment delete | Fixed |
| SM-6 | Low | A transfer that finished as the timeout passed was reported "Timed out" | Fixed |
| SM-7 | Low | Closing a tab left `has_draft` set after its draft was deleted | Fixed |

### SM-1: Save as from a background close prompt saved the wrong tab (High)

- **Path.** The tab strip's X closes the tab it is on, and the tab menu's
  Close or Close all closes the right-clicked tab. Neither has to be the tab
  in front ([workspace.zig:170, 313, 329](../src/ui/workspace.zig:170)). For
  an unsaved draft, `requestClose` → confirm → **Save as...** →
  `saveAndClose(T)` → `beginSaveAs(T)` filled the name from T. But the
  dialog's accept ran `tree.saveTabAs(app, app.current(), …)`.
- **Invalid state.** The tab in front was renamed to T's name, saved as a new
  request, and **relinked to that copy**, so its later edits went to the copy
  and not to its original request. T stayed open and unsaved, and a "Saved"
  toast was shown. `close_after_save == T` never matched and was cleared on
  the next frame.
- **Fix.** `beginSaveAs` records `app.save_tab = T.uid`. The new
  `commands.acceptSaveAs` saves that tab, or does nothing if it is gone. The
  dialog calls it, and the workflow test now calls it too instead of copying
  the logic.
- **Test.** `state_machine_tests.zig` `saveAsFromBackgroundClose`.

### SM-2: Reopening a closed tab duplicated a saved request's editor (High)

- **Path.** Open request R, close its tab (it goes to `closed_tabs`), open R
  again from the sidebar (`openRequest` searches only open tabs, so it makes
  a new tab), then press Ctrl+Shift+T or use the Recently closed menu or the
  toast's Reopen. `reopenClosed` appended the old tab unconditionally.
- **Invalid state.** Two open tabs with the same `link` (breaks **T1**). Both
  write R's file on flush, and the last writer wins, so edits are lost.
  `tabOf` finds only the first tab, so rename, move and delete update only
  that one. After a delete, the other tab keeps a link to a deleted request,
  and `writeLinked` writes the file back.
- **Fix.** `reopenClosed` activates the open tab that already links the
  request and destroys the stale closed copy. This check runs before the
  64-tab limit, because activating needs no room.
- **Test.** `reopenKeepsOneTabPerRequest`.

### SM-4: The history menu acted on a different entry after a retention trim (Medium)

- **Path.** History holds `retention` entries (1000 by default). Right-click
  entry E at index i. While the menu is open, a request in another tab
  finishes: `history.add` → `trim` drops entry 0. The row and its context
  menu were scoped by `cui_push_id_int(index)`, so the open popup (id
  `"history-menu" ^ 0xC7C` in scope i) was now drawn for the entry *after*
  E.
- **Invalid state.** Delete entry removed the wrong entry. **Send again sent
  a different request**, which can be a side effect on a real server (for
  example a DELETE). Save to collection saved the wrong one.
- **Fix.** Every entry gets a stable `id` when it is added, and rows and
  menus are scoped by `historyRowKey(entry)`.
- **Tests.** `history.zig` "ids follow entries when retention shifts their
  indexes", and `historyMenuFollowsItsEntry`, which drives real right-clicks
  and clicks through CUI frames. With index keys, the test deletes "c"
  instead of "b".

### SM-3: Undo of a delete left tabs unlinked (Medium)

- **Path.** Delete a request (or its folder or collection) while it is open
  in a tab, or while it is recently closed. `closeTabsOf` sets `t.link =
  null`. Then press Undo.
- **Invalid state.** The request is back in the tree, but its tab shows
  "Unsaved requests" (breaks **U2** and **D3**). Clicking the restored row
  opens a *second* tab, because no open tab links the request. Ctrl+S on the
  first tab opens Save as and makes a duplicate. Reopened closed tabs come
  back unlinked.
- **Fix.** `closeTabsOf` records `{uid, link}` in `app.unlinked`.
  `undoDelete` → `relinkTabs` gives the link back to each open or closed tab
  that is still unlinked, and touches open ones so their dirty state is
  computed again against the file. `finishDelete` clears the records.
- **Test.** `undoRelinksTabs`.

### SM-5: An expired environment delete came back with a later Undo (Low–Medium)

- **Path.** Delete an environment. The 8 s window passes while no frame runs:
  frames come only from events, for example when the window is in the
  background. The next input deletes a sidebar node. In that frame, the
  sidebar runs before `deletionToast`, which is what would have finalized
  the environment. `deleteNode` finalized only `if (deleted.len > 0 and
  expired)`, so the expired `deleted_envs` survived into the new window.
  Undo then restored both, and `saveEnv` wrote the deleted environment back
  to disk.
- **Fix.** `deleteNode` finalizes on expiry whatever is pending, as
  `deleteEnv` already did.
- **Test.** `expiredEnvironmentStaysDeleted`.

### SM-6: A transfer that completed at the deadline was labelled "Timed out" (Low)

- **Path.** In `supervise`, `wake.waitTimeout` returns `Timeout` just as the
  transfer finishes. `task.cancel` on the finished task returns its result,
  with `failure == .none`. `finish` checked `timed_out` first.
- **Invalid state.** A complete body with `stop = timed_out` and a "No
  complete answer within … ms" error. It showed as Partial and was logged as
  a warning. Cancel already had the `failure != .none` guard; the timeout
  did not.
- **Fix.** The timeout row requires `result.failure != .none` (**J3**).
- **Tests.** `http_client.zig` "a transfer that completed as the deadline
  passed is complete, not timed out" and "a transfer the deadline cut short
  is timed out".

### SM-7: `has_draft` was left set after closing deleted the draft (Low)

- **Path.** `closeNow` deleted the draft file but kept `has_draft = true`
  (breaks **D1**). A reopened clean tab then listed a draft id that does not
  exist in `workspace.json`. Restoring it fell back without harm, so this
  affected bookkeeping, not data.
- **Fix.** `closeNow` clears the flag. A reopened tab writes a new draft when
  it flushes.
- **Test.** The second half of `reopenKeepsOneTabPerRequest`.

## Issues

The fixes are grouped by the invariant they restore:

1. **The close prompt saves the right tab (M1).** SM-1. Files:
   `commands.zig` (`beginSaveAs`, `acceptSaveAs`, `tabByUid`), `dialogs.zig`,
   `state.zig` (`save_tab`).
2. **One editor per saved request, and the draft flag follows its file (T1,
   D1).** SM-2 and SM-7. File: `commands.zig` (`reopenClosed`, `closeNow`).
3. **The Undo window is an exact inverse and does not outlive its deadline
   (U1, U2, D3).** SM-3 and SM-5. Files: `tree_ops.zig` (`deleteNode`,
   `closeTabsOf`, `relinkTabs`, `finishDelete`), `state.zig` (`unlinked`).
4. **State that lasts across frames is keyed by stable identity, not index
   (H1, T4).** SM-4. Files: `history.zig` (`id`, `indexOf`), `sidebar.zig`
   (`historyRowKey`).
5. **Outcome classification wins over deadline races (J3).** SM-6. File:
   `http_client.zig` (`finish`).

The regression tests are in `src/state_machine_tests.zig`, which runs in the
headless `--self-test` suite under `zig build test`, plus unit tests in
`history.zig` and `http_client.zig`.

## Risks noted but not confirmed

These are recorded so that later changes keep them in mind. None of them was
shown to be reachable through normal use, so none was fixed here.

- **The sidebar's `press` holds a raw `*Node` while the mouse is down.** If
  the node were freed during the press (`finishDelete` from an expiring
  window, or `refreshTrees`), the release would dereference it. That needs a
  delete during a held press, or a window activation in the middle of a
  press. Neither was found reachable.
- **Store coalescing reorders writes to different paths.** A crash between a
  tree file write and a request file write can leave a tree that lists a
  request whose file does not exist. The loader reports it as
  `RequestMissing` and leaves it, so nothing is lost silently.
- **External edits that remove a request.** `refreshTrees` replaces the tree,
  but an open tab still links the removed request, and its next save writes
  the file back without a tree entry. This needs an edit by another program.
- **Duplicate entries in `workspace.json`.** `restoreTabs` does not remove a
  request listed twice, so a hand-edited file could break T1 at startup.
- **Toast Retry/Open activate a tab without `prefsChanged`.** The active tab
  is saved with the next change instead of right away. Cosmetic.
- **Dead state.** `Pending.delete_history`, `history_menu_open`,
  `history_menu_at` and `history_menu_row` are never set.
