# EventKit

EventKit is MoltenCodes' World of Warcraft event bridge. It turns Frame `OnEvent` notifications into deterministic SignalKit-backed subscriptions while keeping Frame registration lazy and scoped to active listeners.

## Package contract

- Package: `eventKit`
- Version: `0.9.3`
- API generation: `1`
- Implementation revision: `16`
- Runtime dependencies: Registry API 2, SignalKit API 1
- Optional partners: SchedulerKit API 1, found at call time by `Coalesce` and `Derive`;
  LifecycleKit API 1, found by the first `ForAddon` to close addon scopes at logout

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
per burst, when SchedulerKit is loaded (found at call time; EventKit does not
depend on it):

```lua
events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.1, function(units)
  for unit in pairs(units) do
    updateHealthBar(unit)
  end
end)

local freeSlots = events:Derive("BAG_UPDATE_DELAYED", countFreeSlots)
```

Without SchedulerKit, `Coalesce` is refused and `Derive` recomputes on every
event. See [Coalescing events](docs/API.md#coalescing-events).

See [`docs/API.md`](docs/API.md) for the full public contract and edge-case
semantics, including the two ways to listen to the payload-free combat-log
event, the taint consequences of a shared bus, and the measured cost of
listener isolation.

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
load. SchedulerKit is optional and is not part of this load order: when an
addon also embeds it (after TimerKit, its one required dependency besides
Registry), `Coalesce` and `Derive` find it when they are called. LifecycleKit
is optional too: when it is loaded, `ForAddon` leaves the logout closing of
addon scopes to it.
