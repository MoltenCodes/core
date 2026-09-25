# WidgetKit API

WidgetKit API generation **1** provides pooled, versioned widgets on frames WidgetKit creates itself, containers with explicit layouts, a normalised anchor value type with position persistence, and a renderer for OptionsKit trees.

Implementation revision: **6**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
SignalKit.lua
WidgetKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local WidgetKit = MoltenCodes.Registries[2]:Get("widgetKit", 1)
```

WidgetKit does not rely on `require()` at runtime. Loading it without one of its dependencies raises `MoltenCodes WidgetKit requires Registry API 2 to be loaded first` (or `PoolKit API 1`, `SignalKit API 1`).

### Optional dependencies and host facilities

| Facility | Used by | Without it |
|---|---|---|
| OptionsKit API 1, through `Registry:Find` | `RenderOptions` | `RenderOptions` raises at the caller. |
| SchedulerKit API 1, through `Registry:Find` | `BindPosition` (found when the binding is made) | Every capture saves at once. |
| MediaKit API 1, through `Registry:Find` | `CreateMediaPicker`; `RenderOptions` with `options.media` | `CreateMediaPicker` raises at the caller; the renderer shows the option's own `values`. |
| SettingsKit API 1 | nothing directly | A scope view is simply one kind of storage table `BindPosition` accepts. |
| `CreateFrame` | every constructor | `Create` raises `MoltenCodes WidgetKit requires the World of Warcraft CreateFrame API`. |
| `UIParent` | the parent of released frames; the parent a binding measures against when a frame has none | Released frames rest on a hidden holder frame WidgetKit creates once. |
| `issecretvalue` | every text setter and every value a widget would compare | Nothing is treated as secret. Read at every call. |
| `geterrorhandler` | reporting callback and hook errors | Falls back to `print`. |
| `ColorPickerFrame` with `SetupColorPickerAndShow` | `ColorPicker` | A click fires `OnValueChanged` with the current colour. |
| `IsAltKeyDown`, `IsControlKeyDown`, `IsShiftKeyDown` | `Button` key capture | Captured keys carry no modifier. |
| `ACCEPT`, `NOT_BOUND` global strings | `EditBox` accept button, rendered key bindings | English fallbacks. |

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `RegisterType(name, constructor, version, options?)` | Register a widget type, or replace an older version. `true`, or `false, "older"` / `false, "current"`. |
| `GetTypeVersion(name)` | The registered version, or `nil`. |
| `Create(name)` | Acquire a widget, or `nil, "unknownType"` / `nil, "exhausted"`. |
| `Release(widget)` | Release a widget and everything below it; `true`. Refusals are listed in [The release contract](#the-release-contract). |
| `IsWidget(value)` | Whether `value` is an active widget. |
| `RegisterLayout(name, layout)` / `GetLayout(name)` | Layout registry. `RegisterLayout` returns `true`, or `false, "taken"` for a name in use; `GetLayout` the function or `nil`. |
| `SetFocus(widget)` / `ClearFocus()` / `GetFocus()` | One focused widget per session. `SetFocus` returns `true` and calls the previous widget's `OnFocusLost` hook; `ClearFocus` returns `false` when nothing was focused; `GetFocus` returns the widget or `nil`. |
| `GetStatistics()` | Counters per type and in total (allocates). |
| `BindPosition(frame, storageTable, options?)` | Bind a frame's position to a storage table; returns a binding. |
| `RenderOptions(tree, container, options?)` | Render an OptionsKit tree; returns a rendering. |
| `CreateMediaPicker(mediaType)` | A `Dropdown` over MediaKit's names, or `nil, "exhausted"`. Raises at the caller without MediaKit, for a type MediaKit does not know, and, before any `Dropdown` is acquired, when MediaKit lists more names than `maxDropdownEntries` allows. |
| `Anchor` | `FromRect`, `Normalize`, `Apply`, `Read`, `POINTS`. |
| `Widget`, `Container`, `Binding`, `Rendering` | The shared prototypes, for introspection. |
| `MAX_CREATED`, `MAX_CHILDREN`, `MAX_CALLBACKS` | `256`, `256`, `16`: the defaults. See [Limits](#limits). |
| `SetLimits(limits)` / `GetLimits()` | Change or read the package-wide limits `maxCreatedCeiling` and `maxDropdownEntries`; `GetLimits` returns a fresh table. |
| `UNBOUNDED` | Sentinel `maxCallbacks`, `SetMaxChildren` and the `maxDropdownEntries` limit accept to lift a bound. |
| `API`, `REVISION` | `1`, `6`. |

Widget base (`WidgetKit.Widget`), on every widget:

| Method | Purpose |
|---|---|
| `SetCallback(name, callback)` | Set or (with `nil`) remove the callback for `name`. A name past the type's `maxCallbacks` (16 by default) raises `... holds at most 16 callbacks per widget`. |
| `Fire(name, ...)` | Call `callback(widget, name, ...)`; `true` when it ran without raising. Errors are reported through the host error handler, never raised. |
| `SetUserData(key, value)` / `GetUserData(key)` | Consumer state, cleared on release. A `nil` key raises in `SetUserData` and reads `nil` in `GetUserData`; a secret key is refused. |
| `SetWidth`, `SetHeight`, `GetWidth`, `GetHeight` | Size methods forwarded to the frame; the setters call the type's `OnWidthSet` / `OnHeightSet` hooks. |
| `SetFullWidth(bool)`, `IsFullWidth()`, `SetFullHeight(bool)`, `IsFullHeight()`, `SetRelativeWidth(fraction?)`, `GetRelativeWidth()` | Size requests layouts read. `SetFullWidth(true)` clears a relative width and the other way round. A fraction must be above 0 and at most 1; `nil` clears it. |
| `SetPoint(...)`, `ClearAllPoints()`, `GetPoint(index?)`, `GetNumPoints()` | Anchor methods forwarded to the frame. |
| `SetParent(frameOrWidget)` | Re-parent a widget that is not inside a container, to a frame, to a widget (its content frame when it is a container) or to `nil`. Raises for a widget inside a container. |
| `SetDisabled(disabled?)` | Checks that `disabled` is a boolean or `nil`, and does nothing else. A type that can be disabled defines its own; see [Base widgets](#base-widgets). |
| `Show()`, `Hide()`, `IsShown()`, `IsVisible()` | Visibility methods forwarded to the frame; `Hide` clears the focus when this widget holds it. |
| `IsReleasing()` | Whether this widget or any container above it is being released. |
| `GetType()`, `GetFrame()`, `GetParentContainer()` | Introspection. |
| `Release()` | The same as `WidgetKit:Release(widget)`. |

Container base (`WidgetKit.Container`), on every widget whose constructor set `content`, in addition:

| Method | Purpose |
|---|---|
| `AddChild(child, beforeWidget?)` | Add, or move, a child; lays out unless paused. `true`, or `nil, "full"`. Raises when the container is being released, when `child` is not an active widget, is being released or is this container or one above it, and when `beforeWidget` is not a child of this container or is `child`. |
| `AddChildren(...)` | Checks every argument as `AddChild` does before adding any, adds them in order and lays out once. Returns how many were added, and `"full"` when it stopped early. |
| `ReleaseChildren()` | Release every child, last first. Lays nothing out. Returns the count. |
| `GetChildren()`, `GetNumChildren()`, `GetContent()` | The children array (read it, never change it), its length, the content frame. |
| `SetLayout(nameOrFunction)`, `GetLayoutName()` | The container's layout; default `"List"`. A name that is not registered raises. `GetLayoutName` answers `nil` for a layout set as a function. |
| `PauseLayout()`, `ResumeLayout()`, `IsLayoutPaused()` | Neither pausing nor resuming lays anything out. |
| `PerformLayout()` | Lay out now. `true`, or `false` and `"paused"`, `"recursion"`, `"releasing"` or `"depth"`. |
| `LayoutFinished(width, height)` | The upward size report; see [The layout contract](#the-layout-contract). |
| `SetMaxChildren(limit)`, `GetMaxChildren()` | The most children this container holds: a positive integer or `WidgetKit.UNBOUNDED`; 256 until changed, and again after a release. Lowering it below the current count keeps every child and answers the next addition with `"full"`. |

## The widget author contract

A widget type is a constructor registered with `RegisterType`. These are requirements; WidgetKit checks the first four and raises at the caller of `Create` when one fails.

1. **The constructor returns a new plain table on every call**, without a metatable. WidgetKit installs the metatable that makes the widget and container bases reachable.
2. **`widget.frame` is a frame the constructor created**, with `CreateFrame`. WidgetKit hides, anchors and re-parents it. Never hand WidgetKit a frame you did not create.
3. **A container sets `widget.content`**, the frame children are placed in. Its presence is what makes a widget a container.
4. **`OnAcquire` and `OnRelease`, when present, are functions.** `OnAcquire(widget)` runs on every `Create` and must set every default the type has: size, texts, values, enabled state, size requests such as `SetFullWidth`. `OnRelease(widget)` runs on every release and must clear every text and texture that may show a value, so a secret never survives into the next use. An error in `OnAcquire` releases the widget and is re-raised; an error in `OnRelease` is reported and the release completes.
5. **Build frames and scripts once.** Script handlers are set in the constructor and check `WidgetKit:IsWidget(widget)` before acting; `OnAcquire` never creates a frame or a closure, which is what keeps acquire free of allocation.
6. **Store the type's own state in fields of the widget table**, set in the constructor. Consumers never write fields on a widget: they use `SetUserData`. Nothing is ever written onto a frame; state that belongs to a frame lives in the widget table.
7. **Methods are fields of the widget table**, ideally functions defined once at file scope. A type may define a method the bases also define; it is found first. Type methods report argument errors at their caller's line.
8. **Optional hooks** a type may define: `OnWidthSet(width)`, `OnHeightSet(height)` (the base setters and layouts call them), `OnLayoutStart()` and `OnLayoutFinished(width, height)` (containers; see below), and `OnFocusLost()`. Hook errors are reported, never raised.
9. **Fire callbacks as the last thing a handler does.** A callback may release the widget.

## The release contract

`WidgetKit:Release(widget)` and `widget:Release()` run, in this order:

1. every **rendering** drawn into the widget (when it is a container) is released, as `rendering:Release()` would, except that the widgets it placed in this container go with the container in step 3;
2. the `OnRelease` **callback** (`SetCallback("OnRelease", ...)`);
3. the release of every child, **last first**, each by this same procedure;
4. the type's `OnRelease` **hook**;
5. callbacks, user data, size requests and the layout choice are cleared;
6. the frame loses its anchors, is hidden and is re-parented to `UIParent` (or the hidden holder);
7. the widget leaves its container;
8. the pool takes it back.

During steps 1 to 4, `IsReleasing()` is `true` for the widget and for every widget below it. A widget that was already released, one being released, and anything that is not a widget are refused at the caller's line (`WidgetKit:Release widget was already released`, `... is already being released`, `... must be a WidgetKit widget`). Every method of a released widget raises `... cannot be called on a released widget`, except `IsReleasing`, `GetType` and `Fire`, which returns `false`.

## The layout contract

A layout is a function:

```lua
local width, height = layout(content, children, container, scratch)
```

- `content` is the container's content frame, `children` its children in order (read them, never change the array), `container` the container widget, and `scratch` an empty table borrowed for this call only, returned to a PoolKit table pool afterwards.
- The layout anchors each child's frame with `ClearAllPoints` and `SetPoint` relative to `content`, reads size requests through `IsFullWidth`, `IsFullHeight` and `GetRelativeWidth`, and calls `child:PerformLayout()` for a child container once its width is set, so a pass runs top-down.
- It returns the width and height it used. WidgetKit then calls `container:LayoutFinished(width, height)`.

`LayoutFinished` calls the container type's `OnLayoutFinished(width, height)` hook — a `Group` sets its height to the content's plus its insets, a `ScrollFrame` sizes its scroll child — and, when the hook changed the container's height, lays out the container holding it, unless that one is paused, is being released or is itself inside its pass. That is the whole upward report: nothing reacts to `OnSizeChanged`, so layout never re-enters itself through the client.

`PerformLayout` on a container that is inside its own pass — from its layout, or from its `OnLayoutStart` hook, which runs inside the pass — returns `false, "recursion"`; nested passes deeper than 32 return `false, "depth"`. A layout error is re-raised unchanged after the container's layout state is restored.

Built-in layouts:

| Layout | Places |
|---|---|
| `List` | Children stacked from the top, each below the previous one. Full width spans the content; relative width is a fraction of it; other children keep their width. |
| `Fill` | The first shown child fills the content. Other children are left alone. |
| `Flow` | Children left to right, wrapping to a new row when the next would pass the right edge. A full-width child takes a row of its own; a full-height child takes the height left below its row's top. |

All three skip hidden children and put no spacing between children; widgets carry their own margins. A content frame with a negative size (insets wider than the container) counts as zero wide or high, so no child is sized below zero. A size the client answers as a secret is unknown; see [Secret sizes](#secret-sizes). `Flow` lets a row overflow by up to 0.001 pixels, so children whose relative widths add up to the whole row share it despite floating-point rounding.

## The versioning rule

A type's version is a positive integer, compared on every `RegisterType`:

- **lower** than the registered one: nothing changes; `false, "older"`;
- **equal**: nothing changes; `false, "current"`;
- **higher**: the new constructor is used from now on. Every pooled widget the older version built is retired at once, and every borrowed one is retired when it is released. `Create` never hands out a widget built by an older constructor.

A widget's methods and scripts are closures of the constructor that built it, so a widget of an older version is not a valid instance of the newer type. That is why it is discarded rather than reused. WidgetKit's own base widgets follow the same rule: a later revision of WidgetKit that changes a base widget raises that widget's version.

## The frame cap

The client can create frames but never destroy them, so every type is capped: at most `options.maxCreated` frames over the session (default `MAX_CREATED`, 256; at most the `maxCreatedCeiling` limit, 4096 unless raised). The pool retains every released widget, so none is discarded for lack of room. At the cap, `Create` returns `nil, "exhausted"`.

Retired widgets still count against the cap, so a version upgrade raises it by what that upgrade uses up: the pooled widgets it retires and the borrowed widgets of the version it replaces (borrowed widgets of earlier versions were counted by the upgrade that replaced them), or to the new registration's `maxCreated` when that is larger. The cap after `n` upgrades is therefore at most `(n + 1) × cap`, and never more than the `maxCreatedCeiling` in force when the upgrade is registered; once it reaches the ceiling, retired frames are not replaced and the type may answer `"exhausted"` sooner.

A constructor that raises, or breaks the author contract, after it called `CreateFrame` leaves that frame behind outside the cap: PoolKit counts only successful builds. Such a constructor is a bug to fix, not a path to rely on.

## Limits

Every retained collection WidgetKit keeps is bounded by default. A bound on something you create is an option on it; the one package-wide bound is set with `SetLimits`.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxCreated`, frames one type builds per session | `256` | `RegisterType(name, constructor, version, { maxCreated = n })` | no | `maxCreatedCeiling`; the client never frees a frame |
| `maxCreatedCeiling`, the largest `maxCreated` and the most an upgrade grows a cap to | `4096` | `WidgetKit:SetLimits({ maxCreatedCeiling = n })` | no | an integer from 256 to 16384: frames are never freed, and past 16384 one type could pin client memory no consumer can give back |
| `maxCallbacks`, named callbacks per widget | `16` | `RegisterType(..., { maxCallbacks = n })` | yes | none: the callbacks are your own functions |
| `maxChildren`, children per container | `256` | `container:SetMaxChildren(n)` | yes | none: the children are widgets you created |
| layout nesting depth | `32` | not configurable | no | a hard ceiling: each level is a nested Lua call chain through a layout and its hooks, and one scratch table per level is retained; past it `PerformLayout` returns `false, "depth"` |
| `maxDropdownEntries`, entries in one `Dropdown` list | `1024` | `WidgetKit:SetLimits({ maxDropdownEntries = n })`, read by each `SetList` | yes | none: the list keeps a fixed 16 row frames and scrolls, so an entry is two array slots of your own keys and labels, never a frame; 1024 matches OptionsKit's default `values` bound, so open both together |

```lua
WidgetKit:SetLimits({ maxCreatedCeiling = 8192 })
WidgetKit:RegisterType("MyAddonRow", constructRow, 1, { maxCreated = 6000, maxCallbacks = 32 })

local list = WidgetKit:Create("ScrollFrame")
list:SetMaxChildren(WidgetKit.UNBOUNDED)
```

`SetLimits` accepts any subset and raises at the caller on an unknown name (a key that is not a string, number or boolean is named by its type, `limits.<table>`, so no `__tostring` runs), on `WidgetKit.UNBOUNDED` for `maxCreatedCeiling`, on a secret value (`WidgetKit:SetLimits limits.maxDropdownEntries must not be a secret value`) and on one outside its range, before changing anything. **The limit is shared by every consumer in the session**: every embedded copy and every addon uses one value, so a library should rely on the default. Lowering it never shrinks a cap a type already has; it applies to later registrations and upgrades. `GetLimits` returns a fresh table.

`maxCallbacks` belongs to a type and applies to every widget of it; a newer version's registration sets it again. Base types keep 16; register your own type to ask for more. `SetMaxChildren` belongs to one container and is reset to 256 when the container is released, because pooled containers are reused by other code.

`WidgetKit.UNBOUNDED` and the limits live in the package state, so every embedded copy publishes the same sentinel and an in-place upgrade keeps the limit a consumer set, every type's `maxCallbacks` and every container's `maxChildren`.

## The anchor model

An anchor is a plain table:

```lua
local anchor = { point = "TOPLEFT", relativeTo = "UIParent", relativePoint = "TOPLEFT", x = 20, y = -20, scale = 1 }
```

`relativeTo` is the relative frame's global name when it has one, the frame itself when it has none, or `nil` for the frame's parent; `scale` is the frame's own scale. Every field is plain, so an anchor can be saved as it is.

| Function | Purpose |
|---|---|
| `Anchor.FromRect(rect, parentRect, into?)` | Pure: for rectangles `{ left, bottom, width, height }`, elect the nearest point and return the anchor (without `relativeTo` and `scale`) that keeps the rect where it is. With `into`, fills that table and allocates nothing. |
| `Anchor.Normalize(frame, point, ...)` | Turn any `SetPoint` argument form into an anchor. `nil` as the relative frame is resolved to the parent. |
| `Anchor.Apply(frame, anchor)` | `ClearAllPoints`, `SetScale` when the anchor has a scale, `SetPoint`. `true`; or, leaving the frame alone, `false, "forbidden"` for a frame `IsForbidden` or `CanBeAccessedInContext` refuses and `false, "unknownRelative"` when `relativeTo` names no frame. An anchor it cannot read raises at the caller. |
| `Anchor.Read(frame)` | The frame's first anchor, normalised, or `nil`; also `nil` when the client answers `GetPoint` with secret values (the frame's anchoring is secret). |
| `Anchor.POINTS` | The nine points in election order. |

**Election.** For each of the nine points, `FromRect` measures the squared distance between that point of the rect and the same point of the parent, and keeps the smallest. A frame near a corner is anchored to that corner, one near an edge's middle to that edge, one near the middle to `CENTER`, so the offset stays small and the frame keeps its place when the screen size changes. Equally near points go to the first in `POINTS`: `CENTER`, `TOP`, `BOTTOM`, `LEFT`, `RIGHT`, `TOPLEFT`, `TOPRIGHT`, `BOTTOMLEFT`, `BOTTOMRIGHT`.

### Position persistence

```lua
local binding = WidgetKit:BindPosition(frame, db.global, { key = "mainFrame" })
binding:OnMoved(function(binding, anchor) end)
```

| Option | Default | Meaning |
|---|---|---|
| `key` | `"anchor"` | The field of the storage table the anchor is saved in. |
| `delay` | `0.2` | Seconds a save is debounced by when SchedulerKit is registered. |
| `restore` | `true` | Apply the saved anchor now. |

| Binding method | Purpose |
|---|---|
| `Capture()` | Read the frame's rect in screen coordinates, elect the nearest point of its parent, re-anchor the frame there, save (debounced), fire `OnMoved`. Returns the anchor, or `nil` and `"notPositioned"` (also when the client answers `GetRect` with secret values), `"released"` or `"forbidden"` (a frame `IsForbidden` or `CanBeAccessedInContext` refuses, which `Restore` leaves alone too). |
| `Restore()` | Apply the saved anchor; `false` when none is saved. An anchor it cannot read is reported and the frame keeps its place. |
| `Flush()` | Save a debounced anchor now; `false` when nothing was pending, without SchedulerKit, or once released. |
| `OnMoved(callback)` | Connect `callback(binding, anchor)`; returns a SignalKit connection. Raises on a released binding. |
| `Release()` | Flush, stop the debounce, disconnect every listener. `true`, or `false` when it was already released. |
| `IsReleased()` | Whether `Release` ran. |

A save writes a fresh plain table, so a SettingsKit scope view validates and stores it like any record; declare the fields `point`, `relativeTo`, `relativePoint` (strings), `x`, `y` and `scale` (numbers), all optional. An unnamed relative frame is saved as `nil`, meaning the parent. A binding never sets a script on the frame: call `Capture()` from your own drag handler, as the `Frame` widget does from its title bar.

## The renderer

```lua
local rendering = WidgetKit:RenderOptions(tree, container, { allowSecret = false, media = { ["frame.font"] = "font" } })
```

`tree` is an OptionsKit tree; `container` an active WidgetKit container. Options:

| Option | Meaning |
|---|---|
| `allowSecret` | Checked (a boolean, not a secret) and without effect since revision 6: the client's edit box refuses a secret from addon code, so an `input` option whose value is secret shows `<secret value>`, disabled, as without it. See [Secret values](#secret-values). |
| `media` | Option path → MediaKit type: that `select` is drawn with MediaKit's names when MediaKit is registered. |
| `confirmText` | The question an `execute` option with `confirm = true` asks; default `"Click again to confirm."`. A `confirm` string is asked as it is. |

| Kind | Widget |
|---|---|
| `group` | `Group` with the group's name as title, holding its children (nested groups are nested `Group`s) |
| `toggle` | `CheckBox`, three states with `tristate` |
| `range` | `Slider` over `min`, `max`, `step`, as a percentage with `isPercent` |
| `select` | `Dropdown` over `values` in `sorting` order, or by label |
| `multiselect` | `Group` holding one `CheckBox` per value |
| `input` | `EditBox`, multi-line with `multiline` |
| `color` | `ColorPicker`, with alpha for `hasAlpha` |
| `keybinding` | `Button` in key-capture mode: click, press a key (`ESCAPE` cancels, right click unbinds) |
| `execute` | `Button`; with `confirm`, the first click shows the question below it and the second runs `tree:Execute`. An armed question disarms itself after 5 seconds through SchedulerKit when it is registered, otherwise at the next `Refresh` |
| `header` | `Heading` |
| `description` | `Label` in the font for `fontSize` |

Every widget is full width and the container uses its own layout. Nodes are rendered in `Describe` order; hidden ones are skipped and disabled ones are disabled. A write calls `tree:Validate(path, value)`, then `tree:Set(path, value)`; a refusal (the message `Validate` or `Set` returns) is shown in a red `Label` inserted right below the widget, which shows the stored value again, and the next accepted write removes it. The renderer connects `tree:OnChange` and refreshes every widget in place with `Get`, `IsDisabled` and `IsHidden`; when an option was shown or hidden since the build, it rebuilds instead. OptionsKit does not report changes made to a SettingsKit database directly, so connect `db:OnChange` / `db:OnProfileChanged` to `rendering:Refresh()` yourself.

| Rendering method | Purpose |
|---|---|
| `Refresh()` | Re-read every value and state; rebuild when an option was shown or hidden. `false` once released or when that rebuild failed. |
| `Rebuild()` | Release every rendered widget and build again from a fresh `Describe`. `false` once released, or when building failed (reported through the host error handler; the rendering is then empty). |
| `Release()` | Release every rendered widget together, disconnect from the tree and lay the container out. The container itself stays yours. `true`, or `false` when it was already released. |
| `IsReleased()` | Whether the rendering was released, by `Release` or with its container. |
| `GetWidget(path)` | The widget drawing an option (a `Group` for `multiselect`), or `nil`. |
| `GetMessage(path)` | The inline refusal shown below an option, or `nil`. |

**Ownership.** A rendering never outlives its container: releasing the container (directly or through an ancestor) releases the rendering first, and `rendering:Release()` afterwards returns `false`. The rendering also remembers the acquire serial of every widget it took; a widget that went back to its pool — released by the container or by anyone else — and was acquired again is never refreshed, written or released by the rendering, and `GetWidget` answers `nil` for it. A rendering whose container is no longer the one it was given releases itself at its next `Refresh`, write or click.

**Refusals and failures.** A `Validate` or `Set` that raises is shown inline like a refusal and reported through the host error handler; the rendering is never left mid-write. When a container is full (its `maxChildren`, 256 by default), building stops with `could not add a widget to its container: full`.

`RenderOptions` raises at the caller when OptionsKit is not registered, when `tree` is not a tree, when `container` is not an active container, when a widget type runs out of frames or the container is full, and when building raises (`WidgetKit:RenderOptions <error>`) — after releasing what it had built and restoring the container's layout pause state.

## Base widgets

The twelve base types are registered at version 2, except `ScrollFrame` and `Spacer` at version 1 (see [Embedded copies and upgrades](#embedded-copies-and-upgrades)).

Text setters take `(text, options?)`: a string or a number is shown, `nil` clears the text, anything else raises, and a secret is refused unless `options.allowSecret` is `true` (`EditBox:SetText` refuses one even then). Text getters return what the widget shows, `""` once cleared: the client's font strings and buttons answer an empty text with `nil` (measured on Retail 12.1.0 b69933, 2026-09-25), and every getter turns that into `""`. Every argument error is raised at the caller's line and names the method, as in `WidgetKit Slider:SetSliderValues minimum must not be greater than maximum`.

`SetDisabled(disabled?)` greys a widget out and, where it takes input, ignores it. `Group`, `Label` and `Heading` grey their text; `Button`, `CheckBox`, `Slider`, `EditBox`, `Dropdown` and `ColorPicker` also stop taking input (a disabled `Button` leaves key capture, a disabled `Dropdown` closes its list, a disabled `EditBox` loses the keyboard). `Frame`, `ScrollFrame` and `Spacer` use the base method, which only checks its argument.

| Type | Method | Returns, and what it refuses |
|---|---|---|
| `Frame` | `SetTitle(text, options?)`, `GetTitle()` | The title bar's text. |
| | `SetResizable(resizable)`, `SetMovable(movable)` | Booleans only. A new window is both. |
| | — | The window stays at the `DIALOG` strata whatever you parent it to: it calls `SetFixedFrameStrata(true)` where the client has it, because `SetParent` otherwise hands a frame its parent's strata. |
| | `BindPosition(storageTable, options?)` | A binding, as `WidgetKit:BindPosition` makes for the window's frame; a binding the window already had is released first. Released with the window. |
| | `GetBinding()` | The binding, or `nil`. |
| `Group` | `SetTitle(text, options?)`, `GetTitle()` | The content moves below a title and back up without one. |
| `ScrollFrame` | `GetContentHeight()`, `GetScrollRange()`, `GetScroll()` | Numbers: the height the last layout used, how far it can scroll, the current offset. |
| | `SetScroll(offset)` | A number, clamped to `0 .. GetScrollRange()`. |
| `Label` | `SetText(text, options?)`, `GetText()` | The label's height follows its text, wrapped at the label's width: 200 from `Create` on, then the width `SetWidth` or a layout gives it (a label you anchor on two sides yourself keeps wrapping at that width). A secret text, or a measurement the client answers as a secret, makes it one line (12 pixels) high. |
| | `SetFontObject(fontObject)` | A font object or its global name. |
| | `SetColor(red, green, blue, alpha?)` | Numbers; `alpha` defaults to `1`. Kept while disabled and shown again when enabled. |
| | `SetJustifyH(justify)` | `"LEFT"`, `"CENTER"` or `"RIGHT"`. |
| `Button` | `SetText(text, options?)`, `GetText()` | The button's text. |
| | `SetKeyCapture(enabled)` | A boolean. With it on, a left click listens for one key; turning it off stops listening without a callback. |
| | `IsCapturing()` | Whether it is listening for a key now. |
| `CheckBox` | `SetValue(value)`, `GetValue()` | `true`, `false` or `nil` (the third state; `false` without `SetTriState(true)`). |
| | `SetTriState(enabled)` | A boolean. Turning it off turns a third-state value into `false`. |
| | `SetLabel(text, options?)`, `GetLabel()` | The text beside the box. |
| `Slider` | `SetSliderValues(minimum, maximum, step?)` | Numbers, `minimum` at most `maximum`, `step` not negative (`0` or `nil` for no snapping). The value is snapped and clamped again. |
| | `SetValue(value)`, `GetValue()` | A number, snapped to the step from `minimum` and clamped to the range. |
| | `SetIsPercent(isPercent)` | A boolean: the value box shows `value × 100` with `%` and reads typed values back as percentages. |
| | `SetLabel(text, options?)`, `GetLabel()` | The text above the slider. |
| `EditBox` | `SetText(text, options?)`, `GetText()` | The text of the box in use. A secret is refused at your line whatever `allowSecret` says: `WidgetKit EditBox:SetText text must not be a secret value: the client's edit box takes one only from untainted code`. |
| | `SetMultiLine(multiLine, lines?)`, `IsMultiLine()` | A boolean and a positive integer of visible lines (default 4). The text moves to the box in use; a multi-line box shows an accept button. |
| | `SetMaxLetters(letters)` | `0` for no limit, or a positive integer. |
| | `SetFocus()` | Gives the box the keyboard and makes the widget WidgetKit's focused widget. |
| | `SetLabel(text, options?)`, `GetLabel()` | The text above the box. |
| `Dropdown` | `SetList(values, order?)` | `values` maps keys (strings or numbers) to string labels, at most `maxDropdownEntries` (1024 unless `SetLimits` opened it); past it `SetList` raises and keeps the list it had. `order` lists keys in display order, skipping keys without a label; without it entries are sorted by label, then by key (numbers first). Every entry is checked before anything changes. |
| | `SetValue(key)`, `GetValue()` | A string, a number or `nil`; a key not in the list shows no label. |
| | `GetNumEntries()` | The number of entries. |
| | `Open()`, `Close()`, `IsOpen()` | `Open` returns `false` when disabled or empty, `true` otherwise. |
| | `PickIndex(index)` | Chooses the entry at a positive integer `index` in display order as a click on its row does, firing `OnValueChanged`; `false` past the last entry or when disabled. |
| | `SetLabel(text, options?)`, `GetLabel()` | The text above the button. |
| `ColorPicker` | `SetColor(red, green, blue, alpha?)`, `GetColor()` | Numbers; `alpha` defaults to `1`. `GetColor` returns all four. |
| | `SetHasAlpha(hasAlpha)` | A boolean: whether the client picker offers opacity. |
| | `OpenPicker()` | `true` when the client picker opened. `false` when disabled, and `false` after firing `OnValueChanged` with the current colour on a client without a usable picker. |
| | `SetLabel(text, options?)`, `GetLabel()` | The text beside the swatch. |
| `Heading` | `SetText(text, options?)`, `GetText()` | A centred title between two lines; full width from `Create` on. |
| `Spacer` | — | Empty space, 10 × 8 until resized. |

| Type | Callbacks, fired by user input |
|---|---|
| `Frame` | `OnClose` (the close button, after the frame hid), `OnMoved` (a drag ended, after a bound position was captured), `OnResize(width, height)` (a resize ended, after the window was laid out) |
| `Button` | `OnClick(mouseButton)`; with key capture `OnKeyCaptured(key)` (`"ALT-CTRL-SHIFT-"` prefixes as held; `""` from a right click, to unbind) and `OnKeyCaptureCancelled` (`ESCAPE`) |
| `CheckBox`, `Slider`, `Dropdown` | `OnValueChanged(value)` |
| `EditBox` | `OnEnterPressed(text)`, `OnTextChanged(text)`, `OnEscapePressed` |
| `ColorPicker` | `OnValueChanged(red, green, blue, alpha)` |

Every widget also fires `OnRelease` when it is released. Programmatic setters (`SetValue`, `SetText`, `SetColor` and the others above) never fire callbacks. Two methods stand in for user input and do: `Dropdown:PickIndex`, and `ColorPicker:OpenPicker` on a client without a usable picker.

**Dropdown lists** are parented to `UIParent` (the widget's frame without one) at the `FULLSCREEN_DIALOG` strata, so a `ScrollFrame` or any clipping parent cannot cut them off. While a list is open, one invisible full-screen frame owned by WidgetKit — one for the session, at the `FULLSCREEN` strata just below the list — closes it on a click anywhere else. Opening a list closes any other open list; hiding or releasing the dropdown closes its list. `SetList` checks every entry before it changes anything, so a refused list leaves the dropdown as it was.

**ColorPicker** callbacks from the client picker reach only the use of the widget that opened it: a release disarms them. Without `SetHasAlpha(true)` the stored alpha is kept.

**Types in the editor.** `Create` is annotated as returning `WidgetKit.Widget`. Each base type has its own class — `WidgetKit.Window` (the `Frame` type), `WidgetKit.Group`, `WidgetKit.ScrollFrame`, `WidgetKit.Label`, `WidgetKit.Button`, `WidgetKit.CheckBox`, `WidgetKit.Slider`, `WidgetKit.EditBox`, `WidgetKit.Dropdown`, `WidgetKit.ColorPicker`, `WidgetKit.Heading`, `WidgetKit.Spacer` — reached with a cast:

```lua
local slider = WidgetKit:Create("Slider") --[[@as WidgetKit.Slider]]
```

## Secret values

A font string can display a secret value, but whether one should appear is the caller's decision (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). Every text setter refuses a secret at your line — `WidgetKit Label:SetText text must not be a secret value unless options.allowSecret is true` — unless you pass `{ allowSecret = true }`. A secret text is never measured (a `Label` showing one is one line high).

**What the client takes (measured on Retail 12.1.0 b69933, 2026-09-25).** A font string takes a secret text from addon code: a `Label` and a `Heading` show one with `allowSecret`, and `GetText` then answers a secret. An edit box does not: its `SetText` raises `Secret values are only allowed during untainted execution for this argument`, like `SetWidth` and `SetHeight`. So `EditBox:SetText` refuses a secret at your line even with `allowSecret` (`WidgetKit EditBox:SetText text must not be a secret value: the client's edit box takes one only from untainted code`), and the renderer shows an `input` option whose value is secret as `<secret value>`, disabled, whatever `options.allowSecret` says. A font string that showed a secret keeps a secret aspect after `SetText("")`: its text and its measurements stay secret. Every release that clears a font string a text setter may have given a secret calls `ClearText`, which removes that aspect, so the next use of the widget starts plain; a `Label` never sizes itself from a measurement the client answers as a secret (it is one line high instead), so the secret never reaches `SetHeight`. Values a widget would compare (`CheckBox:SetValue`, `Dropdown:SetValue`, `Dropdown:SetList`, `Label:SetJustifyH`, numbers and optional numbers such as an `alpha` or a relative width, counts and indices such as `SetMaxLetters` and `PickIndex`, limits and caps, names, user-data keys, and the keys of a `Dropdown:SetList` `order`, which are refused before they index `values`: `WidgetKit Dropdown:SetList key must not be a secret value`) are refused when secret, before they are compared with anything, `nil` included. Absence of an optional argument, option field, constructor field or host result is tested with `type`, never by comparing with `nil`, so a value WidgetKit only stores, such as a user-data value, may be secret. Released widgets clear their texts. The renderer never inspects a secret value or hands one to a widget: every kind whose value is secret shows a placeholder or its default and is disabled, `allowSecret` or not.

**Secret booleans.** A secret value is never tested as a boolean (`if`, `and`, `or`, `not`) or compared inside WidgetKit, because either raises there (measured on Retail 12.1.0 b69933). What that means for each place a foreign value decides a branch:

| Where | A secret value |
|---|---|
| `SetDisabled(disabled)` of every widget, `SetFullWidth`, `SetFullHeight`, `Frame:SetResizable`, `Frame:SetMovable`, `Button:SetKeyCapture`, `CheckBox:SetTriState`, `Slider:SetIsPercent`, `EditBox:SetMultiLine`, `ColorPicker:SetHasAlpha` | Refused at your line: `WidgetKit Slider:SetIsPercent isPercent must not be a secret value`. |
| `options.allowSecret` of a text setter and of `RenderOptions`, `options.restore` of `BindPosition` | Refused at your line: `WidgetKit Label:SetText options.allowSecret must not be a secret value`. |
| `x`, `y` of `Anchor.Normalize`, and `x`, `y` of an anchor `Anchor.Apply` or `Restore` reads | Refused (`... x must not be a secret value`) instead of being defaulted with `or 0`; `Restore` reports it and leaves the frame in place. |
| `GetPoint` answers (`Anchor.Read`), `GetRect` answers (`Binding:Capture`) | `Anchor.Read` returns `nil`; `Capture` returns `nil, "notPositioned"`. |
| The width or height a layout function returns | Ignored, like any non-number. |
| `tree:IsDisabled(path)` | The option is disabled: the user is not offered what the tree will not say is enabled. |
| `tree:IsHidden(path)`, a node's `hidden` | Counts as not hidden: the option stays in view (and disabled when its state is secret too). |
| A node's `tristate`, `isPercent`, `multiline`, `hasAlpha` | Counts as not set. |
| A node's `confirm` | Counts as `true`: the option asks the default question before it runs. |
| A node's `fontSize` | The default (`medium`) font. |
| A node's `step` | Passed to `Slider:SetSliderValues`, which refuses it; building fails as for any invalid node. |
| The answer of `tree:Validate` or `tree:Set` | A refusal. A secret message is shown as `<secret value>`. |

Callback and hook return values are never read, so they need no rule.

### Secret sizes

`GetWidth`, `GetHeight` and `GetSize` carry `SecretWhenAnchoringSecret` (and `ConstSecretAccessor`) in the client's documentation (`packages/apiKit/metadata/retail`, Retail 12.1.0 b69933): a frame anchored to something secret answers its size as a secret, and `SetWidth`, `SetHeight` and `SetSize` accept a secret argument only from untainted code, which an addon's is not. Arithmetic or a comparison on a secret raises, so every size WidgetKit reads from the client during a layout or to size a widget is asked of `issecretvalue` first, and a secret size is **unknown**; no measurement reaches a setter unchecked:

| Where | A secret size |
|---|---|
| The content width in `List`, `Fill` and `Flow` | Sizes no child: a relative-width child keeps its width, a full-width child is still anchored across the content, and children are told no width (`OnWidthSet` is not called). The layout reports no width to `LayoutFinished` (`nil`). `Flow` packs its rows against a width of 0, so each child after the first in a row wraps to a new row. |
| The content height in `Fill` and `Flow` | Sizes no child: a full-height child keeps its height, and `Fill` tells its child no height and reports none. |
| A child's own width (`Flow`) or height (`List`, `Flow`) | Counts as 0 in the offsets and row heights. |
| A container's height before or after `OnLayoutFinished` | Counts as unchanged: the container holding it is not laid out again. |
| A `ScrollFrame` viewport's width | The scroll child keeps its width instead of being given the secret one. |
| A `ScrollFrame` viewport's height | Counts as 0: the whole content height is the scroll range. |
| A `Label`'s string height (`GetStringHeight`) | Not used: the label is one line (12 pixels) high. Measured on Retail 12.1.0 b69933: a label whose font string had shown a secret measured a later plain text as a secret. |

A custom layout that reads sizes from the client follows the same care; what it returns is covered by the table above.

## Error behaviour

Every argument failure and refusal reports the line that called WidgetKit and names the method: `WidgetKit:Create name must be a non-empty string`, `WidgetKit.Container:AddChild beforeWidget must be a child of this container`, `WidgetKit Slider:SetSliderValues minimum must not be greater than maximum`. Calling a method on the wrong receiver raises `... must be called on a WidgetKit widget` (or container, binding, rendering, facade). Errors raised by a constructor and by a layout function propagate unchanged. Callback and hook errors are reported through the host error handler.

## Performance

| Operation | Cost |
|---|---|
| `Create` / `Release` of a warm widget | LIFO pool operations, the type's hooks; no allocation (guarded by a spec for every simple type). |
| `PerformLayout` with unchanged children | One scratch table borrowed and returned, anchors re-set; no allocation. |
| `Fire` | One table read and a protected call; no allocation. |
| `Anchor.FromRect` with `into` | Nine distance computations; no allocation. |
| `BindPosition` | One binding, one SignalKit signal and, with SchedulerKit, one debounce handle. Each save allocates the saved anchor table. |
| `RenderOptions`, `Rebuild` | Proportional to the tree: one `Describe`, the widgets and one record per option. `Refresh` allocates only what `Get` returns. |
| `GetStatistics` | Allocates the result. |

## A custom widget and a custom layout

```lua
local WidgetKit = MoltenCodes.Registries[2]:Get("widgetKit", 1)

-- Methods defined once, stored on every widget.
local function setProgress(self, fraction)
  self._fraction = fraction
  self.bar:SetWidth(math.max(1, self.frame:GetWidth() * fraction))
end

local function onAcquire(self)          -- every default, on every Create
  self.frame:SetSize(200, 12)
  self._fraction = 0
  self.bar:SetWidth(1)
end

local function onRelease(self)          -- nothing shown survives
  self._fraction = 0
end

local function onWidthSet(self)         -- a layout resized the widget
  self.bar:SetWidth(math.max(1, self.frame:GetWidth() * self._fraction))
end

WidgetKit:RegisterType("MyAddonProgress", function()
  local frame = CreateFrame("Frame")
  local bar = frame:CreateTexture(nil, "ARTWORK")
  bar:SetColorTexture(0.2, 0.8, 0.2, 1)
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("BOTTOMLEFT")
  return {
    frame = frame,
    bar = bar,
    _fraction = 0,
    OnAcquire = onAcquire,
    OnRelease = onRelease,
    OnWidthSet = onWidthSet,
    SetProgress = setProgress,
  }
end, 1)

-- Two equal columns, filled left then right, row by row.
WidgetKit:RegisterLayout("MyAddonColumns", function(content, children)
  local half = content:GetWidth() / 2
  local top = 0
  for index = 1, #children, 2 do
    local rowHeight = 0
    for column = 0, 1 do
      local child = children[index + column]
      if child then
        child.frame:ClearAllPoints()
        child.frame:SetPoint("TOPLEFT", content, "TOPLEFT", column * half, -top)
        child:SetWidth(half)
        if child.content then
          child:PerformLayout()
        end
        rowHeight = math.max(rowHeight, child:GetHeight())
      end
    end
    top = top + rowHeight
  end
  return content:GetWidth(), top
end)

local group = WidgetKit:Create("Group")
group:SetLayout("MyAddonColumns")
local progress = WidgetKit:Create("MyAddonProgress")
group:AddChild(progress)
progress:SetProgress(0.4)
```

To change `MyAddonProgress` later, register the new constructor with version `2`; pooled version-1 widgets are retired rather than reused.

## Embedded copies and upgrades

Several addons may embed WidgetKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: the widget and container prototypes, the type registry, the pools, every live widget's record, and the binding and rendering prototypes are kept, and gain the newer copy's methods. Pools call through a shared dispatch table, so a newer copy's build and retire steps run for pools an older copy created. Built-in layouts are resolved by name on every pass, so they are replaced for existing containers too. Base widget types are registered again with this copy's versions: an equal version keeps the older constructor, a higher one retires the older widgets. Revisions 2, 3, 4 and 5 keep the revision 1 state as it is and replace the methods only; every base widget stays at version 1. Revision 6 keeps the state too and raises `Frame`, `Group`, `Label`, `Button`, `CheckBox`, `Slider`, `EditBox`, `Dropdown`, `ColorPicker` and `Heading` to version 2, because it changed their constructors: an upgrade from an older revision retires their pooled widgets at once and their borrowed ones when they are released (the frame cap grows by what is retired, as [The frame cap](#the-frame-cap) says), so every `Create` after it hands out a widget with the revision 6 behaviour. `ScrollFrame` and `Spacer` stay at version 1.

Nothing survives `/reload`: widgets are created again when the addon loads.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **One runtime file.** The package ships `WidgetKit.lua` alone, because the release builder lists one facade file per package in `loadOrder`. The core, bases, layouts, anchors, the twelve base widgets and the renderer are sections of that file. Widget sets beyond the base set, and a split of the base widgets themselves, belong in sibling packages in generation 2, as the plan's first point foresees.
- **Widget callbacks are one function per name, not SignalKit signals.** A signal per callback name per widget would allocate on every acquire. SignalKit carries a binding's `OnMoved` listeners instead, and the renderer listens through OptionsKit's SignalKit connection.
- **`RegisterType` reports an equal version** with `false, "current"`, beside the planned `false, "older"` for a lower one.
- **`Trim` is not exposed.** The pool retains every released widget; trimming would free widget tables while their frames, which the client never frees, stay counted against the cap.
- **`RegisterLayout` never replaces a layout** (`false, "taken"`): layouts are shared by every addon in the session.
- **`RegisterType` takes a fourth `options` argument** (`maxCreated`, `maxCallbacks`), so a type can ask for a cap other than 256 and a callback bound other than 16.
- **`Frame:BindPosition(storage, options?)`** binds the window to a storage table and releases the binding with the window; the plan named only `WidgetKit:BindPosition`.
- **A SettingsKit scope view is passed directly as the storage table**; WidgetKit never looks SettingsKit up, which is why it appears among the optional dependencies only as a documented storage shape.
- **The `execute` confirmation text is a render option (`confirmText`),** not an option field: OptionsKit refuses fields its kinds do not declare. A `confirm` string on the option is still asked as it is.
- **Additions:** `IsWidget`, `GetFocus`, `GetParentContainer`, `GetChildren`, `GetNumChildren`, `GetContent`, `GetLayoutName`, `IsLayoutPaused`, `Anchor.POINTS`, `SetLimits`, `GetLimits`, `UNBOUNDED`, `SetMaxChildren`, `GetMaxChildren`, an `into` table for `FromRect`, `binding:Capture`, `Restore`, `Flush`, `IsReleased`, `rendering:Rebuild`, `IsReleased`, `GetWidget`, `GetMessage`, `CreateMediaPicker`, and `options.allowSecret` / `options.media` for the renderer.
- **Not rendered in generation 1:** an option's `desc` (there is no tooltip widget), `softMin` / `softMax`, `bigStep`, and `usage`. Groups are always nested `Group`s; tabs and trees of pages wait for a widget set that provides them.
