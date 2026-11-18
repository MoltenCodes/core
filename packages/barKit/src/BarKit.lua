-- MoltenCodes BarKit
--
-- Status and timer bars: what LibCandyBar-3.0 gives boss-timer and cooldown
-- addons, and what unit-frame addons build by hand. A bar has a label, an
-- icon, a value text and a colour, and either shows a value between a
-- minimum and a maximum or counts a duration down with the remaining time
-- drawn as `1:23` or `9.4`, pausable, with a callback when it runs out.
--
-- A bar is the client's own `StatusBar`, which takes a Retail 12.x secret
-- value (a unit's health or power) as it is, so a bar can show what an addon
-- may not read: `SetValue` and `SetMinMax` pass secrets straight through.
-- Bars come from a PoolKit pool that keeps every released frame, because the
-- client never frees one; a released bar is cleared of every text, icon,
-- colour, value, timer and callback.
--
-- BarKit requires Registry API 2 and PoolKit API 1. It reads at call time
-- `CreateFrame`, `UIParent`, `GetTime` and `geterrorhandler`, and
-- `issecretvalue` once at load (again on each check only when the host had
-- none at load).
--
-- Contents
-- --------
--   Constants ............. identity, limits, look
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, the clock
--   Argument checks ....... receivers, texts, numbers, colours, limits
--   Frames ................ the bar factory and reset
--   Timers ................ the countdown and its text
--   Bar methods ........... SetLabel, SetValue, Start, Pause, ...
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "barKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local STATE_SCHEMA = 1

-- Every bar record carries the layout it was built with, so a later revision
-- that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The default and the ceiling of `maxBars`, the bars acquired at once. Each
-- is a frame the session keeps, so there is no unbounded setting.
local MAX_BARS, BARS_CEILING = 64, 512

-- A new bar's size and look: the client's own status bar texture.
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 200, 18
local DEFAULT_TEXTURE = [[Interface\TargetingFrame\UI-StatusBar]]
local DEFAULT_COLOR = { 0.2, 0.6, 1, 1 }
local DEFAULT_BACKGROUND = { 0, 0, 0, 0.5 }
local TEXT_INSET = 4

-- Below this many seconds the time text shows tenths.
local TENTHS_BELOW = 10

-- The options each call accepts.
local ACQUIRE_OPTIONS = { width = true, height = true, texture = true, parent = true }
local START_OPTIONS = { onFinished = true, fill = true, releaseOnFinish = true }
local TEXT_OPTIONS = { allowSecret = true }

-- The `__metatable` of every bar handle. It hides the handle's metatable.
local BAR_METATABLE_TAG = "BarKit.Bar"

local FACADE_METHODS = { "Acquire", "Release", "SetLimits", "GetLimits" }
local BAR_METHODS = {
  "SetLabel",
  "SetValueText",
  "SetIcon",
  "SetColor",
  "SetBackgroundColor",
  "SetMinMax",
  "SetValue",
  "Start",
  "Pause",
  "Resume",
  "Stop",
  "IsRunning",
  "IsPaused",
  "GetRemaining",
  "GetFrame",
}

-- Public types ---------------------------------------------------------------

---The options of `Acquire`.
---@class BarKit.AcquireOptions
---@field width number? Default `200`.
---@field height number? Default `18`.
---@field texture (string|integer)? The fill texture; default the client's status bar.
---@field parent table? The frame the bar is a child of; default `UIParent`.

---The options of `Start`.
---@class BarKit.StartOptions
---@field onFinished fun(bar: BarKit.Bar)? Called once when the time runs out.
---@field fill boolean? Fill from empty instead of draining from full.
---@field releaseOnFinish boolean? Release the bar when the time runs out, after `onFinished`.

---A status or timer bar.
---@class BarKit.Bar
---@field SetLabel fun(self: BarKit.Bar, text: (string|number)?, options: { allowSecret: boolean? }?)
---@field SetValueText fun(self: BarKit.Bar, text: (string|number)?, options: { allowSecret: boolean? }?)
---@field SetIcon fun(self: BarKit.Bar, texture: (string|integer)?)
---@field SetColor fun(self: BarKit.Bar, r: number, g: number, b: number, a: number?)
---@field SetBackgroundColor fun(self: BarKit.Bar, r: number, g: number, b: number, a: number?)
---@field SetMinMax fun(self: BarKit.Bar, minimum: number, maximum: number)
---@field SetValue fun(self: BarKit.Bar, value: number)
---@field Start fun(self: BarKit.Bar, duration: number, options: BarKit.StartOptions?)
---@field Pause fun(self: BarKit.Bar): boolean
---@field Resume fun(self: BarKit.Bar): boolean
---@field Stop fun(self: BarKit.Bar): boolean
---@field IsRunning fun(self: BarKit.Bar): boolean
---@field IsPaused fun(self: BarKit.Bar): boolean
---@field GetRemaining fun(self: BarKit.Bar): number?
---@field GetFrame fun(self: BarKit.Bar): table

---The shared limits.
---@class BarKit.Limits
---@field maxBars integer Bars acquired at once: 1 to 512; default `64`.

---The BarKit package facade published through Registry.
---@class BarKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_BARS integer Default of `maxBars` (`64`).
---@field BARS_CEILING integer The highest `maxBars` accepts (`512`).
---@field Acquire fun(self: BarKit, options: BarKit.AcquireOptions?): BarKit.Bar
---@field Release fun(self: BarKit, bar: BarKit.Bar)
---@field SetLimits fun(self: BarKit, limits: BarKit.Limits)
---@field GetLimits fun(self: BarKit): BarKit.Limits

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
  error("MoltenCodes BarKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes BarKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit keeps every bar frame for reuse.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
  type(PoolKit) ~= "table"
  or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
  or type(rawget(PoolKit, "New")) ~= "function"
then
  error("MoltenCodes BarKit requires PoolKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local mathFloor, mathMax, stringFormat = math.floor, math.max, string.format

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete BarKit API 1 surface.
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

---Whether `value` is an exact integer from 1 to the ceiling.
---@param value any
---@return boolean
local function isBarLimit(value)
  return type(value) == "number" and value >= 1 and value <= BARS_CEILING and value % 1 == 0
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
    and isBarLimit(rawget(limits, "maxBars"))
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "frames")) == "table"
    and type(rawget(currentState, "acquiredCount")) == "number"
    and type(rawget(currentState, "barPrototype")) == "table"
    and type(rawget(currentState, "barMetatable")) == "table"
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
-- and register this one. What stays here is what only BarKit can answer.
local BarKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes BarKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if BarKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(BarKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes BarKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The pool and the frames hold
  -- the closures below for the session, so they look their behaviour up here.
  local dispatch = {}
  local barPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxBars = MAX_BARS },
    -- Handle to record, and bar frame to record, while acquired.
    records = {},
    frames = {},
    acquiredCount = 0,
    -- The pool, made on first use (it needs `CreateFrame`).
    pool = false,
    barPrototype = barPrototype,
    barMetatable = { __index = barPrototype, __metatable = BAR_METATABLE_TAG },
    dispatch = dispatch,
    scripts = {
      build = function()
        return dispatch.build()
      end,
      reset = function(frame)
        dispatch.reset(frame)
      end,
      OnUpdate = function(frame)
        dispatch.tick(frame)
      end,
    },
  }
  rawset(BarKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes BarKit package state is corrupted or incomplete", 2)
end

---@type table<table, table>
local records = rawget(state, "records")
---@type table<table, table>
local frames = rawget(state, "frames")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local BarPrototype = rawget(state, "barPrototype")
local BAR_METATABLE = rawget(state, "barMetatable")
local sharedLimits = rawget(state, "limits")

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

---The client's time in seconds, `GetTime`.
---@return number
local function now()
  local getTime = readGlobal("GetTime")
  if type(getTime) ~= "function" then
    return 0
  end
  return getTime()
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- BarKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

-- shared:begin validateFacade 1 __FACADE__=BarKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the BarKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= BarKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the BarKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---The record of an acquired bar handle, or raise at the caller.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if not isSecret(receiver) and type(receiver) == "table" then
    record = records[receiver]
  end
  if record == nil then
    error(
      label
        .. " must be called on an acquired BarKit bar; use bar:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

---Raise at the caller unless `options` is `nil` or a table holding only the
---fields `accepted` names.
---@param options any
---@param accepted table<string, boolean>
---@param list string the accepted fields, for the message
---@param label string
---@param level integer stack level the failure is reported at
local function validateOptions(options, accepted, list, label, level)
  if type(options) == "nil" then
    return
  end
  if isSecret(options) or type(options) ~= "table" then
    error(label .. " options must be a table or nil", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not accepted[key] then
      error(label .. " options holds an unknown field; it accepts " .. list, level)
    end
  end
end

---Raise at the caller unless `value` is a finite number above 0 (or `nil`
---when `optional`).
---@param value any
---@param where string
---@param optional boolean
---@param level integer stack level the failure is reported at
local function validatePositive(value, where, optional, level)
  if isSecret(value) then
    error(where .. " must not be a secret value", level)
  end
  if type(value) == "nil" and optional then
    return
  end
  if type(value) ~= "number" or not (value > 0 and value < math.huge) then
    error(where .. " must be a number above 0", level)
  end
end

---Raise at the caller unless `value` is a colour component from 0 to 1, or
---`nil` when `optional`.
---@param value any
---@param where string
---@param optional boolean
---@param level integer stack level the failure is reported at
local function validateComponent(value, where, optional, level)
  if isSecret(value) then
    error(where .. " must not be a secret value", level)
  end
  if type(value) == "nil" and optional then
    return
  end
  if type(value) ~= "number" or not (value >= 0 and value <= 1) then
    error(where .. " must be a number from 0 to 1", level)
  end
end

---Raise at the caller unless `value` is a number or a secret (passed to the
---client's status bar as it is).
---@param value any
---@param where string
---@param level integer stack level the failure is reported at
local function validateBarNumber(value, where, level)
  if not isSecret(value) and type(value) ~= "number" then
    error(where .. " must be a number", level)
  end
end

---Raise at the caller unless `value` is a texture path, a FileDataID or
---`nil`.
---@param value any
---@param where string
---@param level integer stack level the failure is reported at
local function validateTexture(value, where, level)
  if isSecret(value) then
    error(where .. " must not be a secret value", level)
  end
  local kind = type(value)
  if kind ~= "nil" and kind ~= "string" and kind ~= "number" then
    error(where .. " must be a texture path, a FileDataID or nil", level)
  end
end

-- Frames ---------------------------------------------------------------------

---A bar frame: a status bar with a background, an icon on its left and two
---texts on it.
---@return table frame
function dispatch.build()
  local frame = readGlobal("CreateFrame")("StatusBar")
  frame:Hide()
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  frame.background = background
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("RIGHT", frame, "LEFT", 0, 0)
  frame.icon = icon
  local label = frame:CreateFontString(nil, "OVERLAY")
  label:SetFontObject("GameFontHighlightSmall")
  label:SetPoint("LEFT", frame, "LEFT", TEXT_INSET, 0)
  label:SetJustifyH("LEFT")
  frame.label = label
  local valueText = frame:CreateFontString(nil, "OVERLAY")
  valueText:SetFontObject("GameFontHighlightSmall")
  valueText:SetPoint("RIGHT", frame, "RIGHT", -TEXT_INSET, 0)
  valueText:SetJustifyH("RIGHT")
  frame.valueText = valueText
  return frame
end

---Empty a font string. `ClearText` also removes the client's secret text
---aspect, which a font string that showed a secret keeps through a plain
---`SetText` (measured on Retail 12.1.0 b69933 for WidgetKit, whose
---docs/API.md records it): without it, the next text drawn there would read
---back as a secret. Every promised client has `ClearText` (Blizzard's
---`SimpleFontStringAPIDocumentation.lua` on `live`, `classic` and
---`classic_era`); a host without it gets `SetText(nil)`.
---@param fontString table
local function clearFontString(fontString)
  if type(fontString.ClearText) == "function" then
    fontString:ClearText()
  else
    fontString:SetText(nil)
  end
end

---Return a bar frame to the pool with nothing of its last use left.
---@param frame table
function dispatch.reset(frame)
  frame:Hide()
  frame:SetScript("OnUpdate", nil)
  frame:ClearAllPoints()
  clearFontString(frame.label)
  clearFontString(frame.valueText)
  frame.icon:SetTexture(nil)
  frame.icon:Hide()
  frame:SetMinMaxValues(0, 1)
  frame:SetValue(0)
  frame:SetReverseFill(false)
end

---The pool, made on first use.
---@return table
local function pool()
  local barPool = rawget(state, "pool")
  if not barPool then
    barPool = PoolKit:New({
      create = scripts.build,
      reset = scripts.reset,
      maxRetained = PoolKit.UNBOUNDED,
      maxCreated = BARS_CEILING,
    })
    rawset(state, "pool", barPool)
  end
  return barPool
end

---Draw the icon at the bar's height, or hide it.
---@param record table
local function drawIcon(record)
  local icon = record.frame.icon
  if record.iconTexture then
    local height = record.height
    icon:SetSize(height, height)
    icon:SetTexture(record.iconTexture)
    icon:Show()
  else
    icon:SetTexture(nil)
    icon:Hide()
  end
end

-- Timers ---------------------------------------------------------------------

---The remaining time as a bar shows it: `1:05:03`, `1:23`, `12` or `9.4`.
---@param remaining number
---@return string
local function timeText(remaining)
  if remaining < TENTHS_BELOW then
    return stringFormat("%.1f", mathFloor(remaining * 10) / 10)
  end
  local seconds = mathFloor(remaining)
  if seconds < 60 then
    return tostring(seconds)
  end
  local minutes = mathFloor(seconds / 60)
  if minutes < 60 then
    return stringFormat("%d:%02d", minutes, seconds % 60)
  end
  return stringFormat("%d:%02d:%02d", mathFloor(minutes / 60), minutes % 60, seconds % 60)
end

---The seconds left of a running or paused timer.
---@param record table
---@return number
local function remainingOf(record)
  if record.pausedRemaining then
    return record.pausedRemaining
  end
  return mathMax(0, record.endsAt - now())
end

---Draw the timer's fill and, when it changed, its text.
---@param record table
---@param remaining number
local function drawTimer(record, remaining)
  local frame = record.frame
  local duration = record.duration
  frame:SetValue(record.fill and (duration - remaining) or remaining)
  local text = timeText(remaining)
  if text ~= record.shownTime then
    record.shownTime = text
    if record.secretValueText then
      record.secretValueText = false
      clearFontString(frame.valueText)
    end
    frame.valueText:SetText(text)
  end
end

---Every frame of a running timer: draw it, and finish it at zero.
---@param frame table
function dispatch.tick(frame)
  local record = frames[frame]
  if record == nil or not record.endsAt then
    return
  end
  local remaining = remainingOf(record)
  drawTimer(record, remaining)
  if remaining > 0 then
    return
  end
  frame:SetScript("OnUpdate", nil)
  local onFinished, release = record.onFinished, record.releaseOnFinish
  record.endsAt, record.onFinished, record.releaseOnFinish = false, false, false
  if onFinished then
    local ok, failure = pcall(onFinished, record.handle)
    if not ok then
      reportError(failure)
    end
  end
  -- `onFinished` may have started the bar again or released it; a bar
  -- running a new timer is the addon's again, and a released one is gone.
  if release and records[record.handle] == record and not record.endsAt then
    BarKit:Release(record.handle)
  end
end

---End a timer without calling its callback.
---@param record table
local function clearTimer(record)
  record.endsAt, record.pausedRemaining = false, false
  record.onFinished, record.releaseOnFinish = false, false
  record.frame:SetScript("OnUpdate", nil)
end

-- Bar methods ----------------------------------------------------------------

---Set one of the bar's texts.
---@param record table
---@param fontString table
---@param text any
---@param options any
---@param label string
local function setText(record, fontString, text, options, label)
  validateOptions(options, TEXT_OPTIONS, "allowSecret", label, 4)
  local allowSecret = type(options) == "table" and options.allowSecret
  if type(allowSecret) ~= "nil" and (isSecret(allowSecret) or type(allowSecret) ~= "boolean") then
    error(label .. " options.allowSecret must be a boolean", 3)
  end
  if isSecret(text) then
    if not allowSecret then
      error(label .. " text must not be a secret value; pass { allowSecret = true } to draw one", 3)
    end
  elseif type(text) ~= "nil" and type(text) ~= "string" and type(text) ~= "number" then
    error(label .. " text must be a string, a number or nil", 3)
  end
  local isValueText = fontString == record.frame.valueText
  local secretField = isValueText and "secretValueText" or "secretLabel"
  local secret = isSecret(text)
  if not secret and record[secretField] then
    -- The font string showed a secret: remove the client's aspect first, so
    -- this plain text reads back as itself.
    clearFontString(fontString)
  end
  record[secretField] = secret
  fontString:SetText((not secret and type(text) == "number") and tostring(text) or text)
  if isValueText then
    -- A text set by hand replaces the time text until the next tick.
    record.shownTime = false
  end
end

---Set the label on the bar's left; `nil` clears it.
---@param self BarKit.Bar
---@param text (string|number)?
---@param options { allowSecret: boolean? }?
local function barSetLabel(self, text, options)
  local record = requireRecord(self, "BarKit.Bar:SetLabel", 3)
  setText(record, record.frame.label, text, options, "BarKit.Bar:SetLabel")
end

---Set the text on the bar's right (a running timer writes its time there).
---@param self BarKit.Bar
---@param text (string|number)?
---@param options { allowSecret: boolean? }?
local function barSetValueText(self, text, options)
  local record = requireRecord(self, "BarKit.Bar:SetValueText", 3)
  setText(record, record.frame.valueText, text, options, "BarKit.Bar:SetValueText")
end

---Show `texture` as a square icon left of the bar; `nil` removes it.
---@param self BarKit.Bar
---@param texture (string|integer)?
local function barSetIcon(self, texture)
  local record = requireRecord(self, "BarKit.Bar:SetIcon", 3)
  validateTexture(texture, "BarKit.Bar:SetIcon texture", 3)
  record.iconTexture = texture or false
  drawIcon(record)
end

---Colour the fill.
---@param self BarKit.Bar
---@param r number
---@param g number
---@param b number
---@param a number?
local function barSetColor(self, r, g, b, a)
  local label = "BarKit.Bar:SetColor"
  local record = requireRecord(self, label, 3)
  validateComponent(r, label .. " r", false, 3)
  validateComponent(g, label .. " g", false, 3)
  validateComponent(b, label .. " b", false, 3)
  validateComponent(a, label .. " a", true, 3)
  record.frame:SetStatusBarColor(r, g, b, a or 1)
end

---Colour the background behind the fill.
---@param self BarKit.Bar
---@param r number
---@param g number
---@param b number
---@param a number?
local function barSetBackgroundColor(self, r, g, b, a)
  local label = "BarKit.Bar:SetBackgroundColor"
  local record = requireRecord(self, label, 3)
  validateComponent(r, label .. " r", false, 3)
  validateComponent(g, label .. " g", false, 3)
  validateComponent(b, label .. " b", false, 3)
  validateComponent(a, label .. " a", true, 3)
  record.frame.background:SetColorTexture(r, g, b, a or 1)
end

---Set the range a status value is shown in. Secrets are passed to the
---client's status bar as they are; a running timer is stopped.
---@param self BarKit.Bar
---@param minimum number
---@param maximum number
local function barSetMinMax(self, minimum, maximum)
  local label = "BarKit.Bar:SetMinMax"
  local record = requireRecord(self, label, 3)
  validateBarNumber(minimum, label .. " minimum", 3)
  validateBarNumber(maximum, label .. " maximum", 3)
  if not isSecret(minimum) and not isSecret(maximum) and minimum > maximum then
    error(label .. " minimum must not be greater than maximum", 2)
  end
  clearTimer(record)
  record.frame:SetMinMaxValues(minimum, maximum)
end

---Show a status value. A secret is passed to the client's status bar as it
---is; a running timer is stopped.
---@param self BarKit.Bar
---@param value number
local function barSetValue(self, value)
  local record = requireRecord(self, "BarKit.Bar:SetValue", 3)
  validateBarNumber(value, "BarKit.Bar:SetValue value", 3)
  clearTimer(record)
  record.frame:SetValue(value)
end

---Count `duration` seconds down, draining the bar (or filling it with
---`fill`), and call `onFinished` at zero. A timer already running is
---replaced without its callback.
---@param self BarKit.Bar
---@param duration number
---@param options BarKit.StartOptions?
local function barStart(self, duration, options)
  local label = "BarKit.Bar:Start"
  local record = requireRecord(self, label, 3)
  validatePositive(duration, label .. " duration", false, 3)
  validateOptions(options, START_OPTIONS, "onFinished, fill and releaseOnFinish", label, 3)
  local onFinished, fill, releaseOnFinish = nil, false, false
  if options then
    onFinished = options.onFinished
    if type(onFinished) ~= "nil" and type(onFinished) ~= "function" then
      error(label .. " options.onFinished must be a function or nil", 2)
    end
    for _, field in ipairs({ "fill", "releaseOnFinish" }) do
      local flag = options[field]
      if type(flag) ~= "nil" and (isSecret(flag) or type(flag) ~= "boolean") then
        error(label .. " options." .. field .. " must be a boolean", 2)
      end
    end
    fill, releaseOnFinish = options.fill == true, options.releaseOnFinish == true
  end
  clearTimer(record)
  record.duration = duration
  record.endsAt = now() + duration
  record.fill = fill
  record.onFinished = onFinished or false
  record.releaseOnFinish = releaseOnFinish
  record.shownTime = false
  local frame = record.frame
  frame:SetMinMaxValues(0, duration)
  drawTimer(record, duration)
  frame:SetScript("OnUpdate", scripts.OnUpdate)
end

---Hold a running timer where it is: `true`, or `false` when none runs.
---@param self BarKit.Bar
---@return boolean
local function barPause(self)
  local record = requireRecord(self, "BarKit.Bar:Pause", 3)
  if not record.endsAt or record.pausedRemaining then
    return false
  end
  record.pausedRemaining = remainingOf(record)
  record.frame:SetScript("OnUpdate", nil)
  return true
end

---Let a paused timer run on from where it was: `true`, or `false` when none
---is paused.
---@param self BarKit.Bar
---@return boolean
local function barResume(self)
  local record = requireRecord(self, "BarKit.Bar:Resume", 3)
  if not record.pausedRemaining then
    return false
  end
  record.endsAt = now() + record.pausedRemaining
  record.pausedRemaining = false
  record.frame:SetScript("OnUpdate", scripts.OnUpdate)
  return true
end

---End the timer without its callback; the bar shows where it stopped.
---`true`, or `false` when no timer ran.
---@param self BarKit.Bar
---@return boolean
local function barStop(self)
  local record = requireRecord(self, "BarKit.Bar:Stop", 3)
  if not record.endsAt then
    return false
  end
  clearTimer(record)
  return true
end

---Whether a timer is running or paused.
---@param self BarKit.Bar
---@return boolean
local function barIsRunning(self)
  return requireRecord(self, "BarKit.Bar:IsRunning", 3).endsAt ~= false
end

---Whether a timer is paused.
---@param self BarKit.Bar
---@return boolean
local function barIsPaused(self)
  return requireRecord(self, "BarKit.Bar:IsPaused", 3).pausedRemaining ~= false
end

---The seconds left of a running or paused timer, or `nil`.
---@param self BarKit.Bar
---@return number?
local function barGetRemaining(self)
  local record = requireRecord(self, "BarKit.Bar:GetRemaining", 3)
  if not record.endsAt then
    return nil
  end
  return remainingOf(record)
end

---The bar's frame, a `StatusBar`, for an addon that anchors or styles it.
---Its parts are `frame.icon`, `frame.label`, `frame.valueText` and
---`frame.background`.
---@param self BarKit.Bar
---@return table
local function barGetFrame(self)
  return requireRecord(self, "BarKit.Bar:GetFrame", 3).frame
end

-- Package public API ---------------------------------------------------------

---Borrow a bar, shown, empty, at its default colours.
---@param self BarKit
---@param options BarKit.AcquireOptions?
---@return BarKit.Bar
local function packageAcquire(self, options)
  local label = "BarKit:Acquire"
  validateFacade(self, label, 3)
  validateOptions(options, ACQUIRE_OPTIONS, "width, height, texture and parent", label, 3)
  options = options or {}
  validatePositive(options.width, label .. " options.width", true, 3)
  validatePositive(options.height, label .. " options.height", true, 3)
  validateTexture(options.texture, label .. " options.texture", 3)
  local parent = options.parent
  if type(parent) ~= "nil" and (isSecret(parent) or type(parent) ~= "table") then
    error(label .. " options.parent must be a frame or nil", 2)
  end
  local maxBars = rawget(sharedLimits, "maxBars")
  if rawget(state, "acquiredCount") >= maxBars then
    error(
      label .. " holds at most " .. maxBars .. " bars at once; release one, or raise maxBars",
      2
    )
  end
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" or type(readGlobal("CreateFrame")) ~= "function" then
    error(label .. " needs the client's CreateFrame and UIParent, which this host does not have", 2)
  end
  if parent == nil then
    parent = uiParent
  end
  local frame, reason = pool():Acquire()
  if frame == nil then
    error(label .. " could not get a bar frame: " .. tostring(reason), 2)
  end
  local width, height = options.width or DEFAULT_WIDTH, options.height or DEFAULT_HEIGHT
  frame:SetParent(parent)
  frame:SetSize(width, height)
  frame:SetStatusBarTexture(options.texture or DEFAULT_TEXTURE)
  frame:SetStatusBarColor(DEFAULT_COLOR[1], DEFAULT_COLOR[2], DEFAULT_COLOR[3], DEFAULT_COLOR[4])
  frame.background:SetColorTexture(
    DEFAULT_BACKGROUND[1],
    DEFAULT_BACKGROUND[2],
    DEFAULT_BACKGROUND[3],
    DEFAULT_BACKGROUND[4]
  )
  frame:Show()
  local handle = setmetatable({}, BAR_METATABLE)
  local record = {
    schema = RECORD_SCHEMA,
    handle = handle,
    frame = frame,
    height = height,
    iconTexture = false,
    endsAt = false,
    pausedRemaining = false,
    duration = 0,
    fill = false,
    onFinished = false,
    releaseOnFinish = false,
    shownTime = false,
    secretLabel = false,
    secretValueText = false,
  }
  drawIcon(record)
  records[handle] = record
  frames[frame] = record
  rawset(state, "acquiredCount", rawget(state, "acquiredCount") + 1)
  return handle
end

---Give a bar back to the pool, cleared; its handle is refused afterwards.
---@param self BarKit
---@param bar BarKit.Bar
local function packageRelease(self, bar)
  validateFacade(self, "BarKit:Release", 3)
  local record = nil
  if not isSecret(bar) and type(bar) == "table" then
    record = records[bar]
  end
  if record == nil then
    error("BarKit:Release bar must be an acquired BarKit bar", 2)
  end
  clearTimer(record)
  records[bar] = nil
  frames[record.frame] = nil
  rawset(state, "acquiredCount", rawget(state, "acquiredCount") - 1)
  pool():Release(record.frame)
end

---Change `maxBars`. Lowering it keeps every bar and refuses the next.
---@param self BarKit
---@param limits BarKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "BarKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("BarKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxBars" then
      error("BarKit:SetLimits limits holds an unknown field; it accepts maxBars", 2)
    end
    if isSecret(value) then
      error("BarKit:SetLimits limits.maxBars must not be a secret value", 2)
    end
    if not isBarLimit(value) then
      error("BarKit:SetLimits limits.maxBars must be an integer from 1 to " .. BARS_CEILING, 2)
    end
  end
  if type(limits.maxBars) ~= "nil" then
    rawset(sharedLimits, "maxBars", limits.maxBars)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self BarKit
---@return BarKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "BarKit:GetLimits", 3)
  return { maxBars = rawget(sharedLimits, "maxBars") }
end

-- Commit ---------------------------------------------------------------------

rawset(BarPrototype, "SetLabel", barSetLabel)
rawset(BarPrototype, "SetValueText", barSetValueText)
rawset(BarPrototype, "SetIcon", barSetIcon)
rawset(BarPrototype, "SetColor", barSetColor)
rawset(BarPrototype, "SetBackgroundColor", barSetBackgroundColor)
rawset(BarPrototype, "SetMinMax", barSetMinMax)
rawset(BarPrototype, "SetValue", barSetValue)
rawset(BarPrototype, "Start", barStart)
rawset(BarPrototype, "Pause", barPause)
rawset(BarPrototype, "Resume", barResume)
rawset(BarPrototype, "Stop", barStop)
rawset(BarPrototype, "IsRunning", barIsRunning)
rawset(BarPrototype, "IsPaused", barIsPaused)
rawset(BarPrototype, "GetRemaining", barGetRemaining)
rawset(BarPrototype, "GetFrame", barGetFrame)

rawset(BarKit, "API", API_GENERATION)
rawset(BarKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(BarKit, "MAX_BARS", MAX_BARS)
rawset(BarKit, "BARS_CEILING", BARS_CEILING)
rawset(BarKit, "Acquire", packageAcquire)
rawset(BarKit, "Release", packageRelease)
rawset(BarKit, "SetLimits", packageSetLimits)
rawset(BarKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(BarKit) or not validateCurrentState(BarKit) then
  error("MoltenCodes BarKit package state is corrupted or incomplete", 2)
end
for index = 1, #BAR_METHODS do
  if type(rawget(BarPrototype, BAR_METHODS[index])) ~= "function" then
    error("MoltenCodes BarKit package state is corrupted or incomplete", 2)
  end
end

return BarKit
