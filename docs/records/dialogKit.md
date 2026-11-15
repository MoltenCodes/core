# dialogKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## dialogKit

**dialogKit** — facade `DialogKit`

1. Package `dialogKit`, facade `DialogKit`, API generation 1.
2. Purpose: confirmation and input dialogs without `StaticPopupDialogs`.
   An addon that adds entries to Blizzard's `StaticPopupDialogs` table and
   calls `StaticPopup_Show` runs its code inside Blizzard's popup system and
   can taint it; DialogKit draws its own dialog on one frame of its own, with
   the client's button and input-box templates: a text, one or two buttons,
   an optional input line, an optional timeout. One dialog is shown at a
   time; the others wait in a bounded queue. Escape closes it through
   `UISpecialFrames`, the client's list of frames Escape hides, which every
   promised client has (checked in Blizzard's source, branches `live`,
   `classic`, `classic_era`, 2026-11-15). Non-goals: changing Blizzard's
   own popups, arbitrary widgets in a dialog (WidgetKit), several dialogs
   on screen at once.
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `UIParent`, `GetTime` (timeouts); `UISpecialFrames` (Escape) when present.
4. Surface: `DialogKit:Show(options)` → dialog, with `text`,
   `accept` (default `"OK"`), `cancel` (default `"Cancel"`, `false` for one
   button), `onAccept(data, inputText)`, `onCancel(data, reason)`, `data`,
   `input` and `inputText`, `maxLetters`, `timeout`, `key` (a dialog shown or
   waiting under the same key is returned instead of a second one),
   `allowSecret`; `dialog:Hide()`, `IsShown()`, `IsQueued()`, `GetInput()`;
   `DialogKit:HideAll()`; `SetLimits{ maxQueued }` / `GetLimits()`.
5. Ownership: a dialog lives from `Show` until it is accepted, cancelled
   (its button, Escape, the timeout, `Hide`, `HideAll`) or, while waiting,
   removed; the callback that ends it runs once, protected. The frame is the
   package's, created once and kept for the session.
6. Performance and memory: one frame for every dialog; nothing runs per
   frame except a shown dialog with a timeout. `maxQueued` defaults to 16
   and opens to `UNBOUNDED` (a waiting dialog is a Lua table).
7. Tests: the frame's texts, buttons and input line; accept, cancel, Escape
   (hiding the frame), timeout, `Hide` and `HideAll` each calling the right
   callback once with its reason; the queue's order, its limit and
   `UNBOUNDED`; keys; Enter and Escape in the input line; callbacks that
   raise reported; secret texts; upgrade; manifest; error levels. A client
   suite on Retail: a dialog shown and accepted, one closed with Escape
   through `UISpecialFrames`, and a queued one shown after it.
8. Docs: README (with the migration from `StaticPopup_Show`), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 26 specs; the client suite (`tests/client/MoltenCodesTest_DialogKit`)
   is written and has not been run in a client.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 32 specs
   (a parent's hide no longer cancels the dialog; secret button texts
   refused without naming allowSecret, a secret `cancel` before it is
   compared; a secret `text` drawn unconverted).

