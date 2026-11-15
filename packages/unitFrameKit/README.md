# UnitFrameKit

UnitFrameKit finds the unit frame shown on screen for a unit token, what LibGetFrame-1.0 gives WeakAuras: the party or raid frame of `party1`, Blizzard's or another addon's, to anchor an aura or a glow to.

```lua
local UnitFrameKit = MoltenCodes.Registries[2]:Get("unitFrameKit", 1)

local frame = UnitFrameKit:GetUnitFrame("party1")
if frame then
  icon:SetPoint("LEFT", frame, "RIGHT", 2, 0)
end

-- Follow frames as units move between them (a roster change, a new layout).
local connection = UnitFrameKit:OnChange(function(frame, unit, previousUnit)
  MyAddon:Reanchor(unit, previousUnit)
end)

-- The nameplate of a unit, when it has one.
local plate = UnitFrameKit:GetNamePlate("nameplate3")
```

What each piece promises:

- **Every unit frame, by its unit attribute.** A scan keeps every visible, non-forbidden `Button` whose `unit` attribute is set, whatever addon made it. A query reads the attribute again and compares it with `UnitIsUnit`, so `"target"` finds the raid frame of the unit you target.
- **Ranked, not guessed.** The caller's patterns come first, then the frames of other addons the Kit knows (ElvUI, Cell, Grid2, Shadowed Unit Frames), then those of addons it does not know, then Blizzard's own. A query answers raid, party and boss frames; `PlayerFrame`, `TargetFrame` and the other single-unit frames answer only for their own token. `options.kinds`, `priorities` and `ignore` change that.
- **Bounded scans.** A scan walks the client's frames with `EnumerateFrames`, 400 per client frame by default, and keeps its place between frames. It runs one second after a roster change, a zone change, the start or end of combat, a boss appearing or a pet changing, with all such events in that second sharing one scan. Nothing runs per frame otherwise.
- **Safe in combat.** Scans and queries only read frames.
- **Bounded memory.** At most 512 frames kept (up to 4096), 64 listeners (up to 512); there is no unbounded setting.

Non-goals: names or GUIDs in place of unit tokens, per-addon workarounds (ElvUI's health bar, Cell's override hook), third-party nameplate addons, arena frames, anchoring (the caller anchors).

### Moving from LibGetFrame-1.0

| LibGetFrame-1.0 | UnitFrameKit |
|---|---|
| `LGF.GetUnitFrame(unit, options)`, `LGF.GetFrame` | `UnitFrameKit:GetUnitFrame(unit, options?)` |
| `options.returnAll = true` | `UnitFrameKit:GetUnitFrames(unit, options?)`, an array in rank order |
| `options.framePriorities` | `options.priorities`, ranked before everything else |
| `options.ignoreFrames` | `options.ignore` |
| `options.ignorePlayerFrame`, `ignoreTargetFrame`, `ignorePartyFrame`, `ignoreRaidFrame`, `ignoreBossFrame` and the other toggles | `options.kinds = { "raid", "party", ... }`: the kinds that answer, in rank order |
| `LGF.getDefaultFramePriorities()`, `getDefaultRaidFrames()` and the other lists | `UnitFrameKit:GetKindPatterns(kind)` |
| `LGF.ScanForUnitFrames()` | `UnitFrameKit:Rescan()` |
| `FRAME_UNIT_ADDED`, `FRAME_UNIT_UPDATE`, `FRAME_UNIT_REMOVED` | `UnitFrameKit:OnChange(callback)`: `(frame, unit, previousUnit)`, `previousUnit` `nil` for an added frame, `unit` `nil` for a removed one |
| `GETFRAME_REFRESH` | No equivalent; `OnChange` reports each frame that changed |
| `LGF.GetUnitNameplate(unit)` | `UnitFrameKit:GetNamePlate(unit)`: Blizzard's plate only |
| A GUID or a name as the unit | Not accepted: pass a unit token |
| `LGF.StartProfile()` and the profiling calls | No equivalent |

LibGetFrame's frame lists are not reused. UnitFrameKit's patterns were written from each addon's own source, cited in [`docs/API.md`](docs/API.md), and an addon it does not know is still found through its frames' unit attribute.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\unitFrameKit\UnitFrameKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `unitFrameKit/UnitFrameKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

UnitFrameKit makes its one event frame at the first query, `OnChange` or `Rescan`, never at load.
