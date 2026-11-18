-- MoltenCodes PoolKit part Generations
--
-- A generation stamped on the objects a pool builds, so objects built by a
-- superseded factory are retired instead of reused after an upgrade: the
-- constructor option `generation` and `pool:SetGeneration`. Without this
-- part both are refused at the caller with the file to embed, and
-- `GetGeneration` answers `1` (docs/API.md, "Generations"; ADR 0001).
--
-- Stamps live in a weak-keyed side table owned by the pool, never on the
-- object, so a consumer's objects keep exactly the shape its factory gave
-- them and a stamp never keeps an object alive. An object built while the
-- pool's generation equals the generation it was created with is not
-- stamped, so a pool that never changes its generation writes no stamps.
--
-- The core calls the hooks this part records in `_state.parts.Generations`
-- (`configure`, `stamp`, `isStale`) only for a pool whose generation differs
-- from its base, and the part reads the core's helpers from `_state.helpers`
-- at call time.
--
-- Contents
-- --------
--   Constants ............. identity and the part interface it needs
--   Core .................. PoolKit's core, its state and its prototype
--   Stamps ................ configuring, stamping and stale detection
--   Methods ............... SetGeneration
--   Commit ................ the part record and the prototype method

-- Constants ------------------------------------------------------------------

local PART_NAME = "Generations"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "poolKit", 1
-- The `_state.helpers` entries and part-record hooks this part relies on; the
-- core publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1
-- The generation of a pool built without a generation option.
local DEFAULT_GENERATION = 1

-- Core -----------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local PoolKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  PoolKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(PoolKit) == "table" and rawget(PoolKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes PoolKit part Generations requires PoolKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return PoolKit
end

local Pool = rawget(PoolKit, "Pool")

-- Stamps ---------------------------------------------------------------------

---Give a pool `PoolKit:New` is building its first generation.
---@param pool table
---@param generation integer
local function configure(pool, generation)
  rawset(pool, "_generation", generation)
  rawset(pool, "_baseGeneration", generation)
end

---Stamp an object built while the pool's generation differs from its base.
---@param pool table
---@param object table|userdata
local function stamp(pool, object)
  rawset(rawget(pool, "_stamps"), object, rawget(pool, "_generation"))
end

---Whether `object` was built by a generation older than the pool's current one.
---@param pool table
---@param object table|userdata
---@return boolean stale
local function isStale(pool, object)
  local generation = rawget(pool, "_generation")
  local baseGeneration = rawget(pool, "_baseGeneration")
  if generation == baseGeneration then
    return false
  end
  local stamps = rawget(pool, "_stamps")
  local objectStamp = stamps and rawget(stamps, object) or baseGeneration
  return objectStamp < generation
end

---Destroy every retained object a newer generation superseded.
---@param pool table
---@return integer removed
local function trimStale(pool)
  local helpers = rawget(state, "helpers")
  local available = rawget(pool, "_available")
  local count = rawget(pool, "_availableCount")
  local kept = 0
  -- `SetGeneration` is rare and never on a hot path, so one scratch list here
  -- is cheaper to read than an allocation-free two-pass variant.
  local stale = {}
  local staleCount = 0

  -- Compact the fresh objects towards the bottom of the stack, keeping their
  -- order, and publish the new count before any destroy callback runs.
  for index = 1, count do
    local object = rawget(available, index)
    if isStale(pool, object) then
      staleCount = staleCount + 1
      stale[staleCount] = object
    else
      kept = kept + 1
      rawset(available, kept, object)
    end
  end
  for index = kept + 1, count do
    rawset(available, index, nil)
  end
  rawset(pool, "_availableCount", kept)

  local firstError = nil
  for index = 1, staleCount do
    local ok, value = helpers.discardAvailableObject(pool, stale[index])
    firstError = helpers.captureFirstError(firstError, ok, value)
  end

  helpers.raiseCaptured(firstError)
  return staleCount
end

-- Methods --------------------------------------------------------------------

---Raise the pool's generation. Retained objects from an older generation are
---destroyed at once; borrowed ones are destroyed instead of retained when they
---come back. Lowering the generation is refused.
---@param self PoolKit.Pool
---@param generation integer positive integer no lower than the current one
---@return integer removed retained objects destroyed by this call
local function poolSetGeneration(self, generation)
  local helpers = rawget(state, "helpers")
  helpers.validatePool(self, "PoolKit.Pool:SetGeneration", 3)
  helpers.ensureMutationAllowed(self, "PoolKit.Pool:SetGeneration", 3)
  helpers.validatePositiveInteger(generation, "PoolKit.Pool:SetGeneration generation", 3)

  local current = rawget(self, "_generation") or DEFAULT_GENERATION
  if generation < current then
    error(
      "PoolKit.Pool:SetGeneration cannot lower the generation from "
        .. tostring(current)
        .. " to "
        .. tostring(generation),
      2
    )
  end
  if generation == current then
    return 0
  end

  if rawget(self, "_baseGeneration") == nil then
    -- A pool built without a generation option has the default one.
    rawset(self, "_baseGeneration", DEFAULT_GENERATION)
  end
  if not rawget(self, "_stamps") then
    rawset(self, "_stamps", setmetatable({}, { __mode = "k" }))
  end
  rawset(self, "_generation", generation)
  return trimStale(self)
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { SetGeneration = poolSetGeneration },
  configure = configure,
  stamp = stamp,
  isStale = isStale,
})
rawset(Pool, "SetGeneration", poolSetGeneration)

return PoolKit
