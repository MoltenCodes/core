-- MoltenCodes MenuKit
--
-- Menus an addon describes as plain tables, shown by Blizzard's Menu API
-- (`Blizzard_Menu`, 11.0, which replaces the deprecated UIDropDownMenu): a
-- context menu at the cursor, the menu of a dropdown button, and entries an
-- addon adds to one of Blizzard's own tagged menus (`Menu.ModifyMenu`) and
-- can remove again. Blizzard draws every menu; MenuKit only describes it.
--
-- What MenuKit adds over calling `MenuUtil` directly: a menu is checked at the
-- caller's line (entry kinds, texts, callbacks, a secret refused), bounded in
-- size and depth, and every callback it hands Blizzard runs protected, so one
-- that raises is reported through the error handler and never breaks the
-- menu around it.
--
-- A menu is an array of entries, or a function returning one. A function is
-- called each time the menu opens, so a menu can show the state of that
-- moment; an array is read each time as well, so a change to it shows at the
-- next opening. Nothing is cached between openings.
--
-- MenuKit requires Registry API 2. It reads `MenuUtil` and `Menu` at call
-- time (every call raises at the caller without them) and `geterrorhandler`,
-- and `issecretvalue` once at load, again on each check only when the host
-- had none at load (without it nothing is secret).
--
-- Contents
-- --------
--   Constants ............. identity, limits, entry kinds and fields
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, Blizzard's menus
--   Argument checks ....... receivers, menus, owners, limits
--   Menu checks ........... one entry tree, answered as a message
--   Building .............. entries into Blizzard's element descriptions
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "menuKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- The default of the `maxEntries` limit: the most entries one menu holds,
-- every submenu's included. A menu longer than this is a list that wants a
-- scrolling window, not a menu.
local MAX_ENTRIES = 256

-- The default of the `maxDepth` limit: how many menus deep a submenu may
-- open. The root menu is depth 1.
local MAX_DEPTH = 4

-- The default and the ceiling of the `maxExtensions` limit: the most
-- extensions of Blizzard's tagged menus the session holds. Each is a
-- callback registered with Blizzard until it is removed.
local MAX_EXTENSIONS = 64
local EXTENSIONS_CEILING = 1024

-- The limits `SetLimits` accepts, in the order `GetLimits` reports them.
local LIMIT_NAMES = { "maxEntries", "maxDepth", "maxExtensions" }

-- Error-message stand-in for a value `issecretvalue` reports secret.
local SECRET_PLACEHOLDER = "<secret value>"

-- The fields each kind of entry accepts. Anything else is a typo, refused.
local KIND_FIELDS = {
  button = {
    kind = true,
    text = true,
    data = true,
    disabled = true,
    tooltip = true,
    onClick = true,
    entries = true,
  },
  checkbox = {
    kind = true,
    text = true,
    data = true,
    disabled = true,
    tooltip = true,
    isSelected = true,
    setSelected = true,
  },
  radio = {
    kind = true,
    text = true,
    data = true,
    disabled = true,
    tooltip = true,
    isSelected = true,
    setSelected = true,
  },
  title = { kind = true, text = true },
  divider = { kind = true },
  spacer = { kind = true },
}

-- The kinds in the order the error message lists them.
local KIND_LIST = '"button", "checkbox", "radio", "title", "divider" or "spacer"'

-- The `__metatable` of every extension handle. It hides the handle's metatable.
local EXTENSION_METATABLE_TAG = "MenuKit.Extension"

local FACADE_METHODS = {
  "OpenContextMenu",
  "SetupDropdown",
  "ExtendMenu",
  "CloseMenus",
  "SetLimits",
  "GetLimits",
}
local EXTENSION_METHODS = { "Remove", "IsActive" }

-- Public types ---------------------------------------------------------------

---What an entry is.
---@alias MenuKit.Kind "button"|"checkbox"|"radio"|"title"|"divider"|"spacer"

---One line of a menu.
---@class MenuKit.Entry
---@field kind MenuKit.Kind
---@field text string? The line's text; required except for a divider and a spacer.
---@field data any Handed to every callback of the entry.
---@field disabled (boolean|fun(data: any): boolean)? Greys the line out.
---@field tooltip string? Shown when the cursor rests on the line.
---@field onClick fun(data: any)? A button's action.
---@field entries MenuKit.Entry[]? A button's submenu: entries, read each time it opens.
---@field isSelected fun(data: any): boolean? Whether a checkbox or radio is selected.
---@field setSelected fun(data: any)? Called when a checkbox or radio is clicked.

---A menu: entries, or a function returning them each time the menu opens.
---For an extension the function also receives Blizzard's context data.
---@alias MenuKit.Menu MenuKit.Entry[]|fun(owner: table, contextData: any): MenuKit.Entry[]

---An extension of one of Blizzard's tagged menus.
---@class MenuKit.Extension
---@field Remove fun(self: MenuKit.Extension): boolean
---@field IsActive fun(self: MenuKit.Extension): boolean

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class MenuKit.Limits
---@field maxEntries integer|table Most entries one menu holds, submenus included: a positive integer or `MenuKit.UNBOUNDED`; default `256`.
---@field maxDepth integer|table How many menus deep a submenu may open: a positive integer or `MenuKit.UNBOUNDED`; default `4`.
---@field maxExtensions integer Most extensions of tagged menus the session holds: 1 to 1024; default `64`.

---The MenuKit package facade published through Registry.
---@class MenuKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_ENTRIES integer Default of `maxEntries` (`256`).
---@field MAX_DEPTH integer Default of `maxDepth` (`4`).
---@field MAX_EXTENSIONS integer Default of `maxExtensions` (`64`).
---@field EXTENSIONS_CEILING integer The highest `maxExtensions` accepts (`1024`).
---@field UNBOUNDED table Sentinel `maxEntries` and `maxDepth` accept; the same table for every revision.
---@field OpenContextMenu fun(self: MenuKit, owner: table?, menu: MenuKit.Menu): table?
---@field SetupDropdown fun(self: MenuKit, dropdown: table, menu: MenuKit.Menu)
---@field ExtendMenu fun(self: MenuKit, tag: string, menu: MenuKit.Menu): MenuKit.Extension
---@field CloseMenus fun(self: MenuKit)
---@field SetLimits fun(self: MenuKit, limits: MenuKit.Limits)
---@field GetLimits fun(self: MenuKit): MenuKit.Limits

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
  error("MoltenCodes MenuKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes MenuKit requires a valid Registry API 2 facade", 2)
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

---Whether `implementation` exposes the complete MenuKit API 1 surface.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
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

---Whether `value` is an exact integer of one or more. `nan` fails every
---comparison and both infinities are refused before the integer test.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value >= 1 and value ~= math.huge and value % 1 == 0
end

---Whether `limits` holds a valid value for every limit this revision knows.
---@param limits any
---@param unbounded any the package's sentinel
---@return boolean
local function validateLimitsTable(limits, unbounded)
  if type(limits) ~= "table" then
    return false
  end
  local maxEntries = rawget(limits, "maxEntries")
  local maxDepth = rawget(limits, "maxDepth")
  local maxExtensions = rawget(limits, "maxExtensions")
  return (maxEntries == unbounded or isPositiveInteger(maxEntries))
    and (maxDepth == unbounded or isPositiveInteger(maxDepth))
    and isPositiveInteger(maxExtensions)
    and maxExtensions <= EXTENSIONS_CEILING
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local unbounded = rawget(currentState, "unbounded")
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and type(unbounded) == "table"
    and validateLimitsTable(rawget(currentState, "limits"), unbounded)
    and type(rawget(currentState, "extensions")) == "table"
    and type(rawget(currentState, "extensionRecords")) == "table"
    and type(rawget(currentState, "extensionCount")) == "number"
    and type(rawget(currentState, "extensionPrototype")) == "table"
    and type(rawget(currentState, "extensionMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
end

---Whether `implementation` carries package state of this revision's schema,
---and publishes the sentinel that state owns.
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
-- and register this one. What stays here is what only MenuKit can answer.
local MenuKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes MenuKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if MenuKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(MenuKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes MenuKit package state is corrupted or incomplete", 2)
  end

  local extensionPrototype = {}
  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    -- The sentinel `SetLimits` accepts to lift a limit. It lives here, not
    -- in a file local, so every embedded revision hands out the same table.
    unbounded = {},
    limits = {
      maxEntries = MAX_ENTRIES,
      maxDepth = MAX_DEPTH,
      maxExtensions = MAX_EXTENSIONS,
    },
    -- Extension handles registered with Blizzard now. Each holds its record
    -- in `extensionRecords`, kept weakly so a removed extension nobody holds
    -- any more is collected.
    extensions = {},
    extensionRecords = setmetatable({}, { __mode = "k" }),
    extensionCount = 0,
    -- The methods every extension handle reaches through its metatable.
    extensionPrototype = extensionPrototype,
    extensionMetatable = { __index = extensionPrototype, __metatable = EXTENSION_METATABLE_TAG },
    -- Functions every loading revision rewrites. The generators handed to
    -- Blizzard live as long as the dropdown or the extension that holds
    -- them, so they look their behaviour up here at every call.
    dispatch = {},
  }
  rawset(MenuKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes MenuKit package state is corrupted or incomplete", 2)
end

---@type table<table, boolean>
local extensions = rawget(state, "extensions")
---@type table<table, { tag: string, handle: table }>
local extensionRecords = rawget(state, "extensionRecords")
local dispatch = rawget(state, "dispatch")
local ExtensionPrototype = rawget(state, "extensionPrototype")
local EXTENSION_METATABLE = rawget(state, "extensionMetatable")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")

-- Host facilities ------------------------------------------------------------

-- shared:begin isSecret 1
-- Copied from tooling/shared/lua/isSecret.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Whether `value` is a secret value the host forbids comparing.
---@type fun(value: any): boolean
local isSecret
do
  -- issecretvalue is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local loadedProbe = rawget(_G, "issecretvalue")
  if type(loadedProbe) ~= "function" then
    loadedProbe = nil
  end

  isSecret = function(value)
    local probe = loadedProbe
    if probe == nil then
      -- selene: allow(global_usage)
      probe = rawget(_G, "issecretvalue")
      if type(probe) ~= "function" then
        return false
      end
    end
    return probe(value) == true
  end
end
-- shared:end isSecret

-- shared:begin reportError 1
-- Copied from tooling/shared/lua/reportError.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Report `failure` through the host error handler, or print it.
---@param failure any
local function reportError(failure)
  -- geterrorhandler is a client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) == "function" then
    local handler = getErrorHandler()
    if type(handler) == "function" and pcall(handler, failure) then
      return
    end
  end
  print(failure)
end
-- shared:end reportError

---Blizzard's `MenuUtil` and `Menu`, or raise at the caller of the public
---method naming `label`.
---@param label string
---@param level integer stack level the failure is reported at
---@return table menuUtil
---@return table menu
local function requireMenuApi(label, level)
  local menuUtil = readGlobal("MenuUtil")
  local menu = readGlobal("Menu")
  if
    type(menuUtil) ~= "table"
    or type(menu) ~= "table"
    or type(menuUtil.CreateContextMenu) ~= "function"
    or type(menu.ModifyMenu) ~= "function"
    or type(menu.GetManager) ~= "function"
  then
    error(
      label .. " needs the client's Menu API (Blizzard_Menu), which this host does not have",
      level
    )
  end
  return menuUtil, menu
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- MenuKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

-- shared:begin validateFacade 1 __FACADE__=MenuKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the MenuKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= MenuKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the MenuKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

-- Menu checks ----------------------------------------------------------------
--
-- One walk checks a whole entry tree and answers the first problem as a
-- message instead of raising, so the same check serves a menu handed to a
-- public method (raised at the caller) and one a menu function returned while
-- Blizzard opens the menu (reported, because the caller is Blizzard).

---How a field is named in a message: `menu[2].entries[1].text`.
---@param path string
---@param index integer
---@return string
local function entryPath(path, index)
  return path .. "[" .. index .. "]"
end

---The problem with a text field, or `nil`.
---@param value any
---@param where string
---@param required boolean
---@return string?
local function textProblem(value, where, required)
  if isSecret(value) then
    return where .. " must not be a secret value"
  end
  if type(value) == "nil" and not required then
    return nil
  end
  if type(value) ~= "string" or value == "" then
    return where .. " must be a non-empty string"
  end
  return nil
end

---The problem with one entry's own fields, not its submenu, or `nil`.
---@param entry any
---@param where string
---@return string?
local function entryProblem(entry, where)
  if isSecret(entry) or type(entry) ~= "table" then
    return where .. " must be an entry table"
  end
  local kind = rawget(entry, "kind")
  if isSecret(kind) or type(kind) ~= "string" or KIND_FIELDS[kind] == nil then
    return where .. ".kind must be " .. KIND_LIST
  end
  local fields = KIND_FIELDS[kind]
  for key in pairs(entry) do
    if isSecret(key) or type(key) ~= "string" or not fields[key] then
      local shown = SECRET_PLACEHOLDER
      if not isSecret(key) then
        shown = type(key) == "string" and key or "<" .. type(key) .. ">"
      end
      return where .. " holds the field " .. shown .. ", which a " .. kind .. " does not take"
    end
  end
  if kind == "divider" or kind == "spacer" then
    return nil
  end
  local problem = textProblem(rawget(entry, "text"), where .. ".text", true)
    or textProblem(rawget(entry, "tooltip"), where .. ".tooltip", false)
  if problem then
    return problem
  end
  local disabled = rawget(entry, "disabled")
  if type(disabled) ~= "nil" and type(disabled) ~= "boolean" and type(disabled) ~= "function" then
    return where .. ".disabled must be a boolean, a function or nil"
  end
  if kind == "button" then
    local onClick = rawget(entry, "onClick")
    if type(onClick) ~= "nil" and type(onClick) ~= "function" then
      return where .. ".onClick must be a function or nil"
    end
  elseif kind ~= "title" then
    if type(rawget(entry, "isSelected")) ~= "function" then
      return where .. ".isSelected must be a function"
    end
    if type(rawget(entry, "setSelected")) ~= "function" then
      return where .. ".setSelected must be a function"
    end
  end
  return nil
end

---The problem with an entry array and everything below it, or `nil`.
---`counter[1]` counts entries across the whole tree; `onPath` holds the
---entry arrays above, so an array that contains itself is refused rather
---than walked forever.
---@param entries any
---@param where string
---@param depth integer
---@param counter integer[]
---@param onPath table<table, boolean>
---@return string?
local function entriesProblem(entries, where, depth, counter, onPath)
  if isSecret(entries) or type(entries) ~= "table" then
    return where .. " must be an array of entries"
  end
  local maxDepth = rawget(sharedLimits, "maxDepth")
  if maxDepth ~= UNBOUNDED and depth > maxDepth then
    return where .. " opens " .. depth .. " menus deep; maxDepth is " .. maxDepth
  end
  if onPath[entries] then
    return where .. " contains itself"
  end
  onPath[entries] = true
  local maxEntries = rawget(sharedLimits, "maxEntries")
  for index = 1, #entries do
    local entry = rawget(entries, index)
    local at = entryPath(where, index)
    local problem = entryProblem(entry, at)
    if problem then
      return problem
    end
    counter[1] = counter[1] + 1
    if maxEntries ~= UNBOUNDED and counter[1] > maxEntries then
      return where .. " holds more than " .. maxEntries .. " entries; maxEntries is " .. maxEntries
    end
    local submenu = rawget(entry, "entries")
    if type(submenu) ~= "nil" then
      problem = entriesProblem(submenu, at .. ".entries", depth + 1, counter, onPath)
      if problem then
        return problem
      end
    end
  end
  onPath[entries] = nil
  return nil
end

---The problem with a whole menu's entries, or `nil`.
---@param entries any
---@param where string
---@return string?
local function menuProblem(entries, where)
  return entriesProblem(entries, where, 1, { 0 }, {})
end

---Raise at the caller when `menu` is neither a function nor a valid entry
---array.
---@param menu any
---@param label string
---@param level integer stack level the failure is reported at
local function validateMenu(menu, label, level)
  if type(menu) == "function" then
    return
  end
  local problem = menuProblem(menu, label .. " menu")
  if problem then
    error(problem, level)
  end
end

-- Building -------------------------------------------------------------------

---Call `callback(data)` protected; a failure is reported and answers `nil`.
---@param callback function
---@param data any
---@return any
local function protectedCall(callback, data)
  local ok, result = pcall(callback, data)
  if not ok then
    reportError(result)
    return nil
  end
  return result
end

---Give a line Blizzard's enabled state and tooltip from the entry.
---@param description table Blizzard's element description
---@param entry MenuKit.Entry
local function decorate(description, entry)
  local disabled = rawget(entry, "disabled")
  if type(disabled) == "boolean" then
    description:SetEnabled(not disabled)
  elseif type(disabled) == "function" then
    local data = rawget(entry, "data")
    description:SetEnabled(function()
      return protectedCall(disabled, data) ~= true
    end)
  end
  local tooltip = rawget(entry, "tooltip")
  if type(tooltip) == "string" then
    description:SetTooltip(function(tooltipFrame)
      tooltipFrame:SetText(tooltip, nil, nil, nil, nil, true)
    end)
  end
end

---Add every entry to Blizzard's description `parent`, submenus included.
---The entries were checked before this runs. Every field is read with
---`rawget`, as the check reads it: a field an `__index` metatable supplies was
---never checked, so it must not reach Blizzard (a submenu there would escape
---`maxEntries` and `maxDepth`).
---@param parent table a root or element description
---@param entries MenuKit.Entry[]
local function addEntries(parent, entries)
  for index = 1, #entries do
    local entry = rawget(entries, index)
    local kind = rawget(entry, "kind")
    local data = rawget(entry, "data")
    local text = rawget(entry, "text")
    if kind == "divider" then
      parent:CreateDivider()
    elseif kind == "spacer" then
      parent:CreateSpacer()
    elseif kind == "title" then
      parent:CreateTitle(text)
    elseif kind == "button" then
      local onClick = rawget(entry, "onClick")
      local responder = nil
      if onClick then
        responder = function(clicked)
          protectedCall(onClick, clicked)
        end
      end
      local description = parent:CreateButton(text, responder, data)
      decorate(description, entry)
      local submenu = rawget(entry, "entries")
      if submenu then
        addEntries(description, submenu)
      end
    else
      -- The check made both functions for a checkbox and a radio.
      local isSelected = rawget(entry, "isSelected") --[[@as function]]
      local setSelected = rawget(entry, "setSelected") --[[@as function]]
      local function readSelected(selectedData)
        return protectedCall(isSelected, selectedData) == true
      end
      local function writeSelected(clicked)
        protectedCall(setSelected, clicked)
      end
      local description
      if kind == "checkbox" then
        description = parent:CreateCheckbox(text, readSelected, writeSelected, data)
      else
        description = parent:CreateRadio(text, readSelected, writeSelected, data)
      end
      decorate(description, entry)
    end
  end
end

---Fill Blizzard's root description from `menu` as it is now. A menu
---function that raises or returns entries that fail the check is reported,
---and the menu is left empty: the caller is Blizzard, opening the menu.
---@param menu MenuKit.Menu
---@param owner table
---@param root table
---@param contextData any
function dispatch.populate(menu, owner, root, contextData)
  local entries = menu
  if type(menu) == "function" then
    local ok, result = pcall(menu, owner, contextData)
    if not ok then
      reportError(result)
      return
    end
    entries = result
  end
  local problem = menuProblem(entries, "MenuKit menu")
  if problem then
    reportError(problem)
    return
  end
  local ok, failure = pcall(addEntries, root, entries)
  if not ok then
    reportError(failure)
  end
end

---A generator for Blizzard that fills a menu from `menu` each time it opens.
---It calls through `dispatch`, so a newer revision's code runs for it.
---@param menu MenuKit.Menu
---@return fun(owner: table, root: table)
local function generatorFor(menu)
  return function(owner, root)
    dispatch.populate(menu, owner, root, nil)
  end
end

-- Extension methods ----------------------------------------------------------

---The record of an extension handle, or raise at the caller.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireExtension(receiver, label, level)
  local record = nil
  if not isSecret(receiver) and type(receiver) == "table" then
    record = extensionRecords[receiver]
  end
  if record == nil then
    error(
      label
        .. " must be called on a MenuKit extension; use extension:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

---Remove the extension from Blizzard's menu: `true`, or `false` when it was
---already removed.
---@param self MenuKit.Extension
---@return boolean
local function extensionRemove(self)
  local record = requireExtension(self, "MenuKit.Extension:Remove", 3)
  if not extensions[self] then
    return false
  end
  extensions[self] = nil
  rawset(state, "extensionCount", rawget(state, "extensionCount") - 1)
  local handle = record.handle
  local ok, failure = pcall(handle.Unregister, handle)
  if not ok then
    reportError(failure)
  end
  return true
end

---Whether the extension is still registered with Blizzard.
---@param self MenuKit.Extension
---@return boolean
local function extensionIsActive(self)
  requireExtension(self, "MenuKit.Extension:IsActive", 3)
  return extensions[self] ~= nil
end

-- Package public API ---------------------------------------------------------

---Open `menu` at the cursor. Blizzard closes it when `owner` hides; without
---an owner, Blizzard's own top-level parent is used.
---@param self MenuKit
---@param owner table?
---@param menu MenuKit.Menu
---@return table? menu Blizzard's menu, or `nil` when it did not open
local function packageOpenContextMenu(self, owner, menu)
  validateFacade(self, "MenuKit:OpenContextMenu", 3)
  if type(owner) ~= "nil" and (isSecret(owner) or type(owner) ~= "table") then
    error("MenuKit:OpenContextMenu owner must be a frame or nil", 2)
  end
  validateMenu(menu, "MenuKit:OpenContextMenu", 3)
  local menuUtil = requireMenuApi("MenuKit:OpenContextMenu", 3)
  return menuUtil.CreateContextMenu(owner, generatorFor(menu))
end

---Give a dropdown button (`CreateFrame("DropdownButton", ...)`) its menu.
---@param self MenuKit
---@param dropdown table
---@param menu MenuKit.Menu
local function packageSetupDropdown(self, dropdown, menu)
  validateFacade(self, "MenuKit:SetupDropdown", 3)
  if isSecret(dropdown) or type(dropdown) ~= "table" or type(dropdown.SetupMenu) ~= "function" then
    error("MenuKit:SetupDropdown dropdown must be a DropdownButton", 2)
  end
  validateMenu(menu, "MenuKit:SetupDropdown", 3)
  requireMenuApi("MenuKit:SetupDropdown", 3)
  dropdown:SetupMenu(generatorFor(menu))
end

---Add `menu`'s entries to the end of Blizzard's menu tagged `tag` every time
---it opens, until the extension is removed.
---@param self MenuKit
---@param tag string a Blizzard menu tag, such as `"MENU_UNIT_PLAYER"`
---@param menu MenuKit.Menu
---@return MenuKit.Extension
local function packageExtendMenu(self, tag, menu)
  validateFacade(self, "MenuKit:ExtendMenu", 3)
  local problem = textProblem(tag, "MenuKit:ExtendMenu tag", true)
  if problem then
    error(problem, 2)
  end
  validateMenu(menu, "MenuKit:ExtendMenu", 3)
  local _, blizzardMenu = requireMenuApi("MenuKit:ExtendMenu", 3)
  local maxExtensions = rawget(sharedLimits, "maxExtensions")
  if rawget(state, "extensionCount") >= maxExtensions then
    error(
      "MenuKit:ExtendMenu holds at most "
        .. maxExtensions
        .. " extensions; remove one, or raise maxExtensions with MenuKit:SetLimits",
      2
    )
  end
  local handle = blizzardMenu.ModifyMenu(tag, function(owner, root, contextData)
    dispatch.populate(menu, owner, root, contextData)
  end)
  local extension = setmetatable({}, EXTENSION_METATABLE)
  extensionRecords[extension] = { tag = tag, handle = handle }
  extensions[extension] = true
  rawset(state, "extensionCount", rawget(state, "extensionCount") + 1)
  return extension
end

---Close every open menu.
---@param self MenuKit
local function packageCloseMenus(self)
  validateFacade(self, "MenuKit:CloseMenus", 3)
  local _, blizzardMenu = requireMenuApi("MenuKit:CloseMenus", 3)
  blizzardMenu.GetManager():CloseMenus()
end

---Change any subset of the shared limits. Every value is checked before any
---changes.
---@param self MenuKit
---@param limits MenuKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "MenuKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("MenuKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or (key ~= "maxEntries" and key ~= "maxDepth" and key ~= "maxExtensions") then
      error(
        "MenuKit:SetLimits limits holds an unknown field; it accepts maxEntries, maxDepth and maxExtensions",
        2
      )
    end
    if isSecret(value) then
      error("MenuKit:SetLimits limits." .. key .. " must not be a secret value", 2)
    end
    if key == "maxExtensions" then
      if not isPositiveInteger(value) or value > EXTENSIONS_CEILING then
        error(
          "MenuKit:SetLimits limits.maxExtensions must be an integer from 1 to "
            .. EXTENSIONS_CEILING,
          2
        )
      end
    elseif value ~= UNBOUNDED and not isPositiveInteger(value) then
      error(
        "MenuKit:SetLimits limits." .. key .. " must be a positive integer or MenuKit.UNBOUNDED",
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
---@param self MenuKit
---@return MenuKit.Limits limits
local function packageGetLimits(self)
  validateFacade(self, "MenuKit:GetLimits", 3)
  return {
    maxEntries = rawget(sharedLimits, "maxEntries"),
    maxDepth = rawget(sharedLimits, "maxDepth"),
    maxExtensions = rawget(sharedLimits, "maxExtensions"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(ExtensionPrototype, "Remove", extensionRemove)
rawset(ExtensionPrototype, "IsActive", extensionIsActive)

rawset(MenuKit, "API", API_GENERATION)
rawset(MenuKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(MenuKit, "MAX_ENTRIES", MAX_ENTRIES)
rawset(MenuKit, "MAX_DEPTH", MAX_DEPTH)
rawset(MenuKit, "MAX_EXTENSIONS", MAX_EXTENSIONS)
rawset(MenuKit, "EXTENSIONS_CEILING", EXTENSIONS_CEILING)
rawset(MenuKit, "UNBOUNDED", UNBOUNDED)
rawset(MenuKit, "OpenContextMenu", packageOpenContextMenu)
rawset(MenuKit, "SetupDropdown", packageSetupDropdown)
rawset(MenuKit, "ExtendMenu", packageExtendMenu)
rawset(MenuKit, "CloseMenus", packageCloseMenus)
rawset(MenuKit, "SetLimits", packageSetLimits)
rawset(MenuKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(MenuKit) or not validateCurrentState(MenuKit) then
  error("MoltenCodes MenuKit package state is corrupted or incomplete", 2)
end
for index = 1, #EXTENSION_METHODS do
  if type(rawget(ExtensionPrototype, EXTENSION_METHODS[index])) ~= "function" then
    error("MoltenCodes MenuKit package state is corrupted or incomplete", 2)
  end
end

return MenuKit
