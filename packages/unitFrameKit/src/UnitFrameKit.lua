-- MoltenCodes UnitFrameKit
--
-- The unit frame shown on screen for a unit token: what LibGetFrame-1.0 gives
-- WeakAuras to anchor an aura or a glow to a party or raid member's frame.
--
-- A scan walks the client's frames with `EnumerateFrames`, a slice per client
-- frame, and keeps every visible `Button` whose `unit` attribute is set, under
-- its name or, for an unnamed frame, its parent's name and its parent key
-- (`PartyFrame.MemberFrame1`). Frames are never deleted and `EnumerateFrames`
-- walks them in creation order, so a scan keeps its place in the walk between
-- slices and sees the frames made while it runs. A query reads each kept
-- frame's `unit` attribute again, compares it with `UnitIsUnit`, drops hidden
-- frames and ranks what is left: the caller's patterns, then frames of other
-- addons, then Blizzard's frames. The design is the package's record in
-- `docs/ROADMAP.md` (package unitFrameKit); `docs/API.md` cites where every
-- frame name in the pattern table comes from.
--
-- Scans and queries only read frames, which the client allows in combat, so
-- both run in combat.
--
-- UnitFrameKit requires Registry API 2. It reads at call time `CreateFrame`,
-- `EnumerateFrames`, `UnitIsUnit`, `UnitExists`, `C_NamePlate`,
-- `issecretvalue` and `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, timings, events, kinds
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler
--   Argument checks ....... receivers, units, options, limits
--   Frame reading ......... unit, visibility, name and kind of one frame
--   Listeners ............. connections and change notifications
--   Scanning .............. requests, slices, the end of a scan, events
--   Queries ............... matching and ranking kept frames
--   Connection methods .... Disconnect, IsConnected
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "unitFrameKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- `maxFrames`: frames kept by a scan. Each holds a name string, so the limit
-- has a ceiling and no unbounded setting.
local MAX_FRAMES, FRAMES_CEILING = 512, 4096
-- `scanFramesPerStep`: frames a scan visits per client frame.
local SCAN_FRAMES_PER_STEP, SCAN_STEP_CEILING = 400, 4000
-- `maxListeners`: `OnChange` connections at once.
local MAX_LISTENERS, LISTENERS_CEILING = 64, 512

-- The longest pattern list an option accepts.
local MAX_PATTERNS = 64

-- Seconds between an event and the scan it asks for; events inside that time
-- share one scan.
local COALESCE_SECONDS = 1

-- The events that change which frame shows which unit.
local SCAN_EVENTS = {
  "PLAYER_ENTERING_WORLD",
  "GROUP_ROSTER_UPDATE",
  "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED",
  "INSTANCE_ENCOUNTER_ENGAGE_UNIT",
  "UNIT_PET",
}
local UNIT_PET = "UNIT_PET"

-- Secure aura buttons carry a `unit` attribute too; their `type` names them.
local NOT_A_UNIT_FRAME_TYPE = "cancelaura"

-- Every kind, and the rank of each kind a query answers without `kinds`.
local KINDS = { "raid", "party", "boss", "player", "target", "targettarget", "focus" }
local KNOWN_KINDS = {}
for index = 1, #KINDS do
  KNOWN_KINDS[KINDS[index]] = true
end
local DEFAULT_KIND_RANKS = { raid = 1, party = 2, boss = 3 }
-- The solo kinds, each answering for its own token, ranked after the defaults.
local SOLO_TOKEN_KINDS =
  { player = "player", target = "target", targettarget = "targettarget", focus = "focus" }
local SOLO_KIND_RANK = 4

-- Rank bands: a caller's pattern ranks by its position (1 to MAX_PATTERNS);
-- the bands below are above any position.
local KNOWN_ADDON_BAND, UNKNOWN_ADDON_RANK, BLIZZARD_BAND = 100, 200, 300

-- The frames the Kit can name a kind for: `{ pattern, kind, blizzard }`.
-- Blizzard's names come from wow-ui-source (`live`, `classic`, `classic_era`);
-- every other entry was checked in that addon's own source. `docs/API.md`
-- cites each one. A frame no entry matches is still found, without a kind.
local KIND_PATTERNS = {
  { "^CompactRaidFrame%d+$", "raid", true },
  { "^CompactRaidGroup%dMember%d$", "raid", true },
  { "^CompactPartyFrameMember%d$", "party", true },
  { "^PartyFrame%.MemberFrame%d$", "party", true },
  { "^Boss%dTargetFrame$", "boss", true },
  { "^PlayerFrame$", "player", true },
  { "^TargetFrame$", "target", true },
  { "^TargetFrameToT$", "targettarget", true },
  { "^FocusFrame$", "focus", true },
  -- ElvUI
  { "^ElvUF_Raid%dGroup%dUnitButton%d+$", "raid", false },
  { "^ElvUF_PartyGroup1UnitButton%d$", "party", false },
  { "^ElvUF_Boss%d$", "boss", false },
  { "^ElvUF_Player$", "player", false },
  { "^ElvUF_Target$", "target", false },
  { "^ElvUF_TargetTarget$", "targettarget", false },
  { "^ElvUF_Focus$", "focus", false },
  -- Cell
  { "^CellRaidFrameHeader%dUnitButton%d+$", "raid", false },
  { "^CellPartyFrameHeaderUnitButton%d$", "party", false },
  -- Grid2
  { "^Grid2LayoutHeader%d+UnitButton%d+$", "raid", false },
  -- Shadowed Unit Frames
  { "^SUFHeaderraid%d*UnitButton%d+$", "raid", false },
  { "^SUFHeaderpartyUnitButton%d$", "party", false },
  { "^SUFHeaderbossUnitButton%d$", "boss", false },
  { "^SUFUnitplayer$", "player", false },
  { "^SUFUnittarget$", "target", false },
  { "^SUFUnittargettarget$", "targettarget", false },
  { "^SUFUnitfocus$", "focus", false },
}

-- The options `GetUnitFrame` and `GetUnitFrames` accept.
local QUERY_OPTIONS = { kinds = true, priorities = true, ignore = true }

-- The limits `SetLimits` accepts, with their ceilings.
local LIMIT_CEILINGS = {
  maxFrames = FRAMES_CEILING,
  scanFramesPerStep = SCAN_STEP_CEILING,
  maxListeners = LISTENERS_CEILING,
}

-- The `__metatable` of every connection handle. It hides the handle's metatable.
local CONNECTION_METATABLE_TAG = "UnitFrameKit.Connection"

local FACADE_METHODS = {
  "GetUnitFrame",
  "GetUnitFrames",
  "GetNamePlate",
  "Rescan",
  "IsScanning",
  "OnChange",
  "GetKindPatterns",
  "SetLimits",
  "GetLimits",
}
local CONNECTION_METHODS = { "Disconnect", "IsConnected" }

-- Public types ---------------------------------------------------------------

---What a query accepts.
---@class UnitFrameKit.QueryOptions
---@field kinds string[]? Kinds that answer, in rank order; default `{ "raid", "party", "boss" }` plus the asked token's own solo kind.
---@field priorities string[]? Name patterns ranked before everything else, in order; a frame matching one answers whatever its kind.
---@field ignore string[]? Name patterns never answered.

---A listener's connection.
---@class UnitFrameKit.Connection
---@field Disconnect fun(self: UnitFrameKit.Connection): boolean
---@field IsConnected fun(self: UnitFrameKit.Connection): boolean

---The shared limits.
---@class UnitFrameKit.Limits
---@field maxFrames integer Frames a scan keeps: 1 to 4096; default `512`.
---@field scanFramesPerStep integer Frames a scan visits per client frame: 1 to 4000; default `400`.
---@field maxListeners integer `OnChange` connections at once: 1 to 512; default `64`.

---The UnitFrameKit package facade published through Registry.
---@class UnitFrameKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_FRAMES integer Default of `maxFrames` (`512`).
---@field FRAMES_CEILING integer The highest `maxFrames` accepts (`4096`).
---@field SCAN_FRAMES_PER_STEP integer Default of `scanFramesPerStep` (`400`).
---@field SCAN_STEP_CEILING integer The highest `scanFramesPerStep` accepts (`4000`).
---@field MAX_LISTENERS integer Default of `maxListeners` (`64`).
---@field LISTENERS_CEILING integer The highest `maxListeners` accepts (`512`).
---@field MAX_PATTERNS integer The longest pattern list an option accepts (`64`).
---@field GetUnitFrame fun(self: UnitFrameKit, unit: string, options: UnitFrameKit.QueryOptions?): table?
---@field GetUnitFrames fun(self: UnitFrameKit, unit: string, options: UnitFrameKit.QueryOptions?): table[]
---@field GetNamePlate fun(self: UnitFrameKit, unit: string): table?
---@field Rescan fun(self: UnitFrameKit)
---@field IsScanning fun(self: UnitFrameKit): boolean
---@field OnChange fun(self: UnitFrameKit, callback: fun(frame: table, unit: string?, previousUnit: string?)): UnitFrameKit.Connection
---@field GetKindPatterns fun(self: UnitFrameKit, kind: string): string[]
---@field SetLimits fun(self: UnitFrameKit, limits: table)
---@field GetLimits fun(self: UnitFrameKit): UnitFrameKit.Limits

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
  error("MoltenCodes UnitFrameKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes UnitFrameKit requires a valid Registry API 2 facade", 2)
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

---Whether `implementation` exposes the complete UnitFrameKit API 1 surface.
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

---Whether `value` is an exact integer from 1 to `ceiling`.
---@param value any
---@param ceiling integer
---@return boolean
local function isLimit(value, ceiling)
  return type(value) == "number" and value >= 1 and value <= ceiling and value % 1 == 0
end

---Whether `cache` has the layout of a scan's frame table.
---@param cache any
---@return boolean
local function isCache(cache)
  return type(cache) == "table"
    and type(rawget(cache, "count")) == "number"
    and type(rawget(cache, "frames")) == "table"
    and type(rawget(cache, "names")) == "table"
    and type(rawget(cache, "kinds")) == "table"
    and type(rawget(cache, "blizzard")) == "table"
    and type(rawget(cache, "units")) == "table"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  if type(currentState) ~= "table" or rawget(currentState, "schema") ~= STATE_SCHEMA then
    return false
  end
  local limits = rawget(currentState, "limits")
  if type(limits) ~= "table" then
    return false
  end
  for name, ceiling in pairs(LIMIT_CEILINGS) do
    if not isLimit(rawget(limits, name), ceiling) then
      return false
    end
  end
  return type(rawget(currentState, "runtimeRevision")) == "number"
    and type(rawget(currentState, "phase")) == "string"
    and isCache(rawget(currentState, "cache"))
    and isCache(rawget(currentState, "working"))
    and type(rawget(currentState, "listeners")) == "table"
    and type(rawget(currentState, "rankScratch")) == "table"
    and type(rawget(currentState, "connectionPrototype")) == "table"
    and type(rawget(currentState, "connectionMetatable")) == "table"
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
-- and register this one. What stays here is what only UnitFrameKit can answer.
local UnitFrameKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes UnitFrameKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if UnitFrameKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(UnitFrameKit, "_state")

---An empty frame table of a scan: parallel arrays by scan order, and the
---unit each frame showed by frame.
---@return table
local function newCache()
  return { count = 0, frames = {}, names = {}, kinds = {}, blizzard = {}, units = {} }
end

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes UnitFrameKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The event frame holds the
  -- closures below for the session, so they look their behaviour up here.
  local dispatch = {}
  local connectionPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = {
      maxFrames = MAX_FRAMES,
      scanFramesPerStep = SCAN_FRAMES_PER_STEP,
      maxListeners = MAX_LISTENERS,
    },
    -- `"idle"`, `"waiting"` (a scan is due when `waitRemaining` runs out) or
    -- `"scanning"`; `queued` asks for one more scan after the running one.
    phase = "idle",
    waitRemaining = 0,
    queued = false,
    -- The last frame the running scan visited, or `false` before the first.
    cursor = false,
    -- What the last scan kept, and the table the running scan fills; they
    -- swap when a scan ends.
    cache = newCache(),
    working = newCache(),
    -- Whether `maxFrames` has been reported since it last changed.
    overflowReported = false,
    -- The session's event frame, made at first use.
    eventFrame = false,
    -- Connection records in connection order, the number still connected,
    -- how deep notifications run, and whether records wait to be removed.
    listeners = {},
    listenerCount = 0,
    firing = 0,
    compactPending = false,
    -- Ranks of `GetUnitFrames` matches, reused by every call.
    rankScratch = {},
    connectionPrototype = connectionPrototype,
    connectionMetatable = {
      __index = connectionPrototype,
      __metatable = CONNECTION_METATABLE_TAG,
    },
    dispatch = dispatch,
    scripts = {
      OnEvent = function(_, event, unit)
        dispatch.event(event, unit)
      end,
      OnUpdate = function(_, elapsed)
        dispatch.update(elapsed)
      end,
    },
  }
  rawset(UnitFrameKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes UnitFrameKit package state is corrupted or incomplete", 2)
end

local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local listeners = rawget(state, "listeners")
local rankScratch = rawget(state, "rankScratch")
local ConnectionPrototype = rawget(state, "connectionPrototype")
local CONNECTION_METATABLE = rawget(state, "connectionMetatable")
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

---A non-empty string the client answered, or `nil` for a secret or anything else.
---@param value any
---@return string?
local function plainString(value)
  if isSecret(value) or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

---Whether the client answered exactly `true`; a secret answer is not.
---@param value any
---@return boolean
local function isTrue(value)
  return not isSecret(value) and value == true
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- UnitFrameKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= UnitFrameKit then
    error(label .. " must be called on the UnitFrameKit facade; use " .. label .. "(...)", level)
  end
end

---@param unit any
---@param label string
---@param level integer stack level the failure is reported at
local function validateUnit(unit, label, level)
  if isSecret(unit) or type(unit) ~= "string" or unit == "" then
    error(label .. " unit must be a non-empty unit token", level)
  end
end

---Check one option's list: an array of at most `MAX_PATTERNS` non-empty
---strings, each a valid Lua pattern (a kind name is one too).
---@param list any
---@param field string the option's name
---@param noun string what the entries are, for the message
---@param label string
---@param level integer stack level the failure is reported at
local function validatePatterns(list, field, noun, label, level)
  local prefix = label .. " options." .. field
  if isSecret(list) or type(list) ~= "table" then
    error(prefix .. " must be an array of " .. noun, level)
  end
  local count = #list
  if count > MAX_PATTERNS then
    error(prefix .. " holds at most " .. MAX_PATTERNS .. " " .. noun, level)
  end
  for key in pairs(list) do
    if isSecret(key) or type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
      error(prefix .. " must be an array of " .. noun, level)
    end
  end
  for index = 1, count do
    local pattern = list[index]
    if isSecret(pattern) or type(pattern) ~= "string" or pattern == "" then
      error(prefix .. "[" .. index .. "] must be a non-empty string", level)
    end
    if not pcall(string.find, "", pattern) then
      error(prefix .. "[" .. index .. "] is not a valid pattern", level)
    end
  end
end

---Check a query's options. Reads them without copying, so a query allocates nothing.
---@param options any
---@param label string
---@param level integer stack level the failure is reported at
local function validateQueryOptions(options, label, level)
  if type(options) == "nil" then
    return
  end
  if isSecret(options) or type(options) ~= "table" then
    error(label .. " options must be a table or nil", level)
  end
  for key in pairs(options) do
    if isSecret(key) or type(key) ~= "string" or not QUERY_OPTIONS[key] then
      error(label .. " options holds an unknown field; it accepts kinds, priorities, ignore", level)
    end
  end
  local kinds = options.kinds
  if type(kinds) ~= "nil" then
    validatePatterns(kinds, "kinds", "kinds", label, level + 1)
    for index = 1, #kinds do
      if not KNOWN_KINDS[kinds[index]] then
        error(
          label
            .. " options.kinds["
            .. index
            .. "] is not a kind; kinds are "
            .. table.concat(KINDS, ", "),
          level
        )
      end
    end
  end
  if type(options.priorities) ~= "nil" then
    validatePatterns(options.priorities, "priorities", "patterns", label, level + 1)
  end
  if type(options.ignore) ~= "nil" then
    validatePatterns(options.ignore, "ignore", "patterns", label, level + 1)
  end
end

---The record of a connection handle (connected or not), or raise.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireConnection(receiver, label, level)
  local record = nil
  if
    not isSecret(receiver)
    and type(receiver) == "table"
    and getmetatable(receiver) == CONNECTION_METATABLE_TAG
  then
    record = rawget(receiver, "_record")
  end
  if type(record) ~= "table" then
    error(
      label
        .. " must be called on a UnitFrameKit connection; use connection:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

-- Frame reading --------------------------------------------------------------

---The unit `frame` shows: its `unit` attribute with `unitsuffix` appended, as
---Blizzard's `SecureButton_GetUnit` reads it (`raid1pet` becomes `raidpet1`),
---or `nil`. A secret attribute is no unit.
---@param frame table
---@return string?
local function unitOf(frame)
  if type(frame.GetAttribute) ~= "function" then
    return nil
  end
  local unit = plainString(frame:GetAttribute("unit"))
  if unit == nil then
    return nil
  end
  local suffix = plainString(frame:GetAttribute("unitsuffix"))
  if suffix == nil then
    return unit
  end
  return (string.gsub(unit .. suffix, "^([^%d]+)([%d]+)[pP][eE][tT]", "%1pet%2"))
end

---Whether `frame` is shown on screen; a secret answer is not.
---@param frame table
---@return boolean
local function isVisible(frame)
  return type(frame.IsVisible) == "function" and isTrue(frame:IsVisible())
end

---The name patterns see for `frame`: its name, or its parent's name and its
---parent key (`PartyFrame.MemberFrame1`), or `nil`.
---@param frame table
---@return string?
local function nameOf(frame)
  if type(frame.GetName) == "function" then
    local name = plainString(frame:GetName())
    if name then
      return name
    end
  end
  if type(frame.GetParent) ~= "function" or type(frame.GetParentKey) ~= "function" then
    return nil
  end
  local key = plainString(frame:GetParentKey())
  local parent = frame:GetParent()
  if key == nil or isSecret(parent) or type(parent) ~= "table" then
    return nil
  end
  local parentName = type(parent.GetName) == "function" and plainString(parent:GetName()) or nil
  if parentName == nil then
    return nil
  end
  return parentName .. "." .. key
end

---The kind and source the pattern table gives `name`: a kind or `false`, and
---whether the frame is Blizzard's.
---@param name string
---@return string|false kind
---@return boolean blizzard
local function classify(name)
  for index = 1, #KIND_PATTERNS do
    local entry = KIND_PATTERNS[index]
    if string.find(name, entry[1]) then
      return entry[2], entry[3]
    end
  end
  return false, false
end

---The unit `frame` shows when the scan keeps it, or `nil`: a visible,
---non-forbidden `Button` with a unit, which is no aura button.
---@param frame any
---@return string?
local function keptUnit(frame)
  if isSecret(frame) or type(frame) ~= "table" then
    return nil
  end
  if type(frame.IsForbidden) == "function" then
    local forbidden = frame:IsForbidden()
    if isSecret(forbidden) or forbidden == true then
      return nil
    end
  end
  if type(frame.GetObjectType) ~= "function" then
    return nil
  end
  local objectType = frame:GetObjectType()
  if isSecret(objectType) or objectType ~= "Button" then
    return nil
  end
  local unit = unitOf(frame)
  if unit == nil then
    return nil
  end
  local frameType = frame:GetAttribute("type")
  if not isSecret(frameType) and frameType == NOT_A_UNIT_FRAME_TYPE then
    return nil
  end
  if not isVisible(frame) then
    return nil
  end
  return unit
end

-- Listeners ------------------------------------------------------------------

---Drop disconnected records from the listener list, keeping order.
local function compactListeners()
  local kept = 0
  local total = #listeners
  for index = 1, total do
    local record = listeners[index]
    if record.connected then
      kept = kept + 1
      listeners[kept] = record
    end
  end
  for index = kept + 1, total do
    listeners[index] = nil
  end
  rawset(state, "compactPending", false)
end

---Tell every connected listener that `frame` shows `unit` now instead of
---`previousUnit`. A listener that raises is reported; the others still run.
---@param frame table
---@param unit string?
---@param previousUnit string?
local function notify(frame, unit, previousUnit)
  rawset(state, "firing", rawget(state, "firing") + 1)
  local total = #listeners
  for index = 1, total do
    local record = listeners[index]
    if record.connected then
      local ok, failure = pcall(record.callback, frame, unit, previousUnit)
      if not ok then
        reportError(failure)
      end
    end
  end
  rawset(state, "firing", rawget(state, "firing") - 1)
  if rawget(state, "firing") == 0 and rawget(state, "compactPending") then
    compactListeners()
  end
end

-- Scanning -------------------------------------------------------------------

---Run the event frame's `OnUpdate` while a scan waits or runs, and only then.
---@param running boolean
local function setUpdating(running)
  local eventFrame = rawget(state, "eventFrame")
  if eventFrame then
    eventFrame:SetScript("OnUpdate", running and scripts.OnUpdate or nil)
  end
end

---Ask for a scan in `delay` seconds. Requests while one waits share it (the
---sooner wins); a request while one runs queues exactly one more.
---@param delay number
local function requestScan(delay)
  if not rawget(state, "eventFrame") then
    return
  end
  local phase = rawget(state, "phase")
  if phase == "scanning" then
    rawset(state, "queued", true)
  elseif phase == "waiting" then
    if delay < rawget(state, "waitRemaining") then
      rawset(state, "waitRemaining", delay)
    end
  else
    rawset(state, "phase", "waiting")
    rawset(state, "waitRemaining", delay)
    setUpdating(true)
  end
end

---Make the session's event frame and ask for the first scan, once. Without
---`CreateFrame` nothing is ever scanned.
local function ensureListening()
  if rawget(state, "eventFrame") then
    return
  end
  local createFrame = readGlobal("CreateFrame")
  if type(createFrame) ~= "function" then
    return
  end
  local eventFrame = createFrame("Frame")
  eventFrame:SetScript("OnEvent", scripts.OnEvent)
  for index = 1, #SCAN_EVENTS do
    eventFrame:RegisterEvent(SCAN_EVENTS[index])
  end
  rawset(state, "eventFrame", eventFrame)
  requestScan(0)
end

---Keep `frame`, showing `unit`, in the running scan's table, unless the
---table is full; the first overflow since `maxFrames` changed is reported.
---@param frame table
---@param unit string
local function keep(frame, unit)
  local name = nameOf(frame)
  if name == nil then
    return
  end
  local working = rawget(state, "working")
  local maxFrames = rawget(sharedLimits, "maxFrames")
  if working.count >= maxFrames then
    if not rawget(state, "overflowReported") then
      rawset(state, "overflowReported", true)
      reportError(
        "UnitFrameKit keeps at most "
          .. maxFrames
          .. " frames; raise maxFrames with UnitFrameKit:SetLimits"
      )
    end
    return
  end
  local index = working.count + 1
  working.count = index
  working.frames[index] = frame
  working.names[index] = name
  local kind, blizzard = classify(name)
  working.kinds[index] = kind
  working.blizzard[index] = blizzard
  working.units[frame] = unit
end

---Empty a frame table, keeping its tables.
---@param cache table
local function wipeCache(cache)
  for index = 1, cache.count do
    cache.frames[index] = nil
    cache.names[index] = nil
    cache.kinds[index] = nil
    cache.blizzard[index] = nil
  end
  cache.count = 0
  local units = cache.units
  for frame in pairs(units) do
    units[frame] = nil
  end
end

---End the running scan: what it kept becomes the cache, the next scan is
---decided, and listeners hear of every frame whose unit changed.
local function finishScan()
  local fresh, previous = rawget(state, "working"), rawget(state, "cache")
  rawset(state, "cache", fresh)
  rawset(state, "working", previous)
  rawset(state, "cursor", false)
  if rawget(state, "queued") then
    rawset(state, "queued", false)
    rawset(state, "phase", "waiting")
    rawset(state, "waitRemaining", 0)
  else
    rawset(state, "phase", "idle")
    setUpdating(false)
  end
  local freshUnits, previousUnits = fresh.units, previous.units
  for index = 1, fresh.count do
    local frame = fresh.frames[index]
    local unit, previousUnit = freshUnits[frame], previousUnits[frame]
    if unit ~= previousUnit then
      notify(frame, unit, previousUnit)
    end
  end
  for frame, previousUnit in pairs(previousUnits) do
    if freshUnits[frame] == nil then
      notify(frame, nil, previousUnit)
    end
  end
  -- A listener may have started the next scan already; it fills `working`
  -- only from the next client frame on, so emptying it now is safe.
  wipeCache(previous)
end

---Visit at most `scanFramesPerStep` frames, from where the scan stopped.
local function scanStep()
  local enumerate = readGlobal("EnumerateFrames")
  if type(enumerate) ~= "function" then
    finishScan()
    return
  end
  local cursor = rawget(state, "cursor")
  for _ = 1, rawget(sharedLimits, "scanFramesPerStep") do
    local frame
    if cursor then
      frame = enumerate(cursor)
    else
      frame = enumerate()
    end
    if frame == nil then
      finishScan()
      return
    end
    local unit = keptUnit(frame)
    if unit then
      keep(frame, unit)
    end
    cursor = frame
  end
  rawset(state, "cursor", cursor)
end

---A client frame passed: count down a waiting scan, or run a slice.
---@param elapsed any seconds since the previous client frame
function dispatch.update(elapsed)
  local phase = rawget(state, "phase")
  if phase == "idle" then
    setUpdating(false)
    return
  end
  if phase == "waiting" then
    local seconds = (not isSecret(elapsed) and type(elapsed) == "number") and elapsed or 0
    local remaining = rawget(state, "waitRemaining") - seconds
    rawset(state, "waitRemaining", remaining)
    if remaining > 0 then
      return
    end
    rawset(state, "phase", "scanning")
    rawset(state, "cursor", false)
  end
  local ok, failure = pcall(scanStep)
  if not ok then
    -- The scan is dropped, not retried every frame; the next event or
    -- `Rescan` starts a fresh one.
    wipeCache(rawget(state, "working"))
    rawset(state, "cursor", false)
    rawset(state, "queued", false)
    rawset(state, "phase", "idle")
    setUpdating(false)
    reportError(failure)
  end
end

---An event that may move units between frames: ask for a coalesced scan.
---`UNIT_PET` counts only for the player and group members.
---@param event string
---@param unit any
function dispatch.event(event, unit)
  if event == UNIT_PET then
    if isSecret(unit) or type(unit) ~= "string" then
      return
    end
    if
      unit ~= "player"
      and not string.find(unit, "^party%d")
      and not string.find(unit, "^raid%d")
    then
      return
    end
  end
  requestScan(COALESCE_SECONDS)
end

-- Queries --------------------------------------------------------------------

---Whether `name` matches one of `patterns`.
---@param name string
---@param patterns string[]
---@return boolean
local function matchesAny(name, patterns)
  for index = 1, #patterns do
    if string.find(name, patterns[index]) then
      return true
    end
  end
  return false
end

---The rank of `kind` for a query of `unit`, or `nil` when it does not answer.
---@param kind string
---@param unit string
---@param kinds string[]?
---@return integer?
local function kindRank(kind, unit, kinds)
  if kinds then
    for index = 1, #kinds do
      if kinds[index] == kind then
        return index
      end
    end
    return nil
  end
  local rank = DEFAULT_KIND_RANKS[kind]
  if rank then
    return rank
  end
  if SOLO_TOKEN_KINDS[unit] == kind then
    return SOLO_KIND_RANK
  end
  return nil
end

---The rank of cache entry `index` for a query (lower ranks first), or `nil`
---when it does not answer.
---@param cache table
---@param index integer
---@param unit string
---@param options UnitFrameKit.QueryOptions?
---@return integer?
local function rankOf(cache, index, unit, options)
  local name = cache.names[index]
  local ignore = options and options.ignore
  if ignore and matchesAny(name, ignore) then
    return nil
  end
  local priorities = options and options.priorities
  if priorities then
    for position = 1, #priorities do
      if string.find(name, priorities[position]) then
        return position
      end
    end
  end
  local kind = cache.kinds[index]
  if not kind then
    return UNKNOWN_ADDON_RANK
  end
  local rank = kindRank(kind, unit, options and options.kinds)
  if rank == nil then
    return nil
  end
  return (cache.blizzard[index] and BLIZZARD_BAND or KNOWN_ADDON_BAND) + rank
end

---Whether the kept frame shows `unit` now: visible, its unit attribute read
---again and the same unit to `UnitIsUnit`. A secret answer is no match.
---@param frame table
---@param unit string
---@param unitIsUnit function
---@return boolean
local function showsUnit(frame, unit, unitIsUnit)
  if not isVisible(frame) then
    return false
  end
  local frameUnit = unitOf(frame)
  return frameUnit ~= nil and isTrue(unitIsUnit(frameUnit, unit))
end

---The client's `UnitIsUnit` when `unit` can match at all, or `nil`: without
---`UnitIsUnit`, or when `UnitExists` answers a plain `false`.
---@param unit string
---@return function?
local function matcherFor(unit)
  local unitIsUnit = readGlobal("UnitIsUnit")
  if type(unitIsUnit) ~= "function" then
    return nil
  end
  local unitExists = readGlobal("UnitExists")
  if type(unitExists) == "function" then
    local exists = unitExists(unit)
    if not isSecret(exists) and not exists then
      return nil
    end
  end
  return unitIsUnit
end

-- Connection methods ---------------------------------------------------------

---Stop the listener: `true`, or `false` when it already was.
---@param self UnitFrameKit.Connection
---@return boolean
local function connectionDisconnect(self)
  local record = requireConnection(self, "UnitFrameKit.Connection:Disconnect", 3)
  if not record.connected then
    return false
  end
  record.connected = false
  rawset(state, "listenerCount", rawget(state, "listenerCount") - 1)
  if rawget(state, "firing") > 0 then
    rawset(state, "compactPending", true)
  else
    compactListeners()
  end
  return true
end

---Whether the listener still hears changes.
---@param self UnitFrameKit.Connection
---@return boolean
local function connectionIsConnected(self)
  return requireConnection(self, "UnitFrameKit.Connection:IsConnected", 3).connected
end

-- Package public API ---------------------------------------------------------

---The best-ranked frame shown now for `unit`, or `nil`.
---@param self UnitFrameKit
---@param unit string
---@param options UnitFrameKit.QueryOptions?
---@return table?
local function packageGetUnitFrame(self, unit, options)
  local label = "UnitFrameKit:GetUnitFrame"
  validateFacade(self, label, 3)
  validateUnit(unit, label, 3)
  validateQueryOptions(options, label, 3)
  ensureListening()
  local unitIsUnit = matcherFor(unit)
  if unitIsUnit == nil then
    return nil
  end
  local cache = rawget(state, "cache")
  local bestFrame, bestRank = nil, nil
  for index = 1, cache.count do
    local rank = rankOf(cache, index, unit, options)
    if rank and (bestRank == nil or rank < bestRank) then
      local frame = cache.frames[index]
      if showsUnit(frame, unit, unitIsUnit) then
        bestFrame, bestRank = frame, rank
      end
    end
  end
  return bestFrame
end

---Every frame shown now for `unit`, best-ranked first, in a new array.
---@param self UnitFrameKit
---@param unit string
---@param options UnitFrameKit.QueryOptions?
---@return table[]
local function packageGetUnitFrames(self, unit, options)
  local label = "UnitFrameKit:GetUnitFrames"
  validateFacade(self, label, 3)
  validateUnit(unit, label, 3)
  validateQueryOptions(options, label, 3)
  ensureListening()
  local result = {}
  local unitIsUnit = matcherFor(unit)
  if unitIsUnit == nil then
    return result
  end
  local cache = rawget(state, "cache")
  local count = 0
  for index = 1, cache.count do
    local rank = rankOf(cache, index, unit, options)
    local frame = cache.frames[index]
    if rank and showsUnit(frame, unit, unitIsUnit) then
      -- Insertion keeps equal ranks in scan order.
      local position = count
      while position > 0 and rankScratch[position] > rank do
        result[position + 1] = result[position]
        rankScratch[position + 1] = rankScratch[position]
        position = position - 1
      end
      result[position + 1] = frame
      rankScratch[position + 1] = rank
      count = count + 1
    end
  end
  for index = 1, count do
    rankScratch[index] = nil
  end
  return result
end

---The nameplate's unit frame shown for `unit`, or `nil`: Blizzard's
---`UnitFrame` child of the plate, or the plate. A forbidden plate is `nil`.
---@param self UnitFrameKit
---@param unit string
---@return table?
local function packageGetNamePlate(self, unit)
  local label = "UnitFrameKit:GetNamePlate"
  validateFacade(self, label, 3)
  validateUnit(unit, label, 3)
  local namePlates = readGlobal("C_NamePlate")
  if type(namePlates) ~= "table" or type(namePlates.GetNamePlateForUnit) ~= "function" then
    return nil
  end
  local ok, plate = pcall(namePlates.GetNamePlateForUnit, unit)
  if not ok or isSecret(plate) or type(plate) ~= "table" then
    return nil
  end
  if type(plate.IsForbidden) == "function" then
    local forbidden = plate:IsForbidden()
    if isSecret(forbidden) or forbidden == true then
      return nil
    end
  end
  local unitFrame = rawget(plate, "UnitFrame")
  if not isSecret(unitFrame) and type(unitFrame) == "table" then
    return unitFrame
  end
  return plate
end

---Ask for a scan on the next client frame (after the running one, if any).
---@param self UnitFrameKit
local function packageRescan(self)
  validateFacade(self, "UnitFrameKit:Rescan", 3)
  ensureListening()
  requestScan(0)
end

---Whether a scan is due or running.
---@param self UnitFrameKit
---@return boolean
local function packageIsScanning(self)
  validateFacade(self, "UnitFrameKit:IsScanning", 3)
  return rawget(state, "phase") ~= "idle"
end

---Call `callback(frame, unit, previousUnit)` after each scan for every frame
---whose unit changed: `previousUnit` is `nil` for a frame new to the cache,
---`unit` is `nil` for one gone from it.
---@param self UnitFrameKit
---@param callback fun(frame: table, unit: string?, previousUnit: string?)
---@return UnitFrameKit.Connection
local function packageOnChange(self, callback)
  local label = "UnitFrameKit:OnChange"
  validateFacade(self, label, 3)
  if isSecret(callback) or type(callback) ~= "function" then
    error(label .. " callback must be a function", 2)
  end
  local maxListeners = rawget(sharedLimits, "maxListeners")
  if rawget(state, "listenerCount") >= maxListeners then
    error(
      label
        .. " holds at most "
        .. maxListeners
        .. " listeners; raise maxListeners with UnitFrameKit:SetLimits",
      2
    )
  end
  ensureListening()
  local handle = setmetatable({}, CONNECTION_METATABLE)
  local record = { callback = callback, connected = true }
  rawset(handle, "_record", record)
  listeners[#listeners + 1] = record
  rawset(state, "listenerCount", rawget(state, "listenerCount") + 1)
  return handle
end

---A copy of the patterns that give frames `kind`, in table order.
---@param self UnitFrameKit
---@param kind string
---@return string[]
local function packageGetKindPatterns(self, kind)
  local label = "UnitFrameKit:GetKindPatterns"
  validateFacade(self, label, 3)
  if isSecret(kind) or type(kind) ~= "string" or not KNOWN_KINDS[kind] then
    error(label .. " kind must be one of " .. table.concat(KINDS, ", "), 2)
  end
  local patterns = {}
  for index = 1, #KIND_PATTERNS do
    local entry = KIND_PATTERNS[index]
    if entry[2] == kind then
      patterns[#patterns + 1] = entry[1]
    end
  end
  return patterns
end

---Change `maxFrames`, `scanFramesPerStep` or `maxListeners`. A lower
---`maxFrames` applies from the next scan; a lower `maxListeners` keeps every
---connection and refuses the next.
---@param self UnitFrameKit
---@param limits table
local function packageSetLimits(self, limits)
  local label = "UnitFrameKit:SetLimits"
  validateFacade(self, label, 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error(label .. " limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or type(key) ~= "string" or LIMIT_CEILINGS[key] == nil then
      error(
        label
          .. " limits holds an unknown field; it accepts maxFrames, scanFramesPerStep, maxListeners",
        2
      )
    end
    if isSecret(value) then
      error(label .. " limits." .. key .. " must not be a secret value", 2)
    end
    if not isLimit(value, LIMIT_CEILINGS[key]) then
      error(
        label .. " limits." .. key .. " must be an integer from 1 to " .. LIMIT_CEILINGS[key],
        2
      )
    end
  end
  for name in pairs(LIMIT_CEILINGS) do
    if type(limits[name]) ~= "nil" then
      rawset(sharedLimits, name, limits[name])
    end
  end
  if type(limits.maxFrames) ~= "nil" then
    rawset(state, "overflowReported", false)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self UnitFrameKit
---@return UnitFrameKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "UnitFrameKit:GetLimits", 3)
  return {
    maxFrames = rawget(sharedLimits, "maxFrames"),
    scanFramesPerStep = rawget(sharedLimits, "scanFramesPerStep"),
    maxListeners = rawget(sharedLimits, "maxListeners"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(ConnectionPrototype, "Disconnect", connectionDisconnect)
rawset(ConnectionPrototype, "IsConnected", connectionIsConnected)

rawset(UnitFrameKit, "API", API_GENERATION)
rawset(UnitFrameKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(UnitFrameKit, "MAX_FRAMES", MAX_FRAMES)
rawset(UnitFrameKit, "FRAMES_CEILING", FRAMES_CEILING)
rawset(UnitFrameKit, "SCAN_FRAMES_PER_STEP", SCAN_FRAMES_PER_STEP)
rawset(UnitFrameKit, "SCAN_STEP_CEILING", SCAN_STEP_CEILING)
rawset(UnitFrameKit, "MAX_LISTENERS", MAX_LISTENERS)
rawset(UnitFrameKit, "LISTENERS_CEILING", LISTENERS_CEILING)
rawset(UnitFrameKit, "MAX_PATTERNS", MAX_PATTERNS)
rawset(UnitFrameKit, "GetUnitFrame", packageGetUnitFrame)
rawset(UnitFrameKit, "GetUnitFrames", packageGetUnitFrames)
rawset(UnitFrameKit, "GetNamePlate", packageGetNamePlate)
rawset(UnitFrameKit, "Rescan", packageRescan)
rawset(UnitFrameKit, "IsScanning", packageIsScanning)
rawset(UnitFrameKit, "OnChange", packageOnChange)
rawset(UnitFrameKit, "GetKindPatterns", packageGetKindPatterns)
rawset(UnitFrameKit, "SetLimits", packageSetLimits)
rawset(UnitFrameKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(UnitFrameKit) or not validateCurrentState(UnitFrameKit) then
  error("MoltenCodes UnitFrameKit package state is corrupted or incomplete", 2)
end
for index = 1, #CONNECTION_METHODS do
  if type(rawget(ConnectionPrototype, CONNECTION_METHODS[index])) ~= "function" then
    error("MoltenCodes UnitFrameKit package state is corrupted or incomplete", 2)
  end
end

return UnitFrameKit
