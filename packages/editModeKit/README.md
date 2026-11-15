# EditModeKit

EditModeKit puts an addon's frames in Blizzard's Edit Mode, what LibEditMode gives addons. While Edit Mode is open, each registered frame shows a labelled blue overlay; dragging it moves the frame, and the position is saved under the active Edit Mode layout. When the player switches layout, every frame goes to the position saved for that layout.

```lua
local EditModeKit = MoltenCodes.Registries[2]:Get("editModeKit", 1)

-- MyAddonDB.positions is a SavedVariables table: { [layoutName] = { x, y } }.
local registration = EditModeKit:Register(MyAddonBars, MyAddonDB.positions, { label = "My Bars" })

-- Or a function, so the positions follow the active profile.
EditModeKit:Register(MyAddonCastBar, function()
  return Profiles:GetCurrent().positions
end)

registration:Unregister()
```

What each piece promises:

- **Blizzard's events, nothing patched.** EditModeKit listens to `EventRegistry`'s `EditMode.Enter` and `EditMode.Exit` and to `EDIT_MODE_LAYOUTS_UPDATED`, and reads the active layout's name from `EditModeManagerFrame`. It never hooks or changes Blizzard's Edit Mode frames.
- **Positions per layout.** A position is the frame's centre offset from `UIParent`'s centre, in `UIParent`'s scale, so it survives a change of the frame's own scale. A layout without a saved position leaves the frame where it is.
- **Combat-safe.** The client refuses to move a protected frame from addon code in combat; such a move, and a drag that would start one, waits for `PLAYER_REGEN_ENABLED`.
- **Nothing per frame.** Work happens when Edit Mode opens or closes, a layout changes or a drag ends.
- **Bounded.** At most 64 frames, up to 256 with `EditModeKit:SetLimits({ maxRegistrations = n })`; each holds an overlay frame the session keeps, so there is no unbounded setting.

Non-goals: Blizzard's own Edit Mode systems and their settings dialog, snapping and grids, frame settings other than the position.

### Moving from LibEditMode

| LibEditMode | EditModeKit |
|---|---|
| `LEM:AddFrame(frame, callback, default)`, the callback saving `point, x, y` per layout | `EditModeKit:Register(frame, storage, { label = ... })`: EditModeKit saves and restores the position itself |
| `LEM:GetActiveLayoutName()` | `EditModeKit:GetLayoutName()` |
| `LEM:IsInEditMode()` | `EditModeKit:IsEditing()` |
| `LEM:RegisterCallback("layout", callback)` | Not needed for positions; for other per-layout data, listen to `EDIT_MODE_LAYOUTS_UPDATED` and read `EditModeKit:GetLayoutName()` |
| `LEM:AddFrameSettings(frame, settings)` | No equivalent: frame settings belong in an OptionsKit tree. |

Positions saved by LibEditMode use their own anchor point; they are not read. A frame registered for the first time stays where it is until it is dragged.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\editModeKit\EditModeKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `editModeKit/EditModeKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

EditModeKit makes its frames when the first frame is registered, never at load.
