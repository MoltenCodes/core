# addonKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## addonKit

**addonKit** — facade `AddonKit`, entry point `MoltenCodes:For(...)`

Status: recorded 2026-11-15 under core decisions 18 and 19; code follows.

Basis: the decision 18 usability diagnosis (the ten-task comparison and a
prototype entry point run against the fake client) and the repository's
Registry, ModuleKit, SettingsKit, SchemaKit, CommandKit, PanelKit,
LauncherKit and BrokerKit references.
Ace3 `AceAddon-3.0.lua:493-579` (module enable and disable order) read at
`ac3d122`, BSD-style licence (`LICENSE.txt`), for behaviour only; nothing
copied.

1. Package `addonKit`, facade `AddonKit`, API generation 1, version 0.1.0,
   implementation revision 1. Optional: no Kit depends on it, and an addon
   that does not embed it loads nothing of it and pays nothing.

2. Purpose: one obvious way in for addon authors, so a first addon takes
   the lines and concepts Ace3 takes or fewer, while every guarantee of the
   Kits underneath stays. It holds no behaviour of its own beyond lookups,
   defaults and fix-it errors: every call it makes is a documented API 1
   call of another Kit, so validation, bounds, secret checks and ownership
   stay the Kits'.

   - **Entry point.** `local MC = MoltenCodes:For(...)` in every file of an
     addon returns that addon's facade (the same table in every file).
     `MC.TimerKit`, `MC.EventKit` and so on resolve on first read through
     `Registry:Find(packageId, generation)` and are cached on the facade
     with `rawset`, so a later read is a plain field read. `MC.S` is
     SchemaKit; `MC.Registry` is `MoltenCodes.Registries[2]`.
     `MC.addonName` is the folder name. The second value of `...` (the
     addon's private table) is accepted and ignored, so `...` can be passed
     as it is.
   - **Where `For` lives (decided here).** AddonKit installs `For` on the
     shared `MoltenCodes` namespace, and the same function is
     `AddonKit:For`. Registry is not touched. Reasons: Registry sits at its
     1000-line budget and its header says new behaviour moves into a
     package of its own; Registry is loaded by every addon that embeds any
     Kit, so a catalogue there would cost addons that never use it; and the
     catalogue changes with every new Kit, which would put Registry
     revisions on every Kit addition. The namespace key is claimed by a
     small protocol: AddonKit writes `MoltenCodes.For` only when it is
     absent or is the stable entry function recorded in `AddonKit._state`;
     an upgraded revision keeps that same function, which dispatches through
     the state, so the newest revision serves every addon. Any other value
     is left alone and reported once through `geterrorhandler()`;
     `MoltenCodes.Registries[2]:Get("addonKit", 1):For(...)` then remains
     the documented one-line alias. The key is reserved in Registry's
     documentation (text in the report).
   - **Generations stay explicit.** The catalogue maps each facade name to
     its package ID and the API generation AddonKit API 1 hands out. An
     entry's generation never changes inside AddonKit API 1; new Kits only
     add entries, and a Kit's next generation is reached with
     `MC:Use("TimerKit", 2)` (before the first read of that name; a pin
     after a read at another generation raises) or by a later AddonKit
     generation. An addon therefore never receives a contract it was not
     written against, even when another addon embeds a newer AddonKit
     revision. A spec reads every `package.manifest.json` and fails when the
     catalogue misses a package or names a generation that does not exist,
     and fails when a published entry's generation changed, against a
     recorded baseline in the spec.
   - **Fix-it errors at the author's line.** A facade name that is not in
     the catalogue raises `MoltenCodes has no Kit named <name>; did you
     mean MC.TimerKit?` (case-insensitive match, a missing `Kit` suffix, or
     an edit distance of at most 2 over catalogue and method names, so a
     misspelt method gets `did you mean MC:Database?`). A Kit that is not
     loaded raises `MyAddon uses MoltenCodes TimerKit (API 1), which is not
     loaded. Add timerKit\TimerKit.lua to embeds.xml after the files it
     needs, or rebuild embeds.xml with the build tool (docs/EMBEDDING.md,
     "Load order")`; the `generation_mismatch` and `retired` reasons of
     `Find` get their own wording. A write to the facade (`MC.db = x`)
     raises `the MC facade holds Kits and helpers only; keep your fields on
     your addon object`. A dot call (`MoltenCodes.For(...)`, `MC.Database(...)`)
     raises with the colon form. Helpers that call another Kit run the call
     under `pcall` and raise its message again at the author's line with
     AddonKit's own position removed, so the line printed is always the
     author's.
   - **Addon object.** `MC:NewAddon(definition?)` is the module `"Main"` of
     the addon's ModuleKit container (`ModuleKit:ForAddon(name)
     :CreateModule("Main", definition)`), not a wrapper: `OnInitialize` runs
     at the loaded phase, `OnEnable` at ready, `OnDisable` on `Disable()`
     and at logout, and `self.scope.Events`, `.Timers`, `.Hooks`,
     `.Commands`, `.Comm`, `.Jobs`, `.Messages` own what the addon
     registers, released on disable. A second `NewAddon` raises with the fix
     (`MC:GetAddon()` or `MC:NewModule(name)`). `MC:NewModule(name,
     definition?)` creates a module that declares `DependsOn("Main")`, so,
     as AceAddon does (`AceAddon-3.0.lua:516-579`), the addon initializes and
     enables before its modules and disabling it disables them; the name
     `"Main"` is refused. `MC:GetAddon()` and `MC:GetModule(name)` answer
     the objects from other files. No mixin methods are added: ModuleKit's
     module metatable stays ModuleKit's, and the addon object is a plain
     receiver, so the method-name callbacks of decision 19c work on it as
     they come from the runtime Kits (for example
     `self.scope.Events:Connect("BAG_UPDATE", self, "OnBagUpdate")`, in
     whatever form the runtime Kits' records fix). The guide, cookbook and
     specs use that form where the loaded revisions support it, detected
     from each Kit's documented capability, and the closure form otherwise.
   - **Database.** `MC:Database(savedVariable, defaults, options?)` opens a
     SettingsKit database from an AceDB-style defaults table, the schema
     inferred: a boolean, number or string becomes `optional(type,
     value)` (strings get `max = 4096`; numbers are not made integers, so
     `scale = 1` accepts 1.5); a table becomes an optional record; `{}`
     becomes a bounded free-form bag (`map` of string or number keys to
     `any`, `max = 1024`); `["*"]` becomes a `map` whose values read the
     wildcard's defaults, as AceDB's do; an array of one primitive type
     becomes an `array` of that type; a SchemaKit node or sealed schema
     written inline passes through, made optional when it is not. Two
     shorthands make ranges and enums one call: `MC.Range(min, max,
     default)` and `MC.Enum(values, default)` return the optional nodes.
     The top-level keys are SettingsKit's scopes (`profile`, `global`,
     `char`, `realm`, `class`, `faction`); `options` is `SettingsKit:Open`'s.
     It refuses, with the fix: a call before the addon's `ADDON_LOADED`
     (`MyAddon opened MyAddonDB before ADDON_LOADED; open it in
     OnInitialize, after the client restored it`), through LifecycleKit's
     `IsLoaded`; an AceDB scope SettingsKit does not have
     (`factionrealm`, `locale`), naming the six it has; `["*"]` beside named
     keys and `["**"]` (no SettingsKit form: the message says to move the
     named keys or write a schema node); a `nil`-shaped or function default;
     a non-string key in a record. A second call for the same saved
     variable answers the same database when given the same defaults table
     and raises otherwise (SettingsKit refuses a second schema for an open
     name; the inferred one would always be new).
   - **Options.** `MC:Options(tree, { db, slash, title })` defines the tree
     with OptionsKit (`db` for `bind`), registers it with PanelKit and, with
     `slash`, registers a CommandKit command on the addon's scope that opens
     the panel; it returns the panel. Unlike the prototype it does not drop
     CommandKit's refusals: `"taken"`, `"emote"` and `"full"` raise at the
     author's line with the fix (`/myaddon is already used by another addon
     or a chat command; pass another slash name to MC:Options`). The command
     is registered first, so a refusal leaves no tree and no panel; a
     failure of `Define` or `Register` after it unregisters the command
     before raising.
   - **Launcher.** `MC:Launcher(definition, db, field?)` creates a BrokerKit
     object named after the addon (`type = "launcher"` unless given),
     registers a LauncherKit button whose storage is `db.profile[field]`
     (`field` defaults to `"minimap"`) and refreshes it on
     `db:OnProfileChanged`; it returns the launcher. It checks with
     `db:Validate` that the profile declares the field and otherwise raises
     `declare minimap = MC.LAUNCHER_DEFAULTS in defaults.profile`.
     `MC.LAUNCHER_DEFAULTS` is LibDBIcon's three fields (`hide = false`,
     `lock = false`, `minimapPos = 225`), a fresh table per facade so one
     addon editing it never changes another's.
   - Non-goals: Ace-style mixins (`self:RegisterEvent`) on the addon
     object, a second options or database implementation, LibStub
     emulation (BridgeKit's), generating `embeds.xml` (the tooling's
     F6), and strict module scopes (a ModuleKit addition, below).

3. Dependencies: registry API 2, required, and nothing else required.
   Optional, found at call time through `Registry:Find` and declared under
   `optionalDependencies` (API 1 each): moduleKit and lifecycleKit (addon
   object, database gate), schemaKit and settingsKit (database), optionsKit,
   panelKit and commandKit (options), brokerKit and launcherKit (launcher).
   Every other Kit is reached only when the author reads `MC.<Kit>`. A
   helper whose Kit is missing raises the same "not loaded" message as a
   read. No host API is called by AddonKit itself, so the flavour gate has
   nothing to guard; the Kits it calls guard their own.
   Parts (decision 18a): the core file `src/AddonKit.lua` holds the
   namespace entry, the catalogue, the lazy lookup, the errors, `Use` and
   the addon object. Two part files hold the rest: `Database.lua` (schema
   inference, `Database`, `Range`, `Enum`) and `Composition.lua`
   (`Options`, `Launcher`, `LAUNCHER_DEFAULTS`), in the runtime
   subdirectory layout `docs/PACKAGE_MANIFEST.md` describes; the exact
   directory and how a part is declared optional follow the Kit parts
   format (the tooling record above). A part installs its methods into
   `AddonKit._state.parts` under its own revision check, so an upgraded
   part takes over. A method of a part that is not loaded raises
   `MC:Database is in AddonKit's Database part, which is not loaded: add
   addonKit\...\Database.lua to embeds.xml`. Until the tooling can mark
   parts optional, the build loads them always, as runtime subdirectories
   are loaded today.

4. Surface:
   - `MoltenCodes:For(addonName, ...)` and `AddonKit:For(addonName, ...)`
     → facade (`MoltenCodesFacade`); `addonName` a non-empty string, not
     secret, raised at the caller otherwise.
   - Facade fields: `MC.addonName`, `MC.<Kit>` for every catalogue name,
     `MC.S`, `MC.Registry`, `MC.LAUNCHER_DEFAULTS` (Composition part).
   - Facade methods: `MC:Use(facadeName, generation)`; `MC:NewAddon(definition?)`,
     `MC:NewModule(name, definition?)`, `MC:GetAddon()`,
     `MC:GetModule(name)`; `MC:Database(savedVariable, defaults, options?)`,
     `MC.Range(min, max, default)`, `MC.Enum(values, default)`;
     `MC:Options(tree, options)`, `MC:Launcher(definition, db, field?)`.
   - Package facade: `AddonKit:For`, `AddonKit:GetCatalogue()` (a fresh
     `{ [facadeName] = { packageId, api } }` copy, for tools and
     diagnostics), `AddonKit:SetLimits{ maxFacades }` / `GetLimits()`,
     `API`, `REVISION`. `maxFacades` (addons with a facade in the session)
     defaults to 256 with a ceiling of 4096 and no `UNBOUNDED`; past it
     `For` raises with the `SetLimits` fix.
   - LuaCATS: `MoltenCodesNamespace` gains `For`; `MoltenCodesFacade` has
     one `---@field <Kit> <Kit>` per catalogue entry (the Kits' own class
     names, all present today), the methods above with full parameter and
     return types (`NewAddon` → `AddonKit.Addon`, a `ModuleKit.Module` with
     a `db` field slot; `Database` → `SettingsKit.Database`), so
     lua-language-server completes `MC.TimerKit:ForAddon(...)` and flags
     a misspelt `scope:After`, as the language-server probe of the
     diagnosis measured. The field block
     disables `undefined-doc-name` locally, because AddonKit's own
     workspace holds only Registry; an addon's workspace holds the Kits it
     embeds.

5. Ownership: the facade of an addon lives for the session in
   `AddonKit._state.facades` (one per addon name, bounded by
   `maxFacades`). It holds cached references to shared Kit tables, which
   Registry's stable-reference guarantee keeps valid across in-place
   upgrades, never a copy. Methods are not cached on the facade: they are
   found through the state's metatable on each call, so an upgraded revision
   serves addons that took their facade earlier. Everything the addon
   object, a database, a panel, a command or a launcher owns belongs to the
   Kit that created it (ModuleKit, SettingsKit, PanelKit, CommandKit,
   LauncherKit) under that Kit's rules; AddonKit keeps one record per
   opened database on the facade (saved-variable name, defaults table,
   database) to answer a repeated `Database` call. An upgraded revision
   takes over the facades, the metatable's `__index` and `__newindex`
   (stable closures in `_state` dispatching through a table), the namespace
   entry and the parts.

6. Performance and memory: no frame, no event, no timer, nothing per frame.
   After the first read, `MC.<Kit>` is one table field read: zero cost per
   call against a hand-written local. Method calls on `MC` go through one
   `__index` function call; they are setup-time calls. Schema inference
   runs once per `Database` call and allocates only the nodes SettingsKit
   needs anyway; the database's own cost is SettingsKit's (and shrinks with
   SchemaKit's sparse nodes). The catalogue is kept compact (one
   string-keyed table of facade name to generation, the package ID derived
   by lower-casing the first letter and the file path built only when an
   error needs it).
   Expected numbers, from the prototype and the diagnosis prototype (host
   Lua 5.1.5, debug info kept, measured 2026-11-15):

   | Measure | Ace3 | MC today | Prototype | AddonKit target (phase 2 measures) |
   |---|---:|---:|---:|---:|
   | Ten tasks, code lines | 62 | 84 | 55 | 55 or fewer |
   | Concepts for the ten tasks | 16 | 25 | 15 | 15 |
   | Resident, entry point and addon object | AceAddon 27.0 KB (+ LibStub 2.6 KB) | 0 (no facade) | 25.6 KB (without inference) | at most 24 KB, core file |
   | Resident, defaults-to-schema | AceDB 33.0 KB | 0 | 4.8 KB | at most 8 KB, Database part |
   | Resident, options and launcher helpers | AceConsole 10.5 KB + AceConfig family | 0 | included above | at most 8 KB, Composition part |
   | Resident, all of AddonKit | 73.1 KB (AceAddon, AceDB, AceConsole, LibStub) | | 30.4 KB | at most 40 KB |
   | Per addon using the facade | | | one table | at most 1 KB plus one field per Kit read |
   | Cost per `MC.<Kit>` read after the first | | | one field read | one field read |

   The prototype's 25.6 KB is mostly its catalogue (three strings and a
   table per Kit); the compact catalogue is what brings the core under the
   target despite the Bootstrap, state validation and limits a real Kit
   adds. Phase 2 measures each file and the per-addon cost with the same
   script and reports them against the rows above. The ten-task line count
   is re-counted with the diagnosis prototype.

   Mistakes a newcomer makes, before and after (messages measured by the
   prototype's specs; phase 2 asserts each):

   | Mistake | MC today | AddonKit |
   |---|---|---|
   | Kit missing from `embeds.xml` | `attempt to index local 'TimerKit' (a nil value)` at first use | names the Kit, the file to add and the rebuild, at the reading line |
   | Misspelt Kit name | `packageName must match ^[a-z][A-Za-z0-9]*$` | `did you mean MC.TimerKit?` |
   | Wrong generation typed | the same `nil` index error | not typed by the author; `Use` checks a pin |
   | AceDB-style defaults passed to the database | refused, schema node required | accepted, schema inferred |
   | Database opened at file scope | no error, saved data lost | raised with the fix |
   | Slash name already taken | `nil, "taken"`, easy to drop | raised with the fix |
   | Minimap storage not declared | write refused and reported later | raised at `MC:Launcher` with the fix |

7. Tests (Busted, `packages/addonKit/tests/`, coverage at least 96%):
   Bootstrap (first load, same revision, in-place upgrade from a revision 1
   copy keeping facades, cached Kits, the namespace entry and the parts; a
   foreign `MoltenCodes.For` left alone and reported; a newer copy loaded by
   a second addon serving the first addon's facade); Manifest (package,
   API, revision, optional dependencies); Catalogue (against every
   `package.manifest.json`, and the generation baseline); Arguments (every
   public call's argument errors and their levels, the `__index` and
   `__newindex` errors at the reading or writing line, dot calls, secret
   values first on every argument); Lookup (lazy resolution, the cache,
   every `Find` reason, did-you-mean for Kits and methods, `Use` before and
   after a read, `maxFacades`); Addon (NewAddon, NewModule with the Main
   dependency and Ace's order, GetAddon, GetModule, a second NewAddon, the
   `"Main"` name refused, method-name callbacks through the scope when the
   runtime Kits provide them); Database (every inference rule, `"*"` reads,
   `{}` bags, arrays, inline nodes, `Range`, `Enum`, wrong-type and
   out-of-range writes refused with SettingsKit's message, the
   `ADDON_LOADED` gate, unsupported scopes and wildcards, the repeated
   call); Options (panel, slash command opening it, each refusal raised,
   nothing left behind on a refusal or a later failure); Launcher (button,
   storage, profile switch refresh, the undeclared-field error); Parts (a
   missing part's message); TenTasks (the prototype's ten-task smoke flow
   over a fixture addon, every task checked); Guide (the final code of the
   getting-started guide runs on the fake client, and each guide snippet
   tagged with a fixture file must equal it; pending until the guide is
   placed in `docs/`); LuaLS (the fixture addons pass
   `lua-language-server --check` at Warning with no diagnostic, and a
   misspelt scope method in a probe file is flagged). A client suite
   `tests/client/MoltenCodesTest_AddonKit` (.toc, suite, EXPECTED.md),
   never run: `MoltenCodes:For` in the real client, the error level through
   `__index` (verified only on host Lua so far), the database gate against
   the real `ADDON_LOADED` and saved variable, the panel opened by the
   slash command, the minimap button placed and kept across a profile
   switch.

8. Docs: `packages/addonKit/README.md` with a "First addon in 10 minutes"
   section (the `.toc`, `embeds.xml`, the eight-line addon, then database,
   options, slash command and launcher, each a step) and a migration table
   from AceAddon-3.0, AceDB-3.0 defaults, AceConfig with AceConsole and
   LibDBIcon-1.0; `docs/API.md`; `CHANGELOG.md`; `tests/README.md`;
   `INTERNALS.md` (state, dispatch, the namespace protocol, parts). Drafts
   for the shared docs:
   `GETTING_STARTED.md` (about 200 lines, ending in exactly the TenTasks
   fixture, every snippet run by the Guide spec) and `COOKBOOK.md` (one
   5-to-15-line recipe per common task: the ten tasks plus bucketed events,
   a window, a confirmation dialog, a tooltip, migrations, spec profiles,
   each linking to the Kit's API). Text for the shared documents: ROADMAP
   placement of this record, ARCHITECTURE's package list, EMBEDDING rows,
   `packages/README.md` row, the README hero snippet and link,
   `docs/README.md` map entries, MIGRATING_FROM_ACE3 "Before you start",
   `meta/MoltenCodes.lua` (`For` on the namespace class), the coverage
   floor, spell words, and a sentence for `registry/docs/API.md` reserving
   the `For` key (Registry's package).

9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.1.0,
   revision 1, parts Database and Composition revision 1, 72 specs (98.0%
   line coverage); the client suite
   (`tests/client/MoltenCodesTest_AddonKit`) is written and has not been run
   in a client. Deviations: resident memory measured 40.6 KB (core), 17.7 KB
   (Database), 9.8 KB (Composition), 68.1 KB in all, against targets of 24,
   8, 8 and 40 KB set from a prototype without Bootstrap, state validation,
   limits or suggestions; still below AceAddon, AceDB and AceConsole
   together (70.6 KB, same session). A facade costs about 450 bytes per
   addon. lua-language-server checks calls through the facade, a Kit and a
   database; a call chained straight through the addon object
   (`self.scope.Timers:After`) is not checked, because the addon object
   accepts the author's fields. `docs/GETTING_STARTED.md` and
   `docs/COOKBOOK.md` ship with it, the guide's code checked by a spec.

Settings records (settingsKit, schemaKit, optionsKit, commandKit), basis: the
decision 18 settings and memory diagnoses (prototypes measured against Ace3
in the same host benchmark run, Lua 5.1.5). "Measured" means a prototype
run; "estimate" means priced from measurements, not run.

Client facts used, read 2026-11-15 from Gethe/wow-ui-source
`Blizzard_APIDocumentationGenerated/UnitDocumentation.lua`:

- `UnitNameUnmodified(unit)` → `unitName, unitServer`, both strings, not
  nilable: `live` 12.1.5 (70783) line 2434 (with
  `SecretWhenUnitIdentityRestricted = true`), `classic` 5.5.4 (70631) line
  1456, `classic_era` 1.15.9 (70576) line 1456. Also in this repository's
  `packages/apiKit/metadata/{retail,classic-mop,classic-era}/namespaces.json`.
- `UnitName` on `live` carries `SecretWhenUnitNameIdentityRestricted = true`
  (line 2400).
- warcraft.wiki.gg `API_UnitNameUnmodified` (redirects to `API_UnitName`):
  `UnitName` reports a changed name under effects such as the Lifegiving Seed effect,
  "`UnitNameUnmodified()` is unaffected by this".
- `RegionalUniqueNamesEnabled()` → `bool` exists only on the `forever` branch
  (1.60.1, 70938, line 536); it is absent from `live`, `classic` and
  `classic_era`. WoW Forever (interface 1.60.x) is not in
  `tooling/validation/supported_clients.json`.
- AceDB-3.0 (BSD-style licence, read only, nothing copied): at `5e2e0d3`
  (`AceDB-3.0.lua:263-282`) it keys characters by `UnitNameUnmodified`, and
  between interface 16000 and 19999 by name, surname and ruleset; at the
  current upstream head `ac3d122` the test is `RegionalUniqueNamesEnabled()`
  and the key is `name .. " " .. surname` with the ruleset as realm key.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## addonKit (package O): the module defaults and the created notice on the facade

**addonKit (package O): the module defaults and the created notice on the facade** — a change to facade `AddonKit`

1. Package `addonKit`, facade `AddonKit`, API generation 1 (additive),
   version 0.2.0 (from 0.1.0), implementation revision 2 (from 1). Core
   only; no part changes.
2. Purpose: surface the ModuleKit conveniences of this round where an
   AddonKit author meets them, `MC`, the way AceAddon offers them on the
   addon (`MyAddon:SetDefaultModuleState(false)`). Kept minimal: AddonKit
   only forwards (ADR 0004: a layer over ModuleKit, no behaviour of its own).
   - `MC:SetDefaultModuleState(enabled)`, `MC:SetDefaultModulePrototype(prototype)`
     and `MC:OnModuleCreated(callback | receiver[, methodName])` call the
     addon container's methods of the same names at the caller's line
     (`callAtCaller`), and return what they return.
   - `MC:NewModule(name, definition)` already passes the definition through,
     so the new definition fields `enabledState` and `prototype` work with
     no change; the `"Main"` dependency is still added.
   - The addon object stays on: when the container's default state is
     `false` and `MC:NewAddon()` is called after it, the new `"Main"`
     module's intent is set back to `true` with `SetEnabledState(true)`
     (unless its definition says `enabledState = false`), so an addon whose
     author changed the module default first still enables at login.
     AceAddon's default never applies to the addon object either. A default
     prototype set before `MC:NewAddon()` does apply to `"Main"`;
     the documentation says to set defaults after `MC:NewAddon()`, as in
     AceAddon.
   - A ModuleKit revision without these methods (before 23) is refused at
     the caller: `MC:SetDefaultModuleState needs ModuleKit revision 23 or
     later; update the copy of moduleKit your addon embeds`.
   Non-goals: `MC:FindAddon` (`MoltenCodes:For(name):GetAddon()` and
   `ModuleKit:FindAddon` cover it); an Ace-style `OnModuleCreated` field on
   the addon object (a method-name subscription
   `MC:OnModuleCreated(addon)` after defining `addon:OnModuleCreated` is the
   port).
3. Dependencies: unchanged (registry API 2; moduleKit API 1 optional, found
   lazily as today).
4. Surface: three facade methods added to `CORE_METHODS`; facade LuaCATS
   types updated. Errors: the forwarded ModuleKit refusals at the author's
   line, and the revision refusal above.
5. Ownership: nothing new is held by AddonKit; the container holds the
   defaults and the bus holds the subscription.
6. Performance and memory: about 50 lines, about 2 KB held (AddonKit 42.3 KB
   compiled today); no change on any read path of the facade. Nothing
   per object.
7. Tests: each forwarder (result, error level at the author's line, the
   revision refusal with a ModuleKit stand-in), `MC:NewAddon()` after
   `MC:SetDefaultModuleState(false)` enabling at login while a later
   `MC:NewModule` stays off, a module from `MC:NewModule(name, { prototype =
   ... })`, `MC:OnModuleCreated` seeing a later `MC:NewModule`, the upgrade
   from revision 1.
8. Docs: API.md (facade methods, *Modules*), README (AceAddon rows),
   CHANGELOG 0.2.0, tests/README, GETTING_STARTED-style example in the
   README for a prototype. For the shared files: none beyond the moduleKit
   record's migration rows.
9. Status: implemented 2026-11-15, 0.2.0, revision 2, 79 specs;
   `MC:NewAddon()` keeps the addon object enabled when the module default is
   off.

