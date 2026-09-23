-- MoltenCodes PoolKit
--
-- Allocation-conscious reusable object pools for World of Warcraft addons.
-- PoolKit is pure Lua: it owns object lifecycle and retention policy without
-- depending on Frames, timers, or other WoW APIs.
--
-- Beyond plain reuse, a pool can serve objects the host can never free, such
-- as Frames: a creation cap, a live limit with a bounded waiting queue,
-- cascading release of attached children, and release deferred until an
-- animation finishes. Every pool also carries a generation, so objects built
-- by a superseded factory are retired instead of reused after an upgrade.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, status markers, reasons
--   Public types .......... LuaCATS declarations for the published surface
--   Dependencies .......... Registry
--   Bootstrap ............. surface/state validation, registration, migration
--   Validation ............ argument checks and lazy pool upgrade
--   Option parsing ........ constructor options and their defaults
--   Error helpers ......... best-effort error capture
--   Diagnostics ........... host error-handler reporting
--   Internal lifecycle .... callback guard, factory, discard, trimming
--   Generations ........... stamps and stale-object detection
--   Capacity and waiting .. creation cap, live limit, waiting ring
--   Children .............. intrusive parent/child links
--   Release helpers ....... unparking and the child cascade
--   Release transaction ... the one path every release goes through
--   Deferred release ...... parking until an animation finishes
--   Construction .......... pool creation and constructor prewarm
--   Pool methods .......... the handle a pool owner receives
--   Package constructors .. New and NewTablePool
--   Commit ................ prototype/facade assignment and self-check

-- Constants ------------------------------------------------------------------

local PACKAGE_NAME = "poolKit"
local API_GENERATION = 1
local IMPLEMENTATION_REVISION = 5
local REQUIRED_REGISTRY_API = 2
local STATE_SCHEMA = 2
local DEFAULT_MAX_RETAINED = 128

-- A pool's generation when its constructor names none, and the generation of
-- every pool an older revision built. Fixed rather than tied to PoolKit's own
-- revision, so behaviour never depends on which embedded copy won.
local DEFAULT_GENERATION = 1

-- The shape every pool carries. Pools built by an older revision have no
-- `_schema` field and are brought up to this shape the first time a method of
-- this revision touches them (see `upgradePool`).
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
---@field generation integer? Positive integer stamped on every object the factory builds; default `1`.

---Options accepted by `PoolKit:New`.
---@class PoolKit.NewOptions : PoolKit.CommonOptions
---@field create PoolKit.Factory Required factory.
---@field reset PoolKit.ObjectCallback? Called before retention or discard.
---@field destroy PoolKit.ObjectCallback? Called when an object leaves pool ownership.
---@field strictReset boolean? Refuse to construct a pool that has no `reset`; default `false`.
---@field maxCreated integer? Positive cap on factory calls over the pool's lifetime; for objects the host can never free.
---@field maxActive integer? Positive cap on objects borrowed or parked at the same time.
---@field maxWaiting integer? Bounded waiting-queue size for `Acquire(onAvailable)`; default `0`; requires `maxCreated` or `maxActive`.

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
---@field IsPlaying (fun(self: PoolKit.AnimationGroup): boolean)?

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

---The PoolKit package facade published through Registry.
---@class PoolKit
---@field API integer Public API generation.
---@field REVISION integer Compatible implementation revision.
---@field Pool PoolKit.Pool Shared pool prototype.
---@field UNBOUNDED table Sentinel selecting caller-owned unbounded retention.
---@field DEFAULT_MAX_RETAINED integer
---@field New fun(self: PoolKit, options: PoolKit.NewOptions): PoolKit.Pool
---@field NewTablePool fun(self: PoolKit, options: PoolKit.CommonOptions?): PoolKit.Pool

-- Dependencies --------------------------------------------------------------

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
    error("MoltenCodes PoolKit requires Registry API 2 to be loaded first", 2)
end

local bootstrapPackage = rawget(Registry, "Bootstrap")
local getPackage = rawget(Registry, "Get")
if type(bootstrapPackage) ~= "function" or type(getPackage) ~= "function" then
    error("MoltenCodes PoolKit requires a valid Registry API 2 facade", 2)
end

-- Bootstrap -----------------------------------------------------------------

---Whether `implementation` exposes the complete PoolKit API 1 surface.
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
    return validateStateBase(currentState)
        and rawget(currentState, "schema") == STATE_SCHEMA
        and type(rawget(currentState, "hookedGroups")) == "table"
        and type(rawget(currentState, "deferredPool")) == "table"
        and type(rawget(currentState, "deferredObject")) == "table"
        and type(rawget(currentState, "dispatch")) == "table"
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
        and rawget(rawget(currentState, "poolMetatable"), "__index")
            == rawget(implementation, "Pool")
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

if PoolKit == nil then
    -- Equal or newer compatible revision already owns the shared package table.
    return selected
end

local Pool = rawget(PoolKit, "Pool")
local state = rawget(PoolKit, "_state")

if previousRevision == nil then
    if Pool ~= nil or state ~= nil then
        error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
    end

    Pool = {}
    state = {
        schema = STATE_SCHEMA,
        poolMetatable = {},
        unbounded = {},
        -- Animation groups carry one permanent `OnFinished` hook each, so the
        -- set of hooked groups is remembered and never hooked twice.
        hookedGroups = setmetatable({}, { __mode = "k" }),
        -- The pending deferred release of each animation group, if any.
        deferredPool = {},
        deferredObject = {},
        -- Host hooks call through this table, so a newer revision replaces
        -- the behaviour behind hooks an older revision installed.
        dispatch = {},
    }
    rawset(PoolKit, "Pool", Pool)
    rawset(PoolKit, "_state", state)
elseif type(Pool) ~= "table" or not validateStateBase(state) then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
else
    if rawget(state, "schema") == 1 then
        -- Revisions 1 to 3 kept no generations and no deferred releases. Their
        -- pools cannot be enumerated from here, so they are upgraded lazily
        -- (see `upgradePool`). Revision 4 also recorded a `legacyGeneration`
        -- here; revision 5 no longer reads it and leaves it where it is.
        rawset(state, "hookedGroups", setmetatable({}, { __mode = "k" }))
        rawset(state, "deferredPool", {})
        rawset(state, "deferredObject", {})
        rawset(state, "dispatch", {})
        rawset(state, "schema", STATE_SCHEMA)
    end

    if not validateState(state) then
        error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
    end
end

local POOL_METATABLE = rawget(state, "poolMetatable")
local UNBOUNDED = rawget(state, "unbounded")
rawset(POOL_METATABLE, "__index", Pool)

-- Validation ----------------------------------------------------------------

---Whether `value` is an exact integer of zero or more. `nan` and both
---infinities are rejected before the integer test can accept them.
---@param value any
---@return boolean
local function isNonNegativeInteger(value)
    return type(value) == "number"
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

---Bring a pool built by an older revision up to this revision's shape.
---
---Pools are not registered anywhere, so a bootstrap cannot migrate them. Every
---pool method validates its receiver first, and that check upgrades a pool whose
---`_schema` is not current: one field comparison per call, nothing allocated
---once the pool is current. The defaults reproduce the older behaviour exactly:
---no caps, no queue, no children, and the default generation.
---@param pool table
local function upgradePool(pool)
    local generation = DEFAULT_GENERATION
    rawset(pool, "_generation", generation)
    rawset(pool, "_baseGeneration", generation)
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

---@param self any receiver the public method was called on
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePool(self, methodName, level)
    if type(self) ~= "table" or getmetatable(self) ~= POOL_METATABLE then
        error(methodName .. " must be called on a PoolKit pool", level)
    end
    if rawget(self, "_schema") ~= POOL_SCHEMA then
        upgradePool(self)
    end
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
    if not isNonNegativeInteger(value) then
        error(label .. " must be a non-negative integer", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validatePositiveInteger(value, label, level)
    if not isPositiveInteger(value) then
        error(label .. " must be a positive integer", level)
    end
end

---@param value any
---@param label string argument description, used in the argument error
---@param required boolean whether `nil` is rejected
---@param level integer stack level the failure is reported at
local function validateCallback(value, label, required, level)
    if value == nil and not required then
        return
    end
    if type(value) ~= "function" then
        error(label .. " must be a function", level)
    end
end

-- Option parsing --------------------------------------------------------------

local GENERIC_OPTION_KEYS = {
    create = true,
    reset = true,
    destroy = true,
    maxRetained = true,
    strict = true,
    strictReset = true,
    prewarm = true,
    maxActiveWarning = true,
    generation = true,
    maxCreated = true,
    maxActive = true,
    maxWaiting = true,
}

local TABLE_OPTION_KEYS = {
    maxRetained = true,
    strict = true,
    prewarm = true,
    maxActiveWarning = true,
    generation = true,
}

---Reject the alphabetically first unrecognised option field, if any.
---@param options table
---@param allowed table<string, boolean>
---@param methodName string public method name, used in the argument error
---@param level integer stack level the failure is reported at
local function validateKnownFields(options, allowed, methodName, level)
    local firstUnknown = nil
    for key in next, options do
        if allowed[key] ~= true then
            local text = tostring(key)
            if firstUnknown == nil or text < firstUnknown then
                firstUnknown = text
            end
        end
    end
    if firstUnknown ~= nil then
        error(methodName .. ' options contains unknown field "' .. firstUnknown .. '"', level)
    end
end

---Validate the options every constructor shares and apply their defaults.
---@param options PoolKit.CommonOptions|nil
---@param allowed table<string, boolean> option keys this constructor accepts
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@param defaultMaxRetained integer retention bound when `maxRetained` is absent
---@return integer|table maxRetained
---@return boolean strict
---@return integer prewarm
---@return integer|false maxActiveWarning `false` when leak warnings are disabled
---@return integer generation
local function parseCommonOptions(options, allowed, methodName, level, defaultMaxRetained)
    if options == nil then
        options = {}
    elseif type(options) ~= "table" then
        error(methodName .. " options must be a table", level)
    end

    validateKnownFields(options, allowed, methodName, level + 1)

    local maxRetained = rawget(options, "maxRetained")
    if maxRetained == nil then
        maxRetained = defaultMaxRetained
    else
        maxRetained = validateMaxRetained(maxRetained, methodName .. " maxRetained", level + 1)
    end

    local strict = rawget(options, "strict")
    if strict == nil then
        strict = true
    elseif type(strict) ~= "boolean" then
        error(methodName .. " strict must be a boolean", level)
    end

    local prewarm = rawget(options, "prewarm")
    if prewarm == nil then
        prewarm = 0
    else
        validateCount(prewarm, methodName .. " prewarm", level + 1)
    end

    if maxRetained ~= UNBOUNDED and prewarm > maxRetained then
        error(methodName .. " prewarm cannot exceed maxRetained", level)
    end

    -- Leak diagnostics are opt-in. `false` means "never warn" and is the value
    -- the acquire hot path compares against, so the default costs one
    -- comparison per `Acquire`.
    local maxActiveWarning = rawget(options, "maxActiveWarning")
    if maxActiveWarning == nil then
        maxActiveWarning = false
    else
        validateCount(maxActiveWarning, methodName .. " maxActiveWarning", level + 1)
    end

    local generation = rawget(options, "generation")
    if generation == nil then
        generation = DEFAULT_GENERATION
    else
        validatePositiveInteger(generation, methodName .. " generation", level + 1)
    end

    return maxRetained, strict, prewarm, maxActiveWarning, generation
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
    if released ~= false then
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
    if destroy ~= false then
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
    if released ~= false then
        rawset(released, object, nil)
    end
end

---Build one new object through the pool's factory and count it.
---
---An object built while the pool's generation differs from the generation the
---pool was created with is stamped; an unstamped object belongs to that base
---generation. A pool that never changes its generation therefore writes no
---stamps at all.
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

    local generation = rawget(pool, "_generation")
    if generation ~= rawget(pool, "_baseGeneration") then
        rawset(rawget(pool, "_stamps"), object, generation)
    end
    return object
end

---Whether the pool has room to retain one more released object.
---@param pool PoolKit.Pool
---@return boolean
local function canRetain(pool)
    local maxRetained = rawget(pool, "_maxRetained")
    return maxRetained == UNBOUNDED or rawget(pool, "_availableCount") < maxRetained
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
        maxCreated ~= false
        and targetCount > count
        and rawget(pool, "_createdCount") + (targetCount - count) > maxCreated
    then
        error("PoolKit.Pool:Prewarm target cannot exceed maxCreated", level)
    end

    local created = 0

    while count < targetCount do
        local object = createObject(pool, "PoolKit.Pool:Prewarm", nestedLevel(level))
        count = count + 1
        created = created + 1
        rawset(available, count, object)
        rawset(retained, object, true)
    end

    rawset(pool, "_availableCount", count)
    return created
end

-- Generations ----------------------------------------------------------------
--
-- Stamps live in a weak-keyed side table owned by the pool, never on the
-- object, so a consumer's objects keep exactly the shape its factory gave them
-- and a stamp never keeps an object alive.

---Whether `object` was built by a generation older than the pool's current one.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean stale
local function isStale(pool, object)
    local generation = rawget(pool, "_generation")
    local baseGeneration = rawget(pool, "_baseGeneration")
    if generation == baseGeneration then
        return false
    end
    local stamp = rawget(rawget(pool, "_stamps"), object) or baseGeneration
    return stamp < generation
end

---Destroy every retained object a newer generation superseded.
---@param pool PoolKit.Pool
---@return integer removed
local function trimStale(pool)
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
        local ok, value = discardAvailableObject(pool, stale[index])
        firstError = captureFirstError(firstError, ok, value)
    end

    raiseCaptured(firstError)
    return staleCount
end

-- Capacity and waiting ------------------------------------------------------
--
-- The waiting queue is a ring of `maxWaiting` slots filled with `false` when
-- the pool is built, so enqueueing and dequeueing only overwrite existing array
-- slots: no allocation, ever. A request past the ring's size is refused with
-- `"queueFull"` rather than growing it.

---Whether the pool may hand out one more object right now.
---@param pool PoolKit.Pool
---@return boolean
local function hasCapacity(pool)
    local maxActive = rawget(pool, "_maxActive")
    if
        maxActive ~= false
        and rawget(pool, "_activeCount") + rawget(pool, "_parkedCount") >= maxActive
    then
        return false
    end
    if rawget(pool, "_availableCount") > 0 then
        return true
    end
    local maxCreated = rawget(pool, "_maxCreated")
    return maxCreated == false or rawget(pool, "_createdCount") < maxCreated
end

---Append a waiting request at the back of the ring. The caller checked room.
---@param pool PoolKit.Pool
---@param callback PoolKit.WaitCallback
local function enqueueWaiter(pool, callback)
    local capacity = rawget(pool, "_maxWaiting")
    local count = rawget(pool, "_waitingCount")
    local slot = (rawget(pool, "_waitingHead") + count - 1) % capacity + 1
    rawset(rawget(pool, "_waiting"), slot, callback)
    rawset(pool, "_waitingCount", count + 1)
end

---Put a request back at the front of the ring after a hand-off failed.
---@param pool PoolKit.Pool
---@param callback PoolKit.WaitCallback
local function requeueFront(pool, callback)
    local capacity = rawget(pool, "_maxWaiting")
    local head = (rawget(pool, "_waitingHead") - 2) % capacity + 1
    rawset(rawget(pool, "_waiting"), head, callback)
    rawset(pool, "_waitingHead", head)
    rawset(pool, "_waitingCount", rawget(pool, "_waitingCount") + 1)
end

---Remove and return the oldest waiting request. The caller checked one exists.
---@param pool PoolKit.Pool
---@return PoolKit.WaitCallback callback
local function dequeueWaiter(pool)
    local waiting = rawget(pool, "_waiting")
    local head = rawget(pool, "_waitingHead")
    local callback = rawget(waiting, head)
    rawset(waiting, head, false)
    rawset(pool, "_waitingHead", head % rawget(pool, "_maxWaiting") + 1)
    rawset(pool, "_waitingCount", rawget(pool, "_waitingCount") - 1)
    return callback
end

---Remove the oldest waiting request equal to `callback`, keeping FIFO order.
---@param pool PoolKit.Pool
---@param callback function
---@return boolean removed
local function removeWaiter(pool, callback)
    local count = rawget(pool, "_waitingCount")
    local capacity = rawget(pool, "_maxWaiting")
    local head = rawget(pool, "_waitingHead")
    local waiting = rawget(pool, "_waiting")

    for offset = 0, count - 1 do
        if rawget(waiting, (head + offset - 1) % capacity + 1) == callback then
            -- Shift every request behind it one slot towards the head.
            for later = offset, count - 2 do
                local target = (head + later - 1) % capacity + 1
                local source = (head + later) % capacity + 1
                rawset(waiting, target, rawget(waiting, source))
            end
            rawset(waiting, (head + count - 2) % capacity + 1, false)
            rawset(pool, "_waitingCount", count - 1)
            return true
        end
    end
    return false
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
    if released ~= false then
        rawset(released, object, nil)
    end

    rawset(rawget(pool, "_active"), object, ACTIVE)
    local activeCount = rawget(pool, "_activeCount") + 1
    rawset(pool, "_activeCount", activeCount)

    local warnAt = rawget(pool, "_maxActiveWarning")
    if warnAt ~= false and activeCount >= warnAt and rawget(pool, "_activeWarned") ~= true then
        warnActiveThreshold(pool, activeCount)
    end
end

---Hand freed capacity to waiting requests, oldest first.
---
---A request's object is borrowed on its behalf before its callback runs, so
---the callback owns it exactly as an `Acquire` caller would. A callback that
---raises is reported through the host error handler and keeps the object. A
---factory that raises is reported the same way; the request goes back to the
---front of the queue and waits for the next release.
---@param pool PoolKit.Pool
local function drainWaiting(pool)
    while
        rawget(pool, "_waitingCount") > 0
        and rawget(pool, "_closed") ~= true
        and hasCapacity(pool)
    do
        local callback = dequeueWaiter(pool)
        local ok, object = pcall(takeObject, pool, "PoolKit.Pool:Acquire", 0)
        if not ok then
            requeueFront(pool, callback)
            reportWarning(object)
            return
        end

        markActive(pool, object)
        local delivered, callbackError = pcall(callback, object, pool)
        if not delivered then
            reportWarning(callbackError)
        end
    end
end

---Fail every waiting request because the pool closed. Errors are reported.
---@param pool PoolKit.Pool
local function failWaiting(pool)
    while rawget(pool, "_waitingCount") > 0 do
        local callback = dequeueWaiter(pool)
        local ok, callbackError = pcall(callback, nil, pool, REASON_CLOSED)
        if not ok then
            reportWarning(callbackError)
        end
    end
end

-- Children ------------------------------------------------------------------
--
-- A parent's children form an intrusive doubly linked list kept in side tables
-- owned by the parent's pool, keyed by the child. The child's own pool records
-- which pool it is attached in, so a child released on its own leaves its
-- parent's list in constant time. The tables are created on a pool's first
-- `AttachChild`, so pools that never use children carry only a `false`.

local releaseActive

---Return the parent-side link tables of `pool`, creating them once.
---@param pool PoolKit.Pool
---@return table links
local function ensureChildLinks(pool)
    local links = rawget(pool, "_children")
    if links == false then
        links = {
            first = {},
            nextSibling = {},
            previousSibling = {},
            childPool = {},
            parent = {},
        }
        rawset(pool, "_children", links)
    end
    return links
end

---Return the child-side attachment table of `pool`, creating it once.
---@param pool PoolKit.Pool
---@return table attachedTo child -> the pool its parent belongs to
local function ensureAttachments(pool)
    local attachedTo = rawget(pool, "_attachedTo")
    if attachedTo == false then
        attachedTo = {}
        rawset(pool, "_attachedTo", attachedTo)
    end
    return attachedTo
end

---Put `child` at the front of `parent`'s child list.
---@param parentPool PoolKit.Pool
---@param parent table|userdata
---@param child table|userdata
---@param childPool PoolKit.Pool
local function linkChild(parentPool, parent, child, childPool)
    local links = ensureChildLinks(parentPool)
    local first = rawget(links.first, parent)
    rawset(links.nextSibling, child, first or false)
    rawset(links.previousSibling, child, false)
    if first ~= nil then
        rawset(links.previousSibling, first, child)
    end
    rawset(links.first, parent, child)
    rawset(links.childPool, child, childPool)
    rawset(links.parent, child, parent)
    rawset(ensureAttachments(childPool), child, parentPool)
end

---Take `child` out of its parent's list. Never raises.
---@param parentPool PoolKit.Pool
---@param child table|userdata
local function unlinkChild(parentPool, child)
    local links = rawget(parentPool, "_children")
    local parent = rawget(links.parent, child)
    local childPool = rawget(links.childPool, child)
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

    rawset(links.nextSibling, child, nil)
    rawset(links.previousSibling, child, nil)
    rawset(links.childPool, child, nil)
    rawset(links.parent, child, nil)
    rawset(rawget(childPool, "_attachedTo"), child, nil)
end

---Leave the parent `object` is attached to, if any.
---@param pool PoolKit.Pool pool `object` belongs to
---@param object table|userdata
local function detachFromParent(pool, object)
    local attachedTo = rawget(pool, "_attachedTo")
    if attachedTo == false then
        return
    end
    local parentPool = rawget(attachedTo, object)
    if parentPool ~= nil then
        unlinkChild(parentPool, object)
    end
end

-- Release helpers -------------------------------------------------------------

---Move a parked object back to plain borrowed state and forget its animation.
---@param pool PoolKit.Pool
---@param object table|userdata
local function unpark(pool, object)
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
end

---Complete a deferred release now.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean released
local function finalizeParked(pool, object)
    unpark(pool, object)
    return releaseActive(pool, object)
end

---Release one attached child as part of its parent's release.
---@param childPool PoolKit.Pool
---@param child table|userdata
local function releaseCascadedChild(childPool, child)
    local status = rawget(rawget(childPool, "_active"), child)
    if status ~= ACTIVE and status ~= PARKED then
        -- `RELEASING` is a cycle back to an object already being released;
        -- anything else is no longer borrowed. Either way there is nothing to do.
        return
    end

    ensureMutationAllowed(childPool, "PoolKit.Pool:Release", 0)
    if status == PARKED then
        finalizeParked(childPool, child)
    else
        releaseActive(childPool, child)
    end
end

---Release every child attached to `parent`, most recently attached first.
---@param pool PoolKit.Pool
---@param parent table|userdata
---@return table|nil firstError
local function releaseChildren(pool, parent)
    local links = rawget(pool, "_children")
    if links == false then
        return nil
    end

    local firstError = nil
    local child = rawget(links.first, parent)
    while child ~= nil do
        local childPool = rawget(links.childPool, child)
        -- Unlink first so the child's own release does not look for a parent,
        -- and so the loop always advances whatever the release does.
        unlinkChild(pool, child)
        local ok, value = pcall(releaseCascadedChild, childPool, child)
        firstError = captureFirstError(firstError, ok, value)
        child = rawget(links.first, parent)
    end
    return firstError
end

-- Release transaction ---------------------------------------------------------

---Release one borrowed object: cascade to its children, reset it, then retain
---it or retire it, and finally hand freed capacity to waiting requests.
---
---The caller has validated the pool and that `object` is `ACTIVE`.
---@param pool PoolKit.Pool
---@param object table|userdata
---@return boolean released
function releaseActive(pool, object)
    local active = rawget(pool, "_active")
    rawset(active, object, RELEASING)

    local firstError = releaseChildren(pool, object)

    local reset = rawget(pool, "_reset")
    if reset ~= false then
        if rawget(pool, "_trustedCallbacks") == true then
            reset(object, pool)
        else
            local ok, value = pcall(invokeLifecycleCallback, pool, "reset", reset, object, pool)
            if not ok then
                rawset(active, object, ACTIVE)
                -- First error wins: a child that failed before this reset ran
                -- is the error the caller hears about.
                firstError = captureFirstError(firstError, false, value)
                raiseCaptured(firstError)
            end
        end
    end

    detachFromParent(pool, object)
    rawset(active, object, nil)
    rawset(pool, "_activeCount", rawget(pool, "_activeCount") - 1)

    if rawget(pool, "_closed") ~= true and canRetain(pool) and not isStale(pool, object) then
        local count = rawget(pool, "_availableCount") + 1
        rawset(rawget(pool, "_available"), count, object)
        rawset(rawget(pool, "_retained"), object, true)
        rawset(pool, "_availableCount", count)
    else
        local ok, value = pcall(destroyDiscarded, pool, object)
        firstError = captureFirstError(firstError, ok, value)
    end

    if rawget(pool, "_waitingCount") > 0 then
        drainWaiting(pool)
    end

    raiseCaptured(firstError)
    return true
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
    if released ~= false and rawget(released, object) == true then
        error(methodName .. " object has already been released", level)
    end
    error(methodName .. " object was not acquired from this pool", level)
end

-- Deferred release ------------------------------------------------------------

---`OnFinished` hook shared by every animation group PoolKit ever hooked.
---
---Reads its behaviour from shared state, so a hook an older revision installed
---runs the newest accepted revision's completion.
---@param group PoolKit.AnimationGroup
local function onAnimationFinished(group)
    local finish = rawget(rawget(state, "dispatch"), "animationFinished")
    return finish(group)
end

---Complete the deferred release waiting on `group`, if any. Called by the host.
---
---Failures cannot reach a caller here, so they are reported through the host
---error handler. A pool that is inside one of its own lifecycle callbacks when
---the animation ends keeps the object parked; `Release` or `Close` completes it.
---@param group PoolKit.AnimationGroup
local function completeDeferredRelease(group)
    local pool = rawget(rawget(state, "deferredPool"), group)
    if pool == nil then
        return
    end
    local object = rawget(rawget(state, "deferredObject"), group)

    if rawget(pool, "_callbackDepth") > 0 then
        reportWarning(
            "PoolKit could not complete a deferred release because its pool was inside a "
                .. tostring(rawget(pool, "_callbackPhase"))
                .. " callback; release the object explicitly"
        )
        return
    end

    local ok, value = pcall(finalizeParked, pool, object)
    if not ok then
        reportWarning(value)
    end
end

---Install PoolKit's `OnFinished` hook on `group`, once per group ever.
---
---`HookScript` cannot be undone, so hooking per release would stack one more
---permanent hook on a pooled Frame's animation every time it is reused.
---@param group PoolKit.AnimationGroup
local function hookAnimationGroup(group)
    local hooked = rawget(state, "hookedGroups")
    if rawget(hooked, group) == true then
        return
    end
    group:HookScript("OnFinished", onAnimationFinished)
    rawset(hooked, group, true)
end

---Park a borrowed object until `group` finishes.
---@param pool PoolKit.Pool
---@param object table|userdata
---@param group PoolKit.AnimationGroup
local function park(pool, object, group)
    local parked = rawget(pool, "_parked")
    if parked == false then
        parked = {}
        rawset(pool, "_parked", parked)
    end
    rawset(parked, object, group)
    rawset(rawget(state, "deferredPool"), group, pool)
    rawset(rawget(state, "deferredObject"), group, object)

    rawset(rawget(pool, "_active"), object, PARKED)
    rawset(pool, "_activeCount", rawget(pool, "_activeCount") - 1)
    rawset(pool, "_parkedCount", rawget(pool, "_parkedCount") + 1)
end

-- Construction ------------------------------------------------------------------

---Settings a constructor resolved from its options.
---@class PoolKit.PoolSettings
---@field create PoolKit.Factory
---@field reset PoolKit.ObjectCallback|nil
---@field destroy PoolKit.ObjectCallback|nil
---@field maxRetained integer|table
---@field strict boolean
---@field prewarm integer
---@field maxActiveWarning integer|false
---@field trustedCallbacks boolean whether PoolKit itself owns the callbacks
---@field generation integer
---@field maxCreated integer|false
---@field maxActive integer|false
---@field maxWaiting integer

---Construct one pool and, when asked, prewarm it before it escapes.
---@param settings PoolKit.PoolSettings
---@return PoolKit.Pool
local function newPool(settings)
    -- `false` rather than `nil` so the hot path can test the field with one
    -- comparison instead of distinguishing "absent" from "empty".
    ---@type table|false
    local released = false
    if settings.strict then
        released = setmetatable({}, { __mode = "k" })
    end

    -- The ring is filled once here, so queue traffic only overwrites slots.
    local maxWaiting = settings.maxWaiting
    ---@type table|false
    local waiting = false
    if maxWaiting > 0 then
        waiting = {}
        for slot = 1, maxWaiting do
            waiting[slot] = false
        end
    end

    local pool = setmetatable({
        _schema = POOL_SCHEMA,
        _create = settings.create,
        _reset = settings.reset or false,
        _destroy = settings.destroy or false,
        _maxRetained = settings.maxRetained,
        _strict = settings.strict,
        _available = {},
        _availableCount = 0,
        _active = {},
        _activeCount = 0,
        _maxActiveWarning = settings.maxActiveWarning,
        _activeWarned = false,
        _retained = {},
        _released = released,
        _createdCount = 0,
        _discardedCount = 0,
        _closed = false,
        _callbackPhase = false,
        _callbackDepth = 0,
        _trustedCallbacks = settings.trustedCallbacks == true,
        _generation = settings.generation,
        _baseGeneration = settings.generation,
        _stamps = false,
        _maxCreated = settings.maxCreated,
        _maxActive = settings.maxActive,
        _maxWaiting = maxWaiting,
        _waiting = waiting,
        _waitingHead = 1,
        _waitingCount = 0,
        _parked = false,
        _parkedCount = 0,
        _children = false,
        _attachedTo = false,
    }, POOL_METATABLE)

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
---@param self PoolKit.Pool
---@param onAvailable PoolKit.WaitCallback? called with the object once one frees
---@return table|userdata|nil object
---@return PoolKit.AcquireReason? reason why no object was returned
local function poolAcquire(self, onAvailable)
    validatePool(self, "PoolKit.Pool:Acquire", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:Acquire", 3)
    if rawget(self, "_closed") == true then
        error("PoolKit.Pool:Acquire cannot use a closed pool", 2)
    end
    if onAvailable ~= nil and type(onAvailable) ~= "function" then
        error("PoolKit.Pool:Acquire onAvailable must be a function", 2)
    end

    -- Requests already waiting are served first, so a new caller never jumps
    -- the queue; normally the queue is empty and this is one comparison.
    if rawget(self, "_waitingCount") > 0 then
        drainWaiting(self)
    end

    if rawget(self, "_waitingCount") > 0 or not hasCapacity(self) then
        if onAvailable == nil then
            return nil, REASON_EXHAUSTED
        end
        if rawget(self, "_waitingCount") >= rawget(self, "_maxWaiting") then
            return nil, REASON_QUEUE_FULL
        end
        enqueueWaiter(self, onAvailable)
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
    if retainCount == nil then
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

---Complete every parked release of a closing pool, best effort.
---@param pool PoolKit.Pool
---@return table|nil firstError
local function finalizeAllParked(pool)
    local parked = rawget(pool, "_parked")
    if parked == false then
        return nil
    end

    local firstError = nil
    local object = next(parked)
    while object ~= nil do
        local ok, value = pcall(finalizeParked, pool, object)
        firstError = captureFirstError(firstError, ok, value)
        -- `unpark` removes the entry before anything can raise; this only
        -- guarantees the loop advances if that ever stops being true.
        rawset(parked, object, nil)
        object = next(parked)
    end
    return firstError
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

    failWaiting(self)
    local firstError = finalizeAllParked(self)
    local ok, value = pcall(trimTo, self, 0)
    firstError = captureFirstError(firstError, ok, value)

    raiseCaptured(firstError)
    return true
end

---Whether the pool is terminally closed.
---@param self PoolKit.Pool
---@return boolean closed
local function poolIsClosed(self)
    validatePool(self, "PoolKit.Pool:IsClosed", 3)
    return rawget(self, "_closed") == true
end

---Number of objects retained and ready to hand out.
---@param self PoolKit.Pool
---@return integer availableCount
local function poolGetAvailableCount(self)
    validatePool(self, "PoolKit.Pool:GetAvailableCount", 3)
    return rawget(self, "_availableCount")
end

---Number of objects currently borrowed. Parked objects are not counted.
---@param self PoolKit.Pool
---@return integer activeCount
local function poolGetActiveCount(self)
    validatePool(self, "PoolKit.Pool:GetActiveCount", 3)
    return rawget(self, "_activeCount")
end

---Number of objects this pool has ever built through its factory.
---@param self PoolKit.Pool
---@return integer createdCount
local function poolGetCreatedCount(self)
    validatePool(self, "PoolKit.Pool:GetCreatedCount", 3)
    return rawget(self, "_createdCount")
end

---Number of objects this pool has released from its ownership.
---@param self PoolKit.Pool
---@return integer discardedCount
local function poolGetDiscardedCount(self)
    validatePool(self, "PoolKit.Pool:GetDiscardedCount", 3)
    return rawget(self, "_discardedCount")
end

---Current retention bound, or `PoolKit.UNBOUNDED`.
---@param self PoolKit.Pool
---@return integer|table maxRetained
local function poolGetMaxRetained(self)
    validatePool(self, "PoolKit.Pool:GetMaxRetained", 3)
    return rawget(self, "_maxRetained")
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

---The generation stamped on objects the factory builds from now on.
---@param self PoolKit.Pool
---@return integer generation
local function poolGetGeneration(self)
    validatePool(self, "PoolKit.Pool:GetGeneration", 3)
    return rawget(self, "_generation")
end

---Raise the pool's generation. Retained objects from an older generation are
---destroyed at once; borrowed ones are destroyed instead of retained when they
---come back. Lowering the generation is refused.
---@param self PoolKit.Pool
---@param generation integer positive integer no lower than the current one
---@return integer removed retained objects destroyed by this call
local function poolSetGeneration(self, generation)
    validatePool(self, "PoolKit.Pool:SetGeneration", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:SetGeneration", 3)
    validatePositiveInteger(generation, "PoolKit.Pool:SetGeneration generation", 3)

    local current = rawget(self, "_generation")
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

    if rawget(self, "_stamps") == false then
        rawset(self, "_stamps", setmetatable({}, { __mode = "k" }))
    end
    rawset(self, "_generation", generation)
    return trimStale(self)
end

---Number of `Acquire(onAvailable)` requests waiting for an object.
---@param self PoolKit.Pool
---@return integer waitingCount
local function poolGetWaitingCount(self)
    validatePool(self, "PoolKit.Pool:GetWaitingCount", 3)
    return rawget(self, "_waitingCount")
end

---Withdraw the oldest waiting request made with `callback`.
---@param self PoolKit.Pool
---@param callback PoolKit.WaitCallback
---@return boolean removed `false` when no such request was waiting.
local function poolCancelWaiting(self, callback)
    validatePool(self, "PoolKit.Pool:CancelWaiting", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:CancelWaiting", 3)
    validateCallback(callback, "PoolKit.Pool:CancelWaiting callback", true, 3)
    if rawget(self, "_waitingCount") == 0 then
        return false
    end
    return removeWaiter(self, callback)
end

---Number of objects whose release waits for an animation to finish.
---@param self PoolKit.Pool
---@return integer parkedCount
local function poolGetParkedCount(self)
    validatePool(self, "PoolKit.Pool:GetParkedCount", 3)
    return rawget(self, "_parkedCount")
end

---The creation cap, or `false` when the pool has none.
---@param self PoolKit.Pool
---@return integer|false maxCreated
local function poolGetMaxCreated(self)
    validatePool(self, "PoolKit.Pool:GetMaxCreated", 3)
    return rawget(self, "_maxCreated")
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
    if current == false then
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
    if rawget(self, "_waitingCount") > 0 and rawget(self, "_closed") ~= true then
        drainWaiting(self)
    end
    return self
end

---Attach `child`, borrowed from `childPool`, to `parent`, borrowed from this
---pool. Releasing `parent` releases its children first, most recently attached
---first, through their own pools; a child released on its own is detached.
---@param self PoolKit.Pool
---@param parent table|userdata an object borrowed from this pool
---@param child table|userdata an object borrowed from `childPool`
---@param childPool PoolKit.Pool the pool `child` belongs to; may be this pool
---@return PoolKit.Pool self
local function poolAttachChild(self, parent, child, childPool)
    validatePool(self, "PoolKit.Pool:AttachChild", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:AttachChild", 3)
    validatePoolObject(parent, "PoolKit.Pool:AttachChild parent", 3)
    validatePoolObject(child, "PoolKit.Pool:AttachChild child", 3)
    if type(childPool) ~= "table" or getmetatable(childPool) ~= POOL_METATABLE then
        error("PoolKit.Pool:AttachChild childPool must be a PoolKit pool", 2)
    end
    if rawget(childPool, "_schema") ~= POOL_SCHEMA then
        upgradePool(childPool)
    end

    if rawget(rawget(self, "_active"), parent) ~= ACTIVE then
        error("PoolKit.Pool:AttachChild parent must be borrowed from this pool", 2)
    end
    if rawget(rawget(childPool, "_active"), child) ~= ACTIVE then
        error("PoolKit.Pool:AttachChild child must be borrowed from childPool", 2)
    end
    if parent == child then
        error("PoolKit.Pool:AttachChild cannot attach an object to itself", 2)
    end
    local attachedTo = rawget(childPool, "_attachedTo")
    if attachedTo ~= false and rawget(attachedTo, child) ~= nil then
        error("PoolKit.Pool:AttachChild child is already attached to a parent", 2)
    end

    linkChild(self, parent, child, childPool)
    return self
end

---Detach `child` from its parent in this pool without releasing either.
---@param self PoolKit.Pool
---@param child table|userdata
---@return boolean detached `false` when `child` had no parent in this pool.
local function poolDetachChild(self, child)
    validatePool(self, "PoolKit.Pool:DetachChild", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:DetachChild", 3)
    validatePoolObject(child, "PoolKit.Pool:DetachChild child", 3)

    local links = rawget(self, "_children")
    if links == false or rawget(links.parent, child) == nil then
        return false
    end
    unlinkChild(self, child)
    return true
end

---Release `object` once `animationGroup` finishes playing.
---
---The object is parked: still owned by the pool (`Owns` is `true`), no longer
---borrowed (`IsActive` is `false`), and still counted against `maxActive`
---because it is still on screen. PoolKit hooks the group's `OnFinished` once per
---group. A group that is not playing would never finish, so the object is
---released at once instead. `Release(object)` completes a parked release early.
---@param self PoolKit.Pool
---@param object table|userdata an object borrowed from this pool
---@param animationGroup PoolKit.AnimationGroup the fade-out or other animation
---@return boolean deferred `false` when the object was released immediately.
local function poolReleaseAfter(self, object, animationGroup)
    validatePool(self, "PoolKit.Pool:ReleaseAfter", 3)
    ensureMutationAllowed(self, "PoolKit.Pool:ReleaseAfter", 3)
    validatePoolObject(object, "PoolKit.Pool:ReleaseAfter object", 3)

    local groupType = type(animationGroup)
    if
        (groupType ~= "table" and groupType ~= "userdata")
        or type(animationGroup.HookScript) ~= "function"
    then
        error("PoolKit.Pool:ReleaseAfter animationGroup must be an animation group", 2)
    end

    local status = rawget(rawget(self, "_active"), object)
    if status ~= ACTIVE then
        raiseNotReleasable(self, object, status, "PoolKit.Pool:ReleaseAfter", 3)
    end
    if rawget(rawget(state, "deferredPool"), animationGroup) ~= nil then
        error("PoolKit.Pool:ReleaseAfter animationGroup already has a pending release", 2)
    end

    local isPlaying = animationGroup.IsPlaying
    if type(isPlaying) == "function" and not isPlaying(animationGroup) then
        releaseActive(self, object)
        return false
    end

    hookAnimationGroup(animationGroup)
    park(self, object, animationGroup)
    return true
end

-- Package constructors -------------------------------------------------------

---Validate the capacity options of `PoolKit:New`.
---@param options table
---@param level integer stack level the failures are reported at
---@return integer|false maxCreated
---@return integer|false maxActive
---@return integer maxWaiting
local function parseCapacityOptions(options, level)
    local maxCreated = rawget(options, "maxCreated")
    if maxCreated == nil then
        maxCreated = false
    else
        validatePositiveInteger(maxCreated, "PoolKit:New maxCreated", level + 1)
    end

    local maxActive = rawget(options, "maxActive")
    if maxActive == nil then
        maxActive = false
    else
        validatePositiveInteger(maxActive, "PoolKit:New maxActive", level + 1)
    end

    local maxWaiting = rawget(options, "maxWaiting")
    if maxWaiting == nil then
        maxWaiting = 0
    else
        validateCount(maxWaiting, "PoolKit:New maxWaiting", level + 1)
    end
    if maxWaiting > 0 and maxCreated == false and maxActive == false then
        error("PoolKit:New maxWaiting requires maxCreated or maxActive", level)
    end

    return maxCreated, maxActive, maxWaiting
end

---Create a generic object pool.
---@param _ PoolKit
---@param options PoolKit.NewOptions
---@return PoolKit.Pool pool
local function packageNew(_, options)
    if type(options) ~= "table" then
        error("PoolKit:New options must be a table", 2)
    end
    local create = rawget(options, "create")
    local reset = rawget(options, "reset")
    local destroy = rawget(options, "destroy")
    validateCallback(create, "PoolKit:New create", true, 3)
    validateCallback(reset, "PoolKit:New reset", false, 3)
    validateCallback(destroy, "PoolKit:New destroy", false, 3)

    -- A construction-time check only: `strictReset` never reaches the pool, so
    -- opting into it costs the acquire/release hot paths nothing.
    local strictReset = rawget(options, "strictReset")
    if strictReset ~= nil and type(strictReset) ~= "boolean" then
        error("PoolKit:New strictReset must be a boolean", 2)
    end
    if strictReset == true and reset == nil then
        error("PoolKit:New strictReset requires a reset callback", 2)
    end

    -- A capped pool retains everything it may ever create by default: the
    -- objects a cap exists for cannot be freed, so discarding one on release
    -- would only lose it for good.
    local requestedMaxCreated = rawget(options, "maxCreated")
    local defaultMaxRetained = DEFAULT_MAX_RETAINED
    if isPositiveInteger(requestedMaxCreated) then
        defaultMaxRetained = requestedMaxCreated
    end

    local maxRetained, strict, prewarm, maxActiveWarning, generation =
        parseCommonOptions(options, GENERIC_OPTION_KEYS, "PoolKit:New", 3, defaultMaxRetained)
    local maxCreated, maxActive, maxWaiting = parseCapacityOptions(options, 3)
    if maxCreated ~= false and prewarm > maxCreated then
        error("PoolKit:New prewarm cannot exceed maxCreated", 2)
    end

    return newPool({
        create = create,
        reset = reset,
        destroy = destroy,
        maxRetained = maxRetained,
        strict = strict,
        prewarm = prewarm,
        maxActiveWarning = maxActiveWarning,
        trustedCallbacks = false,
        generation = generation,
        maxCreated = maxCreated,
        maxActive = maxActive,
        maxWaiting = maxWaiting,
    })
end

---Factory for `PoolKit:NewTablePool`.
---@return table
local function tableCreate()
    return {}
end

---Shallow-clearing reset for `PoolKit:NewTablePool`.
---@param object table
local function tableReset(object)
    for key in next, object do
        rawset(object, key, nil)
    end
end

---Create a shallow-clearing Lua table pool.
---@param _ PoolKit
---@param options PoolKit.CommonOptions?
---@return PoolKit.Pool pool
local function packageNewTablePool(_, options)
    local maxRetained, strict, prewarm, maxActiveWarning, generation = parseCommonOptions(
        options,
        TABLE_OPTION_KEYS,
        "PoolKit:NewTablePool",
        3,
        DEFAULT_MAX_RETAINED
    )
    return newPool({
        create = tableCreate,
        reset = tableReset,
        destroy = nil,
        maxRetained = maxRetained,
        strict = strict,
        prewarm = prewarm,
        maxActiveWarning = maxActiveWarning,
        trustedCallbacks = true,
        generation = generation,
        maxCreated = false,
        maxActive = false,
        maxWaiting = 0,
    })
end

-- Commit --------------------------------------------------------------------

rawset(Pool, "Acquire", poolAcquire)
rawset(Pool, "Release", poolRelease)
rawset(Pool, "Prewarm", poolPrewarm)
rawset(Pool, "Trim", poolTrim)
rawset(Pool, "Clear", poolClear)
rawset(Pool, "Close", poolClose)
rawset(Pool, "IsClosed", poolIsClosed)
rawset(Pool, "GetAvailableCount", poolGetAvailableCount)
rawset(Pool, "GetActiveCount", poolGetActiveCount)
rawset(Pool, "GetCreatedCount", poolGetCreatedCount)
rawset(Pool, "GetDiscardedCount", poolGetDiscardedCount)
rawset(Pool, "GetMaxRetained", poolGetMaxRetained)
rawset(Pool, "SetMaxRetained", poolSetMaxRetained)
rawset(Pool, "Owns", poolOwns)
rawset(Pool, "IsActive", poolIsActive)
rawset(Pool, "GetGeneration", poolGetGeneration)
rawset(Pool, "SetGeneration", poolSetGeneration)
rawset(Pool, "GetWaitingCount", poolGetWaitingCount)
rawset(Pool, "CancelWaiting", poolCancelWaiting)
rawset(Pool, "GetParkedCount", poolGetParkedCount)
rawset(Pool, "GetMaxCreated", poolGetMaxCreated)
rawset(Pool, "SetMaxCreated", poolSetMaxCreated)
rawset(Pool, "AttachChild", poolAttachChild)
rawset(Pool, "DetachChild", poolDetachChild)
rawset(Pool, "ReleaseAfter", poolReleaseAfter)

rawset(PoolKit, "API", API_GENERATION)
rawset(PoolKit, "REVISION", IMPLEMENTATION_REVISION)
rawset(PoolKit, "Pool", Pool)
rawset(PoolKit, "UNBOUNDED", UNBOUNDED)
rawset(PoolKit, "DEFAULT_MAX_RETAINED", DEFAULT_MAX_RETAINED)
rawset(PoolKit, "New", packageNew)
rawset(PoolKit, "NewTablePool", packageNewTablePool)

rawset(rawget(state, "dispatch"), "animationFinished", completeDeferredRelease)

if not validatePublicSurface(PoolKit) or not validateCurrentState(PoolKit) then
    error("MoltenCodes PoolKit package state is corrupted or incomplete", 2)
end

return PoolKit
