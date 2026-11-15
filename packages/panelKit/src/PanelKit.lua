-- MoltenCodes PanelKit
--
-- An addon's OptionsKit tree in Blizzard's settings panel (the AddOns tab),
-- as a category or a subcategory of one: what Ace3's
-- `AceConfigDialog:AddToBlizOptions` does. PanelKit wraps Blizzard's Settings
-- API instead of drawing a panel of its own: `Settings.RegisterCanvasLayoutCategory`,
-- `Settings.RegisterCanvasLayoutSubcategory`, `Settings.RegisterAddOnCategory`
-- and `Settings.OpenToCategory`, which Retail, Mists of Pandaria Classic and
-- Classic Era ship with the same code.
--
-- Each panel owns one plain frame, the canvas Blizzard shows on its page.
-- Nothing is drawn while the page is hidden: when Blizzard shows the canvas,
-- PanelKit acquires a WidgetKit `ScrollFrame` and renders the tree into it
-- with `WidgetKit:RenderOptions`; when it hides the canvas, every widget goes
-- back to its pool. The tree is looked up by name with `OptionsKit:Get` each
-- time, so a tree defined again is picked up at the next show.
--
-- Blizzard cannot unregister a category and the client never frees a frame,
-- so a panel lives for the session and `maxPanels` has a ceiling instead of
-- an `UNBOUNDED` opt-out.
--
-- PanelKit requires Registry API 2, WidgetKit API 1 and OptionsKit API 1. It
-- reads three host facilities at call time: `Settings` (`Register` refuses
-- without it), `issecretvalue` (without it nothing is secret) and
-- `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, layout
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, WidgetKit, OptionsKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, Settings
--   Argument checks ....... receivers, names, options, limits
--   Drawing ............... what a page shows, and when
--   Panel methods ......... Open, GetName, GetCategoryID, GetRendering, SetDefaultHandler
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "panelKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local REQUIRED_WIDGETKIT_API = 1
local REQUIRED_OPTIONSKIT_API = 1
local STATE_SCHEMA = 1

-- Every panel record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The default of the `maxPanels` limit: the most panels the session holds,
-- subcategories included. An addon registers one page or a handful, so this
-- only stops a loop that registers without end.
local MAX_PANELS = 64

-- The highest `maxPanels` accepts. Each panel is a frame and a category the
-- session keeps until logout; there is no unbounded setting.
local PANELS_CEILING = 1024

-- The space between the canvas Blizzard gives a page and the scroll frame
-- PanelKit draws in it, in pixels.
local CANVAS_INSET = 8

-- The limits `SetLimits` accepts.
local LIMIT_NAMES = { "maxPanels" }

-- The options `Register` accepts.
local REGISTER_OPTIONS = { name = true, parent = true }

-- What `Open` answers when the client cannot open its settings panel.
local REASON_UNAVAILABLE = "unavailable"

-- The `__metatable` of every panel handle. It hides the handle's metatable.
local PANEL_METATABLE_TAG = "PanelKit.Panel"

local FACADE_METHODS = { "Register", "Get", "SetLimits", "GetLimits" }
local PANEL_METHODS = { "Open", "GetName", "GetCategoryID", "GetRendering", "SetDefaultHandler" }

-- Public types ---------------------------------------------------------------

---The options of `PanelKit:Register`.
---@class PanelKit.RegisterOptions
---@field name string? The title in the settings list; default the tree's name.
---@field parent PanelKit.Panel? A panel to place this one under, as a subcategory.

---Called by the page's Defaults button, with the panel.
---@alias PanelKit.DefaultHandler fun(panel: PanelKit.Panel)

---One page in Blizzard's settings panel.
---@class PanelKit.Panel
---@field Open fun(self: PanelKit.Panel): true|nil, string?
---@field GetName fun(self: PanelKit.Panel): string
---@field GetCategoryID fun(self: PanelKit.Panel): any
---@field GetRendering fun(self: PanelKit.Panel): WidgetKit.Rendering?
---@field SetDefaultHandler fun(self: PanelKit.Panel, callback: PanelKit.DefaultHandler?)

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class PanelKit.Limits
---@field maxPanels integer Most panels the session holds, subcategories included: 1 to 1024; default `64`.

---The PanelKit package facade published through Registry.
---@class PanelKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_PANELS integer Default of the `maxPanels` limit (`64`).
---@field PANELS_CEILING integer The highest `maxPanels` accepts (`1024`).
---@field Register fun(self: PanelKit, treeName: string, options: PanelKit.RegisterOptions?): PanelKit.Panel
---@field Get fun(self: PanelKit, name: string, parent: PanelKit.Panel?): PanelKit.Panel?
---@field SetLimits fun(self: PanelKit, limits: PanelKit.Limits)
---@field GetLimits fun(self: PanelKit): PanelKit.Limits

---Everything PanelKit keeps per panel. Private.
---@class PanelKit.Record
---@field schema integer
---@field name string the title in the settings list
---@field treeName string the OptionsKit name the page draws
---@field parent PanelKit.Record|false the record of the panel above a subcategory
---@field children table<string, PanelKit.Record> subcategories by name
---@field panel PanelKit.Panel the handle consumers hold
---@field frame table the canvas Blizzard shows on this page
---@field category table the category Blizzard returned
---@field categoryID any the ID `Settings.OpenToCategory` takes
---@field defaultHandler PanelKit.DefaultHandler|false
---@field scroll table|false the WidgetKit `ScrollFrame` while the page is shown
---@field tree table|false the OptionsKit tree drawn while the page is shown
---@field rendering table|false the WidgetKit rendering while the page is shown

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
  error("MoltenCodes PanelKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes PanelKit requires a valid Registry API 2 facade", 2)
end

-- WidgetKit draws every page; OptionsKit holds the trees by name.
local WidgetKit = getPackage(Registry, "widgetKit", REQUIRED_WIDGETKIT_API)
if
  type(WidgetKit) ~= "table"
  or rawget(WidgetKit, "API") ~= REQUIRED_WIDGETKIT_API
  or type(rawget(WidgetKit, "RenderOptions")) ~= "function"
then
  error("MoltenCodes PanelKit requires WidgetKit API 1 to be loaded first", 2)
end

local OptionsKit = getPackage(Registry, "optionsKit", REQUIRED_OPTIONSKIT_API)
if
  type(OptionsKit) ~= "table"
  or rawget(OptionsKit, "API") ~= REQUIRED_OPTIONSKIT_API
  or type(rawget(OptionsKit, "Get")) ~= "function"
then
  error("MoltenCodes PanelKit requires OptionsKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete PanelKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
  then
    return false
  end
  for index = 1, #FACADE_METHODS do
    if type(rawget(implementation, FACADE_METHODS[index])) ~= "function" then
      return false
    end
  end
  return true
end

---Whether `value` is an exact integer from 1 to the ceiling. `nan` fails
---every comparison.
---@param value any
---@return boolean
local function isPanelLimit(value)
  return type(value) == "number" and value >= 1 and value <= PANELS_CEILING and value % 1 == 0
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and type(limits) == "table"
    and isPanelLimit(rawget(limits, "maxPanels"))
    and type(rawget(currentState, "panels")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "frames")) == "table"
    and type(rawget(currentState, "panelCount")) == "number"
    and type(rawget(currentState, "panelPrototype")) == "table"
    and type(rawget(currentState, "panelMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "onShow")) == "function"
    and type(rawget(currentState, "onHide")) == "function"
    and type(rawget(currentState, "onRefresh")) == "function"
    and type(rawget(currentState, "onDefault")) == "function"
end

---Whether `implementation` carries package state of this revision's schema.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  return validateStateBase(rawget(implementation, "_state"))
end

-- Bootstrap ------------------------------------------------------------------

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only PanelKit can answer.
local PanelKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes PanelKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if PanelKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(PanelKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes PanelKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The canvas frames hold the
  -- closures below as their scripts and fields, which cannot be replaced
  -- once Blizzard has the frame, so they look their behaviour up here.
  local dispatch = {}
  local panelPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxPanels = MAX_PANELS },
    -- Top-level panels by name; subcategories live in their parent's
    -- `children`. Panels live for the session.
    panels = {},
    -- Panel handle to its record, and canvas frame to its record.
    records = {},
    frames = {},
    panelCount = 0,
    -- The methods every handle reaches through its metatable, rewritten by
    -- every loading revision.
    panelPrototype = panelPrototype,
    panelMetatable = { __index = panelPrototype, __metatable = PANEL_METATABLE_TAG },
    dispatch = dispatch,
    -- The canvas scripts (`OnShow`, `OnHide`) and the fields Blizzard's panel
    -- calls on a canvas (`OnRefresh`, `OnDefault`).
    onShow = function(frame)
      dispatch.show(frame)
    end,
    onHide = function(frame)
      dispatch.hide(frame)
    end,
    onRefresh = function(frame)
      dispatch.refresh(frame)
    end,
    onDefault = function(frame)
      dispatch.default(frame)
    end,
  }
  rawset(PanelKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes PanelKit package state is corrupted or incomplete", 2)
end

---@type table<string, PanelKit.Record>
local panels = rawget(state, "panels")
---@type table<table, PanelKit.Record>
local records = rawget(state, "records")
---@type table<table, PanelKit.Record>
local frames = rawget(state, "frames")
local dispatch = rawget(state, "dispatch")
local PanelPrototype = rawget(state, "panelPrototype")
local PANEL_METATABLE = rawget(state, "panelMetatable")
local sharedLimits = rawget(state, "limits")

-- Host facilities ------------------------------------------------------------

---Whether `value` is a secret value (Retail 12.x). `issecretvalue` is looked
---up at every call, so a probe that appears after load is used at once.
---@param value any
---@return boolean
local function isSecret(value)
  local probe = readGlobal("issecretvalue")
  return type(probe) == "function" and probe(value) == true
end

---Hand `failure` to the host error handler, the way the client reports a
---script error, without raising. Outside a client it is printed, as the
---client's own default handler would.
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
  print(failure)
end

---The client's `Settings` table when it has everything `Register` calls, or
---`nil`.
---@return table?
local function settingsApi()
  local settings = readGlobal("Settings")
  if
    type(settings) == "table"
    and type(settings.RegisterCanvasLayoutCategory) == "function"
    and type(settings.RegisterCanvasLayoutSubcategory) == "function"
    and type(settings.RegisterAddOnCategory) == "function"
  then
    return settings
  end
  return nil
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- PanelKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= PanelKit then
    error(label .. " must be called on the PanelKit facade; use " .. label .. "(...)", level)
  end
end

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

---The record of a panel handle, or `nil`. A secret is never a handle.
---@param value any
---@return PanelKit.Record?
local function recordOf(value)
  if isSecret(value) or type(value) ~= "table" then
    return nil
  end
  return records[value]
end

---The record of the panel a method was called on.
---@param receiver any
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return PanelKit.Record
local function requireRecord(receiver, label, level)
  local record = recordOf(receiver)
  if record == nil then
    error(
      label .. " must be called on a PanelKit panel; use panel:" .. label:match("[^:]+$") .. "(...)",
      level
    )
  end
  return record
end

---Check the options of `Register` and return the name and the parent record.
---@param options any
---@param treeName string
---@param level integer stack level the failure is reported at
---@return string name
---@return PanelKit.Record|false parent
local function readRegisterOptions(options, treeName, level)
  if type(options) == "nil" then
    return treeName, false
  end
  if isSecret(options) or type(options) ~= "table" then
    error("PanelKit:Register options must be a table or nil", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not REGISTER_OPTIONS[key] then
      error("PanelKit:Register options holds an unknown field; it accepts name and parent", level)
    end
  end
  local name = rawget(options, "name")
  if type(name) == "nil" then
    name = treeName
  else
    validateName(name, "PanelKit:Register options.name", level + 1)
  end
  local parentHandle = rawget(options, "parent")
  if type(parentHandle) == "nil" then
    return name, false
  end
  local parent = recordOf(parentHandle)
  if parent == nil then
    error("PanelKit:Register options.parent must be a PanelKit panel", level)
  end
  return name, parent
end

-- Drawing --------------------------------------------------------------------

---Release what the page shows: the scroll frame and, with it, the rendering
---and any message. Nothing is left on the canvas.
---@param record PanelKit.Record
local function clearPage(record)
  local scroll = record.scroll
  record.scroll = false
  record.tree = false
  record.rendering = false
  if scroll and WidgetKit:IsWidget(scroll) then
    WidgetKit:Release(scroll)
  end
end

---Put one line on the page in place of the tree.
---@param record PanelKit.Record
---@param scroll table
---@param text string
local function showMessage(record, scroll, text)
  local label = WidgetKit:Create("Label")
  if label == nil then
    reportError("PanelKit could not draw the page " .. record.name .. ": no Label is free")
    return
  end
  label:SetText(text)
  label:SetFullWidth(true)
  scroll:AddChild(label)
end

---Draw the page: a scroll frame on the canvas holding the tree, or a line
---saying no tree is defined. A failure is reported, never raised: the caller
---is Blizzard's panel.
---@param record PanelKit.Record
local function drawPage(record)
  local frame = record.frame
  local scroll = WidgetKit:Create("ScrollFrame")
  if scroll == nil then
    reportError("PanelKit could not draw the page " .. record.name .. ": no ScrollFrame is free")
    return
  end
  scroll:SetParent(frame)
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", CANVAS_INSET, -CANVAS_INSET)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -CANVAS_INSET, CANVAS_INSET)
  scroll:Show()
  record.scroll = scroll

  local tree = OptionsKit:Get(record.treeName)
  if tree == nil then
    showMessage(record, scroll, "No options are defined for " .. record.treeName .. ".")
    return
  end
  record.tree = tree
  local ok, rendering = pcall(WidgetKit.RenderOptions, WidgetKit, tree, scroll)
  if not ok then
    reportError(rendering)
    return
  end
  record.rendering = rendering
end

---`OnShow` of a canvas: draw its page.
---@param frame table
function dispatch.show(frame)
  local record = frames[frame]
  if record ~= nil and not record.scroll then
    drawPage(record)
  end
end

---`OnHide` of a canvas: give every widget back to its pool.
---@param frame table
function dispatch.hide(frame)
  local record = frames[frame]
  if record ~= nil then
    clearPage(record)
  end
end

---Blizzard's `OnRefresh`: read every value again, or draw the page again
---when the tree under its name is not the one drawn.
---@param frame table
function dispatch.refresh(frame)
  local record = frames[frame]
  if record == nil or not record.scroll then
    return
  end
  if OptionsKit:Get(record.treeName) ~= (record.tree or nil) then
    clearPage(record)
    drawPage(record)
  elseif record.rendering then
    record.rendering:Refresh()
  end
end

---Blizzard's `OnDefault`, from the Defaults button: run the panel's handler,
---reporting what it raises, then refresh what the page shows.
---@param frame table
function dispatch.default(frame)
  local record = frames[frame]
  if record == nil then
    return
  end
  local handler = record.defaultHandler
  if handler then
    local ok, failure = pcall(handler, record.panel)
    if not ok then
      reportError(failure)
    end
  end
  dispatch.refresh(frame)
end

-- Panel methods --------------------------------------------------------------

---Open Blizzard's settings panel on this page.
---@param self PanelKit.Panel
---@return true|nil opened
---@return string? reason `"unavailable"` when the client has no `Settings.OpenToCategory`
local function panelOpen(self)
  local record = requireRecord(self, "PanelKit.Panel:Open", 3)
  local settings = readGlobal("Settings")
  if type(settings) ~= "table" or type(settings.OpenToCategory) ~= "function" then
    return nil, REASON_UNAVAILABLE
  end
  settings.OpenToCategory(record.categoryID)
  return true
end

---The title this page has in the settings list.
---@param self PanelKit.Panel
---@return string
local function panelGetName(self)
  return requireRecord(self, "PanelKit.Panel:GetName", 3).name
end

---The ID Blizzard gave this page's category, as `Settings.OpenToCategory`
---takes it.
---@param self PanelKit.Panel
---@return any
local function panelGetCategoryID(self)
  return requireRecord(self, "PanelKit.Panel:GetCategoryID", 3).categoryID
end

---The WidgetKit rendering of the tree while the page is shown, or `nil`.
---@param self PanelKit.Panel
---@return table?
local function panelGetRendering(self)
  return requireRecord(self, "PanelKit.Panel:GetRendering", 3).rendering or nil
end

---Set, or with `nil` remove, what the page's Defaults button runs.
---@param self PanelKit.Panel
---@param callback PanelKit.DefaultHandler?
local function panelSetDefaultHandler(self, callback)
  local record = requireRecord(self, "PanelKit.Panel:SetDefaultHandler", 3)
  if type(callback) ~= "nil" and type(callback) ~= "function" then
    error("PanelKit.Panel:SetDefaultHandler callback must be a function or nil", 2)
  end
  record.defaultHandler = callback or false
end

-- Package public API ---------------------------------------------------------

---Register a page for the OptionsKit tree named `treeName` in Blizzard's
---settings panel, at the top of the AddOns list or under `options.parent`.
---@param self PanelKit
---@param treeName string
---@param options PanelKit.RegisterOptions?
---@return PanelKit.Panel
local function packageRegister(self, treeName, options)
  validateFacade(self, "PanelKit:Register", 3)
  validateName(treeName, "PanelKit:Register treeName", 3)
  local name, parent = readRegisterOptions(options, treeName, 3)
  local siblings = parent and parent.children or panels
  if siblings[name] ~= nil then
    error("PanelKit:Register a panel named " .. name .. " is already registered there", 2)
  end
  local maxPanels = rawget(sharedLimits, "maxPanels")
  if rawget(state, "panelCount") >= maxPanels then
    error(
      "PanelKit:Register holds at most "
        .. maxPanels
        .. " panels; raise maxPanels with PanelKit:SetLimits",
      2
    )
  end
  local settings = settingsApi()
  if settings == nil then
    error("PanelKit:Register needs the client's Settings API, which this host does not have", 2)
  end

  local frame = readGlobal("CreateFrame")("Frame")
  frame:Hide()
  frame:SetScript("OnShow", rawget(state, "onShow"))
  frame:SetScript("OnHide", rawget(state, "onHide"))
  frame.OnRefresh = rawget(state, "onRefresh")
  frame.OnDefault = rawget(state, "onDefault")

  local category
  if parent then
    category = settings.RegisterCanvasLayoutSubcategory(parent.category, frame, name)
  else
    category = settings.RegisterCanvasLayoutCategory(frame, name)
    settings.RegisterAddOnCategory(category)
  end

  local categoryID = category.ID
  if type(category.GetID) == "function" then
    categoryID = category:GetID()
  end

  local panel = setmetatable({}, PANEL_METATABLE)
  ---@type PanelKit.Record
  local record = {
    schema = RECORD_SCHEMA,
    name = name,
    treeName = treeName,
    parent = parent,
    children = {},
    panel = panel,
    frame = frame,
    category = category,
    categoryID = categoryID,
    defaultHandler = false,
    scroll = false,
    tree = false,
    rendering = false,
  }
  siblings[name] = record
  records[panel] = record
  frames[frame] = record
  rawset(state, "panelCount", rawget(state, "panelCount") + 1)
  return panel
end

---The panel registered as `name`, at the top or under `parent`, or `nil`.
---@param self PanelKit
---@param name string
---@param parent PanelKit.Panel?
---@return PanelKit.Panel?
local function packageGet(self, name, parent)
  validateFacade(self, "PanelKit:Get", 3)
  validateName(name, "PanelKit:Get name", 3)
  local siblings = panels
  if type(parent) ~= "nil" then
    local parentRecord = recordOf(parent)
    if parentRecord == nil then
      error("PanelKit:Get parent must be a PanelKit panel or nil", 2)
    end
    siblings = parentRecord.children
  end
  local record = siblings[name]
  return record and record.panel or nil
end

---Change any subset of the shared limits. Every value is checked before any
---changes. Lowering `maxPanels` keeps every panel and refuses the next one.
---@param self PanelKit
---@param limits PanelKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "PanelKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("PanelKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxPanels" then
      error("PanelKit:SetLimits limits holds an unknown field; it accepts maxPanels", 2)
    end
    if isSecret(value) then
      error("PanelKit:SetLimits limits.maxPanels must not be a secret value", 2)
    end
    if not isPanelLimit(value) then
      error(
        "PanelKit:SetLimits limits.maxPanels must be an integer from 1 to " .. PANELS_CEILING,
        2
      )
    end
  end
  for index = 1, #LIMIT_NAMES do
    local name = LIMIT_NAMES[index]
    local value = rawget(limits, name)
    if type(value) ~= "nil" then
      rawset(sharedLimits, name, value)
    end
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self PanelKit
---@return PanelKit.Limits limits
local function packageGetLimits(self)
  validateFacade(self, "PanelKit:GetLimits", 3)
  return { maxPanels = rawget(sharedLimits, "maxPanels") }
end

-- Commit ---------------------------------------------------------------------

rawset(PanelPrototype, "Open", panelOpen)
rawset(PanelPrototype, "GetName", panelGetName)
rawset(PanelPrototype, "GetCategoryID", panelGetCategoryID)
rawset(PanelPrototype, "GetRendering", panelGetRendering)
rawset(PanelPrototype, "SetDefaultHandler", panelSetDefaultHandler)

rawset(PanelKit, "API", API_GENERATION)
rawset(PanelKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(PanelKit, "MAX_PANELS", MAX_PANELS)
rawset(PanelKit, "PANELS_CEILING", PANELS_CEILING)
rawset(PanelKit, "Register", packageRegister)
rawset(PanelKit, "Get", packageGet)
rawset(PanelKit, "SetLimits", packageSetLimits)
rawset(PanelKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(PanelKit) or not validateCurrentState(PanelKit) then
  error("MoltenCodes PanelKit package state is corrupted or incomplete", 2)
end
for index = 1, #PANEL_METHODS do
  if type(rawget(PanelPrototype, PANEL_METHODS[index])) ~= "function" then
    error("MoltenCodes PanelKit package state is corrupted or incomplete", 2)
  end
end

return PanelKit
