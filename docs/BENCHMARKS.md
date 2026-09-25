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
`messageDispatch`, `timers`, `settings`, `codec`, `comm`. `--rounds`,
`--repeat` and `--warmup` change the batch counts below. The first run
downloads Ace3 (about 1 MB) into the cache; a full run takes a few minutes.
`--repeat 1 --rounds 1 --warmup 0` is a quick check that everything still runs.

A results file is committed only from a full default run, named after its
date and kind, and its rendered report goes into [Results](#results) below.

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

## In-client plan

The host cannot measure what only the client shows. Those measurements belong
to an in-client runner, which is designed here and not built yet:

- **What it adds.** Frame time p95 and p99 with a synthetic load running
  (listeners on busy events, timers, a comm stream, a settings panel) against
  the same load on the Ace side; garbage-collector steps and memory growth over
  a session of several minutes; UI open and close where WidgetKit and
  OptionsKit have an Ace3 counterpart doing the same (AceGUI-3.0,
  AceConfigDialog-3.0); the cost of `issecretvalue` and `securecallfunction`
  as native calls on Retail 12.x; a real addon-message round trip through the
  client's own throttle.
- **The same workloads.** The workload modules talk to a host only through the
  interface `BenchHost.lua` gives them (`RequireAll`, `Global`, `EventHandler`,
  `Tick`, `timers`, `chat`). A client host implements it over the real API:
  Kits come from Registry instead of `require`, Ace3 from `LibStub`,
  `EventHandler` returns `frame:GetScript("OnEvent")` of the library's frame,
  and the clock is `debugprofilestop()`. Cases that need simulated time (timer
  firing, throttle refills) become frame-driven: they run across real frames
  and report per-frame cost.
- **The addons.** Like the real-client tests
  ([`tests/client/README.md`](../tests/client/README.md)): a harness addon
  `MoltenCodesBench` with a slash command (`/mcb run <workload> <side>`),
  and one load-on-demand addon per side, `MoltenCodesBench_Kits` (the bundle's
  Kits) and `MoltenCodesBench_Ace3` (the libraries copied from the benchmark
  cache at install time, never from the repository), so only one side is in
  memory during a run and a `/reload` separates runs. `tooling.client.install`
  gains a `--bench` target that installs and removes them the way it handles
  the test addons.
- **Results.** The harness saves raw results to its saved variables; a
  `tooling.bench` command reads them with `tooling/client/saved_variables.py`
  into `tooling/bench/results/<date>-client-<flavour>.json`: the same schema
  with `kind = "client"`, the flavour, the client build (`GetBuildInfo`), the
  frame-rate cap, the addons loaded (only the bench addons), and the commits
  of both sides. `report` renders host and client files separately and never
  merges them.

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
  not restrict. A future in-client runner copies Ace3 from the cache into the
  local game folder at install time, again without redistributing it.

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

The first host run,
[`tooling/bench/results/2026-09-25-host.json`](../tooling/bench/results/2026-09-25-host.json),
rendered with `python3 -m tooling.bench.report`. The machine was shared: a game
client and a virtual machine were running, which the load averages show and
which widens the ranges (the slowest batches). The medians and, where the
quartiles do not overlap, the verdicts are what this section relies on.

### What the numbers show

Host Lua only; none of this is a claim about the game client.

- **Advantage.** Switching profiles: SettingsKit takes about 0.37× AceDB's
  time and allocates nothing, where AceDB allocates about 500 bytes per switch.
- **Advantage outside time.** A cancelled TimerKit timer leaves no host timer
  pending; each cancelled AceTimer timer stays queued on the host (1,000 of
  1,000) and keeps about 550 bytes alive until it would have fired, against
  about 40 bytes for TimerKit. CodecKit's output is smaller than
  AceSerializer's: 104 against 118 bytes, 3,152 against 3,675, and 11,736
  against 16,311. Delivery in connection order is promised and checked on the
  MoltenCodes side; CallbackHandler does not promise it and did not keep it.
- **Regressions: dispatch.** EventKit dispatch costs about 1.8 to 2.4× AceEvent
  at 1, 10 and 100 listeners (medians; the quartiles overlap at this load, so
  the report says *within noise*), and connecting plus disconnecting a listener
  4 to 5× as much, with 900 to 1,900 bytes per pair against 0 to 100. The
  SignalKit bus costs 1.9 to 2.9× AceEvent messages per dispatch and about 4×
  per subscribe and unsubscribe (about 550 bytes each).
- **Regressions: timers.** Starting a TimerKit one-shot costs 3.6 to 5.1×
  AceTimer and 1,072 bytes against 512 (224 of TimerKit's bytes are the
  simulated `C_Timer` handle, see `host-stub-oneshot-create-cancel`). A
  repeating tick costs 1.4×, of which the stub is a smaller share on TimerKit's
  side than on AceTimer's.
- **Regressions: settings.** Opening a database costs 17 to 23× AceDB, with
  about 35 KB allocated and 25.5 KB held per open database against 3.3 to
  3.8 KB. Reading through a SettingsKit view costs 0.7 to 3 µs against 9 to
  29 ns for an AceDB table (70 to 126×). Writes are validated and signalled, so
  they are not compared; they cost 1.8 to 2.4 µs, and `Validate` 2.8 µs.
- **Regressions: serialisation.** CodecKit encodes 2.3 to 5.5× slower than
  AceSerializer and allocates about twice as much; it decodes 1.3 to 1.8×
  slower for the small and medium payloads, and the large one is within noise.
- **Regressions: messages.** CommKit sends 6 to 30× slower than AceComm with
  ChatThrottleLib (6.3 KB against 104 bytes allocated for a single-chunk
  message) and receives 4.6 to 7.6× slower. It sends 1 to 3% more bytes on the
  wire (a four-byte chunk header against one) and holds 2.1 KB against 1.0 KB
  for an incomplete 1,000-byte stream.

Every check of promised behaviour passed on both sides.

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
| Load average (1, 5, 15 min) | 4.35 / 4.39 / 3.83 at the start, 6.37 / 5.29 / 4.33 at the end |
| Empty loop iteration | 2.5693 ns (included in every ns/op) |
| MoltenCodes | commit `6dbc76236d962e745990ad1c210e88172d2abed2`, packages/ unmodified |
| Ace3 | `WoWUIDev/Ace3` commit `5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773` |
| Command | `python3 -m tooling.bench.run --out tooling/bench/results/2026-09-25-host.json` |

### Summary

Comparable cases: MoltenCodes faster in 1, slower in 25, within noise in 6.
Every check of promised behaviour passed on both sides.

### Game-event dispatch

EventKit (on SignalKit) against AceEvent-3.0 events (on CallbackHandler-1.0).

Libraries: MoltenCodes: EventKit revision 16, SignalKit revision 8; Ace3: AceEvent-3.0 minor 4, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `dispatch-1` | UNIT_POWER_UPDATE with 2 payload values to 1 listener(s) | 512 [487–1,745] | 214 [208–760] | 2.39× (min 2.34×, within noise) | 0.0 | 0.0 |
| `dispatch-10` | UNIT_POWER_UPDATE with 2 payload values to 10 listener(s) | 1,847 [1,750–6,091] | 1,003 [975–2,742] | 1.84× (min 1.80×, within noise) | 0.0 | 0.0 |
| `dispatch-100` | UNIT_POWER_UPDATE with 2 payload values to 100 listener(s) | 14,771 [14,540–51,087] | 8,086 [7,991–22,589] | 1.83× (min 1.82×, within noise) | 0.0 | 0.0 |
| `churn-warm` | connect and disconnect one listener beside 10 others | 1,846 [1,787–6,787] | 395 [373–1,020] | 4.67× (min 4.79×, slower) | 922 | 0.0 |
| `churn-cold` | connect and disconnect the only listener | 2,796 [2,745–9,324] | 719 [668–801] | 3.89× (min 4.11×, slower) | 1,880 | 104 |

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
| `connection-order` | pass: delivery order of 8 listeners: 1 2 3 4 5 6 7 8 | fail (not promised): delivery order of 8 listeners: 1 7 6 5 4 3 2 8 |

### Addon-message dispatch

a SignalKit bus against AceEvent-3.0 messages (on CallbackHandler-1.0).

Libraries: MoltenCodes: SignalKit revision 8; Ace3: AceEvent-3.0 minor 4, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `dispatch-1` | one message with 2 values to 1 listener(s) | 1,434 [594–1,970] | 502 [198–679] | 2.86× (min 3.00×, slower) | 0.0 | 0.0 |
| `dispatch-10` | one message with 2 values to 10 listener(s) | 4,617 [1,885–6,084] | 2,495 [966–3,410] | 1.85× (min 1.95×, within noise) | 0.0 | 0.0 |
| `dispatch-100` | one message with 2 values to 100 listener(s) | 40,228 [19,350–50,160] | 20,537 [18,102–24,418] | 1.96× (min 1.07×, slower) | 0.0 | 0.0 |
| `churn-warm` | connect and disconnect one listener beside 10 others | 3,818 [3,138–4,784] | 957 [816–1,310] | 3.99× (min 3.84×, slower) | 538 | 0.0 |
| `churn-cold` | connect and disconnect the only listener | 3,867 [3,082–5,082] | 960 [857–1,351] | 4.03× (min 3.60×, slower) | 560 | 0.0 |

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
| `connection-order` | pass: delivery order of 8 listeners: 1 2 3 4 5 6 7 8 | fail (not promised): delivery order of 8 listeners: 7 6 5 4 3 2 1 8 |

### Timers on a simulated clock

TimerKit against AceTimer-3.0.

Libraries: MoltenCodes: TimerKit revision 9; Ace3: AceTimer-3.0 minor 17.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `oneshot-create-cancel` | start a 10 s one-shot timer and cancel it | 4,375 [4,164–4,917] | 859 [610–1,154] | 5.09× (min 6.82×, slower) | 1,072 | 512 |
| `oneshot-create-fire` | start a 1 s one-shot timer and let it fire | 4,432 [3,973–5,283] | 1,246 [983–1,740] | 3.56× (min 4.04×, slower) | 1,072 | 512 |
| `repeat-tick` | deliver one tick of a 1 s repeating timer (100 running) | 889 [740–955] | 633 [528–696] | 1.40× (min 1.40×, slower) | 0.0 | 0.0 |
| `host-stub-oneshot-create-cancel` | the simulated C_Timer alone, one one-shot start and cancel in this library's style | 575 [492–711] | 270 [225–370] | different work | 224 | 0.0 |
| `host-stub-repeat-tick` | the simulated C_Timer alone, one tick in this library's style | 218 [176–247] | 331 [277–365] | different work | 0.0 | 0.0 |

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

Libraries: MoltenCodes: SettingsKit revision 5, SchemaKit revision 4, SignalKit revision 8, EventKit revision 16; Ace3: AceDB-3.0 minor 37, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `open-empty` | open a database over a new, empty saved variable | 139,489 [49,089–172,463] | 6,122 [2,154–7,182] | 22.78× (min 22.78×, slower) | 35,434 | 3,299 |
| `open-populated` | open a database over a saved variable with 22 profiles and 50 characters | 129,215 [45,840–175,590] | 7,505 [4,300–13,740] | 17.22× (min 10.66×, slower) | 34,842 | 3,792 |
| `switch-profile` | switch between two existing profiles and read one value | 2,620 [1,198–3,244] | 7,117 [3,123–8,216] | 0.37× (min 0.38×, faster) | 0.0 | 496 |
| `read-default` | read a profile value nothing was saved for | 794 [351–938] | 8.7 [3.9–11.8] | 90.82× (min 90.55×, slower) | 0.0 | 0.0 |
| `read-saved` | read a saved profile value | 701 [309–761] | 9.8 [3.5–14.9] | 71.79× (min 87.27×, slower) | 0.0 | 0.0 |
| `read-nested` | read a nested record value (profile.frame.x) | 1,940 [1,798–2,875] | 15.4 [6.9–22.6] | 126.01× (min 261.15×, slower) | 0.0 | 0.0 |
| `read-entry-default` | read a field of an unsaved keyed entry (profile.auras[118].shown) | 3,013 [1,357–3,611] | 28.6 [10.6–35.4] | 105.39× (min 127.66×, slower) | 0.0 | 0.0 |
| `write-scalar` | write a profile number (profile.scale) | 1,776 [1,721–4,703] | 9.5 [8.6–31.4] | different work | 0.0 | 0.0 |
| `write-nested` | write a nested record value (profile.frame.x) | 2,443 [2,336–7,866] | 5.3 [5.2–24.8] | different work | 0.0 | 0.0 |
| `validate` | check a write without writing it (db:Validate) | 2,804 [2,709–7,452] | — | one side only | 0.0 | — |

- `switch-profile`: AceDB also strips default-equal values from the old profile on every switch
- `write-scalar`: SettingsKit validates the value and fires its change signal; AceDB stores it unchecked
- `write-nested`: SettingsKit validates the value and fires its change signal; AceDB stores it unchecked
- `validate`: SettingsKit only: AceDB has no validation

Other measurements:

| Case | Measurement | MoltenCodes | Ace3 |
|---|---|---:|---:|
| `open-populated` | databasesHeld | 1 | 1 |
| `open-populated` | retainedBytesPerOpenDatabase | 25,538 | 3,872 |

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

Libraries: MoltenCodes: CodecKit revision 4, PoolKit revision 8; Ace3: AceSerializer-3.0 minor 5.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `encode-small` | serialise the small payload for the addon channel | 22,014 [20,778–88,522] | 4,021 [3,912–17,146] | 5.47× (min 5.31×, slower) | 459 | 201 |
| `decode-small` | deserialise the small payload | 7,343 [7,200–7,738] | 4,102 [3,983–4,147] | 1.79× (min 1.81×, slower) | 512 | 600 |
| `encode-medium` | serialise the medium payload for the addon channel | 348,622 [315,396–1,207,786] | 102,593 [98,686–391,180] | 3.40× (min 3.20×, slower) | 11,608 | 4,786 |
| `decode-medium` | deserialise the medium payload | 151,839 [146,966–159,398] | 118,403 [115,405–120,548] | 1.28× (min 1.27×, slower) | 20,302 | 20,384 |
| `encode-large` | serialise the large payload for the addon channel | 1,313,740 [1,297,830–5,023,420] | 578,220 [559,350–2,234,840] | 2.27× (min 2.32×, within noise) | 62,488 | 28,080 |
| `decode-large` | deserialise the large payload | 1,905,900 [608,180–2,373,780] | 609,470 [596,760–1,874,940] | 3.13× (min 1.02×, within noise) | 71,130 | 71,050 |

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

Libraries: MoltenCodes: CommKit revision 4, SchedulerKit revision 17, TimerKit revision 9, EventKit revision 16, SignalKit revision 8, PoolKit revision 8; Ace3: AceComm-3.0 minor 14, ChatThrottleLib minor 32, CallbackHandler-1.0 minor 8.

| Case | One operation | MoltenCodes ns/op | Ace3 ns/op | MoltenCodes ÷ Ace3 | MoltenCodes B/op | Ace3 B/op |
|---|---|---:|---:|---|---:|---:|
| `send-200` | send a 200-byte message until every chunk left | 22,192 [21,513–90,305] | 740 [715–831] | 30.00× (min 30.09×, slower) | 6,314 | 104 |
| `receive-200` | receive and reassemble a 200-byte message | 1,762 [1,704–1,820] | 324 [308–338] | 5.44× (min 5.53×, slower) | 225 | 0.0 |
| `send-1000` | send a 1000-byte message until every chunk left | 36,801 [35,064–43,287] | 2,933 [2,810–3,087] | 12.55× (min 12.48×, slower) | 7,973 | 2,086 |
| `receive-1000` | receive and reassemble a 1000-byte message | 15,193 [14,625–15,436] | 1,993 [1,904–2,102] | 7.63× (min 7.68×, slower) | 2,864 | 1,638 |
| `send-8000` | send a 8000-byte message until every chunk left | 149,925 [144,787–161,013] | 23,938 [22,825–24,800] | 6.26× (min 6.34×, slower) | 24,761 | 21,679 |
| `receive-8000` | receive and reassemble a 8000-byte message | 68,780 [65,616–72,368] | 15,004 [14,716–15,620] | 4.58× (min 4.46×, slower) | 31,050 | 30,372 |

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
| `receive-1000` | retainedBytesMidStream | 2,105 | 1,023 |
| `send-8000` | chunks | 32 | 32 |
| `send-8000` | framesPerMessage | 1 | 0 |
| `send-8000` | wireBytesWithPrefix | 8,416 | 8,320 |
| `receive-8000` | chunks | 32 | 32 |
| `receive-8000` | delivered | yes | yes |
| `receive-8000` | retainedBytesMidStream | 9,396 | 8,845 |

Checks:

| Check | MoltenCodes | Ace3 |
|---|---|---|
| `round-trip-200` | pass: 1 chunk(s), delivered 1 time(s), text equal: true | pass: 1 chunk(s), delivered 1 time(s), text equal: true |
| `round-trip-1000` | pass: 4 chunk(s), delivered 1 time(s), text equal: true | pass: 4 chunk(s), delivered 1 time(s), text equal: true |
| `round-trip-8000` | pass: 32 chunk(s), delivered 1 time(s), text equal: true | pass: 32 chunk(s), delivered 1 time(s), text equal: true |
| `interleaved-senders` | pass: complete messages from two interleaved senders: 2 | pass: complete messages from two interleaved senders: 2 |
