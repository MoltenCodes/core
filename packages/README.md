# Runtime Packages

Every visible directory directly under `packages/` is an independently publishable runtime package.

Package directories are discovered automatically from their `package.manifest.json`; do not maintain a separate package list in CI or tooling.

A package owns its source, tests, documentation, changelog, and runtime dependency declarations. See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for package boundaries and [`../docs/PACKAGE_MANIFEST.md`](../docs/PACKAGE_MANIFEST.md) for the required layout and manifest schema.

Current packages:

<!-- generated:package-index -->
- [`registry`](registry/) — Zero-dependency shared package registration, discovery and in-place revision upgrades.
- [`addonKit`](addonKit/) — The single entry point for addon authors: `MoltenCodes:For(...)` with every Kit by name, an addon object over ModuleKit, databases from plain defaults, and one-call options panels and minimap launchers, with errors that say the fix.
- [`apiKit`](apiKit/) — The flavour-aware, typed wrapper over the World of Warcraft API (`wow.retail.api`, ...), generated from the client's own documentation tables.
- [`barKit`](barKit/) — Status and timer bars on the client's StatusBar, with secret values passed through and pausable countdowns, pooled and bounded.
- [`bindingKit`](bindingKit/) — Override key bindings in named scopes (commands, button clicks, Lua functions) that never touch the player's own, applied after combat when set during it.
- [`bridgeKit`](bridgeKit/) — Migration from Ace3: AceSerializer-3.0 text written and read byte for byte, AceConfig-3.0 tables converted to OptionsKit trees, AceDB-3.0 saved variables imported into SettingsKit, AceComm-3.0 spoken through CommKit.
- [`brokerKit`](brokerKit/) — LibDataBroker-compatible data objects: typed attributes as plain fields, per-attribute change signals and a two-way LibDataBroker-1.1 bridge.
- [`cacheKit`](cacheKit/) — Bounded LRU and TTL caches, memoisation, negative entries, lazy namespaces, bounded queues and snapshots with diffs.
- [`clientKit`](clientKit/) — Client flavour, build floor, probed capability flags, secret-value and frame-access probes, and shims with one shape per host call.
- [`codecKit`](codecKit/) — Serialise, compress and channel-encode values behind a self-describing header; decoding never raises.
- [`commandKit`](commandKit/) — Slash commands with hyperlink-aware parsing, generated usage, schema-checked arguments, sinks, completion and an OptionsKit command line.
- [`commKit`](commKit/) — Addon messaging of any length: a chunk protocol with bounded reassembly, refusing priority queues, a session bandwidth budget and sync sets.
- [`compatKit`](compatKit/) — Versioned shims with a host opt-out, provider registries with a fallback cascade, and the catalogue of taint-hostile subsystems as data.
- [`dialogKit`](dialogKit/) — Confirmation and input dialogs without StaticPopupDialogs: one frame of their own, a bounded queue, Escape through UISpecialFrames, timeouts.
- [`editModeKit`](editModeKit/) — Addon frames in Blizzard's Edit Mode: a labelled overlay drags each frame while Edit Mode is open, its position saved per layout and put back on a layout switch.
- [`eventKit`](eventKit/) — Lazy game-event subscriptions on SignalKit, unit-event filtering and combat-log routing by sub-event.
- [`glowKit`](glowKit/) — Glows that draw the eye to a frame, pixel lines running round its edge or a pulsing border, keyed per frame, pooled and bounded.
- [`hookKit`](hookKit/) — Reversible, secure-first hooking of functions, methods and frame scripts in three named semantics.
- [`interopKit`](interopKit/) — The LibStub bridge: expose Kits to LibStub consumers and adopt LibStub libraries read-only.
- [`launcherKit`](launcherKit/) — Minimap buttons for BrokerKit objects, dragged round any minimap shape, state in LibDBIcon's saved fields, and Retail's addon compartment.
- [`lifecycleKit`](lifecycleKit/) — Replay-aware per-addon loading, readiness and shutdown, a shared combat gate with a bounded out-of-combat queue, and a halted state.
- [`localeKit`](localeKit/) — Per-addon translations, missing-key reporting and coverage, indexed format specifiers.
- [`logKit`](logKit/) — Levelled, structured logging with lazy secret-safe formatting, a bounded journal and chat, callback and table sinks.
- [`mediaKit`](mediaKit/) — A typed media registry with font scripts, sorted cached lists, per-consumer defaults and LibSharedMedia adoption and mirroring.
- [`menuKit`](menuKit/) — Menus described as checked, bounded tables and shown by Blizzard's Menu API: context menus, dropdowns and removable extensions of Blizzard's own menus.
- [`moduleKit`](moduleKit/) — Addon-scoped module lifecycle, dependency graphs, dependency injection with checked interfaces, and dependency policies.
- [`optionsKit`](optionsKit/) — A typed, validated, introspectable options tree bound to getters or a SettingsKit database, with no renderer.
- [`panelKit`](panelKit/) — An OptionsKit tree in Blizzard's settings panel, as a category or subcategory, drawn by WidgetKit only while its page is shown.
- [`poolKit`](poolKit/) — Allocation-conscious bounded object pooling with deterministic ownership and cleanup.
- [`profileKit`](profileKit/) — Zero-cost-when-off performance sections with count, total, spike and a sorted report.
- [`rangeKit`](rangeKit/) — Unit range estimates: the distance to a unit bracketed in yards from the player's own spells and the client's interact distances, and whether it is within a given range.
- [`readinessKit`](readinessKit/) — Named readiness gates for host data that arrives after load: polling, timeouts, negative caching and bounded waiters.
- [`schedulerKit`](schedulerKit/) — Cooperative, frame-budgeted scheduling with priorities, cancellation scopes and TimerKit delays.
- [`schemaKit`](schemaKit/) — Sealed value schemas with structured, secret-safe failures: one validation core for arguments, saved variables, options and messages.
- [`settingsKit`](settingsKit/) — Saved variables with scopes, schema-validated writes, defaults never written back, profiles and versioned migrations.
- [`signalKit`](signalKit/) — Deterministic, re-entrant callback dispatch with explicit connection lifetimes, subscriber-transition hooks, journals and named message buses.
- [`timerKit`](timerKit/) — Cancelable one-shot and repeating timers with ownership scopes, and addon scopes closed at logout through LifecycleKit or EventKit when present.
- [`toastKit`](toastKit/) — Short notifications that stack at one anchor, hold under the cursor and fade out, with icons and click handlers, pooled and bounded.
- [`tooltipKit`](tooltipKit/) — Multi-column tooltips, keyed and pooled, with headers, spans, colours, line handlers, scrolling, smart anchoring and auto-hide.
- [`unitFrameKit`](unitFrameKit/) — The unit frame shown on screen for a unit token, what LibGetFrame-1.0 gives WeakAuras: a sliced scan of the client's frames, matches ranked across Blizzard's and other addons' unit frames, change notifications and nameplates.
- [`widgetKit`](widgetKit/) — Pooled, versioned widgets with explicit layouts, saveable anchors and an OptionsKit renderer.
- [`testKit`](testKit/) — Development only, never bundled: in-client test suites in LifecycleKit phases and SchedulerKit jobs, with structured results.
<!-- /generated:package-index -->
