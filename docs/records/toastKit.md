# toastKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## toastKit

**toastKit** — facade `ToastKit`

1. Package `toastKit`, facade `ToastKit`, API generation 1.
2. Purpose: short notifications that appear, stay a few seconds and fade:
   "profile copied", "a new version is out", a loot or achievement-style
   note from an addon. A toast has a title, an optional text and icon, and
   an optional click handler; toasts stack at one anchor on the screen,
   growing down or up, at most a few at a time, the rest waiting in a
   bounded queue. The cursor resting on a toast holds it. Toasts are frames
   of the package's own, from a PoolKit pool. Non-goals: Blizzard's alert
   system (`AlertFrame`, whose queue and taint rules belong to Blizzard),
   chat messages, sounds.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent`; `GetTime` is not needed (a
   toast counts its own `OnUpdate` time).
4. Surface: `ToastKit:Show(options)` → toast, with `title`, `text`,
   `icon`, `duration` (default 5 seconds), `onClick(data)`, `data`, `key`
   (a toast shown or waiting under the same key is updated and starts
   again), `allowSecret`; `toast:Dismiss()`, `IsShown()`, `IsQueued()`;
   `ToastKit:DismissAll()`; `ToastKit:SetAnchor(point, x, y, direction)`;
   `SetLimits{ maxVisible, maxQueued }` / `GetLimits()`.
5. Ownership: a toast lives from `Show` until it fades out, is clicked or
   dismissed; its frame then goes back to the pool cleared.
6. Performance and memory: each shown toast runs one `OnUpdate` that
   counts its time and, in its last half second, its fade; nothing runs
   once it is gone. `maxVisible` defaults to 5 with a ceiling of 20 (the
   frames are kept for the session); `maxQueued` defaults to 32 and opens
   to `UNBOUNDED` (a waiting toast is a Lua table).
7. Tests: texts, icon, anchor and stacking both ways, the life and the
   fade, holding under the cursor, clicks (one that raises reported),
   `Dismiss`, `DismissAll`, keys updating and restarting, the queue and its
   limit, pooling, secret texts, upgrade, manifest, error levels. A client
   suite on Retail: toasts shown, stacked, faded on the client's frames and
   their frames reused.
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 23 specs; the client suite (`tests/client/MoltenCodesTest_ToastKit`) is
   written and has not been run in a client.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, documentation only.

