-- MoltenCodes ToastKit
--
-- Short notifications that appear, stay a few seconds and fade: "profile
-- copied", "a new version is out", an addon's achievement-style note. A toast
-- has a title, an optional text and icon, and an optional click handler.
-- Toasts stack at one anchor on the screen, growing down or up, at most a few
-- at a time; the rest wait in a bounded queue. The cursor resting on a toast
-- holds it. A click runs the handler and dismisses the toast.
--
-- Toasts are frames of the package's own, from a PoolKit pool that keeps
-- every released frame, because the client never frees one. Blizzard's alert
-- system (`AlertFrame`) is never touched.
--
-- ToastKit requires Registry API 2 and PoolKit API 1. It reads at call time
-- `CreateFrame`, `UIParent` and `geterrorhandler`, and `issecretvalue` once at
-- load (again on each check only when the host had none at load).
--
-- Contents
-- --------
--   Constants ............. identity, limits, look, timing
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler
--   Argument checks ....... receivers, options, limits
--   Frames ................ the toast factory and reset
--   Stack ................. showing, stacking, ending and advancing
--   Toast methods ......... Dismiss, IsShown, IsQueued
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "toastKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local STATE_SCHEMA = 1

-- Every toast record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- `maxVisible`: toasts on screen at once; each is a frame the session keeps,
-- so it has a ceiling. `maxQueued`: toasts waiting; each is a Lua table, so
-- it opens to `UNBOUNDED`.
local MAX_VISIBLE, VISIBLE_CEILING = 5, 20
local MAX_QUEUED = 32

-- How long a toast stays by default, and the fade at the end of its life.
local DEFAULT_DURATION = 5
local FADE_SECONDS = 0.5

-- The look.
local WIDTH, HEIGHT = 260, 48
local GAP = 6
local ICON_SIZE = 32
local PADDING = 8
local BACKGROUND_COLOR = { 0.05, 0.05, 0.08, 0.9 }

-- Where the stack starts until `SetAnchor` moves it.
local DEFAULT_ANCHOR = { point = "TOP", x = 0, y = -120, direction = "DOWN" }

-- The points `SetAnchor` accepts, and the directions.
local POINTS = {
  TOP = true,
  BOTTOM = true,
  LEFT = true,
  RIGHT = true,
  CENTER = true,
  TOPLEFT = true,
  TOPRIGHT = true,
  BOTTOMLEFT = true,
  BOTTOMRIGHT = true,
}
local DIRECTIONS = { UP = 1, DOWN = -1 }

-- The options `Show` accepts.
local SHOW_OPTIONS = {
  title = true,
  text = true,
  icon = true,
  duration = true,
  onClick = true,
  data = true,
  key = true,
  allowSecret = true,
}

-- The `__metatable` of every toast handle. It hides the handle's metatable.
local TOAST_METATABLE_TAG = "ToastKit.Toast"

local FACADE_METHODS = { "Show", "DismissAll", "SetAnchor", "SetLimits", "GetLimits" }
local TOAST_METHODS = { "Dismiss", "IsShown", "IsQueued" }

-- Public types ---------------------------------------------------------------

---The options of `Show`.
---@class ToastKit.ShowOptions
---@field title string|number The toast's first line; required.
---@field text (string|number)? A second line.
---@field icon (string|integer)? A texture path or a FileDataID shown on the left.
---@field duration number? Seconds on screen; default `5`.
---@field onClick fun(data: any)? Called when the toast is clicked; the toast is dismissed after.
---@field data any Handed to `onClick`.
---@field key string? A toast shown or waiting under this key is updated and starts again.
---@field allowSecret boolean? Draw a secret `title` or `text` instead of refusing it.

---A toast, shown or waiting.
---@class ToastKit.Toast
---@field Dismiss fun(self: ToastKit.Toast): boolean
---@field IsShown fun(self: ToastKit.Toast): boolean
---@field IsQueued fun(self: ToastKit.Toast): boolean

---The shared limits.
---@class ToastKit.Limits
---@field maxVisible integer Toasts on screen at once: 1 to 20; default `5`.
---@field maxQueued integer|table Toasts waiting: a positive integer or `ToastKit.UNBOUNDED`; default `32`.

---The ToastKit package facade published through Registry.
---@class ToastKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_VISIBLE integer Default of `maxVisible` (`5`).
---@field VISIBLE_CEILING integer The highest `maxVisible` accepts (`20`).
---@field MAX_QUEUED integer Default of `maxQueued` (`32`).
---@field UNBOUNDED table Sentinel `maxQueued` accepts; the same table for every revision.
---@field Show fun(self: ToastKit, options: ToastKit.ShowOptions): ToastKit.Toast
---@field DismissAll fun(self: ToastKit): integer
---@field SetAnchor fun(self: ToastKit, point: string, x: number, y: number, direction: ("UP"|"DOWN")?)
---@field SetLimits fun(self: ToastKit, limits: ToastKit.Limits)
---@field GetLimits fun(self: ToastKit): ToastKit.Limits

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
  error("MoltenCodes ToastKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes ToastKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit keeps every toast frame for reuse.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
  type(PoolKit) ~= "table"
  or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
  or type(rawget(PoolKit, "New")) ~= "function"
then
  error("MoltenCodes ToastKit requires PoolKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local tableRemove = table.remove

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete ToastKit API 1 surface.
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

---Whether `value` is an exact integer of one or more.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value >= 1 and value ~= math.huge and value % 1 == 0
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  local unbounded = rawget(currentState, "unbounded")
  if type(limits) ~= "table" or type(unbounded) ~= "table" then
    return false
  end
  local maxVisible, maxQueued = rawget(limits, "maxVisible"), rawget(limits, "maxQueued")
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and isPositiveInteger(maxVisible)
    and maxVisible <= VISIBLE_CEILING
    and (maxQueued == unbounded or isPositiveInteger(maxQueued))
    and type(rawget(currentState, "visible")) == "table"
    and type(rawget(currentState, "queue")) == "table"
    and type(rawget(currentState, "byKey")) == "table"
    and type(rawget(currentState, "frames")) == "table"
    and type(rawget(currentState, "anchor")) == "table"
    and type(rawget(currentState, "toastPrototype")) == "table"
    and type(rawget(currentState, "toastMetatable")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "scripts")) == "table"
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
-- and register this one. What stays here is what only ToastKit can answer.
local ToastKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes ToastKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if ToastKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(ToastKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes ToastKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The pool and the frames hold
  -- the closures below for the session, so they look their behaviour up here.
  local dispatch = {}
  local toastPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    unbounded = {},
    limits = { maxVisible = MAX_VISIBLE, maxQueued = MAX_QUEUED },
    -- The records on screen, first one at the anchor; the records waiting.
    visible = {},
    queue = {},
    -- Key to record, and frame to record, while shown or waiting.
    byKey = {},
    frames = {},
    anchor = {
      point = DEFAULT_ANCHOR.point,
      x = DEFAULT_ANCHOR.x,
      y = DEFAULT_ANCHOR.y,
      direction = DEFAULT_ANCHOR.direction,
    },
    -- The pool, made on first use (it needs `CreateFrame`).
    pool = false,
    toastPrototype = toastPrototype,
    toastMetatable = { __index = toastPrototype, __metatable = TOAST_METATABLE_TAG },
    dispatch = dispatch,
    scripts = {
      build = function()
        return dispatch.build()
      end,
      reset = function(frame)
        dispatch.reset(frame)
      end,
      OnUpdate = function(frame, elapsed)
        dispatch.tick(frame, elapsed)
      end,
      OnMouseUp = function(frame)
        dispatch.click(frame)
      end,
    },
  }
  rawset(ToastKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes ToastKit package state is corrupted or incomplete", 2)
end

local visible = rawget(state, "visible")
local queue = rawget(state, "queue")
local byKey = rawget(state, "byKey")
---@type table<table, table>
local frames = rawget(state, "frames")
local anchor = rawget(state, "anchor")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local ToastPrototype = rawget(state, "toastPrototype")
local TOAST_METATABLE = rawget(state, "toastMetatable")
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

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- ToastKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

-- shared:begin validateFacade 1 __FACADE__=ToastKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the ToastKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= ToastKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the ToastKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---The record of a toast handle (shown, waiting or ended), or raise.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if
    not isSecret(receiver)
    and type(receiver) == "table"
    and getmetatable(receiver) == TOAST_METATABLE_TAG
  then
    record = rawget(receiver, "_record")
  end
  if type(record) ~= "table" then
    error(
      label .. " must be called on a ToastKit toast; use toast:" .. label:match("[^:]+$") .. "(...)",
      level
    )
  end
  return record
end

---Raise at the caller unless `value` is a text: a non-empty string or a
---number, `nil` when `optional`, a secret only with `allowSecret`.
---@param value any
---@param where string
---@param optional boolean
---@param allowSecret boolean
---@param level integer stack level the failure is reported at
local function validateText(value, where, optional, allowSecret, level)
  if isSecret(value) then
    if not allowSecret then
      error(where .. " must not be a secret value; pass allowSecret = true to draw one", level)
    end
    return
  end
  if (type(value) == "nil" and optional) or type(value) == "number" then
    return
  end
  if type(value) ~= "string" or value == "" then
    error(where .. " must be a non-empty string or a number", level)
  end
end

---Check `Show`'s options and return the fields of a record.
---@param options any
---@param level integer stack level the failure is reported at
---@return table fields
local function readShowOptions(options, level)
  local label = "ToastKit:Show"
  if isSecret(options) or type(options) ~= "table" then
    error(label .. " options must be a table", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not SHOW_OPTIONS[key] then
      error(
        label
          .. " options holds an unknown field; it accepts title, text, icon, duration, onClick, data, key and allowSecret",
        level
      )
    end
  end
  local allowSecret = options.allowSecret
  if type(allowSecret) ~= "nil" and (isSecret(allowSecret) or type(allowSecret) ~= "boolean") then
    error(label .. " options.allowSecret must be a boolean", level)
  end
  validateText(options.title, label .. " options.title", false, allowSecret == true, level + 1)
  validateText(options.text, label .. " options.text", true, allowSecret == true, level + 1)
  local icon = options.icon
  if
    isSecret(icon) or (type(icon) ~= "nil" and type(icon) ~= "string" and type(icon) ~= "number")
  then
    error(label .. " options.icon must be a texture path, a FileDataID or nil", level)
  end
  local duration = options.duration
  if
    type(duration) ~= "nil"
    and (
      isSecret(duration)
      or type(duration) ~= "number"
      or not (duration > 0 and duration < math.huge)
    )
  then
    error(label .. " options.duration must be a number above 0", level)
  end
  if type(options.onClick) ~= "nil" and type(options.onClick) ~= "function" then
    error(label .. " options.onClick must be a function or nil", level)
  end
  local key = options.key
  if type(key) ~= "nil" and (isSecret(key) or type(key) ~= "string" or key == "") then
    error(label .. " options.key must be a non-empty string", level)
  end
  return {
    title = options.title,
    text = options.text,
    icon = icon or false,
    duration = duration or DEFAULT_DURATION,
    onClick = options.onClick or false,
    data = options.data,
    key = key or false,
  }
end

-- Frames ---------------------------------------------------------------------

---A toast frame: a background, an icon and two lines of text, taking clicks.
---@return table frame
function dispatch.build()
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" then
    -- `Show` checked it; only a host that removed it since lands here.
    error("ToastKit needs the client's UIParent", 0)
  end
  local frame = readGlobal("CreateFrame")("Frame", nil, uiParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:EnableMouse(true)
  frame:Hide()
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  background:SetColorTexture(
    BACKGROUND_COLOR[1],
    BACKGROUND_COLOR[2],
    BACKGROUND_COLOR[3],
    BACKGROUND_COLOR[4]
  )
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("LEFT", frame, "LEFT", PADDING, 0)
  frame.icon = icon
  local title = frame:CreateFontString(nil, "ARTWORK")
  title:SetFontObject("GameFontNormal")
  title:SetJustifyH("LEFT")
  frame.title = title
  local text = frame:CreateFontString(nil, "ARTWORK")
  text:SetFontObject("GameFontHighlightSmall")
  text:SetJustifyH("LEFT")
  frame.text = text
  frame:SetScript("OnMouseUp", scripts.OnMouseUp)
  return frame
end

---Return a toast frame to the pool with nothing of its last use left.
---@param frame table
function dispatch.reset(frame)
  frame:Hide()
  frame:SetScript("OnUpdate", nil)
  frame:ClearAllPoints()
  frame:SetAlpha(1)
  frame.title:SetText(nil)
  frame.text:SetText(nil)
  frame.icon:SetTexture(nil)
end

---The pool, made on first use.
---@return table
local function pool()
  local toastPool = rawget(state, "pool")
  if not toastPool then
    toastPool = PoolKit:New({
      create = scripts.build,
      reset = scripts.reset,
      maxRetained = PoolKit.UNBOUNDED,
      maxCreated = VISIBLE_CEILING,
    })
    rawset(state, "pool", toastPool)
  end
  return toastPool
end

---Write `record`'s texts and icon into its frame.
---@param record table
local function draw(record)
  local frame = record.frame
  local left = PADDING
  if record.icon then
    frame.icon:SetTexture(record.icon)
    frame.icon:Show()
    left = PADDING * 2 + ICON_SIZE
  else
    frame.icon:SetTexture(nil)
    frame.icon:Hide()
  end
  local title, text = frame.title, frame.text
  title:ClearAllPoints()
  text:ClearAllPoints()
  local width = WIDTH - left - PADDING
  title:SetWidth(width)
  text:SetWidth(width)
  title:SetText(
    (not isSecret(record.title) and type(record.title) == "number") and tostring(record.title)
      or record.title
  )
  if type(record.text) ~= "nil" then
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -PADDING)
    text:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", left, PADDING)
    text:SetText(
      (not isSecret(record.text) and type(record.text) == "number") and tostring(record.text)
        or record.text
    )
  else
    title:SetPoint("LEFT", frame, "LEFT", left, 0)
    text:SetText(nil)
  end
end

-- Stack ----------------------------------------------------------------------

---Place every shown toast: the first at the anchor, each next one a step
---further in the stack's direction.
local function restack()
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" then
    return
  end
  local step = (HEIGHT + GAP) * DIRECTIONS[anchor.direction]
  for index = 1, #visible do
    local frame = visible[index].frame
    frame:ClearAllPoints()
    frame:SetPoint(anchor.point, uiParent, anchor.point, anchor.x, anchor.y + step * (index - 1))
  end
end

---Put `record` on screen in a frame from the pool.
---@param record table
local function present(record)
  -- `maxVisible` never exceeds the pool's creation cap and every frame comes
  -- back to the pool, so a frame is always free here.
  local frame = pool():Acquire()
  record.frame = frame
  record.elapsed = 0
  frames[frame] = record
  visible[#visible + 1] = record
  draw(record)
  frame:SetAlpha(1)
  frame:SetScript("OnUpdate", scripts.OnUpdate)
  frame:Show()
  restack()
end

---Fill the free places on screen from the queue.
local function advance()
  while #visible < rawget(sharedLimits, "maxVisible") and #queue > 0 do
    present(tableRemove(queue, 1))
  end
end

---End a shown or waiting toast and give its frame back.
---@param record table
local function finish(record)
  if record.ended then
    return
  end
  record.ended = true
  if record.key and byKey[record.key] == record then
    byKey[record.key] = nil
  end
  local frame = record.frame
  if frame then
    for index = 1, #visible do
      if visible[index] == record then
        tableRemove(visible, index)
        break
      end
    end
    frames[frame] = nil
    record.frame = false
    pool():Release(frame)
    restack()
    advance()
  else
    for index = 1, #queue do
      if queue[index] == record then
        tableRemove(queue, index)
        break
      end
    end
  end
end

---Whether the cursor is over `frame`; a secret or missing answer is no.
---@param frame table
---@return boolean
local function cursorOver(frame)
  if type(frame.IsMouseOver) ~= "function" then
    return false
  end
  local over = frame:IsMouseOver()
  return not isSecret(over) and over == true
end

---Every frame of a shown toast: count its time unless the cursor holds it,
---fade it at the end, and end it.
---@param frame table
---@param elapsed number
function dispatch.tick(frame, elapsed)
  local record = frames[frame]
  if record == nil then
    return
  end
  if cursorOver(frame) then
    frame:SetAlpha(1)
    return
  end
  if not isSecret(elapsed) and type(elapsed) == "number" then
    record.elapsed = record.elapsed + elapsed
  end
  local left = record.duration - record.elapsed
  if left <= 0 then
    finish(record)
  elseif left < FADE_SECONDS then
    frame:SetAlpha(left / FADE_SECONDS)
  end
end

---A click on a toast: its handler, protected, then the toast ends.
---@param frame table
function dispatch.click(frame)
  local record = frames[frame]
  if record == nil then
    return
  end
  local onClick, data = record.onClick, record.data
  finish(record)
  if onClick then
    local ok, failure = pcall(onClick, data)
    if not ok then
      reportError(failure)
    end
  end
end

-- Toast methods --------------------------------------------------------------

---End the toast now: `true`, or `false` when it already ended.
---@param self ToastKit.Toast
---@return boolean
local function toastDismiss(self)
  local record = requireRecord(self, "ToastKit.Toast:Dismiss", 3)
  if record.ended then
    return false
  end
  finish(record)
  return true
end

---Whether the toast is on screen.
---@param self ToastKit.Toast
---@return boolean
local function toastIsShown(self)
  local record = requireRecord(self, "ToastKit.Toast:IsShown", 3)
  return not record.ended and record.frame ~= false
end

---Whether the toast waits for a place on screen.
---@param self ToastKit.Toast
---@return boolean
local function toastIsQueued(self)
  local record = requireRecord(self, "ToastKit.Toast:IsQueued", 3)
  return not record.ended and record.frame == false
end

-- Package public API ---------------------------------------------------------

---Show a toast, or queue it when the screen holds `maxVisible`. A toast shown
---or waiting under `options.key` is updated and starts again instead.
---@param self ToastKit
---@param options ToastKit.ShowOptions
---@return ToastKit.Toast
local function packageShow(self, options)
  validateFacade(self, "ToastKit:Show", 3)
  local fields = readShowOptions(options, 3)
  if type(readGlobal("CreateFrame")) ~= "function" or type(readGlobal("UIParent")) ~= "table" then
    error(
      "ToastKit:Show needs the client's CreateFrame and UIParent, which this host does not have",
      2
    )
  end
  local existing = fields.key and byKey[fields.key]
  if existing then
    -- Field by field: a field left out of the new options clears the old one.
    existing.title, existing.text, existing.icon = fields.title, fields.text, fields.icon
    existing.duration, existing.onClick, existing.data =
      fields.duration, fields.onClick, fields.data
    if existing.frame then
      existing.elapsed = 0
      existing.frame:SetAlpha(1)
      draw(existing)
    end
    return existing.handle
  end
  local maxQueued = rawget(sharedLimits, "maxQueued")
  local full = #visible >= rawget(sharedLimits, "maxVisible")
  if full and maxQueued ~= UNBOUNDED and #queue >= maxQueued then
    error(
      "ToastKit:Show holds at most "
        .. maxQueued
        .. " waiting toasts; raise maxQueued with ToastKit:SetLimits",
      2
    )
  end
  local record = fields
  record.schema = RECORD_SCHEMA
  record.frame = false
  record.elapsed = 0
  record.ended = false
  local handle = setmetatable({ _record = record }, TOAST_METATABLE)
  record.handle = handle
  if record.key then
    byKey[record.key] = record
  end
  if full then
    queue[#queue + 1] = record
  else
    present(record)
  end
  return handle
end

---End every toast, the waiting ones first. Returns how many ended.
---@param self ToastKit
---@return integer
local function packageDismissAll(self)
  validateFacade(self, "ToastKit:DismissAll", 3)
  local count = #queue + #visible
  while #queue > 0 do
    finish(queue[#queue])
  end
  while #visible > 0 do
    finish(visible[#visible])
  end
  return count
end

---Move the stack: its first toast at `point` of `UIParent` offset by `x`,
---`y`, the next ones growing `"DOWN"` (the default) or `"UP"`.
---@param self ToastKit
---@param point string
---@param x number
---@param y number
---@param direction ("UP"|"DOWN")?
local function packageSetAnchor(self, point, x, y, direction)
  local label = "ToastKit:SetAnchor"
  validateFacade(self, label, 3)
  if isSecret(point) or not POINTS[point] then
    error(label .. ' point must be an anchor point such as "TOP" or "BOTTOMRIGHT"', 2)
  end
  for _, pair in ipairs({ { x, "x" }, { y, "y" } }) do
    local value = pair[1]
    if
      isSecret(value)
      or type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
    then
      error(label .. " " .. pair[2] .. " must be a finite number", 2)
    end
  end
  if type(direction) ~= "nil" and (isSecret(direction) or not DIRECTIONS[direction]) then
    error(label .. ' direction must be "UP", "DOWN" or nil', 2)
  end
  anchor.point, anchor.x, anchor.y, anchor.direction = point, x, y, direction or "DOWN"
  restack()
end

---Change any subset of the shared limits. Every value is checked before any
---changes. Raising `maxVisible` shows waiting toasts at once.
---@param self ToastKit
---@param limits ToastKit.Limits
local function packageSetLimits(self, limits)
  local label = "ToastKit:SetLimits"
  validateFacade(self, label, 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error(label .. " limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or (key ~= "maxVisible" and key ~= "maxQueued") then
      error(label .. " limits holds an unknown field; it accepts maxVisible and maxQueued", 2)
    end
    if isSecret(value) then
      error(label .. " limits." .. key .. " must not be a secret value", 2)
    end
    if key == "maxVisible" then
      if not isPositiveInteger(value) or value > VISIBLE_CEILING then
        error(label .. " limits.maxVisible must be an integer from 1 to " .. VISIBLE_CEILING, 2)
      end
    elseif value ~= UNBOUNDED and not isPositiveInteger(value) then
      error(label .. " limits.maxQueued must be a positive integer or ToastKit.UNBOUNDED", 2)
    end
  end
  for _, name in ipairs({ "maxVisible", "maxQueued" }) do
    if type(limits[name]) ~= "nil" then
      rawset(sharedLimits, name, limits[name])
    end
  end
  if type(readGlobal("CreateFrame")) == "function" and type(readGlobal("UIParent")) == "table" then
    advance()
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self ToastKit
---@return ToastKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "ToastKit:GetLimits", 3)
  return {
    maxVisible = rawget(sharedLimits, "maxVisible"),
    maxQueued = rawget(sharedLimits, "maxQueued"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(ToastPrototype, "Dismiss", toastDismiss)
rawset(ToastPrototype, "IsShown", toastIsShown)
rawset(ToastPrototype, "IsQueued", toastIsQueued)

rawset(ToastKit, "API", API_GENERATION)
rawset(ToastKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(ToastKit, "MAX_VISIBLE", MAX_VISIBLE)
rawset(ToastKit, "VISIBLE_CEILING", VISIBLE_CEILING)
rawset(ToastKit, "MAX_QUEUED", MAX_QUEUED)
rawset(ToastKit, "UNBOUNDED", UNBOUNDED)
rawset(ToastKit, "Show", packageShow)
rawset(ToastKit, "DismissAll", packageDismissAll)
rawset(ToastKit, "SetAnchor", packageSetAnchor)
rawset(ToastKit, "SetLimits", packageSetLimits)
rawset(ToastKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(ToastKit) or not validateCurrentState(ToastKit) then
  error("MoltenCodes ToastKit package state is corrupted or incomplete", 2)
end
for index = 1, #TOAST_METHODS do
  if type(rawget(ToastPrototype, TOAST_METHODS[index])) ~= "function" then
    error("MoltenCodes ToastKit package state is corrupted or incomplete", 2)
  end
end

return ToastKit
