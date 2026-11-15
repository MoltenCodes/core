# UnitFrameKit API

UnitFrameKit API generation **1** finds the unit frame shown on screen for a unit token: a sliced, bounded scan of the client's frames, matches ranked across Blizzard's and other addons' unit frames, change notifications, and nameplates.

Implementation revision: **2** (package version 0.1.1).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
UnitFrameKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local UnitFrameKit = MoltenCodes.Registries[2]:Get("unitFrameKit", 1)
```

UnitFrameKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame` | the event frame, made at the first `GetUnitFrame`, `GetUnitFrames`, `OnChange` or `Rescan` | Nothing is ever scanned; every query answers `nil` or `{}`. |
| `EnumerateFrames` | scans | A scan ends at once with nothing kept. |
| `UnitIsUnit` | queries | Every query answers `nil` or `{}`. |
| `UnitExists` | queries: a unit that does not exist answers nothing without looking | Every query looks. |
| `C_NamePlate.GetNamePlateForUnit` | `GetNamePlate` | `GetNamePlate` answers `nil`. |
| `frame:CanBeAccessedInContext()` (Retail) | whether a frame may be read at all | The frame is read when it is not forbidden (`IsForbidden`). |
| `issecretvalue` | every check, every value the client answers | Nothing is treated as secret. |
| `geterrorhandler` | listener failures, a failed scan, the `maxFrames` report | They are printed. |

`EnumerateFrames`, `UnitIsUnit`, `UnitExists`, `C_NamePlate.GetNamePlateForUnit` and the frame methods UnitFrameKit reads (`IsForbidden`, `GetObjectType`, `GetAttribute`, `IsVisible`, `GetName`, `GetParent`, `GetParentKey`) exist on Retail, Mists of Pandaria Classic and Classic Era. `CanBeAccessedInContext` is in the Retail documentation only (`SimpleFrameScriptObjectAPIDocumentation.lua`: "Returns whether the current Lua execution context has permission to access this object", false "when execution is tainted and the object is forbidden or enforcing access restrictions"); UnitFrameKit asks it when the frame has it. `EnumerateFrames` is not in the captured API documentation; warcraft.wiki.gg (`API_EnumerateFrames`) lists it for every game type, and UnitFrameKit checks for it at every scan.

## Public surface

| Member | Purpose |
|---|---|
| `GetUnitFrame(unit, options?)` | The best-ranked frame shown now for `unit`, or `nil`. |
| `GetUnitFrames(unit, options?)` | Every frame shown now for `unit`, best-ranked first, in a new array. |
| `GetNamePlate(unit)` | The nameplate's unit frame for `unit`, or `nil`. |
| `Rescan()` | Ask for a scan on the next client frame. |
| `IsScanning()` | Whether a scan is due or running. |
| `OnChange(callback)` | Hear, after each scan, of every frame whose unit changed. Returns the connection. |
| `GetKindPatterns(kind)` | A copy of the name patterns that give frames `kind`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxFrames`, `scanFramesPerStep`, `maxListeners`; `GetLimits` returns a fresh table. |
| `MAX_FRAMES`, `FRAMES_CEILING` | `512`, `4096`. |
| `SCAN_FRAMES_PER_STEP`, `SCAN_STEP_CEILING` | `400`, `4000`. |
| `MAX_LISTENERS`, `LISTENERS_CEILING` | `64`, `512`. |
| `MAX_PATTERNS` | `64`, the longest list an option accepts. |
| `API`, `REVISION` | `1`, `2`. |

A connection:

| Method | Purpose |
|---|---|
| `Disconnect()` | Stop listening: `true`, or `false` when it already was. Safe inside a notification. |
| `IsConnected()` | Whether the listener still hears changes. |

## Scanning

A scan walks every frame the client hands out through `EnumerateFrames`, at most `scanFramesPerStep` per client frame, and keeps its place between client frames. That is safe because frames are never deleted ("Frames cannot be deleted or garbage collected", warcraft.wiki.gg `API_CreateFrame`) and the walk follows creation order (`API_EnumerateFrames`), so a frame made during a scan comes later in the walk and is seen. A frame that is forbidden, or that `CanBeAccessedInContext` refuses (or answers with a secret), is skipped before any other method of it is called, and so is an unnamed frame whose parent is; the scan goes on with the next frame. The same check runs on every kept frame at each query and on a nameplate.

A frame is kept when it is a `Button`, accessible (above), shown (`IsVisible`), and has a unit: its `unit` attribute with its `unitsuffix` attribute appended, read the way Blizzard's `SecureButton_GetUnit` reads them (`raid1` with suffix `pet` becomes `raidpet1`; `Blizzard_FrameXML/SecureTemplates.lua`, the same in `live`, `classic` and `classic_era`). A button whose `type` attribute is `"cancelaura"` (a secure aura button) is not kept. A unit a button inherits from its parent's attributes is not followed.

A kept frame is filed under its name, or, for an unnamed frame, its parent's name and its parent key: Blizzard's party member frames are unnamed buttons of `PartyFrame` with the keys `MemberFrame1` to `MemberFrame4` on all three clients, filed as `PartyFrame.MemberFrame1`. A frame with neither is not kept. The name decides the frame's kind (below).

A scan runs:

- after the first `GetUnitFrame`, `GetUnitFrames`, `OnChange` or `Rescan`, on the next client frame;
- one second after `PLAYER_ENTERING_WORLD`, `GROUP_ROSTER_UPDATE`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`, `INSTANCE_ENCOUNTER_ENGAGE_UNIT`, or `UNIT_PET` of `player`, `party%d` or `raid%d`; every such event while a scan waits shares it;
- on the next client frame after `Rescan`, which also brings a waiting scan forward.

A request while a scan runs queues exactly one more, run when the first ends. The event frame's `OnUpdate` is set only while a scan waits or runs. When a scan ends, what it kept replaces the cache whole; a query before the first scan ends answers nothing.

A frame hidden when the scan passes it is not kept until the next scan. A scan that raises is dropped, reported through `geterrorhandler`, and not retried until the next event or `Rescan`.

## Queries

`GetUnitFrame(unit, options?)` and `GetUnitFrames(unit, options?)` take a unit token and answer, among the kept frames, those that are shown now, whose unit attribute (read again) names the same unit as `unit` to `UnitIsUnit`, and that rank (below). A frame reassigned to another unit since the scan answers for its new unit. A unit `UnitExists` says does not exist answers nothing.

`options`:

| Field | Meaning | Default |
|---|---|---|
| `kinds` | The kinds that answer, in rank order. | `{ "raid", "party", "boss" }`, plus the asked token's own solo kind. |
| `priorities` | Name patterns (Lua patterns, matched with `string.find`) ranked before everything else, in their order. A frame matching one answers whatever its kind. | none |
| `ignore` | Name patterns never answered, not even through `priorities`. | none |

Each list holds at most 64 entries.

### Kinds

A kind says what a frame shows: `raid`, `party`, `boss`, or a single unit, `player`, `target`, `targettarget`, `focus`. The solo kind of a token answers when the asked token is that token and `kinds` is not given: `GetUnitFrame("target")` answers `TargetFrame`, ranked after the group kinds, and `GetUnitFrame("party1")` never answers `TargetFrame` even while `party1` is targeted.

A frame no pattern names has no kind. It answers every query whose unit it shows, ranked after the frames the Kit knows: an addon the table does not list is still found.

Two of Blizzard's named unit buttons show none of the kinds: `PetFrame` (unit `pet`) and `FocusFrameToT` (the focus's target). The table lists them as Blizzard's without a kind. Like a solo kind, each answers only a query for its own token (`GetUnitFrame("pet")`, and for `FocusFrameToT` the token of the focus's target, `focus` followed by `target`) and only without `kinds`, ranked after every Blizzard kind; `priorities` reach them for any token. Revision 1 ranked them as another addon's frames, so `GetUnitFrame("party1")` answered `FocusFrameToT` before Blizzard's party frame while the focus targeted `party1`.

### Ranking

Lower ranks come first; equal ranks keep scan order (creation order).

1. A frame matching `priorities[n]`: rank `n` (the first pattern it matches).
2. Another addon's frame of a known kind: by the kind's position in `kinds` (or raid, party, boss, solo kind by default).
3. Another addon's frame without a kind.
4. Blizzard's frames: by the kind's position in the same way.
5. Blizzard's `PetFrame` and `FocusFrameToT`, for their own token only.

So with ElvUI's and Blizzard's party frames both shown, `party1` answers ElvUI's; with only Blizzard's, it answers whichever of `CompactPartyFrameMember2` and `PartyFrame.MemberFrame1` is shown. Inside a raid, Blizzard's raid frames rank before its party frames.

### The pattern table

`GetKindPatterns(kind)` returns the patterns of `kind` below; the two rows without a kind are never returned. Blizzard's names were read in Gethe/wow-ui-source, branches `live` (12.1.5, commit `297d7aaa`), `classic` (5.5.4, `e5d9b3a2`) and `classic_era` (1.15.9, `4192ac60`), on 2026-11-15; each other addon's names were read in its own published source on that date. Children of a `SecureGroupHeaderTemplate` header are named `<header>UnitButton<n>` by Blizzard's `Blizzard_RestrictedAddOnEnvironment/SecureGroupHeaders.lua` (all three branches), which the header patterns below rely on.

| Pattern | Kind | Source |
|---|---|---|
| `^CompactRaidFrame%d+$` | raid | Blizzard: `Blizzard_CompactRaidFrames/Blizzard_CompactRaidFrameContainer.lua`, `CreateFrame("Button", "CompactRaidFrame"..unitFramesCreated, ...)` |
| `^CompactRaidGroup%dMember%d$` | raid | Blizzard: `Blizzard_UnitFrame/Shared/CompactRaidGroup.xml` (`$parentMember1` to `5`) and `CompactRaidGroup.lua` (`"CompactRaidGroup"..groupIndex`) |
| `^CompactPartyFrameMember%d$` | party | Blizzard: `Blizzard_UnitFrame/Shared/CompactPartyFrame.lua` (`"CompactPartyFrame"`, inheriting `CompactRaidGroupTemplate`) |
| `^PartyFrame%.MemberFrame%d$` | party | Blizzard: `Blizzard_UnitFrame/Shared/PartyFrame.lua`, pooled buttons with `SetParentKey("MemberFrame"..i)` |
| `^Boss%dTargetFrame$` | boss | Blizzard: `TargetFrame.xml` (`Mainline` and `Classic`), `Boss1TargetFrame` to `Boss5TargetFrame` |
| `^PlayerFrame$` | player | Blizzard: `PlayerFrame.xml` (`Mainline` and `Classic`) |
| `^TargetFrame$` | target | Blizzard: `TargetFrame.xml` |
| `^TargetFrameToT$` | targettarget | Blizzard: `TargetFrame.lua` names the target-of-target button `self:GetName().."ToT"` and gives it the unit `"targettarget"` |
| `^FocusFrame$` | focus | Blizzard: `TargetFrame.xml` |
| `^FocusFrameToT$` | none (Blizzard) | Blizzard: `TargetFrame.xml` has `FocusFrame`'s `OnLoad` create its target-of-target button for the focus's target (`Mainline` line 595, `Classic` line 593), and `TargetFrame.lua` names that button `self:GetName().."ToT"` |
| `^PetFrame$` | none (Blizzard) | Blizzard: `PetFrame.xml` (`Mainline` and `Classic`), `<Button name="PetFrame" ... inherits="... SecureUnitButtonTemplate ...">` |
| `^ElvUF_Raid%dGroup%dUnitButton%d+$` | raid | ElvUI (tukui-org/ElvUI, commit `a3843ac3c4`): `Groups/Raid.lua` loads headers `raid1` to `raid3`; `UnitFrames.lua`, `CreateAndUpdateHeaderGroup`, names groups `'ElvUF_'..name..'Group'..index`, with `E:StringTitle` (`General/Math.lua`) capitalising the first letter |
| `^ElvUF_PartyGroup1UnitButton%d$` | party | ElvUI: the `party` header has one group (`numGroups = 1`) |
| `^ElvUF_Boss%d$` | boss | ElvUI: `Groups/Boss.lua` loads the boss group; `UnitFrames.lua`, `CreateAndUpdateUFGroup`, names each `'ElvUF_'..frameName` |
| `^ElvUF_Player$`, `^ElvUF_Target$`, `^ElvUF_TargetTarget$`, `^ElvUF_Focus$` | player, target, targettarget, focus | ElvUI: `Units/Player.lua`, `Target.lua`, `TargetTarget.lua`, `Focus.lua` load these units; `UnitFrames.lua`, `CreateAndUpdateUF`, names each `'ElvUF_'` and the unit with its first letter, and that of a second `target`, capitalised |
| `^CellRaidFrameHeader%dUnitButton%d+$` | raid | Cell (enderneko/Cell, commit `2fbdca82e7`): `RaidFrames/Groups/RaidFrame.lua`, headers `"CellRaidFrameHeader"..group` and `CellRaidFrameHeader0` |
| `^CellPartyFrameHeaderUnitButton%d$` | party | Cell: `RaidFrames/Groups/PartyFrame.lua`, header `CellPartyFrameHeader` |
| `^Grid2LayoutHeader%d+UnitButton%d+$` | raid | Grid2 (michaelnpsp/Grid2, commit `7efa52db78`): `GridLayout.lua`, headers `"Grid2LayoutHeader"..NUM_HEADERS`; Grid2 lays out party and raid alike |
| `^SUFHeaderraid%d*UnitButton%d+$` | raid | Shadowed Unit Frames (Nevcairiel/ShadowedUnitFrames, commit `dcd7fc4eb5`): `modules/units.lua`, headers `"SUFHeader" .. type` and `"SUFHeader" .. type .. id` |
| `^SUFHeaderpartyUnitButton%d$` | party | Shadowed Unit Frames: the same, type `party` |
| `^SUFHeaderbossUnitButton%d$` | boss | Shadowed Unit Frames: `"SUFHeader" .. type .. "UnitButton" .. id` |
| `^SUFUnitplayer$`, `^SUFUnittarget$`, `^SUFUnittargettarget$`, `^SUFUnitfocus$` | player, target, targettarget, focus | Shadowed Unit Frames: `"SUFUnit" .. unit` |

Left out because they could not be checked in the addon's own published source: VuhDo, HealBot, Plexus, Danders and the other names LibGetFrame-1.0 lists. Their frames are still found, without a kind.

## `GetNamePlate(unit)`

Answers `C_NamePlate.GetNamePlateForUnit(unit)`'s plate's `UnitFrame` child (Blizzard's `Blizzard_NamePlates.xml`, `parentKey="UnitFrame"`, on all three clients), or the plate when it has none. `nil` when there is no plate, the call raises, or the plate is forbidden (`IsForbidden`) or refused by `CanBeAccessedInContext`. Other addons' nameplates are not looked into.

## Change notifications

`OnChange(callback)` calls `callback(frame, unit, previousUnit)` after each scan, once for every frame whose unit differs from the previous scan: `previousUnit` is `nil` for a frame new to the cache, `unit` is `nil` for a frame gone from it (hidden, without its unit, or past `maxFrames`). This is LibGetFrame-1.0's `FRAME_UNIT_ADDED`, `FRAME_UNIT_UPDATE` and `FRAME_UNIT_REMOVED` in one. Listeners run after the new cache is in place, so a query inside one sees it; in connection order; a listener that raises is reported through `geterrorhandler` and the others still run. A listener may call `Rescan` or `Disconnect`.

## Secret values

Every unit, option, pattern, kind, callback, limit and receiver is checked with `issecretvalue` first and refused at the caller. A value the client answers as a secret counts as the safe answer: a secret `unit` or `unitsuffix` attribute is no unit (Retail can return attributes as secrets once a frame carries the `Attributes` aspect), a secret `UnitIsUnit` answer is no match (Retail restricts some unit comparisons), a secret `IsForbidden`, `CanBeAccessedInContext`, object type, visibility or name keeps the frame out, and a secret nameplate is `nil`. A secret `UnitExists` answer lets the query look.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxFrames`, frames a scan keeps | `512` | `UnitFrameKit:SetLimits({ maxFrames = n })` | no | `4096`: each holds a name string and is read by every query |
| `scanFramesPerStep`, frames visited per client frame | `400` | `UnitFrameKit:SetLimits({ scanFramesPerStep = n })` | no | `4000`: the work done in one client frame |
| `maxListeners`, connections at once | `64` | `UnitFrameKit:SetLimits({ maxListeners = n })` | no | `512`: each is called for every change |

A scan that reaches `maxFrames` keeps the first frames and reports once (`UnitFrameKit keeps at most 512 frames; raise maxFrames with UnitFrameKit:SetLimits`); the report comes again only after `maxFrames` changes. A lower `maxFrames` applies from the next scan, a different `scanFramesPerStep` from the next client frame; a lower `maxListeners` keeps every connection and refuses the next. The limits are shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line. A secret value is refused with the same message as a wrong type, except for a limit value, which names it. `<Method>` is the method called, `<field>` one of `kinds`, `priorities`, `ignore`:

| Message | When |
|---|---|
| `UnitFrameKit:<Method> must be called on the UnitFrameKit facade; use UnitFrameKit:<Method>(...)` | A method called with `.` or on another table. |
| `UnitFrameKit:<Method> unit must be a non-empty unit token` | `GetUnitFrame`, `GetUnitFrames`, `GetNamePlate`: `unit` is not a non-empty string. |
| `UnitFrameKit:<Method> options must be a table or nil` | `options` of a query. |
| `UnitFrameKit:<Method> options holds an unknown field; it accepts kinds, priorities, ignore` | Any other key. |
| `UnitFrameKit:<Method> options.<field> must be an array of kinds` (or `of patterns`) | Not a table, or a key that is not an index from 1 to its length. |
| `UnitFrameKit:<Method> options.<field> holds at most 64 kinds` (or `patterns`) | A longer list. |
| `UnitFrameKit:<Method> options.<field>[n] must be a non-empty string` | An entry that is not one. |
| `UnitFrameKit:<Method> options.<field>[n] is not a valid pattern` | An entry `string.find` refuses. |
| `UnitFrameKit:<Method> options.kinds[n] is not a kind; kinds are raid, party, boss, player, target, targettarget, focus` | An unknown kind. |
| `UnitFrameKit:OnChange callback must be a function` | |
| `UnitFrameKit:OnChange holds at most <n> listeners; raise maxListeners with UnitFrameKit:SetLimits` | `maxListeners` connections already. |
| `UnitFrameKit:GetKindPatterns kind must be one of raid, party, boss, player, target, targettarget, focus` | |
| `UnitFrameKit:SetLimits limits must be a table` | |
| `UnitFrameKit:SetLimits limits holds an unknown field; it accepts maxFrames, scanFramesPerStep, maxListeners` | Any other key, or a secret key. |
| `UnitFrameKit:SetLimits limits.<name> must not be a secret value` | |
| `UnitFrameKit:SetLimits limits.<name> must be an integer from 1 to <ceiling>` | |
| `UnitFrameKit.Connection:Disconnect must be called on a UnitFrameKit connection; use connection:Disconnect(...)` (and `IsConnected`) | A connection method on anything but a connection handle. |

At load, `MoltenCodes UnitFrameKit requires Registry API 2 to be loaded first`, `MoltenCodes UnitFrameKit requires a valid Registry API 2 facade` and `MoltenCodes UnitFrameKit package state is corrupted or incomplete` raise at the loading file. What the client calls (events, `OnUpdate`) never raises: a scan that fails, a listener's error and the `maxFrames` report go to `geterrorhandler()`.

## Performance

| Path | Cost |
|---|---|
| No scan due | Nothing: no `OnUpdate`. |
| A scan slice | At most `scanFramesPerStep` frames; per frame `IsForbidden`, `CanBeAccessedInContext` where it exists, and `GetObjectType`, and for a `Button` up to three `GetAttribute` calls and `IsVisible`. A kept frame allocates its name when it is unnamed, and is matched against the pattern table once. |
| The end of a scan | The cache and the working table swap; the old one is wiped and reused, so a scan allocates no tables. One comparison per kept frame for `OnChange`. |
| `GetUnitFrame` | At most `maxFrames` entries; per entry the name patterns of the options, then, for an entry that could rank better, the access check, `IsVisible`, one or two `GetAttribute` calls and one `UnitIsUnit`. Allocates nothing, except a string for a frame with a `unitsuffix` attribute. |
| `GetUnitFrames` | The same for every entry, and the result array. |
| `GetNamePlate` | One `GetNamePlateForUnit` call. |

The cost of a full scan on a loaded Retail interface has not been measured yet; it is to be measured in the benchmark harness before the first release and recorded here.

## Embedded copies and upgrades

Several addons may embed UnitFrameKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the cache, the scan in progress, the event frame, the listeners and the limits. The event frame's `OnEvent` and `OnUpdate` call through a dispatch table in the shared state that every loading revision rewrites, so a scan an older copy started finishes with the newest copy's code. The event frame is made once per session.

Revision 2 changed no state field: a revision 1 copy upgrades in place with its cache, scan, listeners and limits. The cache's kinds are decided when a scan keeps a frame, so `PetFrame` and `FocusFrameToT` rank as Blizzard's from the first scan after the upgrade.
