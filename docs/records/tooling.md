# tooling records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Kit parts and the embeds generator (core decision 19a)

**Kit parts and the embeds generator (core decision 19a)** — repository tooling, no facade

1. Tooling for Kits made of a core file plus optional part files, so an
   addon loads only what it uses (core decision 19a). Scope: (`tooling/`, `tests/support/framework/`, `docs/TOOLING.md`,
   `docs/decisions/`, `.github/workflows/`, the manifest schema). No Kit is
   split by this record: every Kit stays single-file and behaves exactly as
   today. Splitting a Kit is its owner's record (a later package O record starts with
   widgetKit).
2. Purpose: the memory diagnosis (the diagnosis prototype, fix 12) measured
   339 KB of resident code in optional sections a typical addon never runs
   (SchedulerKit and EventKit coalescing, CodecKit compression, CommKit
   reassembly and SyncSet, CommandKit options binding, SettingsKit views and
   spec profiles, ModuleKit halted addons, the WidgetKit renderer and widget
   types). It is the only lever that brings a typical addon near Ace3, and it
   needs the tooling first. The usability diagnosis (the diagnosis prototype,
   cause 3 and F6) found that embedding means copying a 46-line load order by
   hand and that the builder writes no `embeds.xml`. This record gives both:
   parts in the manifest and every gate, and a generated `embeds.xml`.
   Non-goals: assembling parts into one release file (architecture plan 5.3,
   superseded by 19a, which ships parts as files); turning apiKit's flavour
   files into parts (possible later, noted as a follow-up); per-flavour
   `.toc` files; comment stripping; publishing releases.
3. Dependencies: Python 3.10+ standard library only, as the rest of
   `tooling/`; host Lua 5.1 and Busted for the runner, LuaCov for coverage,
   as today. No runtime dependency is added to any Kit.
4. Surface.
   - **Layout.** A part is `packages/<id>/src/parts/<Facade>-<Part>.lua`,
     for example `eventKit/src/parts/EventKit-Coalescing.lua`. `<Part>` is
     PascalCase (`^[A-Z][A-Za-z0-9]*$`). The facade prefix gives every part
     one name across the repository: one `require` name in specs, and an
     unambiguous file name in a client error even when the client cuts the
     path short (the Ace3 `AceGUIWidget-Button` spelling authors know).
     `src/` keeps exactly one top-level Lua file, the core. Other
     subdirectories of `src/` (apiKit's `flavours/`) keep today's meaning:
     always loaded after the core.
   - **Manifest.** An optional `parts` object, written last (after the
     top-level `api` and `revision`, so every `Manifest_spec` that reads the
     first `"api"`/`"revision"` keeps working):

     ```json
     "parts": {
       "Coalescing": {
         "description": "Coalesced and bucketed delivery.",
         "revision": 1,
         "dependencies": { "schedulerKit": { "api": 1 } },
         "optionalDependencies": {},
         "parts": ["Throttle"]
       }
     }
     ```

     `revision` is the part's own implementation revision (highest wins at
     runtime, as for a Kit). `parts` names sibling parts it needs; its own
     core is always implied. Any dependency contract, in a part or in the
     core's `dependencies`, may carry `"parts": ["Name", ...]` to require
     parts of another Kit. Validation: names and file exist one to one
     (a file under `src/parts/` with no entry fails, and the reverse);
     required parts exist; no part names its own Kit in `dependencies`; a
     core never requires its own parts; a release Kit never requires a
     development Kit's part; the required graph over cores and parts has no
     cycle; the part file's `PART_REVISION = <n>` literal equals the
     manifest `revision`.
   - **Runtime contract** (written in ADR 0019a; implemented per Kit by its
     owner): a part loads after its core and everything it requires, resolves
     its core through `Registry:Get` at file scope and raises
     `MoltenCodes <Facade> part <Part> requires <Facade> API <n> to be loaded
     first` when it is missing; it keeps its state in the core's state
     (`_state.parts.<Part>`) with its own `PART_REVISION`, so two addons
     embedding different revisions of a part upgrade in place like Kits; a
     core feature whose part is absent fails at the caller's line with an
     error that names the part to embed.
   - **Load order.** One rule for cores and parts: a depth-first walk over
     nodes. A core's needs are its dependency Kits' cores (sorted by name),
     each followed by the parts its contract names; a part's needs are its
     own core, then its dependency cores and named parts, then its sibling
     parts in manifest order. The top level walks the selected Kits in sorted
     order, each core followed by its selected parts in manifest order. With
     no parts in the repository this is exactly today's algorithm, so every
     existing load order, `.toc` and checksum stays byte-identical.
   - **Builder** (`python3 -m tooling.package.build`):
     `--package ID` (repeatable) selects a Kit's core and the parts its
     contracts require; `--part ID/Part` or `ID/*` (repeatable) adds parts and
     implies the core; `--all` is every release Kit with every part (the
     standalone `MoltenCodes` addon). Bundle name: `MoltenCodes` for `--all`;
     `MoltenCodes-<Facade>` when the selection is one Kit (with any of its
     parts); otherwise `MoltenCodes-Custom`, overridable with `--name`
     (`^MoltenCodes(-[A-Za-z0-9]+)?$`). `--embeds` also writes `embeds.xml` in
     the bundle root. Every file is copied, checksummed and listed in the
     bundle `.toc` in load order; `--verify` holds `CHECKSUMS.txt`, the `.toc`
     and `embeds.xml` to the build. `manifest.json` moves to schema 2: each
     package entry gains `parts` (files, revision, contracts) and
     `selectedParts`, and `loadOrder` may interleave packages (a part can load
     after another Kit's core). The release workflow, `tooling.release.
     library_toc --package` and `tooling.release.pkgmeta --package` build a
     single-Kit release as the whole Kit (`--package ID --part 'ID/*'`), since
     the packager moves the whole `src/` folder; unchanged output today.
   - **Embeds generator** (`python3 -m tooling.package.embeds`): positional
     selectors `ID` (core), `ID/Part`, `ID/*`; `--root 'Libs\MoltenCodes-Custom'`
     (the folder the author copies the bundle to); prints `embeds.xml` (one
     `<Script file=...>` per file, backslashes, dependencies deduplicated, a
     comment naming the selection), or with `--toc` the equivalent `.toc`
     lines; `--out FILE` writes it. Unknown Kit, unknown part, development Kit
     and a missing dependency are refused with a message that names the fix
     (`unknown Kit "TimerKit"; did you mean "timerKit"?`). The builder's
     `--embeds` uses the same function, so the two never disagree.
   - **Test runner** (`tooling.test.run`): every source package on a suite's
     path also contributes `src/parts/?.lua`, so a spec loads a part with
     `require("EventKit-Coalescing")`, or names it in its test environment's
     `modules` list after the core. A suite also gets the Kits its parts
     require and optionally use (the same rule as `optionalDependencies`
     today).
   - **Coverage** (`tooling.test.coverage`): a package's figure covers its
     core and its parts; the report and the step summary show one row per
     part; a declared part that no spec of its own package loaded fails the
     run (a file LuaCov never saw is otherwise invisible).
   - **lua-language-server**: a package's expected `src/.luarc.json` library
     list is the dependency-first closure of its core and all of its parts
     (the `src/` workspace already contains the parts). Unchanged for every
     Kit today.
   - **Repository validation**: the part rules above; the quoted load order
     in `docs/EMBEDDING.md` keeps its check (now including part files); the
     "Minimum footprint per Kit" table and a new "Optional parts" table are
     rendered from the manifests and compared between
     `<!-- generated:footprint -->` / `<!-- /generated:footprint -->` and
     `<!-- generated:parts -->` / `<!-- /generated:parts -->` markers; a
     mismatch prints the exact replacement block, as the load-order check
     does. `python3 -m tooling.package.embeds --footprint` prints both.
5. Ownership: the builder owns nothing at runtime. A generated `embeds.xml`
   is the author's file once written; the generator never edits an existing
   file unless `--out` names it. Generated documentation blocks are only the
   marked blocks; the prose around them stays hand-written.
6. Performance and memory, expected from the prototypes: the tooling adds no
   runtime cost; with no Kit split yet, every bundle is byte-identical to
   today's (checked against the checksums of today's `--all` bundle:
   189 files, 45 Lua files in load order). Once Kits are split, an addon
   that embeds no optional part saves up to 339 KB resident (memory.md
   fix 12), and the event-and-timer minimum set drops from about 333 KB to
   about 313 KB without EventKit coalescing alone. For the author: generated
   `embeds.xml` lines 19 to 0 hand-written for the nine-Kit usability
   example (the prototype's 19 files equal the hand list), and every
   additional addon embedding the same Kits compiles less (duplicate
   embedding allocates 4,992 KB transient today, all of it proportional to
   the files loaded).
7. Tests (`tooling/tests/`, temporary repositories as the builder tests use):
   manifest validation of `parts` (each rule above, accept and refuse); load
   order with parts (core before part, part after another Kit's core, a core
   requiring another Kit's part, sibling parts, cycles refused, the walk
   identical to today's without parts, asserted on the real manifests);
   builder selections (`--package` repeated, `--part ID/Part`, `ID/*`,
   `--all`, names, `--name`, `--embeds`, schema 2 manifest, checksums and
   `--verify` catching a stale `embeds.xml`); the embeds generator (XML and
   `.toc` output, deduplication, root prefix, each refusal message); the
   runner's path carrying `src/parts/` and a Busted run of a fixture Kit
   whose spec requires its part; coverage failing for a part no spec
   loaded and reporting part rows; `.luarc.json` expectations with a part
   that adds a dependency; the EMBEDDING footprint and parts blocks;
   `library_toc` and `pkgmeta` single-Kit output unchanged today. The full
   `--all` build is compared with the baseline checksums.
8. Docs: `docs/TOOLING.md` (builder options, the embeds generator, runner
   and coverage notes); `docs/decisions/README.md` (what an ADR is here,
   the template: Status, Date, Context, Decision, Consequences; numbering:
   ADRs are numbered in sequence from 0001 and stand on their own, each
   naming its date and what it decides: `0001-kit-core-and-parts.md`,
   `0002-secret-checks-only-where-the-client-answers.md`,
   `0003-method-name-callbacks.md`, `0004-addon-kit-entry-point.md`, in
   plain project language. Also updated by this work: `docs/PACKAGE_MANIFEST.md` ("Parts" section
   and the layout tree), `docs/RELEASES.md` (options table, bundle names,
   schema 2), `docs/TESTING.md` (loading a part in a spec). Shared files,
   exact text in the phase 2 report: `docs/EMBEDDING.md` (the two marker
   blocks, a "Choosing parts" paragraph, the generator command), `README.md`
   and `docs/README.md` (a link to `docs/decisions/`), `docs/ROADMAP.md`
   (this record).
9. Status: implemented 2026-11-15 under core decisions 18 and 19: the tooling,
   43 unit tests, no Kit split yet, bundles byte-identical to before; the
   release `manifest.json` stays schema 1, with `parts` added only where a
   Kit declares them; ADRs 0001 to 0004 in `docs/decisions/`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Lua limits gate and version check (architecture plan items 1 and 2)

**Lua limits gate and version check (architecture plan items 1 and 2)** — repository tooling, no facade

1. Two repository gates under core decision 18, in the tooling:
   `tooling/validation/lua_limits.py` with its ratchet file
   `tooling/validation/lua_limits.json`, and a manifest-against-CHANGELOG
   version check in `tooling/validation/validate_repository.py`. The second
   replaces the version-string pins of 14 `Manifest_spec.lua` files.
2. Purpose. Lua 5.1 allows 200 active locals and 60 upvalues per function,
   and nothing measures either today: CommKit and CommandKit sit at 198 of
   200 main-chunk locals, which nobody could see until the architecture
   diagnosis counted them (the diagnosis prototype 2.2, 5.4). The
   gate turns that into a number at review time and holds every file to it.
   Separately, 14 specs pin the SemVer string, so every documentation patch
   edits a spec, while the invariant the pin was after (the manifest version
   is the one the changelog releases) is checked nowhere (5.5). Non-goals:
   splitting any file (that is decision 19a's work, which this gate then
   watches); a revision-against-tag history check (later, once tags exist).
3. Dependencies: `luac` from the Lua 5.1.5 toolchain the CI action
   `.github/actions/setup-lua` already builds (hererocks) and
   `docs/DEVELOPMENT.md` installs locally; Python standard library.
4. Surface.
   - `python3 -m tooling.validation.lua_limits [--update] [paths...]`
     compiles every runtime Lua file (`packages/*/src/**/*.lua`, parts
     included) with `luac -p -l -l` and measures, per function: peak active
     locals (the quantity the 200 limit counts; the prototype is calibrated
     so a file at the limit reports exactly 200), upvalues, and constants
     (reported only). Rules: a main chunk above **190** active locals fails,
     above **180** warns; any other function above **190** locals or above
     **50** upvalues fails. A file already over a fail line is allowed only
     at the value its ratchet entry records. The ratchet can only go down: a
     measured value above its entry fails, a value below its entry fails
     with "lower the entry" (so an entry always equals the measurement and
     a raise can never pass unseen), and an entry for a file under the fail
     line fails as stale. `--update` rewrites the entries to the measured
     values and refuses to raise any. Output names the file, the function's
     line, the value, the limit and the headroom left.
   - Ratchet at the start (measured 2026-11-15): CommKit 198, CommandKit 198,
     SettingsKit 196, ModuleKit 195, SchedulerKit 194, EventKit 191 (main
     chunk). Warnings: WidgetKit 189. No function exceeds the per-function
     lines (largest: SchedulerKit `installCoalescingFamily` at 2317, 111
     locals and 43 upvalues; next upvalues WidgetKit and SettingsKit 25).
   - CI: a new `limits` job in `.github/workflows/ci.yml` (checkout, the
     `setup-lua` action, the command), added to the `ci` summary job's
     `needs`. The repository job has no Lua, so it does not run there.
   - Version check in `validate_repository`: for every package, the manifest
     `version` equals the version of the first `## <version> — <date>`
     heading of its `CHANGELOG.md`, and that date is not later than today
     (UTC). All 41 packages pass today.
   - The 14 pins (barKit, bindingKit, brokerKit, compatKit, dialogKit,
     editModeKit, glowKit, launcherKit, menuKit, panelKit, rangeKit,
     tooltipKit, toastKit, unitFrameKit) become the shape assertion mediaKit
     already uses, `'"version"%s*:%s*"%d+%.%d+%.%d+"'`: one line per file,
     nothing else in those specs touched, so spec counts stay the same.
5. Ownership: the ratchet file is data the gate owns; a contributor changes
   it only through `--update` after making a file smaller.
6. Performance and memory: no runtime effect. The gate compiles 45 files;
   expected run time under 5 seconds locally. Headroom becomes visible:
   CommKit and CommandKit 2 locals, SettingsKit 4, ModuleKit 5,
   SchedulerKit 6, EventKit 9. Documentation-only patches no longer edit a
   spec (14 specs freed of a pin).
7. Tests (`tooling/tests/test_lua_limits.py`, `test_validate_repository.py`):
   the parser on real `luac -l -l` output (peak, a zero-length local, nested
   functions, upvalue counts); calibration (a generated file of 196 locals
   plus a numeric `for` reports 200 and compiles; 197 fails to compile);
   each rule (warn, fail, ratchet held, ratchet lowered, ratchet stale,
   `--update` never raises); the gate green on the repository; the version
   check accepting a match and refusing a mismatch, a missing heading and a
   future date. Every package suite still passes after the pin edits.
8. Docs: `docs/TOOLING.md` (the gate, the thresholds and why, the ratchet,
   the version rule); `docs/decisions/` is covered by the Kit parts record.
   Shared files, exact text in the phase 2 report: `docs/ROADMAP.md` (this
   record), `docs/CONTRIBUTING.md` if it lists the gates (`python3 -m
   tooling.validation.lua_limits`).
9. Status: implemented 2026-11-15: the `lua_limits` gate (21 unit tests, CI
   job `limits`, ratchet `tooling/validation/lua_limits.json`); the 14
   version pins in Manifest specs replaced by the manifest-against-
   CHANGELOG check.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Shared helper blocks and their gate (architecture plan item 4)

**Shared helper blocks and their gate (architecture plan item 4)** — repository tooling, no facade

1. One canonical source for the helpers every Kit carries by hand, inlined into
   each Kit between marked blocks and held to the source by a `--check` gate.
   Scope: `tooling/shared/` (the sources, the tool, the opt-out file),
   `tooling/tests/`, `docs/TOOLING.md`, `docs/CONTRIBUTING.md`, the `repository`
   job of `.github/workflows/ci.yml`. **No Kit is converted by this record**:
   the gate accepts a Kit with no blocks, and each conversion is its Kit's own
   change (revision bump, CHANGELOG, specs) from the migration list in 4.
2. Purpose. The helpers are copied by hand and have drifted (measured
   2026-11-15 over `packages/*/src/**/*.lua`, comments stripped): `isSecret`
   28 copies in 10 bodies, plus 7 `isSecretValue` in 6 bodies; `reportError`
   22 copies in 8 bodies (14 call a raising error handler unprotected, 2 fall
   back to `print`); `describeKey` 18 copies in 5 bodies (15 put a secret key
   straight into a message, apiKit answers `<secret>`, lifecycleKit
   `<secret value>`); `validateFacade` 28 copies in 8 bodies once the facade
   name is replaced (20 identical); the `SetLimits` validation loop 17
   `validateLimitUpdate` copies, each with its own messages. The probe rule of
   package O (resolve `issecretvalue` once at load, read it again per call only
   when it was absent at load) is in the runtime Kits converted in the first
   package O round, and not in the 26 whose check reads the global on every
   call. A canonical copy ends the drift
   at its source; the gate makes a hand edit inside a block fail CI with the
   name of the file to edit instead. Non-goals: converting any Kit; a shared
   runtime library (it would add a required dependency to every Kit against
   ADR 0001's core-plus-parts layout, for about 1.9 KB per Kit); `readGlobal`
   (22 identical copies, nothing to hold), `refuseSecret` (6 bodies whose
   messages are each Kit's contract) and the logout-close routing (later, once
   these five have shown the mechanism).
3. Dependencies: Python 3.10+ standard library. The canonical Lua is valid
   Lua 5.1 on its own, so StyLua, selene, `luac -p` and host Lua read it
   unchanged. No runtime dependency is added to any Kit.
4. Surface.
   - **Sources.** One file per helper under `tooling/shared/lua/`:
     `isSecret.lua`, `reportError.lua`, `describeKey.lua`,
     `validateFacade.lua`, `limits.lua`. Each starts with a header naming its
     revision (`-- shared revision: 1`), the names it defines, the blocks it
     needs earlier in the file (`-- shared requires: isSecret, describeKey`)
     and its parameters; the body follows. A parameter is an identifier that is
     valid Lua (`__FACADE__`), so the source compiles and lints as written;
     the tool substitutes it in identifiers and in string literals.
   - **One main-chunk local per helper.** Every block declares exactly the
     names a Kit calls and keeps its own state inside a `do` block:
     `local isSecret` then `do local loadedProbe = ... isSecret = function(value) ... end end`.
     A Kit that converts never gains main-chunk locals (the probe rule's
     three locals in timerKit become one), so the `lua_limits` ratchet only
     moves down.
   - **Revision 1 of each helper**, chosen from the bodies already in the
     repository, never new behaviour:
     - `isSecret(value)`: the probe rule. `issecretvalue` read once at load
       through `rawget(_G, ...)` and kept only when it is a function; when it
       was absent, each call reads it again and accepts only a function; the
       answer is a strict boolean.
     - `reportError(failure)`: `geterrorhandler()` called through `pcall`;
       a missing handler, or one that raises, falls back to `print(failure)`,
       so reporting one failure never becomes a second one (compatKit's and
       logKit's form). The failure is passed on unchanged and never inspected.
     - `describeKey(key)`: `<secret>` for a secret (asked through `isSecret`),
       a string as written, a number or boolean through `tostring`, anything
       else `<type>`; no caller code (`__tostring`) ever runs.
     - `validateFacade(receiver, label, level)`, parameter `__FACADE__`:
       `type(receiver) ~= "table" or receiver ~= __FACADE__` raises
       `<label> must be called on the <Facade> facade; use <label>(...)` at
       `level` (the form 20 Kits share).
     - `limits` (requires `isSecret`, `describeKey`), parameter `__FACADE__`,
       defines `validateLimitUpdate(limits, level)`,
       `applyLimitUpdate(target, limits)` and `copyLimits(source)` over a
       table the Kit declares before the block,
       `LIMIT_RULES = { { name = "maxGlows", ceiling = 1024, minimum = 1, integer = true, unbounded = false, unboundedReason = "...", check = nil }, ... }`.
       Validation is complete before anything is written (a bad entry leaves
       every limit as it was): a non-table, a secret key, an unknown key
       (described with `describeKey` and the list of accepted names), a secret
       value, a value outside `[minimum, ceiling]` or not an integer where the
       rule says so, `UNBOUNDED` where the rule refuses it (with its reason),
       then the rule's own `check(value, level)` for cross-limit rules such as
       LogKit's against SignalKit. Messages are one canonical set,
       `<Facade>:SetLimits limits.<name> must be an integer from <minimum> to <ceiling>`
       and so on. A Kit whose limits do not fit the rule table keeps its own
       code and is listed in the opt-out file.
   - **Blocks in a facade or part:**

     ```lua
     -- shared:begin validateFacade 1 __FACADE__=GlowKit
     -- Copied from tooling/shared/lua/validateFacade.lua by tooling.shared.sync; edit that file.
     ...
     -- shared:end validateFacade
     ```

     A block may be indented (one inside a `do` block); the tool indents the
     source to the marker's column. Canonical lines are kept at most 90
     columns, which the tool checks, so StyLua never rewraps an indented
     copy.
   - **Command.** `python3 -m tooling.shared.sync [--check] [--list] [paths]`.
     Without a flag it rewrites every block from its source. `--check` writes
     nothing and fails on: a block whose text differs from its source at the
     block's revision (printing the expected text and the source file); an
     unknown helper or parameter; a block whose required blocks do not come
     earlier in the file; a block older than its source's revision without an
     entry in `tooling/shared/pins.json`; a malformed or unclosed marker; a
     canonical source over the column budget. It never fails because a Kit
     has no blocks. `--list` prints the migration list: every top-level
     `local function <helper>(` (and `isSecretValue`) outside a block, by
     Kit and line, with whether its behaviour equals revision 1.
   - **Pins.** `tooling/shared/pins.json` names a Kit and helper that stays
     on an older revision or opts out, each with a one-sentence reason. Seeded
     with one entry: `registry` opts out of every helper (its 1000-line budget
     cannot take the marker lines, and it raises nothing these helpers
     report).
   - **Gate:** `python3 -m tooling.shared.sync --check` in the `repository`
     job of `ci.yml` and in `python3 -m tooling.lint`.
   - **Migration list** (each line is one Kit's later change; what changes
     for its users when it converts):
     - `isSecret` gains the probe rule (one global read per check saved):
       addonKit, apiKit, barKit, bindingKit, brokerKit, compatKit, dialogKit,
       editModeKit, glowKit, launcherKit, logKit, mediaKit, menuKit, panelKit,
       rangeKit, toastKit, tooltipKit, unitFrameKit, and the other per-call
       forms: optionsKit, settingsKit, widgetKit, interopKit, testKit, commKit,
       bridgeKit and schemaKit (the last three through a reader of their own).
       Already on the rule, no behaviour change: timerKit and moduleKit
       (rename from `isSecretValue`), signalKit, hookKit. Resolved at load
       only, gain the late read (a probe installed after load is honoured):
       poolKit, readinessKit, cacheKit. commandKit asks ClientKit first and
       is pinned out unless its owner chooses otherwise.
     - `reportError`: a raising error handler now falls back to `print`
       instead of propagating: addonKit, barKit, bindingKit, commandKit,
       dialogKit, editModeKit, launcherKit, menuKit, panelKit, rangeKit,
       toastKit, tooltipKit, unitFrameKit, widgetKit. No change: compatKit,
       logKit. Compared in conversion: commKit, hookKit, readinessKit,
       schedulerKit, settingsKit, testKit.
     - `describeKey`: a secret key is described as `<secret>`: cacheKit,
       codecKit, commandKit, compatKit, eventKit, logKit, mediaKit, moduleKit,
       poolKit, profileKit, readinessKit, schedulerKit, schemaKit, signalKit,
       timerKit. lifecycleKit: `<secret value>` becomes `<secret>`. apiKit: no
       change. testKit: compared in conversion.
     - `validateFacade`: no change for the 20 Kits on the shared form
       (addonKit, barKit, bindingKit, bridgeKit, brokerKit, codecKit, commKit,
       commandKit, compatKit, editModeKit, glowKit, launcherKit, logKit,
       menuKit, panelKit, profileKit, rangeKit, toastKit, tooltipKit,
       unitFrameKit); a `type` check added for mediaKit, settingsKit,
       widgetKit, cacheKit, testKit (the last three also gain the
       `; use <label>(...)` hint); dialogKit drops its `isSecret` call (a secret
       is never a table); hookKit keeps `rawequal` by a pin unless its owner
       chooses otherwise.
     - `limits`: every Kit with `SetLimits` (41) is a candidate; messages
       become the canonical set, which is a visible change and takes a minor
       version. The first conversions are the single-limit Kits (glowKit,
       toastKit, barKit, tooltipKit, dialogKit), whose loops are the simplest.
5. Ownership: the sources and the tool own the text between markers; the Kit
   owns everything else, including where its blocks sit and which helpers it
   uses. A Kit changes behaviour only by converting or by raising a block's
   revision, each with its own revision bump.
6. Performance and memory. No runtime effect until a Kit converts; every
   bundle stays byte-identical. Measured on host Lua 5.1 with the probe
   installed (5 runs of 5 million calls, best run): the per-call lookup form
   of `isSecret` costs 77 ns, the probe rule 26 to 28 ns, **2.8 to 3.0x per
   check**, for the 26 per-call forms in the first migration line. Main-chunk locals
   never rise on conversion and fall by two where the probe rule's helpers
   collapse into one block. Correctness: 15 Kits stop putting a secret key
   into a message, 14 stop letting a raising error handler escape. Expected
   tool run time under one second for 45 files.
7. Tests (`tooling/tests/test_shared_sync.py`, temporary repositories as the
   builder tests use): marker parsing (begin, end, indentation, parameters,
   unclosed, nested, unknown helper); rewriting and indentation; `--check`
   accepting a fresh block and refusing a hand edit, a stale revision without
   a pin, a missing required block, a parameter left unsubstituted, a source
   over the column budget; pins accepting a documented older revision;
   `--list` on a fixture with converted and unconverted Kits; the gate green
   on the repository as it is (no blocks). Behaviour of the canonical Lua on
   host Lua 5.1 (skipped where Lua is absent, run in the `limits` job): the
   probe at load, absent at load then installed, never installed; a strict
   boolean answer; `reportError` with a handler, without one, with one that
   raises; `describeKey` for each type, a secret and a table whose
   `__tostring` raises (never called); `validateFacade` for the facade, a
   table, a string, a secret, with the error at the caller's line; every
   `limits` rule (atomicity, each refusal and its message, `UNBOUNDED`, a
   rule's `check`), errors at the caller's line.
8. Docs: `docs/TOOLING.md` (the sources, markers, parameters, `--check`,
   `--list`, pins), `docs/CONTRIBUTING.md` (writing a new Kit with blocks;
   converting an existing one: run `--list`, insert markers, run the tool,
   bump the revision, CHANGELOG line, specs). Shared files, exact text in the
   report: `docs/ARCHITECTURE.md` "Conventions every Kit shares" (one
   paragraph pointing to `tooling/shared/`), `docs/ROADMAP.md` (this record).
9. Status: implemented 2026-11-15: `tooling/shared/` (five sources, sync.py,
   pins.json with three opt-outs: registry every helper, commandKit isSecret,
   hookKit validateFacade), the gate in the repository job and `tooling.lint`,
   20 unit tests and a host Lua behaviour script; no Kit converted yet;
   `--list` names 120 hand-written helpers.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Kit conformance suite (architecture plan item 5)

**Kit conformance suite (architecture plan item 5)** — test support, no facade

1. One shared spec module, `tests/support/KitConformance.lua`, that any
   package suite opts into with a short description of its Kit, so every Kit
   is held to the same rules for limits, error levels, secret values, upgrade
   in place and manifest agreement. Scope: `tests/support/` (the module, and
   two small additions to `FrameworkTestEnv.lua`), `tooling/tests/` (a fixture
   Kit and its runner test), `docs/TESTING.md`. **No package suite opts in
   by this record**; each opt-in is a one-file change of its owner
   (`tests/Conformance_spec.lua`), listed in 4.
2. Purpose. The same rules are tested today by 27 `Limits_spec.lua`,
   28 `ErrorLevels_spec.lua` and 31 `SecretValues_spec.lua` files written
   by hand, under different names and to different depth; 11 Kits have no
   file of that name (addonKit, barKit, bindingKit, bridgeKit, clientKit,
   dialogKit, editModeKit, glowKit, settingsKit, toastKit, widgetKit), some
   testing secrets inside other specs. The pattern helpers (`validate*`,
   `SetLimits`) have bodies that legitimately differ, so a byte comparison
   (the shared-helper gate) cannot hold them to one rule; a behaviour suite
   can. The CodecKit `tostring(key)` defect of 2026-11-15 is the kind it
   catches: a `__tostring` key handed to `SetLimits`. Non-goals: deleting
   any existing spec (each owner may retire duplicates after opting in);
   behaviour specific to one Kit; the client suites.
3. Dependencies: Busted and luassert as every suite; `FrameworkTestEnv`;
   `git` only for the true previous revision (4), which is skipped with a
   reason when it is unavailable.
4. Surface.
   - **Opt-in**, in a package's `tests/Conformance_spec.lua`:

     ```lua
     local KitConformance = require("KitConformance")
     KitConformance.Describe({
       environment = GlowKitTestEnv,         -- NewPackage, Reset, NewSecretValue
       packageId = "glowKit",                -- manifest and API.md are found from it
       limits = {
         maxGlows = { default = 64, ceiling = 1024, minimum = 1, integer = true, unbounded = false },
       },
       arguments = {                         -- one line each: the error must name this line
         { name = "Start frame", call = function(kit, value) return kit:Start(value) end },
       },
       upgrade = {
         seed = function(kit) ... end,       -- state an older revision leaves
         verify = function(kit, seeded) ... end,
       },
     })
     ```

     `Describe` opens one `describe` block named
     `"<Facade> conformance"` and registers the `it` cases below; a field left
     out skips its group with a pending note that names the field.
   - **Limits:** `GetLimits` returns a fresh table each call with exactly the
     described names and defaults; `SetLimits` refuses a non-table, a secret
     key, a non-string key, a table key whose `__tostring` raises (and proves
     it never ran), an unknown name, a secret value, a value above the
     ceiling, below the minimum, a fraction where `integer` is set, and
     `UNBOUNDED` where `unbounded` is false; it accepts the boundaries and
     `UNBOUNDED` where allowed; a refused update changes no limit; every
     refusal names the line of the `SetLimits` call; every limit name appears
     in the "Limits" section of the package's `docs/API.md`.
   - **Error levels and secret values:** each `arguments` entry is called
     with a secret value (`environment.NewSecretValue()`) and must raise at
     the entry's line with "secret" in the message; the entry must be one line
     (the helper checks `linedefined == lastlinedefined` and says how to fix
     it otherwise). Every facade method is called on a receiver that is not
     the facade (a table, a string) and must raise at the caller's line. Per
     ADR 0002, only arguments the Kit compares, tests or stores as a key are
     listed; a key that only indexes a table is not.
   - **Upgrade in place**, two levels: (a) revision takeover, always run:
     the Kit's source is loaded with `IMPLEMENTATION_REVISION` lowered by one,
     `seed` runs, the current source loads, `verify` sees the state kept and
     the facade's identity unchanged; (b) the true previous revision, run
     when the test runner provides it: `tooling.test.run` extracts the Kit's
     facade (and parts) from the last commit whose manifest `revision` is one
     lower (`git log` on the manifest) into a temporary directory and names
     it in `MOLTENCODES_PREVIOUS_REVISION_DIR`; outside a checkout, or with a
     shallow history, the case is pending with that reason. CI's `test` job
     checks out with full history for it.
   - **Manifest and runtime agree:** `API` and `REVISION` equal the manifest's
     `api` and `revision`; `Registry:Get(packageId, api)` returns the facade;
     each part's `PART_REVISION` equals its manifest entry; loading the Kit
     without each required dependency fails with an error naming that
     dependency's facade (`FrameworkTestEnv` gains `NewPackageWithout(moduleName)`
     for this, built on its existing module list).
   - **`FrameworkTestEnv` additions:** `NewPackageWithout` and
     `LoadSourceWithRevision(moduleName, revision)` (the generic form of the
     35 per-package `LoadRevision` helpers, walking `package.path` as they
     do). Nothing existing changes.
   - **Opt-in list,** in order of how little each needs: (1) the user-interface
     Kits with one or two limits and uniform helpers: glowKit, toastKit,
     barKit, tooltipKit, dialogKit, bindingKit, menuKit, launcherKit,
     panelKit, editModeKit, rangeKit, unitFrameKit; (2) the data Kits with
     several limits: brokerKit, cacheKit, profileKit, localeKit, logKit,
     mediaKit, compatKit, schemaKit, codecKit, interopKit, readinessKit,
     poolKit, clientKit, apiKit, bridgeKit; (3) the runtime Kits, whose
     owners are converting them this round: signalKit, eventKit,
     lifecycleKit, moduleKit, timerKit, schedulerKit, hookKit, settingsKit,
     optionsKit, commandKit, commKit, widgetKit, addonKit; (4) testKit.
     registry is not on the list: its specs prove the bootstrap that this
     suite relies on.
5. Ownership: the module owns the shared assertions; each package owns its
   description and decides when to opt in and which of its own specs to
   retire.
6. Performance and memory: test time only; expected under 0.3 s per opted-in
   Kit (about 25 cases, each a fresh environment). No runtime effect, every
   bundle byte-identical.
7. Tests: a fixture Kit under `tooling/tests/fixtures/conformance/` (one
   limit, one method, an upgrade path) whose `Conformance_spec.lua` passes;
   variants that each break one rule (an unknown key accepted, a
   `tostring(key)` in a message, an error at the wrong level, a secret
   compared, `REVISION` not matching the manifest, state lost on upgrade, a
   limit missing from `docs/API.md`) and must fail with the case that names
   it; `tooling/tests/test_kit_conformance.py` runs them through Busted
   (skipped where Busted is absent) and asserts which cases fail. A
   multi-line `arguments` entry gives the guidance failure.
8. Docs: `docs/TESTING.md` (opting in, each field, what each group proves,
   the previous-revision source and why it can be pending),
   `tests/support/` file header. Shared files, exact text in the report:
   `docs/ROADMAP.md` (this record), `tests/support/framework/` is not
   touched.
9. Status: implemented 2026-11-15: `tests/support/KitConformance.lua`,
   FrameworkTestEnv's Modules, NewPackageWithout, LoadSourceWithRevision and
   findModuleFile, `tooling/test/previous.py` with the test job on full
   history; proven on a fixture Kit and eight broken copies; no package opted
   in yet.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## One-command client sessions (architecture plan item 7)

**One-command client sessions (architecture plan item 7)** — repository tooling and the test harness, no facade

1. A client session per flavour in three commands and three slash commands:
   `prepare` installs everything, `/mct run all` runs what needs no player,
   `/mct run guided` walks the tests that need one, `collect` records the
   results, `clean` removes the installation. Scope:
   `tooling/client/` (`session.py`, `--all` in `install.py`, `report.py`
   modes), `tests/client/MoltenCodesTest/` (the harness only),
   `tooling/tests/`, `docs/TESTING.md`. The package suites are not edited:
   which suites are interactive is each suite's one-line change (4).
2. Purpose. 41 client suites hold 818 tests, and 13 Kits' suites have never
   run in a client; no Classic flavour has run at all. Installing every suite
   takes `--package` 41 times, the order of manual steps is spread over 41
   `EXPECTED.md` files (settingsKit alone needs two runs with a `/reload`
   between them), and a test that waits for the player (a right click, Edit
   Mode, a party) stalls an otherwise unattended run for its timeout. This
   makes one evening per flavour enough. Non-goals: running anything
   automatically at login (the harness rule stays); changing what any suite
   tests; the benchmark (its own record).
3. Dependencies: the existing installer, report and harness; TestKit as
   today. Python standard library.
4. Surface.
   - **`python3 -m tooling.client.install --all`**: every package with a
     client suite (`tests/client/MoltenCodesTest_<Facade>/`), discovered from
     the manifests; packages without one (testKit) are named in the output.
     `--all` and `--package` are exclusive.
   - **`python3 -m tooling.client.session prepare --wow-dir DIR [--flavour-dir NAME] [--packages ID,...]`**:
     the install of `--all` (or the named packages), then a session sheet
     printed and written to `<wow-dir>/<flavour-dir>/MoltenCodesTest-session.txt`:
     the in-game lines in order (`/mct run all`, `/mct run guided`, `/mct run
     combat` at a dummy, the settingsKit second run, `/reload`); the
     preconditions copied from each `EXPECTED.md` "Combat run", "The
     procedure" and "Per flavour" section, with the package named; and the
     expected totals per package, read from the totals line of each
     `EXPECTED.md` (all 41 carry one in the same form).
   - **`collect --wow-dir DIR [--flavour-dir NAME]`**: `tooling.client.report`
     for that flavour, then a table per package: expected totals, recorded
     totals per mode, and one of "as expected", "differs", "not run". A
     difference is reported, never fatal: the expectations are Retail's and
     the "Per flavour" notes are prose.
   - **`clean --wow-dir DIR [--flavour-dir NAME] [--force]`**: `install
     --remove` plus the session sheet, refused while `results.json` has no
     row whose installation time equals the installed `Expected.lua`'s, so
     results are never deleted before they are recorded; `--force` overrides
     and says what is lost.
   - **Harness:** a suite option `interactive = "<one instruction line>"`
     (a non-empty string; `Harness:Suite` refuses anything else).
     `/mct run all` runs every loaded package's suites except interactive
     and combat ones, saves rows with mode `unattended`, and ends with
     `MoltenCodes Test: session pass done: <n> packages, <n> passed, <n> failed, <n> skipped, <n> timed out; <n> interactive suites wait for /mct run guided; /reload to save`.
     `/mct run guided` takes the interactive suites one package at a time:
     prints the suite's instruction, waits for `/mct next` (or `/mct skip`,
     recorded as skipped with the reason "skipped by the player"), runs it,
     saves rows with mode `guided`, moves on. `/mct run` and `/mct run <id>`
     keep their meaning (mode `default`); `/mct run combat` is unchanged.
     `all`, `guided`, `combat`, `next` and `skip` become reserved: repository
     validation refuses a package with one of those IDs.
   - **Report:** `results.json` rows gain the modes `unattended` and
     `guided` (rows were already keyed by mode); `RESULTS.md` shows them as
     columns of the same package row.
   - **Interactive suites to tag** (one line each, by the suite owners; until
     then those suites still run in `/mct run all` and wait for their
     timeout), read from the suites and their `EXPECTED.md`: menuKit
     `extensions` (right-click your own unit frame), editModeKit `editMode`
     (open and close Edit Mode), rangeKit `player` (target a unit, walk 30
     yards away), unitFrameKit `party` (be in a party of two with Blizzard's
     party frames). Any further suite whose `EXPECTED.md` asks the player to
     act is listed by `python3 -m tooling.client.session prepare --dry-run`,
     which reads the harness's suite registrations.
5. Ownership: the harness owns the modes, the reserved words and the session
   totals line; the session tool owns only the sheet it writes; each suite
   owns its `interactive` text.
6. Performance and memory: nothing changes for addon users. For the owner:
   one install command instead of 41 flags, and one sheet instead of 41
   documents. The duration of an unattended pass has never been measured
   (no session has run); the sheet records the start and end time of each
   pass so the first session measures it. Expected per flavour: about 30 to
   45 minutes including the guided and combat steps.
7. Tests: `tooling/tests/test_client_install.py` (`--all` installs every
   suite and names the packages without one; exclusive with `--package`);
   `tooling/tests/test_client_session.py` (the sheet from fixture
   `EXPECTED.md` files: totals parsed, sections collected, order of lines;
   `collect` against fixture saved variables: as expected, differs, not run;
   `clean` refused without a recorded row, allowed with one, forced);
   `tooling/tests/test_client_report.py` (the two new modes); the harness
   driven through host Lua by a Busted spec under
   `tooling/tests/fixtures/harness/` with the shared fake client: an
   interactive suite skipped by `run all` and listed, `run guided` waiting
   for `next`, `skip` recorded, the totals line, the reserved words;
   repository validation refusing a reserved package ID.
8. Docs: `docs/TESTING.md` (the session commands and the slash commands),
   `docs/DEVELOPMENT.md` (the one-evening procedure per flavour). Shared
   files, exact text in the report: `tests/client/README.md` (the session
   section and the `interactive` option), `docs/ROADMAP.md` (this record).
9. Status: implemented 2026-11-15: `install --all`, `tooling.client.session
   prepare/collect/clean`, the harness's `/mct run all`, `run guided`, `next`
   and `skip` with the interactive suite option, report modes unattended and
   guided; a host Busted spec drives the harness. Deviation: `/mct skip`
   records nothing (the package shows not run). Tagged interactive on
   2026-11-16: menuKit `extensions`, editModeKit `editMode`, rangeKit
   `player`, unitFrameKit `party`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Lists generated from the manifests (architecture plan item 8)

**Lists generated from the manifests (architecture plan item 8)** — repository tooling, no facade

1. Every list of packages kept by hand in the repository becomes a block
   rendered from the manifests between markers, checked by repository
   validation, which prints the exact replacement block. Scope:
   `tooling/docs/` (`generate.py`), `tooling/validation/validate_repository.py`,
   `tooling/validation/validate_manifests.py` (one optional field),
   `tooling/tests/`, `docs/TOOLING.md`, `docs/CONTRIBUTING.md`. The shared
   files that receive markers are edited once, from the text in the report.
2. Purpose. A new Kit is written into 14 lists in 9 files outside its
   package, and they disagree today: the three package indexes give three
   different one-line purposes for each of the 42 packages (none equals the
   manifest `description`), and the root README, `docs/README.md`,
   `packages/README.md` and the ARCHITECTURE tree list the packages in three
   different orders. Validation checks only that each name is present.
   Non-goals: hand-written prose (ARCHITECTURE's package paragraphs and
   dependency graph, MIGRATING_FROM_ACE3, EMBEDDING's prose), the client
   suite tree in `tests/client/README.md`, per-package spelling and
   allow-list files (each a later record), the EMBEDDING footprint and parts
   tables (already generated).
3. Dependencies: Python standard library; `tooling.package.build` for the
   manifests and the release/development split.
4. Surface.
   - **Manifest:** an optional `summary` field, one sentence of at most 240
     characters ending with a full stop, the line a package index shows. A
     package without one shows its `description`. The 42 summaries to add
     are the purposes of today's root README table, so that table renders
     unchanged; the exact manifest lines are in the report.
   - **Order:** `registry` first, then the release packages by ID in
     alphabetical order, then the development packages. One rule for every
     list, so a reader finds a Kit by name.
   - **Markers:** `` / ``
     in Markdown (on their own lines, or around an inline value for a count),
     `# generated:<name>` / `# /generated:<name>` in YAML, as EMBEDDING
     already uses.
   - **Blocks:**

     | Block | File | Rendered from |
     |---|---|---|
     | `package-table` | `README.md` | `name`, `summary`, development flag |
     | `package-count` (inline, twice) and `package-count-sentence` | `README.md` | count of release and development packages, in figures and in words |
     | `package-index` | `docs/README.md` | `displayName`, `summary` |
     | `package-index` | `packages/README.md` | `name`, `summary` |
     | `package-tree` | `docs/ARCHITECTURE.md` | `name` |
     | `package-ids`, `facade-names` (inline) | `docs/ARCHITECTURE.md` "Package naming" | `name`, `displayName`, registry excluded |
     | `move-folders` | `.pkgmeta` | release packages, `src` and `docs` |
     | `kit-labels` | `.github/labels.yml` | every package |
     | `kit-labeler` | `.github/labeler.yml` | every package |
     | `kit-options` | `.github/ISSUE_TEMPLATE/bug_report.yml`, `feature_request.yml` | every package |

   - **Command:** `python3 -m tooling.docs.generate [--check] [--write] [--block NAME]`.
     Default prints every block; `--write` replaces the content between
     existing markers and never adds a marker; `--check` fails on a missing or
     stale block and prints the block to put in its place.
   - **Validation:** `validate_repository` runs the same comparison and
     prints the same replacement text. It replaces the three presence checks
     (`validate_navigation_indexes`' package half,
     `validate_github_kit_lists`, the package half of
     `validate_pkgmeta_packages`), whose rules the exact blocks now hold. The
     `summary` field is validated by `validate_manifests`.
   - **ARCHITECTURE presence check:** every package ID has a paragraph in
     "Package by package" (a in backticks ID starting a paragraph); missing ones
     are named. The paragraphs stay hand-written.
5. Ownership: generated blocks belong to the generator; the text around them
   stays hand-written. A package owns its `summary`.
6. Performance and memory: no runtime effect, no bundle byte changes (the
   packaged `.pkgmeta` move-folders are the same entries, reordered; the
   packager result is the same files). A new Kit then edits 0 of these 14
   lists by hand: one command writes them all. Readers see one purpose per
   package in all three indexes instead of three.
7. Tests (`tooling/tests/test_docs_generate.py`, fixture manifests): each
   block renders as specified; order; a package without `summary`; counts in
   figures and words; inline and block markers; YAML markers; `--write`
   replacing only between markers and refusing a file with no markers;
   `--check` and validation printing the replacement for a missing and for a
   stale block; the `summary` field rules; the ARCHITECTURE presence check;
   the repository green once the markers are in place.
8. Docs: `docs/TOOLING.md` (the blocks, the command, the order rule),
   `docs/CONTRIBUTING.md` (adding a Kit: write `summary`, run the command).
   Shared files, exact text in the report: the marker blocks for
   `README.md`, `docs/README.md`, `packages/README.md`,
   `docs/ARCHITECTURE.md`, `.pkgmeta`, `.github/labels.yml`,
   `.github/labeler.yml`, both issue forms; the 42 `summary` lines;
   `docs/PACKAGE_MANIFEST.md` (the `summary` field); `docs/ROADMAP.md` (this
   record).
9. Status: implemented 2026-11-15: `tooling.docs.generate` with 13 blocks, the
   `summary` manifest field, validation printing replacements, the markers in
   the shared files.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## A required docs/API.md skeleton and its checker (architecture plan item 9)

**A required `docs/API.md` skeleton and its checker (architecture plan item 9)** — repository tooling, no facade

1. A fixed set of `##` sections every Kit's `docs/API.md` carries, in a fixed
   order, checked by repository validation in warning mode first. Scope:
   `tooling/validation/validate_repository.py`, `tooling/tests/`,
   `docs/CONTRIBUTING.md` (the skeleton), `docs/TOOLING.md`. No API.md is
   edited by this record.
2. Purpose. The 42 documents name one concern seven ways ("Errors" in 7,
   "Error behaviour" in 24; "Cost" in 10, "Performance" in 23; "Upgrades"
   and "Embedded identity and upgrades" beside "Embedded copies and
   upgrades"), and 16 documents have no "Secret values" section. A
   reader cannot find the same fact in the same place twice. Non-goals:
   rewriting any document's content; the cross-check of every error literal
   against "Error behaviour" (a later step, once the skeleton holds).
3. Dependencies: Python standard library.
4. Surface.
   - **Required sections, in this order:** Loading, Public surface, Secret
     values, Limits, Error behaviour, Performance, Embedded copies and
     upgrades. Any other `##` section may stand anywhere after "Public
     surface". A required section may hold only "None." and one sentence
     saying why. Headings inside fenced code blocks are ignored (two
     documents quote a `.toc` whose `## Title:` line is not a heading).
     This order, with "Secret values" before "Limits", is the one 14
     documents already follow; the order "Limits" then "Secret values" fits
     4 of them.
   - **Renames the checker suggests:** "Errors" to "Error behaviour", "Cost"
     to "Performance", "Upgrades" and "Embedded identity and upgrades" to
     "Embedded copies and upgrades".
   - **Warning mode:** `validate_repository` prints one warning per
     document and problem (missing section, order, a section before
     "Loading", a suggested rename) and exits 0 for them. A constant,
     `API_SECTIONS_REQUIRED = False`, turns the warnings into errors once
     the list below is empty.
   - **Not conforming today (28):** compatKit (renames only: Errors, Cost);
     addonKit, localeKit, logKit, readinessKit, settingsKit, testKit (each
     missing "Secret values"); apiKit, bridgeKit, cacheKit, clientKit,
     codecKit, commKit, commandKit, eventKit, hookKit, interopKit,
     lifecycleKit, moduleKit, optionsKit, poolKit, profileKit, registry,
     schedulerKit, schemaKit, signalKit, timerKit, widgetKit (missing
     sections, order, or both; the checker's warnings list each). Conforming
     (14): barKit, bindingKit, brokerKit, dialogKit, editModeKit, glowKit,
     launcherKit, mediaKit, menuKit, panelKit, rangeKit, toastKit,
     tooltipKit, unitFrameKit.
5. Ownership: the checker owns only headings; each package owns its
   document and moves its own headings.
6. Performance and memory: no runtime effect, no bundle change. Expected: 14
   of 42 conform today, 15 after renames alone.
7. Tests (`tooling/tests/test_validate_repository.py`): a conforming
   document; each problem reported; a heading inside a fence ignored;
   "None." accepted; warning mode exits 0 and error mode fails; the repository
   gives exactly the 28 warnings' documents listed above.
8. Docs: `docs/CONTRIBUTING.md` (the skeleton, copyable, with a sentence on
   what each section holds), `docs/TOOLING.md` (the check and its mode).
   Shared files, exact text in the report: `docs/ARCHITECTURE.md` "Package
   ownership" (the API.md line names the skeleton), `docs/ROADMAP.md` (this
   record).
9. Status: implemented 2026-11-15 in warning mode: 14 of 42 documents conform,
   the others are listed by the warnings.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## Benchmark smoke profile, login and saved-variables cases, AceConfigDialog pinned (architecture plan item 10)

**Benchmark smoke profile, login and saved-variables cases, AceConfigDialog pinned (architecture plan item 10)** — benchmark tooling, no facade

1. A short in-client benchmark run, the two measurements the memory claim
   rests on (the cost of loading each side as an addon, and of opening a
   database that came from disk), and AceConfigDialog-3.0 added to the
   pinned Ace3 files. Scope: `tooling/bench/` (workloads, installer, the
   `MoltenCodesBench` harness, report, `ace3.py`), `tooling/tests/`,
   `docs/BENCHMARKS.md`.
2. Purpose. The in-client benchmark has never run: one case per session and
   side makes a full run about 150 reloads at one round and about 760 at
   five. Nothing measures what an addon author pays at login for each side,
   and AceDB against SettingsKit is measured only on data built in memory,
   not on saved variables the client restored. AceConfigDialog-3.0, the
   library most Ace3 addons load for options, is not in the pinned set.
   Non-goals: an `optionsDialog` workload comparing PanelKit with
   AceConfigDialog (it needs this pin first and follows it); CPU attribution
   with `GetAddOnCPUUsage`; the Classic event list for `session`; the A/B
   with a ported addon.
3. Dependencies: the pinned Ace3 commit `5e2e0d3b3fd1` (BSD-3-Clause, as
   recorded in `docs/BENCHMARKS.md`); the builder's selections for the Kit
   sets. Client functions used, present in all five apiKit flavour tables
   (generated from `Blizzard_APIDocumentationGenerated`):
   `C_AddOns.LoadAddOn`, `UpdateAddOnMemoryUsage`, `GetAddOnMemoryUsage`,
   `debugprofilestop`.
4. Surface.
   - **Smoke profile** (`PROFILES["smoke"]` in `client_workloads.py`): one
     headline case per shared workload and the four client-only ones, 13
     cases, 26 items with both sides: eventDispatch `dispatch-10`,
     messageDispatch `dispatch-10`, settings `read-saved`, codec
     `encode-medium`, libraryRegistry `lookup`, hooks `call-posthooked-method`,
     slashCommands `dispatch-words`, locale `lookup`, aceSerializer
     `decode-medium`, window `open-close-drawn`, timersLive `oneshot-fire-1000`,
     session `load-60s`, session `memory-300s`. `PROFILES["all"]` is every
     case.
   - **`/mcb run smoke [rounds]` and `/mcb run all [rounds]`** queue a profile
     for both sides, alternating sides per item so drift affects both.
   - **Planner:** `python3 -m tooling.bench.client_install --plan smoke|all [--rounds N] [--reload-seconds S]`
     prints the items, the reloads and an estimate (case time from the
     workloads, plus `S` per reload, 20 by default and stated as an
     assumption) before anything is installed.
   - **`login` workload** (client only): after a `/reload`, the harness
     loads one side addon with `C_AddOns.LoadAddOn` between two
     `debugprofilestop` reads, runs a full collection, then reads
     `UpdateAddOnMemoryUsage`/`GetAddOnMemoryUsage` for it. Three sets, each
     a pair of load-on-demand side addons the installer writes:
     `minimum` (registry, signalKit, eventKit, lifecycleKit, timerKit against
     LibStub, CallbackHandler-1.0, AceAddon-3.0, AceEvent-3.0, AceTimer-3.0),
     `typical` (addonKit's core and its required closure, no parts, against
     the Ace3 libraries a typical addon embeds: LibStub, CallbackHandler-1.0,
     AceAddon-3.0, AceEvent-3.0, AceTimer-3.0, AceDB-3.0, AceConsole-3.0,
     AceLocale-3.0), and `full` (the release bundle against every pinned Ace3
     file). 5 rounds by default. Kit sets come from the builder's selection,
     so they follow the manifests and parts.
   - **`savedVariables` workload** (client only): each side addon declares
     one saved variable. Case `write-<profiles>x<keys>` builds 1x200 and
     20x200 databases (AceDB-3.0 profiles against SettingsKit profiles with
     the same values) and asks for a `/reload`; case `read-<profiles>x<keys>`
     in the next session times `LoadAddOn` (which includes the client
     restoring the table) and the open of the database (AceDB `New` against
     SettingsKit's open) separately, with memory after a full collection.
     The harness pairs a read with the write before it and refuses a read
     with no write.
   - **AceConfigDialog pin:** `ace3.py` gains `AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua`
     and the AceGUI-3.0 files it creates that are not pinned yet (read from
     its source at the pinned commit: `BlizOptionsGroup`, `DropDownGroup`,
     `TabGroup`, `TreeGroup` containers; `DropDown`, `DropDown-Items`,
     `ColorPicker`, `Keybinding`, `MultiLineEditBox`, `Icon` widgets), as a
     separate `DIALOG_FILES` tuple covered by the same content digest, which
     changes once. Only the `full` login set loads them; every existing
     workload and side keeps the files it loads today, so existing results
     stay comparable.
5. Ownership: the harness owns the queue and its saved results; the
   installer owns the side addons it writes.
6. Performance and memory: no runtime effect on any Kit; every release
   bundle is byte-identical. For the owner: a smoke run is 26 reloads
   instead of about 150, about 35 minutes including the two 5-minute memory
   cases per side (estimate; the planner states its assumption). Expected
   numbers are those the record exists to produce: the first in-client
   login time and held memory of each side for the three sets, and the first
   AceDB against SettingsKit open of restored saved variables. The host
   figures to compare them with: the minimum set's source is 457 KB against
   Ace3's 48.6 KB (9.4x), so this is the measurement package O's memory work
   is judged by.
7. Tests (`tooling/tests/test_bench_client.py`, `test_bench.py`): profiles
   name only existing cases; the planner's counts and estimate; `run smoke`
   and `run all` queues (order, alternation, rounds); the side addons of each
   login set (files from the builder's selection, Ace3 files, `.toc`s load
   on demand, saved variables declared); the saved-variables pairing and the
   refusal of an unpaired read; the new pinned files and digest, and the
   existing workloads' file lists unchanged; the report rendering the two new
   workloads. The Lua side of each new workload runs on host Lua with the
   shared fake client's `LoadAddOn` and memory stubs where they exist; the
   real numbers come only from a client.
8. Docs: `docs/BENCHMARKS.md` (profiles, the planner, the two workloads, the
   sets and why each, the new pinned files and licence). Shared files, exact
   text in the report: `docs/ROADMAP.md` (this record).
9. Status: implemented 2026-11-15: smoke (13 cases, 26 sessions) and all
   profiles, `/mcb run smoke|all`, `--plan`, the login and savedVariables
   workloads with seven set side addons, AceConfigDialog-3.0 and ten AceGUI
   files pinned (new digest); not yet run in a client.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## apiKit's flavour files loaded only on their own client (architecture plan item 14)

**apiKit's flavour files loaded only on their own client (architecture plan item 14)** — packaging, no facade change

1. The bundle `.toc` loads each apiKit flavour file only on the client game
   type it serves, so the standalone addon compiles one flavour's tables
   instead of five. Scope: `tooling/api/flavours.json` (a `gameTypes` list
   per flavour), `tooling/package/toc.py` and `build.py` (the `.toc` line),
   `tooling/release/library_toc.py` (the same line for the packager),
   `tooling/package/embeds.py` (`--toc` output), `tooling/tests/`,
   `docs/RELEASES.md`. ApiKit's source, manifest and revision do not change.
2. Purpose. The `MoltenCodes` bundle's `.toc` lists all five flavour files
   (2.27 MB of source). ApiKit installs only the running client's flavour and
   discards the other installers, so the four others are compiled for
   nothing at every login on every client. Non-goals: dropping Ptr and Beta
   from release bundles (a choice for the owner, below); one `.toc` file per
   flavour; comment stripping; any change to how an embedder lists files in
   `embeds.xml`.
3. Dependencies, verified on warcraft.wiki.gg "TOC format" (last edited
   2026-11-05): a file line in a `.toc` may end with the inline directive
   `[AllowLoadGameType <type>, ...]` ("restricts the addon directive or
   file to one or multiple specific game types"; game types `standard`,
   `mists`, `tbc`, `vanilla` among others); inline directives for files
   arrived in patch 11.1.5; the page says Mists of Pandaria Classic 5.5.4 and
   Classic Era 1.15.9 "include all Modern changes up to 12.0.7", so every
   promised client (`supported_clients.json`: 120105, 50504, 11509) has
   them. The page also says an `AllowLoadGameType` naming no recognised game
   type "will still be satisfied", so an unknown name loads the file rather
   than losing it. Not stated by the page, and therefore checked in the
   first client session: whether TBC Anniversary 2.5.6 reads the directive,
   and which game type a Retail PTR or beta client reports.
4. Surface.
   - **Data:** each flavour in `tooling/api/flavours.json` gains
     `"gameTypes"`: retail, ptr and beta `["standard"]`, classic-mop
     `["mists"]`, classic-era `["vanilla"]`.
   - **`.toc` line:** `apiKit\flavours\Retail.lua [AllowLoadGameType standard]`,
     and so on, written by the one function every `.toc` renderer uses (the
     bundle `.toc`, `library_toc`, the client-test installer's bundle and the
     embeds generator's `--toc` output), so they never disagree. `--verify`
     and repository validation read the line with its directive.
   - **Unchanged:** `embeds.xml` (`<Script file>` has no directive; an
     embedder keeps listing only the flavours it ships), every other line
     and file of every bundle, `manifest.json`, `CHECKSUMS.txt` except the
     `.toc`'s own checksum.
   - **Ptr and Beta (owner's choice, not taken by this record):** both stay
     in the bundle under `standard`, so a live Retail client still compiles
     Retail, Ptr and Beta. Leaving them out of release bundles (kept in
     development builds) would bring Retail to one file; it would also mean a
     PTR or beta player using the release bundle gets no `wow.ptr.api` or
     `wow.beta.api`.
   - **Visible change:** `ApiKit:GetMetadataBuild(flavour)` for a flavour
     whose file the client did not load now returns nothing (today it
     returns the version and build of every loaded file). ApiKit's
     `docs/API.md` and README need one sentence each; the exact text is in
     the report, since this record does not touch ApiKit's documents.
5. Ownership: flavour data stays in `tooling/api/flavours.json`, which the
   generator already owns; the builder owns the `.toc` line.
6. Performance and memory, measured on host Lua 5.1 (compile only, 5 runs,
   best): all five files 11.4 ms and 6,401 KB allocated while compiling;
   Retail, Ptr and Beta 7.8 ms and 4,264 KB; Retail alone 2.5 ms and
   1,893 KB; ClassicMop or ClassicEra alone 1.8 ms and 1,560 KB. So, with
   Ptr and Beta kept: a Classic client compiles **6.3x less** (11.4 to
   1.8 ms) and allocates **4.1x less** at login; a Retail client 1.5x less.
   With Ptr and Beta left out of releases, Retail 4.6x less time and 3.4x
   less allocation. Held memory is unchanged (the discarded installers were
   garbage already); the gain is login time and collector work. Bundles are
   byte-identical except the `.toc` lines of the five flavour files.
7. Tests (`tooling/tests/test_package_build.py`, `test_release.py`,
   `test_kit_parts.py`, `test_client_install.py`): the bundle `.toc` and
   `library_toc` carry each directive; `--verify` accepts them and refuses a
   stale one; the embeds generator's `--toc` matches; `flavours.json`
   validation requires a non-empty `gameTypes` of known names; every other
   bundle file's checksum unchanged against the build before the change.
   The client proof is one line added to the ApiKit client suite by its
   owner (exact text in the report): the running flavour is installed and
   no other flavour has registered metadata.
8. Docs: `docs/RELEASES.md` (the directive and why), `docs/TOOLING.md`.
   Shared files, exact text in the report: `docs/EMBEDDING.md` (the `.toc`
   example and the "apiKit carries one file per flavour" paragraph: the
   directive for embedders who use a `.toc`), ApiKit's README and
   `docs/API.md` (the `GetMetadataBuild` sentence), `docs/ROADMAP.md` (this
   record).
9. Status: implemented 2026-11-15: `gameTypes` in `tooling/api/flavours.json`,
   the `[AllowLoadGameType ...]` directive in every generated `.toc`, apiKit
   0.2.3 (documentation and packaging only, revision 6); bundles byte-
   identical apart from the five `.toc` lines; on host Lua a Classic client
   compiles 6.3x faster and allocates 4.1x less.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## ROADMAP split into a status table and one record file per package (architecture plan item 12)

**ROADMAP split into a status table and one record file per package (architecture plan item 12)** — documentation tooling, no facade

1. A script that moves every nine-point record out of `docs/ROADMAP.md` into
   `docs/records/<package>.md`, unchanged, and leaves ROADMAP as the status
   table, the open items, the standing obligations and the policies. Scope:
   `tooling/docs/split_roadmap.py` and its tests. Running it, and committing
   the moved text, is a one-time step on the shared files.
2. Purpose. ROADMAP is 5,123 lines with 58 records and changed in 107
   commits; every new Kit or capability writes into the same file, so
   parallel work queues on it. One file per package lets records land
   independently. Non-goals: editing any record's text; the client-run
   columns of the status table rendered from `results.json` (a later
   generated block of the lists record).
3. Dependencies: Python standard library.
4. Surface.
   - `python3 -m tooling.docs.split_roadmap [--write]`: finds each record by
     its bold title line ending in ` — <kind>` and its nine numbered points;
     maps it to a package by the first word of the title when it is a package
     ID (`**settingsKit read-through views ...**` to `settingsKit`), or to
     `tooling` for a record of kind "repository tooling" or "test support";
     any record it cannot map stops the run and is named. Without `--write`
     it prints the plan: each record, its lines, its target file.
   - Each `docs/records/<package>.md` gets a title, then the records in
     their ROADMAP order under the heading of the phase or package letter
     they came from, byte for byte.
   - ROADMAP keeps its prose and gains, per phase and package, a table: record
     title, package, status (the record's point 9, first clause), link.
   - A check in repository validation: every `docs/records/*.md` file is
     linked from ROADMAP, and each record there has points 1 to 9.
5. Ownership: each package owns its record file; ROADMAP owns the table.
6. Performance and memory: no runtime effect, no bundle change. ROADMAP
   shrinks from 5,123 lines to an expected 400 to 600; a new record touches
   one package file and one table row.
7. Tests (`tooling/tests/test_split_roadmap.py`): a fixture ROADMAP with
   records of each kind; the mapping; an unmappable record stops the run;
   the moved text equals the original byte for byte (concatenating the
   record files and the remaining ROADMAP reproduces every original line);
   the table rows; the validation check.
8. Docs: `docs/TOOLING.md` (the script). Shared files, after the run:
   `docs/ROADMAP.md`, `docs/README.md` (a link to `docs/records/`).
9. Status: implemented 2026-11-15 and run: the records live in
   `docs/records/`, one file per package.

**Package O records: core and parts for SchedulerKit, EventKit, CodecKit and CommKit**

Status: implemented 2026-11-15; each record's point 9 gives the results.

Four records under ADR 0001 (a Kit is a core file plus optional parts), one
per Kit, followed by the shared contract they all follow and the measured
footprint of the sets an addon actually embeds. The records go into
`docs/ROADMAP.md`, package O, after the codecKit record.

**Measurements behind the records**

Host Lua 5.1.5, 64-bit, debug information kept as the client keeps it, the
shared fake client (`tooling/bench/lua/BenchHost.lua`), the memory
diagnosis's `exec.lua` (one process per set, string table pre-grown, resident
heap after a full collection). "Today" is the working tree at `ad2626a`.
"Core alone (measured)" is a research copy of each file with the part's
sections removed and replaced by stubs, loaded in the same set; the real core
adds the part interface, `HasPart` and the fix-it stubs, priced at 1 to 3 KB
per Kit. A part's own figure is today minus the measured core; where one
section becomes several parts, the measured total is split in proportion to
the live prototype bytes of each subsection (`Bytecode.lua` pricing).
Ace3 figures are the pinned bench copy (`ACE3_COMMIT` `5e2e0d3b`) measured
the same way.

| Kit | Today | Core alone (measured) | Parts (resident when loaded) | Core + every part (expected) | Ace3 it replaces |
|---|---:|---:|---|---:|---|
| SchedulerKit | 176.0 KB | 89.9 KB | Coalescing ≈ 51 KB, Lanes ≈ 24 KB, Watch ≈ 12 KB (86.1 KB measured together) | ≈ 179 KB | AceBucket 9.6 KB (the Coalescing part's counterpart); the core has none (AceTimer's role is TimerKit's) |
| EventKit | 106.3 KB | 80.9 KB | Coalescing 25.4 KB today, ≈ 42 KB once it times itself by TimerKit (eventKit record) | ≈ 124 KB | AceEvent 6.7 KB + CallbackHandler 10.2 KB = 16.9 KB |
| CodecKit | 148.5 KB | 91.8 KB | Compression 56.7 KB, plus 59.0 KB of DEFLATE tables built on the first Lua compression or decompression (lazy since revision 9) | ≈ 150 KB (≈ 209 KB after a Lua compression) | AceSerializer 11.5 KB; compression has no Ace3 counterpart |
| CommKit | 213.9 KB | 180.2 KB | SyncSet 33.7 KB; ChatThrottle ≈ 24 KB (new, priced at 44 KB per 1,000 lines for about 550 lines) | ≈ 216 KB without ChatThrottle, ≈ 240 KB with it | AceComm 14.1 KB + ChatThrottleLib 32.7 KB = 46.7 KB; SchedulerKit no longer required (commKit record) |

The sets an addon embeds (resident, KB, one process each). "Split" is the
cores only; "split + drivers on TimerKit" adds the two TimerKit changes in
the eventKit and commKit records below. The comm rows without SchedulerKit
were measured with a research copy of CommKit that loads without it; the
TimerKit driver is priced at about 2 KB on top. The bucket row's EventKit
part is priced: today's 25.4 KB plus about 17 KB for its own TimerKit timing
(the prototypes of SchedulerKit's coalesce and a debounce without arguments,
`leading` or `maxWaitSeconds`, scaled by the measured resident-to-prototype
ratio of 1.29).

| Set | Today | Split | Split + drivers on TimerKit | Ace3 | Ratio today → split → with TimerKit drivers |
|---|---:|---:|---:|---:|---|
| Smallest useful: Registry, SignalKit, EventKit, LifecycleKit, TimerKit | 353.5 | 328.2 | 328.2 | 53.8 (LibStub, CallbackHandler, AceAddon, AceEvent, AceTimer) | 6.6× → 6.1× → 6.1× |
| AceBucket counterpart: the smallest set plus `Coalesce` (today and split: SchedulerKit and its Coalescing part with EventKit's part; with TimerKit: EventKit's part only) | 529.8 | ≈ 495 | ≈ 370 | 63.4 (plus AceBucket) | 8.4× → 7.8× → 5.8× |
| Events + timers + comm: the smallest set plus PoolKit and CommKit (and SchedulerKit, which CommKit requires until its driver runs on TimerKit) | 824.3 | 679.2 | ≈ 589 (587.2 measured) | 100.5 (plus AceComm and ChatThrottleLib) | 8.2× → 6.8× → 5.9× |
| The same with HookKit (outside traffic charged) and CodecKit (serialisation) | 1,035.3 | 833.7 | ≈ 744 (742.0 measured) | 129.8 (plus AceHook and AceSerializer) | 8.0× → 6.4× → 5.7× |

Said plainly: the split and the two TimerKit drivers save a typical addon
25 KB (event and timer set), 160 KB (buckets), 235 KB (comm set) and 290 KB
(comm set with serialisation); an addon that embeds a part pays what it pays
today plus a few KB. None of it brings these sets near Ace3: the cores
themselves hold about 6 times Ace3's resident memory, because of code volume
in every core (SignalKit 87 KB, PoolKit 79 KB, LifecycleKit 71 KB), not of
optional features. The levers that act on the cores are the memory
diagnosis's fix 3 (shared helper families, −100 to −145 KB over the set),
fix 6 and fix 10, outside these records.

The smallest-set figure is higher than the memory diagnosis's 333 KB because
package O's first records added method-name callbacks and scope reopening to
SignalKit, EventKit, TimerKit and LifecycleKit.

**The contract every split here follows**

This is ADR 0001 applied to Kits that existed as whole files. It is the same
for the four records and should be the same for every Kit split in package O.

- **Layout.** `src/<Facade>.lua` and `src/parts/<Facade>-<Part>.lua`, each
  part declared under `parts` in the manifest with `revision` 1.
- **What stays on the facade.** Every member a part provides keeps its name
  on the facade and on the shared prototypes even when the part is not
  loaded. Without the part it is a stub that raises at the caller's line:
  `SchedulerKit:Debounce is in SchedulerKit's Coalescing part, which is not
  loaded: add schedulerKit\parts\SchedulerKit-Coalescing.lua to embeds.xml
  after schedulerKit\SchedulerKit.lua` (AddonKit's wording). Keeping the
  member means the public-surface check of every other copy, which tests
  for these members by `type(...) == "function"`, still accepts the facade.
  Limits, statistics keys and reason codes of a part stay in the core's
  tables, so `SetLimits`, `GetLimits` and `GetStatistics` keep one shape
  whichever parts are loaded.
- **`Kit:HasPart(name)`**, new on each split facade: `true` when the named
  part is installed. Other Kits that use a part optionally test this, never
  `type(Kit.Member) == "function"`, which a stub satisfies.
- **The part interface.** The core publishes, in its state, `parts` (part
  name to `{ revision = n }`), `helpers` (the core functions a part calls,
  read through the table at call time on cold paths, so an upgraded core
  serves a part loaded before it) and `partInterface` (an integer, 1 now).
  Entries are only added; a core that must change one adds a new entry and
  raises `partInterface`. A part checks `partInterface` at file scope and
  raises `MoltenCodes <Facade> part <Part> requires <Facade> API 1 to be
  loaded first` when its core is missing or older than the interface it
  needs. The core's own hooks into a part (closing a scope's members, a lane
  job ending) are dispatch entries the part fills; the core's defaults do
  nothing, which is exact, since no member of an absent part can exist.
- **Revisions.** Highest wins, per Kit and per part. A part file of an equal
  or lower revision than the installed one returns without touching
  anything.
- **Upgrading from the last whole file** (the shared rule for every split in package O). The previous revisions were whole
  files. A split core that takes over from one upgrades in place, as today.
  When its part is loaded too, the part adopts the whole revision's live
  objects (same layouts, which these records do not change) and every handle
  keeps working. When the part is not loaded, the core cannot run that
  code: it closes the live objects of the absent part at takeover, installs
  the stubs, and reports once through `geterrorhandler()` which part to
  embed. A whole revision loaded after a split core is the lower revision
  and yields, so its addon gets the stub's error. Both cases need one addon
  that embeds a whole development copy beside another that embeds a split
  core without the part. No revision of these Kits was ever published (no
  tag, no release), so no addon in the wild can be in that position; the
  specs pin both behaviours so they stay loud and safe.

