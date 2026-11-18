-- MoltenCodes GlowKit
--
-- Glows that draw the eye to a frame (an action button, an aura icon, a unit
-- frame): what LibCustomGlow-1.0 gives WeakAuras and action-bar addons. Two
-- effects, drawn with plain textures on an overlay frame of the package's own
-- laid over the target:
--
--   * `pixel`: short lines running round the frame's edge;
--   * `pulse`: a border whose opacity breathes.
--
-- Several glows can sit on one frame under different keys. Overlays come from
-- a PoolKit pool that keeps every released frame, because the client never
-- frees one; Blizzard's own spell-activation overlay is never touched. An
-- overlay is a child of its target, so it runs nothing while the target is
-- hidden and resumes when it shows.
--
-- GlowKit requires Registry API 2 and PoolKit API 1. It reads `CreateFrame`
-- and `geterrorhandler` at call time, and `issecretvalue` once at load (again
-- on each check only when the host had none at load).
--
-- Contents
-- --------
--   Constants ............. identity, limits, defaults
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, PoolKit, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values
--   Argument checks ....... receivers, frames, options, limits
--   Overlays .............. the pool, textures, drawing both effects
--   Glow methods .......... Stop, IsActive
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "glowKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local REQUIRED_POOLKIT_API = 1
local STATE_SCHEMA = 1

-- Every glow record carries the layout it was built with, so a later revision
-- that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- `maxGlows`: glows active at once. Each holds an overlay frame the session
-- keeps, so the limit has a ceiling and no unbounded setting.
local MAX_GLOWS, GLOWS_CEILING = 64, 512

-- The effects, and the defaults and ranges of their options.
local KIND_PIXEL, KIND_PULSE = "pixel", "pulse"
local KINDS = { [KIND_PIXEL] = true, [KIND_PULSE] = true }
local DEFAULT_KEY = "default"
local DEFAULT_COLOR = { 0.95, 0.95, 0.32, 1 }
local DEFAULT_LINES, MAX_LINES = 8, 32
local DEFAULT_THICKNESS, MAX_THICKNESS = 2, 10
local DEFAULT_FREQUENCY, MAX_FREQUENCY = 0.25, 10
local OVERLAY_LEVEL_OFFSET = 5

-- A pulse's opacity runs between these.
local PULSE_LOW, PULSE_HIGH = 0.3, 1

-- The options `Start` accepts.
local START_OPTIONS =
  { kind = true, key = true, color = true, lines = true, thickness = true, frequency = true }

-- The `__metatable` of every glow handle. It hides the handle's metatable.
local GLOW_METATABLE_TAG = "GlowKit.Glow"

local FACADE_METHODS = { "Start", "Stop", "StopAll", "IsGlowing", "SetLimits", "GetLimits" }
local GLOW_METHODS = { "Stop", "IsActive" }

-- Public types ---------------------------------------------------------------

---The options of `Start`.
---@class GlowKit.StartOptions
---@field kind ("pixel"|"pulse")? Default `"pixel"`.
---@field key string? The glow's name on its frame; default `"default"`.
---@field color number[]? `{ r, g, b, a? }`, each from 0 to 1; default a light yellow.
---@field lines integer? `pixel`: how many lines run round the edge, 1 to 32; default `8`.
---@field thickness number? Pixels, above 0 and at most 10; default `2`.
---@field frequency number? Rounds (or breaths) per second, above 0 and at most 10; default `0.25`.

---A glow on a frame.
---@class GlowKit.Glow
---@field Stop fun(self: GlowKit.Glow): boolean
---@field IsActive fun(self: GlowKit.Glow): boolean

---The shared limits.
---@class GlowKit.Limits
---@field maxGlows integer Glows active at once: 1 to 512; default `64`.

---The GlowKit package facade published through Registry.
---@class GlowKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_GLOWS integer Default of `maxGlows` (`64`).
---@field GLOWS_CEILING integer The highest `maxGlows` accepts (`512`).
---@field Start fun(self: GlowKit, frame: table, options: GlowKit.StartOptions?): GlowKit.Glow
---@field Stop fun(self: GlowKit, frame: table, key: string?): boolean
---@field StopAll fun(self: GlowKit, frame: table): integer
---@field IsGlowing fun(self: GlowKit, frame: table, key: string?): boolean
---@field SetLimits fun(self: GlowKit, limits: GlowKit.Limits)
---@field GetLimits fun(self: GlowKit): GlowKit.Limits

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
  error("MoltenCodes GlowKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
  error("MoltenCodes GlowKit requires a valid Registry API 2 facade", 2)
end

-- PoolKit keeps every overlay frame for reuse.
local PoolKit = getPackage(Registry, "poolKit", REQUIRED_POOLKIT_API)
if
  type(PoolKit) ~= "table"
  or rawget(PoolKit, "API") ~= REQUIRED_POOLKIT_API
  or type(rawget(PoolKit, "New")) ~= "function"
then
  error("MoltenCodes GlowKit requires PoolKit API 1 to be loaded first", 2)
end

---Read a host global without triggering a metatable, or `nil`.
---@param name string
---@return any
local function readGlobal(name)
  -- Host APIs are reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

local mathMin, mathMax, mathSin, mathPi = math.min, math.max, math.sin, math.pi

-- Validation -----------------------------------------------------------------

---Whether `implementation` exposes the complete GlowKit API 1 surface.
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
local function isGlowLimit(value)
  return type(value) == "number" and value >= 1 and value <= GLOWS_CEILING and value % 1 == 0
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
    and isGlowLimit(rawget(limits, "maxGlows"))
    and type(rawget(currentState, "byFrame")) == "table"
    and type(rawget(currentState, "overlays")) == "table"
    and type(rawget(currentState, "activeCount")) == "number"
    and type(rawget(currentState, "glowPrototype")) == "table"
    and type(rawget(currentState, "glowMetatable")) == "table"
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
-- and register this one. What stays here is what only GlowKit can answer.
local GlowKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes GlowKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if GlowKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(GlowKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes GlowKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The pool and the overlays hold
  -- the closures below for the session, so they look their behaviour up here.
  local dispatch = {}
  local glowPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxGlows = MAX_GLOWS },
    -- Target frame to { key = record }; overlay frame to record.
    byFrame = {},
    overlays = {},
    activeCount = 0,
    -- The pool, made on first use (it needs `CreateFrame`).
    pool = false,
    glowPrototype = glowPrototype,
    glowMetatable = { __index = glowPrototype, __metatable = GLOW_METATABLE_TAG },
    dispatch = dispatch,
    scripts = {
      build = function()
        return dispatch.build()
      end,
      reset = function(overlay)
        dispatch.reset(overlay)
      end,
      OnUpdate = function(overlay, elapsed)
        dispatch.tick(overlay, elapsed)
      end,
    },
  }
  rawset(GlowKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes GlowKit package state is corrupted or incomplete", 2)
end

local byFrame = rawget(state, "byFrame")
---@type table<table, table>
local overlays = rawget(state, "overlays")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local GlowPrototype = rawget(state, "glowPrototype")
local GLOW_METATABLE = rawget(state, "glowMetatable")
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

---A size or level the client answered, or 0 when it answered a secret.
---@param value any
---@return number
local function plain(value)
  if isSecret(value) or type(value) ~= "number" then
    return 0
  end
  return value
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- GlowKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

-- shared:begin validateFacade 1 __FACADE__=GlowKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the GlowKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= GlowKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the GlowKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---Raise at the caller unless `frame` is a frame.
---@param frame any
---@param label string
---@param level integer stack level the failure is reported at
local function validateFrame(frame, label, level)
  if
    isSecret(frame)
    or type(frame) ~= "table"
    or type(frame.GetWidth) ~= "function"
    or type(frame.CreateTexture) ~= "function"
  then
    error(label .. " frame must be a frame", level)
  end
end

---`key`, or the default; raise at the caller unless it is a non-empty string.
---@param key any
---@param label string the start of the message, ending where "key" follows
---@param level integer stack level the failure is reported at
---@return string
local function readKey(key, label, level)
  if type(key) == "nil" then
    return DEFAULT_KEY
  end
  if isSecret(key) or type(key) ~= "string" or key == "" then
    error(label .. "key must be a non-empty string or nil", level)
  end
  return key
end

---Raise at the caller unless `value` is `nil` or a number in `(low, high]`.
---@param value any
---@param where string
---@param high number
---@param level integer stack level the failure is reported at
local function validateRange(value, where, high, level)
  if type(value) == "nil" then
    return
  end
  if isSecret(value) or type(value) ~= "number" or not (value > 0 and value <= high) then
    error(where .. " must be a number above 0 and at most " .. high, level)
  end
end

---Check `Start`'s options and return the record's settings.
---@param options any
---@param level integer stack level the failure is reported at
---@return table settings
local function readStartOptions(options, level)
  local label = "GlowKit:Start"
  if type(options) == "nil" then
    options = {}
  elseif isSecret(options) or type(options) ~= "table" then
    error(label .. " options must be a table or nil", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not START_OPTIONS[key] then
      error(
        label
          .. " options holds an unknown field; it accepts kind, key, color, lines, thickness and frequency",
        level
      )
    end
  end
  local kind = options.kind
  if type(kind) ~= "nil" and (isSecret(kind) or not KINDS[kind]) then
    error(label .. ' options.kind must be "pixel" or "pulse"', level)
  end
  local key = readKey(options.key, label .. " options.", level + 1)
  local color = options.color
  if type(color) ~= "nil" then
    if isSecret(color) or type(color) ~= "table" then
      error(label .. " options.color must be { r, g, b, a? }", level)
    end
    for index = 1, 4 do
      local component = color[index]
      if not (index == 4 and type(component) == "nil") then
        if
          isSecret(component)
          or type(component) ~= "number"
          or not (component >= 0 and component <= 1)
        then
          error(label .. " options.color must be { r, g, b, a? }, each from 0 to 1", level)
        end
      end
    end
  end
  local lines = options.lines
  if
    type(lines) ~= "nil"
    and (
      isSecret(lines)
      or type(lines) ~= "number"
      or lines % 1 ~= 0
      or lines < 1
      or lines > MAX_LINES
    )
  then
    error(label .. " options.lines must be an integer from 1 to " .. MAX_LINES, level)
  end
  validateRange(options.thickness, label .. " options.thickness", MAX_THICKNESS, level + 1)
  validateRange(options.frequency, label .. " options.frequency", MAX_FREQUENCY, level + 1)
  color = color or DEFAULT_COLOR
  return {
    kind = kind or KIND_PIXEL,
    key = key,
    red = color[1],
    green = color[2],
    blue = color[3],
    alpha = color[4] or 1,
    lines = lines or DEFAULT_LINES,
    thickness = options.thickness or DEFAULT_THICKNESS,
    frequency = options.frequency or DEFAULT_FREQUENCY,
  }
end

-- Overlays -------------------------------------------------------------------

---An overlay frame: no textures until a glow needs them.
---@return table overlay
function dispatch.build()
  local overlay = readGlobal("CreateFrame")("Frame")
  overlay:Hide()
  overlay.lines = {}
  overlay.edges = {}
  return overlay
end

---Return an overlay to the pool with every texture hidden.
---@param overlay table
function dispatch.reset(overlay)
  overlay:Hide()
  overlay:SetScript("OnUpdate", nil)
  overlay:ClearAllPoints()
  overlay:SetParent(nil)
  for _, texture in ipairs(overlay.lines) do
    texture:Hide()
  end
  for _, texture in ipairs(overlay.edges) do
    texture:Hide()
  end
end

---The pool, made on first use.
---@return table
local function pool()
  local overlayPool = rawget(state, "pool")
  if not overlayPool then
    overlayPool = PoolKit:New({
      create = scripts.build,
      reset = scripts.reset,
      maxRetained = PoolKit.UNBOUNDED,
      maxCreated = GLOWS_CEILING,
    })
    rawset(state, "pool", overlayPool)
  end
  return overlayPool
end

---The `index`th texture of `list` on `overlay`, made on first use, coloured.
---@param overlay table
---@param list table
---@param index integer
---@param record table
---@return table texture
local function textureOf(overlay, list, index, record)
  local texture = list[index]
  if texture == nil then
    texture = overlay:CreateTexture(nil, "OVERLAY")
    list[index] = texture
  end
  texture:SetColorTexture(record.red, record.green, record.blue, record.alpha)
  texture:Show()
  return texture
end

---Draw the pixel lines at the record's phase: each line starts a fixed share
---of the way round the edge (top left to right, right side down, bottom right
---to left, left side up) and is cut where its side ends.
---@param record table
local function drawPixel(record)
  local overlay, target = record.overlay, record.frame
  local width, height = plain(target:GetWidth()), plain(target:GetHeight())
  local perimeter = 2 * (width + height)
  local lines, thickness = record.lines, record.thickness
  local list = overlay.lines
  for index = 1, lines do
    local texture = textureOf(overlay, list, index, record)
    if perimeter <= 0 then
      texture:Hide()
    else
      local start = ((record.phase + (index - 1) / lines) % 1) * perimeter
      local length = perimeter / lines / 2
      texture:ClearAllPoints()
      if start < width then
        texture:SetPoint("TOPLEFT", overlay, "TOPLEFT", start, 0)
        texture:SetSize(mathMax(1, mathMin(length, width - start)), thickness)
      elseif start < width + height then
        local offset = start - width
        texture:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, -offset)
        texture:SetSize(thickness, mathMax(1, mathMin(length, height - offset)))
      elseif start < 2 * width + height then
        local offset = start - width - height
        texture:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -offset, 0)
        texture:SetSize(mathMax(1, mathMin(length, width - offset)), thickness)
      else
        local offset = start - 2 * width - height
        texture:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 0, offset)
        texture:SetSize(thickness, mathMax(1, mathMin(length, height - offset)))
      end
    end
  end
  for index = lines + 1, #list do
    list[index]:Hide()
  end
end

---Place the pulse's four border textures once, on the overlay's edges.
---@param record table
local function placePulse(record)
  local overlay, thickness = record.overlay, record.thickness
  local edges = overlay.edges
  local placements = {
    { "TOPLEFT", "TOPRIGHT", true },
    { "BOTTOMLEFT", "BOTTOMRIGHT", true },
    { "TOPLEFT", "BOTTOMLEFT", false },
    { "TOPRIGHT", "BOTTOMRIGHT", false },
  }
  for index = 1, 4 do
    local texture = textureOf(overlay, edges, index, record)
    local first, second, horizontal =
      placements[index][1], placements[index][2], placements[index][3]
    texture:ClearAllPoints()
    texture:SetPoint(first, overlay, first, 0, 0)
    texture:SetPoint(second, overlay, second, 0, 0)
    if horizontal then
      texture:SetHeight(thickness)
    else
      texture:SetWidth(thickness)
    end
  end
end

---Every frame of a visible glow: advance its phase and draw it.
---@param overlay table
---@param elapsed number
function dispatch.tick(overlay, elapsed)
  local record = overlays[overlay]
  if record == nil then
    return
  end
  record.phase = (record.phase + plain(elapsed) * record.frequency) % 1
  if record.kind == KIND_PIXEL then
    drawPixel(record)
  else
    local breath = 0.5 + 0.5 * mathSin(record.phase * 2 * mathPi)
    overlay:SetAlpha(PULSE_LOW + (PULSE_HIGH - PULSE_LOW) * breath)
  end
end

---Take an overlay, lay it over the record's frame and start it.
---@param record table
local function attach(record)
  local overlay = pool():Acquire()
  local target = record.frame
  record.overlay = overlay
  overlays[overlay] = record
  overlay:SetParent(target)
  overlay:ClearAllPoints()
  overlay:SetAllPoints(target)
  overlay:SetFrameLevel(plain(target:GetFrameLevel()) + OVERLAY_LEVEL_OFFSET)
  overlay:SetAlpha(1)
  if record.kind == KIND_PULSE then
    placePulse(record)
  end
  dispatch.tick(overlay, 0)
  overlay:SetScript("OnUpdate", scripts.OnUpdate)
  overlay:Show()
end

---End a glow and give its overlay back.
---@param record table
local function detach(record)
  if not record.active then
    return
  end
  record.active = false
  local glows = byFrame[record.frame]
  if glows and glows[record.key] == record then
    glows[record.key] = nil
    if next(glows) == nil then
      byFrame[record.frame] = nil
    end
  end
  overlays[record.overlay] = nil
  rawset(state, "activeCount", rawget(state, "activeCount") - 1)
  pool():Release(record.overlay)
end

-- Glow methods ---------------------------------------------------------------

---Stop the glow: `true`, or `false` when it was already stopped.
---@param self GlowKit.Glow
---@return boolean
local function glowStop(self)
  local record = nil
  if not isSecret(self) and type(self) == "table" and getmetatable(self) == GLOW_METATABLE_TAG then
    record = rawget(self, "_record")
  end
  if type(record) ~= "table" then
    error("GlowKit.Glow:Stop must be called on a GlowKit glow; use glow:Stop(...)", 2)
  end
  if not record.active then
    return false
  end
  detach(record)
  return true
end

---Whether the glow is still on its frame.
---@param self GlowKit.Glow
---@return boolean
local function glowIsActive(self)
  local record = nil
  if not isSecret(self) and type(self) == "table" and getmetatable(self) == GLOW_METATABLE_TAG then
    record = rawget(self, "_record")
  end
  if type(record) ~= "table" then
    error("GlowKit.Glow:IsActive must be called on a GlowKit glow; use glow:IsActive(...)", 2)
  end
  return record.active
end

-- Package public API ---------------------------------------------------------

---Start a glow on `frame` under `options.key`, restarting one already there.
---@param self GlowKit
---@param frame table
---@param options GlowKit.StartOptions?
---@return GlowKit.Glow
local function packageStart(self, frame, options)
  local label = "GlowKit:Start"
  validateFacade(self, label, 3)
  validateFrame(frame, label, 3)
  local settings = readStartOptions(options, 3)
  if type(readGlobal("CreateFrame")) ~= "function" then
    error(label .. " needs the client's CreateFrame, which this host does not have", 2)
  end
  local glows = byFrame[frame]
  local existing = glows and glows[settings.key]
  if not existing and rawget(state, "activeCount") >= rawget(sharedLimits, "maxGlows") then
    error(
      label
        .. " holds at most "
        .. rawget(sharedLimits, "maxGlows")
        .. " glows at once; stop one, or raise maxGlows",
      2
    )
  end
  if existing then
    detach(existing)
  end
  local record = settings
  record.schema = RECORD_SCHEMA
  record.frame = frame
  record.phase = 0
  record.active = true
  local handle = setmetatable({ _record = record }, GLOW_METATABLE)
  record.handle = handle
  glows = byFrame[frame] or {}
  byFrame[frame] = glows
  glows[record.key] = record
  rawset(state, "activeCount", rawget(state, "activeCount") + 1)
  attach(record)
  return handle
end

---Stop the glow under `key` (default `"default"`) on `frame`: `true`, or
---`false` when there was none.
---@param self GlowKit
---@param frame table
---@param key string?
---@return boolean
local function packageStop(self, frame, key)
  validateFacade(self, "GlowKit:Stop", 3)
  validateFrame(frame, "GlowKit:Stop", 3)
  key = readKey(key, "GlowKit:Stop ", 3)
  local glows = byFrame[frame]
  local record = glows and glows[key]
  if not record then
    return false
  end
  detach(record)
  return true
end

---Stop every glow on `frame`; returns how many there were.
---@param self GlowKit
---@param frame table
---@return integer
local function packageStopAll(self, frame)
  validateFacade(self, "GlowKit:StopAll", 3)
  validateFrame(frame, "GlowKit:StopAll", 3)
  local glows = byFrame[frame]
  if not glows then
    return 0
  end
  local records = {}
  for _, record in pairs(glows) do
    records[#records + 1] = record
  end
  for index = 1, #records do
    detach(records[index])
  end
  return #records
end

---Whether a glow is under `key` (default: any key) on `frame`.
---@param self GlowKit
---@param frame table
---@param key string?
---@return boolean
local function packageIsGlowing(self, frame, key)
  validateFacade(self, "GlowKit:IsGlowing", 3)
  validateFrame(frame, "GlowKit:IsGlowing", 3)
  local glows = byFrame[frame]
  if type(key) == "nil" then
    return glows ~= nil
  end
  key = readKey(key, "GlowKit:IsGlowing ", 3)
  return glows ~= nil and glows[key] ~= nil
end

---Change `maxGlows`. Lowering it keeps every glow and refuses the next.
---@param self GlowKit
---@param limits GlowKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "GlowKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("GlowKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxGlows" then
      error("GlowKit:SetLimits limits holds an unknown field; it accepts maxGlows", 2)
    end
    if isSecret(value) then
      error("GlowKit:SetLimits limits.maxGlows must not be a secret value", 2)
    end
    if not isGlowLimit(value) then
      error("GlowKit:SetLimits limits.maxGlows must be an integer from 1 to " .. GLOWS_CEILING, 2)
    end
  end
  if type(limits.maxGlows) ~= "nil" then
    rawset(sharedLimits, "maxGlows", limits.maxGlows)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self GlowKit
---@return GlowKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "GlowKit:GetLimits", 3)
  return { maxGlows = rawget(sharedLimits, "maxGlows") }
end

-- Commit ---------------------------------------------------------------------

rawset(GlowPrototype, "Stop", glowStop)
rawset(GlowPrototype, "IsActive", glowIsActive)

rawset(GlowKit, "API", API_GENERATION)
rawset(GlowKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(GlowKit, "MAX_GLOWS", MAX_GLOWS)
rawset(GlowKit, "GLOWS_CEILING", GLOWS_CEILING)
rawset(GlowKit, "Start", packageStart)
rawset(GlowKit, "Stop", packageStop)
rawset(GlowKit, "StopAll", packageStopAll)
rawset(GlowKit, "IsGlowing", packageIsGlowing)
rawset(GlowKit, "SetLimits", packageSetLimits)
rawset(GlowKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(GlowKit) or not validateCurrentState(GlowKit) then
  error("MoltenCodes GlowKit package state is corrupted or incomplete", 2)
end
for index = 1, #GLOW_METHODS do
  if type(rawget(GlowPrototype, GLOW_METHODS[index])) ~= "function" then
    error("MoltenCodes GlowKit package state is corrupted or incomplete", 2)
  end
end

return GlowKit
