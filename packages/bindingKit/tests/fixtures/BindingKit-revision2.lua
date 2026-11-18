-- MoltenCodes BindingKit
--
-- Key bindings an addon sets at run time without touching the player's own.
-- BindingKit uses override bindings (`SetOverrideBinding`,
-- `SetOverrideBindingClick`), which the client drops at logout and never
-- saves, and keeps them in named scopes, so an addon clears only its own. A key
-- can run a binding command (`"TOGGLEWORLDMAP"`), click a named button, or call
-- a Lua function through a hidden named button of the package's own.
--
-- The client refuses binding changes from addon code in combat. A change made
-- then is kept and applied when combat ends (`PLAYER_REGEN_ENABLED`), and the
-- scope says that it waits.
--
-- BindingKit requires Registry API 2. It reads at call time `CreateFrame`,
-- `SetOverrideBinding`, `SetOverrideBindingClick`, `ClearOverrideBindings`,
-- `InCombatLockdown`, `issecretvalue` and `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ............. identity, limits, names
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry, host readers
--   Validation ............ public-surface and shared-state predicates
--   Bootstrap ............. Registry registration and inherited state
--   Host facilities ....... secret values, the error handler, the client
--   Argument checks ....... receivers, keys, targets, limits
--   Applying .............. a scope's bindings onto the client
--   Function keys ......... the hidden buttons and their free list
--   Scope methods ......... BindCommand, BindClick, BindFunction, ...
--   Package public API .... the facade published through Registry
--   Commit ................ prototype/facade assignment, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "bindingKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 2
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 1

-- Every scope record carries the layout it was built with, so a later
-- revision that changes the layout can upgrade old records instead of guessing.
local RECORD_SCHEMA = 1

-- The defaults and ceilings of the limits. Each scope has an owner frame and
-- each function key a button, frames the session keeps, so neither limit
-- opens to unbounded.
local MAX_SCOPES, SCOPES_CEILING = 32, 256
local MAX_FUNCTION_KEYS, FUNCTION_KEYS_CEILING = 64, 512

-- Function keys click hidden buttons with these global names, numbered.
local BUTTON_NAME_PREFIX = "MoltenCodesBindingKitButton"

-- The event that ends combat.
local COMBAT_ENDED = "PLAYER_REGEN_ENABLED"

-- The kinds of binding.
local KIND_COMMAND, KIND_CLICK, KIND_FUNCTION = "command", "click", "function"

-- The options `CreateScope` accepts.
local SCOPE_OPTIONS = { priority = true }

-- The `__metatable` of every scope handle. It hides the handle's metatable.
local SCOPE_METATABLE_TAG = "BindingKit.Scope"

local FACADE_METHODS = { "CreateScope", "GetScope", "SetLimits", "GetLimits" }
local SCOPE_METHODS = {
  "BindCommand",
  "BindClick",
  "BindFunction",
  "Unbind",
  "ClearAll",
  "GetBinding",
  "IsPending",
  "GetName",
}

-- Public types ---------------------------------------------------------------

---What a key is bound to.
---@alias BindingKit.Kind "command"|"click"|"function"

---A named set of override bindings.
---@class BindingKit.Scope
---@field BindCommand fun(self: BindingKit.Scope, key: string, command: string)
---@field BindClick fun(self: BindingKit.Scope, key: string, buttonName: string, mouseButton: string?)
---@field BindFunction fun(self: BindingKit.Scope, key: string, func: fun(key: string))
---@field Unbind fun(self: BindingKit.Scope, key: string): boolean
---@field ClearAll fun(self: BindingKit.Scope): integer
---@field GetBinding fun(self: BindingKit.Scope, key: string): BindingKit.Kind?, any
---@field IsPending fun(self: BindingKit.Scope): boolean
---@field GetName fun(self: BindingKit.Scope): string

---The shared limits.
---@class BindingKit.Limits
---@field maxScopes integer Scopes in the session: 1 to 256; default `32`.
---@field maxFunctionKeys integer Function keys bound at once: 1 to 512; default `64`.

---The BindingKit package facade published through Registry.
---@class BindingKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field MAX_SCOPES integer Default of `maxScopes` (`32`).
---@field SCOPES_CEILING integer The highest `maxScopes` accepts (`256`).
---@field MAX_FUNCTION_KEYS integer Default of `maxFunctionKeys` (`64`).
---@field FUNCTION_KEYS_CEILING integer The highest `maxFunctionKeys` accepts (`512`).
---@field CreateScope fun(self: BindingKit, name: string, options: { priority: boolean? }?): BindingKit.Scope
---@field GetScope fun(self: BindingKit, name: string): BindingKit.Scope?
---@field SetLimits fun(self: BindingKit, limits: BindingKit.Limits)
---@field GetLimits fun(self: BindingKit): BindingKit.Limits

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
  error("MoltenCodes BindingKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes BindingKit requires a valid Registry API 2 facade", 2)
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

---Whether `implementation` exposes the complete BindingKit API 1 surface.
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
---@param ceiling number
---@return boolean
local function isIntegerUpTo(value, ceiling)
  return type(value) == "number" and value >= 1 and value <= ceiling and value % 1 == 0
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
    and isIntegerUpTo(rawget(limits, "maxScopes"), SCOPES_CEILING)
    and isIntegerUpTo(rawget(limits, "maxFunctionKeys"), FUNCTION_KEYS_CEILING)
    and type(rawget(currentState, "scopes")) == "table"
    and type(rawget(currentState, "records")) == "table"
    and type(rawget(currentState, "scopeCount")) == "number"
    and type(rawget(currentState, "buttons")) == "table"
    and type(rawget(currentState, "freeButtons")) == "table"
    and type(rawget(currentState, "buttonCount")) == "number"
    and type(rawget(currentState, "functionKeyCount")) == "number"
    and type(rawget(currentState, "scopePrototype")) == "table"
    and type(rawget(currentState, "scopeMetatable")) == "table"
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
-- and register this one. What stays here is what only BindingKit can answer.
local BindingKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes BindingKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if BindingKit == nil then
  -- An equal or newer compatible revision already owns the shared package table.
  return selected
end

local state = rawget(BindingKit, "_state")

if previousRevision == nil then
  if state ~= nil then
    error("MoltenCodes BindingKit package state is corrupted or incomplete", 2)
  end

  -- Functions every loading revision rewrites. The frames hold the closures
  -- below as their scripts for the session, so they look their behaviour up.
  local dispatch = {}
  local scopePrototype = {}

  state = {
    schema = STATE_SCHEMA,
    runtimeRevision = 0,
    limits = { maxScopes = MAX_SCOPES, maxFunctionKeys = MAX_FUNCTION_KEYS },
    -- Name to scope record; handle to record.
    scopes = {},
    records = {},
    scopeCount = 0,
    -- Function-key button to its binding while bound; buttons free for reuse.
    buttons = {},
    freeButtons = {},
    buttonCount = 0,
    functionKeyCount = 0,
    -- The frame that waits for the end of combat, made on first need.
    eventFrame = false,
    scopePrototype = scopePrototype,
    scopeMetatable = { __index = scopePrototype, __metatable = SCOPE_METATABLE_TAG },
    dispatch = dispatch,
    scripts = {
      click = function(button)
        dispatch.click(button)
      end,
      OnEvent = function(_, event)
        dispatch.event(event)
      end,
    },
  }
  rawset(BindingKit, "_state", state)
elseif not validateStateBase(state) then
  error("MoltenCodes BindingKit package state is corrupted or incomplete", 2)
end

local scopes = rawget(state, "scopes")
---@type table<table, table>
local records = rawget(state, "records")
---@type table<table, table>
local buttons = rawget(state, "buttons")
local freeButtons = rawget(state, "freeButtons")
local dispatch = rawget(state, "dispatch")
local scripts = rawget(state, "scripts")
local ScopePrototype = rawget(state, "scopePrototype")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
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

---Whether the client is in combat lockdown; `false` without the function.
---@return boolean
local function inCombat()
  local inCombatLockdown = readGlobal("InCombatLockdown")
  if type(inCombatLockdown) ~= "function" then
    return false
  end
  local answer = inCombatLockdown()
  return not isSecret(answer) and answer == true
end

---Whether the client has the override binding functions.
---@return boolean
local function hasBindingApi()
  return type(readGlobal("CreateFrame")) == "function"
    and type(readGlobal("SetOverrideBinding")) == "function"
    and type(readGlobal("SetOverrideBindingClick")) == "function"
    and type(readGlobal("ClearOverrideBindings")) == "function"
end

-- Argument checks ------------------------------------------------------------
--
-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- BindingKit. `level` is always the value `error` needs *inside the function
-- that receives it*, so every further hop towards `error` adds exactly one.
-- Secrets are checked first, because comparing one raises.

---@param receiver any the table the method was called on
---@param label string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  -- `type` first: a secret receiver is never a table, and only a table is compared.
  if type(receiver) ~= "table" or receiver ~= BindingKit then
    error(label .. " must be called on the BindingKit facade; use " .. label .. "(...)", level)
  end
end

---Raise at the caller unless `value` is a non-empty string.
---@param value any
---@param where string
---@param level integer stack level the failure is reported at
local function validateName(value, where, level)
  if isSecret(value) then
    error(where .. " must not be a secret value", level)
  end
  if type(value) ~= "string" or value == "" then
    error(where .. " must be a non-empty string", level)
  end
end

---The record of a scope handle, or raise at the caller.
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
        .. " must be called on a BindingKit scope; use scope:"
        .. label:match("[^:]+$")
        .. "(...)",
      level
    )
  end
  return record
end

-- Applying -------------------------------------------------------------------

---The frame that waits for the end of combat.
---@return table
local function eventFrame()
  local frame = rawget(state, "eventFrame")
  if not frame then
    frame = readGlobal("CreateFrame")("Frame")
    frame:SetScript("OnEvent", scripts.OnEvent)
    rawset(state, "eventFrame", frame)
  end
  return frame
end

---Put `record`'s bindings onto the client: clear the owner's override
---bindings and set each again. In combat the scope waits instead.
---@param record table
local function apply(record)
  if inCombat() then
    record.pending = true
    eventFrame():RegisterEvent(COMBAT_ENDED)
    return
  end
  local clear = readGlobal("ClearOverrideBindings")
  local setBinding = readGlobal("SetOverrideBinding")
  local setClick = readGlobal("SetOverrideBindingClick")
  if
    type(clear) ~= "function"
    or type(setBinding) ~= "function"
    or type(setClick) ~= "function"
  then
    return
  end
  local owner, priority = record.owner, record.priority
  clear(owner)
  for key, binding in pairs(record.bindings) do
    local kind = binding.kind
    if kind == KIND_COMMAND then
      setBinding(owner, priority, key, binding.command)
    elseif kind == KIND_CLICK then
      setClick(owner, priority, key, binding.buttonName, binding.mouseButton)
    else
      setClick(owner, priority, key, binding.button:GetName(), "LeftButton")
    end
  end
  record.pending = false
  -- The client no longer clicks the buttons this scope gave up, so they are
  -- free for other keys now (see `remove`).
  local retired = record.retiredButtons
  if retired then
    for index = #retired, 1, -1 do
      freeButtons[#freeButtons + 1] = retired[index]
      retired[index] = nil
    end
  end
end

---The end of combat: apply every waiting scope, then stop listening.
---@param event string
function dispatch.event(event)
  if event ~= COMBAT_ENDED or inCombat() then
    return
  end
  eventFrame():UnregisterEvent(COMBAT_ENDED)
  for _, record in pairs(scopes) do
    if record.pending then
      apply(record)
    end
  end
end

-- Function keys --------------------------------------------------------------

---A hidden named button for a function key: a free one, or a new one.
---@return table button
local function takeButton()
  local button = tableRemove(freeButtons)
  if button then
    return button
  end
  local count = rawget(state, "buttonCount") + 1
  rawset(state, "buttonCount", count)
  button = readGlobal("CreateFrame")("Button", BUTTON_NAME_PREFIX .. count)
  button:Hide()
  button:SetScript("OnClick", scripts.click)
  return button
end

---A click on a function key's button: the function with the key, protected.
---@param button table
function dispatch.click(button)
  local binding = buttons[button]
  if binding then
    local ok, failure = pcall(binding.func, binding.key)
    if not ok then
      reportError(failure)
    end
  end
end

---Forget the binding of `key` in `record`, freeing its button.
---@param record table
---@param key string
---@return boolean removed
local function remove(record, key)
  local binding = record.bindings[key]
  if not binding then
    return false
  end
  record.bindings[key] = nil
  if binding.kind == KIND_FUNCTION then
    local button = binding.button
    buttons[button] = nil
    rawset(state, "functionKeyCount", rawget(state, "functionKeyCount") - 1)
    if inCombat() then
      -- The change waits for the end of combat, and until then the client
      -- still clicks this button on the old key. Handing it to another key
      -- now would run that key's function on the old one, so it is retired
      -- with the scope and freed when `apply` has cleared the owner.
      -- Revision 1 records have no list yet.
      local retired = record.retiredButtons
      if not retired then
        retired = {}
        record.retiredButtons = retired
      end
      retired[#retired + 1] = button
    else
      -- The `apply` that follows every removal clears the owner now.
      freeButtons[#freeButtons + 1] = button
    end
  end
  return true
end

-- Scope methods --------------------------------------------------------------

---Store `binding` for `key`, replacing what the key had, and apply.
---@param record table
---@param key string
---@param binding table
local function bind(record, key, binding)
  remove(record, key)
  binding.key = key
  record.bindings[key] = binding
  apply(record)
end

---Run the binding command `command` (`"TOGGLEWORLDMAP"`) on `key`.
---@param self BindingKit.Scope
---@param key string
---@param command string
local function scopeBindCommand(self, key, command)
  local label = "BindingKit.Scope:BindCommand"
  local record = requireRecord(self, label, 3)
  validateName(key, label .. " key", 3)
  validateName(command, label .. " command", 3)
  bind(record, key, { kind = KIND_COMMAND, command = command })
end

---Click the button named `buttonName` with `mouseButton` (default
---`"LeftButton"`) on `key`.
---@param self BindingKit.Scope
---@param key string
---@param buttonName string
---@param mouseButton string?
local function scopeBindClick(self, key, buttonName, mouseButton)
  local label = "BindingKit.Scope:BindClick"
  local record = requireRecord(self, label, 3)
  validateName(key, label .. " key", 3)
  validateName(buttonName, label .. " buttonName", 3)
  if type(mouseButton) ~= "nil" then
    validateName(mouseButton, label .. " mouseButton", 3)
  end
  bind(
    record,
    key,
    { kind = KIND_CLICK, buttonName = buttonName, mouseButton = mouseButton or "LeftButton" }
  )
end

---Call `func(key)` on `key`, through a hidden named button. The function
---runs as insecure addon code: it cannot cast or target.
---@param self BindingKit.Scope
---@param key string
---@param func fun(key: string)
local function scopeBindFunction(self, key, func)
  local label = "BindingKit.Scope:BindFunction"
  local record = requireRecord(self, label, 3)
  validateName(key, label .. " key", 3)
  if type(func) ~= "function" then
    error(label .. " func must be a function", 2)
  end
  local current = record.bindings[key]
  local replacing = current and current.kind == KIND_FUNCTION
  local maxKeys = rawget(sharedLimits, "maxFunctionKeys")
  if not replacing and rawget(state, "functionKeyCount") >= maxKeys then
    error(
      label
        .. " holds at most "
        .. maxKeys
        .. " function keys; raise maxFunctionKeys with BindingKit:SetLimits",
      2
    )
  end
  remove(record, key)
  local button = takeButton()
  local binding = { kind = KIND_FUNCTION, func = func, button = button }
  buttons[button] = binding
  rawset(state, "functionKeyCount", rawget(state, "functionKeyCount") + 1)
  bind(record, key, binding)
end

---Remove the binding of `key`: `true`, or `false` when the scope had none.
---@param self BindingKit.Scope
---@param key string
---@return boolean
local function scopeUnbind(self, key)
  local record = requireRecord(self, "BindingKit.Scope:Unbind", 3)
  validateName(key, "BindingKit.Scope:Unbind key", 3)
  if not remove(record, key) then
    return false
  end
  apply(record)
  return true
end

---Remove every binding of the scope; returns how many there were.
---@param self BindingKit.Scope
---@return integer
local function scopeClearAll(self)
  local record = requireRecord(self, "BindingKit.Scope:ClearAll", 3)
  local keys = {}
  for key in pairs(record.bindings) do
    keys[#keys + 1] = key
  end
  for index = 1, #keys do
    remove(record, keys[index])
  end
  apply(record)
  return #keys
end

---What `key` is bound to in this scope: the kind and its target (the
---command, the button name, or the function), or `nil`.
---@param self BindingKit.Scope
---@param key string
---@return BindingKit.Kind? kind
---@return any target
local function scopeGetBinding(self, key)
  local record = requireRecord(self, "BindingKit.Scope:GetBinding", 3)
  validateName(key, "BindingKit.Scope:GetBinding key", 3)
  local binding = record.bindings[key]
  if not binding then
    return nil, nil
  end
  if binding.kind == KIND_COMMAND then
    return KIND_COMMAND, binding.command
  elseif binding.kind == KIND_CLICK then
    return KIND_CLICK, binding.buttonName
  end
  return KIND_FUNCTION, binding.func
end

---Whether the scope's last change waits for the end of combat.
---@param self BindingKit.Scope
---@return boolean
local function scopeIsPending(self)
  return requireRecord(self, "BindingKit.Scope:IsPending", 3).pending == true
end

---The scope's name.
---@param self BindingKit.Scope
---@return string
local function scopeGetName(self)
  return requireRecord(self, "BindingKit.Scope:GetName", 3).name
end

-- Package public API ---------------------------------------------------------

---The scope named `name`, made with an owner frame of its own on first use.
---`options.priority` makes its bindings win over other override bindings;
---it is read only when the scope is made.
---@param self BindingKit
---@param name string
---@param options { priority: boolean? }?
---@return BindingKit.Scope
local function packageCreateScope(self, name, options)
  local label = "BindingKit:CreateScope"
  validateFacade(self, label, 3)
  validateName(name, label .. " name", 3)
  local priority = false
  if type(options) ~= "nil" then
    if isSecret(options) or type(options) ~= "table" then
      error(label .. " options must be a table or nil", 2)
    end
    for key in pairs(options) do
      if isSecret(key) or type(key) ~= "string" or not SCOPE_OPTIONS[key] then
        error(label .. " options holds an unknown field; it accepts priority", 2)
      end
    end
    if
      type(options.priority) ~= "nil"
      and (isSecret(options.priority) or type(options.priority) ~= "boolean")
    then
      error(label .. " options.priority must be a boolean", 2)
    end
    priority = options.priority == true
  end
  local existing = scopes[name]
  if existing then
    return existing.handle
  end
  local maxScopes = rawget(sharedLimits, "maxScopes")
  if rawget(state, "scopeCount") >= maxScopes then
    error(
      label
        .. " holds at most "
        .. maxScopes
        .. " scopes; raise maxScopes with BindingKit:SetLimits",
      2
    )
  end
  if not hasBindingApi() then
    error(
      label .. " needs the client's override binding functions, which this host does not have",
      2
    )
  end
  local handle = setmetatable({}, SCOPE_METATABLE)
  local record = {
    schema = RECORD_SCHEMA,
    name = name,
    handle = handle,
    owner = readGlobal("CreateFrame")("Frame"),
    priority = priority,
    bindings = {},
    pending = false,
    -- Function-key buttons removed in combat, freed once `apply` runs.
    retiredButtons = {},
  }
  scopes[name] = record
  records[handle] = record
  rawset(state, "scopeCount", rawget(state, "scopeCount") + 1)
  return handle
end

---The scope named `name`, or `nil`.
---@param self BindingKit
---@param name string
---@return BindingKit.Scope?
local function packageGetScope(self, name)
  validateFacade(self, "BindingKit:GetScope", 3)
  validateName(name, "BindingKit:GetScope name", 3)
  local record = scopes[name]
  return record and record.handle or nil
end

---Change any subset of the shared limits. Every value is checked before any
---changes; lowering a limit keeps what exists and refuses the next.
---@param self BindingKit
---@param limits BindingKit.Limits
local function packageSetLimits(self, limits)
  local label = "BindingKit:SetLimits"
  validateFacade(self, label, 3)
  if isSecret(limits) or type(limits) ~= "table" then
    error(label .. " limits must be a table", 2)
  end
  local ceilings = { maxScopes = SCOPES_CEILING, maxFunctionKeys = FUNCTION_KEYS_CEILING }
  for key, value in pairs(limits) do
    if isSecret(key) or type(key) ~= "string" or not ceilings[key] then
      error(label .. " limits holds an unknown field; it accepts maxScopes and maxFunctionKeys", 2)
    end
    if isSecret(value) then
      error(label .. " limits." .. key .. " must not be a secret value", 2)
    end
    if not isIntegerUpTo(value, ceilings[key]) then
      error(label .. " limits." .. key .. " must be an integer from 1 to " .. ceilings[key], 2)
    end
  end
  for key, value in pairs(limits) do
    rawset(sharedLimits, key, value)
  end
end

---Return a fresh copy of the shared limits. Allocates one table per call.
---@param self BindingKit
---@return BindingKit.Limits
local function packageGetLimits(self)
  validateFacade(self, "BindingKit:GetLimits", 3)
  return {
    maxScopes = rawget(sharedLimits, "maxScopes"),
    maxFunctionKeys = rawget(sharedLimits, "maxFunctionKeys"),
  }
end

-- Commit ---------------------------------------------------------------------

rawset(ScopePrototype, "BindCommand", scopeBindCommand)
rawset(ScopePrototype, "BindClick", scopeBindClick)
rawset(ScopePrototype, "BindFunction", scopeBindFunction)
rawset(ScopePrototype, "Unbind", scopeUnbind)
rawset(ScopePrototype, "ClearAll", scopeClearAll)
rawset(ScopePrototype, "GetBinding", scopeGetBinding)
rawset(ScopePrototype, "IsPending", scopeIsPending)
rawset(ScopePrototype, "GetName", scopeGetName)

rawset(BindingKit, "API", API_GENERATION)
rawset(BindingKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(BindingKit, "MAX_SCOPES", MAX_SCOPES)
rawset(BindingKit, "SCOPES_CEILING", SCOPES_CEILING)
rawset(BindingKit, "MAX_FUNCTION_KEYS", MAX_FUNCTION_KEYS)
rawset(BindingKit, "FUNCTION_KEYS_CEILING", FUNCTION_KEYS_CEILING)
rawset(BindingKit, "CreateScope", packageCreateScope)
rawset(BindingKit, "GetScope", packageGetScope)
rawset(BindingKit, "SetLimits", packageSetLimits)
rawset(BindingKit, "GetLimits", packageGetLimits)

rawset(state, "runtimeRevision", IMPLEMENTATION_REVISION)

if not validatePublicSurface(BindingKit) or not validateCurrentState(BindingKit) then
  error("MoltenCodes BindingKit package state is corrupted or incomplete", 2)
end
for index = 1, #SCOPE_METHODS do
  if type(rawget(ScopePrototype, SCOPE_METHODS[index])) ~= "function" then
    error("MoltenCodes BindingKit package state is corrupted or incomplete", 2)
  end
end

return BindingKit
