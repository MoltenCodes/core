# schedulerKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## schedulerKit (package O): the probe rule, one-pass key validation, receiver checks and scope reopening

**schedulerKit (package O): the probe rule, one-pass key validation, receiver checks and scope reopening** — a change to facade `SchedulerKit`

1. Package `schedulerKit`, facade `SchedulerKit`, API generation 1
   (additive), version 0.9.0 (from 0.8.9), implementation revision 21
   (from 20).
2. Purpose: the SchedulerKit items of
   the decision 18 diagnosis (section schedulerKit
   coalescing, P1 and P2), package O's probe rule, the private-metatable
   checks, `Scope:Reopen` for ModuleKit's kept `Jobs` scope, and the
   decision 19b removals that fall in this file.
   - **Probe rule.** `issecretvalue` is resolved at load (today at `:530`,
     inside a `do` block, with no fallback). The resolved probe moves out of
     the block so the hot paths see it, and when it was absent at load each
     check reads `rawget(_G, "issecretvalue")`, accepted only as a function.
   - **One-pass key validation in a coalesce handle's `__call`**
     (`coalesceCall`, `:3640`): the probe, the `nil` test and the NaN test
     run in one inline condition, and the existing validator raises the
     message (unchanged, same level) only when that condition fails. One Lua
     call fewer per key; no message string is built on success.
   - **No `type()` before the private-metatable checks** (`:1299`, `:1307`,
     `:1315`, `:2406`, `:2415`, `:3105`, `:5387`).
   - **Decision 19b.** The two option-name checks that only keep a secret
     key away from an internal table read (`:1150`, `:2362`, "a secret key
     would raise at the table read below") guard what the client already
     refuses. They go only if the maintainer confirms the reading below; see point 7.
   - **`Scope:Reopen()`.**
   Non-goals, a later package O record with the coalescing part (decision 19a): EventKit
   calling a trusted SchedulerKit entry that skips the key re-check (P3),
   slimming the coalesce member to 8 fields or fewer (P5, about −376 B per
   bucket), the method-name form for buckets (AceBucket's
   `RegisterBucketEvent(events, interval, "Method")`) and the move of
   `Debounce`/`Coalesce`/`Watch`/lanes into a part file. SchedulerKit gets
   no method-name form in (package O): Ace3 has no counterpart to its jobs.
3. Dependencies: unchanged, registry API 2, timerKit API 1.
4. Surface: `scope:Reopen()` → `true` when it reopened a closed manual scope,
   `false` when it was open; an addon scope raises at the caller
   (`SchedulerKit.Scope:Reopen cannot reopen an addon scope`). Jobs and
   handles the close cancelled or closed stay so. Nothing else changes.
5. Ownership: unchanged.
6. Performance and memory (host bench against AceBucket-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | buckets record-event | 1.90× | 1.73× in the client from the probe (EventKit and SchedulerKit); about 1.85× on the bench host, whose missing `issecretvalue` keeps the fallback's read, minus P2's call |
   | buckets burst | 1.93× | 1.79× in the client, as above |
   | buckets register-remove | 2.34× | unchanged (P5 is a later package O record) |

   No bytes change. `Reopen` adds nothing to any hot path.
7. Tests: coalesce key refusals unchanged in text and level (secret, `nil`,
   NaN) through the one-pass check, including `SecretValues_spec:241`,
   which needs the probe visible outside the `do` block; probe installed
   after load honoured on every path that checks one; receiver checks
   without `type` for scopes, jobs, contexts, members and lanes; `Reopen`;
   in-place upgrade from revision 20 keeping queued jobs and coalesce
   handles. Decision 19b: removing the option-name checks assumes that no
   caller table can hold a secret key. The measurement in
   `docs/EMBEDDING.md` shows that reading `t[secret]` raises; that writing
   one raises too, so `pairs` never yields one, is not measured. Until the
   client suite asserts `t[secretwrap(1)] = true` raises, these two checks
   stay; with the maintainer's yes they go and the client suite gains that test.
8. Docs: API.md (`Reopen`, the probe rule), INTERNALS.md (the one-pass key
   check), CHANGELOG, tests/README; the README's scope table.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 21, 289 specs. The option-name key checks stay (decision 19b
   covers read-side checks only).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## schedulerKit (package O): the coalescing family in three parts

**schedulerKit (package O): the coalescing family in three parts** — a change to facade `SchedulerKit`

1. Package `schedulerKit`, facade `SchedulerKit`, API generation 1
   (additive), version 0.10.0 (from 0.9.0), implementation revision 22
   (from 21). Parts, revision 1 each: `Coalescing`, `Lanes`, `Watch`.
2. Purpose: the memory diagnosis's largest optional section: the coalescing
   family is 67 KB of the Kit's 124 KB of live prototypes and 86 KB of its
   176 KB resident, loaded by every addon that embeds SchedulerKit, and
   until now every comm addon did (CommKit's driver was a SchedulerKit job;
   the commKit record below makes SchedulerKit optional for it). Usage
   decides the cut:
   - **Core: jobs, scopes, priorities, the frame budget, delays, repeats,
     cooperative execution, logout coverage.** CommKit's driver when
     SchedulerKit is present, CodecKit's asynchronous calls and ModuleKit's
     `Jobs` scope use them.
   - **`Coalescing`: `Debounce` and `Coalesce`** with their handles and the
     family's shared machinery (one clock, member links, protected
     delivery, the family timer scope): callable handles for any code, the
     general form of AceBucket's job (`RegisterBucketEvent` in 3 of 16
     corpus addons, 19 sites; `RegisterBucketMessage` in 1; the Ace3 gaps
     diagnosis's usage corpus). EventKit's `Coalesce` needs it only with a
     `lane` (the eventKit record times it by TimerKit otherwise), and
     WidgetKit's `BindPosition` uses `Debounce` when it finds it.
   - **`Lanes`: `Lane`, lane objects and delivery of `Debounce`/`Coalesce`
     into a lane.** No Ace3 counterpart; no other Kit uses lanes.
   - **`Watch`.** No Ace3 counterpart; no other Kit uses it.
   Splitting lanes and watch off the coalescing part means an addon that
   debounces or coalesces its own calls carries about 51 KB instead of
   86 KB.
   Non-goals: any behaviour change of the family; trimming the coalesce
   member (P5 of the runtime diagnosis); moving the driver off SchedulerKit.
3. Dependencies: core unchanged (registry API 2, timerKit API 1; eventKit,
   lifecycleKit optional). `Coalescing`: none beyond its core. `Lanes` and
   `Watch`: `"parts": ["Coalescing"]` (they use its clock, member links,
   protected calls and timer scope).
4. Surface.
   - New: `SchedulerKit:HasPart(name)`.
   - Unchanged names, arguments, returns, errors and levels for `Debounce`,
     `Coalesce`, `Watch`, `Lane` on the facade and the scope prototype, and
     for every handle method, when their part is loaded.
   - Without the part: those members raise at the caller with the file to
     embed. `Debounce` or `Coalesce` given `options.lane` while `Lanes` is
     not loaded raise the same way, naming `SchedulerKit-Lanes`.
   - The limits `maxLanes`, `maxWatchIntervals`, `maxWatchersPerInterval`
     and `maxDebounceArguments` stay in the core's limits and keep their
     validation, whichever parts are loaded.
5. Ownership: unchanged. Members still sit on their scope's second intrusive
   list; the core's `CancelAll`/`Close` reach them through the dispatch
   entries `cancelFamilyMembers` and `closeFamilyMembers`, which the
   `Coalescing` part fills (defaults do nothing). `laneJobFinished` and
   `retryLaneJob` become dispatch entries the `Lanes` part fills. The shared
   metatables and prototypes (`familyMetatables`, `familyPrototypes`) stay
   in the core's state, created by the core, so a part loaded by another
   addon finds them.
6. Performance and memory: SchedulerKit alone 176.0 KB → 89.9 KB measured
   for the core (expected about 92 KB with the part interface), Coalescing
   about 51 KB, Lanes about 24 KB, Watch about 12 KB; core with every part
   about 179 KB. Against Ace3: core plus Coalescing about 143 KB against
   AceBucket's 9.6 KB, though an addon replacing AceBucket's event buckets
   now needs only EventKit's part (eventKit record); the core has no Ace3
   counterpart. Hot paths: a
   coalesce handle's `__call` and the delivery path read one helper
   through the part interface (the clock); the job loop is unchanged.
   Expected bench (`buckets`, against AceBucket, one run): record-event,
   burst and register-remove within 3% of today. The main chunk drops from
   194 locals (the installer is one local; its forward-declared hooks become
   dispatch entries): expected about 190. Duplicate embedding: an addon
   without the parts compiles about 2,300 fewer lines.
7. Tests, failing first where a spec can observe it:
   - Bootstrap and Manifest specs for each part (`PART_REVISION` equals the
     manifest, a part without its core raises the ADR 0001 message, an equal
     or lower part revision returns without changes, a higher one upgrades
     in place with live handles);
   - every existing family spec runs with the three parts loaded and passes
     unchanged (same messages, same levels);
   - without each part: every facade, scope and option entry raises at the
     caller's line with the file to embed; `HasPart`; `CancelAll` and
     `Close` on scopes work; limits accept and report the family limits;
   - `Debounce` with `lane` and no `Lanes` part raises at the caller;
   - lane jobs: finishing, failing and retrying through the dispatch entries;
   - in-place upgrade from revision 21 (whole file) with live debounce,
     coalesce, watch and lane objects: with all parts loaded, all keep
     working; with none, they are closed and one report names the parts;
     revision 21 loaded after a core-only revision 22 yields and its
     `Debounce` call gets the stub's error;
   - the public-surface check of revision 21 accepts a core-only facade.
   Client suite: a debounce through the part in the real client.
8. Docs: README (parts table, embedding lines, migration row for AceBucket
   naming the part), `docs/API.md` (Parts, `HasPart`, the stub errors,
   "Coalescing and lanes" says which part holds what), `INTERNALS.md`
   (the part interface, dispatch hooks, upgrade from the whole file),
   `CHANGELOG.md` 0.10.0, `tests/README.md`, client suite `EXPECTED.md`.
   Shared files (text for the maintainer): `docs/EMBEDDING.md` generated
   footprint and parts blocks; `docs/MIGRATING_FROM_ACE3.md` AceBucket rows
   name `EventKit-Coalescing` (and `SchedulerKit-Coalescing` with
   `SchedulerKit-Lanes` for a `lane`). WidgetKit's `BindPosition` moves to
   `SchedulerKit:HasPart("Coalescing")` and the parts contract in
   widgetKit's own record.
9. Status: implemented 2026-11-15, 0.10.0, revision 22, 307 specs. Core 95.6
   KB (176.0 KB before); parts Coalescing 53.0, Lanes 25.1, Watch 11.7 KB. The
   cores of this record and the next three are 4 to 12 KB above their
   estimates (the part interface: helper tables, stand-ins, `HasPart`). Hand-
   over from an older single-file copy without the part closes its live
   objects on the next frame or at first reach, not at load, so a part loading
   right after the core can still adopt them; one report goes through the
   error handler, only when something was closed.

