# WidgetKit internals

This document describes how WidgetKit is built: its shared state, pooling, the
part machinery, the layout algorithms and the renderer. The public contract is in
[`API.md`](API.md); nothing here is a promise to consumers.

## Shared state

Registry hands every copy the same package table. Everything that must outlive
an upgrade hangs off it, under `_state`, and is never replaced:

| Field | Holds |
|---|---|
| `schema`, `runtimeRevision` | the state layout version (`1`) and the revision that last committed its functions |
| `unbounded`, `limits` | the `UNBOUNDED` sentinel and the package-wide limits `maxCreatedCeiling`, `maxDropdownEntries` and `maxListElements` (written at its default by revision 12 when a kept state has none) |
| `types` | type name → type record `{ name, version, constructor, maxCallbacks, maxCreated, created, discarded, borrowed, free, trusted }` (see [Pooling](#pooling)); `maxCallbacks` is `math.huge` for `UNBOUNDED`, and `borrowed` counts the widgets of each version currently acquired. A record a revision 13 or older copy made also has `pool`, its PoolKit pool, until revision 14 adopts it |
| `layouts` | layout name → layout function |
| `records` | widget → widget record, weak-keyed |
| `dispatch` | `closeOpenDropdown`, the catcher's script, `saveBinding`, the save a binding's SchedulerKit debounce calls (since revision 8), and `initializeScrollListRow` and `clickScrollListRow`, a `ScrollList`'s row drawing and row clicks (since revision 12); each entry is rewritten by every copy of the part that owns it. Revisions 13 and older also kept `build` and `retire`, their PoolKit pool callbacks; revision 14 removes both |
| `widgetMetatable`, `containerMetatable` | `{ __index = Widget }`, `{ __index = Container }` |
| `bindingMetatable`, `renderingMetatable` | the metatables of bindings and renderings |
| `scratchFree` | idle layout scratch tables, at most one per layout depth (revision 13 and older kept a PoolKit table pool in `scratch`; revision 14 drops it) |
| `helpers` | the core functions and shared tables parts bind to (see [Parts](#parts)) |
| `parts` | part name → `{ revision, bind, ... }` for every part loaded |
| `standIns` | weak-keyed set of the stand-in functions a core installed for members of parts that are not loaded |
| `rendererExtensions` | the renderer's extension registries (see [Renderer extensions](#renderer-extensions)); absent until the `Renderer` part loads |
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

Each type keeps its own free list in its type record; there is no PoolKit pool
(revision 14 replaced the one-pool-per-type design, see the
[upgrade](#upgrades-from-revision-13) below):

| Field | Holds |
|---|---|
| `free` | an array of the idle widgets of the current version, created by the type's first `Create` |
| `maxCreated` | the cap: frames the type may ever build (256 unless the registration asked for another) |
| `created`, `discarded` | frames built, and widgets retired because a higher version replaced their constructor |
| `borrowed` | version → widgets of that version currently acquired |
| `trusted` | `true` for a type WidgetKit's own part registered: its hooks run without `pcall` |

- **Nothing at load.** A type that is registered but never created costs its
  record only; the free list is made by the first `Create`. Revision 13 built
  thirteen empty PoolKit pools at load (34.6 KB).
- **Bounded creation.** `Create` takes the last idle widget (LIFO) and builds a
  new one only when the free list is empty and `created` is below the cap; at
  the cap it answers `nil, "exhausted"`. Every released widget of the current
  version goes back to the free list, so a release never discards.
- **Versions are generations.** Each record keeps the version whose
  constructor built the widget. A higher version retires every idle widget at
  once (`retireIdle`); a borrowed one of an older version is retired when it
  is released. Retiring removes the record and parks the frame, hidden, on
  the holder frame. The client still owns that frame, so the cap is raised by
  what an upgrade uses up: the idle widgets it retires and the borrowed
  widgets of the version it replaces; older versions were counted by earlier
  upgrades. The result is clamped to `state.limits.maxCreatedCeiling`.
- **Building is the only protected step.** `buildForCreate` runs the
  constructor through `buildWidget` under `pcall`. When the result breaks the
  author contract, `buildWidget` leaves a message in `state.buildProblem` and
  raises; `Create` raises it at its own caller. A constructor's own error is
  passed on unchanged. Taking an idle widget calls nothing protected.
- **Trusted hooks.** `registerBuiltInType`, which only WidgetKit's parts call,
  marks the type trusted: `Create` calls its `OnAcquire` and `releaseWidget` its
  `OnRelease` directly. A type registered or raised through `RegisterType` is
  not trusted, and its hooks keep their `pcall` and their documented failure
  handling. A built-in widget cycle therefore makes no protected call at all.
- **Equal versions from WidgetKit's own parts.** `registerBuiltInType` replaces
  the constructor of a type registered at the same version (the public
  `RegisterType` answers `false, "current"` instead), so the copy of a part
  that registered it first is no longer referenced after an upgrade. Widgets
  that copy built keep its methods, which behave the same at the same version.

`Create` marks the record active, stamps it with a new serial, counts it as
borrowed for its version, runs `OnAcquire` and shows the frame. Every other
field is already at its default: `buildWidget` sets them and `Release` resets
them. `Release` performs the steps listed in the release contract, then puts
the widget on the free list, or retires it when its version is stale.

Both are the hot half of every widget's use, so they do inline what their
helpers do, with the same checks, messages and order: `Create` checks the
facade, then indexes the types with the name and checks the name only when
no type answered (a secret name meets the client's own refusal at the index,
ADR 0002), and `releaseWidget` fires the `OnRelease` callback, calls the
type's hook, wipes a non-empty callback or user-data table (the callback table
is read again after the hooks, which may have set the first callback), reads
the resting parent (`UIParent` when it is a frame, otherwise the holder) and
detaches from a parent only when there is one. `state`, the records and the
type records are WidgetKit's own tables without a metatable, so they are read
and written by plain indexing, not `rawget`/`rawset`; the widget tables a
constructor returned keep `rawget`, because their metatable falls back to the
widget base. Text setters make one call for their checks: `checkText(widget,
text, options, methodName, level)` checks the widget as `activeRecord` would,
then the options and the text.

**The probe rule.** `issecretvalue` is read once, when the core loads, into
`loadedProbe`. When it was absent then, each check reads the global again and
accepts it only as a function, so a probe a host installs later is honoured.
The checks that run for every value (`isSecret`, `validateNumber`,
`validateName`, `refuseSecret`, `checkText`, the `List` layout) inline the
rule; a setter that checks several values (`Slider:SetSliderValues`) resolves
the probe once through `secretProbe()`. Under ADR 0002 a value that only
indexes one of WidgetKit's tables is not probed: a receiver (`records[widget]`
with no `type` test in front), a type or layout name, a user-data key.

**Layout scratch tables.** A layout pass borrows one scratch table
(`acquireScratch`) and gives it back emptied (`releaseScratch`); at most
`MAX_LAYOUT_DEPTH` idle ones are kept, since passes nest at most that deep.

### Upgrades from revision 13

Revision 13 kept each type's widgets in a PoolKit pool whose callbacks called
`dispatch.build` and `dispatch.retire`. Revision 14's core, on its first load
over such a state, adopts each pool (`adoptPool`): it takes the idle widgets
out with `Acquire` while `GetAvailableCount()` is above zero (PoolKit hands out
a retained widget then and never builds), puts them on the free list, copies
`GetCreatedCount`, `GetDiscardedCount` and `GetMaxCreated`, and drops the pool,
which is collected with its maps. A widget borrowed from it comes back to the
free list when it is released. `dispatch.build`, `dispatch.retire` and the
PoolKit table pool in `scratch` are removed, so nothing references revision
13's functions once the parts that replace its types and members have
loaded.

## Parts

The core is `src/WidgetKit.lua`; every widget type, the anchor and binding
code and the renderer are parts, `src/parts/WidgetKit-<Part>.lua`
(`docs/decisions/0001-kit-core-and-parts.md`):

| Part | Registers | Installs |
|---|---|---|
| `Containers` | `Frame` 4, `Group` 3, `ScrollFrame` 1 | |
| `Text` | `Label` 3, `Heading` 3, `Spacer` 1 | |
| `Button`, `CheckBox`, `Slider`, `EditBox`, `ColorPicker`, `ScrollList` | their type (`3`, `4`, `4`, `4`, `4`, `2`) | `ScrollList`: its two `dispatch` entries |
| `Dropdown` | `Dropdown` 4 | `CreateMediaPicker`, `dispatch.closeOpenDropdown`; `fillMediaDropdown` in its part record |
| `Position` | | `Anchor.POINTS`, `FromRect`, `Normalize`, `Apply`, `Read`; `BindPosition`; the binding methods; `dispatch.saveBinding`; `newBinding` in its part record |
| `Renderer` | | `RenderOptions`; the rendering methods; `registerExtension` and `extensions` in its part record |

**Loading.** A part resolves the core with `Registry:Get("widgetKit", 1)` and
raises `MoltenCodes WidgetKit part <Part> requires WidgetKit API 1 to be loaded
first` when the core's state has no `parts` and `helpers`. It returns at once
when `state.parts[<Part>]` already holds an equal or higher revision. Otherwise
it binds, defines its functions, registers its types with
`registerBuiltInType`, writes its members over the stand-ins, and records
`{ revision = PART_REVISION, bind = bind, ... }`. A part can rely on a core at
least as new as the one it shipped with: an addon's own core file loads before
its parts.

**Binding.** A part declares one local per core helper it uses and a
`bind(helpers)` function that assigns them from `state.helpers`; it runs once
at load. Every core that loads afterwards (a newer revision from another
addon) fills `state.helpers` with its own functions and calls each recorded
part's `bind` again. A part therefore always runs the newest core's helpers,
with no table lookup per call and no older helper kept alive. The contract:
`state.helpers` only grows inside API 1; a helper's arguments and meaning never
change, and a changed helper is a new name. The colours are one table,
`helpers.colours` (`label`, `text`, `disabled`, each `{ r, g, b }`), which a
part reads into number locals in `bind`. `readGlobal` and `clientText` are not
helpers: each part that reads globals has its own, so the flavour gate sees
every global read where it happens.

**Stand-ins.** The core lists every member a part provides, by the table it
lives on (the facade, `Anchor`, `Binding`, `Rendering`). For each it keeps the
loaded part's function, or a function an older single-file revision installed;
an empty slot or an earlier core's stand-in gets a new stand-in that raises
`<member> is in WidgetKit's <Part> part, which is not loaded: add
widgetKit\parts\WidgetKit-<Part>.lua to embeds.xml (or rebuild it with python3 -m
tooling.package.embeds)` at its caller's line. The stand-ins are recorded in
the weak-keyed `state.standIns`, so a later core replaces them and never takes
one for a part's member. The facade and the prototypes therefore always pass
every revision's surface check, which Registry runs on the newer facade when
an older copy yields. `Create` raises the same message for a base type whose
part is absent (`BASE_TYPE_PARTS`), and `GetTypeVersion` answers `nil` for it.
`Frame:BindPosition` asks `state.parts.Position` at its call and raises the
message for `Position` when it is absent.

**A single-file copy after a split core.** A revision 13 or older copy that
loads after a revision 14 or later core yields to it and registers nothing, so
its types and members exist only when the matching parts are loaded. The
reverse order keeps working: a split core loaded over revision 13 keeps that
copy's members for parts nobody loaded, and its types keep their revision 13
constructors on the new free lists.

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
5. refuse a container that a hook or the layout released during the pass,
   with `LayoutFinished`'s own message, then finish the pass.

Finishing is `finishLayout(container, record, width, height)`, which the pass
calls directly with sizes it has already checked (since revision 9; before, it
went through the public `LayoutFinished`, which checks its caller's arguments
again). `LayoutFinished` checks them and calls the same function. It remembers
the container's height, runs `OnLayoutFinished`, and
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
    told a width:   call its OnWidthSet hook
    container:      lay it out now
    offset = offset + child height
return width, offset
```

`List` is the default layout and runs once per child per pass, so it calls the
`OnWidthSet` hook and the nested pass itself rather than through `notifySized`
and `callHook`, and reads `issecretvalue` once per pass for the content width
and every child height (`Fill` and `Flow` still use `notifySized`).

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
passed that check, and each entry is checked before it is compared. A secret
value is never handed to a widget: since revision 6 an `input` shows the
placeholder too, because the client's edit box refuses a secret from addon code
(`allowSecret` is still validated, and no longer stored on the rendering).

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

A binding holds the frame, the storage (a table, or a function returning one)
and key, its anchor table, two reusable rect tables, a SignalKit signal and,
when SchedulerKit was registered when it was made, a debounce handle whose
callback calls `dispatch.saveBinding`. `Capture` computes the frame's and its
parent's rectangles in screen coordinates (rect × effective scale), elects the
anchor into the binding's own table with `FromRect`, divides the offsets by the
frame's effective scale, re-anchors the frame, saves or arms the debounce, and
fires the signal. A save always writes a fresh plain table: a SettingsKit view
refuses a table that is a view or carries a metatable, and a fresh table can
never alias the binding's working copy.

The storage is resolved at every save and every `Restore` (`resolveStorage`):
a function is called under `pcall` and must return a table. The write
(`store`) and `Restore`'s read (`fetch`) run under `pcall` too, through two
small functions rather than a closure per call. A save runs after the frame has
moved — from a drag handler, a debounce timer or a release flush — so every
failure goes to the host error handler and the frame keeps the anchor `Capture`
gave it. These helpers sit in a `do` block with `saveBinding` and `Restore`,
because the main chunk peaks at 197 of Lua 5.1's 200 active locals and a block's
locals end with it.

`Anchor.Apply` (and so `Restore`) refuses a `relativeTo` that is the frame
itself before touching anything. Otherwise it borrows a scratch table from the
layouts' pool, copies the frame's points (five values each, from `GetPoint`)
and scale into it, applies the scale, clears the points and calls `SetPoint`
under `pcall`. When the client refuses the point (an anchor cycle), the points
are cleared again, each kept point is set again under `pcall` (a point the
client answered with secret values cannot be set from addon code and stays
lost), and the kept scale is restored when it is a plain number. The table goes
back to the pool either way.

## The dropdown catcher

A dropdown list is a child of `UIParent`, not of the widget, so no clipping
parent can cut it off. `openDropdownList` closes any other open list, records
the widget as `state.openDropdown`, shows the session's catcher (created on
first use) and then the list. The catcher is a full-screen frame at the
`FULLSCREEN` strata with the mouse enabled; its `OnMouseDown` calls
`dispatch.closeOpenDropdown`, so a newer copy's code runs for a catcher an older
copy created. The widget's own frame closes its list from `OnHide`.

The entries themselves are two parallel arrays, `_keys` and `_labels`; the rows only show a window of them from `_offset`. That is why `state.limits.maxDropdownEntries` (1024 by default) may be `UNBOUNDED`: a longer list costs array slots, never frames. `SetList` reads the limit once when it starts, so a `SetLimits` applies to the next list and never cuts one already set.

## ScrollList

A `ScrollList` wraps Blizzard's ScrollBox framework rather than rebuilding it,
because every promised client ships it with the same code: the `live`,
`classic` and `classic_era` branches of Blizzard's UI source (12.1.5, 5.5.4
and 1.15.9, read 2026-11-15) have the same 22 files in
`Blizzard_SharedXML/Shared/Scroll/`, the same `DataProvider.lua` and the same
`FrameFactory.lua`; the differences are Retail's narration hooks and a return
value in the tree view, neither of which a linear list uses.

The constructor checks for `CreateScrollBoxListLinearView`,
`ScrollUtil.InitScrollBoxListWithScrollBar` and `CreateDataProvider` before it
creates a frame, and leaves its refusal in `state.buildProblem` so `Create`
raises it at the caller. It then builds, once per widget:

- the widget's frame, and inside it a `WowScrollBoxList` frame inset by the
  bar's width plus 4 pixels, and a `MinimalScrollBar` (an `EventFrame`, 8
  pixels wide, hidden while nothing scrolls) beside it. `MinimalScrollBar`
  rather than `WowTrimScrollBar`, because the Classic branches load a Classic
  look for the trim bar (`Classic\Scroll\TrimScrollBar.xml`);
- a linear view with `SetElementExtent(20)` and
  `SetElementInitializer("Button", initializer)`. A native frame type has no
  template info, so the extent must be set: the view cannot read it from a
  template. The initializer is a closure made once that calls
  `dispatch.initializeScrollListRow(widget, row, element)`;
- the binding, `ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)`.

The data provider is made by the first `SetElements` or `Insert` and replaced
by every `SetElements` (`CreateDataProvider(elements)` copies the array), so an
empty list holds none. `Insert`, `Remove` and `Clear` change the provider in
place (`Insert` / `InsertAtIndex`, `Remove`, `Flush`); each change makes the
scroll box update at once.

**Rows.** The view makes row frames from its own pool (a `FramePoolCollection`
keyed by the frame type), parented to the box's scroll target, acquires one per
row on display, sizes it to the extent and anchors it, and calls the
initializer for each row it acquired once layout is done. Rows whose element
stays on display are kept, which Blizzard does only when every element is a
table: that, and the view telling rows apart by their element, is why
elements are tables and each appears once. The initializer builds a row's
parts the first time it sees that frame (`buildRowParts`: a highlight, a
selected band, an icon texture and a text font string, `RegisterForClicks`
for both buttons and an `OnClick` that calls
`dispatch.clickScrollListRow`), keeps them in `widget._rowParts[row]`, and
draws the row: the formatter's text and icon through `pcall`, the text
re-anchored only when the icon appears or goes, the colour for the disabled
state, and the band for the selection. The element's index is the row's order
index (`GetOrderIndex`), which the view keeps; `GetElementDataIndex` would
search the list. A kept row's order index moves when an `Insert` or `Remove`
before it shifts the elements, but the view does not call the initializer for
it (`ValidateDataRange` in `ScrollBoxListView.lua` only calls `SetOrderIndex`
on a kept row), so since revision 13 an `Insert` before the end and a `Remove`
call `ReinitializeFrames` when a custom formatter is set (`redrawShiftedRows`);
the default formatter shows no index and skips it. Row frames are never freed and stay with the widget: the next
use of the widget is handed the same frames, so their parts are standard and
never a consumer's.

**Selection** is `widget._value`. A click or `SetValue` redraws the band of
every row on display (`refreshRowStates`, rows whose `GetElementData` accessor
the view has removed skipped), without asking the formatter. Blizzard's
`SelectionBehaviorMixin` is not used: its single select runs
`DeselectByPredicate` over the whole provider, allocating a table and a
closure per select, and `IsElementDataSelected` treats an element with its own
`selected` field as selected.

**Release** calls the box's `Flush`, which releases every row to the view's
pool and removes the provider, clears the row texts, icons and bands, and drops
the provider, the selection and the formatter. `OnAcquire` restores the
default size and the 20-pixel extent when a previous use changed it.

**Cost of a data change.** Blizzard's update rebuilds its template cache over
every element on each change (`RebuildTemplateInfoCache` asks the element
factory once per element; for a native type the cache never holds an entry,
so each element asks the client for template info again), and `Remove` uses
`tIndexOf`. A data change is therefore O(n) in Blizzard's code whatever the
row height. WidgetKit does not work around it (a provider marked virtual would
skip the walk, but that is Blizzard's private contract); `docs/API.md` tells
consumers to batch changes into `SetElements`.

## Renderer extensions

The `Renderer` part keeps four registries in `state.rendererExtensions`, in
the core's state so they outlive an upgrade of the part. A later part fills
them through `state.parts.Renderer.registerExtension(registry, key, entry)`;
each entry carries the revision of the part that registered it, and a
registration replaces an entry only with an equal or higher revision (it
returns `false` otherwise).

| Registry | Key | Entry | Used |
|---|---|---|---|
| `kinds` | an option kind | `{ type, configure(rendering, record, node) -> boolean, apply?(record, value, disabled) }` | `renderNode` draws the kind with `type` and `configure` instead of the built-in widget and `configureNode`; `refreshRecord` calls `apply` instead of `applyState` |
| `decorators` | a name | `{ decorate?(rendering, record, node), refresh?(rendering, record) }` | after a node's widget is built and after every refresh, in registration order; a raising one is reported through the host error handler |
| `pageStyles` | a `childGroups` value | `{ render(rendering, node, parent) -> boolean }` | `renderGroupChildren` calls it instead of the built-in pages |
| `confirm` | none | `{ ask(rendering, record, question, proceed) }` | an `execute` option with `confirm` asks it instead of the inline "click again"; `proceed()` runs the option when the rendering still owns it |

An empty registry costs nothing on the build or refresh path but one length
test. These are internal: the parts that use them ship with WidgetKit.

## Frames WidgetKit creates

Every base widget builds its frames in its constructor with `CreateFrame`,
parented to `UIParent` (or the holder), and sets its scripts there, once. The
exceptions are a `Dropdown`'s sixteen list rows, built on its first `Open`
and kept for the widget's life, and the secret font string of a text slot.

**Secret font strings.** A font string that showed a secret keeps secret
measurements for good (`ClearText` makes only its text plain again; measured
on Retail 12.1.0 b69933, 2026-09-25), so `showText` shows every text a text
setter may give a secret (the `Label`, `Heading` and `Button` texts, the
`Frame` and `Group` titles and the `labelText` of `CheckBox`, `Slider`,
`EditBox`, `Dropdown` and `ColorPicker`) on one of two regions. Plain texts go
on the region the constructor built; a secret goes on a font string made on
the slot's first secret, with the plain one's anchors, and kept in
`widget._secretTexts[key]` (`{ plain = region, secret = fontString }`) for the
widget's life. The widget field `key` (`text`, `titleText` or `labelText`)
always names the region showing the text, so the widget's own setters and
getters need no branch; at each switch the font object, justification, colour
and word wrap move with the text, and the secret font string is emptied,
cleared and hidden. The bound: at most one extra font string and one small
table per slot, made only by a secret (a widget that never shows one
allocates nothing), and never more however often a secret comes back. A
`Button`'s plain region is the button itself, which keeps its own styling;
its secret font string is parented to it and takes the font of the button's
text, again after `SetDisabled`.

The
templates used are `UIPanelButtonTemplate`, `UIPanelCloseButton`,
`UICheckButtonTemplate`, `InputBoxTemplate`, `WowScrollBoxList` and
`MinimalScrollBar`, present on every supported client; everything else is drawn
with `SetColorTexture`. No widget writes a field onto a frame it did not
create, and the only frames a widget scripts without having created them are a
`ScrollList`'s rows, which Blizzard's view creates inside the list's own calls
and hands to it (see [ScrollList](#scrolllist)). The `ColorPicker` reads
the client's `ColorPickerFrame` and calls its `SetupColorPickerAndShow` with an
info table the widget owns.
