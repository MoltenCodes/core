-- MoltenCodes PoolKit
--
-- Allocation-conscious reusable object pools for World of Warcraft addons.
-- PoolKit is pure Lua: it owns object lifecycle and retention policy without
-- depending on Frames, timers, or other WoW APIs.
--
-- This file is the core (ADR 0001, docs/decisions/0001-kit-core-and-parts.md):
-- the plain pool every Kit in the repository uses, with its bounds, its
-- creation cap for objects the host can never free, and its diagnostics.
-- Four parts load after it and add the mechanisms only some pools use:
--   Waiting ..... a live limit (`maxActive`) and a bounded waiting queue
--                 (`maxWaiting`, `Acquire(onAvailable)`, `CancelWaiting`);
--   Children .... cascading release of attached children;
--   Deferred .... release deferred until an animation finishes;
--   Generations . a generation stamped on objects, so objects built by a
--                 superseded factory are retired instead of reused.
-- The core keeps one test per mechanism on the paths a mechanism changes and
-- calls the part through `_state.parts`; a pool can only reach a mechanism's
-- state through its part. Without a part, its mutators raise at the caller
-- with the file to embed, its constructor options are refused the same way,
-- and its getters answer the neutral value.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, status markers, reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Bootstrap ............. surface/state validation, registration, migration
--   Validation ............ shared helper blocks and argument checks
--   Option parsing ........ one rule table and its walker
--   Error helpers ......... best-effort error capture
--   Diagnostics ........... host error-handler reporting
--   Internal lifecycle .... callback guard, factory, discard, trimming
--   Parts ................. part lookup, stubs, and older pools' mechanisms
--   Capacity .............. creation cap, live limit, borrowing
--   Release transaction ... the one path every release goes through
--   Construction .......... pool creation and constructor prewarm
--   Pool methods .......... the handle a pool owner receives
--   Package constructors .. New, NewTablePool and HasPart
--   Commit ................ prototype/facade assignment, part helpers, self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "poolKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 12
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 2
local DEFAULT_MAX_RETAINED = 128

-- The generation of what the core offers its parts: the `_state.helpers`
-- entries and the hooks a part record carries. Entries are only ever added; a
-- core that must change one adds a new entry and raises this number.
local PART_INTERFACE = 1

-- What a member of a part that is not loaded tells the caller to embed.
local PART_FILES = {
  Waiting = "poolKit\\parts\\PoolKit-Waiting.lua",
  Children = "poolKit\\parts\\PoolKit-Children.lua",
  Deferred = "poolKit\\parts\\PoolKit-Deferred.lua",
  Generations = "poolKit\\parts\\PoolKit-Generations.lua",
}

-- The `PoolKit.Pool` mutators each part provides. Without the part each stays
-- on the prototype as a stub naming the file to embed, so the surface check
-- of every older embedded copy keeps accepting the prototype.
local PART_METHODS = {
  CancelWaiting = "Waiting",
  AttachChild = "Children",
  DetachChild = "Children",
  ReleaseAfter = "Deferred",
  SetGeneration = "Generations",
}

-- A pool's generation when its constructor names none, and the generation of
-- every pool an older revision built. Fixed rather than tied to PoolKit's own
-- revision, so behaviour never depends on which embedded copy won.
local DEFAULT_GENERATION = 1

-- The shape every pool carries. Pools built by revisions 1 to 3 have no
-- `_schema` field and are brought up to this shape the first time a method of
-- this revision touches them (see `upgradePool`). Revision 12 pools are sparse
-- (a field that would be `false` or `0` is absent) and keep this schema: every
-- path reads such a field by truthiness, which reads `false` and `nil` alike.
local POOL_SCHEMA = 2

-- Per-object status in a pool's `_active` map. `PARKED` is an object whose
-- release waits for an animation: still owned by the pool, no longer borrowed.
local ACTIVE = 1
local RELEASING = 2
local PARKED = 3

-- Why `Acquire` handed out nothing. Plain strings, so a caller compares them
-- against literals without reaching for a PoolKit constant.
local REASON_EXHAUSTED = "exhausted"
local REASON_WAITING = "waiting"
local REASON_QUEUE_FULL = "queueFull"
local REASON_CLOSED = "closed"

-- Public types --------------------------------------------------------------
--
-- PoolKit publishes its methods by writing them onto a Registry-owned prototype
-- table, so the editor-facing contract is declared here as LuaCATS classes
-- rather than inferred from those assignments.

---Options shared by every pool constructor.
---@class PoolKit.CommonOptions
---@field maxRetained (integer|table)? Non-negative integer or `PoolKit.UNBOUNDED`; default `128`.
---@field strict boolean? Keep weak discarded-object history for richer duplicate-release diagnostics; default `true`.
---@field prewarm integer? Objects to create up front; default `0`.
---@field maxActiveWarning integer? Report once through `geterrorhandler` when this many objects are borrowed at the same time.
---@field generation integer? Positive integer stamped on every object the factory builds; default `1`. Needs the Generations part.

---Options accepted by `PoolKit:New`.
---@class PoolKit.NewOptions : PoolKit.CommonOptions
---@field create PoolKit.Factory Required factory.
---@field reset PoolKit.ObjectCallback? Called before retention or discard.
---@field destroy PoolKit.ObjectCallback? Called when an object leaves pool ownership.
---@field strictReset boolean? Refuse to construct a pool that has no `reset`; default `false`.
---@field maxCreated integer? Positive cap on factory calls over the pool's lifetime; for objects the host can never free.
---@field maxActive integer? Positive cap on objects borrowed or parked at the same time. Needs the Waiting part.
---@field maxWaiting integer? Bounded waiting-queue size for `Acquire(onAvailable)`; default `0`; requires `maxCreated` or `maxActive`. Needs the Waiting part.

---The factory a pool calls when it has no retained object to hand out.
---@alias PoolKit.Factory fun(pool: PoolKit.Pool): table|userdata

---A per-object lifecycle callback: `reset` before retention, `destroy` on exit.
---@alias PoolKit.ObjectCallback fun(object: table|userdata, pool: PoolKit.Pool)

---Why `Acquire` returned no object.
---@alias PoolKit.AcquireReason "exhausted"|"waiting"|"queueFull"

---A queued `Acquire` request. It receives the object once one frees, or `nil`
---and `"closed"` when the pool closes first.
---@alias PoolKit.WaitCallback fun(object: table|userdata|nil, pool: PoolKit.Pool, reason: "closed"|nil)

---The part of a World of Warcraft AnimationGroup that `ReleaseAfter` uses.
---@class PoolKit.AnimationGroup
---@field HookScript fun(self: PoolKit.AnimationGroup, scriptName: string, handler: function)
---@field IsPlaying fun(self: PoolKit.AnimationGroup): boolean
---@field Play fun(self: PoolKit.AnimationGroup, ...)
---@field Stop fun(self: PoolKit.AnimationGroup, ...)

---A reusable object pool.
---@class PoolKit.Pool
---@field Acquire fun(self: PoolKit.Pool, onAvailable: PoolKit.WaitCallback?): table|userdata|nil, PoolKit.AcquireReason?
---@field Release fun(self: PoolKit.Pool, object: table|userdata): boolean
---@field Prewarm fun(self: PoolKit.Pool, count: integer): integer
---@field Trim fun(self: PoolKit.Pool, retainCount: integer?): integer
---@field Clear fun(self: PoolKit.Pool): integer
---@field Close fun(self: PoolKit.Pool): boolean
---@field IsClosed fun(self: PoolKit.Pool): boolean
---@field GetAvailableCount fun(self: PoolKit.Pool): integer
---@field GetActiveCount fun(self: PoolKit.Pool): integer
---@field GetCreatedCount fun(self: PoolKit.Pool): integer
---@field GetDiscardedCount fun(self: PoolKit.Pool): integer
---@field GetMaxRetained fun(self: PoolKit.Pool): integer|table
---@field SetMaxRetained fun(self: PoolKit.Pool, maxRetained: integer|table): PoolKit.Pool
---@field Owns fun(self: PoolKit.Pool, object: any): boolean
---@field IsActive fun(self: PoolKit.Pool, object: any): boolean
---@field GetGeneration fun(self: PoolKit.Pool): integer
---@field SetGeneration fun(self: PoolKit.Pool, generation: integer): integer
---@field GetWaitingCount fun(self: PoolKit.Pool): integer
---@field CancelWaiting fun(self: PoolKit.Pool, callback: PoolKit.WaitCallback): boolean
---@field GetParkedCount fun(self: PoolKit.Pool): integer
---@field GetMaxCreated fun(self: PoolKit.Pool): integer|false
---@field SetMaxCreated fun(self: PoolKit.Pool, maxCreated: integer): PoolKit.Pool
---@field AttachChild fun(self: PoolKit.Pool, parent: table|userdata, child: table|userdata, childPool: PoolKit.Pool): PoolKit.Pool
---@field DetachChild fun(self: PoolKit.Pool, child: table|userdata): boolean
---@field ReleaseAfter fun(self: PoolKit.Pool, object: table|userdata, animationGroup: PoolKit.AnimationGroup): boolean
---@field package _schema integer pool shape; see `upgradePool`
---@field package _create PoolKit.Factory
---@field package _reset PoolKit.ObjectCallback|false|nil
---@field package _destroy PoolKit.ObjectCallback|false|nil
---@field package _maxRetained integer|table a count or `UNBOUNDED`
---@field package _available table<integer, table|userdata> retained objects, newest last
---@field package _availableCount integer
---@field package _active table<table|userdata, integer> borrowed and parked objects and their status
---@field package _activeCount integer
---@field package _maxActiveWarning integer|false|nil
---@field package _activeWarned boolean|nil
---@field package _retained table<table|userdata, boolean> identity set of `_available`
---@field package _released table|false|nil weak set of discarded objects, for strict pools
---@field package _createdCount integer
---@field package _discardedCount integer
---@field package _closed boolean|nil
---@field package _callbackPhase string|false|nil the lifecycle callback running, for the refusal message
---@field package _callbackDepth integer lifecycle callbacks running on this pool
---@field package _trustedCallbacks boolean|nil built-in table-pool callbacks
---@field package _maxCreated integer|false|nil
---@field package _generation integer|nil Generations part
---@field package _baseGeneration integer|nil Generations part
---@field package _stamps table|false|nil Generations part
---@field package _maxActive integer|false|nil Waiting part
---@field package _maxWaiting integer|nil Waiting part
---@field package _waiting table|false|nil Waiting part
---@field package _waitingHead integer|nil Waiting part
---@field package _waitingCount integer|nil Waiting part
---@field package _parked table|false|nil Deferred part
---@field package _parkedCount integer|nil Deferred part
---@field package _children table|false|nil Children part
---@field package _attachedTo table|false|nil Children part

---The PoolKit package facade published through Registry.
---@class PoolKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Pool PoolKit.Pool Shared pool prototype.
---@field UNBOUNDED table Sentinel selecting caller-owned unbounded retention.
---@field DEFAULT_MAX_RETAINED integer Retention bound a pool gets when `maxRetained` is absent (`128`).
---@field New fun(self: PoolKit, options: PoolKit.NewOptions): PoolKit.Pool
---@field NewTablePool fun(self: PoolKit, options: PoolKit.CommonOptions?): PoolKit.Pool
---@field HasPart fun(self: PoolKit, name: string): boolean Whether the named part (`"Waiting"`, `"Children"`, `"Deferred"`, `"Generations"`) is loaded.

-- Dependencies --------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil

-- Ask for Registry by generation and fall back to the alias. A future Registry
-- API generation takes over `MoltenCodes.Registry`, so reading the alias first
-- would hand this file a facade whose contract it was not written against.
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
if type(Registry) == "nil" and type(namespace) == "table" then
  Registry = rawget(namespace, "Registry")
end
if type(Registry) ~= "table" or rawget(Registry, "API") ~= REQUIRED_REGISTRY_API then
  error("MoltenCodes PoolKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
if type(bootstrapPackage) ~= "function" then
  error("MoltenCodes PoolKit requires a valid Registry API 2 facade", 2)
end

-- Bootstrap -----------------------------------------------------------------

---Whether `implementation` exposes the complete PoolKit API 1 surface. Every
---member of a part stays on the prototype as a stub when the part is absent.
---@param implementation any shared package table handed back by Registry
---@return boolean
local function validatePublicSurface(implementation)
  if
    type(implementation) ~= "table"
    or rawget(implementation, "API") ~= API_GENERATION
    or type(rawget(implementation, "REVISION")) ~= "number"
    or type(rawget(implementation, "Pool")) ~= "table"
    or type(rawget(implementation, "UNBOUNDED")) ~= "table"
    or rawget(implementation, "DEFAULT_MAX_RETAINED") ~= DEFAULT_MAX_RETAINED
  then
    return false
  end

  local Pool = rawget(implementation, "Pool")
  return type(rawget(implementation, "New")) == "function"
    and type(rawget(implementation, "NewTablePool")) == "function"
    and type(rawget(implementation, "HasPart")) == "function"
    and type(rawget(Pool, "Acquire")) == "function"
    and type(rawget(Pool, "Release")) == "function"
    and type(rawget(Pool, "Prewarm")) == "function"
    and type(rawget(Pool, "Trim")) == "function"
    and type(rawget(Pool, "Clear")) == "function"
    and type(rawget(Pool, "Close")) == "function"
    and type(rawget(Pool, "IsClosed")) == "function"
    and type(rawget(Pool, "GetAvailableCount")) == "function"
    and type(rawget(Pool, "GetActiveCount")) == "function"
    and type(rawget(Pool, "GetCreatedCount")) == "function"
    and type(rawget(Pool, "GetDiscardedCount")) == "function"
    and type(rawget(Pool, "GetMaxRetained")) == "function"
    and type(rawget(Pool, "SetMaxRetained")) == "function"
    and type(rawget(Pool, "Owns")) == "function"
    and type(rawget(Pool, "IsActive")) == "function"
    and type(rawget(Pool, "GetGeneration")) == "function"
    and type(rawget(Pool, "SetGeneration")) == "function"
    and type(rawget(Pool, "GetWaitingCount")) == "function"
    and type(rawget(Pool, "CancelWaiting")) == "function"
    and type(rawget(Pool, "GetParkedCount")) == "function"
    and type(rawget(Pool, "GetMaxCreated")) == "function"
    and type(rawget(Pool, "SetMaxCreated")) == "function"
    and type(rawget(Pool, "AttachChild")) == "function"
    and type(rawget(Pool, "DetachChild")) == "function"
    and type(rawget(Pool, "ReleaseAfter")) == "function"
end

---Whether `currentState` has the fields every API 1 revision shares.
---@param currentState any
---@return boolean
local function validateStateBase(currentState)
  return type(currentState) == "table"
    and type(rawget(currentState, "poolMetatable")) == "table"
    and type(rawget(currentState, "unbounded")) == "table"
end

---Whether `currentState` has the shape this revision's schema requires.
---@param currentState any
---@return boolean
local function validateState(currentState)
  local partInterface = validateStateBase(currentState) and rawget(currentState, "partInterface")
  return type(partInterface) == "number"
    and partInterface >= PART_INTERFACE
    and rawget(currentState, "schema") == STATE_SCHEMA
    and type(rawget(currentState, "hookedGroups")) == "table"
    and type(rawget(currentState, "deferredPool")) == "table"
    and type(rawget(currentState, "deferredObject")) == "table"
    and type(rawget(currentState, "dispatch")) == "table"
    and type(rawget(currentState, "parts")) == "table"
    and type(rawget(currentState, "helpers")) == "table"
    and type(rawget(currentState, "releasedMetatable")) == "table"
end

---Whether `implementation` and its package state still agree with each other.
---@param implementation table
---@return boolean
local function validateCurrentState(implementation)
  local currentState = rawget(implementation, "_state")
  if not validateState(currentState) then
    return false
  end

  return rawget(implementation, "UNBOUNDED") == rawget(currentState, "unbounded")
    and rawget(implementation, "DEFAULT_MAX_RETAINED") == DEFAULT_MAX_RETAINED
    and rawget(rawget(currentState, "poolMetatable"), "__index") == rawget(implementation, "Pool")
end

-- `Registry:Bootstrap` owns the reconciliation every embedded package repeats:
-- look the package up, refuse to reinterpret state owned by a newer revision,
-- and register this one. What stays here is what only PoolKit can answer.
local PoolKit, previousRevision, selected = bootstrapPackage(Registry, {
  package = PACKAGE_NAME,
  api = API_GENERATION,
  revision = IMPLEMENTATION_REVISION,
  label = "MoltenCodes PoolKit",
  validatePublicSurface = validatePublicSurface,
  validateState = validateCurrentState,
})

if type(PoolKit) == "nil" then
  -- Equal or newer compatible revision already owns the shared package table.
  return selected
end

local Pool = rawget(PoolKit, "Pool")
local state = rawget(PoolKit, "_state")

if type(previousRevision) == "nil" then
  if Pool ~= nil or state ~= nil then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
  end

  Pool = {}
  state = {
    schema = STATE_SCHEMA,
    poolMetatable = {},
    unbounded = {},
    -- Animation groups carry one permanent `OnFinished` hook each, so the
    -- set of hooked groups is remembered and never hooked twice (Deferred
    -- part).
    hookedGroups = setmetatable({}, { __mode = "k" }),
    -- The pending deferred release of each animation group, if any.
    deferredPool = {},
    deferredObject = {},
    -- Host hooks call through this table, so a newer revision replaces
    -- the behaviour behind hooks an older revision installed.
    dispatch = {},
    -- The parts loaded (name to record), what they call, and the interface
    -- generation the core offers them.
    parts = {},
    helpers = {},
    partInterface = PART_INTERFACE,
    -- One weak-keyed metatable every strict pool's `_released` set shares.
    releasedMetatable = { __mode = "k" },
  }
  rawset(PoolKit, "Pool", Pool)
  rawset(PoolKit, "_state", state)
elseif type(Pool) ~= "table" or not validateStateBase(state) then
  error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
else
  if rawget(state, "schema") == 1 then
    -- Revisions 1 to 3 kept no generations and no deferred releases. Their
    -- pools cannot be enumerated from here, so they are upgraded lazily
    -- (see `upgradePool`), which this flag keeps available for good: a later
    -- revision that inherits from this one still finds such pools. Revision 4
    -- also recorded a `legacyGeneration` here; revisions 5 and later never
    -- read it and leave it where it is.
    rawset(state, "hookedGroups", setmetatable({}, { __mode = "k" }))
    rawset(state, "deferredPool", {})
    rawset(state, "deferredObject", {})
    rawset(state, "dispatch", {})
    rawset(state, "schema", STATE_SCHEMA)
    rawset(state, "legacyPools", true)
  end
  if previousRevision < 12 then
    -- Revisions 11 and older built every mechanism into one file, so their
    -- pools may hold a queue, a parked object, children or a raised
    -- generation without the part that now owns it. Sticky, like
    -- `legacyPools`, for the same reason.
    rawset(state, "fullPools", true)
  end
  if type(rawget(state, "parts")) ~= "table" then
    rawset(state, "parts", {})
  end
  if type(rawget(state, "helpers")) ~= "table" then
    rawset(state, "helpers", {})
  end
  if type(rawget(state, "releasedMetatable")) ~= "table" then
    rawset(state, "releasedMetatable", { __mode = "k" })
  end
  local partInterface = rawget(state, "partInterface")
  if type(partInterface) ~= "number" or partInterface < PART_INTERFACE then
    rawset(state, "partInterface", PART_INTERFACE)
  end

  if not validateState(state) then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
  end
end

local POOL_METATABLE = rawget(state, "poolMetatable")
local UNBOUNDED = rawget(state, "unbounded")
local RELEASED_METATABLE = rawget(state, "releasedMetatable")
local parts = rawget(state, "parts")
rawset(POOL_METATABLE, "__index", Pool)

-- Validation ----------------------------------------------------------------
--
-- Secret values (Retail 12.0.0 and later) raise when compared, so an argument
-- a check would compare is first asked about with the host probe, and absence
-- of a caller's value is tested with `type(value) == "nil"`. A host without
-- `issecretvalue` has no secret values.

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

-- shared:begin validateFacade 1 __FACADE__=PoolKit
-- Copied from tooling/shared/lua/validateFacade.lua by python3 -m tooling.shared.sync; edit that file, not this copy.
---Raise at `level` unless `receiver` is the PoolKit facade.
---@param receiver any the table the method was called on
---@param label string qualified method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFacade(receiver, label, level)
  if type(receiver) ~= "table" or receiver ~= PoolKit then
    local hint = "; use " .. label .. "(...)"
    error(label .. " must be called on the PoolKit facade" .. hint, level)
  end
end
-- shared:end validateFacade

---Refuse a secret argument before any comparison touches it.
---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function refuseSecret(value, label, level)
  if isSecret(value) then
    error(label .. " must not be a secret value", level)
  end
end

---Whether `value` is an exact integer of zero or more. `nan` and both
---infinities are rejected before the integer test can accept them, and a
---secret value is rejected before any comparison.
---@param value any
---@return boolean
local function isNonNegativeInteger(value)
  return type(value) == "number"
    and not isSecret(value)
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= 0
    and value % 1 == 0
end

-- Argument validation raises with an explicit stack level so the reported
-- position is the line that called the public method, never a line inside
-- PoolKit. `level` is always the value `error` needs *inside the function that
-- receives it*, so every further hop towards `error` adds exactly one.
--
-- Level `0` means "no position information" and must stay `0` through every
-- hop. The constructor-time prewarm path needs it: that failure is caught and
-- re-raised verbatim, so a position computed across the `pcall` boundary would
-- be meaningless.
---Return the stack level one hop further from `error`, preserving level `0`.
---@param level integer
---@return integer
local function nestedLevel(level)
  if level == 0 then
    return 0
  end
  return level + 1
end

---Whether `value` is an exact integer of one or more.
---@param value any
---@return boolean
local function isPositiveInteger(value)
  return isNonNegativeInteger(value) and value >= 1
end

-- Bring a pool built by revisions 1 to 3 up to the schema every later
-- revision reads. Pools are not registered anywhere, so a bootstrap cannot
-- migrate them; every pool method validates its receiver first, and that
-- check upgrades a pool whose `_schema` is not current. The function exists
-- only in a session where such a revision loaded (`legacyPools`): elsewhere no
-- pool can carry an older schema and the code is freed after load.
---@type fun(pool: table)|nil
local upgradePool = nil
if rawget(state, "legacyPools") == true then
  -- Revision 1 pools also predate the re-entrancy depth counter and the leak
  -- warning, which revision 2 added to every pool it built but never
  -- back-filled. Those fields are filled only when absent, so a revision 2 or
  -- 3 pool keeps the warning threshold and warned flag it already has. The
  -- defaults reproduce the older behaviour exactly: no caps, no queue, no
  -- children, and the default generation.
  upgradePool = function(pool)
    if rawget(pool, "_callbackDepth") == nil then
      rawset(pool, "_callbackDepth", 0)
    end
    if rawget(pool, "_maxActiveWarning") == nil then
      rawset(pool, "_maxActiveWarning", false)
    end
    if rawget(pool, "_activeWarned") == nil then
      rawset(pool, "_activeWarned", false)
    end
    rawset(pool, "_generation", DEFAULT_GENERATION)
    rawset(pool, "_baseGeneration", DEFAULT_GENERATION)
    rawset(pool, "_stamps", false)
    rawset(pool, "_maxCreated", false)
    rawset(pool, "_maxActive", false)
    rawset(pool, "_maxWaiting", 0)
    rawset(pool, "_waiting", false)
    rawset(pool, "_waitingHead", 1)
    rawset(pool, "_waitingCount", 0)
    rawset(pool, "_parked", false)
    rawset(pool, "_parkedCount", 0)
    rawset(pool, "_children", false)
    rawset(pool, "_attachedTo", false)
    rawset(pool, "_schema", POOL_SCHEMA)
  end
end

---Upgrade `pool` when an older revision built it in an earlier schema.
---@param pool table a table carrying the pool metatable
local function upgradeIfOld(pool)
  if rawget(pool, "_schema") ~= POOL_SCHEMA and upgradePool ~= nil then
    upgradePool(pool)
  end
end

---@param self any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePool(self, methodName, level)
  if type(self) ~= "table" or getmetatable(self) ~= POOL_METATABLE then
    error(methodName .. " must be called on a PoolKit pool", level)
  end
  upgradeIfOld(self)
end

---@param object any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePoolObject(object, label, level)
  local objectType = type(object)
  if objectType ~= "table" and objectType ~= "userdata" then
    error(label .. " must be a table or userdata", level)
  end
end

---@param value any non-negative integer or `PoolKit.UNBOUNDED`
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
---@return integer|table maxRetained
local function validateMaxRetained(value, label, level)
  refuseSecret(value, label, level + 1)
  if value == UNBOUNDED then
    return value
  end
  if not isNonNegativeInteger(value) then
    error(label .. " must be a non-negative integer or PoolKit.UNBOUNDED", level)
  end
  return value
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCount(value, label, level)
  refuseSecret(value, label, level + 1)
  if not isNonNegativeInteger(value) then
    error(label .. " must be a non-negative integer", level)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePositiveInteger(value, label, level)
  refuseSecret(value, label, level + 1)
  if not isPositiveInteger(value) then
    error(label .. " must be a positive integer", level)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param required boolean whether `nil` is rejected
---@param level integer stack level the failure is reported at
local function validateCallback(value, label, required, level)
  if type(value) == "nil" and not required then
    return
  end
  if type(value) ~= "function" then
    error(label .. " must be a function", level)
  end
end

---The message a member of `partName` raises while that part is not loaded.
---@param member string the member as its caller wrote it
---@param partName string
---@return string
local function missingPart(member, partName)
  return member
    .. " is in PoolKit's "
    .. partName
    .. " part, which is not loaded: add "
    .. PART_FILES[partName]
    .. " to embeds.xml after poolKit\\PoolKit.lua"
end

-- Option parsing --------------------------------------------------------------
--
-- Every constructor option, in the order the constructors check them. One
-- walker reads the list; the cross-option checks run after the option they
-- follow, so every refusal keeps its text and its precedence. Each rule is one
-- string, `<name> <kind> [flags]`, read only while a constructor runs, so the
-- list costs one array of strings rather than a table per option:
--   required      `PoolKit:New` refuses the option's absence
--   new           only `PoolKit:New` accepts it, `PoolKit:NewTablePool` does not
--   part=<Part>   the part that must be loaded when the option is given
--   default=<v>   what an absent option reads as: `true`, `false` or a number

local OPTION_RULES = {
  "create callback required new",
  "reset callback new",
  "destroy callback new",
  "strictReset boolean new",
  "maxRetained maxRetained",
  "strict boolean default=true",
  "prewarm count default=0",
  "maxActiveWarning count default=false",
  "generation positive part=Generations",
  "maxCreated positive new default=false",
  "maxActive positive new part=Waiting default=false",
  "maxWaiting count new part=Waiting default=0",
}

---Whether the constructor accepts the option field `key`.
---@param key any a key of the caller's options table
---@param isNew boolean `PoolKit:New` rather than `PoolKit:NewTablePool`
---@return boolean
local function acceptsOption(key, isNew)
  for index = 1, #OPTION_RULES do
    local name, flags = string.match(OPTION_RULES[index], "^(%S+) %S+(.*)$")
    if name == key then
      return isNew or string.find(flags, " new", 1, true) == nil
    end
  end
  return false
end

---Reject the alphabetically first unrecognised option field, if any.
---@param options table
---@param isNew boolean `PoolKit:New` rather than `PoolKit:NewTablePool`
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateKnownFields(options, isNew, methodName, level)
  local firstUnknown = nil
  for key in next, options do
    if not acceptsOption(key, isNew) then
      local text = describeKey(key)
      if firstUnknown == nil or text < firstUnknown then
        firstUnknown = text
      end
    end
  end
  if firstUnknown ~= nil then
    error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
  end
end

---Validate one present option value by its rule's kind.
---@param kind string the rule's kind
---@param value any
---@param label string `<method> <option>`, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOption(kind, value, label, level)
  if kind == "callback" then
    validateCallback(value, label, true, level + 1)
  elseif kind == "boolean" then
    refuseSecret(value, label, level + 1)
    if type(value) ~= "boolean" then
      error(label .. " must be a boolean", level)
    end
  elseif kind == "maxRetained" then
    validateMaxRetained(value, label, level + 1)
  elseif kind == "count" then
    validateCount(value, label, level + 1)
  else
    validatePositiveInteger(value, label, level + 1)
  end
end

---What an absent option reads as, from its rule's `default=` flag.
---@param text string|nil
---@return any
local function readDefault(text)
  if text == "true" then
    return true
  elseif text == "false" then
    return false
  end
  return text and tonumber(text)
end

---Run the checks that relate one option to those before it.
---@param settings table the options read so far
---@param name string the option just read
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
local function checkAfter(settings, name, methodName, level)
  if name == "strictReset" and settings.strictReset == true and type(settings.reset) == "nil" then
    error(methodName .. " strictReset requires a reset callback", level)
  elseif name == "prewarm" then
    local maxRetained = settings.maxRetained
    if maxRetained ~= UNBOUNDED and settings.prewarm > maxRetained then
      error(methodName .. " prewarm cannot exceed maxRetained", level)
    end
  elseif
    name == "maxWaiting"
    and settings.maxWaiting > 0
    and not settings.maxCreated
    and not settings.maxActive
  then
    error(methodName .. " maxWaiting requires maxCreated or maxActive", level)
  end
end

---Validate a constructor's options and return the settings they select.
---@param options any
---@param isNew boolean `PoolKit:New` rather than `PoolKit:NewTablePool`
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return table settings option name to value, defaults applied
local function parseOptions(options, isNew, methodName, level)
  if type(options) == "nil" and not isNew then
    options = {}
  elseif type(options) ~= "table" then
    error(methodName .. " options must be a table", level)
  end

  local settings = {}
  for index = 1, #OPTION_RULES do
    local name, kind, flags = string.match(OPTION_RULES[index], "^(%S+) (%S+)(.*)$")
    if isNew or string.find(flags, " new", 1, true) == nil then
      local value = rawget(options, name)
      local label = methodName .. " " .. name
      if name == "maxRetained" then
        -- The unknown-field refusal comes before every option the table
        -- pool shares, after the callbacks only `New` takes.
        validateKnownFields(options, isNew, methodName, level + 1)
      end
      if type(value) ~= "nil" then
        local part = string.match(flags, " part=(%a+)")
        if part ~= nil and rawget(parts, part) == nil then
          error(missingPart(label, part), level)
        end
        validateOption(kind, value, label, level + 1)
      elseif string.find(flags, " required", 1, true) then
        validateOption(kind, value, label, level + 1)
      elseif name == "maxRetained" then
        -- A capped pool retains everything it may ever create by default:
        -- the objects a cap exists for cannot be freed, so discarding one on
        -- release would only lose it for good.
        local requestedMaxCreated = isNew and rawget(options, "maxCreated") or nil
        value = isPositiveInteger(requestedMaxCreated) and requestedMaxCreated
          or DEFAULT_MAX_RETAINED
      else
        value = readDefault(string.match(flags, " default=(%S+)"))
      end
      settings[name] = value
      checkAfter(settings, name, methodName, level + 1)
    end
  end
  if settings.maxCreated and settings.prewarm > settings.maxCreated then
    error(methodName .. " prewarm cannot exceed maxCreated", level)
  end
  return settings
end

-- Error helpers --------------------------------------------------------------

---Keep the first failure of a best-effort loop, wrapped so `nil` survives.
---@param firstError table|nil
---@param ok boolean
---@param value any
---@return table|nil firstError
local function captureFirstError(firstError, ok, value)
  if not ok and firstError == nil then
    return { value = value }
  end
  return firstError
end

---Re-raise a captured failure unchanged, or return when there was none.
---@param firstError table|nil
local function raiseCaptured(firstError)
  if firstError ~= nil then
    error(firstError.value, 0)
  end
end

-- Diagnostics ----------------------------------------------------------------

---Report a non-fatal diagnostic through the host error handler, best-effort.
---PoolKit is pure Lua, so a host without `geterrorhandler` simply stays silent.
---@param value any
local function reportWarning(value)
  -- geterrorhandler is the World of Warcraft client error sink, published as a global.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) ~= "function" then
    return
  end

  local ok, handler = pcall(getErrorHandler)
  if not ok or type(handler) ~= "function" then
    return
  end
  pcall(handler, value)
end

-- Internal lifecycle ---------------------------------------------------------

---Refuse a mutation attempted from inside one of this pool's own callbacks.
---@param pool PoolKit.Pool
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function ensureMutationAllowed(pool, methodName, level)
  if rawget(pool, "_callbackDepth") > 0 then
    error(
      methodName
        .. " cannot mutate this pool during its "
        .. rawget(pool, "_callbackPhase")
        .. " callback",
      level
    )
  end
end

-- The guard is a depth counter rather than a flag, and the previous phase name
-- is restored rather than cleared. A nested lifecycle callback on the same pool
-- therefore cannot hand the outer callback a pool that looks unguarded, and the
-- rejection message keeps naming the phase the caller is actually inside.
---Run one user lifecycle callback with the re-entrancy guard raised.
---@param pool PoolKit.Pool
---@param phase "create"|"reset"|"destroy"
---@param callback function
---@param ... any arguments forwarded to `callback`
---@return any result
local function invokeLifecycleCallback(pool, phase, callback, ...)
  local depth = rawget(pool, "_callbackDepth") + 1
  local previousPhase = rawget(pool, "_callbackPhase")
  rawset(pool, "_callbackDepth", depth)
  rawset(pool, "_callbackPhase", phase)

  local ok, value = pcall(callback, ...)

  rawset(pool, "_callbackDepth", depth - 1)
  rawset(pool, "_callbackPhase", previousPhase)
  if not ok then
    error(value, 0)
  end
  return value
end

---Record that `object` has left this pool's ownership.
---@param pool PoolKit.Pool
---@param object table|userdata
local function markDiscarded(pool, object)
  local released = rawget(pool, "_released")
  if released then
    rawset(released, object, true)
  end
  rawset(pool, "_discardedCount", rawget(pool, "_discardedCount") + 1)
end

---Mark `object` discarded and run the pool's `destroy` callback for it.
---@param pool PoolKit.Pool
---@param object table|userdata
local function destroyDiscarded(pool, object)
  markDiscarded(pool, object)
  local destroy = rawget(pool, "_destroy")
  if destroy then
    invokeLifecycleCallback(pool, "destroy", destroy, object, pool)
  end
end

---Reject a factory result this pool already owns or cannot pool at all.
---@param pool PoolKit.Pool
---@param object any
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateFactoryObject(pool, object, methodName, level)
  validatePoolObject(object, methodName .. " factory result", nestedLevel(level))

  local active = rawget(pool, "_active")
  local retained = rawget(pool, "_retained")
  if rawget(active, object) ~= nil or rawget(retained, object) == true then
    error(methodName .. " factory returned an object already owned by this pool", level)
  end

  local released = rawget(pool, "_released")
  if released then
    rawset(released, object, nil)
  end
end

-- Parts ---------------------------------------------------------------------
--
-- A part records itself in `_state.parts.<Part>` with its revision, the
-- `PoolKit.Pool` methods it provides and the hooks the core calls, and reads
-- the core's helpers from `_state.helpers` at call time. A pool reaches a
-- mechanism's state only through its part, so the core asks for the part only
-- once a pool is in that state.
--
-- Pools revisions 11 and older built may already be in such a state in a
-- session without the part (`_state.fullPools`). For those this core carries
-- a fallback per mechanism, reported once per part through the host error
-- handler, that takes the safe exact path: a queue's requests fail with
-- `"closed"`, a parked object is released at once, children are detached
-- without cascading, and no stale object is retained. The fallbacks are
-- built only in such a session (`Older pools' mechanisms` below).

---@type table<string, table>|nil
local fallbackMechanisms = nil

---The hooks of `partName`: the loaded part, or the fallback for a pool an
---older revision built.
---@param partName string
---@return table hooks
local function mechanism(partName)
  local part = rawget(parts, partName)
  if part ~= nil then
    return part
  end
  if fallbackMechanisms == nil then
    -- No pool this core built can be in a part's state without the part.
    error(missingPart("PoolKit", partName), 3)
  end
  fallbackMechanisms.report(partName)
  return fallbackMechanisms[partName]
end

---A `PoolKit.Pool` method that raises at its caller, naming the part to embed.
---@param methodName string a key of `PART_METHODS`
---@return function
local function newPartStub(methodName)
  return function()
    error(missingPart("PoolKit.Pool:" .. methodName, PART_METHODS[methodName]), 2)
  end
end

-- Capacity ------------------------------------------------------------------

---Build one new object through the pool's factory and count it.
---
---An object built while the pool's generation differs from the generation the
---pool was created with is stamped by the Generations part; a pool that never
---changes its generation therefore writes no stamps at all.
---@param pool PoolKit.Pool
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table|userdata object
local function createObject(pool, methodName, level)
  local create = rawget(pool, "_create")
  local object
  if rawget(pool, "_trustedCallbacks") == true then
    object = create(pool)
  else
    object = invokeLifecycleCallback(pool, "create", create, pool)
  end
  validateFactoryObject(pool, object, methodName, nestedLevel(level))
  rawset(pool, "_createdCount", rawget(pool, "_createdCount") + 1)

  if rawget(pool, "_generation") ~= rawget(pool, "_baseGeneration") then
    mechanism("Generations").stamp(pool, object)
  end
  return object
end

---Drop one retained object, reporting a failing `destroy` to the caller.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean ok
---@return any errorValue
local function discardAvailableObject(pool, object)
  local retained = rawget(pool, "_retained")
  rawset(retained, object, nil)
  return pcall(destroyDiscarded, pool, object)
end

---Reduce retention to `retainCount` objects, destroying the rest.
---@param pool PoolKit.Pool
---@param retainCount integer
---@return integer removed
local function trimTo(pool, retainCount)
  local available = rawget(pool, "_available")
  local count = rawget(pool, "_availableCount")
  if retainCount >= count then
    return 0
  end

  -- Detach the complete trim snapshot before invoking user destroy callbacks.
  -- A destroy callback may legally interact with the pool again; publishing
  -- the final available count first prevents re-entrant operations from
  -- observing a half-mutated stack or being overwritten by this trim pass.
  local removed = count - retainCount
  local discarded = {}
  local discardedIndex = 0
  while count > retainCount do
    discardedIndex = discardedIndex + 1
    discarded[discardedIndex] = rawget(available, count)
    rawset(available, count, nil)
    count = count - 1
  end
  rawset(pool, "_availableCount", count)

  local firstError = nil
  for index = 1, discardedIndex do
    local ok, value = discardAvailableObject(pool, discarded[index])
    firstError = captureFirstError(firstError, ok, value)
  end

  raiseCaptured(firstError)
  return removed
end

---Create objects until `targetCount` of them are immediately available.
---@param pool PoolKit.Pool
---@param targetCount integer
---@param level integer stack level failures are reported at; `0` for construction
---@return integer created
local function prewarmInternal(pool, targetCount, level)
  if rawget(pool, "_closed") == true then
    error("PoolKit.Pool:Prewarm cannot use a closed pool", level)
  end

  local maxRetained = rawget(pool, "_maxRetained")
  if maxRetained ~= UNBOUNDED and targetCount > maxRetained then
    error("PoolKit.Pool:Prewarm target cannot exceed maxRetained", level)
  end

  local available = rawget(pool, "_available")
  local retained = rawget(pool, "_retained")
  local count = rawget(pool, "_availableCount")

  local maxCreated = rawget(pool, "_maxCreated")
  if
    maxCreated
    and targetCount > count
    and rawget(pool, "_createdCount") + (targetCount - count) > maxCreated
  then
    error("PoolKit.Pool:Prewarm target cannot exceed maxCreated", level)
  end

  local created = 0

  -- The count is written with each object, not after the loop: a factory that
  -- raises partway leaves the objects already built on the free list, where
  -- the next `Acquire` finds them, instead of stranding them counted against
  -- `maxCreated`.
  while count < targetCount do
    local object = createObject(pool, "PoolKit.Pool:Prewarm", nestedLevel(level))
    count = count + 1
    created = created + 1
    rawset(available, count, object)
    rawset(retained, object, true)
    rawset(pool, "_availableCount", count)
  end

  return created
end

---Whether the pool may hand out one more object right now. A live limit
---(`maxActive`, the Waiting part's) counts parked objects too.
---@param pool PoolKit.Pool
---@return boolean
local function hasCapacity(pool)
  local maxActive = rawget(pool, "_maxActive")
  if
    maxActive
    and rawget(pool, "_activeCount") + (rawget(pool, "_parkedCount") or 0) >= maxActive
  then
    return false
  end
  if rawget(pool, "_availableCount") > 0 then
    return true
  end
  local maxCreated = rawget(pool, "_maxCreated")
  return not maxCreated or rawget(pool, "_createdCount") < maxCreated
end

---Take the newest retained object, or build one through the factory.
---@param pool PoolKit.Pool
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
---@return table|userdata object
local function takeObject(pool, methodName, level)
  local count = rawget(pool, "_availableCount")
  if count > 0 then
    local available = rawget(pool, "_available")
    local object = rawget(available, count)
    rawset(available, count, nil)
    rawset(pool, "_availableCount", count - 1)
    rawset(rawget(pool, "_retained"), object, nil)
    return object
  end
  return createObject(pool, methodName, nestedLevel(level))
end

---Report a leak threshold once. Kept out of `markActive` so the disabled
---default costs one comparison and no extra frame on the hot path.
---@param pool PoolKit.Pool
---@param activeCount integer
local function warnActiveThreshold(pool, activeCount)
  rawset(pool, "_activeWarned", true)
  reportWarning(
    "PoolKit pool has "
      .. tostring(activeCount)
      .. " objects borrowed at once, at or above its maxActiveWarning threshold of "
      .. tostring(rawget(pool, "_maxActiveWarning"))
      .. ". Active objects are caller-owned and unbounded: PoolKit cannot"
      .. " reclaim one that is never released. This is reported once per pool."
  )
end

---Record `object` as borrowed.
---@param pool PoolKit.Pool
---@param object table|userdata
local function markActive(pool, object)
  local released = rawget(pool, "_released")
  if released then
    rawset(released, object, nil)
  end

  rawset(rawget(pool, "_active"), object, ACTIVE)
  local activeCount = rawget(pool, "_activeCount") + 1
  rawset(pool, "_activeCount", activeCount)

  local warnAt = rawget(pool, "_maxActiveWarning")
  if warnAt and activeCount >= warnAt and rawget(pool, "_activeWarned") ~= true then
    warnActiveThreshold(pool, activeCount)
  end
end

-- Release transaction ---------------------------------------------------------

---Release one borrowed object: cascade to its children, reset it, then retain
---it or retire it, and finally hand freed capacity to waiting requests.
---
---The caller has validated the pool and that `object` is `ACTIVE`.
---
---This is the hot half of every `Release`, so pool fields and the pool's own
---maps are read and written by plain indexing rather than `rawget`/`rawset`.
---That is the same operation here: the pool metatable has no `__newindex` and
---its `__index` is the `PoolKit.Pool` prototype, which holds no field starting
---with `_`, so an absent field of a sparse pool reads `nil`; the maps have no
---metatable and `_released` has only `__mode`. A plain index is a VM
---instruction; `rawget` is a C call, which dominated this path. Each part's
---mechanism costs one truthiness test here and a call only when it is in use.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean released
local function releaseActive(pool, object)
  local active = pool._active
  active[object] = RELEASING

  local firstError = nil
  if pool._children then
    firstError = mechanism("Children").releaseChildren(pool, object)
  end

  local reset = pool._reset
  if reset then
    if pool._trustedCallbacks == true then
      reset(object, pool)
    else
      -- The re-entrancy guard of `invokeLifecycleCallback`, inlined so one
      -- protected call covers both the guard and the rollback below.
      local depth = pool._callbackDepth + 1
      local previousPhase = pool._callbackPhase
      pool._callbackDepth = depth
      pool._callbackPhase = "reset"
      local ok, value = pcall(reset, object, pool)
      pool._callbackDepth = depth - 1
      pool._callbackPhase = previousPhase
      if not ok then
        active[object] = ACTIVE
        -- First error wins: a child that failed before this reset ran
        -- is the error the caller hears about.
        firstError = captureFirstError(firstError, false, value)
        raiseCaptured(firstError)
      end
    end
  end

  if pool._attachedTo then
    mechanism("Children").detachFromParent(pool, object)
  end
  active[object] = nil
  pool._activeCount = pool._activeCount - 1

  local count = pool._availableCount
  local maxRetained = pool._maxRetained
  if
    pool._closed ~= true
    and (maxRetained == UNBOUNDED or count < maxRetained)
    and (
      pool._generation == pool._baseGeneration
      or not mechanism("Generations").isStale(pool, object)
    )
  then
    count = count + 1
    pool._available[count] = object
    pool._retained[object] = true
    pool._availableCount = count
  else
    local ok, value = pcall(destroyDiscarded, pool, object)
    firstError = captureFirstError(firstError, ok, value)
  end

  local waitingCount = pool._waitingCount
  if waitingCount and waitingCount > 0 then
    mechanism("Waiting").drain(pool)
  end

  if firstError ~= nil then
    raiseCaptured(firstError)
  end
  return true
end

---Complete the deferred release of a parked object now (Deferred part).
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean released
local function finalizeParked(pool, object)
  return mechanism("Deferred").finalizeParked(pool, object)
end

---Raise the error that explains why `object` cannot be released.
---@param pool PoolKit.Pool
---@param object table|userdata
---@param status integer|nil the object's `_active` marker
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function raiseNotReleasable(pool, object, status, methodName, level)
  if status == RELEASING then
    error(methodName .. " release is already in progress for this object", level)
  end
  if status == PARKED then
    error(methodName .. " release is already pending for this object", level)
  end
  if rawget(rawget(pool, "_retained"), object) == true then
    error(methodName .. " object has already been released", level)
  end
  local released = rawget(pool, "_released")
  if released and rawget(released, object) == true then
    error(methodName .. " object has already been released", level)
  end
  error(methodName .. " object was not acquired from this pool", level)
end

-- Construction ------------------------------------------------------------------

---Construct one pool from parsed settings and, when asked, prewarm it before
---it escapes. The pool carries only the fields in use: the twelve every pool
---needs fit one 16-slot hash part with the optional ones, and a part's fields
---appear only when its `configure` hook sets them.
---@param settings table what `parseOptions` returned, plus `trustedCallbacks`
---@return PoolKit.Pool
local function newPool(settings)
  local pool = setmetatable({
    _schema = POOL_SCHEMA,
    _create = settings.create,
    _maxRetained = settings.maxRetained,
    _available = {},
    _availableCount = 0,
    _active = {},
    _activeCount = 0,
    _retained = {},
    _createdCount = 0,
    _discardedCount = 0,
    _callbackPhase = false,
    _callbackDepth = 0,
  }, POOL_METATABLE)
  if settings.reset ~= nil then
    pool._reset = settings.reset
  end
  if settings.destroy ~= nil then
    pool._destroy = settings.destroy
  end
  if settings.strict then
    pool._released = setmetatable({}, RELEASED_METATABLE)
  end
  if settings.maxActiveWarning then
    pool._maxActiveWarning = settings.maxActiveWarning
  end
  if settings.trustedCallbacks then
    pool._trustedCallbacks = true
  end
  if settings.maxCreated then
    pool._maxCreated = settings.maxCreated
  end
  if settings.generation ~= nil then
    rawget(parts, "Generations").configure(pool, settings.generation)
  end
  if settings.maxActive or (settings.maxWaiting or 0) > 0 then
    rawget(parts, "Waiting").configure(pool, settings.maxActive, settings.maxWaiting)
  end

  if settings.prewarm > 0 then
    -- The failure is re-raised verbatim below, so level 0 keeps a
    -- meaningless position computed across this `pcall` out of the message.
    local ok, value = pcall(prewarmInternal, pool, settings.prewarm, 0)
    if not ok then
      -- Construction failed and the pool will not escape. Drop any
      -- successfully prewarmed objects best-effort before rethrowing the
      -- original construction failure.
      pcall(trimTo, pool, 0)
      error(value, 0)
    end
  end

  return pool
end

-- Pool methods ---------------------------------------------------------------

---Borrow one object, reusing the most recently retained object when available.
---
---Without a creation cap or live limit this always returns an object. At
---capacity it returns `nil` and a reason instead: `"exhausted"` when no
---`onAvailable` callback was given, `"waiting"` when the request was queued, and
---`"queueFull"` when the bounded queue had no room and the request was refused.
---A pool without the Waiting part has no queue, so `onAvailable` at capacity
---answers `"queueFull"`.
---@param self PoolKit.Pool
---@param onAvailable PoolKit.WaitCallback? called with the object once one frees
---@return table|userdata|nil object
---@return PoolKit.AcquireReason? reason why no object was returned
local function poolAcquire(self, onAvailable)
  -- Fast path: a current, open, unguarded pool with no live limit, nobody
  -- waiting, a retained object to hand out and no `onAvailable`. Every check
  -- the general path below makes is made here too, in the same order of
  -- outcome, by plain indexing (see `releaseActive` for why that is the same
  -- operation on a pool); anything unusual falls through to the general path.
  if
    type(self) == "table"
    and getmetatable(self) == POOL_METATABLE
    and self._schema == POOL_SCHEMA
    and self._callbackDepth == 0
    and self._closed ~= true
    and type(onAvailable) == "nil"
    and not self._maxActive
  then
    local waitingCount = self._waitingCount
    local count = self._availableCount
    if count > 0 and (waitingCount == nil or waitingCount == 0) then
      local available = self._available
      local object = available[count]
      available[count] = nil
      self._availableCount = count - 1
      self._retained[object] = nil
      -- A retained object is never in `_released`: an object is marked
      -- there only as it leaves the pool, and a factory result or a newly
      -- borrowed object is unmarked, so `markActive`'s unmarking is skipped.
      self._active[object] = ACTIVE
      local activeCount = self._activeCount + 1
      self._activeCount = activeCount
      local warnAt = self._maxActiveWarning
      if warnAt and activeCount >= warnAt and self._activeWarned ~= true then
        warnActiveThreshold(self, activeCount)
      end
      return object
    end
  end

  validatePool(self, "PoolKit.Pool:Acquire", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Acquire", 3)
  if rawget(self, "_closed") == true then
    error("PoolKit.Pool:Acquire cannot use a closed pool", 2)
  end
  local onAvailableType = type(onAvailable)
  if onAvailableType ~= "nil" and onAvailableType ~= "function" then
    error("PoolKit.Pool:Acquire onAvailable must be a function", 2)
  end

  -- Requests already waiting are served first, so a new caller never jumps
  -- the queue; normally the queue is empty and this is one comparison.
  local waitingCount = rawget(self, "_waitingCount")
  if waitingCount and waitingCount > 0 then
    mechanism("Waiting").drain(self)
    waitingCount = rawget(self, "_waitingCount")
  end
  waitingCount = waitingCount or 0

  if waitingCount > 0 or not hasCapacity(self) then
    if onAvailableType == "nil" then
      return nil, REASON_EXHAUSTED
    end
    if
      waitingCount >= (rawget(self, "_maxWaiting") or 0)
      or mechanism("Waiting").enqueue(self, onAvailable) == false
    then
      return nil, REASON_QUEUE_FULL
    end
    return nil, REASON_WAITING
  end

  local object = takeObject(self, "PoolKit.Pool:Acquire", 3)
  markActive(self, object)
  return object
end

---Reset and return an active object; discard it when retention is full, the
---pool is closed, or a newer generation superseded it. Children attached to it
---are released first. A parked object's pending release completes now.
---@param self PoolKit.Pool
---@param object table|userdata
---@return boolean released
local function poolRelease(self, object)
  -- Fast path: a current, unguarded pool releasing a borrowed object. The
  -- general path below makes the same checks through its helpers.
  if
    type(self) == "table"
    and getmetatable(self) == POOL_METATABLE
    and self._schema == POOL_SCHEMA
    and self._callbackDepth == 0
  then
    local objectType = type(object)
    if (objectType == "table" or objectType == "userdata") and self._active[object] == ACTIVE then
      local released = releaseActive(self, object)
      return released
    end
  end

  validatePool(self, "PoolKit.Pool:Release", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Release", 3)
  validatePoolObject(object, "PoolKit.Pool:Release object", 3)

  local status = rawget(rawget(self, "_active"), object)
  if status == PARKED then
    local completed = finalizeParked(self, object)
    return completed
  end
  if status ~= ACTIVE then
    raiseNotReleasable(self, object, status, "PoolKit.Pool:Release", 3)
  end

  local released = releaseActive(self, object)
  return released
end

---Ensure at least `count` objects are immediately available.
---@param self PoolKit.Pool
---@param count integer
---@return integer created
local function poolPrewarm(self, count)
  validatePool(self, "PoolKit.Pool:Prewarm", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Prewarm", 3)
  validateCount(count, "PoolKit.Pool:Prewarm count", 3)
  return prewarmInternal(self, count, 3)
end

---Reduce retention to `retainCount` objects, or to none by default.
---@param self PoolKit.Pool
---@param retainCount integer? defaults to `0`
---@return integer removed
local function poolTrim(self, retainCount)
  validatePool(self, "PoolKit.Pool:Trim", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Trim", 3)
  if type(retainCount) == "nil" then
    retainCount = 0
  else
    validateCount(retainCount, "PoolKit.Pool:Trim retainCount", 3)
  end
  return trimTo(self, retainCount)
end

---Destroy every retained object while keeping the pool usable.
---@param self PoolKit.Pool
---@return integer removed
local function poolClear(self)
  validatePool(self, "PoolKit.Pool:Clear", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Clear", 3)
  return trimTo(self, 0)
end

---Terminally close the pool: fail waiting requests, complete parked releases,
---and destroy everything it retains.
---@param self PoolKit.Pool
---@return boolean closed `false` when the pool was already closed.
local function poolClose(self)
  validatePool(self, "PoolKit.Pool:Close", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:Close", 3)
  if rawget(self, "_closed") == true then
    return false
  end
  rawset(self, "_closed", true)

  local waitingCount = rawget(self, "_waitingCount")
  if waitingCount and waitingCount > 0 then
    mechanism("Waiting").fail(self)
  end
  local firstError = nil
  local parkedCount = rawget(self, "_parkedCount")
  if parkedCount and parkedCount > 0 then
    firstError = mechanism("Deferred").finalizeAllParked(self)
  end
  local ok, value = pcall(trimTo, self, 0)
  firstError = captureFirstError(firstError, ok, value)

  raiseCaptured(firstError)
  return true
end

---Build a getter: validate the receiver at the caller's level, then return
---one field, or `default` when a sparse pool does not carry it. The getters of
---a part answer the part's neutral value when the part was never used.
---@param methodName string the `PoolKit.Pool` method, for the argument error
---@param field string the pool field
---@param default any the value an absent field reads as
---@return function
local function newGetter(methodName, field, default)
  local label = "PoolKit.Pool:" .. methodName
  return function(self)
    validatePool(self, label, 3)
    local value = rawget(self, field)
    if value == nil then
      return default
    end
    return value
  end
end

---Change the retention bound, trimming immediately when it shrinks.
---@param self PoolKit.Pool
---@param maxRetained integer|table non-negative integer or `PoolKit.UNBOUNDED`
---@return PoolKit.Pool self
local function poolSetMaxRetained(self, maxRetained)
  validatePool(self, "PoolKit.Pool:SetMaxRetained", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:SetMaxRetained", 3)
  maxRetained = validateMaxRetained(maxRetained, "PoolKit.Pool:SetMaxRetained maxRetained", 3)
  rawset(self, "_maxRetained", maxRetained)
  if maxRetained ~= UNBOUNDED then
    -- `UNBOUNDED` is the only non-integer `validateMaxRetained` accepts.
    ---@cast maxRetained integer
    trimTo(self, maxRetained)
  end
  return self
end

---Whether `object` is borrowed from, parked in, or retained by this pool.
---@param self PoolKit.Pool
---@param object any
---@return boolean owned
local function poolOwns(self, object)
  validatePool(self, "PoolKit.Pool:Owns", 3)
  local objectType = type(object)
  if objectType ~= "table" and objectType ~= "userdata" then
    return false
  end
  return rawget(rawget(self, "_active"), object) ~= nil
    or rawget(rawget(self, "_retained"), object) == true
end

---Whether `object` is currently borrowed from this pool. Parked objects are not.
---@param self PoolKit.Pool
---@param object any
---@return boolean active
local function poolIsActive(self, object)
  validatePool(self, "PoolKit.Pool:IsActive", 3)
  local objectType = type(object)
  if objectType ~= "table" and objectType ~= "userdata" then
    return false
  end
  local status = rawget(rawget(self, "_active"), object)
  return status == ACTIVE or status == RELEASING
end

---Raise the creation cap. Destroyed objects keep counting against the cap, so
---this is how a pool whose stale objects were retired by `SetGeneration` gets
---room to build their replacements. A retention bound that equalled the old
---cap, as it does by default, follows it up. Waiting requests are served from
---the new room at once.
---@param self PoolKit.Pool
---@param maxCreated integer positive integer no lower than the current cap
---@return PoolKit.Pool self
local function poolSetMaxCreated(self, maxCreated)
  validatePool(self, "PoolKit.Pool:SetMaxCreated", 3)
  ensureMutationAllowed(self, "PoolKit.Pool:SetMaxCreated", 3)
  validatePositiveInteger(maxCreated, "PoolKit.Pool:SetMaxCreated maxCreated", 3)

  local current = rawget(self, "_maxCreated")
  if not current then
    error("PoolKit.Pool:SetMaxCreated cannot cap a pool that was built without maxCreated", 2)
  end
  if maxCreated < current then
    error(
      "PoolKit.Pool:SetMaxCreated cannot lower the cap from "
        .. tostring(current)
        .. " to "
        .. tostring(maxCreated),
      2
    )
  end

  rawset(self, "_maxCreated", maxCreated)
  if rawget(self, "_maxRetained") == current then
    rawset(self, "_maxRetained", maxCreated)
  end
  local waitingCount = rawget(self, "_waitingCount")
  if waitingCount and waitingCount > 0 and rawget(self, "_closed") ~= true then
    mechanism("Waiting").drain(self)
  end
  return self
end

-- Package constructors -------------------------------------------------------

---Create a generic object pool.
---@param self PoolKit
---@param options PoolKit.NewOptions
---@return PoolKit.Pool pool
local function packageNew(self, options)
  validateFacade(self, "PoolKit:New", 3)
  local settings = parseOptions(options, true, "PoolKit:New", 3)
  return newPool(settings)
end

---Factory for `PoolKit:NewTablePool`.
---@return table
local function tableCreate()
  return {}
end

---Shallow-clearing reset for `PoolKit:NewTablePool`.
---
---A plain assignment rather than `rawset`: every key `next` returns holds a
---non-`nil` value, and assigning to a key that is present never consults a
---metatable, so the two are the same operation and the assignment is a VM
---instruction instead of a C call per field. Assigning `nil` to a field
---already visited is legal during `next` traversal.
---@param object table
local function tableReset(object)
  for key in next, object do
    object[key] = nil
  end
end

---Create a shallow-clearing Lua table pool.
---@param self PoolKit
---@param options PoolKit.CommonOptions?
---@return PoolKit.Pool pool
local function packageNewTablePool(self, options)
  validateFacade(self, "PoolKit:NewTablePool", 3)
  local settings = parseOptions(options, false, "PoolKit:NewTablePool", 3)
  settings.create = tableCreate
  settings.reset = tableReset
  settings.trustedCallbacks = true
  return newPool(settings)
end

---Whether the named part is loaded in this session: `"Waiting"`, `"Children"`,
---`"Deferred"` or `"Generations"`. Code that uses a part only when it is there
---asks this, never whether the method is a function: the prototype keeps every
---method, raising when its part is absent.
---@param self PoolKit
---@param name string
---@return boolean
local function packageHasPart(self, name)
  validateFacade(self, "PoolKit:HasPart", 3)
  refuseSecret(name, "PoolKit:HasPart name", 3)
  if type(name) ~= "string" then
    error("PoolKit:HasPart name must be a string", 2)
  end
  return type(rawget(parts, name)) == "table"
end

-- Older pools' mechanisms ------------------------------------------------------
--
-- Built only in a session where a revision 11 or older loaded (`fullPools`):
-- its pools may hold a mechanism's state with that mechanism's part absent.
-- Elsewhere this block never runs and its code is freed after load.

if rawget(state, "fullPools") == true then
  local reported = {}

  ---Tell the host once per part that a pool needs it.
  ---@param partName string
  local function reportMissingPart(partName)
    if reported[partName] then
      return
    end
    reported[partName] = true
    reportWarning(
      missingPart("A pool an older PoolKit revision built uses a mechanism that", partName)
        .. "; PoolKit takes the safe path without it"
    )
  end

  ---Fail every waiting request of `pool` with `"closed"`, oldest first.
  ---@param pool table
  local function failEveryWaiter(pool)
    local waiting = rawget(pool, "_waiting")
    local capacity = rawget(pool, "_maxWaiting")
    while rawget(pool, "_waitingCount") > 0 do
      local head = rawget(pool, "_waitingHead")
      local callback = rawget(waiting, head)
      rawset(waiting, head, false)
      rawset(pool, "_waitingHead", head % capacity + 1)
      rawset(pool, "_waitingCount", rawget(pool, "_waitingCount") - 1)
      local ok, failure = pcall(callback, nil, pool, REASON_CLOSED)
      if not ok then
        reportWarning(failure)
      end
    end
  end

  ---Release a parked object at once.
  ---@param pool table
  ---@param object table|userdata
  ---@return boolean released
  local function releaseParkedNow(pool, object)
    local parked = rawget(pool, "_parked")
    local group = rawget(parked, object)
    rawset(parked, object, nil)
    if group ~= nil then
      rawset(rawget(state, "deferredPool"), group, nil)
      rawset(rawget(state, "deferredObject"), group, nil)
    end
    rawset(rawget(pool, "_active"), object, ACTIVE)
    rawset(pool, "_parkedCount", rawget(pool, "_parkedCount") - 1)
    rawset(pool, "_activeCount", rawget(pool, "_activeCount") + 1)
    return releaseActive(pool, object)
  end

  ---Take `child` out of its parent's list in `parentPool`. Never raises.
  ---@param parentPool table
  ---@param child table|userdata
  local function unlinkChild(parentPool, child)
    local links = rawget(parentPool, "_children")
    local parent = rawget(links.parent, child)
    local previous = rawget(links.previousSibling, child)
    local following = rawget(links.nextSibling, child)
    if previous == false then
      rawset(links.first, parent, following or nil)
    else
      rawset(links.nextSibling, previous, following)
    end
    if following ~= false then
      rawset(links.previousSibling, following, previous)
    end
    rawset(rawget(rawget(links.childPool, child), "_attachedTo"), child, nil)
    rawset(links.nextSibling, child, nil)
    rawset(links.previousSibling, child, nil)
    rawset(links.childPool, child, nil)
    rawset(links.parent, child, nil)
  end

  fallbackMechanisms = {
    report = reportMissingPart,
    Waiting = {
      drain = failEveryWaiter,
      fail = failEveryWaiter,
      -- No queue without the part: a new request is refused as `"queueFull"`.
      enqueue = function()
        return false
      end,
    },
    Deferred = {
      finalizeParked = releaseParkedNow,
      finalizeAllParked = function(pool)
        local parked = rawget(pool, "_parked")
        local firstError = nil
        local object = next(parked)
        while object ~= nil do
          local ok, value = pcall(releaseParkedNow, pool, object)
          firstError = captureFirstError(firstError, ok, value)
          rawset(parked, object, nil)
          object = next(parked)
        end
        return firstError
      end,
      -- An animation an older revision hooked finishes: release at once.
      animationFinished = function(group)
        local pool = rawget(rawget(state, "deferredPool"), group)
        if pool == nil then
          return
        end
        reportMissingPart("Deferred")
        local ok, value =
          pcall(releaseParkedNow, pool, rawget(rawget(state, "deferredObject"), group))
        if not ok then
          reportWarning(value)
        end
      end,
    },
    Children = {
      -- Detach every child without releasing it.
      releaseChildren = function(pool, parent)
        local links = rawget(pool, "_children")
        local child = rawget(links.first, parent)
        while child ~= nil do
          unlinkChild(pool, child)
          child = rawget(links.first, parent)
        end
        return nil
      end,
      detachFromParent = function(pool, object)
        local parentPool = rawget(rawget(pool, "_attachedTo"), object)
        if parentPool ~= nil then
          unlinkChild(parentPool, object)
        end
      end,
    },
    Generations = {
      -- A revision 11 pool keeps its stamps, so staleness stays exact.
      isStale = function(pool, object)
        local stamps = rawget(pool, "_stamps")
        local stamp = stamps and rawget(stamps, object) or rawget(pool, "_baseGeneration")
        return stamp < rawget(pool, "_generation")
      end,
      -- Unstamped, an object counts as the base generation: it is stale, so
      -- it is destroyed on release rather than retained.
      stamp = function() end,
    },
  }
end

-- Commit --------------------------------------------------------------------

rawset(Pool, "Acquire", poolAcquire)
rawset(Pool, "Release", poolRelease)
rawset(Pool, "Prewarm", poolPrewarm)
rawset(Pool, "Trim", poolTrim)
rawset(Pool, "Clear", poolClear)
rawset(Pool, "Close", poolClose)
rawset(Pool, "IsClosed", newGetter("IsClosed", "_closed", false))
rawset(Pool, "GetAvailableCount", newGetter("GetAvailableCount", "_availableCount", 0))
rawset(Pool, "GetActiveCount", newGetter("GetActiveCount", "_activeCount", 0))
rawset(Pool, "GetCreatedCount", newGetter("GetCreatedCount", "_createdCount", 0))
rawset(Pool, "GetDiscardedCount", newGetter("GetDiscardedCount", "_discardedCount", 0))
rawset(Pool, "GetMaxRetained", newGetter("GetMaxRetained", "_maxRetained", DEFAULT_MAX_RETAINED))
rawset(Pool, "SetMaxRetained", poolSetMaxRetained)
rawset(Pool, "Owns", poolOwns)
rawset(Pool, "IsActive", poolIsActive)
rawset(Pool, "GetGeneration", newGetter("GetGeneration", "_generation", DEFAULT_GENERATION))
rawset(Pool, "GetWaitingCount", newGetter("GetWaitingCount", "_waitingCount", 0))
rawset(Pool, "GetParkedCount", newGetter("GetParkedCount", "_parkedCount", 0))
rawset(Pool, "GetMaxCreated", newGetter("GetMaxCreated", "_maxCreated", false))
rawset(Pool, "SetMaxCreated", poolSetMaxCreated)
for methodName in next, PART_METHODS do
  rawset(Pool, methodName, newPartStub(methodName))
end

-- A part loaded before this core keeps serving: its methods replace the stubs.
for _, part in next, parts do
  local methods = type(part) == "table" and rawget(part, "methods") or nil
  if type(methods) == "table" then
    for methodName, method in next, methods do
      rawset(Pool, methodName, method)
    end
  end
end

rawset(PoolKit, "API", API_GENERATION)
rawset(PoolKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(PoolKit, "Pool", Pool)
rawset(PoolKit, "UNBOUNDED", UNBOUNDED)
rawset(PoolKit, "DEFAULT_MAX_RETAINED", DEFAULT_MAX_RETAINED)
rawset(PoolKit, "New", packageNew)
rawset(PoolKit, "NewTablePool", packageNewTablePool)
rawset(PoolKit, "HasPart", packageHasPart)

-- What the parts call, refilled by every core revision so a part loaded
-- before an upgrade is served by the newer core. Parts read it at call time.
do
  local helpers = rawget(state, "helpers")
  rawset(helpers, "validatePool", validatePool)
  rawset(helpers, "upgradeIfOld", upgradeIfOld)
  rawset(helpers, "ensureMutationAllowed", ensureMutationAllowed)
  rawset(helpers, "validatePoolObject", validatePoolObject)
  rawset(helpers, "validatePositiveInteger", validatePositiveInteger)
  rawset(helpers, "validateCallback", validateCallback)
  rawset(helpers, "raiseNotReleasable", raiseNotReleasable)
  rawset(helpers, "releaseActive", releaseActive)
  rawset(helpers, "finalizeParked", finalizeParked)
  rawset(helpers, "hasCapacity", hasCapacity)
  rawset(helpers, "takeObject", takeObject)
  rawset(helpers, "markActive", markActive)
  rawset(helpers, "discardAvailableObject", discardAvailableObject)
  rawset(helpers, "captureFirstError", captureFirstError)
  rawset(helpers, "raiseCaptured", raiseCaptured)
  rawset(helpers, "reportWarning", reportWarning)
end

-- Host animation hooks call through `dispatch`: the Deferred part's completion
-- when it is loaded, otherwise the fallback for groups an older revision
-- hooked (no hook exists in a session without either).
do
  local deferred = rawget(parts, "Deferred")
  local finished = deferred and rawget(deferred, "animationFinished")
  if finished == nil and fallbackMechanisms ~= nil then
    finished = fallbackMechanisms.Deferred.animationFinished
  end
  rawset(rawget(state, "dispatch"), "animationFinished", finished)
end

if not validatePublicSurface(PoolKit) or not validateCurrentState(PoolKit) then
  error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
end

return PoolKit
