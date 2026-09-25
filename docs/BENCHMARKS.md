# Benchmarks

How MoltenCodes Kits compare with the Ace3 libraries that do the same work, how
that is measured, and what the first measurements show. The runner is
`tooling/bench/` ([`TOOLING.md`](TOOLING.md#host-benchmark)); the raw results
are committed under [`tooling/bench/results/`](../tooling/bench/results/).

## Principles

These come from the external review the project accepted, and every part of
the runner follows from them:

- **Only equal behaviour is compared.** Each workload pairs a Kit subset with
  the Ace3 subset that provides the same behaviour (EventKit with AceEvent-3.0
  events, TimerKit with AceTimer-3.0, and so on), never MoltenCodes as a whole
  against one Ace library. Where the two sides do different work for the same
  call (a validated write against a plain store), the row says *different
  work* and gives no ratio.
- **Everything that shapes a number is recorded**: host or client, the Lua
  version, the CPU model, the OS, the machine's load, the data, warm-up,
  repetitions, and the commit of both sides. Host results and in-client
  results are separate files of separate kinds and are never mixed.
- **Raw results and the runner are published.** Advantages and regressions
  are both reported; nothing is claimed as faster without the numbers beside
  it.
- **Allocation is measured apart from time**, as a `collectgarbage("count")`
  delta over a batch with the collector stopped, the way the repository's
  `#allocation` specs measure ([`TESTING.md`](TESTING.md)).

## Running it

```bash
export PATH=$HOME/.local/lua51/bin:$PATH
python3 -m tooling.bench.run --out tooling/bench/results/<date>-host.json
python3 -m tooling.bench.report tooling/bench/results/<date>-host.json
```

`--workload NAME` (repeatable) runs a subset: `eventDispatch`,
`messageDispatch`, `timers`, `settings`, `codec`, `comm`, `libraryRegistry`,
`addonModules`, `hooks`, `slashCommands`, `locale`, `buckets`, `options`,
`widgets`. `--rounds`,
`--repeat` and `--warmup` change the batch counts below. The first run
downloads Ace3 (about 1 MB) into the cache; a full run of the whole catalogue
takes about five minutes.
`--repeat 1 --rounds 1 --warmup 0` is a quick check that everything still runs.

A results file is committed only from a full default run, named after its
date and kind (a second run on the same date takes a `-2` suffix), and its
rendered report goes into [Results](#results) below.

## Methodology

**Processes.** Every case runs in a fresh Lua process per side, so no case
inherits heap, frames or registrations from another and the two sides never
share a process or a heap. A process loads only its own side's libraries.

**Rounds and interleaving.** Each case runs in three rounds. Within a round the
two sides' processes for one case follow each other, and which side goes first
alternates from case to case and from round to round. The rounds' timed
batches are pooled. This matters on a shared machine: CPU time per operation
changes when the scheduler moves a process between core types or other work
competes for the fast cores, and interleaving puts that drift on both sides
alike.

**Batches.** In each process, the subject is built once (not measured), then:

1. two untimed warm-up batches, so first-call costs (table growth, lazily
   created frames, interned strings) are paid;
2. five timed batches of a fixed number of operations, each after a full
   collection, timed with `os.clock` (process CPU time); the collector runs
   normally inside a batch, so a case that allocates also pays for collecting
   it, as it would in the client;
3. one allocation batch with the collector stopped:
   `collectgarbage("count")` before and after, reported in bytes per
   operation.

Set-up that a batch consumes (fresh saved variables, a drained timer queue, a
refilled bandwidth bucket) is restored between batches, outside every timed and
measured region.

**Reading a row.** Time is nanoseconds per operation: the median of the fifteen
timed batches, with the fastest and slowest in brackets. It includes one empty
`for` iteration (recorded with the results, under 1 ns on the reference
machine). *MoltenCodes ÷ Ace3* is the ratio of the medians, with the ratio of
the minimums beside it, the least disturbed batch of each side. The verdict is
*faster* or *slower* only when the two sides' interquartile ranges do not
overlap, and *within noise* otherwise. Bytes per operation near zero (below
one) are interpreter bookkeeping, not an allocation by the library.

**Interned strings.** Lua keeps one copy of equal strings. A workload that
produced the same string on every operation would appear to allocate nothing
for it, so the serialisation workload changes its payload before every encode
and the message workload sends and receives a different text every time.
Decoding one text repeatedly still re-creates the same short strings inside the
decoded value, on both sides alike.

**Correctness checks.** Every workload also runs a set of checks on both sides
(re-entrant dispatch, error isolation, round trips, pending resources). A check of behaviour
the library does not promise, such as delivery order in CallbackHandler, is
reported as *not promised* rather than as a failure.

**Not a gate.** Nothing here runs in CI and there is no threshold: timing on a
shared runner is noise. The unit tests of the runner itself
(`tooling/tests/test_bench.py`) run with the other tooling tests and need
neither the network nor Lua.

## The shared host, and what was stubbed for Ace3

Both sides run on the repository's shared fake client,
[`tests/support/FrameworkTestEnv.lua`](../tests/support/FrameworkTestEnv.lua),
so a Kit and an Ace3 library see the same `CreateFrame`, frames and error
handler. Ace3's own `tests/wow_api.lua` is not used: it lacks most of what
AceDB-3.0, AceComm-3.0 and ChatThrottleLib call, and using it for one side only
would give the two sides different hosts.

[`BenchHost.lua`](../tooling/bench/lua/BenchHost.lua) installs what the fake
client lacks, **for both sides, whether or not a side uses it**:

| Stub | Needed by | Why it favours neither side |
|---|---|---|
| `GetTime`, `GetTimePreciseSec`, `C_Timer.After`, `NewTimer`, `NewTicker` on a simulated clock ([`SimulatedTimers.lua`](../tooling/bench/lua/SimulatedTimers.lua)) | AceTimer (`After`), TimerKit (`NewTimer`, `NewTicker`), CommKit and SchedulerKit | One queue of parallel arrays, one linear pass per `Advance`, one table per handle. Its own cost in each library's style is measured and reported as the `host-stub-*` timer rows, so a reader can subtract it. |
| `securecallfunction`: the fake client's stub (`pcall`, errors to the host error handler) | CallbackHandler-1.0 (required), EventKit, SignalKit buses, CommKit | The same function isolates every listener on both sides; neither side skips isolation the other pays for. |
| `xpcall(f, handler, ...)` forwarding extra arguments, as the client's Lua does | ChatThrottleLib, for every send | Stock Lua 5.1 drops the arguments and ChatThrottleLib would send nothing. The replacement stages up to six arguments without allocating; a call without extra arguments (the only form a Kit uses) goes straight to the stock function. |
| `UnitName`, `UnitNameUnmodified`, `GetRealmName`, `UnitClass`, `UnitRace`, `UnitFactionGroup`, `GetLocale`, `GetCurrentRegion`, `GetCurrentRegionName`, `GetBuildInfo` (Retail 12.1) | AceDB-3.0 at load, SettingsKit at `Open` | Constant answers from plain functions, called once per load or open. |
| `C_ChatInfo` (register, query, send, send logged), `Enum.SendAddonMessageResult`, `Enum.RegisterAddonMessagePrefixResult`, `GetFramerate` (60), `UnitInParty`, `UnitInRaid` | CommKit, AceComm-3.0, ChatThrottleLib | A send appends to three arrays and returns `Success`: no table per message on either side. |
| `Ambiguate` (returns the name) | AceComm-3.0, per received message | A single return; CommKit does not call it. |
| `hooksecurefunc`, `wipe` / `table.wipe`, `strlenutf8` | ChatThrottleLib (hooks the send functions), AceDB-3.0 (profile names) | Client helpers with their client behaviour. ChatThrottleLib's hook wrapper is part of its send path in the client too; HookKit is not loaded, so CommKit installs no hook. |
| `Frame:UnregisterAllEvents` on every frame | AceComm-3.0 at load | Called once, at load. |
| `issecurevariable` (always `false`), `Frame:HasScript`, `Frame:HookScript` (sets the handler when there is none, otherwise chains the new one after it; a later `SetScript` replaces the chain) | AceHook-3.0 (reads `issecurevariable` at load, needs `HasScript` for every script hook, `HookScript` for `SecureHookScript`), HookKit (asks `issecurevariable` before non-secure hooks, uses `HookScript` for `SecureHookScript`) | Every target is the benchmark's own table or frame, which the client reports as not secure; both sides ask the same function and get the same answer. `HookScript` has the client's semantics and is added to every frame for both sides. |
| `SlashCmdList`, `hash_SlashCmdList`, a `DEFAULT_CHAT_FRAME` whose `AddMessage` keeps only a count and the last line, `strtrim` / `string.trim`, `strsplit` / `string.split` | AceConsole-3.0 and CommandKit (registration), AceConfigCmd-3.0 (captures `string.trim` and `string.split` at load, prints to the chat frame), CommandKit (default sink) | Plain tables and the client's semantics; printing a line costs one field write on either side. |
| `CreateFrame` of a type the fake client lacks (`GameTooltip`) builds a plain `Frame` | AceGUI-3.0, once at load (its shared tooltip) | One frame at load; no case creates one. |
| No-op `SetBackdrop`, `SetBackdropColor`, `SetBackdropBorderColor` (the client's `BackdropTemplate` mixin), `SetHitRectInsets`, `EditBox:SetTextColor`, `FontString:SetVertexColor`, added to the fake client's shared method tables the first time a frame of each type is created (only when absent) | AceGUI-3.0 widgets (`InlineGroup`, `Slider`, `EditBox`, `Label`); WidgetKit calls none | Empty methods that change nothing a layout or check reads; installed once per type, no per-frame cost. The font-string hook wraps `CreateFontString`, one extra call per region at construction only, on both sides. |

No fake-client profile is selected, so there is no `issecretvalue` and no
`C_EventUtils`: the Kits take their path for a client without secret values.
On Retail 12.x they also call `issecretvalue` on the values they handle; the
host cannot price a native call, so that cost is left to the in-client runner.

Events are delivered by calling the `OnEvent` script of the frame the library
registered, the way the client calls it, rather than through the fake client's
`Emit`, which walks every frame: the measured time is the library's dispatch.
The fake frames record every `RegisterEvent` and `UnregisterEvent` call in an
array; both sides pay that in the `churn-cold` rows, where both register and
unregister the event every time.

## Workloads

| Workload | MoltenCodes | Ace3 | Measured |
|---|---|---|---|
| `eventDispatch` | EventKit (on SignalKit) | AceEvent-3.0 events (on CallbackHandler-1.0) | `UNIT_POWER_UPDATE` with two payload values to 1, 10 and 100 listeners; connect and disconnect beside ten listeners and as the only one |
| `messageDispatch` | a SignalKit bus, `openTopics = true` | AceEvent-3.0 messages | the same, for a named message any addon can subscribe to |
| `timers` | TimerKit scope timers | AceTimer-3.0 | start and cancel a one-shot; start one and let it fire; one tick of 100 repeating timers; what a cancelled timer leaves pending |
| `settings` | SettingsKit with a SchemaKit schema | AceDB-3.0 with the same defaults | open empty and populated saved variables (22 profiles, 50 characters); profile switch; reads (default, saved, nested, keyed-entry wildcard); writes; `Validate`; memory held per open database |
| `codec` | CodecKit, `channel = "addon"`, no compression | AceSerializer-3.0 | encode and decode a small, a medium (50 records) and a large (500 numbers, 200 strings, 100 records) payload; output size |
| `comm` | CommKit | AceComm-3.0 with ChatThrottleLib | send 200-, 1000- and 8000-byte messages until every chunk left; receive and reassemble them; wire bytes; memory an incomplete stream holds |
| `libraryRegistry` | Registry (`Register`, `Get`, `Find`), InteropKit's LibStub bridge | LibStub | register a new library, upgrade it, refuse a stale copy; look up one of 50 by name; a silent miss; reach a LibStub library through the bridge; expose a Kit to LibStub (MoltenCodes only) |
| `addonModules` | ModuleKit with LifecycleKit (on EventKit, SignalKit) | AceAddon-3.0 (with AceEvent-3.0 embedded in the listener case) | create an addon with 10 modules; create it and deliver its `ADDON_LOADED` after login (initialise and enable all); disable and enable all 10 modules; one module; all 10 with one game-event listener each while enabled |
| `hooks` | HookKit | AceHook-3.0 | pre-hook and unhook a global function, a method and a frame script; raw hook and unhook; post-hook (`hooksecurefunc`) and unhook; a call through a pre-, post- and raw-hooked method, a pre-hooked script, and an unhooked post-hook's inert closure |
| `slashCommands` | CommandKit | AceConsole-3.0 | register and unregister a command beside 50 foreign ones; run a typed line with two words, and `scale <number>` checked against 0.5..2; split plain words, quoted strings and a colour-wrapped item link |
| `locale` | LocaleKit | AceLocale-3.0 | register a default locale of 100 strings and get the read table; ask for a locale the client does not need; read a defined key; first read of an undefined key (silent mode); `Format` with indexed specifiers (MoltenCodes only); memory held per registered addon |
| `buckets` | EventKit `Coalesce` (on SchedulerKit, TimerKit) | AceBucket-3.0 (on AceEvent-3.0, AceTimer-3.0) | one event into an open interval; a burst of 10 events and its delivery; create and remove a bucket over two events beside another; host timers pending after a delivery |
| `options` | OptionsKit, with CommandKit's `BindOptions` and SettingsKit | AceConfigRegistry-3.0, AceConfigCmd-3.0, AceDBOptions-3.0 (with AceDB-3.0, AceConsole-3.0) | define and check a 50- and 200-option table; a typed command that sets a range, a toggle or a select, or is refused; build the profile group and choose a profile from the command line; `tree:Get` and `tree:Set` (OptionsKit only) |
| `widgets` | WidgetKit (on PoolKit, SignalKit) | AceGUI-3.0 | **indicative, fake-client frames**: acquire, fill and release a pooled Label, Button, CheckBox, Slider and EditBox; a titled group (`Group` / `InlineGroup`) with 10 and 50 labels built, laid out once and released; a second layout pass over 50 labels; the stub's anchor cost in each library's style |

What each pairing leaves out, on purpose:

- **Messages.** A raw SignalKit signal is not compared with CallbackHandler: it
  does not isolate listener errors, so it would do less work. The bus does,
  like CallbackHandler.
- **Settings writes.** A SettingsKit write is validated against the schema and
  fires the scope's change signal; an AceDB write is a table store. The rows
  are shown with both numbers and no ratio: the gap is the price of validation
  and notification. On a profile switch AceDB also strips default-equal values
  from the old profile, which SettingsKit leaves to its logout compaction; each
  side does what it does on a switch, and the row says so.
- **Compression.** Ace3 has no compressor. Comparing CodecKit's DEFLATE stage
  would need a second library on the Ace side (LibDeflate), fetched and named
  separately; this benchmark does not fetch it, so compression is off on both
  sides.
- **Throttling.** Both throttles are opened to the same rate (CommKit
  `maxCps = 100000, burst = 1000000`, its ceilings; ChatThrottleLib
  `MAX_CPS` and `BURST` the same) and refilled between batches, so neither
  side waits for bandwidth and the rows measure each library's own path.
  CommKit's send includes one frame of its SchedulerKit driver; ChatThrottleLib
  sends at once while bandwidth is available (`framesPerMessage`).
- **Library bootstrap.** `Registry:Bootstrap`, the path a Kit's own file
  takes (surface validation, retire hooks, migrations, sealing), has no
  LibStub counterpart: LibStub libraries write their upgrade code by hand.
  Only `Register`, `Get` and `Find` are compared. The MoltenCodes process also
  loads `LibStub.lua` from the pinned checkout, for the InteropKit rows only.
  Both sides get the same numeric minors; LibStub turns each into a string for
  its `string.match`, which is its own cost.
- **Modules.** Dependencies, injection and `requiresAddons` have no AceAddon
  counterpart and are not measured; the checks show the ordering difference
  instead. AceAddon embeds libraries into a module when it is created; a
  ModuleKit module's `scope` fields are created on first read, so the two
  mechanisms are compared only in the listener cycle, where both give a module
  an event registration that disable releases. ModuleKit validates and orders
  the module graph on every whole-container pass, which is its documented
  cost. Neither side can delete an addon, so the create and load cases grow
  both registries by a few thousand addons per process.
- **Hook calls.** HookKit runs pre-hook and post-hook handlers under `pcall`
  and reports a failure to the host error handler, so a failing handler never
  stops the original or the caller; AceHook calls them directly (a failing
  pre-hook handler stops the original and raises). Those call rows are
  *different work*. A raw replacement raises on both sides, and an unhooked
  post-hook's inert closure reads one flag on both, so those are compared.
  Both sides get the handler as a function (AceHook's method-name form has no
  HookKit counterpart). HookKit's scope ownership and its secure-target and
  protected-frame refusals are not measured: the host answers
  `issecurevariable` with `false` for every target, which are the benchmark's
  own.
- **Post-hook install.** A post-hook cannot be removed on either side (the
  host chain keeps an inert closure), so the install case hooks a fresh object
  each time, built outside the timed region; what repeated cycles on one
  target leave behind is a separate measurement.
- **Slash-command arguments.** An AceConsole handler receives the raw text and
  splits it with `GetArgs`; its checks are the handler's own code, written as
  AceConsole addons write them (`dispatch-subcommand`). CommandKit's
  registration also checks the name against other addons, chat types and up to
  1,024 emote indexes (`EMOTE<n>_CMD1`; the host defines neither
  `MAXEMOTEINDEX` nor any emote, so every index is read, as the client's
  several hundred emotes would be);
  `register-unregister-one-emote` shows the price of that scan. Tab completion
  (AceTab) is not compared.
- **Missing translations.** The first-miss row runs both libraries in silent
  mode, so no error report is timed, and opens LocaleKit's missing-key bound
  (`maxMissingKeys = UNBOUNDED`) so both store every key; LocaleKit also
  records the key for `MissingKeys`. The default bound (1024), the per-call
  write proxies and the refusal of non-text values are checks, not ratios.
  `Format` has no AceLocale counterpart.
- **Bucketed messages.** AceBucket's `RegisterBucketMessage` is not compared:
  its counterpart is a SignalKit bus listener feeding a SchedulerKit
  `Coalesce` handle, a composition rather than one call. AceBucket counts
  arrivals per key and keeps every key; EventKit delivers `true` per key and
  refuses new keys past 256 per interval. After each delivery AceBucket
  re-arms one more timer, which finds nothing and goes idle. The `burst` row
  includes the simulated `C_Timer` in each library's style (see the
  `host-stub-*` timer rows).
- **Options: define.** AceConfigRegistry checks a table the first time a UI
  asks for it, so the Ace side is `RegisterOptionsTable` plus
  `GetOptionsTable(name, "dialog", ...)`, with the "already validated" mark
  cleared, since it has no unregistration. `OptionsKit:Define` also copies and
  indexes the tree and builds one schema per value option.
- **Options: command line.** Both parse the line, find the option, convert the
  text, check it and call `set`. CommandKit's bound command also echoes
  `path = value` and calls `tree:Describe()` of the whole tree once per
  command; AceConfigCmd prints nothing on success.
- **Options: get and set.** AceConfigRegistry has no call that reads or writes
  an option through the table, so `tree-get` and `tree-set` are OptionsKit
  only. AceConfigDialog needs real frames and is left to the in-client runner.
- **Profile options.** AceDBOptions keeps one group per database and one
  shared args table, so building it again is cheap; `OptionsKit:ProfileOptions`
  builds a new group of closures. Choosing a profile includes each database's
  own switch (see `settings`).
- **Widgets are indicative.** The frames are the fake client's: a `SetPoint`
  or `SetText` is a Lua table write, where the client's is a native call, and
  nothing is drawn. The rows compare each toolkit's own Lua work around its
  frames; frame cost belongs to the in-client runner. The workload creates
  `UIParent` before either side loads (AceGUI captures it at load; both parent
  released frames to it).
- **Group layout is not given a ratio.** AceGUI's `List` anchors each child to
  the one above; the fake client refuses anchor cycles, as the client does, by
  walking the new anchor's chain in Lua, so a pass over n children walks about
  n²/2 anchors and that stub work dominates AceGUI's time. WidgetKit anchors
  each child to the content. `group-10`, `group-50` and `relayout-50` show both
  numbers without a ratio; `host-stub-list-anchors-50` shows the stub work
  alone in each style (it leaves out AceGUI's per-label anchor, so it
  understates AceGUI's share).
- **Heading is left out.** AceGUI's `Heading` at this commit calls the Retail
  12 `issecretvalue` global on every `SetText`; the host installs none on
  purpose, and a Lua stand-in would also run on every WidgetKit text setter.
  AceGUI's `Frame`, `ScrollFrame` and `SimpleGroup` are pinned and load, but
  add nothing a group does not already show on fake frames.
- **Left out entirely.** AceConfigDialog-3.0 (needs real frames; in-client
  plan), AceTab-3.0 (completion needs the client's edit box), AceGUI's
  DropDown, ColorPicker, TabGroup and TreeGroup (not pinned; the in-client
  runner is where frame-heavy widgets can be priced).

## In-client runner

The host cannot measure what only the client shows: native calls, real
frames, the frame loop, the collector over minutes, a real throttled message.
The in-client runner measures those inside World of Warcraft, and runs the host
workloads that make sense there on the client's own Lua. It follows the plan
this section held before it was built; the places where it refines the plan
are listed at the end. Its results are files of their own kind and are never
mixed with host results.

### The addons

`python3 -m tooling.bench.client_install` (see
[`TOOLING.md`](TOOLING.md#in-client-benchmark)) writes three development addons
into the game folder; nothing of them ships:

| Addon | Loads | Holds |
|---|---|---|
| `MoltenCodesBench` | at login | the harness and `/mcb`: its files from [`tooling/bench/client/MoltenCodesBench/`](../tooling/bench/client/MoltenCodesBench/), every benchmark Lua module (the host workloads and the client's own), and a generated `Installation.lua` with the installed commit, the flavour folder, what each side carries and the workload catalogue. It depends on no framework addon. |
| `MoltenCodesBench_Kits` | on demand | the release bundle `tooling.package.build` builds, plus `LibStub.lua` for the InteropKit rows |
| `MoltenCodesBench_Ace3` | on demand | exactly the pinned Ace3 files the host loads (`ace3.py`, `LOADED_FILES`) and Ace3's licence, copied from the checksummed cache at install time and checked against its digest again just before copying ([Ace3 licence](#ace3-licence)) |

The harness loads **one side per session**, so the two sides never share a
heap, a memory figure or a frame. It refuses to load a side while the
standalone `MoltenCodes` addon or `MoltenCodesTest` is loaded, while another
addon already put MoltenCodes Kits (Kits side) or any of the pinned Ace3
libraries in LibStub (Ace3 side), or in combat: each would make the measured
copy something other than the installed one. A refusal stops the run with the
reason and the addons loaded, and saves nothing.

### The same workloads, on a client host

A workload talks to its host only through the interface `BenchHost.lua` gives
it. [`ClientHost.lua`](../tooling/bench/client/lua/ClientHost.lua) gives the same
interface over the real client, so a shared workload module runs unchanged:

| Host call | In the client |
|---|---|
| `RequireAll` | Kits from the Registry the Kits side loaded (`MoltenCodes.Registries[2]`), each at the API of its committed manifest; `LibStub` is the global the side loaded |
| `LoadFiles` | nothing to load (the side's `.toc` loaded the files); checks that the side carries every file the workload names |
| `Global` | the client global |
| `EventHandler` | the frame the side's library registered for the event and its `OnEvent` script, found with `GetFramesRegisteredForEvent` among the frames that did not exist before the side loaded (`EnumerateFrames` at load) |
| `TakeReportedErrors` | the errors the host error handler received: the harness installs a capturing handler with `seterrorhandler` for the whole session item and restores the previous one |
| `environment.Emit` | calls the `OnEvent` script of those same side frames, as the client does |
| `timers`, `chat`, `chatFrame`, `Tick`, the rest of `environment` | the fake client's internals: touching one marks the case *not run in the client*, with the reason |

The clock is `debugprofilestop()`. The client has no `require`: the installer
wraps every module in one `DefineModule` call opened on the module's first
line, so error messages keep the committed file's line numbers
([`Loader.lua`](../tooling/bench/client/MoltenCodesBench/Loader.lua)).

Shared workloads run in the client: `eventDispatch`, `messageDispatch`,
`settings`, `codec`, `libraryRegistry`, `hooks`, `slashCommands`, `locale`.
The others need the fake client and are replaced or left to the host
([`client_workloads.py`](../tooling/bench/client_workloads.py) holds the list
and the reasons, and a unit test holds it to the host catalogue):

| Host workload | Why not in the client | Measured instead by |
|---|---|---|
| `timers` | every case advances the simulated clock | `timersLive` |
| `comm` | sends into the recording outbox and advances the simulated clock | `whisper` |
| `buckets` | delivery waits for the simulated clock | the host rows; the timers under it by `timersLive` |
| `addonModules` | drives fake addons through the fake client's addon-loaded state | the host rows |
| `options` | counts lines on the fake chat frame; in the client every typed command would print to the real chat frame thousands of times per batch | the host rows |
| `widgets` | creates its own `UIParent`, which would replace the client's | `window` |

### What only the client measures

Each is a client-only workload under
[`tooling/bench/client/lua/clientWorkloads/`](../tooling/bench/client/lua/clientWorkloads/),
doing the same work on both sides through one set of adapters
([`Adapters.lua`](../tooling/bench/client/lua/clientWorkloads/Adapters.lua)):

- **`nativeCalls`**: `issecretvalue` of a number, a string and a table, and
  `securecallfunction` of an empty function with none and two arguments, as
  batches beside an empty Lua call and `pcall` for scale. No library is
  involved; both sides run the same calls, so the ratio of the two columns is
  the noise floor of the in-client numbers. A client without either function
  reports those cases as not run.
- **`window`**: a WidgetKit window against an AceGUI-3.0 `Frame`, 400 × 500,
  holding a heading, 20 full-width labels, a button, a check box, a slider and
  an edit box, laid out once with layout paused while filling, shown and
  released. `open-close` times that as a batch (every native frame call
  inside the time, the drawing not); `open-close-drawn` opens it, lets the
  client draw it once and closes it, 60 times, and reports the frame after an
  open against idle frames of the same session.
- **`timersLive`**: TimerKit against AceTimer-3.0 on the client's clock. Start
  and cancel a 10-minute one-shot (a batch; no cancelled native callback comes
  due before the next reload); start 1,000 one-shots of 0.2 s in one frame and
  wait for all (the starting frame's Lua time, how late each callback ran, the
  frames it took); 200 repeating timers of 0.1 s for 10 s (ticks delivered
  against ticks due, frame times).
- **`whisper`**: a real addon-message round trip. CommKit against AceComm-3.0
  with ChatThrottleLib, both at their default rates (800 bytes per second, a
  4000-byte burst), whisper 200-, 1000- and 4000-byte messages to the player's
  own character, five in a row, each sent when the previous one arrived whole.
  Reported: round trip median, minimum and maximum, and messages lost after 60
  s. The server's addon-message limits apply to both sides alike.
- **`session`**: frame time and memory under a synthetic load shaped like a
  busy addon: 10 listeners on each of 10 events that fire in any session
  (auras, power, health, cooldown updates, the cursor, the mouse-over unit, UI
  widgets), a message bus of 20 subscribers published 10 times per frame, 50
  repeating timers of 0.1 s, an open window of 25 widgets whose label changes
  every frame, and a 200-byte whisper to the player every 2 s. `idle-30s` is
  the session's baseline with the side loaded; `load-60s` runs the load and
  reports frame time p50, p95 and p99 and the Lua time of the per-frame work;
  `memory-300s` runs it for five minutes, samples the heap every second and
  the side addon's memory every 10 s (`UpdateAddOnMemoryUsage` and
  `GetAddOnMemoryUsage`, present on every promised flavour's documentation),
  and reports growth per minute, collection cycles, and what stayed after a
  full collection at the end against one at the start, after the load was
  torn down. `UpdateAddOnMemoryUsage` walks the whole heap, so that case's
  frame times are not comparable with `load-60s`.

### Methodology in the client

- **One case per session.** The host's fresh process per case is a fresh UI
  session here. `/mcb run <workload> <kits|ace3|both> [rounds]` queues one
  *checks* item per side (it runs the correctness checks and lists the side's
  cases), then one item per case, side and round, ordered as the host runner
  orders its processes: the two sides of a case follow each other and the
  first side alternates from case to case and round to round. Each item runs
  in its own session; between items the harness shows a panel whose button
  reloads the interface (a reload from a click is always allowed), and after
  the reload it goes on by itself. A session that ended before its item
  finished (a crash, a disconnect) is recorded as such after the next login.
- **Settling.** An item starts 10 s after the session entered the world, so
  login work, the first collections and CommKit's zoning throttle are over,
  and never in combat.
- **Batches.** A batch case follows the host protocol (2 warm-up, 5 timed and
  1 allocation batch per round), one batch per frame so the client keeps
  drawing; each batch still runs synchronously inside its frame, so nothing
  else runs while it is timed, and the client pauses for the length of a
  batch. A client that refuses `collectgarbage("stop")` gets no allocation
  figure rather than a wrong one.
- **Frame cases.** Frame times come from `GetTimePreciseSec` between
  successive frames (no addon can reset it, unlike `debugprofilestop`), and
  go into fixed-size histograms whose percentiles are exact to 1 %, so the
  runner adds nothing to the heap while a case runs. Completed collection
  cycles are counted with an unreachable key in a weak table, checked every
  frame (exact to one cycle).
- **Recorded with every item**: the client build, interface, flavour,
  operating system and locale; the addons loaded after the side loaded; the
  frame-rate settings (`maxFPS`, `maxFPSBk`, `targetFPS`, their `use` flags
  and vertical sync) and `GetFramerate()`; the seconds since entering the world; the
  side's load time and memory; whether errors could be captured; every error
  the handler received; the installed commit and whether the working tree had
  changes. The package versions and the Ace3 source are saved once per
  installation.
- **Reading a row.** As on the host, with one addition: the client's numbers
  include what the client does around the Lua (native calls, the collector of
  a much larger heap). Keep both sides' conditions equal: the same place in
  the world, the camera still, the same frame-rate settings, and no other
  addon loaded; the results list what was loaded.

### Running it in the client

In the repository:

```bash
python3 -m tooling.bench.client_install --wow-dir "/Applications/World of Warcraft" --dry-run
python3 -m tooling.bench.client_install --wow-dir "/Applications/World of Warcraft"
```

In the game, step by step:

1. In the addon list, leave `MoltenCodesBench`, `MoltenCodesBench_Kits` and
   `MoltenCodesBench_Ace3` enabled (the two sides load only when the harness
   asks), and disable `MoltenCodes`, `MoltenCodesTest` and, for comparable
   numbers, every other addon. An addon that embeds Kits must be disabled:
   the harness refuses the Kits side while any other copy of the Kits is
   loaded, and names the addons that are.
2. Log in somewhere quiet and leave the camera still.
3. `/mcb list` shows the workloads and the host workloads the client skips.
4. `/mcb run eventDispatch both` (or `kits`, `ace3`; an optional last number
   runs up to 5 rounds). The first item starts 10 s later and loads one side.
5. When the panel says so, click **Reload and go on** (or type
   `/mcb continue`). The next item runs by itself after the reload. Repeat
   until the chat says the run is complete. `/mcb status` shows progress,
   `/mcb stop` drops the queue (saved results stay), `/mcb report` prints the
   saved results of this installation.
6. **Switching sides** needs a reload: a session that loaded one side refuses
   the other. `both` switches for you at every reload. To run the sides one
   at a time, run `/mcb run <workload> kits`, then after its last reload
   `/mcb run <workload> ace3`; both sides stay enabled in the addon list
   throughout, and the harness loads only the one the item needs.
7. Log out, or reload once more, so the client writes the saved variables.

Back in the repository:

```bash
python3 -m tooling.bench.client_report --wow-dir "/Applications/World of Warcraft"
python3 -m tooling.bench.client_report --render tooling/bench/results/<date>-client-retail.json
python3 -m tooling.bench.client_install --wow-dir "/Applications/World of Warcraft" --remove
```

`client_report` reads `WTF/Account/*/SavedVariables/MoltenCodesBench.lua` of
each flavour folder without running Lua, keeps the entries of the most recent
installation (older ones and test builds are reported and left out), pools the
rounds of a batch case as the host runner does and takes the median of each
frame measurement, writes `tooling/bench/results/<date>-client-<flavour>.json`
(`-2`, `-3`... when the name is taken; `--out` names another file, `--dry-run`
writes none) and prints the tables. `--remove` deletes the three addons, the
harness's saved variables and their lines in every `AddOns.txt`, and nothing
else; run the report first.

### Client results files

A client results file has the host file's shape where the two agree (per
workload, per side: the libraries with their revision or minor, the checks,
the cases with the host's timing fields), so the timing, measurement and check
tables render the same way, and adds `kind = "client"`, the flavour, the
client build, the frame-rate settings, the addons loaded, the settle time, the
frame cases' measurements, the cases not run with their reason, and the host
workloads the client does not run. `python3 -m tooling.bench.report` refuses a
client file and `client_report --render` refuses a host file, so the two kinds
are never rendered or merged together.

### Refinements of the plan

- **The installer is its own command**, `tooling.bench.client_install`,
  instead of a `--bench` target of `tooling.client.install`: it needs the Ace3
  cache and the benchmark's modules, which belong to `tooling/bench/`. It
  shares the test installer's layout, safety and removal helpers, and the two
  never remove each other's addons.
- **A reload separates every case**, not only the sides: a case's set-up stays
  in the Kits' and LibStub's singletons, so two cases in one session would not
  measure what the host measures.
- **Windows only.** The UI comparison is WidgetKit against AceGUI-3.0's
  `Frame`. AceConfigDialog-3.0 is not in the pinned, checksummed file set, so
  OptionsKit dialogs are not compared yet; adding it means pinning its files
  and a new digest.
- **The Kits side carries `LibStub.lua`** from the cache, which the host's
  MoltenCodes process also loads for the InteropKit rows.
- **Six host workloads are not run in the client**, with the reasons above;
  their simulated-time cases became `timersLive` and `whisper`.
- **The report is its own command**, `tooling.bench.client_report`, which reads
  the saved variables and renders client files; `tooling.bench.report` stays
  the host renderer.

## Ace3 licence

Ace3 is under a BSD-style licence
([`LICENSE.txt`](https://github.com/WoWUIDev/Ace3/blob/5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773/LICENSE.txt))
with one added clause: *"Redistribution of a stand alone version is strictly
prohibited without prior written authorization from the Lead of the Ace3
Development Team."* The conclusion for this repository:

- Ace3 is **never committed or vendored**, in whole or in part, and no
  package or bundle ships it. The runner downloads the pinned commit from the
  upstream repository into a cache outside the repository on the machine that
  runs the benchmark, which is use, not redistribution.
- The results name Ace3's files, versions and commit, which the licence does
  not restrict. The in-client runner (`tooling.bench.client_install`) copies the
  pinned files from the cache into the local game folder at install time,
  verified against their digest, without redistributing them.

## Adding a workload

1. Write `tooling/bench/lua/workloads/<Name>.lua` returning a table with
   `Build(side, host, settings)`, which loads only that side's libraries and
   returns `{ libraries, cases, checks }`: `libraries` names each measured
   library with its `revision` (Kits) or `minor` (Ace3); each case has a
   `name` shared by both sides, `iterations`, `operation`, optionally
   `equivalent = false` and a `note`, and `prepare()` returning
   `{ run(iterations), beforeBatch?, afterBatch?, metrics? }`
   ([`Bench.lua`](../tooling/bench/lua/Bench.lua)); `checks()` returns
   `{ name, passed, detail, promised }` rows.
2. Name it in `WORKLOADS` in [`main.lua`](../tooling/bench/lua/main.lua) and
   in [`workloads.py`](../tooling/bench/workloads.py), with the packages it
   measures; `tooling/tests/test_bench.py` holds the two lists equal.
3. Any host call it needs goes into `BenchHost.lua` for both sides, and into
   the stub table above with the reason it favours neither.

## Results

The current run is
[`tooling/bench/results/2026-09-25-host-2.json`](../tooling/bench/results/2026-09-25-host-2.json):
the whole catalogue (fourteen workloads) in one default run, on an otherwise
idle machine (load average about 2 on 18 logical CPUs, no game client or
virtual machine running), rendered below with `python3 -m tooling.bench.report`.

**History.** The first host run,
[`2026-09-25-host.json`](../tooling/bench/results/2026-09-25-host.json), covered
the first six workloads only. It was made before the performance round of
2026-09-25 (commKit r5, settingsKit r6, signalKit r9, eventKit r17, timerKit
r10, codecKit r5) and on a machine shared with a game client and a virtual
machine, so its numbers are not comparable with the current ones and are kept
only as a record.

### What the numbers show

Host Lua only; none of this is a claim about the game client. Ratios are
MoltenCodes ÷ Ace3 of the medians; *parity* means the interquartile ranges
overlap or the ratio is within 1.15× either way.

| Package | Ace3 counterpart | Verdict (MoltenCodes ÷ Ace3) | Allocation (MoltenCodes against Ace3) | Why the remaining gap |
|---|---|---|---|---|
| eventKit | AceEvent-3.0 events (CallbackHandler-1.0) | dispatch at parity (0.95× faster at 10 listeners, 1.00× within noise at 100, 1.13× at 1); connect and disconnect slower, 1.29–1.53× | dispatch 0 against 0; 224–328 B against 0–104 B per connect and disconnect | a connection object per connect, which the caller holds and can disconnect by |
| signalKit (bus) | AceEvent-3.0 messages (CallbackHandler-1.0) | dispatch at parity at 10 and 100 listeners (1.06×, 1.01×), slower at 1 (1.57×); connect and disconnect slower, 1.57–1.64× | 0 against 0 per dispatch; 224 B against 0 per connect and disconnect | fixed per-dispatch cost of error isolation and the firing generation, visible with one listener; a connection object per connect |
| timerKit | AceTimer-3.0 | slower, 2.24–3.07× to start a one-shot; repeating tick at parity (1.09×) | 752 B against 512 B per one-shot (224 B of it the simulated `C_Timer` handle) | one cancellable native timer and one handle per timer; in exchange a cancelled timer leaves nothing (41 B against 553 B retained, 0 against 1,000 pending host timers) |
| settingsKit (with schemaKit) | AceDB-3.0 | profile switch faster, 0.28×; open slower, 2.3–4.5×; reads slower, 57–71×; writes are *different work* (validated, signalled) | open 6.6–7.2 KB against 3.3–3.8 KB, 6.2 KB against 3.9 KB held per database; switch 0 against 496 B | a read goes through the scope view and the schema's path lookup where AceDB indexes a plain table |
| codecKit (compression off) | AceSerializer-3.0 | from 0.90× (large decode, faster) to 1.53× (small encode); encode 1.20–1.53×, decode 0.90–1.25× | encode less: 138 B against 201 B, 4.2 KB against 4.8 KB, 18 KB against 28 KB; decode equal | the channel-escaping pass and type tags; output is 11–28% smaller |
| commKit | AceComm-3.0 with ChatThrottleLib | slower: send 5.0–19.0×, receive 2.7–4.3× | send-200 4.8 KB against 104 B; larger sends within 10%; receive about equal | a SchedulerKit job per wake and a PoolKit lease per message; the send leaves on the next frame (proposal pending) |
| registry | LibStub | slower, 2.5–9.5× (lookup 9.5×, silent miss 6.3×) | 288 B against 64 B per new library; 0 otherwise | `Get` and `Find` re-validate the name and check for a secret value on every call (`packages/registry/src/Registry.lua:66-71`, `:112-126`) |
| interopKit | LibStub (the bridge side) | slower, 3.1× to reach a LibStub library; exposing a Kit to LibStub has no counterpart | 0 against 0 | the same validation as Registry, per call |
| moduleKit with lifecycleKit | AceAddon-3.0 | create at parity (1.10×); load 2.2×; one module disable and enable 4.3×; all ten 8.3×; ten with a listener each 5.3× | 18.7 KB against 0 per disable-and-enable-all; 28.7 KB against 19.4 KB held per addon of ten modules | the module graph is validated and ordered on every whole-container pass |
| hookKit | AceHook-3.0 | install and unhook slower, 2.4–3.8×; a call through a raw hook 1.66×; an unhooked post-hook 0.91× (faster); calls through pre- and post-hooks are *different work* (isolated, about 2×) | 584–720 B against 288–688 B per install and unhook; 0 per call on both | a hook record and argument validation per install; `pcall` isolation per hooked call |
| commandKit | AceConsole-3.0 | slower: parse 2.2–3.7×, dispatch 4.2–4.7×, register and unregister 682× (64× with the emote scan limited to one index) | parse and dispatch equal (32–97 B against 32–130 B); register 1.75 KB against 96 B | `Register` builds up to 1,024 `EMOTE<n>_CMD<m>` names to refuse a taken emote (`packages/commandKit/src/CommandKit.lua:1696`) |
| localeKit | AceLocale-3.0 | lookup at parity (0.99×); register 1.72×; asking for an unneeded locale 4.1×; first miss 3.3× | register 6.1 KB against 5.2 KB; 6.0 KB against 5.2 KB held per addon | per-call write proxies, value validation and missing-key recording |
| eventKit `Coalesce` (schedulerKit, timerKit) | AceBucket-3.0 | slower: 2.4× per event and per burst, 4.3× to create and remove a bucket | burst 752 B against 528 B; create and remove 3.7 KB against 272 B | a coalescing handle, a scheduler job and an EventKit subscription per bucket |
| optionsKit (with commandKit's `BindOptions`) | AceConfigRegistry-3.0, AceConfigCmd-3.0, AceDBOptions-3.0 | define and check 1.51–1.55×; a typed option command 15–26×; profile group build 21.8×; choosing a profile by command 6.1× | define 177–698 KB against 0.2 KB; 53 KB against 0.7–0.9 KB per command; profile group 6.5 KB against 0 | `Define` copies and indexes the tree and builds a schema per option; every bound command calls `tree:Describe()` over the whole tree (`packages/commandKit/src/CommandKit.lua:2195`); AceDBOptions caches its group per database |
| widgetKit (indicative, fake frames) | AceGUI-3.0 | pooled widget cycle slower, 1.04–2.31×; group layout is *different work* (the fake client's anchor check dominates AceGUI's time) | 0 against 0 per cycle (AceGUI EditBox 256 B) | PoolKit's lease and release bookkeeping per acquire and release (`validatePool`, release accounting in PoolKit) |

**Ahead or at parity.** Profile switch 0.28× with no allocation (AceDB 496 B);
EventKit dispatch to 10 listeners 0.95×, to 100 at parity; SignalKit bus
dispatch to 10 and 100 at parity; large decode 0.90×; a call through an
unhooked post-hook 0.91×; locale lookup 0.99×; addon creation 1.10×; repeating
timer tick 1.09×. CodecKit encodes with less garbage at every size and writes
11–28% fewer bytes.

**Behind, largest gap first** (worst median ratio per package):
CommandKit registration 682×; SettingsKit reads 57–71×; OptionsKit command
line 15–26× and profile group build 22×; CommKit send 5–19×; Registry lookup
9.5×; ModuleKit disable-and-enable-all 8.3×; CommandKit dispatch and parsing
2.2–4.7×; EventKit `Coalesce` bucket create and remove 4.3×; LocaleKit unneeded
locale 4.1×; HookKit install 3.8×; InteropKit lookup 3.1×; TimerKit one-shot
3.1×; WidgetKit widget cycle 2.3×; SignalKit bus churn 1.6×; EventKit churn
1.5×; CodecKit small encode 1.5×.

**Advantages outside time**, from the checks:

- *Ordering.* EventKit and SignalKit deliver in connection order
  (CallbackHandler delivered 6 5 4 3 2 1 7 8); ModuleKit disables in reverse
  order and enables a dependency first; WidgetKit releases children last
  first.
- *Bounds.* LocaleKit keeps at most 1,024 missing keys (AceLocale kept 2,000
  of 2,000); EventKit `Coalesce` takes at most 256 keys per interval
  (AceBucket 300 of 300); WidgetKit gives at most 256 widgets of a type
  (AceGUI 300 of 300).
- *Leaks and pending work.* A cancelled TimerKit timer leaves no host timer
  (AceTimer: 1,000 of 1,000 pending, 553 B each); an EventKit bucket leaves no
  timer armed after a delivery (AceBucket re-arms one); unhooking an inherited
  method leaves no field on the object (AceHook writes one).
- *Refusals.* SettingsKit refuses an invalid write; OptionsKit refuses a
  range with `min` above `max`; Registry refuses a fractional revision and
  says why a lookup missed; LocaleKit refuses a non-text translation and
  keeps two addons' registrations apart; CommandKit refuses a name another
  addon holds, handles an escaped quote and refuses an unterminated one.
- *Isolation.* A failing HookKit pre- or post-hook handler is reported and the
  original still runs; with AceHook the call raises. A ModuleKit module whose
  `OnEnable` raised is not reported as enabled.
- *An Ace3 defect.* AceConfigCmd-3.0 (minor 14 at the pinned commit) does not
  enforce a range's `min` and `max` on the command line: it reads `info.min`
  and `info.max`, which its `handle` never sets, so `/cmd g2 scale 5` stored 5
  for a 0.5..2 range. This is the one failed promised check in the summary.
- AceBucket counts arrivals per key; EventKit `Coalesce` delivers `true`
  (reported as *not promised* on the MoltenCodes side).

**Packages with no Ace3 counterpart**, so no comparison:

| Package | What it adds |
|---|---|
| schemaKit | sealed value schemas with structured, secret-safe failures (measured inside settings and options) |
| poolKit | bounded object pools with deterministic ownership (measured inside codec, comm and widgets) |
| cacheKit | bounded LRU and TTL caches, memoisation, snapshots with diffs |
| readinessKit | named readiness gates for late host data, with timeouts and bounded waiters |
| profileKit | zero-cost-when-off performance sections |
| clientKit | client flavour, build floor and probed capabilities |
| compatKit | versioned shims and provider registries with a fallback cascade |
| apiKit | the flavour-aware, typed wrapper over the game API |
| logKit | levelled, structured logging with a bounded journal |
| testKit | in-client test suites (development only) |
| codecKit's compression | a DEFLATE stage; Ace3 has no compressor (LibDeflate is not fetched) |
| brokerKit | LibDataBroker-compatible data objects; its counterpart is LibDataBroker-1.1, not part of Ace3 and not fetched |
| mediaKit | a typed media registry; its counterpart is LibSharedMedia-3.0, not part of Ace3 and not fetched |

### Environment

| | |
|---|---|
| Kind | host (host Lua; never mixed with in-client results) |
| Date | 2026-09-25 |
| CPU | Apple M5 Pro (18 logical CPUs) |
| Memory | 24 GiB |
| OS | macOS 27.0 (26A428), arm64 |
| Lua | Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio |
| Batches | 3 round(s) per case and side, each a fresh process with 2 warm-up, 5 timed and 1 allocation batch |
| Clock | os.clock (process CPU time) |
| Load average (1, 5, 15 min) | 2.14 / 2.30 / 2.29 at the start, 1.31 / 1.80 / 2.07 at the end |
| Empty loop iteration | 0.78 ns (included in every ns/op) |
| MoltenCodes | commit `e43d939233a718457fe47bb90d731e6b9bf5fbb2`, packages/ unmodified |
| Ace3 | `WoWUIDev/Ace3` commit `5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773` |
| Command | `python3 -m tooling.bench.run --out tooling/bench/results/2026-09-25-host-2.json` |

### Summary

Comparable cases: MoltenCodes faster in 4, slower in 69, within noise in 3.
Failed checks of promised behaviour: options / Ace3 / `cmd-range-bounds-enforced`.

### Game-event dispatch

EventKit (on SignalKit) against AceEvent-3.0 events (on CallbackHandler-1.0).

Libraries: MoltenCodes: EventKit revision 17, SignalKit revision 9; Ace3: AceEvent-3.0 minor 4, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `dispatch-1` | UNIT_POWER_UPDATE with 2 payload values to 1 listener(s) | 226 [216–230] | 199 [195–203] | 1.13× (min 1.10×, slower) | 0.0 | 0.0 |
| `dispatch-10` | UNIT_POWER_UPDATE with 2 payload values to 10 listener(s) | 890 [879–938] | 934 [917–966] | 0.95× (min 0.96×, faster) | 0.0 | 0.0 |
| `dispatch-100` | UNIT_POWER_UPDATE with 2 payload values to 100 listener(s) | 7,550 [7,466–7,852] | 7,577 [7,498–7,713] | 1.00× (min 1.00×, within noise) | 0.0 | 0.0 |
| `churn-warm` | connect and disconnect one listener beside 10 others | 466 [457–479] | 362 [347–386] | 1.29× (min 1.32×, slower) | 224 | 0.0 |
| `churn-cold` | connect and disconnect the only listener | 973 [942–1,031] | 637 [621–698] | 1.53× (min 1.52×, slower) | 328 | 104 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `dispatch-1` | listenerCallsPerDispatch | 1 | 1 |
| `dispatch-10` | listenerCallsPerDispatch | 10 | 10 |
| `dispatch-100` | listenerCallsPerDispatch | 100 | 100 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `connect-during-dispatch-waits` | pass: late listener calls: 0 in the dispatch that added it, 1 after the next | pass: late listener calls: 0 in the dispatch that added it, 1 after the next |
| `disconnect-during-dispatch-skips` | pass: listeners that ran after the first removed all: 1 | pass: listeners that ran after the first removed all: 1 |
| `nested-dispatch` | pass: listener calls for one outer and one nested dispatch: 6 of 6 | pass: listener calls for one outer and one nested dispatch: 6 of 6 |
| `error-isolated` | pass: dispatch returned normally: true, other listener ran: 1, errors reported: 1 | pass: dispatch returned normally: true, other listener ran: 1, errors reported: 1 |
| `connection-order` | pass: delivery order of 8 listeners: 1 2 3 4 5 6 7 8 | fail (not promised): delivery order of 8 listeners: 6 5 4 3 2 1 7 8 |

### Addon-message dispatch

a SignalKit bus against AceEvent-3.0 messages (on CallbackHandler-1.0).

Libraries: MoltenCodes: SignalKit revision 9; Ace3: AceEvent-3.0 minor 4, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `dispatch-1` | one message with 2 values to 1 listener(s) | 293 [291–304] | 186 [183–193] | 1.57× (min 1.59×, slower) | 0.0 | 0.0 |
| `dispatch-10` | one message with 2 values to 10 listener(s) | 998 [989–1,015] | 939 [910–957] | 1.06× (min 1.09×, slower) | 0.0 | 0.0 |
| `dispatch-100` | one message with 2 values to 100 listener(s) | 7,694 [7,519–7,853] | 7,599 [7,549–7,794] | 1.01× (min 1.00×, within noise) | 0.0 | 0.0 |
| `churn-warm` | connect and disconnect one listener beside 10 others | 557 [543–572] | 340 [329–365] | 1.64× (min 1.65×, slower) | 224 | 0.0 |
| `churn-cold` | connect and disconnect the only listener | 542 [531–564] | 345 [332–357] | 1.57× (min 1.60×, slower) | 224 | 0.0 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `dispatch-1` | listenerCallsPerDispatch | 1 | 1 |
| `dispatch-10` | listenerCallsPerDispatch | 10 | 10 |
| `dispatch-100` | listenerCallsPerDispatch | 100 | 100 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `connect-during-dispatch-waits` | pass: late listener calls: 0 in the dispatch that added it, 1 after the next | pass: late listener calls: 0 in the dispatch that added it, 1 after the next |
| `disconnect-during-dispatch-skips` | pass: listeners that ran after the first removed all: 1 | pass: listeners that ran after the first removed all: 1 |
| `nested-dispatch` | pass: listener calls for one outer and one nested dispatch: 6 of 6 | pass: listener calls for one outer and one nested dispatch: 6 of 6 |
| `error-isolated` | pass: dispatch returned normally: true, other listener ran: 1, errors reported: 1 | pass: dispatch returned normally: true, other listener ran: 1, errors reported: 1 |
| `connection-order` | pass: delivery order of 8 listeners: 1 2 3 4 5 6 7 8 | fail (not promised): delivery order of 8 listeners: 6 5 4 3 2 1 7 8 |

### Timers on a simulated clock

TimerKit against AceTimer-3.0.

Libraries: MoltenCodes: TimerKit revision 10; Ace3: AceTimer-3.0 minor 17.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `oneshot-create-cancel` | start a 10 s one-shot timer and cancel it | 1,010 [982–1,067] | 329 [320–334] | 3.07× (min 3.07×, slower) | 752 | 512 |
| `oneshot-create-fire` | start a 1 s one-shot timer and let it fire | 991 [978–1,036] | 443 [423–471] | 2.24× (min 2.31×, slower) | 752 | 512 |
| `repeat-tick` | deliver one tick of a 1 s repeating timer (100 running) | 252 [248–269] | 232 [223–249] | 1.09× (min 1.11×, slower) | 0.0 | 0.0 |
| `host-stub-oneshot-create-cancel` | the simulated C_Timer alone, one one-shot start and cancel in this library's style | 215 [208–221] | 105 [100–106] | different work | 224 | 0.0 |
| `host-stub-repeat-tick` | the simulated C_Timer alone, one tick in this library's style | 86.7 [83.9–94.2] | 127 [123–134] | different work | 0.0 | 0.0 |

- `host-stub-oneshot-create-cancel`: host stub cost, not a library cost: NewTimer and Cancel (TimerKit) or After (AceTimer)
- `host-stub-repeat-tick`: host stub cost, not a library cost: After re-armed per tick (AceTimer) or one ticker (TimerKit)

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `oneshot-create-cancel` | cancelledTimers | 1,000 | 1,000 |
| `oneshot-create-cancel` | libraryActiveAfterCancel | 0 | 0 |
| `oneshot-create-cancel` | pendingHostTimersAfterCancel | 0 | 1,000 |
| `oneshot-create-cancel` | retainedBytesPerCancelledTimer | 40.92 | 552.92 |
| `oneshot-create-fire` | firedPerStarted | 1 | 1 |
| `oneshot-create-fire` | pendingHostTimers | 0 | 0 |
| `repeat-tick` | ticksPerExpectedTick | 1 | 1 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `cancelled-oneshot-never-fires` | pass: calls after cancel and 10 s: 0 | pass: calls after cancel and 10 s: 0 |
| `repeat-cancel-from-callback` | pass: ticks of a repeating timer cancelled in its third tick, after 6 s: 3 | pass: ticks of a repeating timer cancelled in its third tick, after 6 s: 3 |
| `fires-in-deadline-order` | pass: order: one, two | pass: order: one, two |
| `nothing-pending-when-idle` | pass: host timers pending: 0, library active: 0 | pass: host timers pending: 0, library active: 0 |

### Saved settings and profiles

SettingsKit (with SchemaKit) against AceDB-3.0.

Libraries: MoltenCodes: SettingsKit revision 6, SchemaKit revision 4, SignalKit revision 9, EventKit revision 17; Ace3: AceDB-3.0 minor 37, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `open-empty` | open a database over a new, empty saved variable | 9,092 [8,819–9,615] | 2,003 [1,900–2,096] | 4.54× (min 4.64×, slower) | 7,235 | 3,299 |
| `open-populated` | open a database over a saved variable with 22 profiles and 50 characters | 9,550 [9,365–10,060] | 4,080 [3,920–4,170] | 2.34× (min 2.39×, slower) | 6,640 | 3,792 |
| `switch-profile` | switch between two existing profiles and read one value | 799 [763–828] | 2,889 [2,850–2,963] | 0.28× (min 0.27×, faster) | 0.0 | 496 |
| `read-default` | read a profile value nothing was saved for | 213 [202–216] | 3.7 [3.5–3.8] | 57.13× (min 57.99×, slower) | 0.0 | 0.0 |
| `read-saved` | read a saved profile value | 199 [196–205] | 3.4 [3.3–3.4] | 59.46× (min 59.97×, slower) | 0.0 | 0.0 |
| `read-nested` | read a nested record value (profile.frame.x) | 448 [441–456] | 6.7 [6.2–7.4] | 67.01× (min 70.48×, slower) | 0.0 | 0.0 |
| `read-entry-default` | read a field of an unsaved keyed entry (profile.auras[118].shown) | 753 [742–764] | 10.7 [10.4–11.0] | 70.63× (min 71.41×, slower) | 0.0 | 0.0 |
| `write-scalar` | write a profile number (profile.scale) | 452 [445–461] | 8.5 [7.1–9.7] | different work | 0.0 | 0.0 |
| `write-nested` | write a nested record value (profile.frame.x) | 1,021 [998–1,029] | 4.9 [4.7–6.6] | different work | 0.0 | 0.0 |
| `validate` | check a write without writing it (db:Validate) | 1,372 [1,335–1,392] | — | one side only | 0.0 | — |

- `switch-profile`: AceDB also strips default-equal values from the old profile on every switch
- `write-scalar`: SettingsKit validates the value and fires its change signal; AceDB stores it unchecked
- `write-nested`: SettingsKit validates the value and fires its change signal; AceDB stores it unchecked
- `validate`: SettingsKit only: AceDB has no validation

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `open-populated` | databasesHeld | 1 | 1 |
| `open-populated` | retainedBytesPerOpenDatabase | 6,168 | 3,872 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `reads-default` | pass: fontSize: 12 | pass: fontSize: 12 |
| `reads-saved` | pass: scale on Alpha: 1.5 | pass: scale on Alpha: 1.5 |
| `reads-entry-wildcard` | pass: auras[118].shown: true | pass: auras[118].shown: true |
| `profiles-are-separate` | pass: Beta scale 0.75, Beta frame.x 0, Alpha frame.x 42 | pass: Beta scale 0.75, Beta frame.x 0, Alpha frame.x 42 |
| `refuses-invalid-write` | pass: writing a string to a number field raised | fail (not promised): writing a string to a number field was stored |

### Serialisation, compression off

CodecKit (addon channel) against AceSerializer-3.0.

Libraries: MoltenCodes: CodecKit revision 5, PoolKit revision 8; Ace3: AceSerializer-3.0 minor 5.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `encode-small` | serialise the small payload for the addon channel | 5,698 [5,616–5,843] | 3,716 [3,668–3,888] | 1.53× (min 1.53×, slower) | 138 | 201 |
| `decode-small` | deserialise the small payload | 4,743 [4,693–4,914] | 3,794 [3,756–3,817] | 1.25× (min 1.25×, slower) | 512 | 600 |
| `encode-medium` | serialise the medium payload for the addon channel | 147,475 [143,327–152,820] | 98,048 [96,141–105,004] | 1.50× (min 1.49×, slower) | 4,234 | 4,786 |
| `decode-medium` | deserialise the medium payload | 124,865 [122,711–129,861] | 110,936 [109,383–111,610] | 1.13× (min 1.12×, slower) | 20,298 | 20,384 |
| `encode-large` | serialise the large payload for the addon channel | 654,240 [643,190–667,730] | 544,430 [539,030–550,740] | 1.20× (min 1.19×, slower) | 18,120 | 28,080 |
| `decode-large` | deserialise the large payload | 509,910 [496,950–518,650] | 567,170 [563,950–574,090] | 0.90× (min 0.88×, faster) | 71,033 | 71,050 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `encode-small` | outputBytes | 104 | 118 |
| `decode-small` | inputBytes | 104 | 118 |
| `encode-medium` | outputBytes | 3,152 | 3,675 |
| `decode-medium` | inputBytes | 3,152 | 3,675 |
| `encode-large` | outputBytes | 11,736 | 16,311 |
| `decode-large` | inputBytes | 11,736 | 16,311 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `round-trip-small` | pass: decode succeeded: true | pass: decode succeeded: true |
| `channel-safe-small` | pass: no NUL, CR or LF in the output | pass: no NUL, CR or LF in the output |
| `round-trip-medium` | pass: decode succeeded: true | pass: decode succeeded: true |
| `channel-safe-medium` | pass: no NUL, CR or LF in the output | pass: no NUL, CR or LF in the output |
| `round-trip-large` | pass: decode succeeded: true | pass: decode succeeded: true |
| `channel-safe-large` | pass: no NUL, CR or LF in the output | pass: no NUL, CR or LF in the output |
| `truncated-input-refused` | pass: decode returned false | pass: decode returned false |

### Multipart addon messages

CommKit against AceComm-3.0 (with ChatThrottleLib).

Libraries: MoltenCodes: CommKit revision 5, SchedulerKit revision 17, TimerKit revision 10, EventKit revision 17, SignalKit revision 9, PoolKit revision 8; Ace3: AceComm-3.0 minor 14, ChatThrottleLib minor 32, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `send-200` | send a 200-byte message until every chunk left | 13,341 [13,146–13,592] | 701 [666–741] | 19.02× (min 19.73×, slower) | 4,778 | 104 |
| `receive-200` | receive and reassemble a 200-byte message | 942 [922–972] | 295 [284–312] | 3.19× (min 3.24×, slower) | 225 | 0.0 |
| `send-1000` | send a 1000-byte message until every chunk left | 24,000 [23,131–24,467] | 2,723 [2,603–2,894] | 8.81× (min 8.89×, slower) | 6,437 | 2,086 |
| `receive-1000` | receive and reassemble a 1000-byte message | 7,593 [7,442–7,751] | 1,772 [1,712–1,837] | 4.28× (min 4.35×, slower) | 2,014 | 1,703 |
| `send-8000` | send a 8000-byte message until every chunk left | 107,025 [102,450–112,425] | 21,575 [21,225–22,913] | 4.96× (min 4.83×, slower) | 23,223 | 21,679 |
| `receive-8000` | receive and reassemble a 8000-byte message | 36,428 [35,440–37,376] | 13,724 [13,512–14,092] | 2.65× (min 2.62×, slower) | 30,188 | 29,848 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `send-200` | chunks | 1 | 1 |
| `send-200` | framesPerMessage | 1 | 0 |
| `send-200` | wireBytesWithPrefix | 210 | 209 |
| `receive-200` | chunks | 1 | 1 |
| `send-1000` | chunks | 4 | 4 |
| `send-1000` | framesPerMessage | 1 | 0 |
| `send-1000` | wireBytesWithPrefix | 1,052 | 1,040 |
| `receive-1000` | chunks | 4 | 4 |
| `receive-1000` | delivered | yes | yes |
| `receive-1000` | retainedBytesMidStream | 1,257 | 1,023 |
| `send-8000` | chunks | 32 | 32 |
| `send-8000` | framesPerMessage | 1 | 0 |
| `send-8000` | wireBytesWithPrefix | 8,416 | 8,320 |
| `receive-8000` | chunks | 32 | 32 |
| `receive-8000` | delivered | yes | yes |
| `receive-8000` | retainedBytesMidStream | 8,548 | 8,845 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `round-trip-200` | pass: 1 chunk(s), delivered 1 time(s), text equal: true | pass: 1 chunk(s), delivered 1 time(s), text equal: true |
| `round-trip-1000` | pass: 4 chunk(s), delivered 1 time(s), text equal: true | pass: 4 chunk(s), delivered 1 time(s), text equal: true |
| `round-trip-8000` | pass: 32 chunk(s), delivered 1 time(s), text equal: true | pass: 32 chunk(s), delivered 1 time(s), text equal: true |
| `interleaved-senders` | pass: complete messages from two interleaved senders: 2 | pass: complete messages from two interleaved senders: 2 |

### Library registration and lookup

Registry (and InteropKit's LibStub bridge) against LibStub.

Libraries: MoltenCodes: Registry revision 13, InteropKit revision 2; Ace3: LibStub minor 2.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `new-library` | register a library name never seen, at its first revision | 820 [737–1,018] | 326 [276–592] | 2.51× (min 2.67×, slower) | 288 | 64 |
| `upgrade` | register a higher revision of an existing library (same table back) | 825 [810–847] | 308 [301–320] | 2.67× (min 2.69×, slower) | 0.0 | 38 |
| `stale-copy` | register an equal revision of an existing library (refused) | 782 [759–795] | 191 [173–199] | 4.10× (min 4.38×, slower) | 0.0 | 0.0 |
| `lookup` | look up a registered library by name (50 registered) | 638 [637–660] | 66.9 [65.9–68.8] | 9.54× (min 9.66×, slower) | 0.0 | 0.0 |
| `silent-miss` | look up a library nobody registered, without raising | 344 [341–348] | 55.0 [51.2–56.2] | 6.26× (min 6.66×, slower) | 0.0 | 0.0 |
| `foreign-lookup` | reach a LibStub library by its major (InteropKit:Find or LibStub:GetLibrary silent) | 170 [165–172] | 54.5 [53.2–57.5] | 3.12× (min 3.11×, slower) | 0.0 | 0.0 |
| `expose-to-libstub` | make a registered Kit a LibStub library (InteropKit:ExposeToLibStub) | 2,125 [2,051–2,417] | — | one side only | 203 | — |

- `expose-to-libstub`: MoltenCodes only: Ace3 has no bridge from another registry into LibStub

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `lookup` | foundPerLookup | 1 | 1 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `upgrade-keeps-table` | pass: same table: true, previous revision: 1 | pass: same table: true, previous revision: 1 |
| `older-and-equal-refused` | pass: lower: nil, equal: nil | pass: lower: nil, equal: nil |
| `silent-miss-says-why` | pass: result: nil, reason: absent | fail (not promised): result: nil, reason: nil |
| `fractional-revision-refused` | pass: revision 1.5 was refused | fail (not promised): revision 1.5 was accepted |
| `kit-reachable-through-libstub` | pass: exposed as MoltenCodes-CheckExposed-1, LibStub returns the Kit's table: true | — |

### Addons, modules and their lifecycle

ModuleKit with LifecycleKit against AceAddon-3.0.

Libraries: MoltenCodes: ModuleKit revision 18, LifecycleKit revision 14, EventKit revision 17, SignalKit revision 9; Ace3: AceAddon-3.0 minor 13, AceEvent-3.0 minor 4, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `create-addon` | create an addon with 10 modules (not loaded yet) | 21,873 [21,600–22,093] | 19,920 [19,520–20,680] | 1.10× (min 1.11×, slower) | 29,650 | 19,881 |
| `load-addon` | create an addon with 10 modules, then its ADDON_LOADED after login (initialise and enable all) | 64,053 [62,340–65,503] | 28,673 [27,867–31,363] | 2.23× (min 2.24×, slower) | 50,986 | 20,565 |
| `disable-enable-all` | disable and enable an addon's 10 modules | 45,181 [43,942–45,946] | 5,445 [5,369–5,581] | 8.30× (min 8.18×, slower) | 18,656 | 0.0 |
| `disable-enable-module` | disable and enable one module | 2,947 [2,894–3,017] | 680 [653–693] | 4.33× (min 4.43×, slower) | 392 | 0.0 |
| `disable-enable-all-listening` | disable and enable 10 modules that each hold one game-event listener while enabled | 72,793 [71,933–73,498] | 13,722 [13,500–13,824] | 5.30× (min 5.33×, slower) | 26,440 | 104 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `create-addon` | retainedBytesPerAddon | 28,714.08 | 19,447.28 |
| `load-addon` | onEnableCallsPerAddon | 10 | 10 |
| `load-addon` | retainedBytesPerLoadedAddon | 28,210.88 | 20,132.08 |
| `disable-enable-all` | onEnableCallsPerCycle | 10 | 10 |
| `disable-enable-module` | onEnableCallsPerCycle | 1 | 1 |
| `disable-enable-all-listening` | onEnableCallsPerCycle | 10 | 10 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `enable-in-creation-order` | pass: enable order: enable:1 enable:2 enable:3 enable:4 | pass: enable order: enable:1 enable:2 enable:3 enable:4 |
| `disable-in-reverse-order` | pass: disable order: disable:4 disable:3 disable:2 disable:1 | fail (not promised): disable order: disable:1 disable:2 disable:3 disable:4 |
| `dependency-enabled-first` | pass: enable order (1 depends on 2): enable:2 enable:1 | fail (not promised): enable order (1 depends on 2): enable:1 enable:2 |
| `failing-module-does-not-stop-others` | pass: other modules enabled: 2 of 2, errors reported: 1 | pass: other modules enabled: 2 of 2, errors reported: 1 |
| `failed-module-not-enabled` | pass: module whose OnEnable raised reports enabled: false | fail (not promised): module whose OnEnable raised reports enabled: true |
| `enable-is-idempotent` | pass: OnEnable calls after load and a second Enable: 1 | pass: OnEnable calls after load and a second Enable: 1 |
| `disable-releases-event-listener` | pass: event registered while enabled: true, after disable: false | pass: event registered while enabled: true, after disable: false |

### Function, method and script hooks

HookKit against AceHook-3.0.

Libraries: MoltenCodes: HookKit revision 5; Ace3: AceHook-3.0 minor 9.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `hook-unhook-function` | pre-hook a global function and unhook it | 2,534 [2,521–2,628] | 674 [648–691] | 3.76× (min 3.89×, slower) | 584 | 288 |
| `hook-unhook-method` | pre-hook a method and unhook it | 2,622 [2,603–2,649] | 1,013 [978–1,031] | 2.59× (min 2.66×, slower) | 584 | 496 |
| `rawhook-unhook-method` | replace a method (raw hook) and unhook it | 2,654 [2,632–2,679] | 1,109 [1,081–1,126] | 2.39× (min 2.44×, slower) | 624 | 688 |
| `hook-unhook-script` | pre-hook a frame's OnShow script and unhook it | 3,406 [3,369–3,439] | 1,126 [1,098–1,145] | 3.02× (min 3.07×, slower) | 584 | 496 |
| `securehook-unhook-method` | post-hook a method (hooksecurefunc) and unhook it, on a fresh object each time | 2,416 [2,382–2,467] | 986 [942–1,110] | 2.45× (min 2.53×, slower) | 720 | 640 |
| `call-prehooked-method` | call a pre-hooked method (empty handler) | 96.2 [95.5–98.3] | 48.4 [44.6–51.3] | different work | 0.0 | 0.0 |
| `call-posthooked-method` | call a post-hooked method (hooksecurefunc, empty handler) | 109 [109–110] | 61.1 [59.9–64.1] | different work | 0.0 | 0.0 |
| `call-rawhooked-method` | call a raw-hooked method whose handler calls the original | 89.4 [87.8–91.9] | 53.7 [51.6–57.8] | 1.66× (min 1.70×, slower) | 0.0 | 0.0 |
| `call-unhooked-posthook` | call a method whose post-hook was unhooked (inert closure left in the chain) | 49.7 [48.3–52.0] | 54.3 [51.5–58.6] | 0.91× (min 0.94×, faster) | 0.0 | 0.0 |
| `call-prehooked-script` | run a frame script that is pre-hooked (empty handler) | 96.7 [96.1–97.7] | 47.2 [44.7–51.2] | different work | 0.0 | 0.0 |

- `call-prehooked-method`: HookKit isolates the handler with pcall and reports its errors; AceHook calls it directly
- `call-posthooked-method`: HookKit isolates the handler with pcall and reports its errors; AceHook calls it directly
- `call-prehooked-script`: HookKit isolates the handler with pcall and reports its errors; AceHook calls it directly

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `hook-unhook-function` | originalRestored | yes | yes |
| `hook-unhook-function` | retainedBytesPerCycle | 0 | 0 |
| `hook-unhook-method` | originalRestored | yes | yes |
| `hook-unhook-method` | retainedBytesPerCycle | 0 | 0 |
| `rawhook-unhook-method` | originalRestored | yes | yes |
| `rawhook-unhook-method` | retainedBytesPerCycle | 0 | 0 |
| `hook-unhook-script` | originalRestored | yes | yes |
| `hook-unhook-script` | retainedBytesPerCycle | 0 | 0 |
| `securehook-unhook-method` | retainedBytesPerRepeatedCycleOnOneTarget | 616 | 472.06 |
| `call-prehooked-method` | resultsReturned | yes | yes |
| `call-posthooked-method` | resultsReturned | yes | yes |
| `call-rawhooked-method` | resultsReturned | yes | yes |
| `call-unhooked-posthook` | resultsReturned | yes | yes |
| `call-prehooked-script` | originalRan | yes | yes |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `prehook-runs-first-and-passes-results` | pass: order: handler original, results returned: 3 | pass: order: handler original, results returned: 3 |
| `unhook-restores-method` | pass: unhook returned true, original back: true | pass: unhook returned true, original back: true |
| `unhook-inherited-method-leaves-no-field` | pass: object has its own Method field after unhook: false | fail (not promised): object has its own Method field after unhook: true |
| `second-hook-refused` | pass: second hook of the same method raised | pass: second hook of the same method raised |
| `unhook-under-foreign-hook-keeps-chain` | pass: later hook still called: 1, result: 7 | pass: later hook still called: 1, result: 7 |
| `prehook-error-isolated` | pass: call returned normally: true, original ran: 1, errors reported: 1 | fail (not promised): call returned normally: false, original ran: 0, errors reported: 0 |
| `posthook-error-isolated` | pass: call returned normally: true | fail (not promised): call returned normally: false |
| `unhooked-posthook-inert` | pass: handler calls: 1 before unhook expected, 1 in all | pass: handler calls: 1 before unhook expected, 1 in all |
| `rawhook-replaces-result` | pass: result: 42 | pass: result: 42 |
| `script-hook-order-and-restore` | pass: order: handler script, script restored: true | pass: order: handler script, script restored: true |
| `nothing-active-after-unhooks` | pass: hooks still active: 0 | pass: hooks still active: 0 |

### Slash commands and argument parsing

CommandKit against AceConsole-3.0.

Libraries: MoltenCodes: CommandKit revision 6, SchemaKit revision 4; Ace3: AceConsole-3.0 minor 7.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `register-unregister` | register a slash command and unregister it (50 foreign commands present) | 251,737 [248,647–254,640] | 369 [348–383] | 682.21× (min 714.50×, slower) | 1,751 | 96 |
| `dispatch-words` | run a typed /command with two words, handed to the handler | 2,014 [1,988–2,125] | 479 [451–509] | 4.20× (min 4.40×, slower) | 66 | 66 |
| `dispatch-subcommand` | run /command scale <number>, checked against 0.5..2 | 2,447 [2,384–2,512] | 519 [495–538] | 4.71× (min 4.81×, slower) | 32 | 32 |
| `register-unregister-one-emote` | register-unregister with the emote check limited to one emote index | 23,764 [23,146–24,175] | — | one side only | 1,683 | — |
| `parse-plain` | split five plain words | 3,852 [3,728–4,083] | 1,054 [1,036–1,092] | 3.66× (min 3.60×, slower) | 97 | 130 |
| `parse-quoted` | split a word and two quoted strings | 2,823 [2,641–2,887] | 835 [791–880] | 3.38× (min 3.34×, slower) | 82 | 81 |
| `parse-link` | split a word, a colour-wrapped item link with spaces, and a word | 2,111 [2,083–2,207] | 978 [926–1,011] | 2.16× (min 2.25×, slower) | 89 | 89 |

- `register-unregister`: CommandKit also checks the name against other addons', chat types and emotes
- `dispatch-subcommand`: Ace3: the handler's own GetArgs, tonumber and bounds test; CommandKit: a sub-command with a number schema
- `register-unregister-one-emote`: CommandKit only, maxEmotes = 1: how much of register-unregister is the emote check

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `dispatch-words` | handlerCallsPerLine | 1 | 1 |
| `dispatch-subcommand` | handlerCallsPerLine | 1 | 1 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `quoted-argument-kept-whole` | pass: second token: two words | pass: second token: two words |
| `item-link-kept-whole` | pass: link token intact: true | pass: link token intact: true |
| `escaped-quote` | pass: second token: say "hi" | fail (not promised): second token: say \ |
| `unterminated-quote-refused` | pass: refused: unterminated quote | fail (not promised): accepted as: open |
| `taken-name-refused` | pass: register returned nil, keys claiming /other1: 1 | fail (not promised): register returned true, keys claiming /other1: 2 |
| `unregistered-command-does-nothing` | pass: handler calls after unregister: 0, key still in SlashCmdList: true | pass: handler calls after unregister: 0, key still in SlashCmdList: false |

### Translations

LocaleKit against AceLocale-3.0.

Libraries: MoltenCodes: LocaleKit revision 2; Ace3: AceLocale-3.0 minor 6.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `register` | register a default locale with 100 strings and get its read table | 24,486 [23,908–25,750] | 14,248 [13,898–15,146] | 1.72× (min 1.72×, slower) | 6,059 | 5,187 |
| `unneeded-locale` | ask for a locale the client does not need (frFR on enUS): nil | 193 [191–198] | 47.5 [45.9–49.2] | 4.06× (min 4.17×, slower) | 0.0 | 0.0 |
| `lookup` | read a defined key from the read table (100 defined) | 13.6 [13.4–14.5] | 13.7 [13.3–14.0] | 0.99× (min 1.00×, within noise) | 0.0 | 0.0 |
| `first-miss` | first read of a key no file defined, silent mode (stored as itself) | 218 [183–535] | 65.8 [59.6–216.1] | 3.31× (min 3.06×, slower) | 0.0 | 0.0 |
| `format` | LocaleKit:Format("%2$s has %1$d items", count, name) | 972 [950–1,013] | — | one side only | 96 | — |

- `first-miss`: LocaleKit's missing-key bound is opened for this row, so both sides store every key
- `format`: LocaleKit only: AceLocale has no formatter

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `register` | retainedBytesPerAddon | 5,993.08 | 5,225.08 |
| `first-miss` | returnedKeyPerMiss | 1 | 1 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `default-keeps-translation` | pass: Greeting: Hello there, Farewell: Farewell | pass: Greeting: Hello there, Farewell: Farewell |
| `missing-reported-once` | pass: reads returned the key: true, reports: 1 | pass: reads returned the key: true, reports: 1 |
| `missing-keys-listed` | pass: keys read but never defined, as listed: 1 | fail (not promised): keys read but never defined, as listed: 0 |
| `interleaved-registration` | pass: a write to the first addon's proxy after the second NewLocale landed in the first addon | fail (not promised): a write to the first addon's proxy after the second NewLocale landed in the second addon |
| `missing-keys-bounded` | pass: distinct missing keys read: 2000, kept in the read table: 1024 | fail (not promised): distinct missing keys read: 2000, kept in the read table: 2000 |
| `non-text-translation-refused` | pass: L.Count = 5 was refused | fail (not promised): L.Count = 5 was stored |

### Event bucketing

SchedulerKit coalescing against AceBucket-3.0.

Libraries: MoltenCodes: EventKit revision 17, SchedulerKit revision 17, TimerKit revision 10, SignalKit revision 9; Ace3: AceBucket-3.0 minor 4, AceEvent-3.0 minor 4, AceTimer-3.0 minor 17, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `record-event` | one event into an open interval, its key already collected (10 units) | 567 [555–576] | 238 [234–246] | 2.39× (min 2.37×, slower) | 0.0 | 0.0 |
| `burst` | a burst of 10 events for 10 units, then the interval ends and delivers it | 8,873 [8,801–8,960] | 3,671 [3,607–3,760] | 2.42× (min 2.44×, slower) | 752 | 528 |
| `register-remove` | create a bucket over 2 events and remove it, beside another bucket | 5,696 [5,589–5,841] | 1,341 [1,292–1,407] | 4.25× (min 4.33×, slower) | 3,664 | 272 |

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `record-event` | deliveries | 8 | 8 |
| `burst` | deliveriesPerBurst | 1.00 | 1.00 |
| `burst` | keysPerDelivery | 10.00 | 10.00 |
| `burst` | pendingHostTimersOneQuietIntervalLater | 0 | 0 |
| `burst` | pendingHostTimersRightAfterDelivery | 0 | 1 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `one-delivery-per-interval` | pass: deliveries: 1, keys: 2 | pass: deliveries: 1, keys: 2 |
| `counts-per-key` | fail (not promised): value delivered for a key sent 3 times: true | pass: value delivered for a key sent 3 times: 3 |
| `idle-after-delivery` | pass: host timers pending right after the delivery: 0, one quiet interval later: 0 | fail (not promised): host timers pending right after the delivery: 1, one quiet interval later: 0 |
| `first-event-starts-interval` | pass: deliveries one interval after the first event, with a second event halfway: 1 | pass: deliveries one interval after the first event, with a second event halfway: 1 |
| `missing-payload-keyed` | pass: an event without a payload was keyed as UNIT_HEALTH | pass: an event without a payload was keyed as nil |
| `keys-per-interval-bounded` | pass: distinct keys sent in one interval: 300, delivered: 256 | fail (not promised): distinct keys sent in one interval: 300, delivered: 300 |
| `error-isolated` | pass: errors reported: 1, other bucket's deliveries: 2 | pass: errors reported: 1, other bucket's deliveries: 2 |
| `removed-bucket-silent` | pass: deliveries after removal: 0, host timers pending: 0 | pass: deliveries after removal: 0, host timers pending: 0 |

### Options tables

OptionsKit (with CommandKit's command line and SettingsKit's profiles) against AceConfigRegistry-3.0, AceConfigCmd-3.0 and AceDBOptions-3.0 (with AceDB-3.0).

Libraries: MoltenCodes: OptionsKit revision 6, CommandKit revision 6, SchemaKit revision 4, SettingsKit revision 6, SignalKit revision 9, EventKit revision 17; Ace3: AceConfigRegistry-3.0 minor 22, AceConfigCmd-3.0 minor 14, AceConsole-3.0 minor 7, AceDBOptions-3.0 minor 17, AceDB-3.0 minor 37, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `define-50` | define and check a 50-option table, then drop it | 241,035 [239,410–243,010] | 159,830 [156,775–162,085] | 1.51× (min 1.53×, slower) | 176,649 | 200 |
| `define-200` | define and check a 200-option table, then drop it | 979,480 [971,320–1,003,120] | 631,180 [616,720–640,680] | 1.55× (min 1.57×, slower) | 697,828 | 201 |
| `cmd-set-range` | type a command setting a range option to a number | 83,003 [82,516–84,042] | 3,944 [3,861–3,990] | 21.05× (min 21.37×, slower) | 53,305 | 768 |
| `cmd-set-toggle` | type a command turning a toggle on or off | 82,401 [80,411–82,850] | 3,164 [3,134–3,280] | 26.04× (min 25.66×, slower) | 53,200 | 736 |
| `cmd-set-select` | type a command choosing a select value by key | 82,774 [82,236–83,710] | 5,017 [4,882–5,118] | 16.50× (min 16.85×, slower) | 53,280 | 736 |
| `cmd-refused` | type a command choosing a value the select does not have | 82,830 [81,712–83,589] | 5,411 [5,279–5,504] | 15.31× (min 15.48×, slower) | 53,641 | 932 |
| `profile-options-build` | build the profile options group for a database | 5,240 [5,084–5,383] | 240 [230–247] | 21.83× (min 22.10×, slower) | 6,460 | 0.0 |
| `profile-choose-cmd` | type a command choosing the profile (Alpha and Beta in turn) | 36,193 [35,864–36,607] | 5,964 [5,848–6,071] | 6.07× (min 6.13×, slower) | 11,314 | 1,761 |
| `tree-get` | read a range option through the tree (tree:Get) | 322 [316–348] | — | one side only | 0.0 | — |
| `tree-set` | write a range option through the tree (tree:Set, checked and signalled) | 1,202 [1,185–1,225] | — | one side only | 0.0 | — |

- `define-50`: Ace3 checks on the first GetOptionsTable; OptionsKit also copies, indexes and builds schemas
- `define-200`: Ace3 checks on the first GetOptionsTable; OptionsKit also copies, indexes and builds schemas
- `cmd-set-range`: CommandKit echoes the new value and describes the tree once per command; AceConfigCmd prints nothing
- `cmd-set-toggle`: CommandKit echoes the new value and describes the tree once per command; AceConfigCmd prints nothing
- `cmd-set-select`: CommandKit echoes the new value and describes the tree once per command; AceConfigCmd prints nothing
- `cmd-refused`: both print the refusal; CommandKit describes the tree once per command
- `profile-options-build`: AceDBOptions reuses one group per database and one shared args table; OptionsKit builds a new group
- `profile-choose-cmd`: includes each database's own profile switch
- `tree-get`: OptionsKit only: AceConfigRegistry has no call that reads or writes an option
- `tree-set`: OptionsKit only: AceConfigRegistry has no call that reads or writes an option

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `cmd-set-range` | chatLinesPerCommand | 1 | 0 |
| `cmd-set-toggle` | chatLinesPerCommand | 1 | 0 |
| `cmd-set-select` | chatLinesPerCommand | 1 | 0 |
| `cmd-refused` | chatLinesPerCommand | 1 | 1 |
| `profile-choose-cmd` | switchesPerCommand | 1.00 | 1.00 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `wrong-field-type-refused` | pass: a label that is a number: refused: OptionsKit:Define tree.args.option.name must be a string | pass: a label that is a number: refused: BenchCheck.args.option.name: expected a string or funcref, got '5' |
| `misspelled-field-refused` | pass: a field named desk: refused: OptionsKit:Define tree.args.option contains unknown field "desk" for type "execute" | pass: a field named desk: refused: BenchCheck.args.option.desk: unknown parameter |
| `min-above-max-refused` | pass: a range with min 2 and max 1: refused: OptionsKit:Define tree.args.option.min must not be greater than max | fail (not promised): a range with min 2 and max 1: accepted |
| `cmd-range-bounds-enforced` | pass: typed 5 for a 0.5..2 range; stored value: 1, said: /benchcheck set: expected number <= 2, found larger number | fail: typed 5 for a 0.5..2 range; stored value: 5, said: nil |
| `cmd-unknown-option-reported` | pass: said: /benchcheck set: unknown option "g1.nosuch" | pass: said: /benchcheck g1 : 'nosuch' - unknown argument |
| `cmd-select-ignores-case` | pass: typed bottom; stored: BOTTOM | pass: typed bottom; stored: BOTTOM |
| `cmd-input-pattern-enforced` | pass: typed bad*text for ^[%w ]*$; stored: "" | pass: typed bad*text for ^[%w ]*$; stored: "" |
| `cmd-profile-chosen` | pass: current profile after choosing Beta: Beta | pass: current profile after choosing Beta: Beta |

### Widgets on the fake client (indicative)

WidgetKit against AceGUI-3.0 on the shared fake client.

Libraries: MoltenCodes: WidgetKit revision 8, PoolKit revision 8, SignalKit revision 9; Ace3: AceGUI-3.0 minor 41.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `cycle-label` | acquire a pooled Label, give it a text or value, release it (fake frames) | 3,491 [3,471–3,524] | 2,839 [2,819–2,851] | 1.23× (min 1.23×, slower) | 0.0 | 0.0 |
| `cycle-button` | acquire a pooled Button, give it a text or value, release it (fake frames) | 2,992 [2,962–3,028] | 1,293 [1,278–1,317] | 2.31× (min 2.32×, slower) | 0.0 | 0.0 |
| `cycle-checkbox` | acquire a pooled CheckBox, give it a text or value, release it (fake frames) | 3,370 [3,358–3,391] | 3,252 [3,203–3,330] | 1.04× (min 1.05×, slower) | 0.0 | 0.0 |
| `cycle-slider` | acquire a pooled Slider, give it a text or value, release it (fake frames) | 4,912 [4,849–4,950] | 2,243 [2,219–2,283] | 2.19× (min 2.19×, slower) | 0.0 | 0.0 |
| `cycle-editbox` | acquire a pooled EditBox, give it a text or value, release it (fake frames) | 4,046 [4,001–4,107] | 2,789 [2,759–2,813] | 1.45× (min 1.45×, slower) | 0.0 | 256 |
| `group-10` | acquire a titled group, add 10 labels, lay it out once, release it with its children (fake frames) | 69,040 [67,698–71,004] | 105,022 [101,916–107,232] | different work | 1.4 | 9.5 |
| `group-50` | acquire a titled group, add 50 labels, lay it out once, release it with its children (fake frames) | 306,500 [304,700–314,700] | 1,313,120 [1,191,540–1,348,020] | different work | 6.8 | 64 |
| `relayout-50` | lay out a titled group of 50 labels again (fake frames) | 92,635 [90,950–95,040] | 1,047,615 [1,023,565–1,085,370] | different work | 3.4 | 32 |
| `host-stub-list-anchors-50` | the fake client alone: anchor 50 frames as this library's List layout does, read their heights | 75,975 [73,470–79,845] | 508,145 [477,950–519,700] | different work | 0.0 | 71 |

- `cycle-label`: indicative: fake-client frames, no native frame cost
- `cycle-button`: indicative: fake-client frames, no native frame cost
- `cycle-checkbox`: indicative: fake-client frames, no native frame cost
- `cycle-slider`: indicative: fake-client frames, no native frame cost
- `cycle-editbox`: indicative: fake-client frames, no native frame cost
- `group-10`: not compared: AceGUI chains each child's anchor to the one above and the fake client checks anchor cycles by walking that chain in Lua, which dominates AceGUI's time (see host-stub-list-anchors-50); fake-client frames, indicative only
- `group-50`: not compared: AceGUI chains each child's anchor to the one above and the fake client checks anchor cycles by walking that chain in Lua, which dominates AceGUI's time (see host-stub-list-anchors-50); fake-client frames, indicative only
- `relayout-50`: not compared: AceGUI chains each child's anchor to the one above and the fake client checks anchor cycles by walking that chain in Lua, which dominates AceGUI's time (see host-stub-list-anchors-50); fake-client frames, indicative only
- `host-stub-list-anchors-50`: host stub cost, not a library cost: each anchor to the frame above (AceGUI) or to the content (WidgetKit); the stub checks anchor cycles by walking the chain in Lua

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `cycle-label` | framesCreatedWhileMeasuring | 0 | 0 |
| `cycle-label` | framesPerWidget | 1 | 1 |
| `cycle-button` | framesCreatedWhileMeasuring | 0 | 0 |
| `cycle-button` | framesPerWidget | 1 | 1 |
| `cycle-checkbox` | framesCreatedWhileMeasuring | 0 | 0 |
| `cycle-checkbox` | framesPerWidget | 2 | 1 |
| `cycle-slider` | framesCreatedWhileMeasuring | 0 | 0 |
| `cycle-slider` | framesPerWidget | 3 | 3 |
| `cycle-editbox` | framesCreatedWhileMeasuring | 0 | 0 |
| `cycle-editbox` | framesPerWidget | 4 | 3 |
| `group-10` | framesCreatedWhileMeasuring | 0 | 0 |
| `group-50` | framesCreatedWhileMeasuring | 0 | 0 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `pool-reuses-widget` | pass: same widget after release: true, frames created: 0 | pass: same widget after release: true, frames created: 0 |
| `released-widget-clean` | pass: callback ran: 0, user data: nil, text cleared: true | pass: callback ran: 0, user data: nil, text cleared: true |
| `double-release-refused` | pass: releasing a released widget raised: true | pass: releasing a released widget raised: true |
| `list-layout-in-order` | pass: 5 labels stacked top to bottom in the order added: true | pass: 5 labels stacked top to bottom in the order added: true |
| `children-released-last-first` | pass: release order of 5 children: 5 4 3 2 1 | fail (not promised): release order of 5 children: 1 2 3 4 5 |
| `pool-bounded` | pass: buttons acquired of 300 asked, none released: 256 | fail (not promised): buttons acquired of 300 asked, none released: 300 |
