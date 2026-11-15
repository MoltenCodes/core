# registry records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## registry cheaper lookups

**registry cheaper lookups** — an internal change to facade `Registry`

1. Package `registry`, facade `Registry`, API generation 2 (unchanged),
   version 0.6.11, implementation revision 16 (from 0.6.10, revision 15).
   Patch. The file stays within its 1000-line budget.
2. Purpose: bring `Get`, `Find` and `Register` lookups closer to LibStub's,
   following the runtime performance diagnosis of 2026-11-15 (registry).
   - The secret-probe rule: `issecretvalue` resolved once at load, looked
     up per call only when it was absent at load, in `isSecret`
     (`Registry.lua:74`) and `lookUp` (`:250`).
   - Owner decision needed: plain indexing on the hit path. `lookUp` reads
     the package bucket, the entry and its two fields with `rawget` and
     checks each with `type`. Indexing them plainly is where the gain is
     (item 6), but `docs/API.md` ("Lookup cost") promises that a hit "reads
     the state with raw access". Plain indexing keeps every shape check
     (the corruption checks stay, and `Corruption_spec` and `FastPath_spec`
     pass). It drops that promise, though: a metatable that foreign code
     puts on the shared state could then answer a missing bucket or field.
     No form of plain indexing keeps the promise for less: a `getmetatable`
     test on the three tables costs what the `rawget`s cost. Unless the
     owner drops the sentence, the hit keeps raw reads and takes only the
     probe rule.
   - Decision 19b: none applies. The secret checks in Registry guard
     arguments before they are compared or used as keys, so the error is
     raised at the caller's line; the client's own refusal would raise
     inside Registry. The sealed facade's `__newindex` (`:712`) asks about
     the key it describes. Whether the client refuses a secret key on
     assignment before `__newindex` runs has not been measured, so that
     check stays.
3. Dependencies: none (Registry is the root).
4. Surface: unchanged. With plain indexing, the "Lookup cost" paragraph
   loses "reads the state with raw access" on the hit. The bootstrap and
   facade checks keep raw access in either case.
5. Ownership: unchanged. The load-time probe is file-local to each
   embedded copy. An in-place upgrade from revision 15 keeps every entry.
6. Performance and memory, host bench `libraryRegistry` workload,
   MoltenCodes ÷ LibStub in the same run (two runs on 2026-11-15, the
   unmodified file against each variant):

   | Case | Before | Probe rule only | Probe rule and plain indexing |
   |---|---:|---:|---:|
   | lookup | 3.54× | 3.35-3.38× | 2.53-2.60× |
   | silent-miss | 5.00-5.05× | 4.84-4.97× | 4.02-4.09× |
   | stale-copy | 1.77-1.83× | 1.74× | 1.44-1.45× |
   | upgrade | 1.18-1.20× | 1.20× | 0.96-1.01× |
   | new-library | 1.91-2.12× | 1.93-2.08× | 1.56-1.81× |

   The target "Ace3/LibStub level" is not reached by either form: a hit
   still runs the probe and the shape check, and a miss runs the name
   pattern. No memory change. Registry lookups happen mostly at load. The
   hot-path cost is the call-time lookups other Kits make, which those
   Kits should resolve once.
7. Tests: the probe rule (present at load, installed after load); a hit
   with a malformed entry still raises the corruption error at the caller;
   a secret name or API still refused before use as a key. With plain
   indexing: the rewritten "Lookup cost" claim, and a spec that a bucket
   carrying a foreign metatable is refused, not read through. In-place
   upgrade from revision 15. Line budget: the file stays at or under 1000
   lines. Client suite (`tests/client/MoltenCodesTest_Registry/`, never run
   here): unchanged.
8. Docs: `docs/API.md` ("Lookup cost"), `CHANGELOG.md` 0.6.11,
   `tests/README.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.11,
   revision 16, plain indexing on the owner's decision (Registry's state
   carries no metatable; the docs/API.md "Lookup cost" sentence replaced), 2
   specs (143), 999 lines.

**Minimal core (2026-11-16)**

Status: recorded 2026-11-16; code follows.

Measured on host Lua 5.1.5 (64-bit), debug information kept as the client keeps
it, on the shared fake client, with the string table pre-grown (the method of
the 2026-11-15 memory diagnosis). "Measured" means a research copy with the
change applied was loaded and executed; "priced" means summed from the measured
prototype sizes of the functions involved.

**Diagnosis**

**What Registry holds today (0.6.11, revision 16)**

| | Registry | LibStub (Ace3 `5e2e0d3b`) | Ratio |
|---|---:|---:|---:|
| Resident after load, debug kept | 32,306 B | 2,623 B | 12.3x |
| Resident, `luac -s` | 20,148 B | about 2 KB | |
| Live prototype arrays | 22,296 B | 1,352 B | 16.5x |
| Transient while loading (per embedding addon) | 88,443 B | 8,081 B | 10.9x |
| Constant strings in live code | 3,203 B (20 prose strings, 1,420 B) | 585 B (3, 219 B) | |
| Source lines: code / comments / LuaCATS / blank | 590 / 125 / 216 / 69 (1,000) | | |
| One registration (`Register` of a new package) | 489 B | 220 B (`NewLibrary`) | 2.2x |

Live prototypes by section: Lookup 5,752 B, Retirement and migration 5,680 B,
Bootstrap 5,488 B, Validation 2,736 B, Bootstrap state 2,640 B. Largest
functions: `bootstrap` 5,032 B (with its two nested closures `refuse` and
`adopt`, created per call), `runMigrations` 1,680 B, `applySeal` 1,408 B,
`lookUp` 1,328 B, `packages` 1,096 B, `register` 1,000 B, `find` 984 B. Upgrade
code that runs only at load (the facade self-check, the namespace publication)
is in the main chunk and freed after load (6,408 B).

**Classification**

| Class | Members | Live prototypes |
|---|---|---:|
| Every user: every Kit calls `Bootstrap` at load, and `Get`/`Find` | `bootstrap`, `lookUp`, `get`, `find`, `register`, `registerEntry`, `selectRevision`, the entry accessors, the validators, `isSecret`/`readProbe`, `passes` | 14,136 B |
| Some users: hand-over policies | `runMigrations`, `selectMigrationSteps`, `retireOutgoing`, `reportFailure`, `applySeal` (with its `__newindex` closure), `onRetire`, `validateOptionalField` | 6,136 B |
| Some users: diagnostics | `getInfo`, `packages`, `packageRowBefore` | 2,024 B |

Usage in the repository, read from every `src/` file: every Kit's
`Registry:Bootstrap` request names `package`, `api`, `revision`, `label`,
`validatePublicSurface`, and most `validateState`; LifecycleKit and ModuleKit
pass `resume`. No Kit passes `retire`, `migrations` or `sealFacade`, and none
calls `OnRetire` or `GetInfo`. `Packages` has one caller, InteropKit
(`InteropKit.lua:489`). `Register` is the LibStub-style form documented for
authors ("Moving from LibStub") and stays.

Cold code that stays resident: the hand-over policies run only when a newer
revision replaces an older one, but an upgrade can happen whenever a later
addon (or a load-on-demand addon) loads, so as long as they are in the core
they must stay resident. Nothing else in Registry is cold.

Duplicated helpers: `isSecret` (with `readProbe`), `reportFailure` (the
`reportError` family) and the key naming inside `applySeal` (the `describeKey`
family). Registry has no `validateFacade` (its methods take `_` and never test
the receiver) and no limits, so two of the five helpers in its `pins.json`
opt-out name nothing that exists.

**The line budget**

The header's budget is 1,000 lines with comments included; the file is at 1,000.
Comments, LuaCATS declarations and blank lines are 410 of those lines and cost
nothing resident. The budget therefore binds documentation, and it is the stated
reason for the opt-out from every shared helper ("its 1000-line budget cannot
take the marker lines"), although the markers are comments. It also pushed the
LibStub bridge, the catalogue and the deprecation warnings into InteropKit,
AddonKit and ClientKit, which was the right outcome for those features.

Decision proposed: **the budget stays, restated as what it protects**: at most
600 code lines (lines that are neither blank nor comments) and at most 24 KB
resident with debug information kept, for `src/Registry.lua`. Comments are no
longer counted. A package-local spec counts the code lines, so the budget is a
gate rather than a header sentence; the resident figure is measured and
reported with each change, as the records do.

**The `pins.json` opt-out**

Decision proposed: **narrowed to `isSecret` only**, with a new reason:

> Registry's lookup fast path reads the load-time `issecretvalue` probe directly,
> once for both arguments; the shared block keeps the probe inside its `do`
> block, so converting would add two calls to every `Get` and `Find`.

`reportError` and `describeKey` leave the core with the hand-over part, which
takes the shared blocks. `validateFacade` and `limits` are removed from the
opt-out because Registry has neither.

**registry: minimal core, Handover and Diagnostics parts, restated budget** — a change to facade `Registry`

1. Package `registry`, facade `Registry`, API generation 2 (unchanged), version
   0.7.0 (from 0.6.11), implementation revision 17 (from 16). Minor. New parts
   (ADR 0001), revision 1 each: `Handover` (`src/parts/Registry-Handover.lua`)
   and `Diagnostics` (`src/parts/Registry-Diagnostics.lua`).
2. Purpose: Registry is loaded by every addon that embeds a Kit and resident once
   per session; it should hold what every Kit needs and nothing else.
   - **R1 Handover part.** `request.retire`, `request.migrations`,
     `request.sealFacade` and `Registry:OnRetire` move to the part, with
     `runMigrations`, `selectMigrationSteps`, `retireOutgoing`, the failure
     reporter and `applySeal`. The core keeps the type checks of the three
     request fields (so a malformed field still raises at the caller as
     today), the `status` and `migratedThrough` bookkeeping (cheap, and the part
     relies on it), and `resume` and `validateState`, which Kits use.
   - **R2 Diagnostics part.** `GetInfo` and `Packages` move to the part.
   - **R3 Small core trims.** `isPositiveInteger` and `isNonNegativeInteger`
     become one bounded-integer test with a minimum; the corruption message
     becomes one constant shared by the accessors.
   - **R4 Budget** restated as above, with a spec.
   - **R5 Parts plumbing.** The ADR 0001 contract: `_state.parts` (a new
     optional field of the global state; the state `schema` stays `1`,
     because every older copy refuses any other schema with "bootstrap state
     is incompatible"), `Registry:HasPart(name)`, and a commit that reinstalls
     an installed part's methods so either load order ends with the part
     serving.
   Non-goals: any change to `Register`, `Get`, `Find` or `Bootstrap` semantics
   for requests that do not use the moved fields; the lookup fast path.
3. Dependencies: none (Registry is the root). Each part loads after
   `Registry.lua` and finds the core through `MoltenCodes.Registries[2]` and the
   shared state key; with no core it raises
   `MoltenCodes Registry part <Part> requires Registry API 2 to be loaded first`.
   InteropKit's manifest names `"registry": { "api": 2, "parts": ["Diagnostics"] }`
   (InteropKit's own change; text in the report).
4. Surface: unchanged names. `OnRetire`, `GetInfo` and `Packages` stay on the
   facade, so every older copy's facade self-check (which tests all seven
   methods with `type(...) == "function"`) still accepts it. Without its part
   each raises at the caller's line:
   `Registry:Packages is in Registry's Diagnostics part, which is not loaded: add registry\parts\Registry-Diagnostics.lua to embeds.xml after registry\Registry.lua`.
   A `Bootstrap` request that names `retire`, `migrations` or `sealFacade`
   without the Handover part raises at the package file's `Bootstrap` call with
   the same form naming `request.<field>`. New: `Registry:HasPart(name)`.
   Embedding: authors who use none of these embed `Registry.lua` alone, as
   today; the generated `embeds.xml` adds a part when a manifest names it.
5. Ownership: unchanged. Part state lives under `_state.parts.<Part>` with its
   `PART_REVISION`; the highest wins. In-place upgrade from revision 16: the
   core takes over the facade as today and installs the stubs; the parts, when
   loaded, install the real methods. An entry revision 16 left with a
   `retire` hook, an unfinished `migrating` run or a `seal`, in a session
   without the Handover part, is reported once through `geterrorhandler()`
   naming the part and left untouched (no Kit in the repository creates any of
   them, and no revision was ever published). A revision 16 copy loaded after
   revision 17 yields as an older copy does today.
6. Performance and memory (resident, debug kept):

   | Change | Registry resident | Basis |
   |---|---:|---|
   | today | 32,306 B | measured |
   | R1 + R2 (+ stubs, `HasPart`) | 22,980 B (-9,326 B, -29%) | measured (research copy) |
   | R3 | about -400 B | priced |
   | target | at most 23,000 B (LibStub 2,623 B) | |
   | Handover part, when loaded | about 10 KB | priced (6,136 B of prototypes plus its header) |
   | Diagnostics part, when loaded | about 4 KB | priced |

   Transient per embedding addon: 88,443 to 64,460 B (measured). Smallest set
   (Registry, SignalKit, EventKit, LifecycleKit, TimerKit) together with the
   SignalKit record: 341,282 to 279,799 B measured (LibStub, CallbackHandler,
   AceAddon, AceEvent, AceTimer: 54,010 B). Lookup bench cases unchanged (the
   fast path is not touched). What stays above LibStub buys the documented
   guarantees: the Bootstrap reconciliation every Kit would otherwise carry
   itself, shape-checked lookups, and errors at the caller's line.
7. Tests: without the parts, each moved member and each moved request field
   raises at the caller with the file to add, and `HasPart` answers `false`;
   with the parts, the existing Retirement, Seal, Metadata and Registry specs
   pass unchanged (the test environment loads the parts); either load order of
   core and part, and a later core revision over an installed part, end with
   the part serving; a part without its core raises the ADR 0001 message; a
   part of an equal or lower revision returns without touching anything;
   in-place upgrade from revision 16 (byte copy of the current file as the
   fixture) keeping every entry, and with a pending retire hook reported once;
   the budget spec (code lines at most 600). Conformance: the `manifest` and
   `arguments` groups fit; `receivers` does not (Registry's methods do not test
   their receiver) and `limits` does not apply. Client suite
   (`tests/client/MoltenCodesTest_Registry/`, never run): `HasPart` and one
   stub error.
8. Docs: README ("Runtime cost", "Embedding"), `docs/API.md` (each moved
   member's section says which part; "Retirement and migration" and "Sealed
   facades" say which part; the section skeleton `docs/CONTRIBUTING.md`
   defines), `CHANGELOG.md` 0.7.0, `tests/README.md`, the file header (budget).
   Shared files (kept by their owner): `tooling/shared/pins.json` (the narrowed opt-out),
   `docs/ARCHITECTURE.md` (the Registry paragraph and the line-budget
   sentences in the interopKit and addonKit paragraphs), `docs/EMBEDDING.md`
   footprint table.
9. Status: recorded 2026-11-16; code follows.
