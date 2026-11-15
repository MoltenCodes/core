-- MoltenCodes WidgetKit
--
-- Pooled, versioned widgets for World of Warcraft addons: a registry of widget
-- types built on frames WidgetKit creates itself, each type with one bounded
-- free list of idle widgets made on its first use; a small base contract every
-- widget shares; and containers whose layout is an explicit operation, never a
-- reaction to `OnSizeChanged`.
--
-- This file is the core. The widget types, the anchor value type with position
-- persistence, and the renderer that turns an OptionsKit tree into widgets are
-- parts, one file each under `parts/` (`docs/decisions/0001-kit-core-and-parts.md`),
-- so an addon loads only the widgets it uses:
--
--   Containers   Frame, Group, ScrollFrame     Dropdown     Dropdown, media pickers
--   Text         Label, Heading, Spacer        ColorPicker  ColorPicker
--   Button       Button                        ScrollList   ScrollList
--   CheckBox     CheckBox                      Position     Anchor, BindPosition
--   Slider       Slider                        Renderer     RenderOptions, pages
--   EditBox      EditBox
--
-- The core needs Registry API 2 and nothing else. A member of a part that is
-- not loaded raises at the caller's line with the file to embed.
--
-- Contents
-- --------
--   Constants ............. identity, bounds, layouts, parts
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry and host facilities
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host helpers .......... error reporting, secrets, globals, frames
--   Argument checks ....... receivers, names, numbers, option tables
--   Widget records ........ the private per-widget record and its lookups
--   Widget base ........... the prototype every widget falls back to
--   Container base ........ children, layout state and PerformLayout
--   Layouts ............... List, Fill and Flow
--   Type registry ......... RegisterType, free lists, Create, Release, focus
--   Widget helpers ........ text checks and shared construction code
--   Parts ................. part registration, helpers and stand-ins
--   Commit ................ prototype/facade assignment and self-check
--
-- Layout algorithms, pooling and the part machinery are described in
-- `docs/INTERNALS.md`.

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "widgetKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 14
local REQUIRED_REGISTRY_API = 2
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

-- Which part holds each widget type WidgetKit ships, so `Create` can name the
-- file to embed when that part is not loaded.
local BASE_TYPE_PARTS = {
  Frame = "Containers",
  Group = "Containers",
  ScrollFrame = "Containers",
  Label = "Text",
  Heading = "Text",
  Spacer = "Text",
  Button = "Button",
  CheckBox = "CheckBox",
  Slider = "Slider",
  EditBox = "EditBox",
  Dropdown = "Dropdown",
  ColorPicker = "ColorPicker",
  ScrollList = "ScrollList",
}

-- The default layout; `Fill` and `Flow` are the other built-in ones.
local LAYOUT_LIST = "List"

-- Accepted option fields, as sets, so option validation allocates nothing.
local TYPE_OPTION_KEYS = { maxCreated = true, maxCallbacks = true }
local TEXT_OPTION_KEYS = { allowSecret = true }

-- The published surface, listed once so the public-surface predicate reads as
-- a checklist. One table rather than a local per list, to spare main-chunk
-- locals.
local SURFACE = {
  facade = {
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
    "GetPartRevision",
    "SetLimits",
    "GetLimits",
  },
  widget = {
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
  },
  container = {
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
  },
  anchor = { "FromRect", "Normalize", "Apply", "Read" },
  binding = { "Capture", "Restore", "Flush", "OnMoved", "Release", "IsReleased" },
  rendering = {
    "Refresh",
    "Rebuild",
    "Release",
    "IsReleased",
    "GetWidget",
    "GetMessage",
  },
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
---@field maxListElements integer|table The most elements one `ScrollList` holds: a positive integer or `WidgetKit.UNBOUNDED`; default 16384.

---Options for the text setters of every widget.
---@class WidgetKit.TextOptions
---@field allowSecret boolean? Display a secret value. The caller decides; see `docs/EMBEDDING.md`. `EditBox:SetText` refuses a secret even with it: the client's edit box takes one only from untainted code.

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
---@alias WidgetKit.BaseTypeName "Frame"|"Group"|"ScrollFrame"|"Label"|"Button"|"CheckBox"|"Slider"|"EditBox"|"Dropdown"|"ColorPicker"|"Heading"|"Spacer"|"ScrollList"

---A movable, resizable window with a title and a close button.
---@class WidgetKit.Window: WidgetKit.Container
---@field SetTitle fun(self: WidgetKit.Window, text: any, options: WidgetKit.TextOptions?)
---@field GetTitle fun(self: WidgetKit.Window): any
---@field SetResizable fun(self: WidgetKit.Window, resizable: boolean)
---@field SetMovable fun(self: WidgetKit.Window, movable: boolean)
---@field BindPosition fun(self: WidgetKit.Window, storage: table|(fun(): table), options: WidgetKit.BindingOptions?): WidgetKit.Binding
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

---A virtualised list over Blizzard's ScrollBox framework: only the rows on
---display exist as frames.
---@class WidgetKit.ScrollList: WidgetKit.Widget
---@field SetElements fun(self: WidgetKit.ScrollList, elements: table[], retainScroll: boolean?)
---@field Insert fun(self: WidgetKit.ScrollList, element: table, index: integer?)
---@field Remove fun(self: WidgetKit.ScrollList, element: table): boolean
---@field Clear fun(self: WidgetKit.ScrollList)
---@field GetNumElements fun(self: WidgetKit.ScrollList): integer
---@field GetElement fun(self: WidgetKit.ScrollList, index: integer): table?
---@field Refresh fun(self: WidgetKit.ScrollList)
---@field ScrollToElement fun(self: WidgetKit.ScrollList, element: table, alignment: ("begin"|"center"|"end"|"nearest")?): boolean
---@field SetValue fun(self: WidgetKit.ScrollList, element: table?)
---@field GetValue fun(self: WidgetKit.ScrollList): table?
---@field SetRowHeight fun(self: WidgetKit.ScrollList, pixels: number)
---@field SetFormatter fun(self: WidgetKit.ScrollList, callback: (fun(element: table, index: integer): any, any)?)

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
---@field Apply fun(frame: WidgetKit.Frame, anchor: WidgetKit.Anchor): true|false, "forbidden"|"unknownRelative"|"refused"|nil
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
---@field allowSecret boolean? Accepted and checked, with no effect since revision 6: the client's edit box refuses a secret from addon code, so an `input` option whose value is secret shows `<secret value>`, disabled.
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
---@field UNBOUNDED table Sentinel `maxCallbacks`, `SetMaxChildren` and the `maxDropdownEntries` and `maxListElements` limits accept to lift the bound; one table shared by every revision.
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
---@field BindPosition fun(self: WidgetKit, frame: WidgetKit.Frame, storage: table|(fun(): table), options: WidgetKit.BindingOptions?): WidgetKit.Binding
---@field RenderOptions fun(self: WidgetKit, tree: table, container: WidgetKit.Container, options: WidgetKit.RenderOptions?): WidgetKit.Rendering
---@field CreateMediaPicker fun(self: WidgetKit, mediaType: string): WidgetKit.Widget|nil, string?
---@field GetPartRevision fun(self: WidgetKit, partName: string): integer?

-- Dependencies ---------------------------------------------------------------

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry
do
  -- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
  -- selene: allow(global_usage)
  local namespace = rawget(_G, "MoltenCodes")
  local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
  Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
  if type(Registry) == "nil" and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
  end
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes WidgetKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local findPackage = rawget(Registry, "Find")
if
  type(bootstrapPackage) ~= "function"
  or type(rawget(Registry, "Get")) ~= "function"
  or type(findPackage) ~= "function"
then
  error("MoltenCodes WidgetKit requires a valid Registry API 2 facade", 2)
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

  return hasMethods(implementation, SURFACE.facade)
    and hasMethods(rawget(implementation, "Widget"), SURFACE.widget)
    and hasMethods(rawget(implementation, "Container"), SURFACE.container)
    and hasMethods(rawget(implementation, "Anchor"), SURFACE.anchor)
    and hasMethods(rawget(implementation, "Binding"), SURFACE.binding)
    and hasMethods(rawget(implementation, "Rendering"), SURFACE.rendering)
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
    and type(rawget(currentState, "helpers")) == "table"
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "scratchFree")) == "table"
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
    -- Frame scripts and long-lived callbacks call through this table, so
    -- a newer revision replaces what they do for frames an older one made.
    dispatch = {},
    -- Type name to its record: version, constructor, free list, cap.
    types = {},
    -- Layout name to layout function.
    layouts = {},
    -- Widget to its private record. Weak-keyed: a widget WidgetKit
    -- discarded is not kept alive for its record.
    records = setmetatable({}, WEAK_KEYS),
    widgetMetatable = { __index = WidgetBase },
    containerMetatable = { __index = ContainerBase },
    bindingMetatable = { __index = BindingPrototype },
    renderingMetatable = { __index = RenderingPrototype },
    -- Idle layout scratch tables, at most one per layout depth.
    scratchFree = {},
    -- Core functions and shared tables the parts bind to; see "Parts".
    helpers = {},
    -- Part name to `{ revision, bind, ... }` for every part loaded.
    parts = {},
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

-- The most elements one `ScrollList` holds. Revision 12 added it, so a state an
-- older revision made gains it here, and a fresh state too. An element costs
-- one array slot of the consumer's own table in Blizzard's data provider,
-- never a frame, so `UNBOUNDED` is allowed. A literal rather than a constant:
-- the main chunk is at Lua 5.1's limit of 200 local variables.
if rawget(rawget(state, "limits"), "maxListElements") == nil then
  rawset(rawget(state, "limits"), "maxListElements", 16384)
end

-- Revision 14 split the package into a core and parts, and replaced the
-- PoolKit pools by free lists of its own. A state an older revision made gains
-- the tables the parts use; its PoolKit table pool for layout scratch tables
-- is dropped (the pools of the widget types are adopted in "Commit", once the
-- functions that adopt them exist).
if rawget(state, "helpers") == nil then
  rawset(state, "helpers", {})
end
if rawget(state, "parts") == nil then
  rawset(state, "parts", {})
end
if rawget(state, "scratchFree") == nil then
  rawset(state, "scratchFree", {})
end
rawset(state, "scratch", nil)

-- The prototypes, metatables and records are kept across upgrades, so widgets
-- built by an older copy keep their records and gain this copy's base methods
-- without being replaced.
local dispatch = rawget(state, "dispatch")
local types = rawget(state, "types")
local layouts = rawget(state, "layouts")
local records = rawget(state, "records")
local scratchFree = rawget(state, "scratchFree")
local helpers = rawget(state, "helpers")
local parts = rawget(state, "parts")
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

-- The probe rule: `issecretvalue` is read once, when this file loads (the
-- client defines it before any addon runs). When it was absent at load, each
-- check reads the global again and accepts it only as a function, so a probe a
-- host installs later is still honoured. Hot checks inline the rule rather
-- than calling a helper, because a call costs as much as the probe itself.
-- selene: allow(global_usage)
local loadedProbe = rawget(_G, "issecretvalue")
if type(loadedProbe) ~= "function" then
  loadedProbe = nil
end

---The secret probe under the probe rule, or `nil` when there is none: for a
---setter that checks several values, so it resolves the probe once.
---@return function? probe
local function secretProbe()
  if loadedProbe ~= nil then
    return loadedProbe
  end
  -- selene: allow(global_usage)
  local probe = rawget(_G, "issecretvalue")
  if probe ~= nil and type(probe) == "function" then
    return probe
  end
  return nil
end

---Whether `value` is a secret value. Clients without secret values do not
---publish the probe, and nothing is secret there.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if probe == nil or type(probe) ~= "function" then
      return false
    end
  end
  return probe(value) == true
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
  -- The probe rule, inlined (see `isSecret`).
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if probe ~= nil and type(probe) ~= "function" then
      probe = nil
    end
  end
  if probe ~= nil and probe(value) == true then
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
  -- The probe rule, inlined (see `isSecret`).
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if probe ~= nil and type(probe) ~= "function" then
      probe = nil
    end
  end
  if probe ~= nil and probe(value) == true then
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
  -- Before any comparison: a secret number compared with a bound raises.
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
  -- The probe rule, inlined (see `isSecret`).
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if probe ~= nil and type(probe) ~= "function" then
      probe = nil
    end
  end
  if probe ~= nil and probe(value) == true then
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
  local record = records[widget]
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

---Borrow an empty scratch table: an idle one when there is one.
---@return table scratch
local function acquireScratch()
  local count = #scratchFree
  if count > 0 then
    local scratch = scratchFree[count]
    scratchFree[count] = nil
    return scratch
  end
  return {}
end

---Give a scratch table back, emptied. At most `MAX_LAYOUT_DEPTH` are kept:
---layouts nest at most `MAX_LAYOUT_DEPTH` deep, so that many are ever in use.
---@param scratch table
local function releaseScratch(scratch)
  wipe(scratch)
  local count = #scratchFree
  if count < MAX_LAYOUT_DEPTH then
    scratchFree[count + 1] = scratch
  end
end

---Remove `child` from its container's children, searching from the end
---because release walks children from the end.
---@param record table the child's record
---@param child WidgetKit.Widget
local function detachFromParent(record, child)
  local parent = record.parent
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
  -- `type` answers "boolean" for a secret boolean; testing it would raise.
  refuseSecret(disabled, "WidgetKit.Widget:SetDisabled disabled", 4)
  if type(disabled) ~= "nil" and type(disabled) ~= "boolean" then
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
  -- Asked once: `type` is a call, and the answer is needed up to three times.
  local clearing = type(callback) == "nil"
  if not clearing and type(callback) ~= "function" then
    error("WidgetKit.Widget:SetCallback callback must be a function or nil", 2)
  end

  local callbacks = record.callbacks
  if callbacks == nil then
    if clearing then
      return
    end
    callbacks = {}
    record.callbacks = callbacks
  end

  local existing = callbacks[name]
  if clearing then
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
        "WidgetKit.Widget:SetCallback holds at most " .. maxCallbacks .. " callbacks per widget",
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
  local record = records[self]
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
  -- A secret key is not probed: it only indexes `userData`, and the client
  -- refuses a secret table key itself (`docs/decisions/0002-secret-checks-only-where-the-client-answers.md`).
  if type(key) == "nil" then
    error("WidgetKit.Widget:SetUserData key must not be nil", 2)
  end
  local userData = record.userData
  if userData == nil then
    if type(value) == "nil" then
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
  -- A secret key meets the client's own refusal at the index (ADR 0002).
  if type(key) == "nil" then
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
  -- Before `== true`: a secret boolean compared with a boolean raises.
  refuseSecret(fullWidth, "WidgetKit.Widget:SetFullWidth fullWidth", 3)
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
  refuseSecret(fullHeight, "WidgetKit.Widget:SetFullHeight fullHeight", 3)
  record.fullHeight = fullHeight == true
end

---@return boolean
function WidgetBase:IsFullHeight()
  return activeRecord(self, "WidgetKit.Widget:IsFullHeight", 3).fullHeight == true
end

---@param fraction number? of the container's width, above 0 and at most 1; `nil` clears it
function WidgetBase:SetRelativeWidth(fraction)
  local record = activeRecord(self, "WidgetKit.Widget:SetRelativeWidth", 3)
  -- `type`, not `~= nil`: the repository nil rule; validation refuses a secret.
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
  -- Tested with `type`, not `index or 1`: a truth test of a secret raises
  -- here, inside WidgetKit, instead of at the caller.
  if type(index) == "nil" then
    index = 1
  end
  refuseSecret(index, "WidgetKit.Widget:GetPoint index", 3)
  return self.frame:GetPoint(index)
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
  elseif type(parent) ~= "nil" and type(parent) ~= "table" then
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
  local record = records[self]
  if record == nil then
    error("WidgetKit.Widget:IsReleasing must be called on a WidgetKit widget", 2)
  end
  return isReleasingRecord(record)
end

---@return string
function WidgetBase:GetType()
  local record = records[self]
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
  local childRecord = records[child]
  if childRecord == nil or not childRecord.active then
    error(methodName .. " child must be an active WidgetKit widget", level)
  end
  -- A child below a container that is being released is itself mid-release
  -- (`IsReleasing` answers true), so it is refused like the container.
  if isReleasingRecord(childRecord) then
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
  local count = #children
  local position = count + 1
  if type(beforeWidget) ~= "nil" then
    for index = 1, count do
      if children[index] == beforeWidget then
        position = index
        break
      end
    end
  end
  if position > count then
    -- Appending, the common case: a plain store instead of `table.insert`.
    children[position] = child
  else
    table.insert(children, position, child)
  end

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
  if type(beforeWidget) ~= "nil" then
    local beforeRecord = records[beforeWidget]
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

do
  ---The upward size report, once `width` and `height` are known to be plain
  ---numbers or `nil`: what `LayoutFinished` does after its checks. A layout
  ---pass calls this directly, since it has the record and has already
  ---checked the sizes its layout returned.
  ---@param container WidgetKit.Widget a container
  ---@param record table
  ---@param width number?
  ---@param height number?
  local function finishLayout(container, record, width, height)
    local frame = container.frame
    local heightBefore = frame:GetHeight()
    callHook(container, "OnLayoutFinished", width, height)
    -- A secret height (Retail 12.x) raises when compared, so a height that
    -- is secret before or after the hook is unknown and counts as unchanged:
    -- the parent is not asked to lay out again, and would read it as 0 anyway.
    local heightAfter = frame:GetHeight()
    if isSecret(heightBefore) or isSecret(heightAfter) or heightAfter == heightBefore then
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

  ---The upward size report a layout pass ends with. Records nothing itself:
  ---it calls the type's `OnLayoutFinished(width, height)` hook, and when that
  ---changed the container's height, lays out the container holding it —
  ---unless that one is laying out already, paused or being released.
  ---@param width number?
  ---@param height number?
  function ContainerBase:LayoutFinished(width, height)
    local record = activeContainerRecord(self, "WidgetKit.Container:LayoutFinished", 3)
    if type(width) ~= "nil" then
      validateNumber(width, "WidgetKit.Container:LayoutFinished width", 3)
    end
    if type(height) ~= "nil" then
      validateNumber(height, "WidgetKit.Container:LayoutFinished height", 3)
    end
    finishLayout(self, record, width, height)
  end

  ---Run the container's layout once.
  ---
  ---The layout is resolved by name on every pass, so a newer copy's built-in
  ---layouts take over containers an older copy built. A pass inside a pass
  ---of the same container is refused, never looped; a layout error is
  ---re-raised unchanged after the container's layout state was restored.
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
    -- `state` has no metatable: plain indexing is `rawget` without the call.
    local depth = state.layoutDepth
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
    state.layoutDepth = depth + 1
    callHook(container, "OnLayoutStart")
    local scratch = acquireScratch()
    local ok, width, height =
      pcall(layout, rawget(container, "content"), record.children, container, scratch)
    releaseScratch(scratch)
    state.layoutDepth = depth
    record.layingOut = false

    if not ok then
      error(width, 0)
    end
    -- A layout's size is the consumer's value: a secret one is ignored like a
    -- non-number, before the NaN test would compare it and raise.
    if type(width) ~= "number" or isSecret(width) or width ~= width then
      width = nil
    end
    if type(height) ~= "number" or isSecret(height) or height ~= height then
      height = nil
    end
    -- A hook or the layout itself released the container during the pass:
    -- refused as `LayoutFinished`'s own check refused it before the pass
    -- called `finishLayout` directly, with the same message.
    if not record.active then
      error("WidgetKit.Container:LayoutFinished cannot be called on a released widget", 1)
    end
    finishLayout(container, record, width, height)
    return true
  end
end

-- Layouts --------------------------------------------------------------------
--
-- Each built-in layout reads the size requests from the child records and
-- places children with `ClearAllPoints` and `SetPoint` relative to the
-- content frame. A child that is itself a container is laid out as soon as
-- its width is known, so a pass runs top-down and each container reports its
-- height before its parent reads it. Hidden children are skipped.
--
-- Sizes read from the host may be secret (Retail 12.x): `GetWidth`,
-- `GetHeight` and `GetSize` carry `SecretWhenAnchoringSecret` in the client's
-- documentation, and arithmetic or a comparison on a secret raises. Every size
-- a layout reads is asked of `issecretvalue` first, and a secret one counts as
-- unknown: an unknown content width or height sizes no child from it (relative
-- widths and full heights are left alone, and the child is told no size) and
-- is reported to `LayoutFinished` as `nil`; an unknown child width or height
-- adds 0 to the offsets and rows. No new local sits at the top level: the main
-- chunk is at Lua's 200-local limit, so each layout keeps its own.

---Tell a child that a layout sized it.
---@param child WidgetKit.Widget
---@param width number?
---@param height number?
local function notifySized(child, width, height)
  if type(width) ~= "nil" then
    callHook(child, "OnWidthSet", width)
  end
  if type(height) ~= "nil" then
    callHook(child, "OnHeightSet", height)
  end
end

---`List`: children stacked from the top, each below the previous one.
---Full-width children span the content; relative widths are a fraction of it.
---
---`List` is the default layout and runs once per child per pass, so it does
---inline what `notifySized` and `callHook` would do for the one hook it calls,
---and resolves the probe once per pass, not once per size (the probe rule,
---see `isSecret`).
---@type WidgetKit.Layout
local function listLayout(content, children)
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
  end
  local probeSecrets = probe ~= nil and type(probe) == "function"
  -- Insets larger than the container leave the content a negative width;
  -- no child is ever sized below zero. A secret width is unknown (`nil`).
  local width = content:GetWidth()
  if probeSecrets and probe(width) == true then
    width = nil
  elseif width < 0 then
    width = 0
  end
  local offset = 0
  for index = 1, #children do
    local child = children[index]
    local childRecord = records[child]
    local frame = child.frame
    if childRecord ~= nil and frame:IsShown() then
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -offset)
      -- The width the child is told, if any: `notifySized(child, sized, nil)`.
      local sized = nil
      if childRecord.fullWidth then
        frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -offset)
        sized = width
      elseif childRecord.relativeWidth ~= nil and width ~= nil then
        sized = width * childRecord.relativeWidth
        frame:SetWidth(sized)
      end
      if sized ~= nil then
        local hook = rawget(child, "OnWidthSet")
        if type(hook) == "function" then
          local ok, failure = pcall(hook, child, sized)
          if not ok then
            reportError(failure)
          end
        end
      end
      if childRecord.isContainer then
        performLayout(child, childRecord)
      end
      local childHeight = frame:GetHeight()
      if not (probeSecrets and probe(childHeight) == true) then
        offset = offset + childHeight
      end
    end
  end
  return width, offset
end

---`Fill`: the first shown child fills the content; the others are left alone.
---@type WidgetKit.Layout
local function fillLayout(content, children)
  -- A secret width or height is unknown (`nil`); the child is told no size.
  local width, height = content:GetWidth(), content:GetHeight()
  if isSecret(width) then
    width = nil
  else
    width = math.max(width, 0)
  end
  if isSecret(height) then
    height = nil
  else
    height = math.max(height, 0)
  end
  for index = 1, #children do
    local child = children[index]
    local childRecord = records[child]
    local frame = child.frame
    if childRecord ~= nil and frame:IsShown() then
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
      frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
      notifySized(child, width, height)
      if childRecord.isContainer then
        performLayout(child, childRecord)
      end
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
  -- A secret content width is unknown: rows are packed against a width of
  -- 0, so each child after the first in a row wraps, and no child is sized
  -- from it. A secret content height sizes no full-height child.
  local width = content:GetWidth()
  local widthKnown = not isSecret(width)
  if widthKnown then
    width = math.max(width, 0)
  else
    width = 0
  end
  local contentHeight = content:GetHeight()
  local heightKnown = not isSecret(contentHeight)
  local x = 0
  local rowTop = 0
  local rowHeight = 0
  for index = 1, #children do
    local child = children[index]
    local childRecord = records[child]
    local frame = child.frame
    if childRecord ~= nil and frame:IsShown() then
      local childWidth
      local sizedWidth = nil
      if childRecord.fullWidth then
        childWidth = width
        if widthKnown then
          sizedWidth = childWidth
        end
      elseif childRecord.relativeWidth ~= nil and widthKnown then
        childWidth = width * childRecord.relativeWidth
        sizedWidth = childWidth
      else
        childWidth = frame:GetWidth()
        if isSecret(childWidth) then
          childWidth = 0
        end
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
      elseif childRecord.relativeWidth ~= nil and widthKnown then
        frame:SetWidth(childWidth)
      end

      local sizedHeight = nil
      if childRecord.fullHeight and heightKnown then
        sizedHeight = contentHeight - rowTop
        if sizedHeight < 0 then
          sizedHeight = 0
        end
        frame:SetHeight(sizedHeight)
      end
      notifySized(child, sizedWidth, sizedHeight)
      if childRecord.isContainer then
        performLayout(child, childRecord)
      end

      local childHeight = frame:GetHeight()
      if isSecret(childHeight) then
        childHeight = 0
      end
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
  if not widthKnown then
    return nil, rowTop + rowHeight
  end
  return width, rowTop + rowHeight
end

-- Type registry --------------------------------------------------------------
--
-- Each type keeps its own free list: an array of the idle widgets it built,
-- created by the type's first `Create`, never at load or at registration, so a
-- type nobody creates costs only its record. The type is capped (`maxCreated`
-- counts every frame it ever built, since the client never frees one), every
-- released widget is kept for reuse, and the type version is the generation:
-- raising it retires the idle widgets the older constructor built at once and
-- the borrowed ones when they come back. Revision 13 and older kept the same
-- bookkeeping in one PoolKit pool per type; an upgrade adopts those pools (see
-- `adoptPool`).
--
-- The type record:
--
--   name, version, constructor
--   maxCallbacks      the callback bound of its widgets
--   maxCreated        the cap
--   created           frames built over the session
--   discarded         widgets retired: stale versions
--   borrowed          version -> widgets of that version currently borrowed
--   free              the idle widgets, or `nil` before the first `Create`
--   trusted           `true` for WidgetKit's own types, whose hooks run
--                     without `pcall`
--   pool              a PoolKit pool an older revision made, until adopted

---Build one widget of `typeRecord`'s type.
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
  elseif type(getmetatable(widget)) ~= "nil" then
    problem = "must return a table without a metatable"
  elseif records[widget] ~= nil then
    problem = "must return a new table on every call"
  elseif type(rawget(widget, "frame")) ~= "table" then
    problem = "must return a table whose frame field is a frame"
  elseif
    type(rawget(widget, "content")) ~= "nil" and type(rawget(widget, "content")) ~= "table"
  then
    problem = "must return a content field that is a frame, or none"
  elseif
    type(rawget(widget, "OnAcquire")) ~= "nil"
    and type(rawget(widget, "OnAcquire")) ~= "function"
  then
    problem = "must return an OnAcquire field that is a function, or none"
  elseif
    type(rawget(widget, "OnRelease")) ~= "nil"
    and type(rawget(widget, "OnRelease")) ~= "function"
  then
    problem = "must return an OnRelease field that is a function, or none"
  end
  if problem ~= nil then
    local message = 'constructor of type "' .. typeRecord.name .. '" ' .. problem
    rawset(state, "buildProblem", message)
    error(message, 0)
  end

  local isContainer = type(rawget(widget, "content")) ~= "nil"
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

---Retire a widget of a stale version: it is never reused.
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

---Release every rendering drawn into a container that is being released.
---A rendering exists only where a renderer made it, so its prototype's
---`Release` is that renderer's (the `Renderer` part, or an older revision's).
---@param renderings table[] the container record's list, emptied by the releases
local function releaseContainerRenderings(renderings)
  local releaseRendering = rawget(RenderingPrototype, "Release")
  for index = #renderings, 1, -1 do
    local rendering = renderings[index]
    if rendering ~= nil then
      if rendering._released then
        table.remove(renderings, index)
      else
        releaseRendering(rendering)
      end
    end
  end
end

---Release `widget` and everything below it. The caller has checked that it is
---active and not already releasing.
---
---In order: the `OnRelease` callback, children from last to first, the type's
---`OnRelease` hook, then the record is cleared (callbacks, user data, size
---requests, layout), the frame loses its anchors, is hidden and re-parented,
---the widget leaves its container, and its type keeps it for reuse (or
---retires it when a higher version replaced its constructor).
---@param widget table
---@param record table
local function releaseWidget(widget, record)
  -- This runs for every release, so it reads the record, `state` and the
  -- type record by plain indexing (none has a metatable) and does inline
  -- what `Fire`, `callHook`, `wipe`, `releaseParent` and `detachFromParent`
  -- would do: the same steps in the same order, without their calls.
  record.releasing = true
  if state.focus == widget then
    WidgetKit:ClearFocus()
  end

  -- A rendering never outlives its container: it is released first, while
  -- its widgets are still this container's children.
  local renderings = record.renderings
  if renderings ~= nil and #renderings > 0 then
    releaseContainerRenderings(renderings)
  end

  -- The `OnRelease` callback, as `Fire` calls it: the record is active here.
  local callbacks = record.callbacks
  if callbacks ~= nil then
    local onRelease = callbacks.OnRelease
    if onRelease ~= nil then
      local ok, failure = pcall(onRelease, widget, "OnRelease")
      if not ok then
        reportError(failure)
      end
    end
  end

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

  -- The type's `OnRelease` hook, as `callHook` calls it. WidgetKit's own
  -- types are trusted: their hook is WidgetKit's code and runs unprotected.
  local typeRecord = record.typeRecord
  local hook = rawget(widget, "OnRelease")
  if hook ~= nil then
    if typeRecord.trusted then
      hook(widget)
    elseif type(hook) == "function" then
      local ok, failure = pcall(hook, widget)
      if not ok then
        reportError(failure)
      end
    end
  end

  -- Callbacks, user data and size requests go back to their defaults. The
  -- tables are kept for the next use; an empty one is left as it is. Read
  -- again: a callback or hook above may have set the first callback.
  callbacks = record.callbacks
  if callbacks ~= nil and next(callbacks) ~= nil then
    wipe(callbacks)
  end
  record.callbackCount = 0
  record.maxChildren = MAX_CHILDREN
  local userData = record.userData
  if userData ~= nil and next(userData) ~= nil then
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
  -- `releaseParent`: `UIParent` when the client has it, read at every
  -- release, otherwise the hidden holder frame.
  -- selene: allow(global_usage)
  local uiParent = rawget(_G, "UIParent")
  if type(uiParent) == "table" and type(uiParent.GetWidth) == "function" then
    frame:SetParent(uiParent)
  else
    frame:SetParent(holderFrame())
  end

  if record.parent ~= nil then
    detachFromParent(record, widget)
  end
  record.releasing = false
  record.active = false
  local borrowed = typeRecord.borrowed
  local version = record.version
  borrowed[version] = borrowed[version] - 1
  if version == typeRecord.version then
    local free = typeRecord.free
    free[#free + 1] = widget
  else
    -- Built by a constructor a higher version replaced: retired, not reused.
    typeRecord.discarded = typeRecord.discarded + 1
    retireWidget(widget)
  end
end

---Retire every idle widget of `typeRecord`: their version was replaced.
---@param typeRecord table
---@return integer retired
local function retireIdle(typeRecord)
  local free = typeRecord.free
  if free == nil then
    return 0
  end
  local retired = #free
  for index = retired, 1, -1 do
    retireWidget(free[index])
    free[index] = nil
  end
  typeRecord.discarded = typeRecord.discarded + retired
  return retired
end

---Give `typeRecord` a higher version and its constructor.
---
---Idle widgets of older versions are retired now and borrowed ones when they
---are released. Retired frames still count against the cap, so the cap grows
---by what this upgrade uses up: the idle widgets it retires and the borrowed
---widgets of the generation it replaces. Borrowed widgets of generations
---before that one were counted by the upgrade that replaced them. The cap
---never passes the `maxCreatedCeiling` limit in force.
---@param typeRecord table
---@param constructor function
---@param version integer
---@param maxCreated integer the cap the registration asked for
---@param maxCallbacks number
local function raiseTypeVersion(typeRecord, constructor, version, maxCreated, maxCallbacks)
  local ceiling = rawget(rawget(state, "limits"), "maxCreatedCeiling")
  local previousVersion = typeRecord.version
  typeRecord.constructor = constructor
  typeRecord.version = version
  typeRecord.maxCallbacks = maxCallbacks
  local stale = typeRecord.borrowed[previousVersion] or 0
  local retired = retireIdle(typeRecord)
  local cap = typeRecord.maxCreated
  local wanted = cap + retired + stale
  if maxCreated > wanted then
    wanted = maxCreated
  end
  if wanted > ceiling then
    wanted = ceiling
  end
  if wanted > cap then
    typeRecord.maxCreated = wanted
  end
end

---A new type record. Its free list is made by the first `Create`.
---@param name string
---@param constructor function
---@param version integer
---@param maxCreated integer
---@param maxCallbacks number
---@return table typeRecord
local function newTypeRecord(name, constructor, version, maxCreated, maxCallbacks)
  return {
    name = name,
    version = version,
    constructor = constructor,
    -- `math.huge` when registered with `maxCallbacks = WidgetKit.UNBOUNDED`.
    maxCallbacks = maxCallbacks,
    maxCreated = maxCreated,
    created = 0,
    discarded = 0,
    -- Type version -> widgets of that version currently borrowed.
    borrowed = {},
    free = nil,
    trusted = false,
  }
end

---Take over the PoolKit pool a revision 13 or older copy made for a type:
---its idle widgets move onto the type's free list (`Acquire` hands out a
---retained widget while one is available and never builds then), its counts
---are copied, and the pool is dropped. Widgets borrowed from it come back to
---the free list when they are released.
---@param typeRecord table
local function adoptPool(typeRecord)
  local pool = typeRecord.pool
  if pool == nil then
    return
  end
  local free = typeRecord.free or {}
  for _ = 1, pool:GetAvailableCount() do
    local widget = pool:Acquire()
    if widget == nil then
      break
    end
    free[#free + 1] = widget
  end
  typeRecord.free = free
  local cap = pool:GetMaxCreated()
  typeRecord.maxCreated = type(cap) == "number" and cap or DEFAULT_MAX_CREATED
  typeRecord.created = pool:GetCreatedCount()
  typeRecord.discarded = pool:GetDiscardedCount()
  typeRecord.trusted = typeRecord.trusted == true
  typeRecord.pool = nil
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
  if type(options) ~= "nil" then
    validateOptionKeys(options, TYPE_OPTION_KEYS, "WidgetKit:RegisterType options", 3)
    if type(options.maxCreated) ~= "nil" then
      -- Before any comparison: a secret compared with a number raises.
      refuseSecret(options.maxCreated, "WidgetKit:RegisterType options.maxCreated", 3)
      if options.maxCreated == UNBOUNDED then
        error(
          "WidgetKit:RegisterType options.maxCreated cannot be WidgetKit.UNBOUNDED:"
            .. " the client never frees a frame",
          2
        )
      end
      validatePositiveInteger(options.maxCreated, "WidgetKit:RegisterType options.maxCreated", 3)
      if options.maxCreated > ceiling then
        error(
          "WidgetKit:RegisterType options.maxCreated must be at most "
            .. ceiling
            .. " (WidgetKit:SetLimits maxCreatedCeiling)",
          2
        )
      end
      maxCreated = options.maxCreated --[[@as integer]]
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
    -- A custom constructor replacing WidgetKit's own is not trusted.
    typeRecord.trusted = false
    raiseTypeVersion(typeRecord, constructor, version, maxCreated, maxCallbacks)
    return true
  end

  types[name] = newTypeRecord(name, constructor, version, maxCreated, maxCallbacks)
  return true
end

---Register one of WidgetKit's own types for the part that ships it. Unlike
---`RegisterType`, an equal version takes this constructor, so the older copy
---of the part that registered it is no longer referenced (no upgrade residue);
---the widgets that copy built keep its methods, which behave the same at the
---same version. A higher version registered by anyone else is kept. The type
---is trusted: its `OnAcquire` and `OnRelease` run without `pcall`.
---@param name string
---@param constructor function
---@param version integer
local function registerBuiltInType(name, constructor, version)
  local typeRecord = types[name]
  if typeRecord == nil then
    typeRecord = newTypeRecord(name, constructor, version, DEFAULT_MAX_CREATED, MAX_CALLBACKS)
    typeRecord.trusted = true
    types[name] = typeRecord
    return
  end
  if version < typeRecord.version then
    return
  end
  typeRecord.trusted = true
  if version == typeRecord.version then
    typeRecord.constructor = constructor
    return
  end
  raiseTypeVersion(
    typeRecord,
    constructor,
    version,
    DEFAULT_MAX_CREATED,
    typeRecord.maxCallbacks or MAX_CALLBACKS
  )
end

---@param name string
---@return integer? version
local function getTypeVersion(self, name)
  validateFacade(self, "WidgetKit:GetTypeVersion", 3)
  -- Indexed before the name is checked: a secret name meets the client's own
  -- refusal at the index (ADR 0002), and a registered name needs no check.
  local typeRecord = types[name]
  if typeRecord ~= nil then
    return typeRecord.version
  end
  validateName(name, "WidgetKit:GetTypeVersion name", 3)
  return nil
end

---The message of a member whose part is not loaded.
---@param memberText string what the caller used, such as `WidgetKit:RenderOptions`
---@param partName string
---@return string
local function missingPartMessage(memberText, partName)
  return memberText
    .. " is in WidgetKit's "
    .. partName
    .. " part, which is not loaded: add widgetKit\\parts\\WidgetKit-"
    .. partName
    .. ".lua to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
end

---Build a new widget for `Create`: `nil` when the type is at its cap.
---@param typeRecord table
---@return table|nil widget
local function buildForCreate(typeRecord)
  if typeRecord.free == nil then
    typeRecord.free = {}
  end
  if typeRecord.created >= typeRecord.maxCreated then
    return nil
  end
  local ok, widget = pcall(buildWidget, typeRecord)
  if not ok then
    local problem = state.buildProblem
    state.buildProblem = nil
    if problem ~= nil then
      error("WidgetKit:Create " .. problem, 3)
    end
    -- The constructor itself raised: its error is passed on unchanged.
    error(widget, 0)
  end
  typeRecord.created = typeRecord.created + 1
  return widget
end

---Acquire a widget of type `name`.
---@param name string
---@return WidgetKit.Widget|nil widget
---@return string? reason `"unknownType"` or `"exhausted"`
local function create(self, name)
  -- `validateFacade` and `validateName`, inlined: this is the hot half of
  -- every widget's use. The name is indexed before it is checked: a secret
  -- name meets the client's own refusal at the index (ADR 0002), and a
  -- registered name needs no further check.
  if self ~= WidgetKit then
    error("WidgetKit:Create must be called on the WidgetKit facade", 2)
  end
  local typeRecord = types[name]
  if typeRecord == nil then
    if type(name) ~= "string" or name == "" then
      error("WidgetKit:Create name must be a non-empty string", 2)
    end
    local partName = BASE_TYPE_PARTS[name]
    if partName ~= nil then
      error(missingPartMessage("WidgetKit:Create " .. name, partName), 2)
    end
    return nil, "unknownType"
  end

  -- An idle widget when there is one; a new one otherwise. Only building
  -- runs protected: taking an idle widget calls nothing.
  local free = typeRecord.free
  local count = free ~= nil and #free or 0
  local widget
  if count > 0 then
    widget = free[count]
    free[count] = nil
  else
    widget = buildForCreate(typeRecord)
    if widget == nil then
      return nil, "exhausted"
    end
  end

  -- `buildWidget` and `releaseWidget` leave every other field of the record
  -- at its default, so acquiring only marks it active and counts it.
  -- `state` has no metatable, so plain indexing reads and writes the same
  -- fields `rawget` and `rawset` would, without a C call each.
  local record = records[widget]
  record.active = true
  local serial = (state.serial or 0) + 1
  state.serial = serial
  record.serial = serial
  local borrowed = typeRecord.borrowed
  local version = record.version
  borrowed[version] = (borrowed[version] or 0) + 1

  -- The constructor checked that `OnAcquire` is a function or absent. A
  -- trusted type's hook is WidgetKit's own and runs unprotected.
  local onAcquire = rawget(widget, "OnAcquire")
  if onAcquire ~= nil then
    if typeRecord.trusted then
      onAcquire(widget)
    else
      local acquired, failure = pcall(onAcquire, widget)
      if not acquired then
        releaseWidget(widget, record)
        error(failure, 0)
      end
    end
  end
  widget.frame:Show()
  return widget
end

---Release `widget`: see `releaseWidget`.
---@param widget WidgetKit.Widget
---@return true
local function release(self, widget)
  if self ~= WidgetKit then
    error("WidgetKit:Release must be called on the WidgetKit facade", 2)
  end
  local record = records[widget]
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
  local record = records[self]
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
  local record = records[value]
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
  -- The widget is an argument here, not the receiver: worded as `Release`
  -- words it.
  local record = records[widget]
  if record == nil then
    error("WidgetKit:SetFocus widget must be a WidgetKit widget", 2)
  end
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
    local active = 0
    for _, count in next, typeRecord.borrowed do
      active = active + count
    end
    local free = typeRecord.free
    local row = {
      version = typeRecord.version,
      maxCreated = typeRecord.maxCreated,
      created = typeRecord.created,
      active = active,
      available = free ~= nil and #free or 0,
      discarded = typeRecord.discarded,
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

---Change any subset of the package-wide limits: `maxCreatedCeiling`,
---`maxDropdownEntries` and `maxListElements`. Every entry is validated before anything changes;
---affects every consumer in the session. Caps already given to registered
---types, and lists already set, are kept.
---@param limits WidgetKit.Limits
local function setLimits(self, limits)
  validateFacade(self, "WidgetKit:SetLimits", 3)
  if type(limits) ~= "table" then
    error("WidgetKit:SetLimits limits must be a table", 2)
  end
  local key = next(limits)
  while type(key) ~= "nil" do
    if key ~= "maxCreatedCeiling" and key ~= "maxDropdownEntries" and key ~= "maxListElements" then
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
  -- sentinel or a bound: comparing a secret with a number bound raises.

  -- `maxDropdownEntries`: a positive integer or `WidgetKit.UNBOUNDED`, since
  -- the entries are the consumer's own keys and labels, not frames.
  local dropdownEntries = rawget(limits, "maxDropdownEntries")
  if type(dropdownEntries) ~= "nil" then
    validateLimitOrUnbounded(dropdownEntries, "WidgetKit:SetLimits limits.maxDropdownEntries", 3)
  end
  -- `maxListElements`: the same, since elements are the consumer's tables.
  local listElements = rawget(limits, "maxListElements")
  if type(listElements) ~= "nil" then
    validateLimitOrUnbounded(listElements, "WidgetKit:SetLimits limits.maxListElements", 3)
  end
  local ceiling = rawget(limits, "maxCreatedCeiling")
  refuseSecret(ceiling, "WidgetKit:SetLimits limits.maxCreatedCeiling", 3)
  if type(ceiling) == "nil" then
    if type(dropdownEntries) ~= "nil" then
      rawset(rawget(state, "limits"), "maxDropdownEntries", dropdownEntries)
    end
    if type(listElements) ~= "nil" then
      rawset(rawget(state, "limits"), "maxListElements", listElements)
    end
    return
  end
  if ceiling == UNBOUNDED then
    error(
      "WidgetKit:SetLimits limits.maxCreatedCeiling cannot be WidgetKit.UNBOUNDED:"
        .. " the client never frees a frame",
      2
    )
  end
  if
    type(ceiling) ~= "number"
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
  if type(listElements) ~= "nil" then
    rawset(rawget(state, "limits"), "maxListElements", listElements)
  end
end

---Return a fresh copy of the package-wide limits.
---@return WidgetKit.Limits
local function getLimits(self)
  validateFacade(self, "WidgetKit:GetLimits", 3)
  return {
    maxCreatedCeiling = rawget(rawget(state, "limits"), "maxCreatedCeiling"),
    maxDropdownEntries = rawget(rawget(state, "limits"), "maxDropdownEntries"),
    maxListElements = rawget(rawget(state, "limits"), "maxListElements"),
  }
end

-- Widget helpers -------------------------------------------------------------
--
-- The base widgets below follow the author contract in `docs/API.md` like any
-- other widget type: a constructor that builds frames once, `OnAcquire` that
-- sets every default, `OnRelease` that clears every text and texture, and
-- methods stored on the widget table. Methods are shared functions defined
-- once here; script handlers are closures made once per widget, at
-- construction, because the widget is pooled for the session.
--
-- Two client facts measured on Retail 12.1.0 b69933 (2026-09-25) shape the
-- text code. The main chunk is near Lua's limit of 200 active locals, so the
-- first is applied inline by every getter and the second by the one shared
-- helper, `showText` (it took the place of a `setShown` helper, replaced by
-- the client's own `SetShown`):
--
--   * a font string or button answers `GetText()` with `nil`, not `""`, for
--     an empty text, so every text getter turns `nil` into `""`;
--   * a font string that showed a secret keeps secret measurements for good:
--     `SetText("")` leaves its text secret too, and `ClearText` makes the text
--     plain again but not `GetStringWidth` or `GetStringHeight` (a reused
--     `Label` measured a plain text as a secret after `ClearText`). So every
--     text a text setter may give a secret goes through `showText`, which
--     shows secrets on a font string of its own and never a plain text there.

-- Colours a widget draws its text and chrome in.
-- One table rather than nine locals, to spare main-chunk locals; the parts
-- bind the numbers to locals of their own.
local COLOURS = {
  label = { 1, 0.82, 0 },
  text = { 1, 1, 1 },
  disabled = { 0.5, 0.5, 0.5 },
}

---Check that `widget` is active and the text it is asked to display.
---
---`nil` clears; a string or number is shown; a secret value is refused unless
---`options.allowSecret` is `true`. A font string can display a secret, but
---whether one should appear is the caller's decision (`docs/EMBEDDING.md`).
---
---The widget is checked here, as `activeRecord` would with the same messages,
---so a text setter makes one call for all its checks: text setters run for
---every text an options dialog shows.
---@param widget any
---@param text any
---@param options any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return string|number text
---@return boolean secret
local function checkText(widget, text, options, methodName, level)
  local record = records[widget]
  if record == nil then
    error(methodName .. " must be called on a WidgetKit widget", level)
  end
  if not record.active then
    error(methodName .. " cannot be called on a released widget", level)
  end
  local allowSecret = false
  if type(options) ~= "nil" then
    validateOptionKeys(options, TEXT_OPTION_KEYS, methodName .. " options", level + 1)
    -- Before `== true`: a secret boolean compared with a boolean raises.
    refuseSecret(options.allowSecret, methodName .. " options.allowSecret", level + 1)
    allowSecret = options.allowSecret == true
  end
  -- The probe rule, inlined (see `isSecret`).
  local probe = loadedProbe
  if probe == nil then
    -- selene: allow(global_usage)
    probe = rawget(_G, "issecretvalue")
    if probe ~= nil and type(probe) ~= "function" then
      probe = nil
    end
  end
  if probe ~= nil and probe(text) == true then
    if not allowSecret then
      error(
        methodName .. " text must not be a secret value unless options.allowSecret is true",
        level
      )
    end
    return text, true
  end
  -- One `type` call answers all three questions; a string is the common case.
  local kind = type(text)
  if kind == "string" or kind == "number" then
    return text, false
  end
  if kind == "nil" then
    return "", false
  end
  error(methodName .. " text must be a string, a number or nil", level)
end

---Show a checked text in the widget's text slot `key`: the field (`text`,
---`titleText` or `labelText`) naming the region that shows the text now.
---
---A plain text is shown by the region the constructor built, a font string
---or, for a `Button`, the button itself. A secret text is shown by a second
---font string, created on the slot's first secret and kept for the widget's
---life: a font string that showed a secret keeps secret measurements after
---`ClearText` (Retail 12.1.0 b69933, 2026-09-25), so it must never show a
---plain text again, and reusing it for every later secret bounds the cost at
---one font string per slot however often a secret comes back. The client
---never frees a font string, so a new one per secret would grow for the
---session.
---
---`widget[key]` always names the region showing the text, so a widget's own
---setters and getters reach the right one. At each switch the text leaves the
---other region (the secret one also gets `ClearText` and is hidden) and the
---font object, justification, colour and word wrap move with it; anchors are
---copied once, when the secret font string is made. A `Button`'s own text
---keeps the button's styling, and its secret font string starts from it.
---@param widget table
---@param key string
---@param value string|number
---@param secret boolean
local function showText(widget, key, value, secret)
  -- `_secretTexts` and its slots are WidgetKit's own tables, so absence is
  -- tested with `== nil` (the nil rule's exception) rather than a `type` call.
  local slots = widget._secretTexts
  if slots == nil then
    if not secret then
      widget[key]:SetText(value)
      return
    end
    slots = {}
    widget._secretTexts = slots
  end
  local slot = slots[key]
  if slot == nil then
    if not secret then
      widget[key]:SetText(value)
      return
    end
    local plain = widget[key]
    local parent, source = plain, plain
    if plain:GetObjectType() == "Button" then
      source = plain:GetFontString()
    else
      parent = plain:GetParent()
    end
    local secretText = parent:CreateFontString(nil, "OVERLAY")
    local points = source:GetNumPoints()
    for index = 1, points do
      secretText:SetPoint(source:GetPoint(index))
    end
    if points == 0 then
      secretText:SetPoint("CENTER", parent, "CENTER", 0, 0)
    end
    secretText:Hide()
    slot = { plain = plain, secret = secretText }
    slots[key] = slot
  end

  local current = widget[key]
  local target = secret and slot.secret or slot.plain
  if current ~= target then
    local source = current
    if current:GetObjectType() == "Button" then
      source = current:GetFontString()
    end
    if target:GetObjectType() ~= "Button" then
      local fontObject = source:GetFontObject()
      if type(fontObject) ~= "nil" then
        target:SetFontObject(fontObject)
      end
      target:SetJustifyH(source:GetJustifyH())
      target:SetTextColor(source:GetTextColor())
      target:SetWordWrap(source:CanWordWrap())
    end
    current:SetText("")
    if current == slot.secret then
      if type(current.ClearText) == "function" then
        current:ClearText()
      end
      current:Hide()
    else
      target:Show()
    end
    widget[key] = target
  end
  target:SetText(value)
end

---Whether `widget` is still an active widget; script handlers check this
---before they act, since a host script can outlive a release by a frame.
---@param widget table
---@return boolean
local function isActive(widget)
  local record = records[widget]
  return record ~= nil and record.active == true
end

---Validate a `SetDisabled` argument.
---@param widget any
---@param disabled any
---@param methodName string qualified public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return boolean disabled
local function readDisabled(widget, disabled, methodName, level)
  activeRecord(widget, methodName, level + 1)
  -- `type` answers "boolean" for a secret boolean; `== true` would raise.
  refuseSecret(disabled, methodName .. " disabled", level + 1)
  if type(disabled) ~= "nil" and type(disabled) ~= "boolean" then
    error(methodName .. " disabled must be a boolean", level)
  end
  return disabled == true
end

---Colour a label font string for the enabled or disabled state.
---@param fontString WidgetKit.Frame
---@param disabled boolean
local function colourLabel(fontString, disabled)
  if disabled then
    local colour = COLOURS.disabled
    fontString:SetTextColor(colour[1], colour[2], colour[3])
  else
    local colour = COLOURS.label
    fontString:SetTextColor(colour[1], colour[2], colour[3])
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

---Build the `SetLabel` and `GetLabel` of a widget type whose label is
---`widget.labelText`. Built once per type, so their errors name the type as
---every other type method does (`WidgetKit CheckBox:SetLabel`).
---@param typeName string
---@return fun(self: table, text: any, options: WidgetKit.TextOptions?) setLabel
---@return fun(self: table): any getLabel
local function newLabelMethods(typeName)
  local setLabelName = "WidgetKit " .. typeName .. ":SetLabel"
  local getLabelName = "WidgetKit " .. typeName .. ":GetLabel"

  ---@param text any
  ---@param options WidgetKit.TextOptions?
  local function setLabel(self, text, options)
    local value, secret = checkText(self, text, options, setLabelName, 3)
    showText(self, "labelText", value, secret)
  end

  ---@return any
  local function getLabel(self)
    activeRecord(self, getLabelName, 3)
    local text = self.labelText:GetText()
    if type(text) == "nil" then
      return ""
    end
    return text
  end

  return setLabel, getLabel
end

-- Parts ----------------------------------------------------------------------
--
-- A part (`parts/WidgetKit-<Part>.lua`) registers its widget types through
-- `registerBuiltInType`, installs the facade and prototype members it
-- provides, and records itself in `state.parts` as `{ revision, bind }`. It
-- reaches the core through `state.helpers`: `bind(helpers)` assigns the
-- part's own locals from that table, and every newer core calls each loaded
-- part's `bind` again, so a part always runs the newest core's helpers with
-- no lookup per call and no older helper kept alive. `state.helpers` only
-- grows inside API 1: a helper's arguments and meaning never change, and a
-- change is a new name. See `docs/INTERNALS.md`, "Parts".

---The installed revision of a part, or `nil` when it is not loaded.
---@param partName string
---@return integer? revision
local function getPartRevision(self, partName)
  validateFacade(self, "WidgetKit:GetPartRevision", 3)
  validateName(partName, "WidgetKit:GetPartRevision partName", 3)
  local part = parts[partName]
  if type(part) ~= "table" then
    return nil
  end
  return part.revision
end

-- Commit ---------------------------------------------------------------------

-- What every part binds to. Functions and shared tables only; see "Parts".
rawset(helpers, "WidgetKit", WidgetKit)
rawset(helpers, "Registry", Registry)
rawset(helpers, "findPackage", findPackage)
rawset(helpers, "state", state)
rawset(helpers, "dispatch", dispatch)
rawset(helpers, "records", records)
rawset(helpers, "parts", parts)
rawset(helpers, "UNBOUNDED", UNBOUNDED)
rawset(helpers, "WEAK_KEYS", WEAK_KEYS)
rawset(helpers, "WidgetBase", WidgetBase)
rawset(helpers, "AnchorFunctions", AnchorFunctions)
rawset(helpers, "BindingPrototype", BindingPrototype)
rawset(helpers, "RenderingPrototype", RenderingPrototype)
rawset(helpers, "BINDING_METATABLE", BINDING_METATABLE)
rawset(helpers, "RENDERING_METATABLE", RENDERING_METATABLE)
rawset(helpers, "colours", COLOURS)
rawset(helpers, "reportError", reportError)
rawset(helpers, "isSecret", isSecret)
rawset(helpers, "secretProbe", secretProbe)
rawset(helpers, "canTouchFrame", canTouchFrame)
rawset(helpers, "createFrame", createFrame)
rawset(helpers, "restingParent", restingParent)
rawset(helpers, "releaseParent", releaseParent)
rawset(helpers, "validateFacade", validateFacade)
rawset(helpers, "validateName", validateName)
rawset(helpers, "validateNumber", validateNumber)
rawset(helpers, "validatePositiveInteger", validatePositiveInteger)
rawset(helpers, "validateOptionKeys", validateOptionKeys)
rawset(helpers, "capacityOf", capacityOf)
rawset(helpers, "refuseSecret", refuseSecret)
rawset(helpers, "activeRecord", activeRecord)
rawset(helpers, "isReleasingRecord", isReleasingRecord)
rawset(helpers, "performLayout", performLayout)
rawset(helpers, "acquireScratch", acquireScratch)
rawset(helpers, "releaseScratch", releaseScratch)
rawset(helpers, "checkText", checkText)
rawset(helpers, "showText", showText)
rawset(helpers, "isActive", isActive)
rawset(helpers, "readDisabled", readDisabled)
rawset(helpers, "colourLabel", colourLabel)
rawset(helpers, "newTopLabel", newTopLabel)
rawset(helpers, "newLabelMethods", newLabelMethods)
rawset(helpers, "registerBuiltInType", registerBuiltInType)
rawset(helpers, "missingPartMessage", missingPartMessage)

-- Revision 13 and older built and retired widgets through PoolKit pool
-- callbacks that called these entries. The pools are adopted below, so the
-- entries go, and the older copy's functions with them.
rawset(dispatch, "build", nil)
rawset(dispatch, "retire", nil)
for _, typeRecord in next, types do
  adoptPool(typeRecord)
end

-- Built-in layouts are this package's own, so each copy installs its own
-- functions over whatever an older copy registered under the same names.
layouts[LAYOUT_LIST] = listLayout
layouts.Fill = fillLayout
layouts.Flow = flowLayout

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
rawset(WidgetKit, "GetPartRevision", getPartRevision)

---Install a stand-in for every part member no part or older revision
---provides, replacing earlier stand-ins.
local function installStandIns()
  -- Every member a part provides, as `{ table, key, part, label }`. Until the
  -- part loads, the member is a stand-in that raises at the caller's line with
  -- the file to embed, so the facade and the shared prototypes always expose
  -- the whole API 1 surface (an older copy that yields to this one checks it).
  local PART_MEMBERS = {
    { WidgetKit, "RenderOptions", "Renderer", "WidgetKit:RenderOptions" },
    { WidgetKit, "CreateMediaPicker", "Dropdown", "WidgetKit:CreateMediaPicker" },
    { WidgetKit, "BindPosition", "Position", "WidgetKit:BindPosition" },
    { AnchorFunctions, "FromRect", "Position", "WidgetKit.Anchor.FromRect" },
    { AnchorFunctions, "Normalize", "Position", "WidgetKit.Anchor.Normalize" },
    { AnchorFunctions, "Apply", "Position", "WidgetKit.Anchor.Apply" },
    { AnchorFunctions, "Read", "Position", "WidgetKit.Anchor.Read" },
    { BindingPrototype, "Capture", "Position", "WidgetKit.Binding:Capture" },
    { BindingPrototype, "Restore", "Position", "WidgetKit.Binding:Restore" },
    { BindingPrototype, "Flush", "Position", "WidgetKit.Binding:Flush" },
    { BindingPrototype, "OnMoved", "Position", "WidgetKit.Binding:OnMoved" },
    { BindingPrototype, "Release", "Position", "WidgetKit.Binding:Release" },
    { BindingPrototype, "IsReleased", "Position", "WidgetKit.Binding:IsReleased" },
    { RenderingPrototype, "Refresh", "Renderer", "WidgetKit.Rendering:Refresh" },
    { RenderingPrototype, "Rebuild", "Renderer", "WidgetKit.Rendering:Rebuild" },
    { RenderingPrototype, "Release", "Renderer", "WidgetKit.Rendering:Release" },
    { RenderingPrototype, "IsReleased", "Renderer", "WidgetKit.Rendering:IsReleased" },
    { RenderingPrototype, "GetWidget", "Renderer", "WidgetKit.Rendering:GetWidget" },
    { RenderingPrototype, "GetMessage", "Renderer", "WidgetKit.Rendering:GetMessage" },
  }

  -- Stand-ins this or an earlier core installed, so a newer core replaces them
  -- (an older stand-in would keep the older core alive) and never mistakes one
  -- for a part's member. Weak-keyed: a stand-in a part replaced is not kept.
  local standIns = rawget(state, "standIns")
  if standIns == nil then
    standIns = setmetatable({}, WEAK_KEYS)
    rawset(state, "standIns", standIns)
  end

  ---A function that raises the not-loaded message at its caller's line.
  ---@param label string
  ---@param partName string
  ---@return function standIn
  local function newStandIn(label, partName)
    local message = missingPartMessage(label, partName)
    local function standIn()
      error(message, 2)
    end
    standIns[standIn] = true
    return standIn
  end

  -- A part's member, or one an older single-file revision installed, is kept;
  -- an empty slot or an earlier stand-in gets this core's stand-in.
  for index = 1, #PART_MEMBERS do
    local row = PART_MEMBERS[index]
    local current = rawget(row[1], row[2])
    if current == nil or standIns[current] then
      rawset(row[1], row[2], newStandIn(row[4], row[3]))
    end
  end
end

installStandIns()

-- Parts loaded before this core run its helpers from now on.
for _, part in next, parts do
  if type(part) == "table" and type(part.bind) == "function" then
    part.bind(helpers)
  end
end

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(WidgetKit) or not validateCurrentState(WidgetKit) then
  error("MoltenCodes WidgetKit package state is corrupted or incomplete", 2)
end

return WidgetKit
