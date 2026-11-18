# Documentation

This directory is the entry point for repository-wide documentation.

## Using the framework

- [`GETTING_STARTED.md`](GETTING_STARTED.md) — your first addon in ten minutes with AddonKit.
- [`COOKBOOK.md`](COOKBOOK.md) — short recipes for the tasks addons do most.
- [`EMBEDDING.md`](EMBEDDING.md) is the addon author's guide: `.toc` entries, load
  order, supported Interface numbers, LibStub coexistence, taint, the combat log,
  `/reload` semantics, performance guidance, and the error messages a wrong load
  order produces.
- [`../examples/`](../examples/) contains a complete example addon that is loaded
  and type-checked on every test run.
- [`MIGRATING_FROM_ACE3.md`](MIGRATING_FROM_ACE3.md) moves an addon from Ace3 to the
  Kits library by library: the Ace3 code, the same thing with the Kits, and what
  behaves differently; the data, options and wire tools are BridgeKit's. It
  also covers the libraries that usually travel with Ace3 (LibDataBroker,
  LibDBIcon, LibSharedMedia, LibQTip, LibDualSpec, LibCandyBar,
  LibCustomGlow, LibEditMode, LibRangeCheck, LibGetFrame) and the Blizzard
  systems addons used to reach into (UIDropDownMenu, `StaticPopupDialogs`,
  the settings panel).

## Architecture and contracts

- [`DESIGN_CONSTITUTION.md`](DESIGN_CONSTITUTION.md) defines the principles that package and tooling changes must preserve.
- [`decisions/`](decisions/README.md) records why the framework is built the way it is, one record per decision.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) explains package boundaries, the dependency graph, API generations, embedded package identity, how a Kit bootstraps, the conventions every Kit shares, and each package's place in the graph.
- [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md) defines the canonical machine-readable package metadata contract.
- [`ROADMAP.md`](ROADMAP.md) records what was decided and delivered in each phase, the status of every record, and the standing obligations.
- [`records/`](records/) holds the nine-point records, one file per package and one for repository tooling, each written before its code.
- [`API_KIT_DESIGN.md`](API_KIT_DESIGN.md) is the design of `apiKit`, the flavour-aware wrapper over the WoW addon API (package H, implemented 2026-09-24): namespaces, naming rules, metadata pipeline, outputs and definition of done.
- [`BRIDGE_KIT_DESIGN.md`](BRIDGE_KIT_DESIGN.md) is the design of `bridgeKit`, the Ace3 migration tools (package N, delivered 2026-11-15): the AceConfig adapter, the AceDB importer and the AceComm/AceSerializer wire adapter, with the Ace3 formats they reproduce.
- [`BENCHMARKS.md`](BENCHMARKS.md) compares Kits with the Ace3 libraries that do the same work: the methodology, the in-client runner and the measured host results, regressions included.

## Development workflow

- [`DEVELOPMENT.md`](DEVELOPMENT.md) contains local prerequisites and canonical repository commands.
- [`TESTING.md`](TESTING.md) describes test layers, Busted conventions, and package-aware test orchestration.
- [`../tests/client/`](../tests/client/README.md) holds the real-client tests: the `/mct` harness addon, one test addon per package, and how to install, run and remove them.
- [`TOOLING.md`](TOOLING.md) explains repository tooling, what repository validation checks, coverage, and every CI job and workflow.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) defines contribution expectations, including the LuaCATS annotation rules.
- [`RELEASES.md`](RELEASES.md) describes independent package versioning, the build command, and release artifacts.

## Package documentation

Every publishable package owns its package-specific documentation under `packages/<name>/`.

Current package entry points:

<!-- generated:package-index -->
- [`Registry`](../packages/registry/README.md) — Zero-dependency shared package registration, discovery and in-place revision upgrades.
- [`AddonKit`](../packages/addonKit/README.md) — The single entry point for addon authors: `MoltenCodes:For(...)` with every Kit by name, an addon object over ModuleKit, databases from plain defaults, and one-call options panels and minimap launchers, with errors that say the fix.
- [`ApiKit`](../packages/apiKit/README.md) — The flavour-aware, typed wrapper over the World of Warcraft API (`wow.retail.api`, ...), generated from the client's own documentation tables.
- [`BarKit`](../packages/barKit/README.md) — Status and timer bars on the client's StatusBar, with secret values passed through and pausable countdowns, pooled and bounded.
- [`BindingKit`](../packages/bindingKit/README.md) — Override key bindings in named scopes (commands, button clicks, Lua functions) that never touch the player's own, applied after combat when set during it.
- [`BridgeKit`](../packages/bridgeKit/README.md) — Migration from Ace3: AceSerializer-3.0 text written and read byte for byte, AceConfig-3.0 tables converted to OptionsKit trees, AceDB-3.0 saved variables imported into SettingsKit, AceComm-3.0 spoken through CommKit.
- [`BrokerKit`](../packages/brokerKit/README.md) — LibDataBroker-compatible data objects: typed attributes as plain fields, per-attribute change signals and a two-way LibDataBroker-1.1 bridge.
- [`CacheKit`](../packages/cacheKit/README.md) — Bounded LRU and TTL caches, memoisation, negative entries, lazy namespaces, bounded queues and snapshots with diffs.
- [`ClientKit`](../packages/clientKit/README.md) — Client flavour, build floor, probed capability flags, secret-value and frame-access probes, and shims with one shape per host call.
- [`CodecKit`](../packages/codecKit/README.md) — Serialise, compress and channel-encode values behind a self-describing header; decoding never raises.
- [`CommandKit`](../packages/commandKit/README.md) — Slash commands with hyperlink-aware parsing, generated usage, schema-checked arguments, sinks, completion and an OptionsKit command line.
- [`CommKit`](../packages/commKit/README.md) — Addon messaging of any length: a chunk protocol with bounded reassembly, refusing priority queues, a session bandwidth budget and sync sets.
- [`CompatKit`](../packages/compatKit/README.md) — Versioned shims with a host opt-out, provider registries with a fallback cascade, and the catalogue of taint-hostile subsystems as data.
- [`DialogKit`](../packages/dialogKit/README.md) — Confirmation and input dialogs without StaticPopupDialogs: one frame of their own, a bounded queue, Escape through UISpecialFrames, timeouts.
- [`EditModeKit`](../packages/editModeKit/README.md) — Addon frames in Blizzard's Edit Mode: a labelled overlay drags each frame while Edit Mode is open, its position saved per layout and put back on a layout switch.
- [`EventKit`](../packages/eventKit/README.md) — Lazy game-event subscriptions with scopes and isolated listeners; unit events, combat-log routing and coalescing as optional parts.
- [`GlowKit`](../packages/glowKit/README.md) — Glows that draw the eye to a frame, pixel lines running round its edge or a pulsing border, keyed per frame, pooled and bounded.
- [`HookKit`](../packages/hookKit/README.md) — Reversible, secure-first hooking of functions, methods and frame scripts in three named semantics.
- [`InteropKit`](../packages/interopKit/README.md) — The LibStub bridge: expose Kits to LibStub consumers and adopt LibStub libraries read-only.
- [`LauncherKit`](../packages/launcherKit/README.md) — Minimap buttons for BrokerKit objects, dragged round any minimap shape, state in LibDBIcon's saved fields, and Retail's addon compartment.
- [`LifecycleKit`](../packages/lifecycleKit/README.md) — Replay-aware per-addon loading, readiness and shutdown that closes the addon's scopes in the other Kits; a combat gate and halting as parts.
- [`LocaleKit`](../packages/localeKit/README.md) — Per-addon translations, missing-key reporting and coverage, indexed format specifiers.
- [`LogKit`](../packages/logKit/README.md) — Levelled, structured logging with lazy secret-safe formatting, a bounded journal and chat, callback and table sinks.
- [`MediaKit`](../packages/mediaKit/README.md) — A typed media registry with font scripts, sorted cached lists, per-consumer defaults and LibSharedMedia adoption and mirroring.
- [`MenuKit`](../packages/menuKit/README.md) — Menus described as checked, bounded tables and shown by Blizzard's Menu API: context menus, dropdowns and removable extensions of Blizzard's own menus.
- [`ModuleKit`](../packages/moduleKit/README.md) — Addon-scoped module lifecycle, dependency graphs and dependency policies; injection, implements contracts and required addons as optional parts.
- [`OptionsKit`](../packages/optionsKit/README.md) — A typed, validated, introspectable options tree bound to getters or a SettingsKit database, with no renderer.
- [`PanelKit`](../packages/panelKit/README.md) — An OptionsKit tree in Blizzard's settings panel, as a category or subcategory, drawn by WidgetKit only while its page is shown.
- [`PoolKit`](../packages/poolKit/README.md) — Allocation-conscious bounded object pooling with deterministic ownership and cleanup.
- [`ProfileKit`](../packages/profileKit/README.md) — Zero-cost-when-off performance sections with count, total, spike and a sorted report.
- [`RangeKit`](../packages/rangeKit/README.md) — Unit range estimates: the distance to a unit bracketed in yards from the player's own spells and the client's interact distances, and whether it is within a given range.
- [`ReadinessKit`](../packages/readinessKit/README.md) — Named readiness gates for host data that arrives after load: polling, timeouts, negative caching and bounded waiters.
- [`SchedulerKit`](../packages/schedulerKit/README.md) — Cooperative, frame-budgeted scheduling with priorities, cancellation scopes and TimerKit delays.
- [`SchemaKit`](../packages/schemaKit/README.md) — Sealed value schemas with structured, secret-safe failures: one validation core for arguments, saved variables, options and messages.
- [`SettingsKit`](../packages/settingsKit/README.md) — Saved variables with scopes, schema-validated writes, defaults never written back, profiles and versioned migrations.
- [`SignalKit`](../packages/signalKit/README.md) — Deterministic, re-entrant callback dispatch with explicit connection lifetimes, subscriber-transition hooks, journals and named message buses.
- [`TimerKit`](../packages/timerKit/README.md) — Cancelable one-shot and repeating timers with ownership scopes, and addon scopes closed at logout through LifecycleKit or EventKit when present.
- [`ToastKit`](../packages/toastKit/README.md) — Short notifications that stack at one anchor, hold under the cursor and fade out, with icons and click handlers, pooled and bounded.
- [`TooltipKit`](../packages/tooltipKit/README.md) — Multi-column tooltips, keyed and pooled, with headers, spans, colours, line handlers, scrolling, smart anchoring and auto-hide.
- [`UnitFrameKit`](../packages/unitFrameKit/README.md) — The unit frame shown on screen for a unit token, what LibGetFrame-1.0 gives WeakAuras: a sliced scan of the client's frames, matches ranked across Blizzard's and other addons' unit frames, change notifications and nameplates.
- [`WidgetKit`](../packages/widgetKit/README.md) — Pooled, versioned widgets with explicit layouts, saveable anchors and an OptionsKit renderer.
- [`TestKit`](../packages/testKit/README.md) — Development only, never bundled: in-client test suites in LifecycleKit phases and SchedulerKit jobs, with structured results.
<!-- /generated:package-index -->

Each package keeps its complete public contract under its own `docs/API.md`.

Repository-wide documents define shared rules. Package documents define package behavior. When the two appear to conflict, the design constitution and package manifest contract should be treated as the architectural source of truth and the inconsistency should be fixed.
