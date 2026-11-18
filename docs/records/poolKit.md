# poolKit records

**Minimal core (2026-11-16)**

Status: implemented 2026-11-18, 0.5.0, revision 12, 157 specs (see item 9).

Measured on host Lua 5.1.5 (64-bit), debug information kept as the client keeps
it, on the shared fake client, string table pre-grown (the method of the
2026-11-15 memory diagnosis). "Measured" means a research copy with the change
applied was loaded and executed; "priced" means summed from measured prototype
sizes.

**Diagnosis**

**Counterpart**

Ace3 has no pool library (AceGUI keeps a private widget pool inside AceGUI-3.0).
The reference for "what every user needs" is therefore usage: the Kits in this
repository, and the client's own object pool, which the client loads anyway
(`Interface/AddOns/Blizzard_SharedXMLBase/Pools.lua`, branch `live` of
Gethe/wow-ui-source, read 2026-11-16): `Acquire`, `Release`, `ReleaseAll`,
`EnumerateActive`, `IsActive`, `GetNumActive`, a creation function, a reset
function and an optional capacity. It is not measured here: it costs an addon
nothing, and it does not run outside the client.

**What PoolKit holds today (0.4.9, revision 11)**

| | PoolKit |
|---|---:|
| Resident after load, debug kept | 81,639 B |
| Resident, `luac -s` | 56,239 B |
| Live prototype arrays | 56,736 B |
| Transient while loading (per embedding addon) | 220,903 B |
| Constant strings in live code | 8,544 B (52 prose strings, 3,639 B) |
| Source lines: code / comments / LuaCATS / blank | 1,372 / 174 / 531 / 223 |
| Empty pool (`New` with create, reset, `UNBOUNDED`, `maxCreated`) | 1,764 B |
| Empty table pool (`NewTablePool`) | 1,724 B |
| Bookkeeping per borrowed object | about 72 B (136 B with a 64 B table object) |

Live prototypes by section: Pool methods 16,384 B, Capacity and waiting 6,616 B,
Internal lifecycle 6,200 B, Validation 5,360 B, Package constructors 4,064 B,
Children 2,944 B, Option parsing 2,864 B, Deferred release 2,776 B, Release
transaction 2,528 B, Release helpers 2,320 B, Construction 2,008 B, Generations
1,656 B. Largest functions: `poolAcquire` 2,040 B, `newPool` 2,008 B,
`packageNew` 1,904 B, `parseCommonOptions` 1,832 B, `releaseActive` 1,672 B,
`poolAttachChild` 1,408 B, `upgradePool` 1,336 B, `poolReleaseAfter` 1,280 B.
Only the surface and state validators run at load alone and are freed
(14,856 B). An empty pool fills 32 fields, most `false` or `0`, which sizes a
32-slot hash part, and it creates a weak metatable of its own for its
`_released` set.

**Classification**

Usage read from every `src/` file: BarKit, GlowKit, ToastKit and TooltipKit
call `PoolKit:New({ create, reset, maxRetained = PoolKit.UNBOUNDED, maxCreated })`,
`Acquire` and `Release`; TooltipKit also `GetMaxCreated` and `SetMaxCreated`.
CodecKit and CommKit call `NewTablePool({ maxRetained })`, `Acquire`,
`Release`. WidgetKit (optional dependency) reads `GetAvailableCount`,
`GetCreatedCount`, `GetDiscardedCount`, `GetMaxCreated` and `Acquire` when it
takes over a pool an older WidgetKit made. Nothing calls `maxActive`,
`maxWaiting`, `Acquire(onAvailable)`, `CancelWaiting`, `AttachChild`,
`DetachChild`, `ReleaseAfter`, `generation` or `SetGeneration`.

| Class | Members | Live prototypes |
|---|---|---:|
| Every user: the plain pool (what the client's pool offers, plus the documented bounds and diagnostics) | `New`, `NewTablePool`, `Acquire`, `Release`, `Prewarm`, `Trim`, `Clear`, `Close`, `IsClosed`, the counts, `Get`/`SetMaxRetained`, `Get`/`SetMaxCreated`, `Owns`, `IsActive`, `maxActiveWarning`, strict history, the re-entrancy guard | 35,344 B |
| Every user, cold: the lazy upgrade of pools revisions 1 to 3 built | `upgradePool` | 1,336 B |
| Some users: live limit and waiting queue | `maxActive`, `maxWaiting`, `Acquire(onAvailable)`, `CancelWaiting`, `GetWaitingCount` | 4,856 B |
| Some users: cascading release | `AttachChild`, `DetachChild`, the link tables | 6,216 B |
| Some users: deferred release | `ReleaseAfter`, `GetParkedCount`, parking | 6,064 B |
| Some users: generations | `generation`, `GetGeneration`, `SetGeneration`, stale trimming | 2,920 B |

Inside the plain pool, seven getters (`GetAvailableCount`, `GetActiveCount`,
`GetCreatedCount`, `GetDiscardedCount`, `GetMaxRetained`, `GetMaxCreated`,
`IsClosed`) are seven copies of one shape, 296 to 344 B each; constructor-time
option parsing (`packageNew`, `parseCommonOptions`, `parseCapacityOptions`,
`validateKnownFields` and the validators) is about 7.6 KB.

Duplicated helpers (`tooling.shared.sync --list`): `PoolKit.lua:369 isSecret`
(named `isSecretValue`; it never asks for a probe installed after load) and
`:569 describeKey`. Priced: `isSecret` +176 B, `describeKey` +80 B. The gain is
one body under the gate. `reportWarning` stays PoolKit's own: it is silent
without a host error handler, where the shared `reportError` prints.

**poolKit: plain-pool core, Waiting, Children, Deferred and Generations parts** — a change to facade `PoolKit`

1. Package `poolKit`, facade `PoolKit`, API generation 1 (unchanged, the facade
   gains `HasPart`), version 0.5.0 (from 0.4.9), implementation revision 12
   (from 11). Minor. New parts, revision 1 each, along the existing sections:
   `Waiting` (`src/parts/PoolKit-Waiting.lua`), `Children`
   (`src/parts/PoolKit-Children.lua`), `Deferred`
   (`src/parts/PoolKit-Deferred.lua`), `Generations`
   (`src/parts/PoolKit-Generations.lua`).
2. Purpose: the core holds the plain pool every user in the repository uses;
   the four optional mechanisms are parts.
   - **P1 Parts.** The core's release transaction keeps one test per
     mechanism (`_children`, `_attachedTo`, a parked status, `_waiting`,
     a generation differing from the base) and calls the part's hook through
     `_state.parts`; a pool can only reach those states through its part. The
     constructor refuses `maxActive`, `maxWaiting` and `generation` without
     their part, at the caller. `Acquire(onAvailable)` stays core: without the
     Waiting part a pool has no queue (`maxWaiting` is `0`), and at capacity it
     answers `nil, "queueFull"` exactly as today.
   - **P2 Getters from one shape**: one function builds the seven getters
     (validate the receiver at the caller's level, return one field).
   - **P3 Cold legacy upgrade**: `upgradePool` is created only when the shared
     state was schema `1` at load (revisions 1 to 3 loaded in the session),
     recorded as `_state.legacyPools = true` (sticky); otherwise the receiver
     check's schema test never fails and the code is freed after load.
   - **P4 Table-driven option parsing**: one rule table for every constructor
     option (kind, default, which constructors accept it, which part owns it)
     and one walker, in place of the per-option code; every message keeps its
     text.
   - **P5 Sparse pools**: a new pool carries only the core's fields (at most
     16, one 16-slot hash part); part fields appear when a part first uses
     them; the weak metatable of `_released` is one shared table in state.
     The hot paths test the part fields by truthiness (`self._waiting`), which
     reads revision 11's full pools (`false`) and sparse pools (`nil`) alike, so
     no pool needs converting.
   - **P6 Shared helper blocks**: `isSecret` (call sites renamed from
     `isSecretValue`; the probe rule now honours a probe installed after load)
     and `describeKey`; `validateFacade` added on `New` and `NewTablePool`,
     whose receiver is unchecked today, which also lets PoolKit take the
     conformance suite's `receivers` group.
   - **P7 Parts plumbing** as in the other split Kits: `PoolKit:HasPart(name)`,
     `_state.parts`, `_state.helpers`, `_state.partInterface = 1`, and a
     commit that reinstalls installed parts' methods.
   Owner decision recorded here: **getters of an absent part answer the
   neutral value** (`GetWaitingCount` and `GetParkedCount` `0`,
   `GetGeneration` `1`) instead of raising, which is exact (no pool can be in
   another state without the part) and keeps read-only diagnostics working;
   mutators of an absent part (`CancelWaiting`, `AttachChild`, `DetachChild`,
   `ReleaseAfter`, `SetGeneration`) raise at the caller with the file to add.
   Non-goals: dropping `strict`, `prewarm`, `maxActiveWarning` or the
   re-entrancy guard from the core; any change to the release order or the
   errors.
3. Dependencies: unchanged (registry API 2). Parts depend on nothing else.
   WidgetKit's optional dependency needs only the core.
4. Surface: unchanged names; every member stays on `PoolKit.Pool` (older
   copies' `validatePublicSurface` tests all 25). Without its part, a mutator
   raises at the caller's line:
   `PoolKit.Pool:AttachChild is in PoolKit's Children part, which is not loaded: add poolKit\parts\PoolKit-Children.lua to embeds.xml after poolKit\PoolKit.lua`,
   and a constructor option raises the same way naming `PoolKit:New maxActive`.
   New: `PoolKit:HasPart(name)`. `PoolKit.New(options)` with a dot now raises
   the facade-receiver message rather than "options must be a table".
5. Ownership: unchanged. In-place upgrade from revision 11: the state gains
   `parts`, `helpers`, `partInterface` and the shared weak metatable; pools
   revision 11 built keep their full layout and are read as they are. Pools
   cannot be enumerated, so a pool that already uses a part's mechanism (a
   queue, a parked object, children, a raised generation) in a session
   without that part is found when a core method touches that state: it is
   reported once through `geterrorhandler()` naming the part, and the core
   then takes the safe exact path (it releases a parked object at once,
   detaches children without cascading, retains no stale object, fails the
   waiting requests with `"closed"`). With the part loaded, everything is
   adopted as is. No revision was ever published.
6. Performance and memory (resident, debug kept):

   | Change | Resident | Basis |
   |---|---:|---|
   | today | 81,639 B | measured |
   | P1 (functions removed, stubs added, release branches kept) | 58,736 B (-28%) | measured (research copy) |
   | P1 + P2 + P3 | 56,362 B (-31%) | measured (research copy) |
   | P4 | about -3,000 B | priced (about 7.6 KB of parsing code to about 4 KB) |
   | P5, P6, P7 | about +500 B | priced |
   | core target | at most 54,000 B | |
   | Waiting part | about 9,000 B | priced (4,856 B of prototypes plus hooks and header) |
   | Children part | about 10,000 B | priced |
   | Deferred part | about 10,000 B | priced |
   | Generations part | about 5,500 B | priced |
   | empty pool | 1,764 to about 1,100 B | priced (16-slot hash part, shared weak metatable) |

   Transient per embedding addon: 220,903 to about 155,000 B (measured for the
   research copy). Acquire and release fast paths keep their order of checks;
   the bench case `pool` in phase 2. What stays in the core above a bare pool
   buys the documented guarantees: bounded retention, the creation cap for
   objects the host cannot free, errors at the caller's line, duplicate-release
   diagnostics, and refusal of mutation from inside a pool's own callbacks.
7. Tests: the specs of each mechanism run with its part loaded and pass
   unchanged; without each part, each mutator and constructor option raises
   at the caller with the file to add and the getters answer the neutral
   value; `Acquire(onAvailable)` without the Waiting part answers
   `"queueFull"` at capacity; either load order; a part without its core
   raises the ADR 0001 message; in-place upgrade from revision 11 (byte copy
   of the current file as the fixture) with a pool holding a waiting request,
   a parked object, an attached child and a raised generation: with the parts
   everything keeps working; without them each is reported once and takes the
   exact path above; P3 with schema `1` state; P5 with a revision 11 full pool
   and a sparse pool side by side; every option message unchanged after P4.
   Conformance: opt in with `manifest`, `receivers` (after P6), `arguments`
   and `upgrade`; `limits` does not apply (no package-wide limits, no
   `SetLimits`). Client suite (`tests/client/MoltenCodesTest_PoolKit/`, never
   run): the `.toc` loads the parts; one stub error with the core alone.
8. Docs: README (parts, embedding), `docs/API.md` ("Generations", "Objects the
   host can never free" for `maxActive` and the queue, "Cascading release",
   "Deferred release" each name their part; the "Limits" table marks
   `maxActive` and `maxWaiting` as the Waiting part's; `HasPart`; the section
   skeleton `docs/CONTRIBUTING.md` defines), `CHANGELOG.md` 0.5.0,
   `tests/README.md`, `src/.luarc.json`, the file header ("Every pool also
   carries a generation" becomes the Generations part's sentence). Shared files (kept by their owner): `docs/EMBEDDING.md` footprint and load order,
   `packages/README.md`.
9. Status: implemented 2026-11-18, 0.5.0, revision 12, 157 specs. Measured
   with the diagnosis harness (host Lua 5.1.5, debug kept, fake client, string
   table pre-grown, Registry revision 17 loaded first): core resident
   82,413 B → 62,240 B (-24%), transient while loading 221,616 B →
   189,184 B; parts when loaded: `Waiting` 7,441 B, `Children` 8,835 B,
   `Deferred` 8,920 B, `Generations` 4,284 B. The 54,000 B core target is
   **not reached**, by about 8 KB: P4's rule list was first written as one
   table per option and measured larger than the code it replaced, so it is
   one array of rule strings read only while a constructor runs; the part
   plumbing (`_state.helpers`, the per-mechanism lookup, five stubs, `HasPart`)
   and the shared blocks add what the research copy priced at +500 B but
   measures at about 2 KB; and the hot paths (`Acquire`, `Release`,
   `releaseActive`, construction) stay as they were. Empty pool: twelve fields
   plus the options given. Choices where the record left one open:
   - At most 16 fields holds for every option combination the repository's
     Kits use; a pool given all five optional settings (`reset`, `destroy`,
     `maxCreated`, `maxActiveWarning` and the default `strict`) carries 17.
     `_callbackPhase` stays present (as `false`) so that a reset callback
     never adds a key, which would grow the hash part on every such pool.
   - The pool fallbacks of item 5 (`_state.fullPools`, sticky, set when
     revision 11 or older loaded) are built only in such a session, like
     `upgradePool` under `_state.legacyPools`; the report is once per part
     per session. Without the `Waiting` part, a revision 11 pool's new
     `Acquire(onAvailable)` at capacity answers `"queueFull"`.
   - A part's getter stays a core method answering the neutral value; only
     the five mutators are stubs.
   - The layout constants (`ACTIVE`, `PARKED`, `"closed"`) are each part's
     own, not helpers: they are values of the pool layout every revision
     shares.
   Specs adjusted: `SecretValues_spec.lua` loads the parts after the core (two
   of its cases use `generation` and `SetGeneration`); the test environment's
   `ReloadPackage` reloads the core and then its parts, and `LoadRevision` up
   to 11 loads the revision 11 file. Client suite: `HasPart` for the four
   parts; a stub error cannot be seen there, because the installed bundle
   carries every part. Other owners: WidgetKit's revision 13 fixture
   (`tests/support/WidgetKitRevision13.lua`) builds pools with `generation`,
   so `Revision13_spec.lua`'s environment must load `PoolKit-Generations`
   after `PoolKit` (3 specs fail without it).
