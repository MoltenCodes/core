# EventKit

EventKit is MoltenCodes' World of Warcraft event bridge. It turns Frame `OnEvent` notifications into deterministic subscriptions with SignalKit's dispatch semantics while keeping Frame registration lazy and scoped to active listeners.

## Package contract

- Package: `eventKit`
- Version: `0.11.0`
- API generation: `1`
- Implementation revision: `22`; part `Coalescing`: revision `1`
- Runtime dependencies: Registry API 2, SignalKit API 1
- Parts: `Coalescing` (`src/parts/EventKit-Coalescing.lua`): `Coalesce` and
  `Derive`, timed by TimerKit; optional, embedded after the core
  ([ADR 0001](../../docs/decisions/0001-kit-core-and-parts.md))
- Optional partners: LifecycleKit API 1, found by the first `ForAddon` to close
  addon scopes at logout; for the Coalescing part, TimerKit API 1 (its timing)
  and SchedulerKit API 1 with its Coalescing and Lanes parts (only for a `lane`),
  both found at call time

EventKit is multi-tenant: one shared instance serves every addon in a WoW
session. That shapes five of its guarantees:

- **Listeners are isolated.** One addon's erroring handler is reported through
  the host error handler and never stops delivery to the others.
- **Unit-filter Frames are bounded and reused.** A unit group is released when
  its last listener goes and its Frame returns to a free list; EventKit creates
  at most 64 Frames for unit filters in a session by default, raised for the
  whole session with `EventKit:SetLimits{ maxUnitFrames = n }` up to 512 (see
  "Limits" in [`docs/API.md`](docs/API.md)).
- **`ConnectUnit` accepts at most two unit tokens**, because
  `Frame:RegisterUnitEvent` has two filter slots. A third is an error rather
  than something the client silently drops.
- **The combat log is read once per event.** `ConnectCombatLog(subEvent,
  callback)` calls `CombatLogGetCurrentEventInfo()` once for every combat-log
  listener in the session and routes by sub-event, so the client's hottest
  event costs one read and one lookup however many addons listen. Retail 12
  clients give addon code no event reader (measured on 12.1.0), so there
  `EventKit:IsCombatLogAvailable()` answers `false` and `ConnectCombatLog`
  raises at the caller's line (see "World of Warcraft specifics" in
  [`docs/API.md`](docs/API.md)).
- **An unknown event name is refused at the caller's line.** Where the client
  has `C_EventUtils.IsEventValid`, every subscribing call checks the name with
  it before registering anything, instead of leaving the client's
  `RegisterEvent` to raise an error that names no caller line (see "Event
  names the client does not know" in [`docs/API.md`](docs/API.md)).

## Example

```lua
local Registry = MoltenCodes.Registry
local EventKit = Registry:Get("eventKit", 1)

local connection = EventKit:Connect("PLAYER_LOGIN", function(eventName)
  print("Logged in via", eventName)
end)

-- Later:
connection:Disconnect()
```

Unit-filtered events use the same connection lifecycle:

```lua
local health = EventKit:ConnectUnit("UNIT_HEALTH", function(eventName, unit)
  print(eventName, "for", unit)
end, "player")
```

So do combat-log sub-events. `COMBAT_LOG_EVENT_UNFILTERED` carries no payload;
EventKit reads `CombatLogGetCurrentEventInfo()` once per event and hands every
return to the listeners of that sub-event (or of `"*"`, every sub-event):

```lua
if EventKit:IsCombatLogAvailable() then
  local damage = EventKit:ConnectCombatLog("SPELL_DAMAGE", function(timestamp, subEvent,
      hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
      destGUID, destName, destFlags, destRaidFlags, spellId, spellName, spellSchool, amount)
    print(spellName, "hit", destName, "for", amount)
  end)
end
```

Owner scopes tear down everything an owner subscribed to in one call. They
mirror TimerKit's scopes:

```lua
local events = EventKit:ForAddon("MyAddon")
events:Connect("PLAYER_REGEN_DISABLED", onCombat)
events:ConnectUnit("UNIT_HEALTH", onHealth, "player")

-- The scope closes at logout by itself: LifecycleKit calls
-- EventKit:CloseAddonScopes("MyAddon") when it is loaded, EventKit's own
-- PLAYER_LOGOUT listener does when it is not.
```

`EventKit:CreateScope()` returns a manually owned scope with the same methods.
An addon scope always closes at logout, with or without LifecycleKit, which
EventKit finds through `Registry:Find` without depending on it (see "At logout"
in [`docs/API.md`](docs/API.md)). Closing a scope never cuts short the event
being dispatched: a scoped `PLAYER_LOGOUT` listener still runs even when its
scope is closed first.

Bursts of events coalesce into one callback, and derived values recompute once
per burst, with the Coalescing part embedded; TimerKit times them (found at
call time; EventKit does not depend on it):

```lua
events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.1, function(units)
  for unit in pairs(units) do
    updateHealthBar(unit)
  end
end)

local freeSlots = events:Derive("BAG_UPDATE_DELAYED", countFreeSlots)
```

Without TimerKit, `Coalesce` is refused and `Derive` recomputes on every
event; without the part, both raise with the file to embed. See
[Coalescing events](docs/API.md#coalescing-events).

See [`docs/API.md`](docs/API.md) for the full public contract and edge-case
semantics, including the two ways to listen to the payload-free combat-log
event, the taint consequences of a shared bus, and the measured cost of
listener isolation and of a connection. See [`docs/INTERNALS.md`](docs/INTERNALS.md)
for the listener storage, the channel pool and the upgrade from signal-backed
channels.

## Moving from AceEvent-3.0 and AceBucket-3.0

| Ace3 | EventKit |
|---|---|
| `self:RegisterEvent("EVENT", callback)` | `EventKit:ForAddon(addonName):Connect("EVENT", callback)`; the callback receives the event name first, as Ace3's does |
| `self:RegisterEvent("EVENT", "OnEvent")` | `scope:Connect("EVENT", self, "OnEvent")`: the method must exist when you connect (otherwise the call raises at your line) and is looked up on `self` at every event, as in AceEvent; it is called as `self:OnEvent("EVENT", ...)` |
| `self:RegisterEvent("EVENT")` (method named after the event) | `scope:Connect("EVENT", self)`, which calls `self:EVENT("EVENT", ...)`; on `ConnectUnit` the method name is required: `scope:ConnectUnit("EVENT", self, "OnEvent", "player")` |
| `self:UnregisterEvent("EVENT")` | `connection:Disconnect()` on the handle `Connect` returned |
| `self:UnregisterAllEvents()` | `scope:DisconnectAll()`, or `scope:Close()` to end the scope (a manual scope can be opened again with `scope:Reopen()`); an addon scope closes at logout by itself |
| a Frame of your own with `RegisterUnitEvent` (AceEvent has no unit form) | `scope:ConnectUnit("EVENT", callback, unit1[, unit2])` |
| `COMBAT_LOG_EVENT_UNFILTERED` and `CombatLogGetCurrentEventInfo()` in every handler | `scope:ConnectCombatLog(subEvent, callback)`, one client read per event for every listener |
| AceBucket `RegisterBucketEvent(events, interval, callback)` | `scope:Coalesce(events, interval, callback)`, with the Coalescing part (`eventKit\parts\EventKit-Coalescing.lua`) and TimerKit embedded; no SchedulerKit needed; the set's values are `true`, not counts |
| AceBucket `UnregisterBucket(handle)` | `handle:Close()` |
| AceEvent `RegisterMessage`, `SendMessage` | SignalKit buses: `SignalKit:ForAddon(addonName)` |

See [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#aceevent-30)
for worked examples.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `eventKit/EventKit.lua`.

Direct runtime dependencies: Registry API 2, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load. `Coalesce` and `Derive` are the optional Coalescing part, embedded
after the core and after TimerKit, which times them:

```toc
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\eventKit\parts\EventKit-Coalescing.lua
```

`python3 -m tooling.package.embeds eventKit/Coalescing` prints the full list.
Without the part the two methods raise at the caller with the file to embed,
and `EventKit:HasPart("Coalescing")` answers `false`. SchedulerKit is needed
only for a `lane`, with its Coalescing and Lanes parts. LifecycleKit is
optional too: when it is loaded, `ForAddon` leaves the logout closing of
addon scopes to it.

Memory (resident on Lua 5.1 with debug information, measured 2026-11-15):
the core holds 85 KB and the Coalescing part 37 KB; before the split the
single file held 106 KB.
