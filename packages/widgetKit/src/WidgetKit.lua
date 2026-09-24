-- MoltenCodes WidgetKit
--
-- Pooled, versioned widgets for World of Warcraft addons: a registry of widget
-- types built on frames WidgetKit creates itself, acquired from and released
-- to one bounded PoolKit pool per type; a small base contract every widget
-- shares; containers whose layout is an explicit operation, never a reaction
-- to `OnSizeChanged`; a normalised anchor value type with position
-- persistence; and a renderer that turns an OptionsKit tree into widgets.
--
-- WidgetKit needs Registry API 2, PoolKit API 1 and SignalKit API 1. It uses
-- OptionsKit, SettingsKit (through the storage table a caller hands it),
-- SchedulerKit and MediaKit API 1 when they are registered, found through
-- `Registry:Find` at call time.
--
-- The whole package is one file, because a package ships one runtime file
-- (see `docs/PACKAGE_MANIFEST.md`). Widget sets beyond the base set belong in
-- sibling packages; see `docs/API.md`, "Deviations".
--
-- Contents
-- --------
--   Constants ............. identity, bounds, points, built-in versions
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit, SignalKit and host facilities
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host helpers .......... error reporting, secrets, globals, frames
--   Argument checks ....... receivers, names, numbers, option tables
--   Widget records ........ the private per-widget record and its lookups
--   Widget base ........... the prototype every widget falls back to
--   Container base ........ children, layout state and PerformLayout
--   Layouts ............... List, Fill and Flow
--   Type registry ......... RegisterType, pools, Create, Release, focus
--   Anchors ............... FromRect, Normalize, Apply, Read
--   Position binding ...... BindPosition and the binding handle
--   Widget helpers ........ text checks and shared construction code
--   Widget: Frame ......... a movable, resizable window with a title
--   Widget: Group ......... an inline group with a title
--   Widget: ScrollFrame ... a scroll child with a scrollbar
--   Widget: Label ......... one FontString
--   Widget: Button ........ a push button that can capture a key
--   Widget: CheckBox ...... a two- or three-state check box
--   Widget: Slider ........ a slider with a value box
--   Widget: EditBox ....... single- and multi-line text entry
--   Widget: Dropdown ...... a keyboard-free list of buttons
--   Widget: ColorPicker ... a swatch over the client colour picker
--   Widget: Heading ....... a centred title between two lines
--   Widget: Spacer ........ empty space
--   Media pickers ......... dropdowns over MediaKit lists
--   Renderer .............. OptionsKit trees rendered into containers
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout algorithms, the renderer and pooling are described in
-- `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "widgetKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local REQUIRED_SIGNALKIT_API = 1
local OPTIONAL_OPTIONSKIT_API = 1
local OPTIONAL_SCHEDULERKIT_API = 1
local OPTIONAL_MEDIAKIT_API = 1
local STATE_SCHEMA = 1

-- The most frames one widget type builds over the session unless its
-- registration asks for another cap. The client never frees a frame, so this
-- is the bound on what a type can ever cost.
local DEFAULT_MAX_CREATED = 256

-- `maxCreatedCeiling`: the largest cap a registration may ask for, and the
-- most a version upgrade grows a type's cap to. `default` holds until a
-- consumer calls `SetLimits{ maxCreatedCeiling }`, which accepts an integer
-- from `minimum` to `maximum`. The client never frees a frame, so the ceiling
-- cannot be `UNBOUNDED`: every frame a type ever builds is kept for the whole
-- session. 16384 frames is four times the default and already more than a
-- whole interface of addons usually shows; past it one widget type could pin
-- client memory no consumer can give back. The minimum is
-- `DEFAULT_MAX_CREATED`, so a registration without options always fits.
-- One table rather than three locals: the main chunk is close to Lua 5.1's
-- limit of 200 local variables.
local MAX_CREATED_CEILING = {
    default = 4096,
    minimum = DEFAULT_MAX_CREATED,
    maximum = 16384,
}

-- The most children one container holds unless `container:SetMaxChildren`
-- says otherwise.
local MAX_CHILDREN = 256

-- The most named callbacks one widget holds unless its type's registration
-- asks for `maxCallbacks`.
local MAX_CALLBACKS = 16

-- How deep nested `PerformLayout` calls may go. Containers cannot form a
-- cycle, so this only bounds a pathological custom layout. It stays a hard
-- ceiling: each level is a Lua call chain through a layout and its hooks, and
-- one scratch table per level is retained.
local MAX_LAYOUT_DEPTH = 32

-- Retained scratch tables for layouts. Layouts nest at most
-- `MAX_LAYOUT_DEPTH` deep, so one table per level is retained.
local SCRATCH_RETAINED = MAX_LAYOUT_DEPTH

-- Default debounce of a position save, in seconds.
local DEFAULT_SAVE_DELAY = 0.2

-- The nine anchor points in election order. `FromRect` keeps the first of
-- equally near points, so this order is the tie-break: the centre, then the
-- edge midpoints, then the corners.
local POINTS = {
    "CENTER",
    "TOP",
    "BOTTOM",
    "LEFT",
    "RIGHT",
    "TOPLEFT",
    "TOPRIGHT",
    "BOTTOMLEFT",
    "BOTTOMRIGHT",
}

-- Where each point sits on a rect, as fractions of its width and height from
-- the bottom-left corner.
local POINT_HORIZONTAL = {
    CENTER = 0.5,
    TOP = 0.5,
    BOTTOM = 0.5,
    LEFT = 0,
    RIGHT = 1,
    TOPLEFT = 0,
    TOPRIGHT = 1,
    BOTTOMLEFT = 0,
    BOTTOMRIGHT = 1,
}
local POINT_VERTICAL = {
    CENTER = 0.5,
    TOP = 1,
    BOTTOM = 0,
    LEFT = 0.5,
    RIGHT = 0.5,
    TOPLEFT = 1,
    TOPRIGHT = 1,
    BOTTOMLEFT = 0,
    BOTTOMRIGHT = 0,
}

-- The version each base widget type is registered with. A later revision of
-- this file that changes a base widget's constructor raises that widget's
-- version, so pooled widgets built by the older constructor are discarded.
local BASE_TYPE_VERSIONS = {
    Frame = 1,
    Group = 1,
    ScrollFrame = 1,
    Label = 1,
    Button = 1,
    CheckBox = 1,
    Slider = 1,
    EditBox = 1,
    Dropdown = 1,
    ColorPicker = 1,
    Heading = 1,
    Spacer = 1,
}

-- The name of every built-in layout, the default one first.
local LAYOUT_LIST = "List"
local LAYOUT_FILL = "Fill"
local LAYOUT_FLOW = "Flow"

-- Accepted option fields, as sets, so option validation allocates nothing.
local TYPE_OPTION_KEYS = { maxCreated = true, maxCallbacks = true }
local TEXT_OPTION_KEYS = { allowSecret = true }
local BINDING_OPTION_KEYS = { key = true, delay = true, restore = true }
local RENDER_OPTION_KEYS = { allowSecret = true, media = true, confirmText = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist.
local FACADE_METHODS = {
    "RegisterType",
    "GetTypeVersion",
    "Create",
    "Release",
    "IsWidget",
    "RegisterLayout",
    "GetLayout",
    "SetFocus",
    "ClearFocus",
    "GetFocus",
    "GetStatistics",
    "BindPosition",
    "RenderOptions",
    "CreateMediaPicker",
    "SetLimits",
    "GetLimits",
}
local WIDGET_METHODS = {
    "SetCallback",
    "Fire",
    "SetUserData",
    "GetUserData",
    "SetWidth",
    "SetHeight",
    "GetWidth",
    "GetHeight",
    "SetFullWidth",
    "IsFullWidth",
    "SetFullHeight",
    "IsFullHeight",
    "SetRelativeWidth",
    "GetRelativeWidth",
    "SetPoint",
    "ClearAllPoints",
    "GetPoint",
    "GetNumPoints",
    "SetParent",
    "Show",
    "Hide",
    "IsShown",
    "IsVisible",
    "IsReleasing",
    "GetType",
    "GetFrame",
    "GetParentContainer",
    "SetDisabled",
    "Release",
}
local CONTAINER_METHODS = {
    "AddChild",
    "AddChildren",
    "ReleaseChildren",
    "GetChildren",
    "GetNumChildren",
    "GetContent",
    "SetLayout",
    "GetLayoutName",
    "PauseLayout",
    "ResumeLayout",
    "IsLayoutPaused",
    "PerformLayout",
    "LayoutFinished",
    "SetMaxChildren",
    "GetMaxChildren",
}
local ANCHOR_FUNCTIONS = { "FromRect", "Normalize", "Apply", "Read" }
local BINDING_METHODS = { "Capture", "Restore", "Flush", "OnMoved", "Release", "IsReleased" }
local RENDERING_METHODS = {
    "Refresh",
    "Rebuild",
    "Release",
    "IsReleased",
    "GetWidget",
    "GetMessage",
}

-- Weak keys for every table keyed by a widget or a frame, so WidgetKit never
-- keeps either alive on its own account.
local WEAK_KEYS = { __mode = "k" }

-- Public types ---------------------------------------------------------------
--
-- WidgetKit publishes its methods by writing them onto Registry-owned
-- prototype tables, so the editor-facing contract is declared here as LuaCATS
-- classes rather than inferred from those assignments.

---A client frame, texture or font string. WidgetKit calls only the methods it
---documents on it.
---@alias WidgetKit.Frame table

---A named callback: `callback(widget, name, ...)`.
---@alias WidgetKit.Callback fun(widget: WidgetKit.Widget, name: string, ...: any)

---A widget constructor: builds one widget of type `typeName` and returns it.
---@alias WidgetKit.Constructor fun(typeName: string): table

---A layout: places `children` inside `content` and returns the size used.
---`scratch` is an empty table borrowed for this call only.
---@alias WidgetKit.Layout fun(content: WidgetKit.Frame, children: WidgetKit.Widget[], container: WidgetKit.Container, scratch: table): number?, number?

---Options for `WidgetKit:RegisterType`.
---@class WidgetKit.TypeOptions
---@field maxCreated integer? The most frames this type builds over the session; default 256, at most `GetLimits().maxCreatedCeiling` (4096 unless raised). Never `UNBOUNDED`: frames are never freed.
---@field maxCallbacks (integer|table)? The most named callbacks one widget of this type holds: a positive integer or `WidgetKit.UNBOUNDED`; default 16.

---The package-wide limits. `SetLimits` accepts any subset; `GetLimits` returns a fresh copy.
---@class WidgetKit.Limits
---@field maxCreatedCeiling integer The largest `maxCreated` a registration may ask for, and the most an upgrade grows a cap to; default 4096, from 256 to 16384.
---@field maxDropdownEntries integer|table The most entries one `Dropdown:SetList` accepts: a positive integer or `WidgetKit.UNBOUNDED`; default 1024.

---Options for the text setters of every widget.
---@class WidgetKit.TextOptions
---@field allowSecret boolean? Display a secret value. The caller decides; see `docs/EMBEDDING.md`.

---The base every widget falls back to.
---@class WidgetKit.Widget
---@field frame WidgetKit.Frame The widget's frame, built by its constructor. Read it; never replace it.
---@field SetCallback fun(self: WidgetKit.Widget, name: string, callback: WidgetKit.Callback?)
---@field Fire fun(self: WidgetKit.Widget, name: string, ...: any): boolean called
---@field SetUserData fun(self: WidgetKit.Widget, key: any, value: any)
---@field GetUserData fun(self: WidgetKit.Widget, key: any): any
---@field SetWidth fun(self: WidgetKit.Widget, width: number)
---@field SetHeight fun(self: WidgetKit.Widget, height: number)
---@field GetWidth fun(self: WidgetKit.Widget): number
---@field GetHeight fun(self: WidgetKit.Widget): number
---@field SetFullWidth fun(self: WidgetKit.Widget, fullWidth: boolean)
---@field IsFullWidth fun(self: WidgetKit.Widget): boolean
---@field SetFullHeight fun(self: WidgetKit.Widget, fullHeight: boolean)
---@field IsFullHeight fun(self: WidgetKit.Widget): boolean
---@field SetRelativeWidth fun(self: WidgetKit.Widget, fraction: number?)
---@field GetRelativeWidth fun(self: WidgetKit.Widget): number?
---@field SetPoint fun(self: WidgetKit.Widget, point: string, ...: any)
---@field ClearAllPoints fun(self: WidgetKit.Widget)
---@field GetPoint fun(self: WidgetKit.Widget, index: integer?): string?, WidgetKit.Frame?, string?, number?, number?
---@field GetNumPoints fun(self: WidgetKit.Widget): integer
---@field SetParent fun(self: WidgetKit.Widget, parent: WidgetKit.Frame|WidgetKit.Widget|nil)
---@field Show fun(self: WidgetKit.Widget)
---@field Hide fun(self: WidgetKit.Widget)
---@field IsShown fun(self: WidgetKit.Widget): boolean
---@field IsVisible fun(self: WidgetKit.Widget): boolean
---@field IsReleasing fun(self: WidgetKit.Widget): boolean
---@field GetType fun(self: WidgetKit.Widget): string
---@field GetFrame fun(self: WidgetKit.Widget): WidgetKit.Frame
---@field GetParentContainer fun(self: WidgetKit.Widget): WidgetKit.Container?
---@field SetDisabled fun(self: WidgetKit.Widget, disabled: boolean?)
---@field Release fun(self: WidgetKit.Widget): true

---A widget that holds children.
---@class WidgetKit.Container: WidgetKit.Widget
---@field content WidgetKit.Frame The frame children are placed in, built by the constructor.
---@field AddChild fun(self: WidgetKit.Container, child: WidgetKit.Widget, beforeWidget: WidgetKit.Widget?): true|nil, "full"?
---@field AddChildren fun(self: WidgetKit.Container, ...: WidgetKit.Widget): integer added, "full"?
---@field ReleaseChildren fun(self: WidgetKit.Container): integer
---@field GetChildren fun(self: WidgetKit.Container): WidgetKit.Widget[]
---@field GetNumChildren fun(self: WidgetKit.Container): integer
---@field GetContent fun(self: WidgetKit.Container): WidgetKit.Frame
---@field SetLayout fun(self: WidgetKit.Container, layout: string|WidgetKit.Layout)
---@field GetLayoutName fun(self: WidgetKit.Container): string?
---@field PauseLayout fun(self: WidgetKit.Container)
---@field ResumeLayout fun(self: WidgetKit.Container)
---@field IsLayoutPaused fun(self: WidgetKit.Container): boolean
---@field PerformLayout fun(self: WidgetKit.Container): boolean done, string? reason
---@field LayoutFinished fun(self: WidgetKit.Container, width: number?, height: number?)
---@field SetMaxChildren fun(self: WidgetKit.Container, limit: integer|table)
---@field GetMaxChildren fun(self: WidgetKit.Container): integer|table

---The name of a base widget type. `Create` returns `WidgetKit.Widget`; cast
---the result to the type's class to reach its own methods:
---
---    local slider = WidgetKit:Create("Slider") --[[@as WidgetKit.Slider]]
---@alias WidgetKit.BaseTypeName "Frame"|"Group"|"ScrollFrame"|"Label"|"Button"|"CheckBox"|"Slider"|"EditBox"|"Dropdown"|"ColorPicker"|"Heading"|"Spacer"

---A movable, resizable window with a title and a close button.
---@class WidgetKit.Window: WidgetKit.Container
---@field SetTitle fun(self: WidgetKit.Window, text: any, options: WidgetKit.TextOptions?)
---@field GetTitle fun(self: WidgetKit.Window): any
---@field SetResizable fun(self: WidgetKit.Window, resizable: boolean)
---@field SetMovable fun(self: WidgetKit.Window, movable: boolean)
---@field BindPosition fun(self: WidgetKit.Window, storageTable: table, options: WidgetKit.BindingOptions?): WidgetKit.Binding
---@field GetBinding fun(self: WidgetKit.Window): WidgetKit.Binding?

---An inline group with a title.
---@class WidgetKit.Group: WidgetKit.Container
---@field SetTitle fun(self: WidgetKit.Group, text: any, options: WidgetKit.TextOptions?)
---@field GetTitle fun(self: WidgetKit.Group): any

---A scroll child with a scrollbar.
---@class WidgetKit.ScrollFrame: WidgetKit.Container
---@field GetContentHeight fun(self: WidgetKit.ScrollFrame): number
---@field GetScrollRange fun(self: WidgetKit.ScrollFrame): number
---@field GetScroll fun(self: WidgetKit.ScrollFrame): number
---@field SetScroll fun(self: WidgetKit.ScrollFrame, offset: number)

---One font string.
---@class WidgetKit.Label: WidgetKit.Widget
---@field SetText fun(self: WidgetKit.Label, text: any, options: WidgetKit.TextOptions?)
---@field GetText fun(self: WidgetKit.Label): any
---@field SetFontObject fun(self: WidgetKit.Label, fontObject: string|table)
---@field SetColor fun(self: WidgetKit.Label, red: number, green: number, blue: number, alpha: number?)
---@field SetJustifyH fun(self: WidgetKit.Label, justify: "LEFT"|"CENTER"|"RIGHT")

---A push button that can capture a key.
---@class WidgetKit.Button: WidgetKit.Widget
---@field SetText fun(self: WidgetKit.Button, text: any, options: WidgetKit.TextOptions?)
---@field GetText fun(self: WidgetKit.Button): any
---@field SetKeyCapture fun(self: WidgetKit.Button, enabled: boolean)
---@field IsCapturing fun(self: WidgetKit.Button): boolean

---A two- or three-state check box.
---@class WidgetKit.CheckBox: WidgetKit.Widget
---@field SetValue fun(self: WidgetKit.CheckBox, value: boolean?)
---@field GetValue fun(self: WidgetKit.CheckBox): boolean?
---@field SetTriState fun(self: WidgetKit.CheckBox, enabled: boolean)
---@field SetLabel fun(self: WidgetKit.CheckBox, text: any, options: WidgetKit.TextOptions?)
---@field GetLabel fun(self: WidgetKit.CheckBox): any

---A slider with a value box.
---@class WidgetKit.Slider: WidgetKit.Widget
---@field SetSliderValues fun(self: WidgetKit.Slider, minimum: number, maximum: number, step: number?)
---@field SetValue fun(self: WidgetKit.Slider, value: number)
---@field GetValue fun(self: WidgetKit.Slider): number
---@field SetIsPercent fun(self: WidgetKit.Slider, isPercent: boolean)
---@field SetLabel fun(self: WidgetKit.Slider, text: any, options: WidgetKit.TextOptions?)
---@field GetLabel fun(self: WidgetKit.Slider): any

---Single- and multi-line text entry.
---@class WidgetKit.EditBox: WidgetKit.Widget
---@field SetText fun(self: WidgetKit.EditBox, text: any, options: WidgetKit.TextOptions?)
---@field GetText fun(self: WidgetKit.EditBox): any
---@field SetMultiLine fun(self: WidgetKit.EditBox, multiLine: boolean, lines: integer?)
---@field IsMultiLine fun(self: WidgetKit.EditBox): boolean
---@field SetMaxLetters fun(self: WidgetKit.EditBox, letters: integer)
---@field SetFocus fun(self: WidgetKit.EditBox)
---@field SetLabel fun(self: WidgetKit.EditBox, text: any, options: WidgetKit.TextOptions?)
---@field GetLabel fun(self: WidgetKit.EditBox): any

---A keyboard-free list of buttons.
---@class WidgetKit.Dropdown: WidgetKit.Widget
---@field SetList fun(self: WidgetKit.Dropdown, values: table, order: any[]?)
---@field SetValue fun(self: WidgetKit.Dropdown, key: string|number|nil)
---@field GetValue fun(self: WidgetKit.Dropdown): string|number|nil
---@field GetNumEntries fun(self: WidgetKit.Dropdown): integer
---@field Open fun(self: WidgetKit.Dropdown): boolean
---@field Close fun(self: WidgetKit.Dropdown)
---@field IsOpen fun(self: WidgetKit.Dropdown): boolean
---@field PickIndex fun(self: WidgetKit.Dropdown, index: integer): boolean
---@field SetLabel fun(self: WidgetKit.Dropdown, text: any, options: WidgetKit.TextOptions?)
---@field GetLabel fun(self: WidgetKit.Dropdown): any

---A colour swatch over the client colour picker.
---@class WidgetKit.ColorPicker: WidgetKit.Widget
---@field SetColor fun(self: WidgetKit.ColorPicker, red: number, green: number, blue: number, alpha: number?)
---@field GetColor fun(self: WidgetKit.ColorPicker): number, number, number, number
---@field SetHasAlpha fun(self: WidgetKit.ColorPicker, hasAlpha: boolean)
---@field OpenPicker fun(self: WidgetKit.ColorPicker): boolean
---@field SetLabel fun(self: WidgetKit.ColorPicker, text: any, options: WidgetKit.TextOptions?)
---@field GetLabel fun(self: WidgetKit.ColorPicker): any

---A centred title between two lines.
---@class WidgetKit.Heading: WidgetKit.Widget
---@field SetText fun(self: WidgetKit.Heading, text: any, options: WidgetKit.TextOptions?)
---@field GetText fun(self: WidgetKit.Heading): any

---Empty space.
---@class WidgetKit.Spacer: WidgetKit.Widget

---A rect in screen coordinates.
---@class WidgetKit.Rect
---@field left number
---@field bottom number
---@field width number
---@field height number

---The anchor value type: plain fields, so it can be saved as it is.
---@class WidgetKit.Anchor
---@field point string One of the nine anchor points.
---@field relativeTo string|WidgetKit.Frame|nil The relative frame's global name when it has one, the frame itself when it has none, or `nil` for the parent.
---@field relativePoint string One of the nine anchor points.
---@field x number
---@field y number
---@field scale number? The frame's own scale when the anchor was taken.

---The anchor functions, called with a dot: `WidgetKit.Anchor.FromRect(...)`.
---@class WidgetKit.AnchorFunctions
---@field POINTS string[] The nine points, in election order.
---@field FromRect fun(rect: WidgetKit.Rect, parentRect: WidgetKit.Rect, into: table?): WidgetKit.Anchor
---@field Normalize fun(frame: WidgetKit.Frame, point: string, ...: any): WidgetKit.Anchor
---@field Apply fun(frame: WidgetKit.Frame, anchor: WidgetKit.Anchor): true|false, "forbidden"|"unknownRelative"|nil
---@field Read fun(frame: WidgetKit.Frame): WidgetKit.Anchor?

---Options for `WidgetKit:BindPosition`.
---@class WidgetKit.BindingOptions
---@field key string? The field of the storage table the anchor is saved in; default `"anchor"`.
---@field delay number? Seconds a save is debounced by when SchedulerKit is present; default 0.2.
---@field restore boolean? Apply the saved anchor when binding; default `true`.

---A frame's position bound to a storage table.
---@class WidgetKit.Binding
---@field Capture fun(self: WidgetKit.Binding): WidgetKit.Anchor|nil, string?
---@field Restore fun(self: WidgetKit.Binding): boolean
---@field Flush fun(self: WidgetKit.Binding): boolean
---@field OnMoved fun(self: WidgetKit.Binding, callback: fun(binding: WidgetKit.Binding, anchor: WidgetKit.Anchor)): table
---@field Release fun(self: WidgetKit.Binding): boolean
---@field IsReleased fun(self: WidgetKit.Binding): boolean

---Options for `WidgetKit:RenderOptions`.
---@class WidgetKit.RenderOptions
---@field allowSecret boolean? Show a secret value in an `input` option's edit box instead of a placeholder.
---@field media table<string, string>? Option path to MediaKit media type, for `select` options drawn as media pickers.
---@field confirmText string? The question an `execute` option with `confirm = true` asks; default `"Click again to confirm."`.

---The widgets rendered from one OptionsKit tree, released together.
---@class WidgetKit.Rendering
---@field Refresh fun(self: WidgetKit.Rendering): boolean
---@field Rebuild fun(self: WidgetKit.Rendering): boolean
---@field Release fun(self: WidgetKit.Rendering): boolean
---@field IsReleased fun(self: WidgetKit.Rendering): boolean
---@field GetWidget fun(self: WidgetKit.Rendering, path: string): WidgetKit.Widget?
---@field GetMessage fun(self: WidgetKit.Rendering, path: string): string?

---Counters of one widget type.
---@class WidgetKit.TypeStatistics
---@field version integer
---@field maxCreated integer
---@field created integer
---@field active integer
---@field available integer
---@field discarded integer

---What `GetStatistics` returns: totals and one row per type.
---@class WidgetKit.Statistics
---@field types integer
---@field created integer
---@field active integer
---@field available integer
---@field discarded integer
---@field byType table<string, WidgetKit.TypeStatistics>

---The WidgetKit package facade published through Registry.
---@class WidgetKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_CREATED integer Default frame cap per widget type (256).
---@field MAX_CHILDREN integer Children per container (256).
---@field MAX_CALLBACKS integer Named callbacks per widget (16).
---@field UNBOUNDED table Sentinel `maxCallbacks`, `SetMaxChildren` and the `maxDropdownEntries` limit accept to lift the bound; one table shared by every revision.
---@field SetLimits fun(self: WidgetKit, limits: WidgetKit.Limits)
---@field GetLimits fun(self: WidgetKit): WidgetKit.Limits
---@field Widget table Shared widget base prototype.
---@field Container table Shared container base prototype.
---@field Binding table Shared binding prototype.
---@field Rendering table Shared rendering prototype.
---@field Anchor WidgetKit.AnchorFunctions
---@field RegisterType fun(self: WidgetKit, name: string, constructor: WidgetKit.Constructor, version: integer, options: WidgetKit.TypeOptions?): boolean, string?
---@field GetTypeVersion fun(self: WidgetKit, name: string): integer?
---@field Create fun(self: WidgetKit, name: string): WidgetKit.Widget|nil, string?
---@field Release fun(self: WidgetKit, widget: WidgetKit.Widget): true
---@field IsWidget fun(self: WidgetKit, value: any): boolean
---@field RegisterLayout fun(self: WidgetKit, name: string, layout: WidgetKit.Layout): boolean, string?
---@field GetLayout fun(self: WidgetKit, name: string): WidgetKit.Layout?
---@field SetFocus fun(self: WidgetKit, widget: WidgetKit.Widget): true
---@field ClearFocus fun(self: WidgetKit): boolean
---@field GetFocus fun(self: WidgetKit): WidgetKit.Widget?
---@field GetStatistics fun(self: WidgetKit): WidgetKit.Statistics
---@field BindPosition fun(self: WidgetKit, frame: WidgetKit.Frame, storageTable: table, options: WidgetKit.BindingOptions?): WidgetKit.Binding
---@field RenderOptions fun(self: WidgetKit, tree: table, container: WidgetKit.Container, options: WidgetKit.RenderOptions?): WidgetKit.Rendering
---@field CreateMediaPicker fun(self: WidgetKit, mediaType: string): WidgetKit.Widget|nil, string?

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
    error("MoltenCodes WidgetKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
local findPackage = rawget(Registry, "Find")
if
    type(bootstrapPackage) ~= "function"
    or type(getPackage) ~= "function"
    or type(findPackage) ~= "function"
then
    error("MoltenCodes WidgetKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit owns every widget: one capped pool per type, and the scratch tables
-- layouts borrow.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
    type(PoolKit) ~= "table"
    or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
    or type(rawget(PoolKit, "New")) ~= "function"
    or type(rawget(PoolKit, "NewTablePool")) ~= "function"
then
    error("MoltenCodes WidgetKit requires PoolKit API 1 to be loaded first", 2)
end

-- SignalKit carries a binding's `OnMoved` listeners.
local SignalKit = getPackage(Registry, "signalKit", REQUIRED_SIGNALKIT_API)
if
    type(SignalKit) ~= "table"
    or rawget(SignalKit, "API") ~= REQUIRED_SIGNALKIT_API
    or type(rawget(SignalKit, "New")) ~= "function"
then
    error("MoltenCodes WidgetKit requires SignalKit API 1 to be loaded first", 2)
end

---Read a global from the host at call time, or `nil`.
---
---Host APIs and named client frames are reachable only through the global
---table. Reading at call time, never at load, lets a host facility that
---appears later be used at once.
---@param name string
---@return any
local function readGlobal(name)
    -- World of Warcraft client APIs and named frames exist only in the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

-- Validation -----------------------------------------------------------------

---Whether every name in `methodNames` is a function field of `prototype`.
---@param prototype any
---@param methodNames string[]
---@return boolean
local function hasMethods(prototype, methodNames)
    if type(prototype) ~= "table" then
        return false
    end
    for index = 1, #methodNames do
        if type(rawget(prototype, methodNames[index])) ~= "function" then
            return false
        end
    end
    return true
end

---Whether `implementation` exposes the complete WidgetKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
    if
        type(implementation) ~= "table"
        or rawget(implementation, "API") ~= API_GENERATION
        or type(rawget(implementation, "REVISION")) ~= "number"
        or type(rawget(implementation, "MAX_CREATED")) ~= "number"
        or type(rawget(implementation, "MAX_CHILDREN")) ~= "number"
        or type(rawget(implementation, "MAX_CALLBACKS")) ~= "number"
        or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    then
        return false
    end

    return hasMethods(implementation, FACADE_METHODS)
        and hasMethods(rawget(implementation, "Widget"), WIDGET_METHODS)
        and hasMethods(rawget(implementation, "Container"), CONTAINER_METHODS)
        and hasMethods(rawget(implementation, "Anchor"), ANCHOR_FUNCTIONS)
        and hasMethods(rawget(implementation, "Binding"), BINDING_METHODS)
        and hasMethods(rawget(implementation, "Rendering"), RENDERING_METHODS)
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
    return type(currentState) == "table"
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "runtimeRevision")) == "number"
        and type(rawget(currentState, "dispatch")) == "table"
        and type(rawget(currentState, "types")) == "table"
        and type(rawget(currentState, "layouts")) == "table"
        and type(rawget(currentState, "records")) == "table"
        and type(rawget(currentState, "widgetMetatable")) == "table"
        and type(rawget(currentState, "containerMetatable")) == "table"
        and type(rawget(currentState, "bindingMetatable")) == "table"
        and type(rawget(currentState, "renderingMetatable")) == "table"
        and type(rawget(currentState, "scratch")) == "table"
        and type(rawget(currentState, "unbounded")) == "table"
        and type(rawget(currentState, "limits")) == "table"
        and type(rawget(rawget(currentState, "limits"), "maxCreatedCeiling")) == "number"
        and rawget(rawget(currentState, "limits"), "maxDropdownEntries") ~= nil
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state keeps.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
    local currentState = rawget(implementation, "_state")
    return validateStateBase(currentState)
        and rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only WidgetKit can answer.
local WidgetKit, previousRevision, selected = bootstrapPackage(Registry, {
    package = PACKAGE_NAME,
    api = API_GENERATION,
    revision = IMPLEMENTATION_REVISION,
    label = "MoltenCodes WidgetKit",
    validatePublicSurface = validatePublicSurface,
    validateState = validateCurrentState,
})

if WidgetKit == nil then
    -- An equal or newer compatible revision already owns the shared package table.
    return selected
end

local WidgetBase = rawget(WidgetKit, "Widget")
local ContainerBase = rawget(WidgetKit, "Container")
local BindingPrototype = rawget(WidgetKit, "Binding")
local RenderingPrototype = rawget(WidgetKit, "Rendering")
local AnchorFunctions = rawget(WidgetKit, "Anchor")
local state = rawget(WidgetKit, "_state")

if previousRevision == nil then
    if
        WidgetBase ~= nil
        or ContainerBase ~= nil
        or BindingPrototype ~= nil
        or RenderingPrototype ~= nil
        or AnchorFunctions ~= nil
        or state ~= nil
    then
        error("MoltenCodes WidgetKit package state is corrupted or incomplete", 2)
    end

    WidgetBase = {}
    ContainerBase = setmetatable({}, { __index = WidgetBase })
    BindingPrototype = {}
    RenderingPrototype = {}
    AnchorFunctions = {}
    state = {
        schema = STATE_SCHEMA,
        runtimeRevision = 0,
        -- Pool callbacks call through this table, so a newer revision
        -- replaces what pools created by an older one do when they build or
        -- retire a widget.
        dispatch = {},
        -- Type name to its record: version, constructor, pool, cap.
        types = {},
        -- Layout name to layout function.
        layouts = {},
        -- Widget to its private record. Weak-keyed: a widget a pool
        -- discarded is not kept alive for its record.
        records = setmetatable({}, WEAK_KEYS),
        widgetMetatable = { __index = WidgetBase },
        containerMetatable = { __index = ContainerBase },
        bindingMetatable = { __index = BindingPrototype },
        renderingMetatable = { __index = RenderingPrototype },
        scratch = PoolKit:NewTablePool({ maxRetained = SCRATCH_RETAINED }),
        layoutDepth = 0,
        focus = false,
        holder = false,
        -- `WidgetKit.UNBOUNDED` lives here so every revision publishes the
        -- same table and an option written against one copy keeps its
        -- meaning after an upgrade.
        unbounded = {},
        -- The package-wide limits, shared by every consumer in the session;
        -- `SetLimits` writes here and an upgrade inherits what was set.
        limits = {
            maxCreatedCeiling = MAX_CREATED_CEILING.default,
            -- The most entries one dropdown list holds. The list keeps a
            -- fixed number of row frames and scrolls through the entries, so
            -- an entry costs two array slots of the consumer's own keys and
            -- labels, never a frame: `UNBOUNDED` is allowed. 1024 matches
            -- OptionsKit's default `values` bound. A literal rather than a
            -- file-scope constant: the main chunk is at Lua 5.1's limit of
            -- 200 local variables.
            maxDropdownEntries = 1024,
        },
    }
    rawset(WidgetKit, "Widget", WidgetBase)
    rawset(WidgetKit, "Container", ContainerBase)
    rawset(WidgetKit, "Binding", BindingPrototype)
    rawset(WidgetKit, "Rendering", RenderingPrototype)
    rawset(WidgetKit, "Anchor", AnchorFunctions)
    rawset(WidgetKit, "_state", state)
elseif
    type(WidgetBase) ~= "table"
    or type(ContainerBase) ~= "table"
    or type(BindingPrototype) ~= "table"
    or type(RenderingPrototype) ~= "table"
    or type(AnchorFunctions) ~= "table"
    or not validateStateBase(state)
then
    error("MoltenCodes WidgetKit package state is corrupted or incomplete", 2)
end

-- The prototypes, metatables and records are kept across upgrades, so widgets
-- built by an older copy keep their records and gain this copy's base methods
-- without being replaced.
local dispatch = rawget(state, "dispatch")
local types = rawget(state, "types")
local layouts = rawget(state, "layouts")
local records = rawget(state, "records")
local scratchPool = rawget(state, "scratch")
local WIDGET_METATABLE = rawget(state, "widgetMetatable")
local CONTAINER_METATABLE = rawget(state, "containerMetatable")
local BINDING_METATABLE = rawget(state, "bindingMetatable")
local RENDERING_METATABLE = rawget(state, "renderingMetatable")
local UNBOUNDED = rawget(state, "unbounded")

-- Host helpers ---------------------------------------------------------------

---Hand a failure to the host error handler.
---
---The failure is passed on unchanged: it may be a secret string built from a
---secret argument, and WidgetKit never inspects it.
---@param failure any
local function reportError(failure)
    local getErrorHandler = readGlobal("geterrorhandler")
    if type(getErrorHandler) == "function" then
        local handler = getErrorHandler()
        if type(handler) == "function" then
            handler(failure)
            return
        end
    end

    -- Outside a WoW client there is no error handler to report through.
    -- Printing is what the client's own default handler does, and staying
    -- silent would turn a callback bug into an invisible one.
    print(failure)
end

---Whether `value` is a secret value, asking the host's `issecretvalue` at every
---call. Clients without secret values do not publish the probe, and nothing
---is secret there.
---@param value any
---@return boolean
local function isSecret(value)
    local probe = readGlobal("issecretvalue")
    if type(probe) == "function" then
        return probe(value) == true
    end
    return false
end

---A global string the client localises, or `fallback` outside the client.
---@param name string
---@param fallback string
---@return string
local function clientText(name, fallback)
    local value = readGlobal(name)
    if type(value) == "string" and not isSecret(value) then
        return value
    end
    return fallback
end

---Whether a frame WidgetKit did not create may be touched from this code, as
---`docs/EMBEDDING.md` ("Frames you did not create") asks.
---@param frame table
---@return boolean
local function canTouchFrame(frame)
    local isForbidden = frame.IsForbidden
    if type(isForbidden) == "function" and isForbidden(frame) then
        return false
    end
    local canBeAccessed = frame.CanBeAccessedInContext
    if type(canBeAccessed) == "function" and not canBeAccessed(frame) then
        return false
    end
    return true
end

---Create a frame through the host's `CreateFrame`.
---@param frameType string
---@param parent WidgetKit.Frame?
---@param template string?
---@return WidgetKit.Frame
local function createFrame(frameType, parent, template)
    local create = readGlobal("CreateFrame")
    if type(create) ~= "function" then
        error("MoltenCodes WidgetKit requires the World of Warcraft CreateFrame API", 0)
    end
    return create(frameType, nil, parent, template)
end

---`UIParent` when the client has it, read at every call.
---@return WidgetKit.Frame?
local function restingParent()
    local uiParent = readGlobal("UIParent")
    if type(uiParent) == "table" and type(uiParent.GetWidth) == "function" then
        return uiParent
    end
    return nil
end

---The hidden frame retired widgets are parked on. Created once, on first use.
---@return WidgetKit.Frame
local function holderFrame()
    local holder = rawget(state, "holder")
    if holder == false or holder == nil then
        holder = createFrame("Frame", nil, nil)
        holder:Hide()
        rawset(state, "holder", holder)
    end
    return holder
end

---The parent a released widget's frame rests on: `UIParent` when the client
---has it, otherwise a hidden holder frame WidgetKit creates once.
---@return WidgetKit.Frame
local function releaseParent()
    return restingParent() or holderFrame()
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- WidgetKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.

---@param receiver any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, methodName, level)
    if receiver ~= WidgetKit then
        error(methodName .. " must be called on the WidgetKit facade", level)
    end
end

---Refuse anything but a non-empty, non-secret string. The secret check comes
---before the emptiness comparison, which would raise on a secret.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateName(value, label, level)
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if type(value) ~= "string" or value == "" then
        error(label .. " must be a non-empty string", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateNumber(value, label, level)
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    -- `value ~= value` is true only for NaN.
    if type(value) ~= "number" or value ~= value then
        error(label .. " must be a number", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePositiveInteger(value, label, level)
    -- The comparisons below would raise inside WidgetKit on a secret number.
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value ~= math.floor(value)
        or value == math.huge
    then
        error(label .. " must be a positive integer", level)
    end
end

---Refuse anything but a positive integer or `WidgetKit.UNBOUNDED`.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateLimitOrUnbounded(value, label, level)
    -- Before the sentinel comparison, which would raise on a secret.
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
    if value == UNBOUNDED then
        return
    end
    if
        type(value) ~= "number"
        or value ~= value
        or value < 1
        or value ~= math.floor(value)
        or value == math.huge
    then
        error(label .. " must be a positive integer or WidgetKit.UNBOUNDED", level)
    end
end

---The bound a hot path compares against: the integer itself, or `math.huge`
---for `WidgetKit.UNBOUNDED`, so the comparison never tests for the sentinel.
---@param limit integer|table a validated limit
---@return number
local function capacityOf(limit)
    -- Validation lets exactly one table through: `WidgetKit.UNBOUNDED`.
    if type(limit) == "number" then
        return limit
    end
    return math.huge
end

---Refuse an option table with a field outside `allowed`, naming the
---alphabetically first one without allocating.
---@param options any
---@param allowed table<string, boolean>
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOptionKeys(options, allowed, label, level)
    if type(options) ~= "table" then
        error(label .. " must be a table", level)
    end
    local firstUnknown = nil
    for key in next, options do
        if allowed[key] ~= true then
            local text = type(key) == "string" and key or ("<" .. type(key) .. ">")
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(label .. ' contains unknown field "' .. firstUnknown .. '"', level)
    end
end

---Refuse a secret `value` handed to a widget method that would inspect it.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
    if isSecret(value) then
        error(label .. " must not be a secret value", level)
    end
end

-- Widget records -------------------------------------------------------------
--
-- Everything WidgetKit knows about a widget lives in a record kept in a
-- weak-keyed table of its own, never on the widget or its frame:
--
--   typeRecord        the type the widget was built for
--   active            borrowed from its pool and not yet released
--   releasing         inside `Release`
--   isContainer       built with a `content` frame
--   parent            the container holding it, or `nil`
--   children          the container's children in order (containers only)
--   callbacks         name -> callback, created on the first `SetCallback`
--   callbackCount     how many names `callbacks` holds
--   userData          key -> value, created on the first `SetUserData`
--   fullWidth, fullHeight, relativeWidth
--                     the size requests layouts read
--   layoutName        the named layout, resolved on every pass
--   layoutFunction    a layout function passed directly, or `nil`
--   layoutPaused, layingOut
--                     the container's layout state
--   version           the type version whose constructor built the widget
--   serial            raised on every acquire, so a holder tells uses apart
--   renderings        the renderings drawn into the container, or `nil`

---The record of an active widget, or an error at the caller.
---@param widget any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table record
local function activeRecord(widget, methodName, level)
    local record = type(widget) == "table" and records[widget] or nil
    if record == nil then
        error(methodName .. " must be called on a WidgetKit widget", level)
    end
    if not record.active then
        error(methodName .. " cannot be called on a released widget", level)
    end
    return record
end

---The record of an active container, or an error at the caller.
---@param widget any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table record
local function activeContainerRecord(widget, methodName, level)
    local record = activeRecord(widget, methodName, level + 1)
    if not record.isContainer then
        error(methodName .. " must be called on a WidgetKit container", level)
    end
    return record
end

---Whether `record` or any container above it is being released.
---@param record table
---@return boolean
local function isReleasingRecord(record)
    local current = record ---@type table?
    while current ~= nil do
        if current.releasing then
            return true
        end
        local parent = current.parent
        current = parent ~= nil and records[parent] or nil
    end
    return false
end

---Empty a table in place, so it can be reused without allocating.
---@param target table
local function wipe(target)
    for key in next, target do
        target[key] = nil
    end
end

---Remove `child` from its container's children, searching from the end
---because release walks children from the end.
---@param record table the child's record
---@param child WidgetKit.Widget
local function detachFromParent(record, child)
    local parent = record.parent
    if parent == nil then
        return
    end
    record.parent = nil
    local parentRecord = records[parent]
    if parentRecord == nil then
        return
    end
    local children = parentRecord.children
    for index = #children, 1, -1 do
        if children[index] == child then
            table.remove(children, index)
            return
        end
    end
end

---Check a `SetDisabled` argument for the base method.
---@param widget any
---@param disabled any
local function readDisabledBase(widget, disabled)
    activeRecord(widget, "WidgetKit.Widget:SetDisabled", 4)
    if disabled ~= nil and type(disabled) ~= "boolean" then
        error("WidgetKit.Widget:SetDisabled disabled must be a boolean", 3)
    end
end

-- Widget base ----------------------------------------------------------------
--
-- Every widget's metatable falls back to these methods; a container's falls
-- back to the container base first. A widget type may define its own method of
-- the same name on the widget table, which is found first.

---Call a widget type's optional hook, isolating and reporting its failure.
---@param widget table
---@param hookName string
---@param ... any
local function callHook(widget, hookName, ...)
    local hook = rawget(widget, hookName)
    if type(hook) == "function" then
        local ok, failure = pcall(hook, widget, ...)
        if not ok then
            reportError(failure)
        end
    end
end

---@param name string
---@param callback WidgetKit.Callback?
function WidgetBase:SetCallback(name, callback)
    local record = activeRecord(self, "WidgetKit.Widget:SetCallback", 3)
    validateName(name, "WidgetKit.Widget:SetCallback name", 3)
    if callback ~= nil and type(callback) ~= "function" then
        error("WidgetKit.Widget:SetCallback callback must be a function or nil", 2)
    end

    local callbacks = record.callbacks
    if callbacks == nil then
        if callback == nil then
            return
        end
        callbacks = {}
        record.callbacks = callbacks
    end

    local existing = callbacks[name]
    if callback == nil then
        if existing ~= nil then
            callbacks[name] = nil
            record.callbackCount = record.callbackCount - 1
        end
        return
    end
    if existing == nil then
        -- A type registered by an older copy of this file has no
        -- `maxCallbacks`; it keeps the default.
        local maxCallbacks = record.typeRecord.maxCallbacks or MAX_CALLBACKS
        if record.callbackCount >= maxCallbacks then
            error(
                "WidgetKit.Widget:SetCallback holds at most "
                    .. maxCallbacks
                    .. " callbacks per widget",
                2
            )
        end
        record.callbackCount = record.callbackCount + 1
    end
    callbacks[name] = callback
end

---Call the callback registered under `name` with `(widget, name, ...)`. A
---callback error is reported through the host error handler, never raised.
---@param name string
---@return boolean called `true` when a callback ran without raising
function WidgetBase:Fire(name, ...)
    local record = type(self) == "table" and records[self] or nil
    if record == nil then
        error("WidgetKit.Widget:Fire must be called on a WidgetKit widget", 2)
    end
    local callbacks = record.callbacks
    local callback = callbacks ~= nil and callbacks[name] or nil
    if callback == nil or not record.active then
        return false
    end
    local ok, failure = pcall(callback, self, name, ...)
    if not ok then
        reportError(failure)
        return false
    end
    return true
end

---@param key any
---@param value any
function WidgetBase:SetUserData(key, value)
    local record = activeRecord(self, "WidgetKit.Widget:SetUserData", 3)
    -- Before the nil test, which would raise on a secret.
    refuseSecret(key, "WidgetKit.Widget:SetUserData key", 3)
    if key == nil then
        error("WidgetKit.Widget:SetUserData key must not be nil", 2)
    end
    local userData = record.userData
    if userData == nil then
        if value == nil then
            return
        end
        userData = {}
        record.userData = userData
    end
    userData[key] = value
end

---@param key any
---@return any
function WidgetBase:GetUserData(key)
    local record = activeRecord(self, "WidgetKit.Widget:GetUserData", 3)
    -- Before the nil test, which would raise on a secret.
    refuseSecret(key, "WidgetKit.Widget:GetUserData key", 3)
    if key == nil then
        return nil
    end
    local userData = record.userData
    if userData == nil then
        return nil
    end
    return userData[key]
end

---@param width number
function WidgetBase:SetWidth(width)
    activeRecord(self, "WidgetKit.Widget:SetWidth", 3)
    validateNumber(width, "WidgetKit.Widget:SetWidth width", 3)
    self.frame:SetWidth(width)
    callHook(self, "OnWidthSet", width)
end

---@param height number
function WidgetBase:SetHeight(height)
    activeRecord(self, "WidgetKit.Widget:SetHeight", 3)
    validateNumber(height, "WidgetKit.Widget:SetHeight height", 3)
    self.frame:SetHeight(height)
    callHook(self, "OnHeightSet", height)
end

---@return number
function WidgetBase:GetWidth()
    activeRecord(self, "WidgetKit.Widget:GetWidth", 3)
    return self.frame:GetWidth()
end

---@return number
function WidgetBase:GetHeight()
    activeRecord(self, "WidgetKit.Widget:GetHeight", 3)
    return self.frame:GetHeight()
end

---@param fullWidth boolean
function WidgetBase:SetFullWidth(fullWidth)
    local record = activeRecord(self, "WidgetKit.Widget:SetFullWidth", 3)
    record.fullWidth = fullWidth == true
    if record.fullWidth then
        record.relativeWidth = nil
    end
end

---@return boolean
function WidgetBase:IsFullWidth()
    return activeRecord(self, "WidgetKit.Widget:IsFullWidth", 3).fullWidth == true
end

---@param fullHeight boolean
function WidgetBase:SetFullHeight(fullHeight)
    local record = activeRecord(self, "WidgetKit.Widget:SetFullHeight", 3)
    record.fullHeight = fullHeight == true
end

---@return boolean
function WidgetBase:IsFullHeight()
    return activeRecord(self, "WidgetKit.Widget:IsFullHeight", 3).fullHeight == true
end

---@param fraction number? of the container's width, above 0 and at most 1; `nil` clears it
function WidgetBase:SetRelativeWidth(fraction)
    local record = activeRecord(self, "WidgetKit.Widget:SetRelativeWidth", 3)
    -- `type`, not `~= nil`: comparing a secret raises before validation refuses it.
    if type(fraction) ~= "nil" then
        validateNumber(fraction, "WidgetKit.Widget:SetRelativeWidth fraction", 3)
        if fraction <= 0 or fraction > 1 then
            error("WidgetKit.Widget:SetRelativeWidth fraction must be above 0 and at most 1", 2)
        end
        record.fullWidth = false
    end
    record.relativeWidth = fraction
end

---@return number?
function WidgetBase:GetRelativeWidth()
    return activeRecord(self, "WidgetKit.Widget:GetRelativeWidth", 3).relativeWidth
end

---@param point string one of the nine anchor points
---@param ... any the rest of `SetPoint`'s arguments: relative frame, relative point, x, y
function WidgetBase:SetPoint(point, ...)
    activeRecord(self, "WidgetKit.Widget:SetPoint", 3)
    self.frame:SetPoint(point, ...)
end

function WidgetBase:ClearAllPoints()
    activeRecord(self, "WidgetKit.Widget:ClearAllPoints", 3)
    self.frame:ClearAllPoints()
end

---@param index integer?
function WidgetBase:GetPoint(index)
    activeRecord(self, "WidgetKit.Widget:GetPoint", 3)
    return self.frame:GetPoint(index or 1)
end

---@return integer
function WidgetBase:GetNumPoints()
    activeRecord(self, "WidgetKit.Widget:GetNumPoints", 3)
    return self.frame:GetNumPoints()
end

---Parent the widget's frame to a frame, or to another widget (its content
---frame when it is a container). Only a widget outside any container may be
---re-parented this way; a container places its children itself.
---@param parent WidgetKit.Frame|WidgetKit.Widget|nil
function WidgetBase:SetParent(parent)
    local record = activeRecord(self, "WidgetKit.Widget:SetParent", 3)
    if record.parent ~= nil then
        error("WidgetKit.Widget:SetParent cannot re-parent a widget inside a container", 2)
    end
    local target = parent
    if type(parent) == "table" and records[parent] ~= nil then
        target = rawget(parent, "content") or parent.frame
    elseif parent ~= nil and type(parent) ~= "table" then
        error("WidgetKit.Widget:SetParent parent must be a frame, a widget or nil", 2)
    end
    self.frame:SetParent(target)
end

function WidgetBase:Show()
    activeRecord(self, "WidgetKit.Widget:Show", 3)
    self.frame:Show()
end

function WidgetBase:Hide()
    activeRecord(self, "WidgetKit.Widget:Hide", 3)
    self.frame:Hide()
    if rawget(state, "focus") == self then
        WidgetKit:ClearFocus()
    end
end

---@return boolean
function WidgetBase:IsShown()
    activeRecord(self, "WidgetKit.Widget:IsShown", 3)
    return self.frame:IsShown() == true
end

---@return boolean
function WidgetBase:IsVisible()
    activeRecord(self, "WidgetKit.Widget:IsVisible", 3)
    return self.frame:IsVisible() == true
end

---Whether this widget, or any container above it, is being released.
---@return boolean
function WidgetBase:IsReleasing()
    local record = type(self) == "table" and records[self] or nil
    if record == nil then
        error("WidgetKit.Widget:IsReleasing must be called on a WidgetKit widget", 2)
    end
    return isReleasingRecord(record)
end

---@return string
function WidgetBase:GetType()
    local record = type(self) == "table" and records[self] or nil
    if record == nil then
        error("WidgetKit.Widget:GetType must be called on a WidgetKit widget", 2)
    end
    return record.typeRecord.name
end

---@return WidgetKit.Frame
function WidgetBase:GetFrame()
    activeRecord(self, "WidgetKit.Widget:GetFrame", 3)
    return self.frame
end

---The base `SetDisabled` only checks its argument: a widget type that can be
---disabled defines its own, which is found first. `Frame`, `ScrollFrame` and
---`Spacer` have nothing to grey out and use this one.
---@param disabled boolean?
function WidgetBase:SetDisabled(disabled)
    readDisabledBase(self, disabled)
end

---@return WidgetKit.Container?
function WidgetBase:GetParentContainer()
    return activeRecord(self, "WidgetKit.Widget:GetParentContainer", 3).parent
end

-- `WidgetBase:Release` is defined with the type registry, below, because it
-- shares the release routine with `WidgetKit:Release`.

-- Container base -------------------------------------------------------------

local performLayout

---Whether `candidate` is `container` or a container above it.
---@param candidate WidgetKit.Widget
---@param container WidgetKit.Widget
---@return boolean
local function isSelfOrAncestor(candidate, container)
    local current = container ---@type WidgetKit.Widget?
    while current ~= nil do
        if current == candidate then
            return true
        end
        local record = records[current]
        current = record ~= nil and record.parent or nil
    end
    return false
end

---Validate one child for `AddChild` / `AddChildren`.
---@param container WidgetKit.Container
---@param child any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table childRecord
local function validateChild(container, child, methodName, level)
    local childRecord = type(child) == "table" and records[child] or nil
    if childRecord == nil or not childRecord.active then
        error(methodName .. " child must be an active WidgetKit widget", level)
    end
    if childRecord.releasing then
        error(methodName .. " child is being released", level)
    end
    if isSelfOrAncestor(child, container) then
        error(methodName .. " child must not be the container or a container above it", level)
    end
    return childRecord
end

---Insert `child` into `container` before `beforeWidget` (or at the end),
---moving it out of a container it was in.
---@param container WidgetKit.Container
---@param record table the container's record
---@param child WidgetKit.Widget
---@param childRecord table
---@param beforeWidget WidgetKit.Widget?
local function insertChild(container, record, child, childRecord, beforeWidget)
    if childRecord.parent ~= nil then
        detachFromParent(childRecord, child)
    end

    local children = record.children
    local position = #children + 1
    if beforeWidget ~= nil then
        for index = 1, #children do
            if children[index] == beforeWidget then
                position = index
                break
            end
        end
    end
    table.insert(children, position, child)

    childRecord.parent = container
    local frame = child.frame
    frame:SetParent(rawget(container, "content"))
    frame:Show()
end

---Add `child` to this container, before `beforeWidget` when it is given, and
---lay the container out unless its layout is paused.
---@param child WidgetKit.Widget
---@param beforeWidget WidgetKit.Widget?
---@return true|nil added, "full"? reason
function ContainerBase:AddChild(child, beforeWidget)
    local record = activeContainerRecord(self, "WidgetKit.Container:AddChild", 3)
    if isReleasingRecord(record) then
        error("WidgetKit.Container:AddChild cannot add to a container that is being released", 2)
    end
    local childRecord = validateChild(self, child, "WidgetKit.Container:AddChild", 3)
    if beforeWidget ~= nil then
        local beforeRecord = type(beforeWidget) == "table" and records[beforeWidget] or nil
        if beforeRecord == nil or beforeRecord.parent ~= self then
            error("WidgetKit.Container:AddChild beforeWidget must be a child of this container", 2)
        end
        if beforeWidget == child then
            error("WidgetKit.Container:AddChild beforeWidget must not be the child itself", 2)
        end
    end
    if childRecord.parent ~= self and #record.children >= record.maxChildren then
        return nil, "full"
    end

    insertChild(self, record, child, childRecord, beforeWidget)
    if not record.layoutPaused then
        performLayout(self, record)
    end
    return true
end

---Add every argument in order and lay the container out once.
---@return integer added, "full"? reason
function ContainerBase:AddChildren(...)
    local record = activeContainerRecord(self, "WidgetKit.Container:AddChildren", 3)
    if isReleasingRecord(record) then
        error("WidgetKit.Container:AddChildren cannot add to a container that is being released", 2)
    end
    local count = select("#", ...)
    for index = 1, count do
        validateChild(self, (select(index, ...)), "WidgetKit.Container:AddChildren", 3)
    end

    local added = 0
    local reason = nil
    for index = 1, count do
        local child = select(index, ...)
        local childRecord = records[child]
        if childRecord.parent ~= self and #record.children >= record.maxChildren then
            reason = "full"
            break
        end
        insertChild(self, record, child, childRecord, nil)
        added = added + 1
    end

    if not record.layoutPaused then
        performLayout(self, record)
    end
    return added, reason
end

---@return WidgetKit.Widget[] children the container's own array; read it, never change it
function ContainerBase:GetChildren()
    return activeContainerRecord(self, "WidgetKit.Container:GetChildren", 3).children
end

---@return integer
function ContainerBase:GetNumChildren()
    return #activeContainerRecord(self, "WidgetKit.Container:GetNumChildren", 3).children
end

---Change how many children this container holds: a positive integer or
---`WidgetKit.UNBOUNDED`. Lowering it below the current count keeps every
---child and refuses the next addition. Release restores the default.
---@param limit integer|table
function ContainerBase:SetMaxChildren(limit)
    local record = activeContainerRecord(self, "WidgetKit.Container:SetMaxChildren", 3)
    validateLimitOrUnbounded(limit, "WidgetKit.Container:SetMaxChildren limit", 3)
    record.maxChildren = capacityOf(limit)
end

---@return integer|table limit the child bound, or `WidgetKit.UNBOUNDED`
function ContainerBase:GetMaxChildren()
    local record = activeContainerRecord(self, "WidgetKit.Container:GetMaxChildren", 3)
    if record.maxChildren == math.huge then
        return UNBOUNDED
    end
    return record.maxChildren
end

---@return WidgetKit.Frame
function ContainerBase:GetContent()
    activeContainerRecord(self, "WidgetKit.Container:GetContent", 3)
    return rawget(self, "content")
end

---@param layout string|WidgetKit.Layout a registered layout name, or a layout function
function ContainerBase:SetLayout(layout)
    local record = activeContainerRecord(self, "WidgetKit.Container:SetLayout", 3)
    if type(layout) == "function" then
        record.layoutName = nil
        record.layoutFunction = layout
        return
    end
    validateName(layout, "WidgetKit.Container:SetLayout layout", 3)
    if layouts[layout] == nil then
        error('WidgetKit.Container:SetLayout layout "' .. layout .. '" is not registered', 2)
    end
    record.layoutName = layout
    record.layoutFunction = nil
end

---@return string? name `nil` when the layout was set as a function
function ContainerBase:GetLayoutName()
    return activeContainerRecord(self, "WidgetKit.Container:GetLayoutName", 3).layoutName
end

function ContainerBase:PauseLayout()
    activeContainerRecord(self, "WidgetKit.Container:PauseLayout", 3).layoutPaused = true
end

---Resume layout. Like pausing, this lays nothing out: call `PerformLayout`.
function ContainerBase:ResumeLayout()
    activeContainerRecord(self, "WidgetKit.Container:ResumeLayout", 3).layoutPaused = false
end

---@return boolean
function ContainerBase:IsLayoutPaused()
    return activeContainerRecord(self, "WidgetKit.Container:IsLayoutPaused", 3).layoutPaused == true
end

---Lay the container's children out now.
---@return boolean done
---@return string? reason `"paused"`, `"recursion"`, `"releasing"` or `"depth"`
function ContainerBase:PerformLayout()
    local record = activeContainerRecord(self, "WidgetKit.Container:PerformLayout", 3)
    return performLayout(self, record)
end

---The upward size report a layout pass ends with. Records nothing itself:
---it calls the type's `OnLayoutFinished(width, height)` hook, and when that
---changed the container's height, lays out the container holding it — unless
---that one is laying out already, paused or being released.
---@param width number?
---@param height number?
function ContainerBase:LayoutFinished(width, height)
    local record = activeContainerRecord(self, "WidgetKit.Container:LayoutFinished", 3)
    if width ~= nil then
        validateNumber(width, "WidgetKit.Container:LayoutFinished width", 3)
    end
    if height ~= nil then
        validateNumber(height, "WidgetKit.Container:LayoutFinished height", 3)
    end

    local frame = self.frame
    local heightBefore = frame:GetHeight()
    callHook(self, "OnLayoutFinished", width, height)
    if frame:GetHeight() == heightBefore then
        return
    end

    local parent = record.parent
    local parentRecord = parent ~= nil and records[parent] or nil
    if
        parentRecord ~= nil
        and parentRecord.active
        and not parentRecord.layingOut
        and not parentRecord.layoutPaused
        and not isReleasingRecord(parentRecord)
    then
        performLayout(parent, parentRecord)
    end
end

---Run the container's layout once.
---
---The layout is resolved by name on every pass, so a newer copy's built-in
---layouts take over containers an older copy built. A pass inside a pass of
---the same container is refused, never looped; a layout error is re-raised
---unchanged after the container's layout state was restored.
---@param container WidgetKit.Widget a container
---@param record table
---@return boolean done
---@return string? reason
function performLayout(container, record)
    if record.layoutPaused then
        return false, "paused"
    end
    if record.layingOut then
        return false, "recursion"
    end
    if isReleasingRecord(record) then
        return false, "releasing"
    end
    local depth = rawget(state, "layoutDepth")
    if depth >= MAX_LAYOUT_DEPTH then
        return false, "depth"
    end

    local layout = record.layoutFunction
    if layout == nil then
        layout = layouts[record.layoutName] or layouts[LAYOUT_LIST]
    end

    -- The pass is marked before `OnLayoutStart` runs, so a hook that asks for
    -- a layout of its own container is refused with `"recursion"` instead of
    -- recursing without bound.
    record.layingOut = true
    rawset(state, "layoutDepth", depth + 1)
    callHook(container, "OnLayoutStart")
    local scratch = scratchPool:Acquire()
    local ok, width, height =
        pcall(layout, rawget(container, "content"), record.children, container, scratch)
    scratchPool:Release(scratch)
    rawset(state, "layoutDepth", depth)
    record.layingOut = false

    if not ok then
        error(width, 0)
    end
    if type(width) ~= "number" or width ~= width then
        width = nil
    end
    if type(height) ~= "number" or height ~= height then
        height = nil
    end
    ContainerBase.LayoutFinished(container, width, height)
    return true
end

-- Layouts --------------------------------------------------------------------
--
-- Each built-in layout reads the size requests from the child records and
-- places children with `ClearAllPoints` and `SetPoint` relative to the
-- content frame. A child that is itself a container is laid out as soon as
-- its width is known, so a pass runs top-down and each container reports its
-- height before its parent reads it. Hidden children are skipped.

---Tell a child that a layout sized it.
---@param child WidgetKit.Widget
---@param width number?
---@param height number?
local function notifySized(child, width, height)
    if width ~= nil then
        callHook(child, "OnWidthSet", width)
    end
    if height ~= nil then
        callHook(child, "OnHeightSet", height)
    end
end

---Lay a child container out once its size is set.
---@param child WidgetKit.Widget
---@param childRecord table
local function layoutNested(child, childRecord)
    if childRecord.isContainer then
        performLayout(child, childRecord)
    end
end

---`List`: children stacked from the top, each below the previous one.
---Full-width children span the content; relative widths are a fraction of it.
---@type WidgetKit.Layout
local function listLayout(content, children)
    -- Insets larger than the container leave the content a negative width;
    -- no child is ever sized below zero.
    local width = math.max(content:GetWidth(), 0)
    local offset = 0
    for index = 1, #children do
        local child = children[index]
        local childRecord = records[child]
        local frame = child.frame
        if childRecord ~= nil and frame:IsShown() then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -offset)
            if childRecord.fullWidth then
                frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -offset)
                notifySized(child, width, nil)
            elseif childRecord.relativeWidth ~= nil then
                local childWidth = width * childRecord.relativeWidth
                frame:SetWidth(childWidth)
                notifySized(child, childWidth, nil)
            end
            layoutNested(child, childRecord)
            offset = offset + frame:GetHeight()
        end
    end
    return width, offset
end

---`Fill`: the first shown child fills the content; the others are left alone.
---@type WidgetKit.Layout
local function fillLayout(content, children)
    local width = math.max(content:GetWidth(), 0)
    local height = math.max(content:GetHeight(), 0)
    for index = 1, #children do
        local child = children[index]
        local childRecord = records[child]
        local frame = child.frame
        if childRecord ~= nil and frame:IsShown() then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
            notifySized(child, width, height)
            layoutNested(child, childRecord)
            return width, height
        end
    end
    return width, 0
end

---`Flow`: children left to right, wrapping to a new row when the next one
---would pass the content's right edge. A full-width child takes a row of its
---own; a full-height child takes the height left below its row's top.
---@type WidgetKit.Layout
local function flowLayout(content, children)
    -- Relative widths are fractions of the content, so children that exactly
    -- fill a row may sum to a hair above its width in floating point. A row
    -- overflows only past this many pixels, far below anything visible.
    local fitTolerance = 0.001
    local width = math.max(content:GetWidth(), 0)
    local contentHeight = content:GetHeight()
    local x = 0
    local rowTop = 0
    local rowHeight = 0
    for index = 1, #children do
        local child = children[index]
        local childRecord = records[child]
        local frame = child.frame
        if childRecord ~= nil and frame:IsShown() then
            local childWidth
            if childRecord.fullWidth then
                childWidth = width
            elseif childRecord.relativeWidth ~= nil then
                childWidth = width * childRecord.relativeWidth
            else
                childWidth = frame:GetWidth()
            end

            -- Wrap before a child that does not fit, or before a full-width
            -- child, unless the row is still empty.
            if x > 0 and (childRecord.fullWidth or x + childWidth > width + fitTolerance) then
                rowTop = rowTop + rowHeight
                x = 0
                rowHeight = 0
            end

            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -rowTop)
            if childRecord.fullWidth then
                frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -rowTop)
            elseif childRecord.relativeWidth ~= nil then
                frame:SetWidth(childWidth)
            end

            local sizedHeight = nil
            if childRecord.fullHeight then
                sizedHeight = contentHeight - rowTop
                if sizedHeight < 0 then
                    sizedHeight = 0
                end
                frame:SetHeight(sizedHeight)
            end
            notifySized(child, childWidth, sizedHeight)
            layoutNested(child, childRecord)

            local childHeight = frame:GetHeight()
            if childHeight > rowHeight then
                rowHeight = childHeight
            end
            x = x + childWidth
            if childRecord.fullWidth then
                rowTop = rowTop + rowHeight
                x = 0
                rowHeight = 0
            end
        end
    end
    return width, rowTop + rowHeight
end

-- Type registry --------------------------------------------------------------
--
-- One PoolKit pool per type, created by the first registration. The pool is
-- capped (`maxCreated`), retains every widget it ever built (the retention
-- bound follows the cap), and is generation-stamped with the type version, so
-- raising the version retires every pooled widget the older constructor built.

---Build one widget of `typeRecord`'s type. Runs as the pool's `create`, through
---`dispatch`, so a newer copy's build runs for pools an older copy created.
---
---A constructor that returns something unusable is a caller error; the
---message is left in `state.buildProblem` for `Create` to raise at its caller.
---@param typeRecord table
---@return table widget
local function buildWidget(typeRecord)
    local widget = typeRecord.constructor(typeRecord.name)
    local problem = nil
    if type(widget) ~= "table" then
        problem = "must return a table"
    elseif getmetatable(widget) ~= nil then
        problem = "must return a table without a metatable"
    elseif records[widget] ~= nil then
        problem = "must return a new table on every call"
    elseif type(rawget(widget, "frame")) ~= "table" then
        problem = "must return a table whose frame field is a frame"
    elseif rawget(widget, "content") ~= nil and type(rawget(widget, "content")) ~= "table" then
        problem = "must return a content field that is a frame, or none"
    elseif
        rawget(widget, "OnAcquire") ~= nil and type(rawget(widget, "OnAcquire")) ~= "function"
    then
        problem = "must return an OnAcquire field that is a function, or none"
    elseif
        rawget(widget, "OnRelease") ~= nil and type(rawget(widget, "OnRelease")) ~= "function"
    then
        problem = "must return an OnRelease field that is a function, or none"
    end
    if problem ~= nil then
        local message = 'constructor of type "' .. typeRecord.name .. '" ' .. problem
        rawset(state, "buildProblem", message)
        error(message, 0)
    end

    local isContainer = rawget(widget, "content") ~= nil
    setmetatable(widget, isContainer and CONTAINER_METATABLE or WIDGET_METATABLE)
    records[widget] = {
        typeRecord = typeRecord,
        active = false,
        releasing = false,
        isContainer = isContainer,
        parent = nil,
        children = isContainer and {} or nil,
        -- `math.huge` after `SetMaxChildren(WidgetKit.UNBOUNDED)`.
        maxChildren = MAX_CHILDREN,
        callbacks = nil,
        callbackCount = 0,
        userData = nil,
        fullWidth = false,
        fullHeight = false,
        relativeWidth = nil,
        layoutName = LAYOUT_LIST,
        layoutFunction = nil,
        layoutPaused = false,
        layingOut = false,
        -- The type version whose constructor built this widget.
        version = typeRecord.version,
        -- Raised on every acquire, so a holder can tell this use from the
        -- next one of the same pooled widget.
        serial = 0,
        -- Renderings drawn into this container, released with it.
        renderings = nil,
    }

    local frame = widget.frame
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(releaseParent())
    return widget
end

---Retire a widget its pool let go of: a stale generation, or a closed pool.
---The client never frees the frame, so it is parked, hidden, on the holder.
---@param widget table
local function retireWidget(widget)
    records[widget] = nil
    local frame = rawget(widget, "frame")
    if type(frame) == "table" then
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(holderFrame())
    end
end

-- Defined with the renderer, below.
local releaseContainerRenderings

---Release `widget` and everything below it. The caller has checked that it is
---active and not already releasing.
---
---In order: the `OnRelease` callback, children from last to first, the type's
---`OnRelease` hook, then the record is cleared (callbacks, user data, size
---requests, layout), the frame loses its anchors, is hidden and re-parented,
---the widget leaves its container, and the pool takes it back.
---@param widget table
---@param record table
local function releaseWidget(widget, record)
    record.releasing = true
    if rawget(state, "focus") == widget then
        WidgetKit:ClearFocus()
    end

    -- A rendering never outlives its container: it is released first, while
    -- its widgets are still this container's children.
    local renderings = record.renderings
    if renderings ~= nil and #renderings > 0 then
        releaseContainerRenderings(renderings)
    end

    WidgetBase.Fire(widget, "OnRelease")

    local children = record.children
    if children ~= nil then
        for index = #children, 1, -1 do
            local child = children[index]
            local childRecord = child ~= nil and records[child] or nil
            if childRecord ~= nil and childRecord.active and not childRecord.releasing then
                releaseWidget(child, childRecord)
            end
            -- A child that failed to detach itself is dropped all the same.
            if children[index] == child then
                children[index] = nil
            end
        end
    end

    callHook(widget, "OnRelease")

    local callbacks = record.callbacks
    if callbacks ~= nil then
        wipe(callbacks)
    end
    record.callbackCount = 0
    record.maxChildren = MAX_CHILDREN
    local userData = record.userData
    if userData ~= nil then
        wipe(userData)
    end
    record.fullWidth = false
    record.fullHeight = false
    record.relativeWidth = nil
    record.layoutName = LAYOUT_LIST
    record.layoutFunction = nil
    record.layoutPaused = false

    local frame = widget.frame
    frame:ClearAllPoints()
    frame:Hide()
    frame:SetParent(releaseParent())

    detachFromParent(record, widget)
    record.releasing = false
    record.active = false
    local typeRecord = record.typeRecord
    local borrowed = typeRecord.borrowed
    borrowed[record.version] = borrowed[record.version] - 1
    typeRecord.pool:Release(widget)
end

---Register a widget type, or replace an older version of it.
---@param name string
---@param constructor WidgetKit.Constructor
---@param version integer
---@param options WidgetKit.TypeOptions?
---@return boolean registered
---@return string? reason `"older"` or `"current"` when an equal or newer version is registered
local function registerType(self, name, constructor, version, options)
    validateFacade(self, "WidgetKit:RegisterType", 3)
    validateName(name, "WidgetKit:RegisterType name", 3)
    if type(constructor) ~= "function" then
        error("WidgetKit:RegisterType constructor must be a function", 2)
    end
    validatePositiveInteger(version, "WidgetKit:RegisterType version", 3)

    local ceiling = rawget(rawget(state, "limits"), "maxCreatedCeiling")
    local maxCreated = DEFAULT_MAX_CREATED
    local maxCallbacks = MAX_CALLBACKS
    if options ~= nil then
        validateOptionKeys(options, TYPE_OPTION_KEYS, "WidgetKit:RegisterType options", 3)
        if type(options.maxCreated) ~= "nil" then
            -- Before the sentinel comparison, which would raise on a secret.
            refuseSecret(options.maxCreated, "WidgetKit:RegisterType options.maxCreated", 3)
            if options.maxCreated == UNBOUNDED then
                error(
                    "WidgetKit:RegisterType options.maxCreated cannot be WidgetKit.UNBOUNDED:"
                        .. " the client never frees a frame",
                    2
                )
            end
            validatePositiveInteger(
                options.maxCreated,
                "WidgetKit:RegisterType options.maxCreated",
                3
            )
            if options.maxCreated > ceiling then
                error(
                    "WidgetKit:RegisterType options.maxCreated must be at most "
                        .. ceiling
                        .. " (WidgetKit:SetLimits maxCreatedCeiling)",
                    2
                )
            end
            maxCreated = options.maxCreated
        end
        if type(options.maxCallbacks) ~= "nil" then
            validateLimitOrUnbounded(
                options.maxCallbacks,
                "WidgetKit:RegisterType options.maxCallbacks",
                3
            )
            maxCallbacks = capacityOf(options.maxCallbacks)
        end
    end

    local typeRecord = types[name]
    if typeRecord ~= nil then
        if version < typeRecord.version then
            return false, "older"
        end
        if version == typeRecord.version then
            return false, "current"
        end

        -- A newer constructor: pooled widgets of older versions are retired
        -- now and borrowed ones when they are released. Retired frames still
        -- count against the cap, so the cap grows by what this upgrade uses
        -- up: the pooled widgets it retires and the borrowed widgets of the
        -- generation it replaces. Borrowed widgets of generations before that
        -- one were counted by the upgrade that replaced them. The cap never
        -- passes the `maxCreatedCeiling` limit in force.
        local previousVersion = typeRecord.version
        typeRecord.constructor = constructor
        typeRecord.version = version
        typeRecord.maxCallbacks = maxCallbacks
        local stale = typeRecord.borrowed[previousVersion] or 0
        local pool = typeRecord.pool ---@type table
        local retired = pool:SetGeneration(version)
        local cap = pool:GetMaxCreated()
        local wanted = cap + retired + stale
        if maxCreated > wanted then
            wanted = maxCreated
        end
        if wanted > ceiling then
            wanted = ceiling
        end
        if wanted > cap then
            pool:SetMaxCreated(wanted)
        end
        return true
    end

    typeRecord = {
        name = name,
        version = version,
        constructor = constructor,
        -- `math.huge` when registered with `maxCallbacks = WidgetKit.UNBOUNDED`.
        maxCallbacks = maxCallbacks,
        pool = nil,
        -- Type version -> widgets of that version currently borrowed.
        borrowed = {},
    }
    typeRecord.pool = PoolKit:New({
        create = function()
            return dispatch.build(typeRecord)
        end,
        destroy = function(widget)
            dispatch.retire(widget)
        end,
        maxCreated = maxCreated,
        generation = version,
    })
    types[name] = typeRecord
    return true
end

---@param name string
---@return integer? version
local function getTypeVersion(self, name)
    validateFacade(self, "WidgetKit:GetTypeVersion", 3)
    validateName(name, "WidgetKit:GetTypeVersion name", 3)
    local typeRecord = types[name]
    return typeRecord ~= nil and typeRecord.version or nil
end

---Acquire a widget of type `name`.
---@param name string
---@return WidgetKit.Widget|nil widget
---@return string? reason `"unknownType"` or `"exhausted"`
local function create(self, name)
    validateFacade(self, "WidgetKit:Create", 3)
    validateName(name, "WidgetKit:Create name", 3)
    local typeRecord = types[name]
    if typeRecord == nil then
        return nil, "unknownType"
    end

    local pool = typeRecord.pool
    local ok, widget, reason = pcall(pool.Acquire, pool)
    if not ok then
        local problem = rawget(state, "buildProblem")
        rawset(state, "buildProblem", nil)
        if problem ~= nil then
            error("WidgetKit:Create " .. problem, 2)
        end
        -- The constructor itself raised: its error is passed on unchanged.
        error(widget, 0)
    end
    if widget == nil then
        return nil, reason
    end

    -- `buildWidget` and `releaseWidget` leave every other field of the record
    -- at its default, so acquiring only marks it active and counts it.
    local record = records[widget]
    record.active = true
    local serial = (rawget(state, "serial") or 0) + 1
    rawset(state, "serial", serial)
    record.serial = serial
    local borrowed = typeRecord.borrowed
    borrowed[record.version] = (borrowed[record.version] or 0) + 1

    local onAcquire = rawget(widget, "OnAcquire")
    if onAcquire ~= nil then
        local acquired, failure = pcall(onAcquire, widget)
        if not acquired then
            releaseWidget(widget, record)
            error(failure, 0)
        end
    end
    widget.frame:Show()
    return widget
end

---Release `widget`: see `releaseWidget`.
---@param widget WidgetKit.Widget
---@return true
local function release(self, widget)
    validateFacade(self, "WidgetKit:Release", 3)
    local record = type(widget) == "table" and records[widget] or nil
    if record == nil then
        error("WidgetKit:Release widget must be a WidgetKit widget", 2)
    end
    if record.releasing then
        error("WidgetKit:Release widget is already being released", 2)
    end
    if not record.active then
        error("WidgetKit:Release widget was already released", 2)
    end
    releaseWidget(widget, record)
    return true
end

---Release this widget; the same as `WidgetKit:Release(widget)`.
---@return true
function WidgetBase:Release()
    local record = type(self) == "table" and records[self] or nil
    if record == nil then
        error("WidgetKit.Widget:Release must be called on a WidgetKit widget", 2)
    end
    if record.releasing then
        error("WidgetKit.Widget:Release widget is already being released", 2)
    end
    if not record.active then
        error("WidgetKit.Widget:Release widget was already released", 2)
    end
    releaseWidget(self, record)
    return true
end

---Release every child, last first. Lays nothing out.
---@return integer released
function ContainerBase:ReleaseChildren()
    local record = activeContainerRecord(self, "WidgetKit.Container:ReleaseChildren", 3)
    local children = record.children
    local released = 0
    for index = #children, 1, -1 do
        local child = children[index]
        local childRecord = child ~= nil and records[child] or nil
        if childRecord ~= nil and childRecord.active and not childRecord.releasing then
            releaseWidget(child, childRecord)
            released = released + 1
        end
        if children[index] == child then
            children[index] = nil
        end
    end
    return released
end

---@param value any
---@return boolean
local function isWidget(self, value)
    validateFacade(self, "WidgetKit:IsWidget", 3)
    local record = type(value) == "table" and records[value] or nil
    return record ~= nil and record.active == true
end

---Register a layout function under `name`. Names are taken for good: a layout
---other addons rely on cannot be replaced from outside.
---@param name string
---@param layout WidgetKit.Layout
---@return boolean registered
---@return string? reason `"taken"`
local function registerLayout(self, name, layout)
    validateFacade(self, "WidgetKit:RegisterLayout", 3)
    validateName(name, "WidgetKit:RegisterLayout name", 3)
    if type(layout) ~= "function" then
        error("WidgetKit:RegisterLayout layout must be a function", 2)
    end
    if layouts[name] ~= nil then
        return false, "taken"
    end
    layouts[name] = layout
    return true
end

---@param name string
---@return WidgetKit.Layout?
local function getLayout(self, name)
    validateFacade(self, "WidgetKit:GetLayout", 3)
    validateName(name, "WidgetKit:GetLayout name", 3)
    return layouts[name]
end

---Make `widget` the one focused widget, telling the previous one it lost focus.
---@param widget WidgetKit.Widget
---@return true
local function setFocus(self, widget)
    validateFacade(self, "WidgetKit:SetFocus", 3)
    activeRecord(widget, "WidgetKit:SetFocus", 3)
    local current = rawget(state, "focus")
    if current == widget then
        return true
    end
    if current ~= false then
        WidgetKit:ClearFocus()
    end
    rawset(state, "focus", widget)
    return true
end

---Clear the focus, calling the focused widget's `OnFocusLost` hook.
---@return boolean cleared `false` when nothing was focused
local function clearFocus(self)
    validateFacade(self, "WidgetKit:ClearFocus", 3)
    local current = rawget(state, "focus")
    if current == false then
        return false
    end
    rawset(state, "focus", false)
    callHook(current, "OnFocusLost")
    return true
end

---@return WidgetKit.Widget?
local function getFocus(self)
    validateFacade(self, "WidgetKit:GetFocus", 3)
    local current = rawget(state, "focus")
    if current == false then
        return nil
    end
    return current
end

---Counters per type and in total. Allocates a fresh table on every call.
---@return WidgetKit.Statistics
local function getStatistics(self)
    validateFacade(self, "WidgetKit:GetStatistics", 3)
    local statistics = {
        types = 0,
        created = 0,
        active = 0,
        available = 0,
        discarded = 0,
        byType = {},
    }
    for name, typeRecord in next, types do
        local pool = typeRecord.pool
        local row = {
            version = typeRecord.version,
            maxCreated = pool:GetMaxCreated(),
            created = pool:GetCreatedCount(),
            active = pool:GetActiveCount(),
            available = pool:GetAvailableCount(),
            discarded = pool:GetDiscardedCount(),
        }
        statistics.byType[name] = row
        statistics.types = statistics.types + 1
        statistics.created = statistics.created + row.created
        statistics.active = statistics.active + row.active
        statistics.available = statistics.available + row.available
        statistics.discarded = statistics.discarded + row.discarded
    end
    return statistics
end

---Change any subset of the package-wide limits: `maxCreatedCeiling` and
---`maxDropdownEntries`. Every entry is validated before anything changes;
---affects every consumer in the session. Caps already given to registered
---types, and lists already set, are kept.
---@param limits WidgetKit.Limits
local function setLimits(self, limits)
    validateFacade(self, "WidgetKit:SetLimits", 3)
    if type(limits) ~= "table" then
        error("WidgetKit:SetLimits limits must be a table", 2)
    end
    local key = next(limits)
    while key ~= nil do
        if key ~= "maxCreatedCeiling" and key ~= "maxDropdownEntries" then
            -- A key that is not a string, number or boolean is named by its
            -- type, so no `__tostring` of the caller's runs here.
            local kind = type(key)
            local keyText = "<" .. kind .. ">"
            if kind == "string" or kind == "number" or kind == "boolean" then
                keyText = tostring(key)
            end
            error("WidgetKit:SetLimits limits." .. keyText .. " is not a recognised limit", 2)
        end
        key = next(limits, key)
    end

    -- Every value is checked for a secret before it is compared with the
    -- sentinel or a bound: comparing a secret raises.

    -- `maxDropdownEntries`: a positive integer or `WidgetKit.UNBOUNDED`, since
    -- the entries are the consumer's own keys and labels, not frames.
    local dropdownEntries = rawget(limits, "maxDropdownEntries")
    if
        type(dropdownEntries) ~= "nil"
        and (
            isSecret(dropdownEntries)
            or (
                dropdownEntries ~= UNBOUNDED
                and (
                    type(dropdownEntries) ~= "number"
                    or dropdownEntries ~= dropdownEntries
                    or dropdownEntries < 1
                    or dropdownEntries == math.huge
                    or dropdownEntries ~= math.floor(dropdownEntries)
                )
            )
        )
    then
        error(
            "WidgetKit:SetLimits limits.maxDropdownEntries must be a positive integer"
                .. " or WidgetKit.UNBOUNDED",
            2
        )
    end
    local ceiling = rawget(limits, "maxCreatedCeiling")
    if type(ceiling) == "nil" then
        if type(dropdownEntries) ~= "nil" then
            rawset(rawget(state, "limits"), "maxDropdownEntries", dropdownEntries)
        end
        return
    end
    if not isSecret(ceiling) and ceiling == UNBOUNDED then
        error(
            "WidgetKit:SetLimits limits.maxCreatedCeiling cannot be WidgetKit.UNBOUNDED:"
                .. " the client never frees a frame",
            2
        )
    end
    if
        isSecret(ceiling)
        or type(ceiling) ~= "number"
        or ceiling ~= math.floor(ceiling)
        or ceiling < MAX_CREATED_CEILING.minimum
        or ceiling > MAX_CREATED_CEILING.maximum
    then
        error(
            "WidgetKit:SetLimits limits.maxCreatedCeiling must be an integer from "
                .. MAX_CREATED_CEILING.minimum
                .. " to "
                .. MAX_CREATED_CEILING.maximum,
            2
        )
    end
    rawset(rawget(state, "limits"), "maxCreatedCeiling", ceiling)
    if type(dropdownEntries) ~= "nil" then
        rawset(rawget(state, "limits"), "maxDropdownEntries", dropdownEntries)
    end
end

---Return a fresh copy of the package-wide limits.
---@return WidgetKit.Limits
local function getLimits(self)
    validateFacade(self, "WidgetKit:GetLimits", 3)
    return {
        maxCreatedCeiling = rawget(rawget(state, "limits"), "maxCreatedCeiling"),
        maxDropdownEntries = rawget(rawget(state, "limits"), "maxDropdownEntries"),
    }
end

-- Anchors --------------------------------------------------------------------
--
-- An anchor is a plain table `{ point, relativeTo, relativePoint, x, y, scale }`
-- that `SetPoint` can consume and a saved variable can hold. `relativeTo` is a
-- global frame name whenever the frame has one.

---Validate a rect and return its four numbers.
---@param rect any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return number left, number bottom, number width, number height
local function readRect(rect, label, level)
    if type(rect) ~= "table" then
        error(label .. " must be a table with left, bottom, width and height", level)
    end
    local left, bottom, width, height = rect.left, rect.bottom, rect.width, rect.height
    if
        type(left) ~= "number"
        or type(bottom) ~= "number"
        or type(width) ~= "number"
        or type(height) ~= "number"
    then
        error(label .. " must be a table with left, bottom, width and height", level)
    end
    return left, bottom, width, height
end

---Elect the point of the parent nearest to the same point of the rect and
---return the anchor that keeps the rect where it is.
---
---The distance compared is between a point of the rect and the same point of
---the parent, squared, so the centre, the four edge midpoints and the four
---corners compete on one scale. Equally near points go to the earlier one in
---`POINTS`. Pure: it reads only its arguments and allocates only the anchor,
---or nothing when `into` is given.
---@param rect WidgetKit.Rect
---@param parentRect WidgetKit.Rect
---@param into table? filled in place and returned
---@return WidgetKit.Anchor
local function anchorFromRect(rect, parentRect, into)
    local left, bottom, width, height = readRect(rect, "WidgetKit.Anchor.FromRect rect", 3)
    local parentLeft, parentBottom, parentWidth, parentHeight =
        readRect(parentRect, "WidgetKit.Anchor.FromRect parentRect", 3)
    if into ~= nil and type(into) ~= "table" then
        error("WidgetKit.Anchor.FromRect into must be a table or nil", 2)
    end

    local bestPoint, bestDistance, bestX, bestY = nil, nil, 0, 0
    for index = 1, #POINTS do
        local point = POINTS[index]
        local horizontal = POINT_HORIZONTAL[point]
        local vertical = POINT_VERTICAL[point]
        local offsetX = (left + width * horizontal) - (parentLeft + parentWidth * horizontal)
        local offsetY = (bottom + height * vertical) - (parentBottom + parentHeight * vertical)
        local distance = offsetX * offsetX + offsetY * offsetY
        if bestDistance == nil or distance < bestDistance then
            bestPoint, bestDistance, bestX, bestY = point, distance, offsetX, offsetY
        end
    end

    local anchor = into or {}
    anchor.point = bestPoint
    anchor.relativeTo = nil
    anchor.relativePoint = bestPoint
    anchor.x = bestX
    anchor.y = bestY
    anchor.scale = nil
    return anchor
end

---Validate a point name.
---@param point any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePoint(point, label, level)
    if isSecret(point) or type(point) ~= "string" or POINT_HORIZONTAL[point] == nil then
        error(label .. " must be one of the nine anchor points", level)
    end
end

---Validate a frame argument: a table with the methods an anchor needs.
---@param frame any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateAnchorFrame(frame, label, level)
    if
        type(frame) ~= "table"
        or type(frame.SetPoint) ~= "function"
        or type(frame.ClearAllPoints) ~= "function"
        or type(frame.GetPoint) ~= "function"
    then
        error(label .. " must be a frame", level)
    end
end

---The name to store for a relative frame, or the frame itself when unnamed.
---@param relative any
---@return string|table|nil
local function relativeName(relative)
    if type(relative) == "table" and type(relative.GetName) == "function" then
        local name = relative:GetName()
        if type(name) == "string" and not isSecret(name) and name ~= "" then
            return name
        end
    end
    return relative
end

---Turn any of the five `SetPoint` argument forms into an anchor, with the
---relative frame as its global name when it has one. `nil` as the relative
---frame means the frame's parent, as for `SetPoint`, and is resolved to it.
---@param frame WidgetKit.Frame
---@param point string
---@return WidgetKit.Anchor
local function anchorNormalize(frame, point, first, second, third, fourth)
    validateAnchorFrame(frame, "WidgetKit.Anchor.Normalize frame", 3)
    validatePoint(point, "WidgetKit.Anchor.Normalize point", 3)

    local relativeTo, relativePoint, x, y
    if first == nil then
        -- `(point)`, or the full form with the parent written as `nil`.
        if type(second) == "string" then
            relativeTo, relativePoint, x, y = nil, second, third or 0, fourth or 0
        else
            relativeTo, relativePoint, x, y = nil, point, 0, 0
        end
    elseif type(first) == "number" then
        relativeTo, relativePoint, x, y = nil, point, first, second or 0
    elseif type(second) == "number" then
        relativeTo, relativePoint, x, y = first, point, second, third or 0
    else
        relativeTo, relativePoint, x, y = first, second or point, third or 0, fourth or 0
    end

    validatePoint(relativePoint, "WidgetKit.Anchor.Normalize relativePoint", 3)
    validateNumber(x, "WidgetKit.Anchor.Normalize x", 3)
    validateNumber(y, "WidgetKit.Anchor.Normalize y", 3)
    if relativeTo ~= nil and type(relativeTo) ~= "table" and type(relativeTo) ~= "string" then
        error("WidgetKit.Anchor.Normalize relativeTo must be a frame, a frame name or nil", 2)
    end
    if relativeTo == nil and type(frame.GetParent) == "function" then
        relativeTo = frame:GetParent()
    end

    local scale = 1
    if type(frame.GetScale) == "function" then
        scale = frame:GetScale()
    end

    return {
        point = point,
        relativeTo = relativeName(relativeTo),
        relativePoint = relativePoint,
        x = x,
        y = y,
        scale = scale,
    }
end

---Read the fields of an anchor, which may be a saved-variable view.
---@param anchor any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return string point, any relativeTo, string relativePoint, number x, number y, number? scale
local function readAnchor(anchor, label, level)
    if type(anchor) ~= "table" then
        error(label .. " must be an anchor table", level)
    end
    local point = anchor.point
    validatePoint(point, label .. ".point", level + 1)
    local relativePoint = anchor.relativePoint
    if relativePoint == nil then
        relativePoint = point
    end
    validatePoint(relativePoint, label .. ".relativePoint", level + 1)
    local x, y = anchor.x or 0, anchor.y or 0
    validateNumber(x, label .. ".x", level + 1)
    validateNumber(y, label .. ".y", level + 1)
    local relativeTo = anchor.relativeTo
    if isSecret(relativeTo) then
        error(label .. ".relativeTo must not be a secret value", level)
    end
    if relativeTo ~= nil and type(relativeTo) ~= "string" and type(relativeTo) ~= "table" then
        error(label .. ".relativeTo must be a frame, a frame name or nil", level)
    end
    local scale = anchor.scale
    if scale ~= nil then
        validateNumber(scale, label .. ".scale", level + 1)
        if scale <= 0 then
            error(label .. ".scale must be above 0", level)
        end
    end
    return point, relativeTo, relativePoint, x, y, scale
end

---Anchor `frame` at `anchor`, replacing its anchors and applying its scale.
---A frame `IsForbidden` or `CanBeAccessedInContext` refuses is left alone.
---@param frame WidgetKit.Frame
---@param anchor WidgetKit.Anchor
---@return boolean applied
---@return string? reason `"forbidden"`, or `"unknownRelative"` when `relativeTo` names no frame
local function anchorApply(frame, anchor)
    validateAnchorFrame(frame, "WidgetKit.Anchor.Apply frame", 3)
    local point, relativeTo, relativePoint, x, y, scale =
        readAnchor(anchor, "WidgetKit.Anchor.Apply anchor", 3)
    if not canTouchFrame(frame) then
        return false, "forbidden"
    end
    if type(relativeTo) == "string" then
        local resolved = readGlobal(relativeTo)
        if type(resolved) ~= "table" then
            return false, "unknownRelative"
        end
        relativeTo = resolved
    end
    if scale ~= nil and type(frame.SetScale) == "function" then
        frame:SetScale(scale)
    end
    frame:ClearAllPoints()
    frame:SetPoint(point, relativeTo, relativePoint, x, y)
    return true
end

---The frame's first anchor, normalised; `nil` when it has none.
---@param frame WidgetKit.Frame
---@return WidgetKit.Anchor?
local function anchorRead(frame)
    validateAnchorFrame(frame, "WidgetKit.Anchor.Read frame", 3)
    local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
    if point == nil then
        return nil
    end
    return anchorNormalize(frame, point, relativeTo, relativePoint, x or 0, y or 0)
end

-- Position binding -----------------------------------------------------------

---A frame's rect in screen coordinates: its own rect times its effective
---scale. `nil` when the frame is not positioned.
---@param frame WidgetKit.Frame
---@return number? left, number bottom, number width, number height
local function screenRect(frame)
    local left, bottom, width, height = frame:GetRect()
    if left == nil then
        return nil, 0, 0, 0
    end
    local scale = 1
    if type(frame.GetEffectiveScale) == "function" then
        scale = frame:GetEffectiveScale()
    end
    return left * scale, bottom * scale, width * scale, height * scale
end

---Write the binding's current anchor into its storage table as a fresh plain
---table, so a SettingsKit view validates and stores it like any record.
---@param binding table
local function saveBinding(binding)
    local anchor = binding._anchor
    if anchor.point == nil then
        return
    end
    local relativeTo = anchor.relativeTo
    if type(relativeTo) ~= "string" then
        relativeTo = nil
    end
    binding._storage[binding._key] = {
        point = anchor.point,
        relativeTo = relativeTo,
        relativePoint = anchor.relativePoint,
        x = anchor.x,
        y = anchor.y,
        scale = anchor.scale,
    }
end

---@param binding any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateBinding(binding, methodName, level)
    if type(binding) ~= "table" or getmetatable(binding) ~= BINDING_METATABLE then
        error(methodName .. " must be called on a WidgetKit binding", level)
    end
end

---Build a binding. Shared by `WidgetKit:BindPosition` and the `Frame`
---widget's `BindPosition`, so both report argument errors at their caller.
---@param frame WidgetKit.Frame
---@param storageTable any
---@param options any
---@param methodName string qualified public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return WidgetKit.Binding
local function newBinding(frame, storageTable, options, methodName, level)
    validateAnchorFrame(frame, methodName .. " frame", level + 1)
    if type(frame.GetRect) ~= "function" then
        error(methodName .. " frame must be a frame", level)
    end
    if type(storageTable) ~= "table" then
        error(methodName .. " storageTable must be a table", level)
    end

    local key, delay, restore = "anchor", DEFAULT_SAVE_DELAY, true
    if options ~= nil then
        validateOptionKeys(options, BINDING_OPTION_KEYS, methodName .. " options", level + 1)
        if options.key ~= nil then
            validateName(options.key, methodName .. " options.key", level + 1)
            key = options.key
        end
        if options.delay ~= nil then
            validateNumber(options.delay, methodName .. " options.delay", level + 1)
            if options.delay < 0 then
                error(methodName .. " options.delay must not be negative", level)
            end
            delay = options.delay
        end
        if options.restore ~= nil then
            if type(options.restore) ~= "boolean" then
                error(methodName .. " options.restore must be a boolean", level)
            end
            restore = options.restore
        end
    end

    local binding = setmetatable({
        _frame = frame,
        _storage = storageTable,
        _key = key,
        _anchor = {},
        _signal = SignalKit:New(),
        _debounce = nil,
        _released = false,
    }, BINDING_METATABLE)

    -- SchedulerKit, when an addon embeds it, coalesces a burst of moves into
    -- one save. Without it every capture saves at once.
    local SchedulerKit = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API)
    if type(SchedulerKit) == "table" and type(SchedulerKit.Debounce) == "function" then
        binding._debounce = SchedulerKit:Debounce(function()
            saveBinding(binding)
        end, delay)
    end

    if restore then
        BindingPrototype.Restore(binding)
    end
    return binding
end

---Bind `frame`'s position to `storageTable[options.key or "anchor"]`.
---@param frame WidgetKit.Frame
---@param storageTable table a plain table or a SettingsKit scope view
---@param options WidgetKit.BindingOptions?
---@return WidgetKit.Binding
local function bindPosition(self, frame, storageTable, options)
    validateFacade(self, "WidgetKit:BindPosition", 3)
    return newBinding(frame, storageTable, options, "WidgetKit:BindPosition", 3)
end

---Read the frame's position, re-anchor it at the nearest point of its parent,
---save that anchor (debounced when SchedulerKit is present) and fire
---`OnMoved(binding, anchor)`.
---@return WidgetKit.Anchor|nil anchor the binding's own anchor table; copy what you keep
---@return string? reason `"released"`, `"forbidden"` or `"notPositioned"`
function BindingPrototype:Capture()
    validateBinding(self, "WidgetKit.Binding:Capture", 3)
    if self._released then
        return nil, "released"
    end

    local frame = self._frame
    if not canTouchFrame(frame) then
        return nil, "forbidden"
    end
    local left, bottom, width, height = screenRect(frame)
    if left == nil then
        return nil, "notPositioned"
    end
    local parent = type(frame.GetParent) == "function" and frame:GetParent() or nil
    if parent == nil then
        parent = restingParent()
    end
    if type(parent) ~= "table" or type(parent.GetRect) ~= "function" then
        return nil, "notPositioned"
    end
    local parentLeft, parentBottom, parentWidth, parentHeight = screenRect(parent)
    if parentLeft == nil then
        return nil, "notPositioned"
    end

    -- `FromRect` reads plain rect fields; reuse two tables kept on the binding.
    local rect = self._rect
    if rect == nil then
        rect = {}
        self._rect = rect
        self._parentRect = {}
    end
    local parentRect = self._parentRect
    rect.left, rect.bottom, rect.width, rect.height = left, bottom, width, height
    parentRect.left, parentRect.bottom = parentLeft, parentBottom
    parentRect.width, parentRect.height = parentWidth, parentHeight

    local anchor = anchorFromRect(rect, parentRect, self._anchor)
    local scale = type(frame.GetEffectiveScale) == "function" and frame:GetEffectiveScale() or 1
    anchor.x = anchor.x / scale
    anchor.y = anchor.y / scale
    anchor.relativeTo = relativeName(parent)
    anchor.scale = type(frame.GetScale) == "function" and frame:GetScale() or 1

    frame:ClearAllPoints()
    frame:SetPoint(anchor.point, parent, anchor.relativePoint, anchor.x, anchor.y)

    local debounce = self._debounce
    if debounce ~= nil then
        debounce()
    else
        saveBinding(self)
    end
    self._signal:Fire(self, anchor)
    return anchor
end

---Apply the saved anchor, when the storage table holds a valid one.
---@return boolean restored
function BindingPrototype:Restore()
    validateBinding(self, "WidgetKit.Binding:Restore", 3)
    if self._released then
        return false
    end
    local saved = self._storage[self._key]
    if type(saved) ~= "table" or not canTouchFrame(self._frame) then
        return false
    end
    local ok, applied = pcall(anchorApply, self._frame, saved)
    if not ok then
        -- A saved anchor this copy cannot read is reported, never raised:
        -- the frame keeps the position it had.
        reportError(applied)
        return false
    end
    if applied then
        local anchor = self._anchor
        anchor.point = saved.point
        anchor.relativeTo = saved.relativeTo
        anchor.relativePoint = saved.relativePoint or saved.point
        anchor.x = saved.x or 0
        anchor.y = saved.y or 0
        anchor.scale = saved.scale
    end
    return applied == true
end

---Save a debounced anchor now.
---@return boolean saved `false` when nothing was pending
function BindingPrototype:Flush()
    validateBinding(self, "WidgetKit.Binding:Flush", 3)
    local debounce = self._debounce
    if debounce == nil or self._released then
        return false
    end
    return debounce:Flush() == true
end

---Connect `callback(binding, anchor)` to every capture.
---@param callback fun(binding: WidgetKit.Binding, anchor: WidgetKit.Anchor)
---@return table connection a SignalKit connection
function BindingPrototype:OnMoved(callback)
    validateBinding(self, "WidgetKit.Binding:OnMoved", 3)
    if type(callback) ~= "function" then
        error("WidgetKit.Binding:OnMoved callback must be a function", 2)
    end
    if self._released then
        error("WidgetKit.Binding:OnMoved cannot be called on a released binding", 2)
    end
    return self._signal:Connect(callback)
end

---Save what is pending, stop listening and forget the frame.
---@return boolean released `false` when it was already released
function BindingPrototype:Release()
    validateBinding(self, "WidgetKit.Binding:Release", 3)
    if self._released then
        return false
    end
    local debounce = self._debounce
    if debounce ~= nil then
        debounce:Flush()
        debounce:Close()
        self._debounce = nil
    end
    self._signal:DisconnectAll()
    self._released = true
    return true
end

---@return boolean
function BindingPrototype:IsReleased()
    validateBinding(self, "WidgetKit.Binding:IsReleased", 3)
    return self._released == true
end

-- Widget helpers -------------------------------------------------------------
--
-- The base widgets below follow the author contract in `docs/API.md` like any
-- other widget type: a constructor that builds frames once, `OnAcquire` that
-- sets every default, `OnRelease` that clears every text and texture, and
-- methods stored on the widget table. Methods are shared functions defined
-- once here; script handlers are closures made once per widget, at
-- construction, because the widget is pooled for the session.

-- Colours a widget draws its text and chrome in.
local LABEL_RED, LABEL_GREEN, LABEL_BLUE = 1, 0.82, 0
local TEXT_RED, TEXT_GREEN, TEXT_BLUE = 1, 1, 1
local DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE = 0.5, 0.5, 0.5

---Check the text a widget is asked to display.
---
---`nil` clears; a string or number is shown; a secret value is refused unless
---`options.allowSecret` is `true`. A font string can display a secret, but
---whether one should appear is the caller's decision (`docs/EMBEDDING.md`).
---@param text any
---@param options any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return string|number text
---@return boolean secret
local function checkText(text, options, methodName, level)
    local allowSecret = false
    if options ~= nil then
        validateOptionKeys(options, TEXT_OPTION_KEYS, methodName .. " options", level + 1)
        allowSecret = options.allowSecret == true
    end
    if isSecret(text) then
        if not allowSecret then
            error(
                methodName .. " text must not be a secret value unless options.allowSecret is true",
                level
            )
        end
        return text, true
    end
    if text == nil then
        return "", false
    end
    local kind = type(text)
    if kind ~= "string" and kind ~= "number" then
        error(methodName .. " text must be a string, a number or nil", level)
    end
    return text, false
end

---Whether `widget` is still an active widget; script handlers check this
---before they act, since a host script can outlive a release by a frame.
---@param widget table
---@return boolean
local function isActive(widget)
    local record = records[widget]
    return record ~= nil and record.active == true
end

---@param frame WidgetKit.Frame
---@param shown boolean
local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

---Validate a `SetDisabled` argument.
---@param widget any
---@param disabled any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean disabled
local function readDisabled(widget, disabled, methodName, level)
    activeRecord(widget, methodName, level + 1)
    if disabled ~= nil and type(disabled) ~= "boolean" then
        error(methodName .. " disabled must be a boolean", level)
    end
    return disabled == true
end

---Colour a label font string for the enabled or disabled state.
---@param fontString WidgetKit.Frame
---@param disabled boolean
local function colourLabel(fontString, disabled)
    if disabled then
        fontString:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
    else
        fontString:SetTextColor(LABEL_RED, LABEL_GREEN, LABEL_BLUE)
    end
end

---Build a label font string at the top of `frame`.
---@param frame WidgetKit.Frame
---@return WidgetKit.Frame fontString
local function newTopLabel(frame)
    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetFontObject("GameFontNormalSmall")
    label:SetJustifyH("LEFT")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    label:SetHeight(18)
    return label
end

---A `SetLabel` shared by the widgets whose label is `widget.labelText`.
---@param text any
---@param options WidgetKit.TextOptions?
local function setWidgetLabel(self, text, options)
    activeRecord(self, "WidgetKit.Widget:SetLabel", 3)
    local value = checkText(text, options, "WidgetKit.Widget:SetLabel", 3)
    self.labelText:SetText(value)
end

---A `GetLabel` shared by the same widgets.
---@return any
local function getWidgetLabel(self)
    activeRecord(self, "WidgetKit.Widget:GetLabel", 3)
    return self.labelText:GetText()
end

-- The base widget constructors, each defined in its own `do` block below so
-- that the helpers of one widget are not visible to the others.
local constructWindow, constructGroup, constructScrollFrame, constructLabel, constructButton, constructCheckBox, constructSlider, constructEditBox, constructDropdown, constructColorPicker, constructHeading, constructSpacer

-- Widget: Frame --------------------------------------------------------------

do
    local WINDOW_WIDTH, WINDOW_HEIGHT = 700, 500
    local WINDOW_TITLE_HEIGHT = 24
    local WINDOW_INSET = 12

    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function windowSetTitle(self, text, options)
        activeRecord(self, "WidgetKit Frame:SetTitle", 3)
        self.titleText:SetText(checkText(text, options, "WidgetKit Frame:SetTitle", 3))
    end

    ---@return any
    local function windowGetTitle(self)
        activeRecord(self, "WidgetKit Frame:GetTitle", 3)
        return self.titleText:GetText()
    end

    ---@param resizable boolean
    local function windowSetResizable(self, resizable)
        activeRecord(self, "WidgetKit Frame:SetResizable", 3)
        if type(resizable) ~= "boolean" then
            error("WidgetKit Frame:SetResizable resizable must be a boolean", 2)
        end
        self.frame:SetResizable(resizable)
        setShown(self.sizer, resizable)
    end

    ---@param movable boolean
    local function windowSetMovable(self, movable)
        activeRecord(self, "WidgetKit Frame:SetMovable", 3)
        if type(movable) ~= "boolean" then
            error("WidgetKit Frame:SetMovable movable must be a boolean", 2)
        end
        self.frame:SetMovable(movable)
    end

    ---Bind the window's position, replacing a binding it already had. The binding
    ---is released with the window.
    ---@param storageTable table
    ---@param options WidgetKit.BindingOptions?
    ---@return WidgetKit.Binding
    local function windowBindPosition(self, storageTable, options)
        activeRecord(self, "WidgetKit Frame:BindPosition", 3)
        local binding =
            newBinding(self.frame, storageTable, options, "WidgetKit Frame:BindPosition", 3)
        local previous = self._binding
        if previous ~= nil then
            previous:Release()
        end
        self._binding = binding
        return binding
    end

    ---@return WidgetKit.Binding?
    local function windowGetBinding(self)
        activeRecord(self, "WidgetKit Frame:GetBinding", 3)
        return self._binding
    end

    local function windowOnAcquire(self)
        local frame = self.frame
        -- A restored anchor applies its saved scale to the frame; the next
        -- use of the window starts at the default one.
        frame:SetScale(1)
        frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:SetResizable(true)
        self.sizer:Show()
        self.titleText:SetText("")
    end

    local function windowOnRelease(self)
        local binding = self._binding
        if binding ~= nil then
            binding:Release()
            self._binding = nil
        end
        self.titleText:SetText("")
        local frame = self.frame
        frame:StopMovingOrSizing()
    end

    ---@return table widget
    function constructWindow()
        local frame = createFrame("Frame", releaseParent())
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:SetClampedToScreen(true)
        frame:EnableMouse(true)
        if type(frame.SetResizeBounds) == "function" then
            frame:SetResizeBounds(240, 160)
        end

        local background = frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(frame)
        background:SetColorTexture(0.05, 0.05, 0.05, 0.92)

        local titleBar = createFrame("Frame", frame)
        titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WINDOW_TITLE_HEIGHT, 0)
        titleBar:SetHeight(WINDOW_TITLE_HEIGHT)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")

        local titleText = titleBar:CreateFontString(nil, "OVERLAY")
        titleText:SetFontObject("GameFontNormal")
        titleText:SetJustifyH("LEFT")
        titleText:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
        titleText:SetPoint("RIGHT", titleBar, "RIGHT", -8, 0)

        local close = createFrame("Button", frame, "UIPanelCloseButton")
        close:SetSize(WINDOW_TITLE_HEIGHT, WINDOW_TITLE_HEIGHT)
        close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

        local sizer = createFrame("Button", frame)
        sizer:SetSize(16, 16)
        sizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        sizer:EnableMouse(true)
        local grip = sizer:CreateTexture(nil, "OVERLAY")
        grip:SetAllPoints(sizer)
        grip:SetColorTexture(0.6, 0.6, 0.6, 0.5)

        local content = createFrame("Frame", frame)
        content:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_INSET, -(WINDOW_TITLE_HEIGHT + 8))
        content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -WINDOW_INSET, WINDOW_INSET)

        local widget = {
            frame = frame,
            content = content,
            titleBar = titleBar,
            titleText = titleText,
            closeButton = close,
            sizer = sizer,
            OnAcquire = windowOnAcquire,
            OnRelease = windowOnRelease,
            SetTitle = windowSetTitle,
            GetTitle = windowGetTitle,
            SetResizable = windowSetResizable,
            SetMovable = windowSetMovable,
            BindPosition = windowBindPosition,
            GetBinding = windowGetBinding,
        }

        titleBar:SetScript("OnDragStart", function()
            if isActive(widget) and frame:IsMovable() then
                frame:StartMoving()
            end
        end)
        titleBar:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            if not isActive(widget) then
                return
            end
            local binding = widget._binding
            if binding ~= nil then
                binding:Capture()
            end
            widget:Fire("OnMoved")
        end)
        close:SetScript("OnClick", function()
            if not isActive(widget) then
                return
            end
            frame:Hide()
            widget:Fire("OnClose")
        end)
        sizer:SetScript("OnMouseDown", function()
            if isActive(widget) and frame:IsResizable() then
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)
        sizer:SetScript("OnMouseUp", function()
            frame:StopMovingOrSizing()
            if not isActive(widget) then
                return
            end
            -- Layout is explicit: a finished resize is the moment to run it.
            widget:PerformLayout()
            widget:Fire("OnResize", frame:GetWidth(), frame:GetHeight())
        end)
        return widget
    end
end

-- Widget: Group --------------------------------------------------------------

do
    local GROUP_INSET = 8
    local GROUP_TITLE_HEIGHT = 18

    ---Anchor the content frame below the title, or at the top without one.
    ---@param widget table
    local function groupPlaceContent(widget)
        local title = widget.titleText:GetText()
        local hasTitle = title ~= nil and (isSecret(title) or title ~= "")
        local top = hasTitle and (GROUP_TITLE_HEIGHT + GROUP_INSET) or GROUP_INSET
        widget._topInset = top
        local content = widget.content
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT", widget.frame, "TOPLEFT", GROUP_INSET, -top)
        content:SetPoint("BOTTOMRIGHT", widget.frame, "BOTTOMRIGHT", -GROUP_INSET, GROUP_INSET)
    end

    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function groupSetTitle(self, text, options)
        activeRecord(self, "WidgetKit Group:SetTitle", 3)
        self.titleText:SetText(checkText(text, options, "WidgetKit Group:SetTitle", 3))
        groupPlaceContent(self)
    end

    ---@return any
    local function groupGetTitle(self)
        activeRecord(self, "WidgetKit Group:GetTitle", 3)
        return self.titleText:GetText()
    end

    ---@param disabled boolean? `true` greys the text out; the widget takes no input
    local function groupSetDisabled(self, disabled)
        colourLabel(self.titleText, readDisabled(self, disabled, "WidgetKit Group:SetDisabled", 3))
    end

    ---A group grows to its content unless it is full height.
    local function groupOnLayoutFinished(self, _, height)
        local record = records[self]
        if record.fullHeight then
            return
        end
        self.frame:SetHeight((height or 0) + self._topInset + GROUP_INSET)
    end

    local function groupOnAcquire(self)
        self.frame:SetSize(300, 2 * GROUP_INSET)
        self.titleText:SetText("")
        colourLabel(self.titleText, false)
        groupPlaceContent(self)
    end

    local function groupOnRelease(self)
        self.titleText:SetText("")
    end

    ---@return table widget
    function constructGroup()
        local frame = createFrame("Frame", releaseParent())
        local background = frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(frame)
        background:SetColorTexture(0.1, 0.1, 0.1, 0.5)

        local titleText = frame:CreateFontString(nil, "OVERLAY")
        titleText:SetFontObject("GameFontNormal")
        titleText:SetJustifyH("LEFT")
        titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", GROUP_INSET, -4)
        titleText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -GROUP_INSET, -4)
        titleText:SetHeight(GROUP_TITLE_HEIGHT)

        local content = createFrame("Frame", frame)

        return {
            frame = frame,
            content = content,
            titleText = titleText,
            _topInset = GROUP_INSET,
            OnAcquire = groupOnAcquire,
            OnRelease = groupOnRelease,
            OnLayoutFinished = groupOnLayoutFinished,
            SetTitle = groupSetTitle,
            GetTitle = groupGetTitle,
            SetDisabled = groupSetDisabled,
        }
    end
end

-- Widget: ScrollFrame --------------------------------------------------------

do
    local SCROLLBAR_WIDTH = 16
    local SCROLL_STEP = 40

    ---@return number
    local function scrollGetContentHeight(self)
        activeRecord(self, "WidgetKit ScrollFrame:GetContentHeight", 3)
        return self._contentHeight
    end

    ---@return number
    local function scrollGetScrollRange(self)
        activeRecord(self, "WidgetKit ScrollFrame:GetScrollRange", 3)
        return self._range
    end

    ---@return number
    local function scrollGetScroll(self)
        activeRecord(self, "WidgetKit ScrollFrame:GetScroll", 3)
        return self.scroll:GetVerticalScroll()
    end

    ---Scroll to `offset`, clamped to the range.
    ---@param offset number
    local function scrollSetScroll(self, offset)
        activeRecord(self, "WidgetKit ScrollFrame:SetScroll", 3)
        validateNumber(offset, "WidgetKit ScrollFrame:SetScroll offset", 3)
        if offset < 0 then
            offset = 0
        elseif offset > self._range then
            offset = self._range
        end
        self.scroll:SetVerticalScroll(offset)
        self.scrollbar:SetValue(offset)
    end

    ---The scroll child has no anchors, so its width is set before each pass.
    local function scrollOnLayoutStart(self)
        self.content:SetWidth(self.scroll:GetWidth())
    end

    ---Size the scroll child to what the layout used and update the scrollbar.
    local function scrollOnLayoutFinished(self, _, height)
        height = height or 0
        self._contentHeight = height
        self.content:SetHeight(height)
        local range = height - self.scroll:GetHeight()
        if range < 0 then
            range = 0
        end
        self._range = range
        local scrollbar = self.scrollbar
        scrollbar:SetMinMaxValues(0, range)
        setShown(scrollbar, range > 0)
        local offset = self.scroll:GetVerticalScroll()
        if offset > range then
            self.scroll:SetVerticalScroll(range)
        end
    end

    local function scrollOnAcquire(self)
        self.frame:SetSize(300, 200)
        self._contentHeight = 0
        self._range = 0
        self.scroll:SetVerticalScroll(0)
        self.scrollbar:SetMinMaxValues(0, 0)
        self.scrollbar:SetValue(0)
        self.scrollbar:Hide()
    end

    ---@return table widget
    function constructScrollFrame()
        local frame = createFrame("Frame", releaseParent())

        local scroll = createFrame("ScrollFrame", frame)
        scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(SCROLLBAR_WIDTH + 4), 0)
        scroll:EnableMouseWheel(true)

        local content = createFrame("Frame", scroll)
        scroll:SetScrollChild(content)

        local scrollbar = createFrame("Slider", frame)
        scrollbar:SetOrientation("VERTICAL")
        scrollbar:SetWidth(SCROLLBAR_WIDTH)
        scrollbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        scrollbar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        scrollbar:SetValueStep(1)
        local track = scrollbar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints(scrollbar)
        track:SetColorTexture(0, 0, 0, 0.4)
        local thumb = scrollbar:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(0.5, 0.5, 0.5, 0.9)
        thumb:SetSize(SCROLLBAR_WIDTH - 4, 24)
        scrollbar:SetThumbTexture(thumb)

        local widget = {
            frame = frame,
            content = content,
            scroll = scroll,
            scrollbar = scrollbar,
            _contentHeight = 0,
            _range = 0,
            OnAcquire = scrollOnAcquire,
            OnLayoutStart = scrollOnLayoutStart,
            OnLayoutFinished = scrollOnLayoutFinished,
            GetContentHeight = scrollGetContentHeight,
            GetScrollRange = scrollGetScrollRange,
            GetScroll = scrollGetScroll,
            SetScroll = scrollSetScroll,
        }

        scrollbar:SetScript("OnValueChanged", function(_, value)
            scroll:SetVerticalScroll(value)
        end)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            if isActive(widget) then
                widget:SetScroll(scroll:GetVerticalScroll() - delta * SCROLL_STEP)
            end
        end)
        return widget
    end
end

-- Widget: Label --------------------------------------------------------------

do
    -- One line of the default fonts, used where a text height cannot be measured.
    local LINE_HEIGHT = 12

    ---Size the label to its text. A secret text is not measured: the measurement
    ---of a secret string may itself be secret.
    ---@param widget table
    local function labelUpdateHeight(widget)
        local height
        if widget._secret then
            height = LINE_HEIGHT
        else
            height = widget.text:GetStringHeight()
        end
        widget.frame:SetHeight(height)
    end

    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function labelSetText(self, text, options)
        activeRecord(self, "WidgetKit Label:SetText", 3)
        local value, secret = checkText(text, options, "WidgetKit Label:SetText", 3)
        self._secret = secret
        self.text:SetText(value)
        labelUpdateHeight(self)
    end

    ---@return any
    local function labelGetText(self)
        activeRecord(self, "WidgetKit Label:GetText", 3)
        return self.text:GetText()
    end

    ---@param fontObject any a font object or its global name
    local function labelSetFontObject(self, fontObject)
        activeRecord(self, "WidgetKit Label:SetFontObject", 3)
        if type(fontObject) ~= "string" and type(fontObject) ~= "table" then
            error("WidgetKit Label:SetFontObject fontObject must be a font object or its name", 2)
        end
        self.text:SetFontObject(fontObject)
        labelUpdateHeight(self)
    end

    ---@param red number
    ---@param green number
    ---@param blue number
    ---@param alpha number?
    local function labelSetColor(self, red, green, blue, alpha)
        activeRecord(self, "WidgetKit Label:SetColor", 3)
        validateNumber(red, "WidgetKit Label:SetColor red", 3)
        validateNumber(green, "WidgetKit Label:SetColor green", 3)
        validateNumber(blue, "WidgetKit Label:SetColor blue", 3)
        if type(alpha) ~= "nil" then
            validateNumber(alpha, "WidgetKit Label:SetColor alpha", 3)
        end
        self._red, self._green, self._blue, self._alpha = red, green, blue, alpha or 1
        if not self._disabled then
            self.text:SetTextColor(red, green, blue, alpha or 1)
        end
    end

    ---@param justify string `"LEFT"`, `"CENTER"` or `"RIGHT"`
    local function labelSetJustifyH(self, justify)
        activeRecord(self, "WidgetKit Label:SetJustifyH", 3)
        refuseSecret(justify, "WidgetKit Label:SetJustifyH justify", 3)
        if justify ~= "LEFT" and justify ~= "CENTER" and justify ~= "RIGHT" then
            error('WidgetKit Label:SetJustifyH justify must be "LEFT", "CENTER" or "RIGHT"', 2)
        end
        self.text:SetJustifyH(justify)
    end

    ---@param disabled boolean? `true` greys the text out; the widget takes no input
    local function labelSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit Label:SetDisabled", 3)
        self._disabled = disabled
        if disabled then
            self.text:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE, 1)
        else
            self.text:SetTextColor(self._red, self._green, self._blue, self._alpha)
        end
    end

    local function labelOnWidthSet(self)
        labelUpdateHeight(self)
    end

    local function labelOnAcquire(self)
        self.frame:SetWidth(200)
        self._secret = false
        self._disabled = false
        self._red, self._green, self._blue, self._alpha = TEXT_RED, TEXT_GREEN, TEXT_BLUE, 1
        self.text:SetFontObject("GameFontHighlightSmall")
        self.text:SetJustifyH("LEFT")
        self.text:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE, 1)
        self.text:SetText("")
        labelUpdateHeight(self)
    end

    ---Clear the text, so a pooled font string never carries a secret into its
    ---next use.
    local function labelOnRelease(self)
        self.text:SetText("")
        self._secret = false
    end

    ---@return table widget
    function constructLabel()
        local frame = createFrame("Frame", releaseParent())
        local text = frame:CreateFontString(nil, "OVERLAY")
        text:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        text:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        text:SetWordWrap(true)
        return {
            frame = frame,
            text = text,
            _secret = false,
            _disabled = false,
            _red = TEXT_RED,
            _green = TEXT_GREEN,
            _blue = TEXT_BLUE,
            _alpha = 1,
            OnAcquire = labelOnAcquire,
            OnRelease = labelOnRelease,
            OnWidthSet = labelOnWidthSet,
            SetText = labelSetText,
            GetText = labelGetText,
            SetFontObject = labelSetFontObject,
            SetColor = labelSetColor,
            SetJustifyH = labelSetJustifyH,
            SetDisabled = labelSetDisabled,
        }
    end
end

-- Widget: Button -------------------------------------------------------------

do
    -- Keys the client reports while a modifier alone is held; a key capture waits
    -- for the key that comes with them.
    local MODIFIER_KEYS = {
        LSHIFT = true,
        RSHIFT = true,
        LCTRL = true,
        RCTRL = true,
        LALT = true,
        RALT = true,
        LMETA = true,
        RMETA = true,
        UNKNOWN = true,
    }

    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function buttonSetText(self, text, options)
        activeRecord(self, "WidgetKit Button:SetText", 3)
        self.frame:SetText(checkText(text, options, "WidgetKit Button:SetText", 3))
    end

    ---@return any
    local function buttonGetText(self)
        activeRecord(self, "WidgetKit Button:GetText", 3)
        return self.frame:GetText()
    end

    ---Leave key-capture mode without firing anything.
    ---@param widget table
    local function buttonStopCapture(widget)
        if widget._capturing then
            widget._capturing = false
            widget.frame:EnableKeyboard(false)
            widget.frame:UnlockHighlight()
        end
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function buttonSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit Button:SetDisabled", 3)
        if disabled then
            buttonStopCapture(self)
        end
        self.frame:SetEnabled(not disabled)
    end

    ---Turn key capture on or off. With it on, a left click starts listening for
    ---one key (with its modifiers), `ESCAPE` cancels, and a right click fires
    ---`OnKeyCaptured` with `""` to unbind.
    ---@param enabled boolean
    local function buttonSetKeyCapture(self, enabled)
        activeRecord(self, "WidgetKit Button:SetKeyCapture", 3)
        if type(enabled) ~= "boolean" then
            error("WidgetKit Button:SetKeyCapture enabled must be a boolean", 2)
        end
        self._captureEnabled = enabled
        if not enabled then
            buttonStopCapture(self)
        end
    end

    ---@return boolean
    local function buttonIsCapturing(self)
        activeRecord(self, "WidgetKit Button:IsCapturing", 3)
        return self._capturing == true
    end

    ---The binding string for `key` with the modifiers held now.
    ---@param key string
    ---@return string
    local function keyWithModifiers(key)
        local prefix = ""
        local isAltKeyDown = readGlobal("IsAltKeyDown")
        local isControlKeyDown = readGlobal("IsControlKeyDown")
        local isShiftKeyDown = readGlobal("IsShiftKeyDown")
        if type(isAltKeyDown) == "function" and isAltKeyDown() then
            prefix = prefix .. "ALT-"
        end
        if type(isControlKeyDown) == "function" and isControlKeyDown() then
            prefix = prefix .. "CTRL-"
        end
        if type(isShiftKeyDown) == "function" and isShiftKeyDown() then
            prefix = prefix .. "SHIFT-"
        end
        return prefix .. key
    end

    local function buttonOnAcquire(self)
        local frame = self.frame
        frame:SetSize(200, 24)
        frame:SetText("")
        frame:SetEnabled(true)
        self._captureEnabled = false
        self._capturing = false
        frame:EnableKeyboard(false)
    end

    local function buttonOnRelease(self)
        buttonStopCapture(self)
        self._captureEnabled = false
        self.frame:SetText("")
    end

    ---@return table widget
    function constructButton()
        local frame = createFrame("Button", releaseParent(), "UIPanelButtonTemplate")
        frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local widget = {
            frame = frame,
            _captureEnabled = false,
            _capturing = false,
            OnAcquire = buttonOnAcquire,
            OnRelease = buttonOnRelease,
            SetText = buttonSetText,
            GetText = buttonGetText,
            SetDisabled = buttonSetDisabled,
            SetKeyCapture = buttonSetKeyCapture,
            IsCapturing = buttonIsCapturing,
        }

        frame:SetScript("OnClick", function(_, mouseButton)
            if not isActive(widget) then
                return
            end
            if widget._captureEnabled then
                if mouseButton == "RightButton" then
                    buttonStopCapture(widget)
                    widget:Fire("OnKeyCaptured", "")
                    return
                end
                if not widget._capturing then
                    widget._capturing = true
                    frame:EnableKeyboard(true)
                    frame:LockHighlight()
                end
                return
            end
            widget:Fire("OnClick", mouseButton)
        end)
        frame:SetScript("OnKeyDown", function(_, key)
            if not widget._capturing or not isActive(widget) then
                return
            end
            if MODIFIER_KEYS[key] then
                return
            end
            buttonStopCapture(widget)
            if key == "ESCAPE" then
                widget:Fire("OnKeyCaptureCancelled")
                return
            end
            widget:Fire("OnKeyCaptured", keyWithModifiers(key))
        end)
        return widget
    end
end

-- Widget: CheckBox -----------------------------------------------------------

do
    ---Show `value` on the check button: checked, unchecked, or the third state.
    ---@param widget table
    local function checkBoxShowValue(widget)
        local value = widget._value
        widget.button:SetChecked(value == true)
        setShown(widget.indeterminate, value == nil and widget._triState)
    end

    ---@param value boolean? `nil` is the third state, and means `false` without it
    local function checkBoxSetValue(self, value)
        activeRecord(self, "WidgetKit CheckBox:SetValue", 3)
        refuseSecret(value, "WidgetKit CheckBox:SetValue value", 3)
        if value ~= nil and type(value) ~= "boolean" then
            error("WidgetKit CheckBox:SetValue value must be a boolean or nil", 2)
        end
        if value == nil and not self._triState then
            value = false
        end
        self._value = value
        checkBoxShowValue(self)
    end

    ---@return boolean?
    local function checkBoxGetValue(self)
        activeRecord(self, "WidgetKit CheckBox:GetValue", 3)
        return self._value
    end

    ---@param enabled boolean
    local function checkBoxSetTriState(self, enabled)
        activeRecord(self, "WidgetKit CheckBox:SetTriState", 3)
        if type(enabled) ~= "boolean" then
            error("WidgetKit CheckBox:SetTriState enabled must be a boolean", 2)
        end
        self._triState = enabled
        if not enabled and self._value == nil then
            self._value = false
        end
        checkBoxShowValue(self)
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function checkBoxSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit CheckBox:SetDisabled", 3)
        self.button:SetEnabled(not disabled)
        if disabled then
            self.labelText:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
        else
            self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
        end
    end

    local function checkBoxOnAcquire(self)
        self.frame:SetSize(200, 24)
        self._value = false
        self._triState = false
        self.button:SetEnabled(true)
        self.labelText:SetText("")
        self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
        checkBoxShowValue(self)
    end

    local function checkBoxOnRelease(self)
        self.labelText:SetText("")
        self._value = false
    end

    ---@return table widget
    function constructCheckBox()
        local frame = createFrame("Frame", releaseParent())
        local button = createFrame("CheckButton", frame, "UICheckButtonTemplate")
        button:SetSize(24, 24)
        button:SetPoint("LEFT", frame, "LEFT", 0, 0)

        local indeterminate = button:CreateTexture(nil, "OVERLAY")
        indeterminate:SetSize(10, 10)
        indeterminate:SetPoint("CENTER", button, "CENTER", 0, 0)
        indeterminate:SetColorTexture(LABEL_RED, LABEL_GREEN, LABEL_BLUE, 1)
        indeterminate:Hide()

        local labelText = frame:CreateFontString(nil, "OVERLAY")
        labelText:SetFontObject("GameFontHighlight")
        labelText:SetJustifyH("LEFT")
        labelText:SetPoint("LEFT", button, "RIGHT", 4, 0)
        labelText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

        local widget = {
            frame = frame,
            button = button,
            indeterminate = indeterminate,
            labelText = labelText,
            _value = false,
            _triState = false,
            OnAcquire = checkBoxOnAcquire,
            OnRelease = checkBoxOnRelease,
            SetValue = checkBoxSetValue,
            GetValue = checkBoxGetValue,
            SetTriState = checkBoxSetTriState,
            SetLabel = setWidgetLabel,
            GetLabel = getWidgetLabel,
            SetDisabled = checkBoxSetDisabled,
        }

        button:SetScript("OnClick", function()
            if not isActive(widget) then
                return
            end
            -- The cycle is unchecked, checked, then (with three states) the third.
            local value = widget._value
            if value == false then
                value = true
            elseif value == true and widget._triState then
                value = nil
            else
                value = false
            end
            widget._value = value
            checkBoxShowValue(widget)
            widget:Fire("OnValueChanged", value)
        end)
        return widget
    end
end

-- Widget: Slider -------------------------------------------------------------

do
    ---Snap `value` to the widget's step and clamp it to its range.
    ---@param widget table
    ---@param value number
    ---@return number
    local function sliderSnap(widget, value)
        local minimum, maximum, step = widget._minimum, widget._maximum, widget._step
        if step > 0 then
            value = minimum + math.floor((value - minimum) / step + 0.5) * step
        end
        if value < minimum then
            value = minimum
        elseif value > maximum then
            value = maximum
        end
        return value
    end

    ---Show the value in the edit box: a percentage for percent sliders.
    ---@param widget table
    local function sliderShowValue(widget)
        local value = widget._value
        local text
        if widget._isPercent then
            text = string.format("%d%%", math.floor(value * 100 + 0.5))
        else
            text = string.format("%.10g", value)
        end
        widget.valueBox:SetText(text)
    end

    ---Store `value` and move the slider without firing `OnValueChanged`.
    ---@param widget table
    ---@param value number
    local function sliderStore(widget, value)
        widget._value = value
        widget._updating = true
        widget.slider:SetValue(value)
        widget._updating = false
        sliderShowValue(widget)
    end

    ---@param minimum number
    ---@param maximum number
    ---@param step number? `0` or `nil` for no snapping
    local function sliderSetSliderValues(self, minimum, maximum, step)
        activeRecord(self, "WidgetKit Slider:SetSliderValues", 3)
        validateNumber(minimum, "WidgetKit Slider:SetSliderValues minimum", 3)
        validateNumber(maximum, "WidgetKit Slider:SetSliderValues maximum", 3)
        if minimum > maximum then
            error("WidgetKit Slider:SetSliderValues minimum must not be greater than maximum", 2)
        end
        step = step or 0
        validateNumber(step, "WidgetKit Slider:SetSliderValues step", 3)
        if step < 0 then
            error("WidgetKit Slider:SetSliderValues step must not be negative", 2)
        end
        self._minimum, self._maximum, self._step = minimum, maximum, step
        self._updating = true
        self.slider:SetMinMaxValues(minimum, maximum)
        self.slider:SetValueStep(step > 0 and step or 0)
        self._updating = false
        self.lowText:SetText(string.format("%.10g", minimum))
        self.highText:SetText(string.format("%.10g", maximum))
        sliderStore(self, sliderSnap(self, self._value))
    end

    ---@param value number
    local function sliderSetValue(self, value)
        activeRecord(self, "WidgetKit Slider:SetValue", 3)
        validateNumber(value, "WidgetKit Slider:SetValue value", 3)
        sliderStore(self, sliderSnap(self, value))
    end

    ---@return number
    local function sliderGetValue(self)
        activeRecord(self, "WidgetKit Slider:GetValue", 3)
        return self._value
    end

    ---@param isPercent boolean
    local function sliderSetIsPercent(self, isPercent)
        activeRecord(self, "WidgetKit Slider:SetIsPercent", 3)
        if type(isPercent) ~= "boolean" then
            error("WidgetKit Slider:SetIsPercent isPercent must be a boolean", 2)
        end
        self._isPercent = isPercent
        sliderShowValue(self)
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function sliderSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit Slider:SetDisabled", 3)
        self.slider:SetEnabled(not disabled)
        self.valueBox:SetEnabled(not disabled)
        colourLabel(self.labelText, disabled)
    end

    ---Accept a user change: snap, store, and fire when it moved.
    ---@param widget table
    ---@param value number
    local function sliderAccept(widget, value)
        value = sliderSnap(widget, value)
        local changed = value ~= widget._value
        sliderStore(widget, value)
        if changed then
            widget:Fire("OnValueChanged", value)
        end
    end

    local function sliderOnAcquire(self)
        self.frame:SetSize(200, 50)
        self._minimum, self._maximum, self._step = 0, 100, 1
        self._value = 0
        self._isPercent = false
        self._updating = true
        self.slider:SetMinMaxValues(0, 100)
        self.slider:SetValueStep(1)
        self._updating = false
        self.slider:SetEnabled(true)
        self.valueBox:SetEnabled(true)
        self.labelText:SetText("")
        colourLabel(self.labelText, false)
        self.lowText:SetText("0")
        self.highText:SetText("100")
        sliderStore(self, 0)
    end

    local function sliderOnRelease(self)
        self.labelText:SetText("")
        self.valueBox:ClearFocus()
    end

    ---@return table widget
    function constructSlider()
        local frame = createFrame("Frame", releaseParent())
        local labelText = newTopLabel(frame)

        local slider = createFrame("Slider", frame)
        slider:SetOrientation("HORIZONTAL")
        slider:SetHeight(16)
        slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
        slider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)
        if type(slider.SetObeyStepOnDrag) == "function" then
            slider:SetObeyStepOnDrag(true)
        end
        slider:EnableMouseWheel(false)
        local track = slider:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints(slider)
        track:SetColorTexture(0, 0, 0, 0.5)
        local thumb = slider:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(0.8, 0.8, 0.8, 1)
        thumb:SetSize(10, 16)
        slider:SetThumbTexture(thumb)

        local lowText = frame:CreateFontString(nil, "OVERLAY")
        lowText:SetFontObject("GameFontHighlightSmall")
        lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
        local highText = frame:CreateFontString(nil, "OVERLAY")
        highText:SetFontObject("GameFontHighlightSmall")
        highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)

        local valueBox = createFrame("EditBox", frame, "InputBoxTemplate")
        valueBox:SetSize(70, 14)
        valueBox:SetPoint("TOP", slider, "BOTTOM", 0, -2)
        valueBox:SetAutoFocus(false)
        valueBox:SetFontObject("GameFontHighlightSmall")
        valueBox:SetJustifyH("CENTER")

        local widget = {
            frame = frame,
            labelText = labelText,
            slider = slider,
            valueBox = valueBox,
            lowText = lowText,
            highText = highText,
            _minimum = 0,
            _maximum = 100,
            _step = 1,
            _value = 0,
            _isPercent = false,
            _updating = false,
            OnAcquire = sliderOnAcquire,
            OnRelease = sliderOnRelease,
            SetSliderValues = sliderSetSliderValues,
            SetValue = sliderSetValue,
            GetValue = sliderGetValue,
            SetIsPercent = sliderSetIsPercent,
            SetLabel = setWidgetLabel,
            GetLabel = getWidgetLabel,
            SetDisabled = sliderSetDisabled,
        }

        slider:SetScript("OnValueChanged", function(_, value)
            if widget._updating or not isActive(widget) then
                return
            end
            sliderAccept(widget, value)
        end)
        valueBox:SetScript("OnEnterPressed", function()
            valueBox:ClearFocus()
            if not isActive(widget) then
                return
            end
            local text = valueBox:GetText()
            if isSecret(text) then
                sliderShowValue(widget)
                return
            end
            local number = tonumber((text:gsub("%%", "")))
            if number == nil then
                sliderShowValue(widget)
                return
            end
            if widget._isPercent then
                number = number / 100
            end
            sliderAccept(widget, number)
        end)
        valueBox:SetScript("OnEscapePressed", function()
            valueBox:ClearFocus()
            if isActive(widget) then
                sliderShowValue(widget)
            end
        end)
        return widget
    end
end

-- Widget: EditBox ------------------------------------------------------------

do
    local EDIT_LINE_HEIGHT = 14

    ---The edit box currently in use: the multi-line one or the single-line one.
    ---@param widget table
    ---@return WidgetKit.Frame
    local function activeEditBox(widget)
        if widget._multiLine then
            return widget.multiBox
        end
        return widget.singleBox
    end

    ---Size the widget for its mode and line count.
    ---@param widget table
    local function editBoxUpdateHeight(widget)
        if widget._multiLine then
            local boxHeight = widget._lines * EDIT_LINE_HEIGHT + 8
            widget.multiBox:SetHeight(boxHeight)
            widget.frame:SetHeight(18 + boxHeight + 28)
        else
            widget.frame:SetHeight(44)
        end
    end

    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function editBoxSetText(self, text, options)
        activeRecord(self, "WidgetKit EditBox:SetText", 3)
        local value = checkText(text, options, "WidgetKit EditBox:SetText", 3)
        self._settingText = true
        activeEditBox(self):SetText(value)
        self._settingText = false
    end

    ---@return any
    local function editBoxGetText(self)
        activeRecord(self, "WidgetKit EditBox:GetText", 3)
        return activeEditBox(self):GetText()
    end

    ---@param multiLine boolean
    ---@param lines integer? visible lines of a multi-line box; default 4
    local function editBoxSetMultiLine(self, multiLine, lines)
        activeRecord(self, "WidgetKit EditBox:SetMultiLine", 3)
        if type(multiLine) ~= "boolean" then
            error("WidgetKit EditBox:SetMultiLine multiLine must be a boolean", 2)
        end
        if type(lines) ~= "nil" then
            validatePositiveInteger(lines, "WidgetKit EditBox:SetMultiLine lines", 3)
        end
        local text = activeEditBox(self):GetText()
        self._multiLine = multiLine
        self._lines = lines or 4
        setShown(self.singleBox, not multiLine)
        setShown(self.multiBox, multiLine)
        setShown(self.acceptButton, multiLine)
        self._settingText = true
        activeEditBox(self):SetText(text)
        self._settingText = false
        editBoxUpdateHeight(self)
    end

    ---@return boolean
    local function editBoxIsMultiLine(self)
        activeRecord(self, "WidgetKit EditBox:IsMultiLine", 3)
        return self._multiLine == true
    end

    ---@param letters integer `0` for no limit
    local function editBoxSetMaxLetters(self, letters)
        activeRecord(self, "WidgetKit EditBox:SetMaxLetters", 3)
        refuseSecret(letters, "WidgetKit EditBox:SetMaxLetters letters", 3)
        if letters ~= 0 then
            validatePositiveInteger(letters, "WidgetKit EditBox:SetMaxLetters letters", 3)
        end
        self.singleBox:SetMaxLetters(letters)
        self.multiBox:SetMaxLetters(letters)
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function editBoxSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit EditBox:SetDisabled", 3)
        self.singleBox:SetEnabled(not disabled)
        self.multiBox:SetEnabled(not disabled)
        self.acceptButton:SetEnabled(not disabled)
        colourLabel(self.labelText, disabled)
        if disabled then
            activeEditBox(self):ClearFocus()
        end
    end

    ---Give the edit box keyboard focus and make it WidgetKit's focused widget.
    local function editBoxSetFocus(self)
        activeRecord(self, "WidgetKit EditBox:SetFocus", 3)
        WidgetKit:SetFocus(self)
        activeEditBox(self):SetFocus()
    end

    ---Called by `WidgetKit:ClearFocus` when another widget takes the focus.
    local function editBoxOnFocusLost(self)
        self.singleBox:ClearFocus()
        self.multiBox:ClearFocus()
    end

    ---Fire `OnEnterPressed` with the current text.
    ---@param widget table
    local function editBoxSubmit(widget)
        if not isActive(widget) then
            return
        end
        widget:Fire("OnEnterPressed", activeEditBox(widget):GetText())
    end

    local function editBoxOnAcquire(self)
        self.frame:SetWidth(200)
        self._multiLine = false
        self._lines = 4
        self._settingText = true
        self.singleBox:SetText("")
        self.multiBox:SetText("")
        self._settingText = false
        self.singleBox:SetMaxLetters(0)
        self.multiBox:SetMaxLetters(0)
        self.singleBox:SetEnabled(true)
        self.multiBox:SetEnabled(true)
        self.acceptButton:SetEnabled(true)
        self.singleBox:Show()
        self.multiBox:Hide()
        self.acceptButton:Hide()
        self.labelText:SetText("")
        colourLabel(self.labelText, false)
        editBoxUpdateHeight(self)
    end

    ---Clear both boxes, so a pooled edit box never carries a secret into its next
    ---use.
    local function editBoxOnRelease(self)
        self._settingText = true
        self.singleBox:SetText("")
        self.multiBox:SetText("")
        self._settingText = false
        self.singleBox:ClearFocus()
        self.multiBox:ClearFocus()
        self.labelText:SetText("")
    end

    ---@return table widget
    function constructEditBox()
        local frame = createFrame("Frame", releaseParent())
        local labelText = newTopLabel(frame)

        local singleBox = createFrame("EditBox", frame, "InputBoxTemplate")
        singleBox:SetAutoFocus(false)
        singleBox:SetFontObject("ChatFontNormal")
        singleBox:SetHeight(20)
        singleBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -20)
        singleBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -20)

        local multiBox = createFrame("EditBox", frame)
        multiBox:SetMultiLine(true)
        multiBox:SetAutoFocus(false)
        multiBox:SetFontObject("ChatFontNormal")
        multiBox:SetTextInsets(4, 4, 4, 4)
        multiBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
        multiBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)
        local multiBackground = multiBox:CreateTexture(nil, "BACKGROUND")
        multiBackground:SetAllPoints(multiBox)
        multiBackground:SetColorTexture(0, 0, 0, 0.5)
        multiBox:Hide()

        local acceptButton = createFrame("Button", frame, "UIPanelButtonTemplate")
        acceptButton:SetSize(80, 22)
        acceptButton:SetPoint("TOPLEFT", multiBox, "BOTTOMLEFT", 0, -3)
        acceptButton:SetText(clientText("ACCEPT", "Accept"))
        acceptButton:Hide()

        local widget = {
            frame = frame,
            labelText = labelText,
            singleBox = singleBox,
            multiBox = multiBox,
            acceptButton = acceptButton,
            _multiLine = false,
            _lines = 4,
            _settingText = false,
            OnAcquire = editBoxOnAcquire,
            OnRelease = editBoxOnRelease,
            OnFocusLost = editBoxOnFocusLost,
            SetText = editBoxSetText,
            GetText = editBoxGetText,
            SetMultiLine = editBoxSetMultiLine,
            IsMultiLine = editBoxIsMultiLine,
            SetMaxLetters = editBoxSetMaxLetters,
            SetLabel = setWidgetLabel,
            GetLabel = getWidgetLabel,
            SetDisabled = editBoxSetDisabled,
            SetFocus = editBoxSetFocus,
        }

        local function onTextChanged(box, userInput)
            if widget._settingText or not userInput or not isActive(widget) then
                return
            end
            widget:Fire("OnTextChanged", box:GetText())
        end
        local function onEscapePressed(box)
            box:ClearFocus()
            if isActive(widget) then
                widget:Fire("OnEscapePressed")
            end
        end
        local function onFocusGained()
            if isActive(widget) then
                WidgetKit:SetFocus(widget)
            end
        end
        local function onFocusLost()
            if rawget(state, "focus") == widget then
                rawset(state, "focus", false)
            end
        end

        singleBox:SetScript("OnEnterPressed", function(box)
            box:ClearFocus()
            editBoxSubmit(widget)
        end)
        for _, box in ipairs({ singleBox, multiBox }) do
            box:SetScript("OnTextChanged", onTextChanged)
            box:SetScript("OnEscapePressed", onEscapePressed)
            box:SetScript("OnEditFocusGained", onFocusGained)
            box:SetScript("OnEditFocusLost", onFocusLost)
        end
        acceptButton:SetScript("OnClick", function()
            multiBox:ClearFocus()
            editBoxSubmit(widget)
        end)
        return widget
    end
end

-- Dropdown list catcher ------------------------------------------------------
--
-- While a dropdown list is open, one invisible full-screen frame owned by the
-- Kit sits just below it and closes it on a click anywhere else. One catcher
-- serves the whole session; its script calls through `dispatch`, so a newer
-- copy's code runs for a catcher an older copy created.

---The session's catcher frame, created on first use.
---@return WidgetKit.Frame
local function dropdownCatcher()
    local catcher = rawget(state, "dropdownCatcher")
    if catcher == nil or catcher == false then
        local uiParent = restingParent()
        catcher = createFrame("Frame", uiParent)
        catcher:SetFrameStrata("FULLSCREEN")
        catcher:ClearAllPoints()
        catcher:SetPoint("TOPLEFT", uiParent, "TOPLEFT", 0, 0)
        catcher:SetPoint("BOTTOMRIGHT", uiParent, "BOTTOMRIGHT", 0, 0)
        catcher:EnableMouse(true)
        catcher:SetScript("OnMouseDown", function()
            dispatch.closeOpenDropdown()
        end)
        catcher:Hide()
        rawset(state, "dropdownCatcher", catcher)
    end
    return catcher
end

---Close `widget`'s list, and hide the catcher when it was the open one.
---@param widget table
local function closeDropdownList(widget)
    widget.list:Hide()
    if rawget(state, "openDropdown") == widget then
        rawset(state, "openDropdown", false)
        local catcher = rawget(state, "dropdownCatcher")
        if catcher ~= nil and catcher ~= false then
            catcher:Hide()
        end
    end
end

---Close whichever dropdown list is open.
local function closeOpenDropdown()
    local open = rawget(state, "openDropdown")
    if open ~= nil and open ~= false then
        closeDropdownList(open)
    end
end

---Show `widget`'s list above the catcher, closing any other open list.
---@param widget table
local function openDropdownList(widget)
    local open = rawget(state, "openDropdown")
    if open ~= nil and open ~= false and open ~= widget then
        closeDropdownList(open)
    end
    rawset(state, "openDropdown", widget)
    dropdownCatcher():Show()
    widget.list:Show()
end

-- Widget: Dropdown -----------------------------------------------------------

do --
    -- A button showing the selected entry, and a list frame of row buttons below
    -- it. Nothing takes the keyboard. The list keeps a fixed number of rows,
    -- created on first open and reused for the widget's whole life; entries past
    -- them are reached with the mouse wheel, which moves the window of entries the
    -- rows show.

    local DROPDOWN_ROW_HEIGHT = 18

    -- Rows a dropdown list shows at once; the rest is reached with the wheel.
    local DROPDOWN_VISIBLE_ROWS = 16

    ---The label shown for the selected key, or an empty string.
    ---@param widget table
    ---@return string
    local function dropdownSelectedLabel(widget)
        local value = widget._value
        if value == nil then
            return ""
        end
        local keys, labels = widget._keys, widget._labels
        for index = 1, widget._count do
            if keys[index] == value then
                return labels[index]
            end
        end
        return ""
    end

    ---Point every row at the entries from `_offset` on.
    ---@param widget table
    local function dropdownRenderRows(widget)
        local rows = widget._rows
        local keys, labels = widget._keys, widget._labels
        for index = 1, #rows do
            local entry = widget._offset + index
            local row = rows[index]
            if entry <= widget._count then
                row:SetText(labels[entry])
                if keys[entry] == widget._value then
                    row:LockHighlight()
                else
                    row:UnlockHighlight()
                end
                row:Show()
            else
                row:SetText("")
                row:Hide()
            end
        end
    end

    ---Select the entry a row shows, close the list and fire.
    ---@param widget table
    ---@param rowIndex integer
    local function dropdownPick(widget, rowIndex)
        if not isActive(widget) or widget._disabled then
            return
        end
        local entry = widget._offset + rowIndex
        if entry > widget._count then
            return
        end
        local key = widget._keys[entry]
        widget._value = key
        widget.button:SetText(widget._labels[entry])
        closeDropdownList(widget)
        widget:Fire("OnValueChanged", key)
    end

    ---Create the list's rows on first open.
    ---@param widget table
    local function dropdownEnsureRows(widget)
        local rows = widget._rows
        if #rows > 0 then
            return
        end
        local list = widget.list
        for index = 1, DROPDOWN_VISIBLE_ROWS do
            local row = createFrame("Button", list)
            row:SetHeight(DROPDOWN_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (index - 1) * DROPDOWN_ROW_HEIGHT)
            row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, -4 - (index - 1) * DROPDOWN_ROW_HEIGHT)
            row:SetNormalFontObject("GameFontHighlightSmall")
            local highlight = row:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints(row)
            highlight:SetColorTexture(1, 1, 1, 0.15)
            row:SetScript("OnClick", function()
                dropdownPick(widget, index)
            end)
            rows[index] = row
        end
    end

    ---Replace the entries.
    ---
    ---`values` maps keys (strings or numbers) to labels; `order` lists the keys in
    ---display order. Without `order`, entries are sorted by label, then by key.
    ---@param values table
    ---@param order any[]?
    local function dropdownSetList(self, values, order)
        activeRecord(self, "WidgetKit Dropdown:SetList", 3)
        if type(values) ~= "table" then
            error("WidgetKit Dropdown:SetList values must be a table", 2)
        end
        if type(order) ~= "nil" and type(order) ~= "table" then
            error("WidgetKit Dropdown:SetList order must be an array or nil", 2)
        end

        -- Every entry is checked into staging arrays first; the widget's own
        -- entries change only once the whole list was accepted, so a refused
        -- entry leaves the dropdown as it was.
        local keys, labels = {}, {}
        local count = 0
        -- Read when the list is set, so `SetLimits` applies to the next list.
        local maxEntries = rawget(rawget(state, "limits"), "maxDropdownEntries")
        if maxEntries == UNBOUNDED then
            maxEntries = math.huge
        end
        local function add(key, label)
            -- `add` runs one call below `SetList`, so its caller is level 3.
            refuseSecret(key, "WidgetKit Dropdown:SetList key", 4)
            refuseSecret(label, "WidgetKit Dropdown:SetList label", 4)
            if type(key) ~= "string" and type(key) ~= "number" then
                error("WidgetKit Dropdown:SetList keys must be strings or numbers", 3)
            end
            if type(label) ~= "string" then
                error("WidgetKit Dropdown:SetList labels must be strings", 3)
            end
            if count >= maxEntries then
                error(
                    "WidgetKit Dropdown:SetList holds at most "
                        .. maxEntries
                        .. " entries (WidgetKit:SetLimits maxDropdownEntries)",
                    3
                )
            end
            count = count + 1
            keys[count] = key
            labels[count] = label
        end

        -- The staged position of each displayed entry, when sorting reorders them.
        local displayOrder = nil
        if order ~= nil then
            for index = 1, #order do
                local key = order[index]
                local label = values[key]
                if label ~= nil then
                    add(key, label)
                end
            end
        else
            for key, label in next, values do
                add(key, label)
            end
            -- Sort by label, then key, through an index array over the staged
            -- entries; the widget's arrays are then filled in that order.
            displayOrder = {}
            for index = 1, count do
                displayOrder[index] = index
            end
            table.sort(displayOrder, function(first, second)
                local firstLabel, secondLabel = labels[first], labels[second]
                if firstLabel ~= secondLabel then
                    return firstLabel < secondLabel
                end
                local firstKey, secondKey = keys[first], keys[second]
                if type(firstKey) ~= type(secondKey) then
                    return type(firstKey) == "number"
                end
                return firstKey < secondKey
            end)
        end

        local ownKeys, ownLabels = self._keys, self._labels
        for index = 1, count do
            local staged = index
            if displayOrder ~= nil then
                staged = displayOrder[index]
            end
            ownKeys[index] = keys[staged]
            ownLabels[index] = labels[staged]
        end
        for index = count + 1, self._count do
            ownKeys[index] = nil
            ownLabels[index] = nil
        end
        self._count = count
        self._offset = 0
        self.button:SetText(dropdownSelectedLabel(self))
        if self.list:IsShown() then
            dropdownRenderRows(self)
        end
    end

    ---@param key string|number|nil
    local function dropdownSetValue(self, key)
        activeRecord(self, "WidgetKit Dropdown:SetValue", 3)
        refuseSecret(key, "WidgetKit Dropdown:SetValue key", 3)
        self._value = key
        self.button:SetText(dropdownSelectedLabel(self))
        if self.list:IsShown() then
            dropdownRenderRows(self)
        end
    end

    ---@return string|number|nil
    local function dropdownGetValue(self)
        activeRecord(self, "WidgetKit Dropdown:GetValue", 3)
        return self._value
    end

    ---@return integer
    local function dropdownGetNumEntries(self)
        activeRecord(self, "WidgetKit Dropdown:GetNumEntries", 3)
        return self._count
    end

    ---Open the list, scrolled so that the selected entry is visible.
    ---@return boolean opened `false` when disabled or empty
    local function dropdownOpen(self)
        activeRecord(self, "WidgetKit Dropdown:Open", 3)
        if self._disabled or self._count == 0 then
            return false
        end
        dropdownEnsureRows(self)
        local visible = self._count < DROPDOWN_VISIBLE_ROWS and self._count or DROPDOWN_VISIBLE_ROWS
        self.list:SetHeight(visible * DROPDOWN_ROW_HEIGHT + 8)
        self._offset = 0
        local value = self._value
        for index = 1, self._count do
            if self._keys[index] == value and index > DROPDOWN_VISIBLE_ROWS then
                self._offset = index - DROPDOWN_VISIBLE_ROWS
            end
        end
        dropdownRenderRows(self)
        openDropdownList(self)
        return true
    end

    local function dropdownClose(self)
        activeRecord(self, "WidgetKit Dropdown:Close", 3)
        closeDropdownList(self)
    end

    ---@return boolean
    local function dropdownIsOpen(self)
        activeRecord(self, "WidgetKit Dropdown:IsOpen", 3)
        return self.list:IsShown() == true
    end

    ---Choose the entry at `index` in display order, as a click on its row does.
    ---@param index integer
    ---@return boolean picked
    local function dropdownPickIndex(self, index)
        activeRecord(self, "WidgetKit Dropdown:PickIndex", 3)
        validatePositiveInteger(index, "WidgetKit Dropdown:PickIndex index", 3)
        if index > self._count or self._disabled then
            return false
        end
        local previousOffset = self._offset
        self._offset = index - 1
        dropdownPick(self, 1)
        self._offset = previousOffset
        return true
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function dropdownSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit Dropdown:SetDisabled", 3)
        self._disabled = disabled
        self.button:SetEnabled(not disabled)
        colourLabel(self.labelText, disabled)
        if disabled then
            closeDropdownList(self)
        end
    end

    local function dropdownOnAcquire(self)
        self.frame:SetSize(200, 44)
        self._value = nil
        self._offset = 0
        self._disabled = false
        self.button:SetEnabled(true)
        self.button:SetText("")
        self.labelText:SetText("")
        colourLabel(self.labelText, false)
        closeDropdownList(self)
    end

    local function dropdownOnRelease(self)
        closeDropdownList(self)
        local keys, labels = self._keys, self._labels
        for index = 1, self._count do
            keys[index] = nil
            labels[index] = nil
        end
        self._count = 0
        self._value = nil
        self.button:SetText("")
        self.labelText:SetText("")
        local rows = self._rows
        for index = 1, #rows do
            rows[index]:SetText("")
        end
    end

    ---@return table widget
    function constructDropdown()
        local frame = createFrame("Frame", releaseParent())
        local labelText = newTopLabel(frame)

        local button = createFrame("Button", frame, "UIPanelButtonTemplate")
        button:SetHeight(24)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -18)
        button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -18)

        -- The list lives on UIParent, above everything, so a ScrollFrame or any
        -- other clipping parent of the dropdown cannot cut it off.
        local list = createFrame("Frame", restingParent() or frame)
        list:SetFrameStrata("FULLSCREEN_DIALOG")
        list:SetToplevel(true)
        list:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, 0)
        list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 0)
        list:EnableMouse(true)
        list:EnableMouseWheel(true)
        local background = list:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(list)
        background:SetColorTexture(0.05, 0.05, 0.05, 0.95)
        list:Hide()

        local widget = {
            frame = frame,
            labelText = labelText,
            button = button,
            list = list,
            _keys = {},
            _labels = {},
            _rows = {},
            _count = 0,
            _offset = 0,
            _value = nil,
            _disabled = false,
            OnAcquire = dropdownOnAcquire,
            OnRelease = dropdownOnRelease,
            SetList = dropdownSetList,
            SetValue = dropdownSetValue,
            GetValue = dropdownGetValue,
            GetNumEntries = dropdownGetNumEntries,
            Open = dropdownOpen,
            Close = dropdownClose,
            IsOpen = dropdownIsOpen,
            PickIndex = dropdownPickIndex,
            SetLabel = setWidgetLabel,
            GetLabel = getWidgetLabel,
            SetDisabled = dropdownSetDisabled,
        }

        button:SetScript("OnClick", function()
            if not isActive(widget) then
                return
            end
            if list:IsShown() then
                closeDropdownList(widget)
            else
                widget:Open()
            end
        end)
        -- The list is not a child of the widget's frame, so it is closed when
        -- that frame hides.
        frame:SetScript("OnHide", function()
            closeDropdownList(widget)
        end)
        list:SetScript("OnMouseWheel", function(_, delta)
            if not isActive(widget) then
                return
            end
            local maximumOffset = widget._count - DROPDOWN_VISIBLE_ROWS
            if maximumOffset < 0 then
                maximumOffset = 0
            end
            local offset = widget._offset - delta
            if offset < 0 then
                offset = 0
            elseif offset > maximumOffset then
                offset = maximumOffset
            end
            widget._offset = offset
            dropdownRenderRows(widget)
        end)
        return widget
    end
end

-- Widget: ColorPicker --------------------------------------------------------

do --
    -- A swatch. A click opens the client's `ColorPickerFrame` through its
    -- `SetupColorPickerAndShow` method when the client has one and the frame may
    -- be touched; WidgetKit writes no field onto that frame. Without it, a click
    -- fires `OnValueChanged` with the current colour.

    ---Show the stored colour on the swatch.
    ---@param widget table
    local function colorShow(widget)
        widget.swatch:SetColorTexture(widget._red, widget._green, widget._blue, widget._alpha)
    end

    ---@param red number
    ---@param green number
    ---@param blue number
    ---@param alpha number?
    local function colorSetColor(self, red, green, blue, alpha)
        activeRecord(self, "WidgetKit ColorPicker:SetColor", 3)
        validateNumber(red, "WidgetKit ColorPicker:SetColor red", 3)
        validateNumber(green, "WidgetKit ColorPicker:SetColor green", 3)
        validateNumber(blue, "WidgetKit ColorPicker:SetColor blue", 3)
        if type(alpha) ~= "nil" then
            validateNumber(alpha, "WidgetKit ColorPicker:SetColor alpha", 3)
        end
        self._red, self._green, self._blue, self._alpha = red, green, blue, alpha or 1
        colorShow(self)
    end

    ---@return number red, number green, number blue, number alpha
    local function colorGetColor(self)
        activeRecord(self, "WidgetKit ColorPicker:GetColor", 3)
        return self._red, self._green, self._blue, self._alpha
    end

    ---@param hasAlpha boolean
    local function colorSetHasAlpha(self, hasAlpha)
        activeRecord(self, "WidgetKit ColorPicker:SetHasAlpha", 3)
        if type(hasAlpha) ~= "boolean" then
            error("WidgetKit ColorPicker:SetHasAlpha hasAlpha must be a boolean", 2)
        end
        self._hasAlpha = hasAlpha
    end

    ---@param disabled boolean? `true` greys the widget out and ignores input
    local function colorSetDisabled(self, disabled)
        disabled = readDisabled(self, disabled, "WidgetKit ColorPicker:SetDisabled", 3)
        self._disabled = disabled
        self.button:SetEnabled(not disabled)
        if disabled then
            self.labelText:SetTextColor(DISABLED_RED, DISABLED_GREEN, DISABLED_BLUE)
        else
            self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
        end
    end

    ---Store a colour chosen in the client picker and fire.
    ---@param widget table
    ---@param red number
    ---@param green number
    ---@param blue number
    ---@param alpha number
    local function colorChosen(widget, red, green, blue, alpha)
        if not isActive(widget) then
            return
        end
        if isSecret(red) or isSecret(green) or isSecret(blue) or isSecret(alpha) then
            return
        end
        widget._red, widget._green, widget._blue, widget._alpha = red, green, blue, alpha
        colorShow(widget)
        widget:Fire("OnValueChanged", red, green, blue, alpha)
    end

    ---Open the client colour picker, or fire with the current colour without one.
    ---@return boolean opened `true` when the client picker was opened
    local function colorOpenPicker(self)
        activeRecord(self, "WidgetKit ColorPicker:OpenPicker", 3)
        if self._disabled then
            return false
        end
        local picker = readGlobal("ColorPickerFrame")
        local setup = type(picker) == "table" and picker.SetupColorPickerAndShow or nil
        if type(setup) ~= "function" or not canTouchFrame(picker) then
            self:Fire("OnValueChanged", self._red, self._green, self._blue, self._alpha)
            return false
        end
        local info = self._pickerInfo
        info.r, info.g, info.b = self._red, self._green, self._blue
        info.opacity = self._alpha
        info.hasOpacity = self._hasAlpha
        self._previousRed, self._previousGreen = self._red, self._green
        self._previousBlue, self._previousAlpha = self._blue, self._alpha
        -- The client picker calls back later; it only reaches this use of the
        -- widget, never a later one after a release.
        self._pickerSession = self._session
        setup(picker, info)
        return true
    end

    local function colorOnAcquire(self)
        self.frame:SetSize(200, 24)
        self._red, self._green, self._blue, self._alpha = 1, 1, 1, 1
        self._hasAlpha = false
        self._disabled = false
        self.button:SetEnabled(true)
        self.labelText:SetText("")
        self.labelText:SetTextColor(TEXT_RED, TEXT_GREEN, TEXT_BLUE)
        colorShow(self)
    end

    local function colorOnRelease(self)
        self.labelText:SetText("")
        -- Disarm the client picker's callbacks for this use of the widget.
        self._session = self._session + 1
    end

    ---@return table widget
    function constructColorPicker()
        local frame = createFrame("Frame", releaseParent())
        local button = createFrame("Button", frame)
        button:SetSize(20, 20)
        button:SetPoint("LEFT", frame, "LEFT", 2, 0)
        local border = button:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints(button)
        border:SetColorTexture(0.8, 0.8, 0.8, 1)
        local swatch = button:CreateTexture(nil, "OVERLAY")
        swatch:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
        swatch:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)

        local labelText = frame:CreateFontString(nil, "OVERLAY")
        labelText:SetFontObject("GameFontHighlight")
        labelText:SetJustifyH("LEFT")
        labelText:SetPoint("LEFT", button, "RIGHT", 6, 0)
        labelText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

        local widget = {
            frame = frame,
            button = button,
            swatch = swatch,
            labelText = labelText,
            _red = 1,
            _green = 1,
            _blue = 1,
            _alpha = 1,
            _hasAlpha = false,
            _session = 0,
            _pickerSession = -1,
            _disabled = false,
            OnAcquire = colorOnAcquire,
            OnRelease = colorOnRelease,
            SetColor = colorSetColor,
            GetColor = colorGetColor,
            SetHasAlpha = colorSetHasAlpha,
            OpenPicker = colorOpenPicker,
            SetLabel = setWidgetLabel,
            GetLabel = getWidgetLabel,
            SetDisabled = colorSetDisabled,
        }

        ---Whether the client picker was opened by the current use of the widget.
        local function pickerIsCurrent()
            return isActive(widget) and widget._pickerSession == widget._session
        end

        ---Read the colour the client picker shows now. Without alpha, the
        ---stored alpha is kept.
        local function readPicker()
            if not pickerIsCurrent() then
                return
            end
            local picker = readGlobal("ColorPickerFrame")
            if type(picker) ~= "table" or type(picker.GetColorRGB) ~= "function" then
                return
            end
            local red, green, blue = picker:GetColorRGB()
            local alpha = widget._alpha
            if widget._hasAlpha and type(picker.GetColorAlpha) == "function" then
                alpha = picker:GetColorAlpha()
            end
            colorChosen(widget, red, green, blue, alpha)
        end

        -- One info table per widget, built once: `SetupColorPickerAndShow` reads
        -- it, and opening the picker again only rewrites its fields.
        widget._pickerInfo = {
            swatchFunc = readPicker,
            opacityFunc = readPicker,
            cancelFunc = function()
                if not pickerIsCurrent() then
                    return
                end
                colorChosen(
                    widget,
                    widget._previousRed,
                    widget._previousGreen,
                    widget._previousBlue,
                    widget._previousAlpha
                )
            end,
        }

        button:SetScript("OnClick", function()
            if isActive(widget) then
                widget:OpenPicker()
            end
        end)
        return widget
    end
end

-- Widget: Heading ------------------------------------------------------------

do
    ---@param text any
    ---@param options WidgetKit.TextOptions?
    local function headingSetText(self, text, options)
        activeRecord(self, "WidgetKit Heading:SetText", 3)
        local value, secret = checkText(text, options, "WidgetKit Heading:SetText", 3)
        self.text:SetText(value)
        -- The lines meet in the middle when there is no text.
        local empty = not secret and value == ""
        self.leftLine:ClearAllPoints()
        self.rightLine:ClearAllPoints()
        self.leftLine:SetPoint("LEFT", self.frame, "LEFT", 0, 0)
        self.rightLine:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0)
        if empty then
            self.leftLine:SetPoint("RIGHT", self.frame, "CENTER", 0, 0)
            self.rightLine:SetPoint("LEFT", self.frame, "CENTER", 0, 0)
        else
            self.leftLine:SetPoint("RIGHT", self.text, "LEFT", -6, 0)
            self.rightLine:SetPoint("LEFT", self.text, "RIGHT", 6, 0)
        end
    end

    ---@return any
    local function headingGetText(self)
        activeRecord(self, "WidgetKit Heading:GetText", 3)
        return self.text:GetText()
    end

    ---@param disabled boolean? `true` greys the text out; the widget takes no input
    local function headingSetDisabled(self, disabled)
        colourLabel(self.text, readDisabled(self, disabled, "WidgetKit Heading:SetDisabled", 3))
    end

    local function headingOnAcquire(self)
        self.frame:SetSize(200, 18)
        self:SetFullWidth(true)
        colourLabel(self.text, false)
        headingSetText(self, "")
    end

    local function headingOnRelease(self)
        self.text:SetText("")
    end

    ---@return table widget
    function constructHeading()
        local frame = createFrame("Frame", releaseParent())
        local text = frame:CreateFontString(nil, "OVERLAY")
        text:SetFontObject("GameFontNormal")
        text:SetPoint("CENTER", frame, "CENTER", 0, 0)
        local leftLine = frame:CreateTexture(nil, "BACKGROUND")
        leftLine:SetHeight(1)
        leftLine:SetColorTexture(0.6, 0.6, 0.6, 0.6)
        local rightLine = frame:CreateTexture(nil, "BACKGROUND")
        rightLine:SetHeight(1)
        rightLine:SetColorTexture(0.6, 0.6, 0.6, 0.6)
        return {
            frame = frame,
            text = text,
            leftLine = leftLine,
            rightLine = rightLine,
            OnAcquire = headingOnAcquire,
            OnRelease = headingOnRelease,
            SetText = headingSetText,
            GetText = headingGetText,
            SetDisabled = headingSetDisabled,
        }
    end
end

-- Widget: Spacer -------------------------------------------------------------

do
    local function spacerOnAcquire(self)
        self.frame:SetSize(10, 8)
    end

    ---@return table widget
    function constructSpacer()
        return {
            frame = createFrame("Frame", releaseParent()),
            OnAcquire = spacerOnAcquire,
        }
    end
end

-- Media pickers --------------------------------------------------------------

---Fill `dropdown` with the names MediaKit lists for `mediaType`.
---@param MediaKit table
---@param dropdown table
---@param mediaType string
---@return boolean filled `false` when MediaKit refused the type
local function fillMediaDropdown(MediaKit, dropdown, mediaType)
    local ok, names = pcall(MediaKit.List, MediaKit, mediaType)
    if not ok or type(names) ~= "table" then
        return false
    end
    local values = {}
    for index = 1, #names do
        values[names[index]] = names[index]
    end
    dropdown:SetList(values, names)
    return true
end

---A Dropdown listing MediaKit's names for `mediaType`, in MediaKit's order.
---@param mediaType string one of MediaKit's media types, such as `"font"` or `"statusbar"`
---@return WidgetKit.Widget|nil dropdown
---@return string? reason `"exhausted"` when no Dropdown can be created
local function createMediaPicker(self, mediaType)
    validateFacade(self, "WidgetKit:CreateMediaPicker", 3)
    validateName(mediaType, "WidgetKit:CreateMediaPicker mediaType", 3)
    local MediaKit = findPackage(Registry, "mediaKit", OPTIONAL_MEDIAKIT_API)
    if type(MediaKit) ~= "table" or type(MediaKit.List) ~= "function" then
        error("WidgetKit:CreateMediaPicker requires MediaKit API 1", 2)
    end
    local probe, names = pcall(MediaKit.List, MediaKit, mediaType)
    if not probe or type(names) ~= "table" then
        error("WidgetKit:CreateMediaPicker mediaType must be a MediaKit media type", 2)
    end
    -- Checked before a Dropdown is acquired: a list `SetList` would refuse must
    -- not leave a borrowed widget behind.
    local maxEntries = rawget(rawget(state, "limits"), "maxDropdownEntries")
    if maxEntries ~= UNBOUNDED and #names > maxEntries then
        error(
            "WidgetKit:CreateMediaPicker MediaKit lists more "
                .. mediaType
                .. " names than a Dropdown holds ("
                .. maxEntries
                .. "; WidgetKit:SetLimits maxDropdownEntries)",
            2
        )
    end

    local dropdown, reason = WidgetKit:Create("Dropdown")
    if dropdown == nil then
        return nil, reason
    end
    fillMediaDropdown(MediaKit, dropdown, mediaType)
    return dropdown
end

-- The renderer lives in its own block; only its entry point is visible below.
local renderOptions

-- Renderer -------------------------------------------------------------------

do --
    -- `RenderOptions` walks `tree:Describe()` once and creates one widget per
    -- visible node in display order. Every read afterwards goes through
    -- `tree:Get`, `tree:IsDisabled` and `tree:IsHidden`, which allocate nothing;
    -- every write goes through `tree:Validate` then `tree:Set`. A refusal is shown
    -- in a Label inserted right below the widget. `tree:OnChange` refreshes the
    -- widgets in place, and rebuilds them only when a node was shown or hidden.

    -- Which widget type draws each option kind.
    local NODE_WIDGET_TYPES = {
        group = "Group",
        toggle = "CheckBox",
        range = "Slider",
        select = "Dropdown",
        multiselect = "Group",
        input = "EditBox",
        color = "ColorPicker",
        keybinding = "Button",
        execute = "Button",
        header = "Heading",
        description = "Label",
    }

    -- The option kinds that carry a value `tree:Get` reads.
    local VALUE_KINDS = {
        toggle = true,
        range = true,
        select = true,
        multiselect = true,
        input = true,
        color = true,
        keybinding = true,
    }

    -- What a widget shows instead of a secret value it was not allowed to show.
    local SECRET_PLACEHOLDER = "<secret value>"

    -- Font objects for `description` options by `fontSize`.
    local DESCRIPTION_FONTS = {
        small = "GameFontHighlightSmall",
        medium = "GameFontHighlight",
        large = "GameFontHighlightLarge",
    }

    -- The text options of an edit box that may show a secret.
    local ALLOW_SECRET_TEXT = { allowSecret = true }

    -- Seconds an armed `execute` confirmation waits for its second click.
    local CONFIRM_SECONDS = 5

    -- The question an `execute` option with `confirm = true` asks.
    local DEFAULT_CONFIRM_TEXT = "Click again to confirm."

    -- The colour of an inline refusal.
    local MESSAGE_RED, MESSAGE_GREEN, MESSAGE_BLUE = 1, 0.3, 0.3

    ---@param rendering any
    ---@param methodName string qualified public method name, used in the argument error
    ---@param level integer stack level the failure is reported at
    local function validateRendering(rendering, methodName, level)
        if type(rendering) ~= "table" or getmetatable(rendering) ~= RENDERING_METATABLE then
            error(methodName .. " must be called on a WidgetKit rendering", level)
        end
    end

    ---Remember the acquire serial `widget` has now, so the rendering can tell
    ---its own use of the widget from a later one after the widget went back to
    ---its pool and was acquired by someone else.
    ---@param rendering table
    ---@param widget table
    local function stamp(rendering, widget)
        rendering._serials[widget] = records[widget].serial
    end

    ---Whether `widget` is still the active widget this rendering acquired (or,
    ---for the container, was given).
    ---@param rendering table
    ---@param widget table?
    ---@return boolean
    local function owns(rendering, widget)
        if widget == nil then
            return false
        end
        local record = records[widget]
        return record ~= nil
            and record.active == true
            and record.serial == rendering._serials[widget]
    end

    ---Create a widget for the renderer, remembering the first failure.
    ---@param rendering table
    ---@param typeName string
    ---@return table? widget
    local function renderCreate(rendering, typeName)
        local widget, reason = WidgetKit:Create(typeName)
        if widget == nil then
            if rendering._failure == nil then
                rendering._failure = "could not create a "
                    .. typeName
                    .. " widget: "
                    .. tostring(reason)
            end
            return nil
        end
        stamp(rendering, widget)
        return widget
    end

    ---Whether the rendering may still act: not released, and its container still
    ---the one it was given. A rendering whose container went away is released
    ---on the spot, so it never touches widgets it no longer owns.
    ---@param rendering table
    ---@return boolean
    local function renderingAlive(rendering)
        if rendering._released then
            return false
        end
        if not owns(rendering, rendering._container) then
            RenderingPrototype.Release(rendering)
            return false
        end
        return true
    end

    ---Add a rendered widget to `parent`, remembering the ones added to the
    ---container the rendering was given, which it releases itself.
    ---@param rendering table
    ---@param parent table
    ---@param widget table
    ---@param beforeWidget table?
    ---@return boolean added
    local function renderAdd(rendering, parent, widget, beforeWidget)
        local added, reason = parent:AddChild(widget, beforeWidget)
        if not added then
            WidgetKit:Release(widget)
            if rendering._failure == nil then
                rendering._failure = "could not add a widget to its container: " .. tostring(reason)
            end
            return false
        end
        if parent == rendering._container then
            local widgets = rendering._widgets
            widgets[#widgets + 1] = widget
        end
        return true
    end

    ---Forget `widget` in the list of widgets the rendering added to its container.
    ---@param rendering table
    ---@param widget table
    local function renderForget(rendering, widget)
        local widgets = rendering._widgets
        for index = #widgets, 1, -1 do
            if widgets[index] == widget then
                table.remove(widgets, index)
                return
            end
        end
    end

    ---Text that can be shown for a message, which may be any error value.
    ---@param message any
    ---@return string|number
    local function messageText(message)
        if isSecret(message) then
            return SECRET_PLACEHOLDER
        end
        if type(message) == "string" or type(message) == "number" then
            return message
        end
        return tostring(message)
    end

    ---Show `message` in a Label right below the record's widget.
    ---@param rendering table
    ---@param record table
    ---@param message any
    local function showMessage(rendering, record, message)
        local text = messageText(message)
        local label = record.messageLabel
        if owns(rendering, label) then
            label:SetText(text)
            local parent = record.parent
            if owns(rendering, parent) then
                parent:PerformLayout()
            end
            return
        end
        record.messageLabel = nil

        local parent = record.parent
        if not owns(rendering, parent) or not owns(rendering, record.widget) then
            return
        end
        label = WidgetKit:Create("Label")
        if label == nil then
            -- Nowhere to show it: the user still learns through the error frame.
            reportError(message)
            return
        end
        stamp(rendering, label)
        label:SetFullWidth(true)
        label:SetColor(MESSAGE_RED, MESSAGE_GREEN, MESSAGE_BLUE)
        label:SetText(text)

        local siblings = parent:GetChildren()
        local beforeWidget = nil
        for index = 1, #siblings do
            if siblings[index] == record.widget then
                beforeWidget = siblings[index + 1]
                break
            end
        end
        if not renderAdd(rendering, parent, label, beforeWidget) then
            rendering._failure = nil
            reportError(message)
            return
        end
        record.messageLabel = label
    end

    ---Remove the record's inline message, if it has one.
    ---@param rendering table
    ---@param record table
    local function clearMessage(rendering, record)
        local label = record.messageLabel
        if label == nil then
            return
        end
        record.messageLabel = nil
        if owns(rendering, label) then
            renderForget(rendering, label)
            WidgetKit:Release(label)
            local parent = record.parent
            if owns(rendering, parent) then
                parent:PerformLayout()
            end
        end
    end

    ---Whether a value read back from the tree is a table that may be indexed.
    ---@param value any
    ---@return boolean
    local function isReadableTable(value)
        return type(value) == "table" and not isSecret(value)
    end

    ---Show `value` and the disabled state on the record's widgets.
    ---
    ---A secret value is never inspected. An `input` option shows it only when the
    ---caller passed `allowSecret`; every other kind shows a placeholder or its
    ---default and is disabled, since the user cannot edit what cannot be read.
    ---@param rendering table
    ---@param record table
    ---@param value any
    ---@param disabled boolean
    local function applyState(rendering, record, value, disabled)
        local kind = record.kind
        local widget = record.widget
        record.disabled = disabled

        if not VALUE_KINDS[kind] then
            widget:SetDisabled(disabled)
            return
        end

        local secret = isSecret(value)
        if kind == "multiselect" then
            widget:SetDisabled(disabled)
            local readable = not secret and isReadableTable(value)
            local keys, boxes = record.keys, record.checkBoxes
            for index = 1, #keys do
                local checked = false
                if readable then
                    local entry = value[keys[index]]
                    checked = not isSecret(entry) and entry == true
                end
                boxes[index]:SetValue(checked)
                boxes[index]:SetDisabled(disabled or secret)
            end
            return
        end

        if secret then
            if kind == "input" and rendering._allowSecret then
                widget:SetText(value, ALLOW_SECRET_TEXT)
                widget:SetDisabled(disabled)
                return
            end
            if kind == "input" then
                widget:SetText(SECRET_PLACEHOLDER)
            elseif kind == "keybinding" then
                widget:SetText(record.name .. ": " .. SECRET_PLACEHOLDER)
            end
            widget:SetDisabled(true)
            return
        end

        if kind == "toggle" then
            if value == nil and record.triState then
                widget:SetValue(nil)
            else
                widget:SetValue(value == true)
            end
        elseif kind == "range" then
            if type(value) == "number" and value == value then
                widget:SetValue(value)
            end
        elseif kind == "select" then
            if type(value) == "string" or type(value) == "number" then
                widget:SetValue(value)
            else
                widget:SetValue(nil)
            end
        elseif kind == "input" then
            if type(value) == "string" or type(value) == "number" then
                widget:SetText(value)
            else
                widget:SetText("")
            end
        elseif kind == "color" then
            if isReadableTable(value) then
                local red, green, blue, alpha = value.r, value.g, value.b, value.a
                if
                    type(red) == "number"
                    and type(green) == "number"
                    and type(blue) == "number"
                    and not isSecret(red)
                    and not isSecret(green)
                    and not isSecret(blue)
                then
                    if type(alpha) ~= "number" or isSecret(alpha) then
                        alpha = 1
                    end
                    widget:SetColor(red, green, blue, alpha)
                end
            end
        elseif kind == "keybinding" then
            local key = clientText("NOT_BOUND", "Not bound")
            if type(value) == "string" and value ~= "" then
                key = value
            end
            widget:SetText(record.name .. ": " .. key)
        end
        widget:SetDisabled(disabled)
    end

    ---Read one record's value and state back from the tree.
    ---@param rendering table
    ---@param record table
    local function refreshRecord(rendering, record)
        if not owns(rendering, record.widget) then
            return
        end
        local tree = rendering._tree
        local value = nil
        if VALUE_KINDS[record.kind] then
            value = tree:Get(record.path)
        end
        applyState(rendering, record, value, tree:IsDisabled(record.path) == true)
    end

    ---Run a refresh that `OnChange` asked for while a write was in progress.
    ---@param rendering table
    local function runPendingRefresh(rendering)
        if rendering._pending and rendering._busy == 0 and not rendering._released then
            rendering._pending = false
            RenderingPrototype.Refresh(rendering)
        end
    end

    ---Write `value` through the tree: `Validate`, then `Set`. A refusal becomes an
    ---inline message and the widget shows the stored value again.
    ---@param rendering table
    ---@param record table
    ---@param value any
    local function writeValue(rendering, record, value)
        if not renderingAlive(rendering) or not owns(rendering, record.widget) then
            return
        end
        local tree = rendering._tree
        rendering._busy = rendering._busy + 1
        -- A raising Validate or Set is shown and reported, never raised into the
        -- widget's script, and never leaves the rendering busy.
        local validated, ok, message = pcall(tree.Validate, tree, record.path, value)
        if not validated then
            ok, message = false, ok
            reportError(message)
        end
        if ok == true then
            local called, result, setMessage = pcall(tree.Set, tree, record.path, value)
            if not called then
                ok, message = false, result
                reportError(result)
            elseif result ~= true then
                ok, message = false, setMessage
            end
        end
        rendering._busy = rendering._busy - 1

        if ok == true then
            clearMessage(rendering, record)
        else
            showMessage(rendering, record, message or "refused")
            refreshRecord(rendering, record)
        end
        runPendingRefresh(rendering)
    end

    ---Write a `multiselect` option after one of its boxes changed: a new map of
    ---the checked keys.
    ---@param rendering table
    ---@param record table
    ---@param key any
    ---@param checked boolean?
    local function writeMultiselect(rendering, record, key, checked)
        if not renderingAlive(rendering) or not owns(rendering, record.widget) then
            return
        end
        local current = rendering._tree:Get(record.path)
        local readable = isReadableTable(current)
        local map = {}
        local keys = record.keys
        for index = 1, #keys do
            local entryKey = keys[index]
            local on
            if entryKey == key then
                on = checked == true
            elseif readable then
                local entry = current[entryKey]
                on = not isSecret(entry) and entry == true
            else
                on = false
            end
            if on then
                map[entryKey] = true
            end
        end
        writeValue(rendering, record, map)
    end

    ---Disarm an armed `execute` confirmation: cancel its timer and remove the
    ---question.
    ---@param rendering table
    ---@param record table
    local function disarmRecord(rendering, record)
        local job = record.disarmJob
        record.disarmJob = nil
        if job ~= nil and type(job.Cancel) == "function" then
            pcall(job.Cancel, job)
        end
        if record.armed then
            record.armed = false
            clearMessage(rendering, record)
        end
    end

    ---Run an `execute` option. With `confirm`, the first click arms it and shows
    ---the question below the button; the second click runs it. An armed
    ---confirmation disarms itself after `CONFIRM_SECONDS` through SchedulerKit
    ---when it is registered, otherwise at the next `Refresh`.
    ---@param rendering table
    ---@param record table
    local function executeRecord(rendering, record)
        if not renderingAlive(rendering) or not owns(rendering, record.widget) then
            return
        end
        local confirm = record.confirm
        if confirm ~= nil and confirm ~= false and not record.armed then
            record.armed = true
            local question = type(confirm) == "string" and confirm or rendering._confirmText
            showMessage(rendering, record, question)
            local SchedulerKit = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API)
            if type(SchedulerKit) == "table" and type(SchedulerKit.After) == "function" then
                record.disarmJob = SchedulerKit:After(CONFIRM_SECONDS, function()
                    record.disarmJob = nil
                    if not rendering._released and record.armed then
                        disarmRecord(rendering, record)
                    end
                end)
            end
            return
        end
        disarmRecord(rendering, record)

        local tree = rendering._tree
        rendering._busy = rendering._busy + 1
        local ok, failure = pcall(tree.Execute, tree, record.path)
        rendering._busy = rendering._busy - 1
        if not ok then
            reportError(failure)
            showMessage(rendering, record, failure)
        end
        runPendingRefresh(rendering)
    end

    ---The keys of a `select` or `multiselect` node in display order: `sorting`
    ---when it has one, otherwise by label, then key.
    ---@param node table
    ---@return any[]
    local function orderedKeys(node)
        local values = node.values
        if type(values) ~= "table" then
            return {}
        end
        local sorting = node.sorting
        local keys = {}
        if type(sorting) == "table" then
            for index = 1, #sorting do
                if values[sorting[index]] ~= nil then
                    keys[#keys + 1] = sorting[index]
                end
            end
            return keys
        end
        for key in next, values do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(first, second)
            local firstLabel, secondLabel = tostring(values[first]), tostring(values[second])
            if firstLabel ~= secondLabel then
                return firstLabel < secondLabel
            end
            if type(first) ~= type(second) then
                return type(first) == "number"
            end
            return first < second
        end)
        return keys
    end

    local renderNodes

    ---Configure a freshly created widget for its node.
    ---@param rendering table
    ---@param record table
    ---@param node table
    ---@return boolean ok
    local function configureNode(rendering, record, node)
        local kind = record.kind
        local widget = record.widget

        if kind == "group" then
            widget:SetTitle(node.name)
            widget:PauseLayout()
            local ok = renderNodes(rendering, node.children, widget)
            widget:ResumeLayout()
            return ok
        elseif kind == "toggle" then
            widget:SetLabel(node.name)
            widget:SetTriState(record.triState)
            widget:SetCallback("OnValueChanged", function(_, _, value)
                writeValue(rendering, record, value)
            end)
        elseif kind == "range" then
            widget:SetLabel(node.name)
            widget:SetSliderValues(node.min, node.max, node.step or 0)
            widget:SetIsPercent(node.isPercent == true)
            widget:SetCallback("OnValueChanged", function(_, _, value)
                writeValue(rendering, record, value)
            end)
        elseif kind == "select" then
            widget:SetLabel(node.name)
            local mediaType = rendering._media ~= nil and rendering._media[record.path] or nil
            local MediaKit = mediaType ~= nil
                    and findPackage(Registry, "mediaKit", OPTIONAL_MEDIAKIT_API)
                or nil
            if
                mediaType == nil
                or type(MediaKit) ~= "table"
                or type(MediaKit.List) ~= "function"
                or not fillMediaDropdown(MediaKit, widget, mediaType)
            then
                widget:SetList(type(node.values) == "table" and node.values or {}, node.sorting)
            end
            widget:SetCallback("OnValueChanged", function(_, _, value)
                writeValue(rendering, record, value)
            end)
        elseif kind == "multiselect" then
            widget:SetTitle(node.name)
            widget:PauseLayout()
            local keys = orderedKeys(node)
            record.keys = keys
            record.checkBoxes = {}
            for index = 1, #keys do
                local key = keys[index]
                local box = renderCreate(rendering, "CheckBox")
                if box == nil then
                    widget:ResumeLayout()
                    return false
                end
                box:SetFullWidth(true)
                box:SetLabel(node.values[key])
                if not renderAdd(rendering, widget, box) then
                    widget:ResumeLayout()
                    return false
                end
                box:SetCallback("OnValueChanged", function(_, _, checked)
                    writeMultiselect(rendering, record, key, checked)
                end)
                record.checkBoxes[index] = box
            end
            widget:ResumeLayout()
        elseif kind == "input" then
            widget:SetLabel(node.name)
            widget:SetMultiLine(node.multiline == true)
            widget:SetCallback("OnEnterPressed", function(_, _, text)
                writeValue(rendering, record, text)
            end)
        elseif kind == "color" then
            widget:SetLabel(node.name)
            local hasAlpha = node.hasAlpha == true
            widget:SetHasAlpha(hasAlpha)
            widget:SetCallback("OnValueChanged", function(_, _, red, green, blue, alpha)
                writeValue(rendering, record, {
                    r = red,
                    g = green,
                    b = blue,
                    a = hasAlpha and alpha or nil,
                })
            end)
        elseif kind == "keybinding" then
            widget:SetKeyCapture(true)
            widget:SetCallback("OnKeyCaptured", function(_, _, key)
                writeValue(rendering, record, key)
            end)
        elseif kind == "execute" then
            widget:SetText(node.name)
            widget:SetCallback("OnClick", function()
                executeRecord(rendering, record)
            end)
        elseif kind == "header" then
            widget:SetText(node.name)
        elseif kind == "description" then
            widget:SetFontObject(DESCRIPTION_FONTS[node.fontSize] or DESCRIPTION_FONTS.medium)
            widget:SetText(node.name)
        end
        return true
    end

    ---Create, add and configure the widget for one visible node.
    ---@param rendering table
    ---@param node table
    ---@param parent table
    ---@return boolean ok
    local function renderNode(rendering, node, parent)
        local kind = node.kind
        local typeName = NODE_WIDGET_TYPES[kind]
        if typeName == nil then
            -- A kind this generation does not know is skipped, not refused.
            return true
        end

        local widget = renderCreate(rendering, typeName)
        if widget == nil then
            return false
        end
        widget:SetFullWidth(true)
        if not renderAdd(rendering, parent, widget) then
            return false
        end

        local record = {
            path = node.path,
            kind = kind,
            name = node.name,
            widget = widget,
            parent = parent,
            triState = node.tristate == true,
            confirm = node.confirm,
            armed = false,
            disabled = false,
            messageLabel = nil,
        }
        local recordList = rendering._records
        recordList[#recordList + 1] = record
        rendering._byPath[node.path] = record

        if not configureNode(rendering, record, node) then
            return false
        end
        -- The value is read with `Get`, not taken from the description:
        -- `Describe` hands out a copy of a table value, and a copy no longer
        -- answers `issecretvalue` as the original did.
        refreshRecord(rendering, record)
        return true
    end

    ---Render every node of `nodes` into `parent`, remembering each one's hidden
    ---state so a refresh can tell when one was shown or hidden.
    ---@param rendering table
    ---@param nodes any
    ---@param parent table
    ---@return boolean ok
    function renderNodes(rendering, nodes, parent)
        if type(nodes) ~= "table" then
            return true
        end
        local visited = rendering._nodes
        for index = 1, #nodes do
            local node = nodes[index]
            local hidden = node.hidden == true
            visited[#visited + 1] = { path = node.path, hidden = hidden }
            if not hidden and not renderNode(rendering, node, parent) then
                return false
            end
        end
        return true
    end

    ---Release everything the rendering created and forget it.
    ---@param rendering table
    local function releaseRendered(rendering)
        local recordList = rendering._records
        for index = #recordList, 1, -1 do
            local record = recordList[index]
            local job = record.disarmJob
            record.disarmJob = nil
            if job ~= nil and type(job.Cancel) == "function" then
                pcall(job.Cancel, job)
            end
            local label = record.messageLabel
            if owns(rendering, label) and not WidgetBase.IsReleasing(label) then
                renderForget(rendering, label)
                WidgetKit:Release(label)
            end
        end
        -- Only widgets this rendering still owns are released: a widget that went
        -- back to its pool and was acquired by someone else is left alone, and one
        -- whose container is being released goes with that container.
        local widgets = rendering._widgets
        for index = #widgets, 1, -1 do
            local widget = widgets[index]
            if owns(rendering, widget) and not WidgetBase.IsReleasing(widget) then
                WidgetKit:Release(widget)
            end
        end
        rendering._records = {}
        rendering._byPath = {}
        rendering._nodes = {}
        rendering._widgets = {}
    end

    ---Build the widgets from a fresh description and lay the container out once.
    ---@param rendering table
    ---@return boolean ok
    local function buildRendering(rendering)
        local container = rendering._container
        local containerRecord = records[container]
        local description = rendering._tree:Describe()

        local wasPaused = containerRecord.layoutPaused
        containerRecord.layoutPaused = true
        rendering._failure = nil
        -- The container's pause state is restored even when building raises.
        local called, ok = pcall(renderNodes, rendering, description.children, container)
        containerRecord.layoutPaused = wasPaused
        if not called then
            rendering._failure = ok
            return false
        end
        if not ok then
            return false
        end
        if not wasPaused then
            performLayout(container, containerRecord)
        end
        return true
    end

    ---Render `tree` into `container`.
    ---@param tree table an OptionsKit tree
    ---@param container WidgetKit.Container
    ---@param options WidgetKit.RenderOptions?
    ---@return WidgetKit.Rendering
    function renderOptions(self, tree, container, options)
        validateFacade(self, "WidgetKit:RenderOptions", 3)
        local OptionsKit = findPackage(Registry, "optionsKit", OPTIONAL_OPTIONSKIT_API)
        if type(OptionsKit) ~= "table" then
            error("WidgetKit:RenderOptions requires OptionsKit API 1", 2)
        end
        if
            type(tree) ~= "table"
            or type(tree.Describe) ~= "function"
            or type(tree.Get) ~= "function"
            or type(tree.Set) ~= "function"
            or type(tree.Validate) ~= "function"
            or type(tree.Execute) ~= "function"
            or type(tree.IsDisabled) ~= "function"
            or type(tree.IsHidden) ~= "function"
            or type(tree.OnChange) ~= "function"
        then
            error("WidgetKit:RenderOptions tree must be an OptionsKit tree", 2)
        end
        local containerRecord = type(container) == "table" and records[container] or nil
        if
            containerRecord == nil
            or not containerRecord.active
            or not containerRecord.isContainer
        then
            error("WidgetKit:RenderOptions container must be an active WidgetKit container", 2)
        end

        local allowSecret, media, confirmText = false, nil, DEFAULT_CONFIRM_TEXT
        if options ~= nil then
            validateOptionKeys(options, RENDER_OPTION_KEYS, "WidgetKit:RenderOptions options", 3)
            if options.allowSecret ~= nil and type(options.allowSecret) ~= "boolean" then
                error("WidgetKit:RenderOptions options.allowSecret must be a boolean", 2)
            end
            allowSecret = options.allowSecret == true
            if options.confirmText ~= nil then
                validateName(options.confirmText, "WidgetKit:RenderOptions options.confirmText", 3)
                confirmText = options.confirmText
            end
            if options.media ~= nil then
                if type(options.media) ~= "table" then
                    error("WidgetKit:RenderOptions options.media must be a table", 2)
                end
                media = {}
                for path, mediaType in next, options.media do
                    if type(path) ~= "string" or type(mediaType) ~= "string" then
                        error(
                            "WidgetKit:RenderOptions options.media must map option paths to media types",
                            2
                        )
                    end
                    media[path] = mediaType
                end
            end
        end

        local rendering = setmetatable({
            _tree = tree,
            _container = container,
            _allowSecret = allowSecret,
            _media = media,
            _confirmText = confirmText,
            -- Widget -> the acquire serial it had when this rendering took it.
            _serials = setmetatable({}, WEAK_KEYS),
            _records = {},
            _byPath = {},
            _nodes = {},
            _widgets = {},
            _busy = 0,
            _pending = false,
            _released = false,
            _failure = nil,
            _connection = nil,
        }, RENDERING_METATABLE)

        stamp(rendering, container)
        if not buildRendering(rendering) then
            local failure = rendering._failure
            releaseRendered(rendering)
            rendering._released = true
            error("WidgetKit:RenderOptions " .. tostring(failure), 2)
        end

        -- The container releases its renderings first when it is released.
        local renderings = containerRecord.renderings
        if renderings == nil then
            renderings = {}
            containerRecord.renderings = renderings
        end
        renderings[#renderings + 1] = rendering

        rendering._connection = tree:OnChange(function()
            rendering:Refresh()
        end)
        return rendering
    end

    ---Show the tree's current values and states. Rebuilds instead when a node was
    ---shown or hidden since the last build.
    ---@return boolean refreshed `false` once released or when a rebuild failed
    function RenderingPrototype:Refresh()
        validateRendering(self, "WidgetKit.Rendering:Refresh", 3)
        if not renderingAlive(self) then
            return false
        end
        if self._busy > 0 then
            -- A write is in progress; refresh once it is done.
            self._pending = true
            return true
        end

        local tree = self._tree
        local visited = self._nodes
        for index = 1, #visited do
            local entry = visited[index]
            if (tree:IsHidden(entry.path) == true) ~= entry.hidden then
                return RenderingPrototype.Rebuild(self)
            end
        end

        local recordList = self._records
        local scheduled = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API) ~= nil
        for index = 1, #recordList do
            local record = recordList[index]
            -- Without SchedulerKit an armed confirmation lasts until the next
            -- refresh.
            if record.armed and not scheduled then
                disarmRecord(self, record)
            end
            refreshRecord(self, record)
        end
        return true
    end

    ---Release every rendered widget and build them again from a fresh description.
    ---@return boolean rebuilt `false` once released, or when widgets ran out (reported)
    function RenderingPrototype:Rebuild()
        validateRendering(self, "WidgetKit.Rendering:Rebuild", 3)
        if not renderingAlive(self) then
            return false
        end
        releaseRendered(self)
        if not buildRendering(self) then
            reportError("WidgetKit.Rendering:Rebuild " .. tostring(self._failure))
            releaseRendered(self)
            return false
        end
        return true
    end

    ---Release every widget the rendering created, together, and stop listening.
    ---@return boolean released `false` when it was already released
    function RenderingPrototype:Release()
        validateRendering(self, "WidgetKit.Rendering:Release", 3)
        if self._released then
            return false
        end
        self._released = true
        local connection = self._connection
        if connection ~= nil then
            connection:Disconnect()
            self._connection = nil
        end
        releaseRendered(self)
        local container = self._container
        local containerRecord = records[container]
        if containerRecord ~= nil then
            local renderings = containerRecord.renderings
            if renderings ~= nil then
                for index = #renderings, 1, -1 do
                    if renderings[index] == self then
                        table.remove(renderings, index)
                    end
                end
            end
        end
        if
            containerRecord ~= nil
            and owns(self, container)
            and not isReleasingRecord(containerRecord)
        then
            performLayout(container, containerRecord)
        end
        return true
    end

    ---Release every rendering drawn into a container that is being released.
    ---@param renderings table[] the container record's list, emptied by the releases
    function releaseContainerRenderings(renderings)
        for index = #renderings, 1, -1 do
            local rendering = renderings[index]
            if rendering ~= nil then
                if rendering._released then
                    table.remove(renderings, index)
                else
                    RenderingPrototype.Release(rendering)
                end
            end
        end
    end

    ---@return boolean
    function RenderingPrototype:IsReleased()
        validateRendering(self, "WidgetKit.Rendering:IsReleased", 3)
        return self._released == true
    end

    ---The widget drawing the option at `path`, or `nil` when it is hidden or the
    ---rendering was released. A `multiselect` option is drawn by a Group.
    ---@param path string
    ---@return WidgetKit.Widget?
    function RenderingPrototype:GetWidget(path)
        validateRendering(self, "WidgetKit.Rendering:GetWidget", 3)
        validateName(path, "WidgetKit.Rendering:GetWidget path", 3)
        local record = self._byPath[path]
        if record == nil or not owns(self, record.widget) then
            return nil
        end
        return record.widget
    end

    ---The inline message shown below the option at `path`, or `nil`.
    ---@param path string
    ---@return any
    function RenderingPrototype:GetMessage(path)
        validateRendering(self, "WidgetKit.Rendering:GetMessage", 3)
        validateName(path, "WidgetKit.Rendering:GetMessage path", 3)
        local record = self._byPath[path]
        local label = record ~= nil and record.messageLabel or nil
        if label == nil or not owns(self, label) then
            return nil
        end
        return label.text:GetText()
    end
end

-- Commit ---------------------------------------------------------------------

rawset(dispatch, "build", buildWidget)
rawset(dispatch, "retire", retireWidget)
rawset(dispatch, "closeOpenDropdown", closeOpenDropdown)

-- Built-in layouts are this package's own, so each copy installs its own
-- functions over whatever an older copy registered under the same names.
layouts[LAYOUT_LIST] = listLayout
layouts[LAYOUT_FILL] = fillLayout
layouts[LAYOUT_FLOW] = flowLayout

rawset(AnchorFunctions, "POINTS", POINTS)
rawset(AnchorFunctions, "FromRect", anchorFromRect)
rawset(AnchorFunctions, "Normalize", anchorNormalize)
rawset(AnchorFunctions, "Apply", anchorApply)
rawset(AnchorFunctions, "Read", anchorRead)

rawset(WidgetKit, "API", API_GENERATION)
rawset(WidgetKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(WidgetKit, "MAX_CREATED", DEFAULT_MAX_CREATED)
rawset(WidgetKit, "MAX_CHILDREN", MAX_CHILDREN)
rawset(WidgetKit, "MAX_CALLBACKS", MAX_CALLBACKS)
rawset(WidgetKit, "UNBOUNDED", UNBOUNDED)
rawset(WidgetKit, "SetLimits", setLimits)
rawset(WidgetKit, "GetLimits", getLimits)
rawset(WidgetKit, "RegisterType", registerType)
rawset(WidgetKit, "GetTypeVersion", getTypeVersion)
rawset(WidgetKit, "Create", create)
rawset(WidgetKit, "Release", release)
rawset(WidgetKit, "IsWidget", isWidget)
rawset(WidgetKit, "RegisterLayout", registerLayout)
rawset(WidgetKit, "GetLayout", getLayout)
rawset(WidgetKit, "SetFocus", setFocus)
rawset(WidgetKit, "ClearFocus", clearFocus)
rawset(WidgetKit, "GetFocus", getFocus)
rawset(WidgetKit, "GetStatistics", getStatistics)
rawset(WidgetKit, "BindPosition", bindPosition)
rawset(WidgetKit, "RenderOptions", renderOptions)
rawset(WidgetKit, "CreateMediaPicker", createMediaPicker)

-- The base widget types. A type already registered at the same or a newer
-- version, by an earlier copy of this file, keeps its constructor.
local BASE_CONSTRUCTORS = {
    Frame = constructWindow,
    Group = constructGroup,
    ScrollFrame = constructScrollFrame,
    Label = constructLabel,
    Button = constructButton,
    CheckBox = constructCheckBox,
    Slider = constructSlider,
    EditBox = constructEditBox,
    Dropdown = constructDropdown,
    ColorPicker = constructColorPicker,
    Heading = constructHeading,
    Spacer = constructSpacer,
}
for typeName, constructor in next, BASE_CONSTRUCTORS do
    registerType(WidgetKit, typeName, constructor, BASE_TYPE_VERSIONS[typeName])
end

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(WidgetKit) or not validateCurrentState(WidgetKit) then
    error("MoltenCodes WidgetKit package state is corrupted or incomplete", 2)
end

return WidgetKit
