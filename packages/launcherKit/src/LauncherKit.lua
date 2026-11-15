-- MoltenCodes LauncherKit
--
-- A minimap button for a BrokerKit object: what LibDBIcon-1.0 gives every
-- addon with a LibDataBroker launcher. The object's icon sits on the edge of
-- the minimap and is dragged around it; a click calls the object's `OnClick`,
-- hovering fills `GameTooltip` through its `OnTooltipShow` (or calls its
-- `OnEnter`), and the icon follows the object's `icon`, `iconCoords` and
-- `iconR`/`iconG`/`iconB` attributes.
--
-- Position, hidden and locked state live in a table the addon gives, in
-- LibDBIcon's field names (`minimapPos` in degrees, `hide`, `lock`), so a
-- saved LibDBIcon table keeps working. The table may be a SettingsKit view,
-- or a function returning one at every read and write, which follows a
-- profile switch.
--
-- The edge follows the minimap's shape: round unless an addon that reshapes
-- the minimap defines the global `GetMinimapShape`, a convention minimap
-- addons share. For each quarter of the minimap the shape says whether it is
-- round (the button sits on a circle) or square (the button sits on the
-- square's edge).
--
-- On Retail the same object can also be listed in Blizzard's AddonCompartment,
-- the addons drop-down beside the minimap. Classic clients have none, and
-- Blizzard has no way to remove an entry once it is added.
--
-- LauncherKit requires Registry API 2 and BrokerKit API 1. It reads at call
-- time `Minimap`, `CreateFrame`, `GameTooltip`, `GetCursorPosition`,
-- `GetMinimapShape`, `AddonCompartmentFrame`, `issecretvalue` and
-- `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, the button's look, shapes
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, BrokerKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler
--   Argument checks ....... receivers, names, storage, limits
--   Storage ............... reading and writing the addon's table
--   Placement ............. an angle onto the minimap's edge
--   Tooltip ............... GameTooltip shown and hidden for an owner
--   Button ................ the frame, its icon, its scripts
--   Launcher methods ...... Show, Hide, Lock, Unlock, Refresh, ...
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "launcherKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_BROKERKIT_API = 1
local STATE_SCHEMA = 1

-- Every launcher record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The default and the ceiling of the `maxLaunchers` limit. Each launcher is a
-- button frame the session keeps until logout, so there is no unbounded
-- setting; a session with more than a few dozen minimap buttons is unusable
-- long before the ceiling.
local MAX_LAUNCHERS = 64
local LAUNCHERS_CEILING = 256

-- Where a launcher sits before it was ever moved, in degrees counter-clockwise
-- from the right: below and left of the minimap's centre, the convention
-- LibDBIcon set, so a fresh button lands where players look for one.
local DEFAULT_ANGLE = 225

-- How far outside the minimap's edge the button's centre sits, in pixels.
local EDGE_OFFSET = 5

-- On a square quarter the button follows a circle through the square's
-- corner, pulled in by this many pixels, then clamped to the square's edge.
local CORNER_PULL = 10

-- The button's look: the standard tracking-button art every minimap button
-- uses, so a launcher looks like the client's own.
local BUTTON_SIZE = 31
local ICON_SIZE = 20
local BORDER_SIZE = 53
local BORDER_TEXTURE = [[Interface\Minimap\MiniMap-TrackingBorder]]
local HIGHLIGHT_TEXTURE = [[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]]

-- The shapes `GetMinimapShape` may answer, and which quarters of each are
-- round. A quarter not listed is square; a shape not listed counts as round.
local ROUND_QUARTERS = {
  ROUND = { topLeft = true, topRight = true, bottomLeft = true, bottomRight = true },
  SQUARE = {},
  ["CORNER-TOPLEFT"] = { topLeft = true },
  ["CORNER-TOPRIGHT"] = { topRight = true },
  ["CORNER-BOTTOMLEFT"] = { bottomLeft = true },
  ["CORNER-BOTTOMRIGHT"] = { bottomRight = true },
  ["SIDE-LEFT"] = { topLeft = true, bottomLeft = true },
  ["SIDE-RIGHT"] = { topRight = true, bottomRight = true },
  ["SIDE-TOP"] = { topLeft = true, topRight = true },
  ["SIDE-BOTTOM"] = { bottomLeft = true, bottomRight = true },
  ["TRICORNER-TOPLEFT"] = { topLeft = true, topRight = true, bottomLeft = true },
  ["TRICORNER-TOPRIGHT"] = { topLeft = true, topRight = true, bottomRight = true },
  ["TRICORNER-BOTTOMLEFT"] = { topLeft = true, bottomLeft = true, bottomRight = true },
  ["TRICORNER-BOTTOMRIGHT"] = { topRight = true, bottomLeft = true, bottomRight = true },
}

-- The object attributes the button draws.
local ICON_ATTRIBUTES = { icon = true, iconCoords = true, iconR = true, iconG = true, iconB = true }

-- What `AddToCompartment` answers when it adds nothing.
local REASON_UNAVAILABLE = "unavailable"
local REASON_ALREADY = "already"

-- The `__metatable` of every launcher handle. It hides the handle's metatable.
local LAUNCHER_METATABLE_TAG = "LauncherKit.Launcher"

local FACADE_METHODS = { "Register", "Get", "AddToCompartment", "SetLimits", "GetLimits" }
local LAUNCHER_METHODS =
  { "Show", "Hide", "IsShown", "Lock", "Unlock", "IsLocked", "Refresh", "GetButton" }

-- Public types ---------------------------------------------------------------

---The fields LauncherKit reads and writes in the addon's table: LibDBIcon's.
---@class LauncherKit.Storage
---@field minimapPos number? Degrees counter-clockwise from the right; default `225`.
---@field hide boolean? `true` while the button is hidden.
---@field lock boolean? `true` while the button cannot be dragged.

---A table, or a function returning one at every read and write.
---@alias LauncherKit.StorageSource LauncherKit.Storage|fun(): LauncherKit.Storage

---One minimap button.
---@class LauncherKit.Launcher
---@field Show fun(self: LauncherKit.Launcher)
---@field Hide fun(self: LauncherKit.Launcher)
---@field IsShown fun(self: LauncherKit.Launcher): boolean
---@field Lock fun(self: LauncherKit.Launcher)
---@field Unlock fun(self: LauncherKit.Launcher)
---@field IsLocked fun(self: LauncherKit.Launcher): boolean
---@field Refresh fun(self: LauncherKit.Launcher)
---@field GetButton fun(self: LauncherKit.Launcher): table

---The shared limits. `SetLimits` accepts any subset; `GetLimits` returns all.
---@class LauncherKit.Limits
---@field maxLaunchers integer Most launchers the session holds: 1 to 256; default `64`.

---The LauncherKit package facade published through Registry.
---@class LauncherKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_LAUNCHERS integer Default of `maxLaunchers` (`64`).
---@field LAUNCHERS_CEILING integer The highest `maxLaunchers` accepts (`256`).
---@field DEFAULT_ANGLE number Where a button sits before it is moved (`225`).
---@field Register fun(self: LauncherKit, objectName: string, storage: LauncherKit.StorageSource): LauncherKit.Launcher
---@field Get fun(self: LauncherKit, objectName: string): LauncherKit.Launcher?
---@field AddToCompartment fun(self: LauncherKit, objectName: string): true|nil, string?
---@field SetLimits fun(self: LauncherKit, limits: LauncherKit.Limits)
---@field GetLimits fun(self: LauncherKit): LauncherKit.Limits

---Everything LauncherKit keeps per launcher. Private.
---@class LauncherKit.Record
---@field schema integer
---@field name string the BrokerKit object's name
---@field object table the BrokerKit object
---@field storage LauncherKit.StorageSource
---@field launcher LauncherKit.Launcher the handle consumers hold
---@field button table the minimap button
---@field icon table the button's icon texture
---@field connection table the BrokerKit change connection
---@field dragging boolean
---@field dragAngle number? the angle the cursor reached during a drag

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
  error("MoltenCodes LauncherKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes LauncherKit requires a valid Registry API 2 facade", 2)
end

-- BrokerKit holds the objects a launcher shows.
local BrokerKit = getPackage(Registry, "brokerKit", REQUIRED_BROKERKIT_API)
if
  type(BrokerKit) ~= "table"
  or rawget(BrokerKit, "API") ~= REQUIRED_BROKERKIT_API
  or type(rawget(BrokerKit, "Get")) ~= "function"
then
  error("MoltenCodes LauncherKit requires BrokerKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local mathCos, mathSin, mathRad, mathDeg, mathAtan2, mathSqrt, mathMax, mathMin =
  math.cos, math.sin, math.rad, math.deg, math.atan2, math.sqrt, math.max, math.min

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete LauncherKit API 1 surface.
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
local function isLauncherLimit(value)
  return type(value) == "number" and value >= 1 and value <= LAUNCHERS_CEILING and value % 1 == 0
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
    and isLauncherLimit(rawget(limits, "maxLaunchers"))
    and type(rawget(currentState, "launchers")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "buttons")) == "table"
    and type(rawget(currentState, "launcherCount")) == "number"
    and type(rawget(currentState, "compartment")) == "table"
    and type(rawget(currentState, "launcherPrototype")) == "table"
    and type(rawget(currentState, "launcherMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "scripts")) == "table"
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
-- and register this one. What stays here is what only LauncherKit can answer.
local LauncherKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes LauncherKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if LauncherKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(LauncherKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes LauncherKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The buttons hold the scripts
  -- below for the session, so the scripts look their behaviour up here.
  local dispatch = {}
  local launcherPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxLaunchers = MAX_LAUNCHERS },
    -- Object name to record, handle to record, button to record.
    launchers = {},
    records = {},
    buttons = {},
    launcherCount = 0,
    -- Object names put in Blizzard's AddonCompartment this session.
    compartment = {},
    launcherPrototype = launcherPrototype,
    launcherMetatable = { __index = launcherPrototype, __metatable = LAUNCHER_METATABLE_TAG },
    dispatch = dispatch,
    -- The button scripts, one stable closure each.
    scripts = {
      OnClick = function(button, mouseButton)
        dispatch.click(button, mouseButton)
      end,
      OnEnter = function(button)
        dispatch.enter(button)
      end,
      OnLeave = function(button)
        dispatch.leave(button)
      end,
      OnDragStart = function(button)
        dispatch.dragStart(button)
      end,
      OnDragStop = function(button)
        dispatch.dragStop(button)
      end,
      OnUpdate = function(button)
        dispatch.drag(button)
      end,
      -- The BrokerKit change listener every launcher connects.
      onAttribute = function(object, attribute)
        dispatch.attributeChanged(object, attribute)
      end,
    },
  }
  rawset(LauncherKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes LauncherKit package state is corrupted or incomplete", 2)
end

---@type table<string, LauncherKit.Record>
local launchers = rawget(state, "launchers")
---@type table<table, LauncherKit.Record>
local records = rawget(state, "records")
---@type table<table, LauncherKit.Record>
local buttons = rawget(state, "buttons")
local compartment = rawget(state, "compartment")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local LauncherPrototype = rawget(state, "launcherPrototype")
local LAUNCHER_METATABLE = rawget(state, "launcherMetatable")
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

---Hand `failure` to the host error handler without raising. Outside a client
---it is printed, as the client's own default handler would.
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

---Call `callback(...)` protected; a failure is reported.
---@param callback function
---@param ... any
local function protectedCall(callback, ...)
  local ok, failure = pcall(callback, ...)
  if not ok then
    reportError(failure)
  end
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- LauncherKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= LauncherKit then
    error(label .. " must be called on the LauncherKit facade; use " .. label .. "(...)", level)
  end
end

---The BrokerKit object named `objectName`, or raise at the caller.
---@param objectName any
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table object
local function requireObject(objectName, label, level)
  if isSecret(objectName) then
    error(label .. " objectName must not be a secret value", level)
  end
  if type(objectName) ~= "string" or objectName == "" then
    error(label .. " objectName must be a non-empty string", level)
  end
  local object = BrokerKit:Get(objectName)
  if object == nil then
    error(
      label
        .. " has no BrokerKit object named "
        .. objectName
        .. "; create it with BrokerKit:New first",
      level
    )
  end
  return object
end

---The record of the launcher a method was called on.
---@param receiver any
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return LauncherKit.Record
local function requireRecord(receiver, label, level)
  local record = nil
  if not isSecret(receiver) and type(receiver) == "table" then
    record = records[receiver]
  end
  if record == nil then
    error(
      label
        .. " must be called on a LauncherKit launcher; use launcher:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

-- Storage --------------------------------------------------------------------

---The addon's table as it is now, or `nil` (reported) when a storage function
---raises or returns something else.
---@param record LauncherKit.Record
---@return table?
local function resolveStorage(record)
  local storage = record.storage
  if type(storage) == "function" then
    local ok, result = pcall(storage)
    if not ok then
      reportError(result)
      return nil
    end
    if isSecret(result) or type(result) ~= "table" then
      reportError("LauncherKit storage for " .. record.name .. " must return a table")
      return nil
    end
    return result
  end
  return storage
end

---One field of a resolved table, or `nil`. A secret reads as `nil`.
---@param storage table?
---@param field string
---@return any
local function fieldOf(storage, field)
  if storage == nil then
    return nil
  end
  local value = storage[field]
  if isSecret(value) then
    return nil
  end
  return value
end

---One field of the addon's table as it is now, or `nil`.
---@param record LauncherKit.Record
---@param field string
---@return any
local function readField(record, field)
  return fieldOf(resolveStorage(record), field)
end

---Write one field of the addon's table. Nothing is written when the table
---cannot be resolved; a write that raises (a read-only SettingsKit view) is
---reported.
---@param record LauncherKit.Record
---@param field string
---@param value any
local function writeField(record, field, value)
  local storage = resolveStorage(record)
  if storage == nil then
    return
  end
  local ok, failure = pcall(function()
    storage[field] = value
  end)
  if not ok then
    reportError(failure)
  end
end

-- Placement ------------------------------------------------------------------

---Put `button` on the minimap's edge at `angle` degrees.
---@param button table
---@param angle number
local function place(button, angle)
  -- The button's parent is the minimap `Register` checked.
  local minimap = button:GetParent()
  local radians = mathRad(angle)
  local x, y = mathCos(radians), mathSin(radians)
  local quarter
  if y > 0 then
    quarter = x < 0 and "topLeft" or "topRight"
  else
    quarter = x < 0 and "bottomLeft" or "bottomRight"
  end
  local getShape = readGlobal("GetMinimapShape")
  local shape = "ROUND"
  if type(getShape) == "function" then
    local ok, answered = pcall(getShape)
    if
      ok
      and not isSecret(answered)
      and type(answered) == "string"
      and ROUND_QUARTERS[answered]
    then
      shape = answered
    end
  end
  local halfWidth = minimap:GetWidth() / 2 + EDGE_OFFSET
  local halfHeight = minimap:GetHeight() / 2 + EDGE_OFFSET
  if ROUND_QUARTERS[shape][quarter] then
    x, y = x * halfWidth, y * halfHeight
  else
    local cornerWidth = mathSqrt(2 * halfWidth * halfWidth) - CORNER_PULL
    local cornerHeight = mathSqrt(2 * halfHeight * halfHeight) - CORNER_PULL
    x = mathMax(-halfWidth, mathMin(x * cornerWidth, halfWidth))
    y = mathMax(-halfHeight, mathMin(y * cornerHeight, halfHeight))
  end
  button:ClearAllPoints()
  button:SetPoint("CENTER", minimap, "CENTER", x, y)
end

---The saved angle, or the default when none is saved or it is not a number.
---@param storage table?
---@return number
local function savedAngle(storage)
  local angle = fieldOf(storage, "minimapPos")
  if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
    return DEFAULT_ANGLE
  end
  return angle
end

-- Tooltip --------------------------------------------------------------------

---Show `GameTooltip` on `owner`, filled by `fill(tooltip)` (protected).
---@param owner table
---@param anchor string
---@param fill function
local function showTooltip(owner, anchor, fill)
  local tooltip = readGlobal("GameTooltip")
  if type(tooltip) ~= "table" then
    return
  end
  tooltip:SetOwner(owner, anchor)
  protectedCall(fill, tooltip)
  tooltip:Show()
end

---Hide `GameTooltip` when `owner` owns it.
---@param owner table
local function hideTooltipOf(owner)
  local tooltip = readGlobal("GameTooltip")
  if type(tooltip) == "table" and tooltip:GetOwner() == owner then
    tooltip:Hide()
  end
end

-- Button ---------------------------------------------------------------------

---Draw the object's icon attributes on the button.
---@param record LauncherKit.Record
local function drawIcon(record)
  local object, icon = record.object, record.icon
  local texture = object.icon
  icon:SetTexture((type(texture) == "string" or type(texture) == "number") and texture or nil)
  local coords = object.iconCoords
  if type(coords) == "table" then
    icon:SetTexCoord(coords[1] or 0, coords[2] or 1, coords[3] or 0, coords[4] or 1)
  else
    icon:SetTexCoord(0, 1, 0, 1)
  end
  local red, green, blue = object.iconR, object.iconG, object.iconB
  if type(red) == "number" and type(green) == "number" and type(blue) == "number" then
    icon:SetVertexColor(red, green, blue)
  else
    icon:SetVertexColor(1, 1, 1)
  end
end

---Show or hide the button and put it at its saved angle, from the storage.
---@param record LauncherKit.Record
local function applyStorage(record)
  local storage = resolveStorage(record)
  place(record.button, savedAngle(storage))
  if fieldOf(storage, "hide") == true then
    record.button:Hide()
  else
    record.button:Show()
  end
end

---Build a launcher button on `minimap`.
---@param createFrame function the client's `CreateFrame`
---@param minimap table the client's `Minimap`
---@return table button
---@return table icon the button's icon texture
local function buildButton(createFrame, minimap)
  local button = createFrame("Button", nil, minimap)
  button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("AnyUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture(HIGHLIGHT_TEXTURE)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("CENTER", button, "CENTER", 0, 1)
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture(BORDER_TEXTURE)
  border:SetSize(BORDER_SIZE, BORDER_SIZE)
  border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

  for _, name in ipairs({ "OnClick", "OnEnter", "OnLeave", "OnDragStart", "OnDragStop" }) do
    button:SetScript(name, scripts[name])
  end
  -- The icon is published on the button, as Blizzard's own buttons publish
  -- their parts, for an addon that restyles it.
  button.icon = icon
  return button, icon
end

---A click: the object's `OnClick(button, mouseButton)`, protected.
---@param button table
---@param mouseButton string
function dispatch.click(button, mouseButton)
  local record = buttons[button]
  local onClick = record and record.object.OnClick
  if type(onClick) == "function" then
    protectedCall(onClick, button, mouseButton)
  end
end

---The cursor enters: the object's tooltip in `GameTooltip`, or its `OnEnter`.
---@param button table
function dispatch.enter(button)
  local record = buttons[button]
  if record == nil or record.dragging then
    return
  end
  local object = record.object
  if type(object.OnTooltipShow) == "function" and type(readGlobal("GameTooltip")) == "table" then
    showTooltip(button, "ANCHOR_LEFT", object.OnTooltipShow)
  elseif type(object.OnEnter) == "function" then
    protectedCall(object.OnEnter, button)
  end
end

---The cursor leaves: the tooltip this button owns is hidden, then the
---object's `OnLeave`.
---@param button table
function dispatch.leave(button)
  local record = buttons[button]
  if record == nil then
    return
  end
  hideTooltipOf(button)
  if type(record.object.OnLeave) == "function" then
    protectedCall(record.object.OnLeave, button)
  end
end

---A drag starts: unless the launcher is locked, follow the cursor every frame.
---@param button table
function dispatch.dragStart(button)
  local record = buttons[button]
  if record == nil or readField(record, "lock") == true then
    return
  end
  record.dragging = true
  hideTooltipOf(button)
  button:SetScript("OnUpdate", scripts.OnUpdate)
end

---The angle from the minimap's centre to the cursor, in degrees, 0 to 360.
---@param button table a launcher button, whose parent is the minimap
---@return number?
local function cursorAngle(button)
  local getCursorPosition = readGlobal("GetCursorPosition")
  if type(getCursorPosition) ~= "function" then
    return nil
  end
  local minimap = button:GetParent()
  local centerX, centerY = minimap:GetCenter()
  local cursorX, cursorY = getCursorPosition()
  if
    isSecret(centerX)
    or isSecret(cursorX)
    or type(centerX) ~= "number"
    or type(cursorX) ~= "number"
  then
    return nil
  end
  local scale = minimap:GetEffectiveScale()
  return mathDeg(mathAtan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
end

---Every frame of a drag: the button follows the cursor round the edge.
---@param button table
function dispatch.drag(button)
  local record = buttons[button]
  local angle = cursorAngle(button)
  if record ~= nil and angle ~= nil then
    record.dragAngle = angle
    place(button, angle)
  end
end

---The drag ends: stop following the cursor and save the angle.
---@param button table
function dispatch.dragStop(button)
  button:SetScript("OnUpdate", nil)
  local record = buttons[button]
  if record == nil or not record.dragging then
    return
  end
  record.dragging = false
  local angle = record.dragAngle
  record.dragAngle = nil
  if type(angle) == "number" then
    writeField(record, "minimapPos", angle)
  end
end

---The object changed: redraw the icon when an icon attribute did.
---@param object table
---@param attribute string
function dispatch.attributeChanged(object, attribute)
  local record = launchers[object.name]
  if record ~= nil and ICON_ATTRIBUTES[attribute] then
    drawIcon(record)
  end
end

-- Launcher methods -----------------------------------------------------------

---Show the button and save `hide = false`.
---@param self LauncherKit.Launcher
local function launcherShow(self)
  local record = requireRecord(self, "LauncherKit.Launcher:Show", 3)
  writeField(record, "hide", false)
  record.button:Show()
end

---Hide the button and save `hide = true`.
---@param self LauncherKit.Launcher
local function launcherHide(self)
  local record = requireRecord(self, "LauncherKit.Launcher:Hide", 3)
  writeField(record, "hide", true)
  record.button:Hide()
end

---Whether the button is shown.
---@param self LauncherKit.Launcher
---@return boolean
local function launcherIsShown(self)
  return requireRecord(self, "LauncherKit.Launcher:IsShown", 3).button:IsShown() == true
end

---Stop the button from being dragged and save `lock = true`.
---@param self LauncherKit.Launcher
local function launcherLock(self)
  writeField(requireRecord(self, "LauncherKit.Launcher:Lock", 3), "lock", true)
end

---Let the button be dragged again and save `lock = false`.
---@param self LauncherKit.Launcher
local function launcherUnlock(self)
  writeField(requireRecord(self, "LauncherKit.Launcher:Unlock", 3), "lock", false)
end

---Whether the saved state says the button is locked.
---@param self LauncherKit.Launcher
---@return boolean
local function launcherIsLocked(self)
  return readField(requireRecord(self, "LauncherKit.Launcher:IsLocked", 3), "lock") == true
end

---Read the storage again: position and visibility, after the addon changed
---the table or switched profile.
---@param self LauncherKit.Launcher
local function launcherRefresh(self)
  applyStorage(requireRecord(self, "LauncherKit.Launcher:Refresh", 3))
end

---The minimap button, for an addon that styles or anchors it.
---@param self LauncherKit.Launcher
---@return table
local function launcherGetButton(self)
  return requireRecord(self, "LauncherKit.Launcher:GetButton", 3).button
end

-- Package public API ---------------------------------------------------------

---Put a minimap button for the BrokerKit object `objectName`, its state in
---`storage`.
---@param self LauncherKit
---@param objectName string
---@param storage LauncherKit.StorageSource
---@return LauncherKit.Launcher
local function packageRegister(self, objectName, storage)
  validateFacade(self, "LauncherKit:Register", 3)
  local object = requireObject(objectName, "LauncherKit:Register", 3)
  if isSecret(storage) or (type(storage) ~= "table" and type(storage) ~= "function") then
    error("LauncherKit:Register storage must be a table or a function returning one", 2)
  end
  if launchers[objectName] ~= nil then
    error("LauncherKit:Register " .. objectName .. " already has a launcher", 2)
  end
  local maxLaunchers = rawget(sharedLimits, "maxLaunchers")
  if rawget(state, "launcherCount") >= maxLaunchers then
    error(
      "LauncherKit:Register holds at most "
        .. maxLaunchers
        .. " launchers; raise maxLaunchers with LauncherKit:SetLimits",
      2
    )
  end
  local minimap = readGlobal("Minimap")
  local createFrame = readGlobal("CreateFrame")
  if type(minimap) ~= "table" or type(createFrame) ~= "function" then
    error(
      "LauncherKit:Register needs the client's Minimap and CreateFrame, which this host does not have",
      2
    )
  end

  local launcher = setmetatable({}, LAUNCHER_METATABLE)
  local button, icon = buildButton(createFrame, minimap)
  ---@type LauncherKit.Record
  local record = {
    schema = RECORD_SCHEMA,
    name = objectName,
    object = object,
    storage = storage,
    launcher = launcher,
    button = button,
    icon = icon,
    -- The listener finds the record by name, so it may connect before the
    -- record is stored: nothing changes the object in between.
    connection = object:OnChange(scripts.onAttribute),
    dragging = false,
  }
  launchers[objectName] = record
  records[launcher] = record
  buttons[record.button] = record
  rawset(state, "launcherCount", rawget(state, "launcherCount") + 1)
  drawIcon(record)
  applyStorage(record)
  return launcher
end

---The launcher of the object `objectName`, or `nil`.
---@param self LauncherKit
---@param objectName string
---@return LauncherKit.Launcher?
local function packageGet(self, objectName)
  validateFacade(self, "LauncherKit:Get", 3)
  if isSecret(objectName) then
    error("LauncherKit:Get objectName must not be a secret value", 2)
  end
  if type(objectName) ~= "string" or objectName == "" then
    error("LauncherKit:Get objectName must be a non-empty string", 2)
  end
  local record = launchers[objectName]
  return record and record.launcher or nil
end

---List the object in Blizzard's AddonCompartment (Retail): its label or
---name, its icon, its `OnClick` and its tooltip.
---@param self LauncherKit
---@param objectName string
---@return true|nil added
---@return string? reason `"unavailable"` (no AddonCompartment) or `"already"`
local function packageAddToCompartment(self, objectName)
  validateFacade(self, "LauncherKit:AddToCompartment", 3)
  local object = requireObject(objectName, "LauncherKit:AddToCompartment", 3)
  local frame = readGlobal("AddonCompartmentFrame")
  if type(frame) ~= "table" or type(frame.RegisterAddon) ~= "function" then
    return nil, REASON_UNAVAILABLE
  end
  if compartment[objectName] then
    return nil, REASON_ALREADY
  end
  local label = object.label
  local icon = object.icon
  frame:RegisterAddon({
    text = (type(label) == "string" and label ~= "") and label or objectName,
    icon = (type(icon) == "string" or type(icon) == "number") and icon or nil,
    func = function(_, inputData)
      dispatch.compartmentClick(objectName, inputData)
    end,
    funcOnEnter = function(entryButton)
      dispatch.compartmentEnter(objectName, entryButton)
    end,
    funcOnLeave = function(entryButton)
      dispatch.compartmentLeave(objectName, entryButton)
    end,
  })
  compartment[objectName] = true
  return true
end

---A click on the compartment entry: the object's `OnClick` with the
---compartment frame and the mouse button.
---@param objectName string
---@param inputData table?
function dispatch.compartmentClick(objectName, inputData)
  local object = BrokerKit:Get(objectName)
  local frame = readGlobal("AddonCompartmentFrame")
  if object ~= nil and type(object.OnClick) == "function" and type(frame) == "table" then
    local mouseButton = type(inputData) == "table" and inputData.buttonName or "LeftButton"
    protectedCall(object.OnClick, frame, mouseButton)
  end
end

---The cursor on the compartment entry: the object's tooltip.
---@param objectName string
---@param entryButton table
function dispatch.compartmentEnter(objectName, entryButton)
  local object = BrokerKit:Get(objectName)
  if object ~= nil and type(object.OnTooltipShow) == "function" then
    showTooltip(entryButton, "ANCHOR_RIGHT", object.OnTooltipShow)
  end
end

---The cursor leaves the compartment entry: its tooltip is hidden.
---@param _ string
---@param entryButton table
function dispatch.compartmentLeave(_, entryButton)
  hideTooltipOf(entryButton)
end

---Change any subset of the shared limits. Every value is checked before any
---changes. Lowering `maxLaunchers` keeps every launcher and refuses the next.
---@param self LauncherKit
---@param limits LauncherKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "LauncherKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("LauncherKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxLaunchers" then
      error("LauncherKit:SetLimits limits holds an unknown field; it accepts maxLaunchers", 2)
    end
    if isSecret(value) then
      error("LauncherKit:SetLimits limits.maxLaunchers must not be a secret value", 2)
    end
    if not isLauncherLimit(value) then
      error(
        "LauncherKit:SetLimits limits.maxLaunchers must be an integer from 1 to "
          .. LAUNCHERS_CEILING,
        2
      )
    end
  end
  -- `rawget`, as the loop above read the fields: a value a metatable's
  -- `__index` hands out was never checked and must not become the limit.
  local maxLaunchers = rawget(limits, "maxLaunchers")
  if type(maxLaunchers) ~= "nil" then
    rawset(sharedLimits, "maxLaunchers", maxLaunchers)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self LauncherKit
---@return LauncherKit.Limits limits
local function packageGetLimits(self)
  validateFacade(self, "LauncherKit:GetLimits", 3)
  return { maxLaunchers = rawget(sharedLimits, "maxLaunchers") }
end

-- Commit ---------------------------------------------------------------------

rawset(LauncherPrototype, "Show", launcherShow)
rawset(LauncherPrototype, "Hide", launcherHide)
rawset(LauncherPrototype, "IsShown", launcherIsShown)
rawset(LauncherPrototype, "Lock", launcherLock)
rawset(LauncherPrototype, "Unlock", launcherUnlock)
rawset(LauncherPrototype, "IsLocked", launcherIsLocked)
rawset(LauncherPrototype, "Refresh", launcherRefresh)
rawset(LauncherPrototype, "GetButton", launcherGetButton)

rawset(LauncherKit, "API", API_GENERATION)
rawset(LauncherKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(LauncherKit, "MAX_LAUNCHERS", MAX_LAUNCHERS)
rawset(LauncherKit, "LAUNCHERS_CEILING", LAUNCHERS_CEILING)
rawset(LauncherKit, "DEFAULT_ANGLE", DEFAULT_ANGLE)
rawset(LauncherKit, "Register", packageRegister)
rawset(LauncherKit, "Get", packageGet)
rawset(LauncherKit, "AddToCompartment", packageAddToCompartment)
rawset(LauncherKit, "SetLimits", packageSetLimits)
rawset(LauncherKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(LauncherKit) or not validateCurrentState(LauncherKit) then
  error("MoltenCodes LauncherKit package state is corrupted or incomplete", 2)
end
for index = 1, #LAUNCHER_METHODS do
  if type(rawget(LauncherPrototype, LAUNCHER_METHODS[index])) ~= "function" then
    error("MoltenCodes LauncherKit package state is corrupted or incomplete", 2)
  end
end

return LauncherKit
