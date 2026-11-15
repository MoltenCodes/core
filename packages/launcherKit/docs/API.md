# LauncherKit API

LauncherKit API generation **1** puts BrokerKit objects on the minimap as buttons, keeps their position, hidden and locked state in a table the addon owns, in LibDBIcon-1.0's field names, and lists them in Retail's addon compartment on request.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
BrokerKit.lua
LauncherKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local LauncherKit = MoltenCodes.Registries[2]:Get("launcherKit", 1)
```

LauncherKit does not rely on `require()` at runtime.

### Host facilities

LauncherKit reads these host globals at call time, never at load:

| Facility | Used by | Without it |
|---|---|---|
| `Minimap`, `CreateFrame` | `Register`, placing a button | `Register` raises at the caller: `LauncherKit:Register needs the client's Minimap and CreateFrame, which this host does not have`. |
| `GameTooltip` | hovering a button or a compartment entry | No tooltip; `OnEnter` is called when the object has one. |
| `GetCursorPosition` | dragging | Required while a button is dragged. |
| `GetMinimapShape` | placing a button | The minimap counts as round. |
| `AddonCompartmentFrame` | `AddToCompartment` | `AddToCompartment` answers `nil, "unavailable"`. Retail has it; Mists of Pandaria Classic and Classic Era do not (Blizzard's interface source, branches `live`, `classic` and `classic_era`, 2026-11-15). |
| `issecretvalue` | every check, every saved field read | Nothing is treated as secret. |
| `geterrorhandler` | callbacks that raise, a storage that fails | The failure is printed. |

`GetMinimapShape` is not a Blizzard function. It is a convention minimap addons share: an addon that changes the minimap's shape defines the global, and every addon that places buttons on the minimap asks it.

## Public surface

| Member | Purpose |
|---|---|
| `Register(objectName, storage)` | Put a button on the minimap for the BrokerKit object `objectName`; return its launcher. |
| `Get(objectName)` | The launcher of that object, or `nil`. |
| `AddToCompartment(objectName)` | List the object in Retail's addon compartment: `true`, or `nil, "unavailable"` / `nil, "already"`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxLaunchers`; `GetLimits` returns a fresh table. |
| `MAX_LAUNCHERS`, `LAUNCHERS_CEILING`, `DEFAULT_ANGLE` | `64`, `256`, `225`. |
| `API`, `REVISION` | `1`, `2`. |

A launcher:

| Method | Purpose |
|---|---|
| `Show()` / `Hide()` | Show or hide the button and save `hide` as `false` / `true`. |
| `IsShown()` | Whether the button is shown. |
| `Lock()` / `Unlock()` | Save `lock` as `true` / `false`; a locked button cannot be dragged. |
| `IsLocked()` | Whether the storage says `lock = true`. |
| `Refresh()` | Read the storage again and place and show or hide the button from it. |
| `GetButton()` | The minimap button (a `Button`); its icon texture is `button.icon`. |

## `LauncherKit:Register(objectName, storage)`

`objectName` names an object `BrokerKit:New` created; LauncherKit follows that object for the session. `storage` is a table, or a function returning one each time LauncherKit reads or writes: `function() return db.profile.minimap end` follows a SettingsKit profile switch, with `launcher:Refresh()` called from `db:OnProfileChanged`.

The storage fields, LibDBIcon-1.0's:

| Field | Meaning |
|---|---|
| `minimapPos` | Where the button sits, in degrees counter-clockwise from the right of the minimap's centre. Absent, not a number, `nan` or infinite: `225` (below and left). Written when a drag stops. |
| `hide` | `true`: the button is hidden. Written by `Show` and `Hide`. |
| `lock` | `true`: the button cannot be dragged. Written by `Lock` and `Unlock`. |

LauncherKit never writes any other field and never writes these on its own. A storage function that raises, or returns something other than a table, is reported (`LauncherKit storage for MyAddon must return a table`) and that read or write does nothing; a write the table refuses (a read-only SettingsKit view) is reported. A secret field reads as absent.

`Register` creates one `Button` on `Minimap`: 31 by 31 pixels, strata `MEDIUM`, level 8, the client's tracking-button border and highlight, the object's icon 20 pixels wide, and the scripts below. The button exists until logout, because the client never frees a frame. It is placed at `minimapPos` and shown unless `hide` is `true`.

`Register` raises at the caller, and creates nothing, when:

- `objectName` is a secret (`LauncherKit:Register objectName must not be a secret value`) or not a non-empty string (`LauncherKit:Register objectName must be a non-empty string`);
- BrokerKit has no object of that name: `LauncherKit:Register has no BrokerKit object named Missing; create it with BrokerKit:New first`;
- `storage` is a secret, or neither a table nor a function: `LauncherKit:Register storage must be a table or a function returning one`;
- the object already has a launcher: `LauncherKit:Register MyAddon already has a launcher`;
- `maxLaunchers` launchers exist: `LauncherKit:Register holds at most 64 launchers; raise maxLaunchers with LauncherKit:SetLimits`;
- the host has no `Minimap` or `CreateFrame`.

`LauncherKit:Get(objectName)` refuses the same two kinds of name with `LauncherKit:Get objectName ...`; it answers `nil` for an object without a launcher, existing or not.

## Placement

The button's centre sits 5 pixels outside the minimap's edge, at `minimapPos`. For each quarter of the minimap, the shape `GetMinimapShape()` answers says whether that quarter is round or square:

| Shape | Round quarters |
|---|---|
| `ROUND` (also: no `GetMinimapShape`, an unknown answer, one that raises) | all four |
| `SQUARE` | none |
| `CORNER-TOPLEFT`, `CORNER-TOPRIGHT`, `CORNER-BOTTOMLEFT`, `CORNER-BOTTOMRIGHT` | the one named |
| `SIDE-LEFT`, `SIDE-RIGHT`, `SIDE-TOP`, `SIDE-BOTTOM` | the two on that side |
| `TRICORNER-TOPLEFT`, `TRICORNER-TOPRIGHT`, `TRICORNER-BOTTOMLEFT`, `TRICORNER-BOTTOMRIGHT` | all but the one opposite the named corner |

On a round quarter the button follows the circle (an ellipse on a minimap that is not square). On a square quarter it follows a circle through the square's corner, pulled in by 10 pixels, clamped to the square's edge, so it runs along the side and rounds the corner.

## Scripts

| The client runs | LauncherKit does |
|---|---|
| `OnClick(button, mouseButton)` (any button, on release) | The object's `OnClick(button, mouseButton)`. |
| `OnEnter` | With `OnTooltipShow`: `GameTooltip:SetOwner(button, "ANCHOR_LEFT")`, `OnTooltipShow(GameTooltip)`, `GameTooltip:Show()`. Otherwise the object's `OnEnter(button)`. Nothing while the button is dragged. |
| `OnLeave` | Hides `GameTooltip` when this button owns it, then the object's `OnLeave(button)`. |
| `OnDragStart` (left button) | Unless the storage says `lock = true`: hides its tooltip and follows the cursor every frame (`OnUpdate`). |
| `OnDragStop` | Stops following the cursor and writes the angle the cursor reached to `minimapPos`; a drag the cursor never moved writes nothing. |

Every object callback runs protected: one that raises is reported through `geterrorhandler`, never raised into the client. A cursor position or minimap centre the client answers as a secret is ignored for that frame. A change to the object's `icon`, `iconCoords`, `iconR`, `iconG` or `iconB` redraws the icon at once: the texture, the texture coordinates (all four, default `0, 1, 0, 1`) and the vertex colour (all three, default white).

## `LauncherKit:AddToCompartment(objectName)`

Calls `AddonCompartmentFrame:RegisterAddon` with the table Blizzard documents for a custom entry: `text`, the object's `label` (its name when it has none); `icon`, the object's `icon` when it is a string or a number; `func`, a click that calls the object's `OnClick(AddonCompartmentFrame, mouseButton)`; and `funcOnEnter` / `funcOnLeave`, a hover that shows its `OnTooltipShow` in `GameTooltip`, anchored `ANCHOR_RIGHT` to the entry, and hides it again. Blizzard calls `func(data, menuInputData, menu)` and reads the mouse button from `menuInputData.buttonName` (Blizzard_Minimap/Mainline/AddonCompartment.lua, branch `live`, read 2026-11-15); LauncherKit passes that on, or `"LeftButton"` when the input table is missing. Blizzard sorts the entries by their text and shows an icon string that names an atlas as that atlas, any other as a texture. The entry draws the label and the icon as they were at that call. Blizzard has no way to remove an entry, so it stays until logout, and a second call for the same object answers `nil, "already"`. `objectName` is checked as in `Register`.

## Secret values

Every argument is checked with `issecretvalue` before anything else touches it and refused at the caller: `objectName must not be a secret value`; a secret storage, limits table, limit key or receiver is refused as the wrong kind of value. Saved fields and cursor positions are read through the same check (above).

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxLaunchers`, launchers in the session | `64` | `LauncherKit:SetLimits({ maxLaunchers = n })` | no | `256`: each launcher is a button frame the session keeps until logout |

`SetLimits` accepts `maxLaunchers` alone and raises at the caller, before changing anything, for a limits value that is not a table (`LauncherKit:SetLimits limits must be a table`), any other field (`LauncherKit:SetLimits limits holds an unknown field; it accepts maxLaunchers`), a secret (`LauncherKit:SetLimits limits.maxLaunchers must not be a secret value`), or a value that is not an integer from 1 to 256 (`LauncherKit:SetLimits limits.maxLaunchers must be an integer from 1 to 256`). Only the table's own fields are read: a value its metatable's `__index` would answer is ignored (revision 2). Lowering it keeps every launcher and refuses the next `Register`. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line. Facade methods called without the facade raise `LauncherKit:Register must be called on the LauncherKit facade; use LauncherKit:Register(...)`; launcher methods called on anything else raise `LauncherKit.Launcher:Show must be called on a LauncherKit launcher; use launcher:Show(...)`. What the client calls is reported through `geterrorhandler`, as above.

## Performance

| Path | Cost |
|---|---|
| A button at rest | Nothing runs. |
| Dragging | One placement per frame, only while dragged. |
| An icon change | One BrokerKit signal and three texture calls. |
| `Register` | One button, two textures, one record, one BrokerKit connection. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed LauncherKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the launchers and their buttons, the compartment entries and the limit. A button keeps its scripts and its BrokerKit connection for the session, and a compartment entry keeps its callbacks; all of them call through a dispatch table in the shared state that every loading revision rewrites, so a button an older copy created runs the newest copy's code.
