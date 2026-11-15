# UnitFrameKit Tests

The UnitFrameKit suite covers:

- scanning: shown buttons kept by their `unit` attribute, `unitsuffix` appended and a raid pet mapped as the client does; unnamed frames named through their parent's name and parent key, and frames without either skipped; forbidden, hidden, non-button, unit-less and aura (`cancelaura`) frames skipped; a frame `CanBeAccessedInContext` refuses (or answers a secret about) skipped while the scan goes on; widgets without the optional methods; `scanFramesPerStep` frames per client frame, resumed in place; frames created during a scan; `OnUpdate` set only while a scan is due or running; events coalesced into one scan a second later, `Rescan` bringing it forward, one more scan queued during a scan; `UNIT_PET` only for the player and group members; `maxFrames` and its single report; a host without `EnumerateFrames` or `CreateFrame`; a scan that raises, dropped and reported;
- ranking: other addons' known frames, then unknown ones, then Blizzard's; the caller's `priorities` first in their order; raid, party and boss by default, a solo kind for its own token; `kinds` in their order; `ignore` over `priorities`; equal ranks in scan order; Blizzard's party frame through its parent key; Blizzard's `PetFrame` and `FocusFrameToT` answering only for their own token, after Blizzard's kinds; `GetKindPatterns` copies;
- queries: nothing before the first scan, a unit found through any token naming it, the unit attribute read again, hidden frames dropped, units that do not exist, a host without `UnitIsUnit` or `UnitExists`, a new array per `GetUnitFrames`; nameplates and their `UnitFrame` child, forbidden or missing plates and a host without `C_NamePlate`; the limits;
- change notifications: frames added, changed and gone after each scan, a listener querying the new cache and asking for another scan, a listener that raises, `Disconnect` inside a notification, `maxListeners`;
- arguments and secrets: every argument failure reported at the caller's line, every method refused on anything but the facade or a connection, the largest options; secret arguments refused, and secret frame answers, attributes, `UnitIsUnit` and `UnitExists` answers, nameplates, event units and elapsed times ignored;
- Registry publication, a duplicate embedded load keeping the cache, yielding to a newer revision, an in-place upgrade where a running scan, the listeners and the limits continue under the new code, an upgrade from a revision 1 copy, refusals of state holding an invalid limit or missing tables, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/UnitFrameKitTestEnv.lua` provides `Widget` and `UnitButton` (stand-in frames with attributes, visibility, names and parent keys, walked by a stand-in `EnumerateFrames` that `VisitCount` counts), `SetUnits` (which token is which unit, for `UnitIsUnit` and `UnitExists`), `SetNamePlate`, `RunScan` (ticks until a scan is done), the secret probe, `LoadRevision` and `NewPackageAtRevision` (a fresh host with the working file loaded as an older revision). The Kit's event frame comes from the shared fixture's `CreateFrame`, so `Emit` and `Tick` drive it.

| Spec | Covers |
|---|---|
| `Scanning_spec.lua` | what a scan keeps, slicing, events, coalescing, queueing, `maxFrames`, a missing host |
| `Ranking_spec.lua` | rank bands, priorities, kinds, the solo-token rule, ignore, `GetKindPatterns` |
| `Queries_spec.lua` | matching, reassigned and hidden frames, nameplates, limits |
| `Callbacks_spec.lua` | `OnChange`, connections, `maxListeners` |
| `Arguments_spec.lua` | argument errors at the caller's line, receivers |
| `SecretValues_spec.lua` | secret arguments refused, secret client answers ignored |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
