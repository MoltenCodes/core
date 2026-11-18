# EditModeKit API

EditModeKit API generation **1** puts addon frames in Blizzard's Edit Mode: a labelled overlay that drags each frame while Edit Mode is open, and positions saved per Edit Mode layout and restored on a layout switch.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
EditModeKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local EditModeKit = MoltenCodes.Registries[2]:Get("editModeKit", 1)
```

EditModeKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `UIParent`, `EventRegistry` | `Register` | `Register` raises at the caller: `EditModeKit:Register needs the client's CreateFrame, UIParent and EventRegistry, which this host does not have`. |
| `EditModeManagerFrame` | the active layout's name; whether Edit Mode is already open when EditModeKit first listens | The layout is named `"default"`; Edit Mode counts as closed until `EditMode.Enter`. |
| `InCombatLockdown` | moves of protected frames | Every move happens at once. |
| `issecretvalue` | every check, every value the client answers; read once at load, and again on each check only when it was absent at load | Nothing is treated as secret. |
| `geterrorhandler` | storage failures | The failure is printed, also when the handler itself raises. |

Edit Mode, the `EventRegistry` events `EditMode.Enter` and `EditMode.Exit`, `EditModeManagerFrame` and `EDIT_MODE_LAYOUTS_UPDATED` exist on Retail, Mists of Pandaria Classic and Classic Era.

## Public surface

| Member | Purpose |
|---|---|
| `Register(frame, storage, options?)` | Put `frame` in Edit Mode, its positions in `storage`; put it where the active layout's position says. Returns the registration. |
| `IsEditing()` | Whether Edit Mode is open. |
| `GetLayoutName()` | The active Edit Mode layout's name, or `"default"`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxRegistrations`; `GetLimits` returns a fresh table. |
| `MAX_REGISTRATIONS`, `REGISTRATIONS_CEILING` | `64`, `256`. |
| `API`, `REVISION` | `1`, `2`. |

A registration:

| Method | Purpose |
|---|---|
| `Unregister()` | Take the frame out of Edit Mode: `true`, or `false` when it already was. The frame stays where it is; a drag under way ends there and is not saved. |
| `Refresh()` | Put the frame where the active layout's saved position says, for instance after a profile change. |
| `GetFrame()` | The registered frame. |

## `EditModeKit:Register(frame, storage, options?)`

`frame` is a frame (a table with `GetCenter` and `StartMoving`), not already registered. `storage` is a table, or a function returning one, read and written as `storage[layoutName] = { x = ..., y = ... }`. A function is called at every read and write, so the positions can follow a profile. `options.label` is the overlay's text; the default is the frame's name, or `Frame`.

The overlay is a child of `frame`, covering it, 20 frame levels above it, hidden until Edit Mode opens. At most `maxRegistrations` frames are registered at once: `EditModeKit:Register holds at most 64 frames; raise maxRegistrations with EditModeKit:SetLimits`.

## Positions

A position `{ x, y }` is the frame's centre minus `UIParent`'s centre, in `UIParent`'s units: the frame's centre times the ratio of the frame's effective scale to `UIParent`'s. Putting a frame there anchors its `CENTER` to `UIParent`'s `CENTER` at `(x, y)` divided by that ratio.

A position is put back when the frame registers, on `Refresh`, after each drag, and for every frame on `EDIT_MODE_LAYOUTS_UPDATED`. A layout without a position, or a position that is not two numbers, leaves the frame where it is.

A drag starts on the overlay (`OnDragStart`, left button) and moves the frame with `StartMoving`; when it ends (`OnDragStop`), the position is saved under the active layout and the frame anchored by it. A drag still under way when Edit Mode closes ends there the same way, saved. One still under way when the frame is unregistered ends where the frame is, unsaved. `StartMoving` acts on the frame itself, so neither case leaves the frame following the cursor (revision 2). `StartMoving` also flags the frame as user-placed, which would let the client restore a named frame from its layout cache at the next login, over the saved position; EditModeKit clears the flag with `SetUserPlaced(false)` right after it (revision 2).

## Combat

When the frame is protected (`frame:IsProtected()`) and `InCombatLockdown()` answers `true`, a move waits: the frame stays where it is and moves on `PLAYER_REGEN_ENABLED`. A drag does not start.

## Storage failures

A storage function that raises, or returns anything but a table, and a storage table that refuses the write, are handed to the host error handler (`EditModeKit storage for My Bars must return a table`); the frame stays where it is and nothing raises.

## Secret values

Every frame, storage, option, limit and receiver is checked with `issecretvalue` first and refused at the caller. A name, layout name, position, scale, centre, frame level or protection answer the client gives as a secret is ignored: the label falls back to `Frame`, the layout to `"default"`, a move or save is skipped, a level counts as 0, and the frame counts as unprotected.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxRegistrations`, frames registered at once | `64` | `EditModeKit:SetLimits({ maxRegistrations = n })` | no | `256`: each holds an overlay frame the session keeps |

Lowering `maxRegistrations` keeps every registration and refuses the next. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line: `EditModeKit:Register options.label must be a non-empty string`; methods called on anything but a registration raise `EditModeKit.Registration:Refresh must be called on an EditModeKit registration; use registration:Refresh(...)`. What the client calls (Edit Mode callbacks, events, drags) never raises.

Every message, raised at the caller's line. `<method>` is the public name called, such as `EditModeKit:Register` or `EditModeKit.Registration:Refresh`.

| Message | Raised by |
|---|---|
| `<method> must be called on the EditModeKit facade; use <method>(...)` | a facade method called on anything but `EditModeKit` |
| `<method> must be called on an EditModeKit registration; use registration:<name>(...)` | a registration method called on anything but a registration handle |
| `EditModeKit:Register frame must be a frame` | anything but a table with `GetCenter` and `StartMoving` |
| `EditModeKit:Register storage must be a table or a function returning one` | |
| `EditModeKit:Register options must be a table or nil` | |
| `EditModeKit:Register options holds an unknown field; it accepts label` | |
| `EditModeKit:Register options.label must be a non-empty string` | also a secret label |
| `EditModeKit:Register frame is already registered; unregister it first` | |
| `EditModeKit:Register holds at most <n> frames; raise maxRegistrations with EditModeKit:SetLimits` | |
| `EditModeKit:Register needs the client's CreateFrame, UIParent and EventRegistry, which this host does not have` | |
| `EditModeKit:SetLimits limits must be a table` | |
| `EditModeKit:SetLimits limits holds an unknown field; it accepts maxRegistrations` | |
| `EditModeKit:SetLimits limits.maxRegistrations must not be a secret value` | |
| `EditModeKit:SetLimits limits.maxRegistrations must be an integer from 1 to 256` | |

Storage failures are reported, not raised; see "Storage failures".

Loading raises `MoltenCodes EditModeKit requires Registry API 2 to be loaded first`, `MoltenCodes EditModeKit requires a valid Registry API 2 facade` or `MoltenCodes EditModeKit package state is corrupted or incomplete`.

A host error handler that itself raises does not turn a reported failure into a second error raised into the client: the failure is printed instead, as on a host without a handler (implementation revision 3).

## Performance

| Path | Cost |
|---|---|
| Edit Mode open | Nothing per frame. |
| `EditMode.Enter`, `EditMode.Exit` | One `Show` or `Hide` per overlay. |
| `EDIT_MODE_LAYOUTS_UPDATED` | One storage read and at most one anchor per frame. |
| A drag | The client's `StartMoving`; one storage write when it ends. |

Overlays given back by `Unregister` are kept and reused by the next `Register`.

## Embedded copies and upgrades

Several addons may embed EditModeKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the registrations, the overlays, the listeners and the limit. The `EventRegistry` callbacks, the event frame's script and every overlay's drag scripts call through a dispatch table in the shared state that every loading revision rewrites, so a frame an older copy registered runs the newest copy's code. The callbacks are registered once per session.
