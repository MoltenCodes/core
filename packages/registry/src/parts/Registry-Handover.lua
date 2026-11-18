-- MoltenCodes Registry part Handover
--
-- What a package needs only when a newer revision of it replaces an older one
-- and the two must hand state over: `request.retire`, `request.migrations` and
-- `request.sealFacade` of `Registry:Bootstrap`, and `Registry:OnRetire`. No Kit
-- in this repository uses them, so the core leaves them out and an addon that
-- does embeds this file after `registry\Registry.lua`
-- (docs/decisions/0001-kit-core-and-parts.md).
--
-- The part records itself in the core's state as `parts.Handover`, with its
-- revision, its facade method and the two entries `Bootstrap` calls
-- (`retireOutgoing` and `adopt`). It reads the core's validators and entry
-- accessors from `state.helpers` at call time, so a core upgraded after this
-- part loaded serves it. Two addons may embed different revisions of the part;
-- the highest wins.
--
-- Contents
--
--   Constants ................ Identity and the state keys.
--   Core ..................... Finding the loaded core and its state.
--   Shared helpers ........... The secret probe, error reporting, key naming.
--   Retirement and migration . OnRetire, the outgoing hand-over and the
--                              migration runner.
--   Sealed facades ........... The metatable that refuses new facade fields.
--   Adoption ................. What `Bootstrap` hands the incoming copy.
--   Commit ................... Recording the part and installing `OnRetire`.

-- Constants ---------------------------------------------------------------

local PART_NAME = "Handover"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local GLOBAL_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"

-- Entry status values, as the core writes them.
local STATUS_ACTIVE = "active"
local STATUS_RETIRED = "retired"

local MIGRATIONS_SHAPE = "request.migrations must map positive revisions to functions"

-- Core --------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared namespace and the Registry state are the documented hand-off points between
-- independently embedded copies; both exist only in the global table.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
-- selene: allow(global_usage)
local state = rawget(_G, GLOBAL_STATE_KEY)
if
  type(Registry) ~= "table"
  or type(rawget(Registry, "HasPart")) ~= "function"
  or type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes Registry part Handover requires Registry API 2 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return Registry
end

-- Shared helpers ------------------------------------------------------------

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

-- shared:begin describeKey 1
-- Copied from tooling/shared/lua/describeKey.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Name `key` for an error message without running any of the caller's code.
---@param key any
---@return string
local function describeKey(key)
  if isSecret(key) then
    return "<secret>"
  end
  local kind = type(key)
  if kind == "string" then
    return key
  end
  if kind == "number" or kind == "boolean" then
    return tostring(key)
  end
  return "<" .. kind .. ">"
end
-- shared:end describeKey

-- Retirement and migration -------------------------------------------------
--
-- When a newer revision replaces an older one, the outgoing copy may hand its
-- state over (its `retire` hook) and the incoming copy runs the migration steps
-- between the two revisions, each exactly once, in ascending order. The shared
-- facade and the Kit's prototype tables keep their identity throughout, so the
-- outgoing copy's entry points already resolve to the incoming methods.

---Registers the retire hook of the currently selected revision.
---
---`Registry:Bootstrap` does this from `request.retire`; this method is for a
---package that only knows what to hand over once its file has finished.
---@param packageName string
---@param api integer
---@param retire fun(implementation: table, incomingRevision: integer): any
local function onRetire(_, packageName, api, retire)
  local helpers = rawget(state, "helpers")
  helpers.validatePackageName(packageName, "OnRetire")
  helpers.validatePositiveInteger(api, "OnRetire", "api")
  if type(retire) ~= "function" then
    error("Registry:OnRetire retire must be a function", 2)
  end
  local entry = helpers.findEntry(packageName, api, 4)
  if entry == nil then
    error('Registry:OnRetire package "' .. packageName .. '" is not registered', 2)
  end
  rawset(entry, "retire", retire)
end

---Mark the entry retired and ask the outgoing copy for its state, once. A failing
---hook is reported and the upgrade continues from no hand-over, not a half-drained one.
---@param entry table
---@param implementation table
---@param incomingRevision integer
---@param label string
---@return any handover
local function retireOutgoing(entry, implementation, incomingRevision, label)
  if rawget(entry, "migrating") == true then
    -- The copy that retired already handed over; its state waits in
    -- `pendingState` for the migration run to be resumed.
    return nil
  end
  local retire = rawget(entry, "retire")
  rawset(entry, "retire", nil)
  rawset(entry, "status", STATUS_RETIRED)
  if type(retire) ~= "function" then
    return nil
  end
  local ok, handover = pcall(retire, implementation, incomingRevision)
  if ok then
    return handover
  end
  reportError(label .. " retire hook failed: " .. tostring(handover))
  return nil
end

---The migration steps in `(fromRevision, toRevision]`, ascending.
---@param migrations table
---@param fromRevision integer
---@param toRevision integer
---@return integer[]|nil steps `nil` when the table is malformed
local function selectMigrationSteps(migrations, fromRevision, toRevision)
  local isBoundedInteger = rawget(state, "helpers").isBoundedInteger
  local steps = {}
  for step, migrate in next, migrations do
    if not isBoundedInteger(step, 1) or type(migrate) ~= "function" then
      return nil
    end
    if step > fromRevision and step <= toRevision then
      steps[#steps + 1] = step
    end
  end
  table.sort(steps)
  return steps
end

---Run every migration step this entry has not run yet.
---
---`migratedThrough` is what makes each step run exactly once: a copy that
---resumes over state an earlier copy of the same revision already migrated
---starts after the last recorded step, not after the inherited revision.
---While a run is unfinished (`migrating`), the next copy starts after the last
---step that completed and receives the state that step produced
---(`pendingState`), so a failed step is retried rather than skipped.
---@param entry table
---@param migrations table|nil
---@param inheritedRevision integer
---@param revision integer
---@param handover any
---@param implementation table
---@return boolean ok
---@return any stateOrProblem the migrated state, or the failure message
local function runMigrations(
  entry,
  migrations,
  inheritedRevision,
  revision,
  handover,
  implementation
)
  local isBoundedInteger = rawget(state, "helpers").isBoundedInteger
  local fromRevision = inheritedRevision
  local migratedThrough = rawget(entry, "migratedThrough")
  local migratedState = handover
  if rawget(entry, "migrating") == true and isBoundedInteger(migratedThrough, 0) then
    -- An earlier copy's run stopped at a failing step. The state is in the
    -- layout of the last step that completed, whatever revision this copy
    -- inherited, and carries on from where that run left it.
    fromRevision = migratedThrough
    migratedState = rawget(entry, "pendingState")
  else
    if isBoundedInteger(migratedThrough, 0) and migratedThrough > fromRevision then
      fromRevision = migratedThrough
    end
    rawset(entry, "migrating", true)
    rawset(entry, "migratedThrough", fromRevision)
    rawset(entry, "pendingState", migratedState)
  end
  if type(migrations) ~= "nil" then
    local steps = selectMigrationSteps(migrations, fromRevision, revision)
    if steps == nil then
      return false, MIGRATIONS_SHAPE
    end
    for index = 1, #steps do
      local step = steps[index]
      local ok, result = pcall(rawget(migrations, step), migratedState, implementation)
      if not ok then
        return false, "migration to revision " .. step .. " failed: " .. tostring(result)
      end
      if type(result) ~= "nil" then
        migratedState = result
      end
      rawset(entry, "migratedThrough", step)
      rawset(entry, "pendingState", migratedState)
    end
  end
  if fromRevision < revision then
    rawset(entry, "migratedThrough", revision)
  end
  rawset(entry, "migrating", nil)
  rawset(entry, "pendingState", nil)
  rawset(entry, "status", STATUS_ACTIVE)
  return true, migratedState
end

-- Sealed facades -----------------------------------------------------------

---Install, keep or remove the sealed-facade metatable, as the request asks.
---
---Lua 5.1 has no metamethod for assignments to fields that already exist, so a
---seal refuses *new* fields only; see `docs/API.md`. A newer revision that does
---not ask for the seal removes the one Registry installed, because the newer
---revision owns the facade's policy. Each seal carries its sealer's label.
---@param entry table
---@param implementation table
---@param wanted boolean
---@param label string
---@return boolean ok `false` when the facade carries a metatable Registry did not install
local function applySeal(entry, implementation, wanted, label)
  local seal = rawget(entry, "seal")
  local current = getmetatable(implementation)
  if not wanted then
    if seal ~= nil and current == seal then
      setmetatable(implementation, nil)
    end
    return true
  end
  if current ~= nil and current ~= seal then
    return false
  end

  local refusal = '" cannot be added from outside the package'
  seal = {
    __newindex = function(_, key)
      -- Named without `tostring` on a table: its `__tostring` is foreign code.
      error(label .. ' facade is sealed; field "' .. describeKey(key) .. refusal, 2)
    end,
  }
  rawset(entry, "seal", seal)
  setmetatable(implementation, seal)
  return true
end

-- Adoption ----------------------------------------------------------------

---Finish handing `implementation` to the copy `Bootstrap` selected: run the
---migration steps it has not run yet, record its retire hook, and apply the
---seal it asked for. `Bootstrap` has validated `request` and raises a failure
---at its caller, prefixed with the request's label.
---@param entry table
---@param implementation table
---@param inheritedRevision integer|nil
---@param handover any
---@param request Registry.BootstrapRequest
---@return boolean ok
---@return any stateOrProblem the migrated state, or the failure message
local function adopt(entry, implementation, inheritedRevision, handover, request)
  local revision = rawget(request, "revision")
  local retire = rawget(request, "retire")
  local migrations = rawget(request, "migrations")
  local wantsSeal = rawget(request, "sealFacade") == true
  local label = rawget(request, "label")
  local migratedState = nil
  if inheritedRevision == nil then
    -- Nothing was inherited, so no step runs; the table is still validated,
    -- so a malformed one fails on every load, not only on the first upgrade.
    if
      type(migrations) ~= "nil" and selectMigrationSteps(migrations, revision, revision) == nil
    then
      return false, MIGRATIONS_SHAPE
    end
    rawset(entry, "migratedThrough", revision)
    rawset(entry, "status", STATUS_ACTIVE)
  else
    local ok, result =
      runMigrations(entry, migrations, inheritedRevision, revision, handover, implementation)
    if not ok then
      return false, result
    end
    migratedState = result
  end
  if type(retire) ~= "nil" then
    rawset(entry, "retire", retire)
  end
  if not applySeal(entry, implementation, wantsSeal, label) then
    return false, "cannot seal a facade that already carries a metatable"
  end
  return true, migratedState
end

-- Commit ------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { OnRetire = onRetire },
  retireOutgoing = retireOutgoing,
  adopt = adopt,
})
rawset(Registry, "OnRetire", onRetire)

return Registry
