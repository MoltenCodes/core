# clientKit records

Moved from `docs/ROADMAP.md` (Package B planned Kits — the nine points).

## clientKit

**clientKit** — facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1.
2. Purpose: one place that answers "which client is this and what can it
   do", and normalised shims for the few host calls whose name or shape
   differs between flavours. Non-goals: gameplay data, range or spell logic,
   anything a domain library should own; no polyfill of missing features.
3. Dependencies: registry API 2 only.
4. Surface: `GetFlavor()` (`"mainline" | "mists" | "tbc" | "classic"`),
   `GetBuild()` and `GetInterfaceNumber()`, `IsAtLeast(interfaceNumber)`,
   `Has(capability)` over a fixed, documented capability table
   (`C_AddOns`, `C_Spell`, `C_Item`, `C_Timer`, `secretValues`,
   `restrictedFrames`, `spellbookApi`, ...), `IsSecret(value)`,
   `CanAccessFrame(frame)`, `IsEventValid(eventName)`, and shims
   `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo`, `GetItemInfo`
   returning one shape on every flavour. Every flag reads `false` when the
   host does not expose the feature; an absent `WOW_PROJECT_ID` yields the
   most conservative flavour, never "everything true".
5. Ownership: stateless facade; the capability table is computed once at
   bootstrap and re-read on upgrade. Nothing to tear down.
6. Performance: each probe is a table read after bootstrap; shims add one
   call. No allocation after bootstrap, except the legacy `GetSpellInfo`
   shim, which builds the result table modern clients return ready made.
7. Tests: one fixture profile per supported flavour (four), the
   `WOW_PROJECT_ID` absent case, the secret-value and forbidden-frame stubs,
   `IsEventValid` for a known, an unknown and an invalid name, upgrade.
8. Docs: README, API.md with the capability table and the shim shapes,
   EMBEDDING.md host-requirements row, CHANGELOG.
9. Status: implemented (package B1, 0.1.0).

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## clientKit deprecation warnings (W13)

**clientKit deprecation warnings (W13)** — an addition to facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1 (additive),
   version 0.3.0, implementation revision 6.
2. Purpose: a Kit marks one of its own things as deprecated (an API
   generation, a facade method, an option) with a replacement and a
   removal plan, and the addon that still uses it is told once per call
   site (or once per addon, when the Kit knows the addon) for the
   session, never once per call. This is the part of W13 Registry's spent
   line budget leaves to ClientKit, as `GetManifest` was; Registry is not
   touched. A Kit finds ClientKit through `Registry:Find("clientKit", 1)`
   at its first deprecated call and checks for `Deprecate`, so no Kit
   gains a load-order edge and a session without ClientKit, or with an
   older revision, simply reports nothing. Nothing is raised unless a
   developer asks for it. Today no Kit has anything deprecated (no
   `docs/API.md`, CHANGELOG or README marks a member deprecated), so the
   capability ships with its specs and documentation and its first
   consumer is the first Kit that deprecates. Non-goals: Blizzard's
   deprecated globals (`Blizzard_Deprecated*`, switched by the
   `loadDeprecationFallbacks` CVar), wrapping or replacing the deprecated
   function for the Kit, removal scheduling, persisting reports across
   sessions, Registry's data-package kinds.
3. Dependencies: unchanged, registry API 2. Host requirements:
   `debugstack` names the call site (all three flavours; without it the
   site is unknown and reports fall back to once per addon given, else
   once per deprecation); `geterrorhandler` carries the report (`print`
   without it). The `debug` library is not used: the Retail client
   publishes no `debug` global.
4. Surface: `ClientKit:Deprecate(spec)` → reporter, with `name` (what is
   deprecated, for example `"TimerKit:After"`, `"EventKit API 1"`,
   `"SettingsKit:Open option legacy"`), `removal` (required: when or in
   what it goes, for example `"TimerKit API 2"`) and `replacement`
   (optional); a second `Deprecate` under the same name returns the same
   reporter with the newer spec's text, so an upgraded Kit re-declaring
   at load adds nothing. `reporter:Warn(level?, addonName?)`: `level` as
   for `error` (default 2, the caller of the Kit's method); `addonName`,
   when the Kit knows the consuming addon (a scope's owner), makes the
   addon the once-key and skips `debugstack` after the first report.
   `ClientKit:GetDeprecationReports()` → fresh array of fresh rows
   `{ name, replacement, removal, addon, site }` in report order, for a
   developer listing what this session used. `ClientKit:SetDeprecationMode(mode)`
   and `GetDeprecationMode()`, one switch for the session: `"report"`
   (default: record and hand to the error handler), `"silent"` (record
   only), `"raise"` (development: raise the report at the consumer's line
   on every call, unrecorded). `SetLimits{ maxDeprecations, maxReports }`
   / `GetLimits()`. Report text: `MoltenCodes: TimerKit:After is
   deprecated; use TimerKit:Delay. Removal: TimerKit API 2. Called from
   MyAddon (Interface/AddOns/MyAddon/Core.lua:42).` The addon is the
   folder after `Interface/AddOns/` in the `debugstack` frame (`/` or
   `\`, bracketed or `[string "@..."]` form), or the `addonName` given,
   or `"unknown"`.
5. Ownership: reporters and their once-keys live for the session in
   ClientKit's state, keyed by name, with the reporter prototype in state
   so an upgraded revision rewrites `Warn` in place. Reports live until
   the session ends; none is saved. A Kit calls `Warn` before it changes
   any state, so `"raise"` leaves the Kit as it was. The mode is shared by
   every addon in the session and is a developer switch, documented as
   such.
6. Performance and memory: nothing runs, and nothing is allocated beyond
   four empty state tables, until a Kit calls `Deprecate`; a Kit that
   deprecates nothing costs nothing. `Warn` on a deprecated path: one
   mode comparison, then with `addonName` one table lookup after the
   first report, otherwise one `debugstack(level + 1, 1, 0)` and one
   lookup of the frame line in the reporter's once-table (no string is
   concatenated before the lookup). Past `maxReports` every reporter stops
   resolving sites and answers after the one comparison. `maxDeprecations`
   defaults to 128 with a ceiling of 1024; a `Deprecate` past it returns
   one shared inert reporter and reports the cap once, never raising at a
   Kit's load. `maxReports` (recorded reports and once-keys for the
   session) defaults to 256 with a ceiling of 4096. No `UNBOUNDED` for
   either.
7. Tests: a report through the error handler once per call site and once
   per addon, a second call from the same site silent, two sites two
   reports, the addon named from a `debugstack` frame in each written form
   and `"unknown"` otherwise, a host without `debugstack` and without
   `geterrorhandler`, the three modes (raise at the consumer's line with
   an explicit level), `GetDeprecationReports` rows and their isolation, a
   re-declared name returning the same reporter with the new text, both
   limits and the inert reporter, the optional-Kit pattern through
   `Registry:Find` with ClientKit absent and with revision 5, secret
   values (spec fields, `addonName`, a secret frame line), receiver and
   argument errors at the caller, an upgrade from revision 5 keeping
   manifests and adding the deprecation state, manifest. A client suite
   addition to `MoltenCodesTest_ClientKit` on Retail, Mists of Pandaria
   Classic and Classic Era: the `debugstack` frame text logged and the
   suite's own addon named in the report.
8. Docs: API.md (a Deprecations section with the Kit-side pattern, the
   modes, the report text; Limits rewritten, since ClientKit gains
   `SetLimits`), CHANGELOG, README, tests/README; ARCHITECTURE's clientKit
   paragraph; package I's deferred item and the clientKit checkbox.
9. Status: implemented 2026-11-15 under core decision 16, 0.3.0, revision
   6, 44 new specs (176 in all); the client suite addition
   (`tests/client/MoltenCodesTest_ClientKit`, part `deprecations`) is
   written and has not been run in a client. Deviations: `debugstack` is a
   guarded local read at every load rather than kept in `state.host` (the
   flavour gate cannot follow a value stored in a table); the deprecation
   state is one `deprecation` table holding a few small tables; the
   one-time `maxDeprecations` notice is not sent in `"silent"` mode; the
   Kit-side pattern remembers a missing ClientKit, so one that loads after
   a Kit's first deprecated call is not used for that deprecation.
   Reviewed 2026-11-15 under core decision 17: 0.3.1, revision 7
   (`IsAtLeast` refuses a secret interface number at the caller before
   comparing it).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## clientKit probe fallback and value descriptions

**clientKit probe fallback and value descriptions** — a fix to facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1 (unchanged),
   version 0.3.2, implementation revision 8 (from 0.3.1, revision 7).
   Patch.
2. Purpose: bring ClientKit to the secret-probe rule every Kit follows, and
   fix a `tostring` on caller values.
   - The secret-probe rule: `bindHostFunctions` (`ClientKit.lua:703`)
     already resolves `issecretvalue` at load, but without a fallback. When
     it was absent at load, `IsSecret`, `validateNotSecret` and
     `describeValue` (`:751`, `:779`, `:874`) now look it up on each call,
     so a probe installed later is honoured. `Has("secretValues")` stays
     the load-time answer it documents.
   - Defect: `describeValue` (`:750`) ends in `tostring(value)`, so a table
     with `__tostring` given as a capability name (`Has`), a limit key
     (`SetLimits`, `:1716`) or a key written to a manifest snapshot
     (`:1067`) runs the caller's code inside ClientKit. It now names a
     table, function, thread or userdata by type (`<table>`), and keeps
     `%q` for strings and `tostring` for numbers, booleans and `nil`.
   - Decision 19b: none applies. ClientKit's secret checks guard arguments
     and the client's own answers. The manifest snapshot's `__newindex`
     describes the key it refuses, and that check stays until a client
     suite shows that a secret key is refused on assignment before
     `__newindex` runs.
3. Dependencies: unchanged (registry API 2).
4. Surface: unchanged methods. Messages that named a table by its address
   now name it `<table>`. `IsSecret` honours a probe installed after load.
5. Ownership: unchanged; the host table in state keeps the load-time
   binding. An in-place upgrade from revision 7 rebinds as today.
6. Performance and memory: with the probe present at load (every client
   with secret values), nothing changes. Without it, each check makes one
   `rawget(_G)` more, about 14 ns. No memory change.
7. Tests, failing first for the defect: a `__tostring` table given to
   `Has`, as a `SetLimits` key and as a manifest field name, each refused
   naming `<table>` with the metamethod never run; the probe installed
   after load honoured by `IsSecret`; in-place upgrade from revision 7.
   Client suite (`tests/client/MoltenCodesTest_ClientKit/`, never run
   here): assigning `manifest[secretwrap("x")] = 1` either raises at the
   assigning line before `__newindex` runs or is refused with
   `<secret>` (the suite records which, for decision 19b).
8. Docs: `docs/API.md` (value descriptions in errors, the probe rule),
   `CHANGELOG.md` 0.3.2, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.3.2,
   revision 8, 4 specs (182); the client suite records whether a secret key is
   refused on assignment before `__newindex`.

