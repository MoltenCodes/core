# WidgetKit API

WidgetKit API generation **1** provides pooled, versioned widgets on frames WidgetKit creates itself, containers with explicit layouts, a normalised anchor value type with position persistence, and a renderer for OptionsKit trees.

Implementation revision: **1**.

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
| `Release(widget)` | Release a widget and everything below it. |
| `IsWidget(value)` | Whether `value` is an active widget. |
| `RegisterLayout(name, layout)` / `GetLayout(name)` | Layout registry. `RegisterLayout` returns `false, "taken"` for a name in use. |
| `SetFocus(widget)` / `ClearFocus()` / `GetFocus()` | One focused widget per session. |
| `GetStatistics()` | Counters per type and in total (allocates). |
| `BindPosition(frame, storageTable, options?)` | Bind a frame's position to a storage table; returns a binding. |
| `RenderOptions(tree, container, options?)` | Render an OptionsKit tree; returns a rendering. |
| `CreateMediaPicker(mediaType)` | A `Dropdown` over MediaKit's names. |
| `Anchor` | `FromRect`, `Normalize`, `Apply`, `Read`, `POINTS`. |
| `Widget`, `Container`, `Binding`, `Rendering` | The shared prototypes, for introspection. |
| `MAX_CREATED`, `MAX_CHILDREN`, `MAX_CALLBACKS` | `256`, `256`, `16`. |
| `API`, `REVISION` | `1`, `1`. |

Widget base (`WidgetKit.Widget`), on every widget:

| Method | Purpose |
|---|---|
| `SetCallback(name, callback)` | Set or (with `nil`) remove the callback for `name`. At most 16 names per widget. |
| `Fire(name, ...)` | Call `callback(widget, name, ...)`; `true` when it ran without raising. Errors are reported through the host error handler, never raised. |
| `SetUserData(key, value)` / `GetUserData(key)` | Consumer state, cleared on release. |
| `SetWidth`, `SetHeight`, `GetWidth`, `GetHeight` | Size methods forwarded to the frame; the setters call the type's `OnWidthSet` / `OnHeightSet` hooks. |
| `SetFullWidth(bool)`, `IsFullWidth()`, `SetFullHeight(bool)`, `IsFullHeight()`, `SetRelativeWidth(fraction?)`, `GetRelativeWidth()` | Size requests layouts read. `SetFullWidth(true)` clears a relative width and the other way round. |
| `SetPoint(...)`, `ClearAllPoints()`, `GetPoint(index?)`, `GetNumPoints()` | Anchor methods forwarded to the frame. |
| `SetParent(frameOrWidget)` | Re-parent a widget that is not inside a container. |
| `Show()`, `Hide()`, `IsShown()`, `IsVisible()` | Visibility methods forwarded to the frame; `Hide` clears the focus when this widget holds it. |
| `IsReleasing()` | Whether this widget or any container above it is being released. |
| `GetType()`, `GetFrame()`, `GetParentContainer()` | Introspection. |
| `Release()` | The same as `WidgetKit:Release(widget)`. |

Container base (`WidgetKit.Container`), on every widget whose constructor set `content`, in addition:

| Method | Purpose |
|---|---|
| `AddChild(child, beforeWidget?)` | Add, or move, a child; lays out unless paused. `true`, or `nil, "full"`. |
| `AddChildren(...)` | Add several and lay out once. Returns how many were added, and `"full"` when it stopped early. |
| `ReleaseChildren()` | Release every child, last first. Lays nothing out. Returns the count. |
| `GetChildren()`, `GetNumChildren()`, `GetContent()` | The children array (read it, never change it), its length, the content frame. |
| `SetLayout(nameOrFunction)`, `GetLayoutName()` | The container's layout; default `"List"`. |
| `PauseLayout()`, `ResumeLayout()`, `IsLayoutPaused()` | Neither pausing nor resuming lays anything out. |
| `PerformLayout()` | Lay out now. `true`, or `false` and `"paused"`, `"recursion"`, `"releasing"` or `"depth"`. |
| `LayoutFinished(width, height)` | The upward size report; see [The layout contract](#the-layout-contract). |

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

1. the `OnRelease` **callback** (`SetCallback("OnRelease", ...)`);
2. the release of every child, **last first**, each by this same procedure;
3. the type's `OnRelease` **hook**;
4. callbacks, user data, size requests and the layout choice are cleared;
5. the frame loses its anchors, is hidden and is re-parented to `UIParent` (or the hidden holder);
6. the widget leaves its container;
7. the pool takes it back.

During steps 1 to 3, `IsReleasing()` is `true` for the widget and for every widget below it. A widget that was already released, one being released, and anything that is not a widget are refused at the caller's line (`WidgetKit:Release widget was already released`, `... is already being released`, `... must be a WidgetKit widget`). Every method of a released widget raises `... cannot be called on a released widget`, except `IsReleasing`, `GetType` and `Fire`, which returns `false`.

## The layout contract

A layout is a function:

```lua
local width, height = layout(content, children, container, scratch)
```

- `content` is the container's content frame, `children` its children in order (read them, never change the array), `container` the container widget, and `scratch` an empty table borrowed for this call only, returned to a PoolKit table pool afterwards.
- The layout anchors each child's frame with `ClearAllPoints` and `SetPoint` relative to `content`, reads size requests through `IsFullWidth`, `IsFullHeight` and `GetRelativeWidth`, and calls `child:PerformLayout()` for a child container once its width is set, so a pass runs top-down.
- It returns the width and height it used. WidgetKit then calls `container:LayoutFinished(width, height)`.

`LayoutFinished` calls the container type's `OnLayoutFinished(width, height)` hook — a `Group` sets its height to the content's plus its insets, a `ScrollFrame` sizes its scroll child — and, when the hook changed the container's height, lays out the container holding it, unless that one is paused, is being released or is itself inside its pass. That is the whole upward report: nothing reacts to `OnSizeChanged`, so layout never re-enters itself through the client.

`PerformLayout` on a container that is inside its own pass returns `false, "recursion"`; nested passes deeper than 32 return `false, "depth"`. A layout error is re-raised unchanged after the container's layout state is restored.

Built-in layouts:

| Layout | Places |
|---|---|
| `List` | Children stacked from the top, each below the previous one. Full width spans the content; relative width is a fraction of it; other children keep their width. |
| `Fill` | The first shown child fills the content. Other children are left alone. |
| `Flow` | Children left to right, wrapping to a new row when the next would pass the right edge. A full-width child takes a row of its own; a full-height child takes the height left below its row's top. |

All three skip hidden children and put no spacing between children; widgets carry their own margins.

## The versioning rule

A type's version is a positive integer, compared on every `RegisterType`:

- **lower** than the registered one: nothing changes; `false, "older"`;
- **equal**: nothing changes; `false, "current"`;
- **higher**: the new constructor is used from now on. Every pooled widget the older version built is retired at once, and every borrowed one is retired when it is released. `Create` never hands out a widget built by an older constructor.

A widget's methods and scripts are closures of the constructor that built it, so a widget of an older version is not a valid instance of the newer type. That is why it is discarded rather than reused. WidgetKit's own base widgets follow the same rule: a later revision of WidgetKit that changes a base widget raises that widget's version.

## The frame cap

The client can create frames but never destroy them, so every type is capped: at most `options.maxCreated` frames over the session (default `MAX_CREATED`, 256; at most 4096). The pool retains every released widget, so none is discarded for lack of room. At the cap, `Create` returns `nil, "exhausted"`. Retired widgets still count against the cap; a version upgrade raises the cap by the number of widgets it retires, or to the new registration's `maxCreated` when that is larger.

## The anchor model

An anchor is a plain table:

```lua
{ point = "TOPLEFT", relativeTo = "UIParent", relativePoint = "TOPLEFT", x = 20, y = -20, scale = 1 }
```

`relativeTo` is the relative frame's global name when it has one, the frame itself when it has none, or `nil` for the frame's parent; `scale` is the frame's own scale. Every field is plain, so an anchor can be saved as it is.

| Function | Purpose |
|---|---|
| `Anchor.FromRect(rect, parentRect, into?)` | Pure: for rectangles `{ left, bottom, width, height }`, elect the nearest point and return the anchor (without `relativeTo` and `scale`) that keeps the rect where it is. With `into`, fills that table and allocates nothing. |
| `Anchor.Normalize(frame, point, ...)` | Turn any `SetPoint` argument form into an anchor. `nil` as the relative frame is resolved to the parent. |
| `Anchor.Apply(frame, anchor)` | `ClearAllPoints`, `SetScale` when the anchor has a scale, `SetPoint`. `true`, or `false, "unknownRelative"` when `relativeTo` names no frame (the frame is left alone). |
| `Anchor.Read(frame)` | The frame's first anchor, normalised, or `nil`. |
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
| `Capture()` | Read the frame's rect in screen coordinates, elect the nearest point of its parent, re-anchor the frame there, save (debounced), fire `OnMoved`. Returns the anchor, or `nil` and `"notPositioned"`, `"released"` or `"forbidden"` (a frame `IsForbidden` or `CanBeAccessedInContext` refuses, which `Restore` leaves alone too). |
| `Restore()` | Apply the saved anchor; `false` when none is saved. An anchor it cannot read is reported and the frame keeps its place. |
| `Flush()` | Save a debounced anchor now. |
| `OnMoved(callback)` | Connect `callback(binding, anchor)`; returns a SignalKit connection. |
| `Release()` | Flush, stop the debounce, disconnect every listener. |

A save writes a fresh plain table, so a SettingsKit scope view validates and stores it like any record; declare the fields `point`, `relativeTo`, `relativePoint` (strings), `x`, `y` and `scale` (numbers), all optional. An unnamed relative frame is saved as `nil`, meaning the parent. A binding never sets a script on the frame: call `Capture()` from your own drag handler, as the `Frame` widget does from its title bar.

## The renderer

```lua
local rendering = WidgetKit:RenderOptions(tree, container, { allowSecret = false, media = { ["frame.font"] = "font" } })
```

`tree` is an OptionsKit tree; `container` an active WidgetKit container. Options:

| Option | Meaning |
|---|---|
| `allowSecret` | An `input` option whose value is secret shows it instead of `<secret value>`. |
| `media` | Option path → MediaKit type: that `select` is drawn with MediaKit's names when MediaKit is registered. |

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
| `execute` | `Button`; with `confirm`, the first click shows the question below it and the second runs `tree:Execute` |
| `header` | `Heading` |
| `description` | `Label` in the font for `fontSize` |

Every widget is full width and the container uses its own layout. Nodes are rendered in `Describe` order; hidden ones are skipped and disabled ones are disabled. A write calls `tree:Validate(path, value)`, then `tree:Set(path, value)`; a refusal (the message `Validate` or `Set` returns) is shown in a red `Label` inserted right below the widget, which shows the stored value again, and the next accepted write removes it. The renderer connects `tree:OnChange` and refreshes every widget in place with `Get`, `IsDisabled` and `IsHidden`; when an option was shown or hidden since the build, it rebuilds instead. OptionsKit does not report changes made to a SettingsKit database directly, so connect `db:OnChange` / `db:OnProfileChanged` to `rendering:Refresh()` yourself.

| Rendering method | Purpose |
|---|---|
| `Refresh()` | Re-read every value and state; rebuild when an option was shown or hidden. |
| `Rebuild()` | Release every rendered widget and build again from a fresh `Describe`. |
| `Release()` | Release every rendered widget together, disconnect from the tree and lay the container out. The container itself stays yours. |
| `GetWidget(path)` | The widget drawing an option (a `Group` for `multiselect`), or `nil`. |
| `GetMessage(path)` | The inline refusal shown below an option, or `nil`. |

`RenderOptions` raises at the caller when OptionsKit is not registered, when `tree` is not a tree, when `container` is not an active container, and when a widget type runs out of frames — after releasing what it had built.

## Base widgets

Every base widget has `SetDisabled(disabled)`. Text setters take `(text, options?)`, where `options.allowSecret` lets a secret through; `nil` clears the text.

| Type | Methods | Callbacks |
|---|---|---|
| `Frame` | `SetTitle`, `GetTitle`, `SetResizable`, `SetMovable`, `BindPosition(storage, options?)`, `GetBinding` | `OnClose`, `OnMoved`, `OnResize(width, height)` |
| `Group` | `SetTitle`, `GetTitle` | — |
| `ScrollFrame` | `GetContentHeight`, `GetScrollRange`, `GetScroll`, `SetScroll(offset)` | — |
| `Label` | `SetText`, `GetText`, `SetFontObject`, `SetColor`, `SetJustifyH` | — |
| `Button` | `SetText`, `GetText`, `SetKeyCapture(enabled)`, `IsCapturing` | `OnClick(mouseButton)`, `OnKeyCaptured(key)`, `OnKeyCaptureCancelled` |
| `CheckBox` | `SetValue`, `GetValue`, `SetTriState`, `SetLabel`, `GetLabel` | `OnValueChanged(value)` |
| `Slider` | `SetSliderValues(min, max, step?)`, `SetValue`, `GetValue`, `SetIsPercent`, `SetLabel`, `GetLabel` | `OnValueChanged(value)` |
| `EditBox` | `SetText`, `GetText`, `SetMultiLine(multiLine, lines?)`, `IsMultiLine`, `SetMaxLetters`, `SetFocus`, `SetLabel`, `GetLabel` | `OnEnterPressed(text)`, `OnTextChanged(text)`, `OnEscapePressed` |
| `Dropdown` | `SetList(values, order?)`, `SetValue`, `GetValue`, `GetNumEntries`, `Open`, `Close`, `IsOpen`, `PickIndex(index)`, `SetLabel`, `GetLabel` | `OnValueChanged(key)` |
| `ColorPicker` | `SetColor(r, g, b, a?)`, `GetColor`, `SetHasAlpha`, `OpenPicker`, `SetLabel`, `GetLabel` | `OnValueChanged(r, g, b, a)` |
| `Heading` | `SetText`, `GetText` | — |
| `Spacer` | — | — |

Every widget also fires `OnRelease` when it is released. Programmatic setters (`SetValue`, `SetText`, `SetColor`) never fire callbacks; only user input does.

## Secret values

A font string can display a secret value, but whether one should appear is the caller's decision (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). Every text setter refuses a secret at your line — `WidgetKit Label:SetText text must not be a secret value unless options.allowSecret is true` — unless you pass `{ allowSecret = true }`. A secret text is never measured (a `Label` showing one is one line high). Values a widget would compare (`CheckBox:SetValue`, `Dropdown:SetValue`, `Dropdown:SetList`, numbers, names, user-data keys) are refused when secret. Released widgets clear their texts. The renderer never inspects a secret value: an `input` shows it only with `allowSecret`, every other kind is disabled.

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

Several addons may embed WidgetKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: the widget and container prototypes, the type registry, the pools, every live widget's record, and the binding and rendering prototypes are kept, and gain the newer copy's methods. Pools call through a shared dispatch table, so a newer copy's build and retire steps run for pools an older copy created. Built-in layouts are resolved by name on every pass, so they are replaced for existing containers too. Base widget types are registered again with this copy's versions: an equal version keeps the older constructor, a higher one retires the older widgets.

Nothing survives `/reload`: widgets are created again when the addon loads.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **One runtime file.** The package ships `WidgetKit.lua` alone, because the release builder lists one facade file per package in `loadOrder`. The core, bases, layouts, anchors, the twelve base widgets and the renderer are sections of that file. Widget sets beyond the base set, and a split of the base widgets themselves, belong in sibling packages in generation 2, as the plan's first point foresees.
- **Widget callbacks are one function per name, not SignalKit signals.** A signal per callback name per widget would allocate on every acquire. SignalKit carries a binding's `OnMoved` listeners instead, and the renderer listens through OptionsKit's SignalKit connection.
- **`RegisterType` reports an equal version** with `false, "current"`, beside the planned `false, "older"` for a lower one.
- **`Trim` is not exposed.** The pool retains every released widget; trimming would free widget tables while their frames, which the client never frees, stay counted against the cap.
- **`RegisterLayout` never replaces a layout** (`false, "taken"`): layouts are shared by every addon in the session.
- **Additions:** `IsWidget`, `GetFocus`, `GetParentContainer`, `GetChildren`, `GetNumChildren`, `GetContent`, `GetLayoutName`, `IsLayoutPaused`, `Anchor.POINTS`, an `into` table for `FromRect`, `binding:Capture`, `Restore`, `Flush`, `IsReleased`, `rendering:Rebuild`, `GetWidget`, `GetMessage`, `CreateMediaPicker`, and `options.allowSecret` / `options.media` for the renderer.
- **Not rendered in generation 1:** an option's `desc` (there is no tooltip widget), `softMin` / `softMax`, `bigStep`, and `usage`. Groups are always nested `Group`s; tabs and trees of pages wait for a widget set that provides them.
