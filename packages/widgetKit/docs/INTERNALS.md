# WidgetKit internals

This document describes how WidgetKit is built: its shared state, pooling, the
layout algorithms and the renderer. The public contract is in
[`API.md`](API.md); nothing here is a promise to consumers.

## Shared state

Registry hands every copy the same package table. Everything that must outlive
an upgrade hangs off it, under `_state`, and is never replaced:

| Field | Holds |
|---|---|
| `schema`, `runtimeRevision` | the state layout version (`1`) and the revision that last committed its functions |
| `types` | type name → type record `{ name, version, constructor, pool, borrowed }`; `borrowed` counts the widgets of each version currently acquired |
| `layouts` | layout name → layout function |
| `records` | widget → widget record, weak-keyed |
| `dispatch` | `build` and `retire`, the pool callbacks, and `closeOpenDropdown`, the catcher's script; rewritten by every copy |
| `widgetMetatable`, `containerMetatable` | `{ __index = Widget }`, `{ __index = Container }` |
| `bindingMetatable`, `renderingMetatable` | the metatables of bindings and renderings |
| `scratch` | the PoolKit table pool layouts borrow from |
| `focus`, `holder`, `layoutDepth` | the focused widget (`false` for none), the hidden holder frame (`false` until first used), the current layout nesting |
| `serial` | the last acquire serial handed out; absent before the first `Create` |
| `buildProblem` | a constructor contract failure `build` leaves for `Create` to raise; cleared at once |
| `dropdownCatcher`, `openDropdown` | the session's click catcher (absent until the first list opens) and the dropdown whose list is open (`false` or absent for none) |

`Container` is a table whose metatable falls back to `Widget`, so a container
finds container methods first, then widget methods. A widget type's own methods
are fields of the widget table and are found before either.

## Widget records

WidgetKit keeps nothing on a widget or its frame. Each widget has a record in
`records`:

```text
typeRecord     the type the widget was built for
active         borrowed and not yet released
releasing      inside Release
isContainer    built with a content frame
parent         the container holding it
children       the container's children (containers only)
maxChildren    the child bound; math.huge for UNBOUNDED, 256 again on release
callbacks      name -> function, created on the first SetCallback
callbackCount  checked against typeRecord.maxCallbacks (math.huge for UNBOUNDED)
userData       key -> value, created on the first SetUserData
fullWidth, fullHeight, relativeWidth
layoutName, layoutFunction, layoutPaused, layingOut
version        the type version whose constructor built it
serial         raised on every acquire
renderings     the renderings drawn into the container, or nil
```

`callbacks`, `userData` and `children` are emptied in place on release rather
than replaced, which is why a warm acquire and release allocate nothing.
`IsReleasing` walks `parent` links upwards and answers `true` at the first
record with `releasing` set.

## Pooling

`RegisterType` creates one PoolKit pool per type:

```lua
PoolKit:New({
    create = function() return dispatch.build(typeRecord) end,
    destroy = function(widget) dispatch.retire(widget) end,
    maxCreated = options.maxCreated or 256,
    generation = version,
})
```

- **Bounded creation.** `maxCreated` caps the frames the type ever builds. With
  no `maxRetained`, PoolKit retains up to the cap, so a release never discards.
- **LIFO.** `Acquire` hands out the most recently released widget.
- **Versions are generations.** The pool's generation is the type version, and
  PoolKit stamps each widget with the generation that built it. A higher
  version calls `pool:SetGeneration(version)`, which retires every retained
  widget of an older generation at once; a borrowed one is retired when it is
  released. Retiring runs `destroy`, which removes the record and parks the
  frame, hidden, on the holder frame. The client still owns that frame, so the
  cap is raised by the number retired (`SetMaxCreated`).
- **Upgrades count one generation.** Each type record keeps the number of
  borrowed widgets per version. An upgrade adds to the cap the pooled widgets
  `SetGeneration` retires and the borrowed widgets of the version it replaces;
  older versions were counted by earlier upgrades. The result is clamped to
  `state.limits.maxCreatedCeiling` (4096 unless `SetLimits` raised it).
- **Validation outside the pool.** `build` checks the constructor's result.
  When it breaks the author contract, `build` leaves a message in
  `state.buildProblem` and raises; `Create` catches the pool's error, finds the
  message and raises it at its own caller. A constructor's own error has no
  message there and is re-raised unchanged.

`Create` marks the record active, stamps it with a new serial, counts it as
borrowed for its version, runs `OnAcquire` and shows the frame. Every other
field is already at its default: `build` sets them and `Release` resets them.
`Release` performs the steps listed in the release contract, then
`pool:Release(widget)`. PoolKit's own `AttachChild` is not used for
children: children come from other pools, their order is WidgetKit's, and a
child must also leave its container's array, which only WidgetKit knows.

## Layout algorithms

`performLayout(container, record)` is the one entry point, used by
`PerformLayout`, `AddChild` and the upward report:

1. refuse when paused, when this container is already inside its pass
   (`"recursion"`), when it or an ancestor is being released, or at nesting
   depth 32 (`"depth"`);
2. resolve the layout: the stored function, or the named layout looked up now;
3. set `layingOut` and raise the nesting depth, so the next step cannot
   recurse;
4. call the type's `OnLayoutStart` hook, borrow a scratch table, call the
   layout under `pcall`, return the scratch table, clear `layingOut`;
   re-raise a layout error;
5. call `LayoutFinished(width, height)`.

`LayoutFinished` remembers the container's height, runs `OnLayoutFinished`, and
when the height changed lays out the parent — unless the parent is paused,
being released, or inside its own pass. Inside a parent's pass the parent reads
the child's new height itself, after the child's `PerformLayout` returns, so a
nested tree is laid out top-down in one pass with no second pass upwards.

### List

```text
width = max(content width, 0); offset = 0
for each shown child:
    anchor TOPLEFT at (0, -offset)
    full width:     also anchor TOPRIGHT at (0, -offset)
    relative width: set width = width * fraction
    container:      lay it out now
    offset = offset + child height
return width, offset
```

### Fill

The first shown child gets `TOPLEFT` and `BOTTOMRIGHT` anchors on the content,
is told its size, and is laid out when it is a container. The layout reports the
content's size, each dimension at least zero.

### Flow

```text
width = max(content width, 0); x = 0; rowTop = 0; rowHeight = 0
for each shown child:
    childWidth = width (full) | width * fraction (relative) | own width
    if x > 0 and (full width or x + childWidth > width + 0.001):
        rowTop = rowTop + rowHeight; x = 0; rowHeight = 0      -- wrap
    anchor TOPLEFT at (x, -rowTop); full width adds TOPRIGHT
    full height: height = max(content height - rowTop, 0)
    container: lay it out now
    rowHeight = max(rowHeight, child height); x = x + childWidth
    full width: close the row
return width, rowTop + rowHeight
```

A child wider than the content on an empty row stays on that row; the layout
never loops over a child that cannot fit. The 0.001-pixel tolerance keeps
children whose relative widths sum to exactly one on one row: ten tenths of a
107-pixel row add up to a hair more than 107 in floating point.

## The renderer

A rendering is a table with the tree, the container, and:

| Field | Holds |
|---|---|
| `_records` | one record per rendered option, in build order |
| `_byPath` | path → record |
| `_nodes` | `{ path, hidden }` for every node visited, hidden ones included |
| `_widgets` | the widgets added directly to the container, which the rendering releases |
| `_busy`, `_pending` | a write in progress, and a refresh asked for during it |

**Build.** The container's layout is paused; `Describe` is walked depth-first;
each visible node gets a widget from its kind (`group` and `multiselect`
become `Group`s whose children are rendered into them, with their own layout
paused), is added to its parent, configured from the node's hints, and shown
the option's value and disabled state read with `Get` and `IsDisabled` (not the
description's copy of the value, which would no longer answer
`issecretvalue`). The container's pause state is restored and
one `PerformLayout` lays out the whole tree top-down. When a widget type is
exhausted, the build stops, everything built is released, and `RenderOptions`
raises.

**Write.** A widget callback calls `writeValue(record, value)`: `Validate`,
then `Set` under `pcall` (`_busy` is raised meanwhile). `Set` fires
`OnChange`, whose `Refresh` only sets `_pending` while a write is in progress;
the write then shows or clears the inline message and runs the pending refresh.
The inline message is a `Label` inserted right after the option's widget in the
same container, which lays that container out; the height change travels up
through `LayoutFinished`.

**Refresh.** When any `_nodes` entry's `IsHidden` differs from what was built,
the rendering is rebuilt. Otherwise every record reads `Get` and `IsDisabled`
and updates its widget in place. Widget setters never fire callbacks, so a
refresh never writes.

**Secrets.** `applyState` checks the value with `issecretvalue` before any
comparison. A multiselect's table value is indexed only after the table itself
passed that check, and each entry is checked before it is compared.

**Ownership.** Every widget acquire raises a session-wide serial kept in the
widget's record. The rendering stores the serial of each widget it acquired,
and of its container, in a weak-keyed `_serials` table; `owns(widget)` is true
only while the widget is active with that same serial. Every refresh, write,
message and release goes through it, so a widget re-acquired by someone else is
never touched. A container's record lists the renderings drawn into it, and
`releaseWidget` releases them before anything else.

**Release.** The tree connection is disconnected first. Then armed
confirmation timers are cancelled, inline messages the rendering still owns are
released, and the widgets in `_widgets` it still owns are released from last to
first (their children with them) — except those whose container is being
released, which go with it. The rendering leaves its container's list, and the
container is laid out once unless it is being released.

## Bindings

A binding holds the frame, the storage table and key, its anchor table, two
reusable rect tables, a SignalKit signal and, when SchedulerKit was registered
when it was made, a debounce handle whose callback saves. `Capture` computes the
frame's and its parent's rectangles in screen coordinates (rect × effective scale),
elects the anchor into the binding's own table with `FromRect`, divides the
offsets by the frame's effective scale, re-anchors the frame, saves or arms the
debounce, and fires the signal. A save always writes a fresh plain table: a
SettingsKit view refuses a table that is a view or carries a metatable, and a
fresh table can never alias the binding's working copy.

## The dropdown catcher

A dropdown list is a child of `UIParent`, not of the widget, so no clipping
parent can cut it off. `openDropdownList` closes any other open list, records
the widget as `state.openDropdown`, shows the session's catcher (created on
first use) and then the list. The catcher is a full-screen frame at the
`FULLSCREEN` strata with the mouse enabled; its `OnMouseDown` calls
`dispatch.closeOpenDropdown`, so a newer copy's code runs for a catcher an older
copy created. The widget's own frame closes its list from `OnHide`.

## Frames WidgetKit creates

Every base widget builds its frames in its constructor with `CreateFrame`,
parented to `UIParent` (or the holder), and sets its scripts there, once. The
one exception is a `Dropdown`'s sixteen list rows, built on its first `Open`
and kept for the widget's life. The
templates used are `UIPanelButtonTemplate`, `UIPanelCloseButton`,
`UICheckButtonTemplate` and `InputBoxTemplate`, present on every supported
client; everything else is drawn with `SetColorTexture`. No widget sets a script
on, or writes a field onto, a frame it did not create. The `ColorPicker` reads
the client's `ColorPickerFrame` and calls its `SetupColorPickerAndShow` with an
info table the widget owns.
