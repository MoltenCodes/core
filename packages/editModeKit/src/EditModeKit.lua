-- MoltenCodes EditModeKit
--
-- An addon's frames in Blizzard's Edit Mode: what LibEditMode gives addons.
-- While Edit Mode is open, each registered frame shows a labelled selection
-- overlay that drags the frame, and its position is saved per Edit Mode layout
-- and put back when the player switches layout.
--
-- Edit Mode tells the world through `EventRegistry` (`EditMode.Enter`,
-- `EditMode.Exit`) and the event `EDIT_MODE_LAYOUTS_UPDATED`; the active
-- layout's name comes from `EditModeManagerFrame:GetActiveLayoutInfo()`. All
-- of it exists on Retail, Mists of Pandaria Classic and Classic Era. A
-- position is stored as the frame's centre offset from `UIParent`'s centre, in
-- `UIParent`'s scale, so it survives a change of the frame's scale.
--
-- The client refuses to move a protected frame from addon code in combat; such
-- a move waits for `PLAYER_REGEN_ENABLED`.
--
-- EditModeKit requires Registry API 2. It reads at call time `CreateFrame`,
-- `UIParent`, `EventRegistry`, `EditModeManagerFrame`, `InCombatLockdown` and
-- `geterrorhandler`, and `issecretvalue` once at load (again on each check
-- only when the host had none at load).
--
-- Contents
-- --------
--   Constants ............. identity, limits, look, events
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, the client
--   Argument checks ....... receivers, frames, storage, limits
--   Positions ............. reading, saving and applying per layout
--   Overlays .............. the pool, Edit Mode opening and closing, drags
--   Registration methods .. Unregister, Refresh, GetFrame
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "editModeKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 3
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- Every registration record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- `maxRegistrations`: frames registered at once. Each holds an overlay frame
-- the session keeps, so the limit has a ceiling and no unbounded setting.
local MAX_REGISTRATIONS, REGISTRATIONS_CEILING = 64, 256

-- The layout name used when the client cannot name the active layout.
local DEFAULT_LAYOUT = "default"

-- The overlay's look: Edit Mode's selection blue.
local OVERLAY_COLOR = { 0.25, 0.6, 1, 0.35 }
local OVERLAY_LEVEL_OFFSET = 20

-- The events.
local EDIT_MODE_ENTER, EDIT_MODE_EXIT = "EditMode.Enter", "EditMode.Exit"
local LAYOUTS_UPDATED = "EDIT_MODE_LAYOUTS_UPDATED"
local COMBAT_ENDED = "PLAYER_REGEN_ENABLED"

-- The options `Register` accepts.
local REGISTER_OPTIONS = { label = true }

-- The `__metatable` of every registration handle. It hides the handle's metatable.
local REGISTRATION_METATABLE_TAG = "EditModeKit.Registration"

local FACADE_METHODS = { "Register", "IsEditing", "GetLayoutName", "SetLimits", "GetLimits" }
local REGISTRATION_METHODS = { "Unregister", "Refresh", "GetFrame" }

-- Public types ---------------------------------------------------------------

---A saved position: the frame's centre offset from `UIParent`'s centre.
---@class EditModeKit.Position
---@field x number
---@field y number

---A table of positions by layout name, or a function returning one.
---@alias EditModeKit.Storage table<string, EditModeKit.Position>|fun(): table<string, EditModeKit.Position>

---One registered frame.
---@class EditModeKit.Registration
---@field Unregister fun(self: EditModeKit.Registration): boolean
---@field Refresh fun(self: EditModeKit.Registration)
---@field GetFrame fun(self: EditModeKit.Registration): table

---The shared limits.
---@class EditModeKit.Limits
---@field maxRegistrations integer Frames registered at once: 1 to 256; default `64`.

---The EditModeKit package facade published through Registry.
---@class EditModeKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_REGISTRATIONS integer Default of `maxRegistrations` (`64`).
---@field REGISTRATIONS_CEILING integer The highest `maxRegistrations` accepts (`256`).
---@field Register fun(self: EditModeKit, frame: table, storage: EditModeKit.Storage, options: { label: string? }?): EditModeKit.Registration
---@field IsEditing fun(self: EditModeKit): boolean
---@field GetLayoutName fun(self: EditModeKit): string
---@field SetLimits fun(self: EditModeKit, limits: EditModeKit.Limits)
---@field GetLimits fun(self: EditModeKit): EditModeKit.Limits

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
  error("MoltenCodes EditModeKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes EditModeKit requires a valid Registry API 2 facade", 2)
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

---Whether `implementation` exposes the complete EditModeKit API 1 surface.
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
local function isRegistrationLimit(value)
  return type(value) == "number"
    and value >= 1
    and value <= REGISTRATIONS_CEILING
    and value % 1 == 0
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
    and isRegistrationLimit(rawget(limits, "maxRegistrations"))
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "byFrame")) == "table"
    and type(rawget(currentState, "overlays")) == "table"
    and type(rawget(currentState, "freeOverlays")) == "table"
    and type(rawget(currentState, "registrationCount")) == "number"
    and type(rawget(currentState, "callbackOwner")) == "table"
    and type(rawget(currentState, "registrationPrototype")) == "table"
    and type(rawget(currentState, "registrationMetatable")) == "table"
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
-- and register this one. What stays here is what only EditModeKit can answer.
local EditModeKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes EditModeKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if EditModeKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(EditModeKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes EditModeKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The overlays, the event frame
  -- and `EventRegistry` hold the closures below for the session, so they look
  -- their behaviour up here.
  local dispatch = {}
  local registrationPrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxRegistrations = MAX_REGISTRATIONS },
    -- Handle to record; frame to record; overlay to record; overlays free.
    records = {},
    byFrame = {},
    overlays = {},
    freeOverlays = {},
    registrationCount = 0,
    -- Whether Edit Mode is open, and whether the session's listeners exist.
    editing = false,
    listening = false,
    -- The owner `EventRegistry` files the callbacks under, and the frame that
    -- listens for layout changes and the end of combat.
    callbackOwner = {},
    eventFrame = false,
    registrationPrototype = registrationPrototype,
    registrationMetatable = {
      __index = registrationPrototype,
      __metatable = REGISTRATION_METATABLE_TAG,
    },
    dispatch = dispatch,
    scripts = {
      enter = function()
        dispatch.enter()
      end,
      exit = function()
        dispatch.exit()
      end,
      OnEvent = function(_, event)
        dispatch.event(event)
      end,
      OnDragStart = function(overlay)
        dispatch.dragStart(overlay)
      end,
      OnDragStop = function(overlay)
        dispatch.dragStop(overlay)
      end,
    },
  }
  rawset(EditModeKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes EditModeKit package state is corrupted or incomplete", 2)
end

---@type table<table, table>
local records = rawget(state, "records")
---@type table<table, table>
local byFrame = rawget(state, "byFrame")
---@type table<table, table>
local overlays = rawget(state, "overlays")
local freeOverlays = rawget(state, "freeOverlays")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local RegistrationPrototype = rawget(state, "registrationPrototype")
local REGISTRATION_METATABLE = rawget(state, "registrationMetatable")
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

---A number the client answered, or `nil` for a secret or anything else.
---@param value any
---@return number?
local function plain(value)
  if isSecret(value) or type(value) ~= "number" then
    return nil
  end
  return value
end

---Whether a move of `frame` must wait: it is protected and the client is in
---combat lockdown.
---@param frame table
---@return boolean
local function mustWait(frame)
  local inCombatLockdown = readGlobal("InCombatLockdown")
  if type(inCombatLockdown) ~= "function" or type(frame.IsProtected) ~= "function" then
    return false
  end
  local protected, locked = frame:IsProtected(), inCombatLockdown()
  return not isSecret(protected) and protected == true and not isSecret(locked) and locked == true
end

---The active Edit Mode layout's name, or `"default"`.
---@return string
local function layoutName()
  local manager = readGlobal("EditModeManagerFrame")
  if type(manager) ~= "table" or type(manager.GetActiveLayoutInfo) ~= "function" then
    return DEFAULT_LAYOUT
  end
  local ok, info = pcall(manager.GetActiveLayoutInfo, manager)
  local name = ok and type(info) == "table" and info.layoutName or nil
  if isSecret(name) or type(name) ~= "string" or name == "" then
    return DEFAULT_LAYOUT
  end
  return name
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- EditModeKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

-- shared:begin validateFacade 1 __FACADE__=EditModeKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the EditModeKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= EditModeKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the EditModeKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---The record of a registration handle (registered or not), or raise.
---@param receiver any
---@param label string
---@param level integer stack level the failure is reported at
---@return table record
local function requireRecord(receiver, label, level)
  local record = nil
  if
    not isSecret(receiver)
    and type(receiver) == "table"
    and getmetatable(receiver) == REGISTRATION_METATABLE_TAG
  then
    record = rawget(receiver, "_record")
  end
  if type(record) ~= "table" then
    error(
      label
        .. " must be called on an EditModeKit registration; use registration:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

-- Positions ------------------------------------------------------------------

---The record's storage table now, or `nil` (reported) when a storage
---function raises or returns no table.
---@param record table
---@return table?
local function storageOf(record)
  local storage = record.storage
  if type(storage) ~= "function" then
    return storage
  end
  local ok, result = pcall(storage)
  if not ok then
    reportError(result)
    return nil
  end
  if isSecret(result) or type(result) ~= "table" then
    reportError("EditModeKit storage for " .. record.label .. " must return a table")
    return nil
  end
  return result
end

---How many `UIParent` units one unit of `frame` is.
---@param frame table
---@return number?
local function scaleRatio(frame)
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" or type(uiParent.GetEffectiveScale) ~= "function" then
    return nil
  end
  local frameScale, parentScale =
    plain(frame:GetEffectiveScale()), plain(uiParent:GetEffectiveScale())
  if not frameScale or not parentScale or parentScale <= 0 or frameScale <= 0 then
    return nil
  end
  return frameScale / parentScale
end

---Put the record's frame where the active layout's saved position says.
---A frame without a saved position stays where it is; a protected frame in
---combat waits.
---@param record table
local function apply(record)
  if not record.registered then
    return
  end
  local storage = storageOf(record)
  local position = storage and storage[layoutName()]
  if type(position) ~= "table" then
    return
  end
  local x, y = plain(position.x), plain(position.y)
  local frame, uiParent, ratio = record.frame, readGlobal("UIParent"), scaleRatio(record.frame)
  if not x or not y or not ratio or type(uiParent) ~= "table" then
    return
  end
  if mustWait(frame) then
    record.pending = true
    local eventFrame = rawget(state, "eventFrame")
    if eventFrame then
      eventFrame:RegisterEvent(COMBAT_ENDED)
    end
    return
  end
  record.pending = false
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", uiParent, "CENTER", x / ratio, y / ratio)
end

---Save where the record's frame is now, under the active layout.
---@param record table
local function save(record)
  local uiParent = readGlobal("UIParent")
  if type(uiParent) ~= "table" or type(uiParent.GetCenter) ~= "function" then
    return
  end
  local frame, ratio = record.frame, scaleRatio(record.frame)
  if not ratio then
    return
  end
  local frameX, frameY = frame:GetCenter()
  local parentX, parentY = uiParent:GetCenter()
  frameX, frameY, parentX, parentY = plain(frameX), plain(frameY), plain(parentX), plain(parentY)
  if not frameX or not frameY or not parentX or not parentY then
    return
  end
  local storage = storageOf(record)
  if not storage then
    return
  end
  local ok, failure = pcall(function()
    storage[layoutName()] = { x = frameX * ratio - parentX, y = frameY * ratio - parentY }
  end)
  if not ok then
    reportError(failure)
  end
end

-- Overlays -------------------------------------------------------------------

---An overlay for `record`'s frame: a free one, or a new one.
---@param record table
---@return table overlay
local function takeOverlay(record)
  local overlay = table.remove(freeOverlays)
  if not overlay then
    overlay = readGlobal("CreateFrame")("Frame")
    local background = overlay:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(overlay)
    background:SetColorTexture(
      OVERLAY_COLOR[1],
      OVERLAY_COLOR[2],
      OVERLAY_COLOR[3],
      OVERLAY_COLOR[4]
    )
    local text = overlay:CreateFontString(nil, "OVERLAY")
    text:SetFontObject("GameFontHighlightSmall")
    text:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    overlay.text = text
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", scripts.OnDragStart)
    overlay:SetScript("OnDragStop", scripts.OnDragStop)
  end
  local frame = record.frame
  overlay:SetParent(frame)
  overlay:ClearAllPoints()
  overlay:SetAllPoints(frame)
  overlay:SetFrameLevel((plain(frame:GetFrameLevel()) or 0) + OVERLAY_LEVEL_OFFSET)
  overlay.text:SetText(record.label)
  overlay:Hide()
  overlays[overlay] = record
  return overlay
end

---Listen for Edit Mode, layout changes and the end of combat, once.
---@param registry table the client's `EventRegistry`, checked by the caller
local function listen(registry)
  if rawget(state, "listening") then
    return
  end
  local owner = rawget(state, "callbackOwner")
  registry:RegisterCallback(EDIT_MODE_ENTER, scripts.enter, owner)
  registry:RegisterCallback(EDIT_MODE_EXIT, scripts.exit, owner)
  local eventFrame = readGlobal("CreateFrame")("Frame")
  eventFrame:SetScript("OnEvent", scripts.OnEvent)
  eventFrame:RegisterEvent(LAYOUTS_UPDATED)
  rawset(state, "eventFrame", eventFrame)
  rawset(state, "listening", true)
  local manager = readGlobal("EditModeManagerFrame")
  if type(manager) == "table" and type(manager.IsEditModeActive) == "function" then
    local ok, active = pcall(manager.IsEditModeActive, manager)
    rawset(state, "editing", ok and not isSecret(active) and active == true)
  end
end

---Edit Mode opened: show every overlay.
function dispatch.enter()
  rawset(state, "editing", true)
  for overlay in pairs(overlays) do
    overlay:Show()
  end
end

---End a drag that is under way: stop moving the frame and, when `keep` is
---set, save where it ended and anchor the frame by it.
---
---A drag ends normally at `OnDragStop`, but a frame that leaves Edit Mode
---while the cursor still holds it would never get there: `Unregister` forgets
---its overlay, and closing Edit Mode hides it. `StartMoving` acts on the frame
---itself, so without this the frame would keep following the cursor.
---@param record table
---@param keep boolean whether to save the position the drag reached
local function endDrag(record, keep)
  if not record.dragging then
    return
  end
  record.dragging = false
  record.frame:StopMovingOrSizing()
  if keep then
    save(record)
    apply(record)
  end
end

---Edit Mode closed: end a drag under way, then hide every overlay.
function dispatch.exit()
  rawset(state, "editing", false)
  for overlay, record in pairs(overlays) do
    endDrag(record, true)
    overlay:Hide()
  end
end

---A layout changed or combat ended: put every frame where its layout says.
---@param event string
function dispatch.event(event)
  if event == COMBAT_ENDED then
    local eventFrame = rawget(state, "eventFrame")
    if eventFrame then
      eventFrame:UnregisterEvent(COMBAT_ENDED)
    end
    for _, record in pairs(records) do
      if record.pending then
        apply(record)
      end
    end
  elseif event == LAYOUTS_UPDATED then
    for _, record in pairs(records) do
      apply(record)
    end
  end
end

---A drag on an overlay starts: move its frame with the cursor.
---@param overlay table
function dispatch.dragStart(overlay)
  local record = overlays[overlay]
  if record == nil or mustWait(record.frame) then
    return
  end
  local frame = record.frame
  frame:SetMovable(true)
  frame:StartMoving()
  -- `StartMoving` flags the frame as user-placed, and the client restores a
  -- named user-placed frame from its layout cache at the next login, over the
  -- position EditModeKit keeps per Edit Mode layout (warcraft.wiki.gg, API
  -- Frame:StartMoving). The position is EditModeKit's, so the flag is cleared.
  if type(frame.SetUserPlaced) == "function" then
    frame:SetUserPlaced(false)
  end
  record.dragging = true
end

---The drag ends: stop moving, save the position, and anchor the frame by it.
---@param overlay table
function dispatch.dragStop(overlay)
  local record = overlays[overlay]
  if record == nil then
    return
  end
  endDrag(record, true)
end

-- Registration methods -------------------------------------------------------

---Take the frame out of Edit Mode: `true`, or `false` when it already was.
---The frame stays where it is; a drag under way ends there, unsaved.
---@param self EditModeKit.Registration
---@return boolean
local function registrationUnregister(self)
  local record = requireRecord(self, "EditModeKit.Registration:Unregister", 3)
  if not record.registered then
    return false
  end
  endDrag(record, false)
  record.registered = false
  records[self] = nil
  byFrame[record.frame] = nil
  local overlay = record.overlay
  overlays[overlay] = nil
  overlay:Hide()
  overlay:ClearAllPoints()
  overlay:SetParent(nil)
  freeOverlays[#freeOverlays + 1] = overlay
  rawset(state, "registrationCount", rawget(state, "registrationCount") - 1)
  return true
end

---Put the frame where the active layout's saved position says.
---@param self EditModeKit.Registration
local function registrationRefresh(self)
  apply(requireRecord(self, "EditModeKit.Registration:Refresh", 3))
end

---The registered frame.
---@param self EditModeKit.Registration
---@return table
local function registrationGetFrame(self)
  return requireRecord(self, "EditModeKit.Registration:GetFrame", 3).frame
end

-- Package public API ---------------------------------------------------------

---Make `frame` part of Edit Mode, its positions per layout in `storage`.
---@param self EditModeKit
---@param frame table
---@param storage EditModeKit.Storage
---@param options { label: string? }?
---@return EditModeKit.Registration
local function packageRegister(self, frame, storage, options)
  local label = "EditModeKit:Register"
  validateFacade(self, label, 3)
  if
    isSecret(frame)
    or type(frame) ~= "table"
    or type(frame.GetCenter) ~= "function"
    or type(frame.StartMoving) ~= "function"
  then
    error(label .. " frame must be a frame", 2)
  end
  if isSecret(storage) or (type(storage) ~= "table" and type(storage) ~= "function") then
    error(label .. " storage must be a table or a function returning one", 2)
  end
  local text = nil
  if type(options) ~= "nil" then
    if isSecret(options) or type(options) ~= "table" then
      error(label .. " options must be a table or nil", 2)
    end
    for key in pairs(options) do
      if isSecret(key) or type(key) ~= "string" or not REGISTER_OPTIONS[key] then
        error(label .. " options holds an unknown field; it accepts label", 2)
      end
    end
    text = options.label
    if type(text) ~= "nil" and (isSecret(text) or type(text) ~= "string" or text == "") then
      error(label .. " options.label must be a non-empty string", 2)
    end
  end
  if byFrame[frame] then
    error(label .. " frame is already registered; unregister it first", 2)
  end
  local maxRegistrations = rawget(sharedLimits, "maxRegistrations")
  if rawget(state, "registrationCount") >= maxRegistrations then
    error(
      label
        .. " holds at most "
        .. maxRegistrations
        .. " frames; raise maxRegistrations with EditModeKit:SetLimits",
      2
    )
  end
  local registry = readGlobal("EventRegistry")
  if
    type(readGlobal("CreateFrame")) ~= "function"
    or type(readGlobal("UIParent")) ~= "table"
    or type(registry) ~= "table"
    or type(registry.RegisterCallback) ~= "function"
  then
    error(
      label
        .. " needs the client's CreateFrame, UIParent and EventRegistry, which this host does not have",
      2
    )
  end
  if text == nil then
    local name = type(frame.GetName) == "function" and frame:GetName() or nil
    text = (not isSecret(name) and type(name) == "string" and name ~= "") and name or "Frame"
  end
  listen(registry)
  local handle = setmetatable({}, REGISTRATION_METATABLE)
  local record = {
    schema = RECORD_SCHEMA,
    handle = handle,
    frame = frame,
    storage = storage,
    label = text,
    registered = true,
    pending = false,
    dragging = false,
  }
  rawset(handle, "_record", record)
  record.overlay = takeOverlay(record)
  records[handle] = record
  byFrame[frame] = record
  rawset(state, "registrationCount", rawget(state, "registrationCount") + 1)
  if rawget(state, "editing") then
    record.overlay:Show()
  end
  apply(record)
  return handle
end

---Whether Edit Mode is open.
---@param self EditModeKit
---@return boolean
local function packageIsEditing(self)
  validateFacade(self, "EditModeKit:IsEditing", 3)
  return rawget(state, "editing") == true
end

---The active Edit Mode layout's name, or `"default"`.
---@param self EditModeKit
---@return string
local function packageGetLayoutName(self)
  validateFacade(self, "EditModeKit:GetLayoutName", 3)
  return layoutName()
end

---Change `maxRegistrations`. Lowering it keeps every registration.
---@param self EditModeKit
---@param limits EditModeKit.Limits
local function packageSetLimits(self, limits)
  validateFacade(self, "EditModeKit:SetLimits", 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error("EditModeKit:SetLimits limits must be a table", 2)
  end
  for key, value in pairs(limits) do
    if isSecret(key) or key ~= "maxRegistrations" then
      error("EditModeKit:SetLimits limits holds an unknown field; it accepts maxRegistrations", 2)
    end
    if isSecret(value) then
      error("EditModeKit:SetLimits limits.maxRegistrations must not be a secret value", 2)
    end
    if not isRegistrationLimit(value) then
      error(
        "EditModeKit:SetLimits limits.maxRegistrations must be an integer from 1 to "
          .. REGISTRATIONS_CEILING,
        2
      )
    end
  end
  if type(limits.maxRegistrations) ~= "nil" then
    rawset(sharedLimits, "maxRegistrations", limits.maxRegistrations)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self EditModeKit
---@return EditModeKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "EditModeKit:GetLimits", 3)
  return { maxRegistrations = rawget(sharedLimits, "maxRegistrations") }
end

-- Commit ---------------------------------------------------------------------

rawset(RegistrationPrototype, "Unregister", registrationUnregister)
rawset(RegistrationPrototype, "Refresh", registrationRefresh)
rawset(RegistrationPrototype, "GetFrame", registrationGetFrame)

rawset(EditModeKit, "API", API_GENERATION)
rawset(EditModeKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(EditModeKit, "MAX_REGISTRATIONS", MAX_REGISTRATIONS)
rawset(EditModeKit, "REGISTRATIONS_CEILING", REGISTRATIONS_CEILING)
rawset(EditModeKit, "Register", packageRegister)
rawset(EditModeKit, "IsEditing", packageIsEditing)
rawset(EditModeKit, "GetLayoutName", packageGetLayoutName)
rawset(EditModeKit, "SetLimits", packageSetLimits)
rawset(EditModeKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(EditModeKit) or not validateCurrentState(EditModeKit) then
  error("MoltenCodes EditModeKit package state is corrupted or incomplete", 2)
end
for index = 1, #REGISTRATION_METHODS do
  if type(rawget(RegistrationPrototype, REGISTRATION_METHODS[index])) ~= "function" then
    error("MoltenCodes EditModeKit package state is corrupted or incomplete", 2)
  end
end

return EditModeKit
