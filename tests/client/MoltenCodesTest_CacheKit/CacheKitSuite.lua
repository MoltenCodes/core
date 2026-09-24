-- MoltenCodes Test: CacheKitSuite.lua
--
-- Real-client suites for the `cacheKit` package. The Busted specs under
-- packages/cacheKit/tests/ prove CacheKit on a stock Lua 5.1 with a clock the
-- spec advances by hand and a scripted EventKit host; these prove, inside the
-- game client with the installed MoltenCodes addon, what that fixture can only
-- simulate:
--
--   * the installed facade and its committed revision, and the two optional
--     host facilities it found: `GetTimePreciseSec` and EventKit API 1;
--   * age limits on the client's own clock: a 0.3-second entry is present
--     before its limit and gone after it, a `Set` restarts the age, and a
--     negative entry expires by its own limit, each measured with
--     `GetTimePreciseSec` and logged in milliseconds;
--   * `Memoize` over real client reads (`C_Item.GetItemInfoInstant` for the
--     Hearthstone, `C_Spell.GetSpellInfo` for Auto Attack), `cacheable`
--     keeping an answer the client has no data for out of the cache, and a
--     memo's age limit on the real clock;
--   * `ClearOn("CVAR_UPDATE")` through EventKit, cleared by the event the
--     client raises inside `C_CVar.SetCVar("chatBubbles", ...)`, and the
--     refusal of an event name the client does not know;
--   * lazy trees (once per path, invalidation, eviction, a resolver that reads
--     the client) and ring queues (every overflow policy, order across the
--     wrap-around, `Iterate`);
--   * that the documented allocation-free paths (cache `Get`, `Peek`, `Set`
--     and `PutNegative` of a stored key, a negative hit, a memoised hit, a lazy
--     hit, queue `Push`, `Pop` and `Iterate`) allocate nothing on the client's
--     own collector;
--   * argument errors, and secret values made by the client's `secretwrap`:
--     stored and handed back untouched where docs/API.md says they survive,
--     refused as limits and in a snapshot's `fill`, all pointing at this file
--     as the client names it.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible.
-- The only client state a test changes is the `chatBubbles` CVar, flipped by
-- the ClearOn tests and put back by the After hook. Every wait is on
-- `GetTimePreciseSec` and lasts at most half a second.
--
-- Run with `/mct run cacheKit`; tests/client/MoltenCodesTest_CacheKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every cache, snapshot and lazy tree a test creates
-- is closed by the After hook of its suite, whatever the test's outcome, which
-- also closes the private EventKit scope of every cache that cleared on an
-- event; only then is the `chatBubbles` CVar put back. Queues have no `Close`
-- and hold nothing once their test ends. EventKit keeps the Frames it created
-- for reuse, because the client never frees a Frame. CacheKit's package-wide
-- limits are never changed: the one `SetLimits` call is refused. Nothing is
-- written to a global or a saved variable.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
    error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local CACHE_KIT_API = 1
local EVENT_KIT_API = 1
local PACKAGE_ID = "cacheKit"

--- The age limit of the expiry tests: long enough for several rendered frames
--- before it, short enough to keep the run fast.
local TTL_SECONDS = 0.3

--- The negative entry's own age limit, shorter than its cache's.
local NEGATIVE_TTL_SECONDS = 0.2

--- The age limit of the cache that holds the negative entry: far beyond the run.
local LONG_TTL_SECONDS = 60

--- How long a test waits for the client's clock to pass a deadline. A rendered
--- frame is far shorter; this only ends a test whose client stopped rendering.
local CLOCK_WAIT_LIMIT_SECONDS = 2

--- The Hearthstone: an item every Retail client knows from its own data, so
--- `C_Item.GetItemInfoInstant` answers it without asking the server.
local HEARTHSTONE_ITEM_ID = 6948

--- An item ID no item has: `C_Item.GetItemInfoInstant` answers it with nothing.
local MISSING_ITEM_ID = 0

--- Auto Attack: a spell every character knows.
local AUTO_ATTACK_SPELL_ID = 6603

--- The CVar the ClearOn tests change so the client raises CVAR_UPDATE. It is
--- cosmetic (whether chat bubbles are drawn), always present on Retail, not
--- read-only and not secure, so `C_CVar.SetCVar` accepts it from addon code;
--- every change is put back by the After hook.
local PROBE_CVAR = "chatBubbles"

--- The event the client raises when a CVar changes.
local CVAR_EVENT = "CVAR_UPDATE"

--- An event name no client knows.
local UNKNOWN_EVENT = "MOLTENCODES_TEST_NO_SUCH_EVENT"

--- How many cycles each allocation guard runs. One table or closure per cycle
--- would cost well over a hundred kilobytes at this count.
local ALLOCATION_CYCLES = 5000

--- How many values the Iterate guard's queue holds, and how many full walks it
--- measures: 64 steps per walk, 32000 steps in all.
local ITERATE_QUEUE_SIZE = 64
local ITERATE_WALKS = 500

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
    -- The clock, CVars, item and spell data, UIParent and the secret-value
    -- functions are World of Warcraft client globals, reachable only through
    -- the global table.
    -- selene: allow(global_usage)
    return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_CVar`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
    local hostNamespace = readHost(namespaceName)
    if type(hostNamespace) ~= "table" then
        return nil
    end
    local candidate = hostNamespace[functionName]
    if type(candidate) ~= "function" then
        return nil
    end
    return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
    error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- CacheKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- objects are typed `any` here.

---@type any
local CacheKit = Registry:Get(PACKAGE_ID, CACHE_KIT_API)
if type(CacheKit) == "nil" then
    error(addonName .. " requires CacheKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- The clock CacheKit's age limits read. The tests measure against the same
--- one, so the addon refuses to load on a client without it.
local getTimePreciseSec = readHost("GetTimePreciseSec")
local uiParent = readHost("UIParent")
if type(getTimePreciseSec) ~= "function" or type(uiParent) ~= "table" then
    error(addonName .. " requires the client's GetTimePreciseSec and UIParent", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
    return SECRETS_AVAILABLE and isSecretValue(value) == true
end

---The client's clock, in seconds.
---@return number
local function now()
    return getTimePreciseSec()
end

---Seconds as whole milliseconds, for the log.
---@param seconds number
---@return string
local function milliseconds(seconds)
    return ("%.1f ms"):format(seconds * 1000)
end

-- Objects of the running test ------------------------------------------------------------

--- Caches, snapshots and lazy trees the running test created; the After hook
--- closes them.
---@type any[]
local trackedObjects = {}

--- Client settings to put back after the objects are closed, newest last.
---@type fun()[]
local pendingRestores = {}

---Remember a cache, snapshot or lazy tree for the After hook and return it.
---@param object any
---@return any object
local function track(object)
    trackedObjects[#trackedObjects + 1] = object
    return object
end

---Close every object the running test created, then put back every client
---setting it changed. The After hook of every suite. Closing first releases
---every ClearOn subscription, so restoring the CVar clears nothing.
local function cleanUp()
    for index = #trackedObjects, 1, -1 do
        local object = trackedObjects[index]
        trackedObjects[index] = nil
        pcall(object.Close, object)
    end
    for index = #pendingRestores, 1, -1 do
        local restore = pendingRestores[index]
        pendingRestores[index] = nil
        pcall(restore)
    end
end

---Register a suite of this package whose tests all end with every object
---closed and every setting put back.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
    local suite = Harness:Suite(PACKAGE_ID, part, addonName)
    suite:After(cleanUp)
    return suite
end

---Suspend the test until the client's clock reads `deadline` or later,
---failing it when the client stops rendering first.
---@param ctx TestKit.Context
---@param deadline number a `GetTimePreciseSec` reading
local function waitForClock(ctx, deadline)
    local reached = ctx:WaitUntil(function()
        return now() >= deadline
    end, CLOCK_WAIT_LIMIT_SECONDS)
    if not reached then
        ctx:Fail("the client's clock did not reach the deadline within the wait limit")
    end
end

---Fail the test when a reading taken at `readAt` was not early enough to be
---sure an entry stored at `storedAt` with `ttlSeconds` was still live. Only a
---client that stalled for the whole age limit fails here.
---@param ctx TestKit.Context
---@param storedAt number clock reading taken just before the entry was stored
---@param readAt number clock reading taken just after the read
---@param ttlSeconds number
local function requireReadBeforeExpiry(ctx, storedAt, readAt, ttlSeconds)
    if readAt - storedAt >= ttlSeconds then
        ctx:Fail(
            ("the read came %s after the store, not before the %s limit: the client stalled; run again"):format(
                milliseconds(readAt - storedAt),
                milliseconds(ttlSeconds)
            )
        )
    end
end

-- Client reads ------------------------------------------------------------------------------

---What the item tests keep about one item: the ID the client answered with
---(`false` when it answered nothing), its icon and its class.
---@class MoltenCodesTest.CacheKit.ItemShape
---@field itemId integer|false
---@field icon any
---@field classId any

---The shape of `C_Item.GetItemInfoInstant(itemId)`: a new table per call. An
---item the client has no data for, or an answer the client made secret, gives
---`itemId = false`.
---@param getItemInfoInstant function
---@param itemId integer
---@return MoltenCodesTest.CacheKit.ItemShape
local function readItemShape(getItemInfoInstant, itemId)
    local succeeded, foundId, _, _, _, icon, classId = pcall(getItemInfoInstant, itemId)
    if not succeeded or isSecret(foundId) or type(foundId) ~= "number" then
        return { itemId = false, icon = false, classId = false }
    end
    return { itemId = foundId, icon = icon, classId = classId }
end

---`C_Item.GetItemInfoInstant`, or end the test as skipped without it.
---@param ctx TestKit.Context
---@return function
local function requireItemInfoInstant(ctx)
    local getItemInfoInstant = readHostFunction("C_Item", "GetItemInfoInstant")
    if type(getItemInfoInstant) == "nil" then
        Harness:SkipTest(ctx, "the client has no C_Item.GetItemInfoInstant")
    end
    ---@cast getItemInfoInstant function
    return getItemInfoInstant
end

-- The probe CVar ------------------------------------------------------------------------------

---The probe CVar's value through `C_CVar.GetCVar`, or `nil`.
---@return string|nil
local function currentProbeValue()
    local getCVar = readHostFunction("C_CVar", "GetCVar")
    if type(getCVar) == "nil" then
        return nil
    end
    local value = getCVar(PROBE_CVAR)
    if type(value) ~= "string" or isSecret(value) then
        return nil
    end
    return value
end

---Set the probe CVar through `C_CVar.SetCVar`.
---@param value string
local function writeProbeCVar(value)
    local setCVar = readHostFunction("C_CVar", "SetCVar")
    if type(setCVar) == "nil" then
        error("the client has no C_CVar.SetCVar", 2)
    end
    ---@cast setCVar function
    setCVar(PROBE_CVAR, value)
end

---Flip the probe CVar between "1" and "0". The first flip of a test schedules
---the original value's restore for the After hook.
---@param ctx TestKit.Context
local function flipProbeCVar(ctx)
    local current = currentProbeValue()
    if type(current) == "nil" then
        ctx:Fail("C_CVar.GetCVar is missing or does not know the CVar " .. PROBE_CVAR)
    end
    ---@cast current string
    if #pendingRestores == 0 then
        local original = current
        pendingRestores[#pendingRestores + 1] = function()
            if currentProbeValue() ~= original then
                writeProbeCVar(original)
            end
        end
    end
    writeProbeCVar(current == "1" and "0" or "1")
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
    local file, line = position:match("^(.-):(%d+): ")
    return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
---@return integer
local function currentLine()
    local _, position = pcall(error, "", 3)
    local _, line = splitPosition(position or "")
    return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
    ctx:Expect(type(message)):ToBe("string")
    if type(message) ~= "string" then
        return nil
    end
    local file, line = splitPosition(message)
    ctx:Expect(type(file)):ToBe("string")
    ctx:Expect((file or ""):sub(-#"CacheKitSuite.lua")):ToBe("CacheKitSuite.lua")
    return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
    local succeeded, message = pcall(raise)
    ctx:Expect(succeeded):ToBe(false)
    ctx:Log("client message: " .. tostring(message))

    local line = expectThisFile(ctx, message)
    ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
    ctx:Expect(line):ToBe(lineBox.start + 1)
end

-- Allocation ----------------------------------------------------------------------------------

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
    local before = collectgarbage("count")
    work()
    return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
    collectgarbage("collect")
    ctx:Yield()
end

---Collect in a step of its own, measure `work`, log the delta and hold it to
---the tolerance.
---@param ctx TestKit.Context
---@param label string what `work` does, for the log
---@param work fun()
local function expectNoAllocation(ctx, label, work)
    collectBeforeMeasuring(ctx)
    local grownKilobytes = measureAllocation(work)
    ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- cacheKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
    "Registry:Get('cacheKit', 1) is the CacheKit facade with API 1, its six constructors, SetLimits, GetLimits and UNBOUNDED",
    function(ctx)
        ctx:Expect(type(CacheKit)):ToBe("table")
        ctx:Expect(rawget(CacheKit, "API")):ToBe(CACHE_KIT_API)
        for _, methodName in ipairs({
            "NewLru",
            "NewTtl",
            "Memoize",
            "NewSnapshot",
            "Lazy",
            "NewQueue",
            "SetLimits",
            "GetLimits",
        }) do
            ctx:Expect(type(CacheKit[methodName])):ToBe("function")
        end
        ctx:Expect(type(CacheKit.UNBOUNDED)):ToBe("table")
        local limits = CacheKit:GetLimits()
        ctx:Expect(type(limits.maxQueueCapacity)):ToBe("number")
        ctx:Log(("maxQueueCapacity in this session: %d"):format(limits.maxQueueCapacity))
    end
)

facade:Test("the installed CacheKit carries the revision of the committed manifest", function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
        ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
        return
    end
    for _, expected in ipairs(expectedPackages) do
        if expected.id == PACKAGE_ID then
            local _, revision = Registry:Get(PACKAGE_ID, CACHE_KIT_API)
            ctx:Expect(revision):ToBe(expected.revision)
            ctx:Expect(rawget(CacheKit, "REVISION")):ToBe(expected.revision)
            return
        end
    end
    ctx:Fail("Expected.lua does not list cacheKit")
end)

facade:Test(
    "the client has GetTimePreciseSec, so age limits are live, and EventKit API 1 is loaded for ClearOn",
    function(ctx)
        local first = now()
        local second = now()
        ctx:Expect(type(first)):ToBe("number")
        ctx:Expect(second >= first):ToBe(true)
        local EventKit, revisionOrReason = Registry:Find("eventKit", EVENT_KIT_API)
        ctx:Log("Registry:Find('eventKit', 1) revision or reason: " .. tostring(revisionOrReason))
        ctx:Expect(type(EventKit)):ToBe("table")
    end
)

-- cacheKit.ttl --------------------------------------------------------------------------------

local ttl = newSuite("ttl")

ttl:Test(
    "a NewTtl entry with a 0.3-second limit is present halfway and gone once GetTimePreciseSec passes 0.3 seconds after Set",
    function(ctx)
        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = TTL_SECONDS }))
        local storedFrom = now()
        cache:Set("probe", "value")
        local storedUntil = now()

        ctx:Expect(cache:Get("probe")):ToBe("value")
        waitForClock(ctx, storedFrom + TTL_SECONDS / 2)
        local halfway = cache:Get("probe")
        local halfwayReadAt = now()
        requireReadBeforeExpiry(ctx, storedFrom, halfwayReadAt, TTL_SECONDS)
        ctx:Expect(halfway):ToBe("value")

        waitForClock(ctx, storedUntil + TTL_SECONDS)
        local goneAt = now()
        ctx:Log(
            ("present at %s after Set, absent at %s after Set"):format(
                milliseconds(halfwayReadAt - storedFrom),
                milliseconds(goneAt - storedFrom)
            )
        )
        -- Peek reports the expired entry as absent but leaves it stored; Get removes it.
        ctx:Expect(cache:Peek("probe")):ToBeNil()
        ctx:Expect(cache:GetCount()):ToBe(1)
        ctx:Expect(cache:Get("probe")):ToBeNil()
        ctx:Expect(cache:GetCount()):ToBe(0)
        local stats = cache:GetStats()
        ctx:Expect(stats.hits):ToBe(2)
        ctx:Expect(stats.misses):ToBe(1)
        ctx:Expect(stats.evictions):ToBe(0)
    end
)

ttl:Test(
    "setting the key again restarts its age: set again at 0.2 seconds, it is still present 0.3 seconds after the first Set",
    function(ctx)
        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = TTL_SECONDS }))
        local firstSetAt = now()
        cache:Set("probe", "first")

        waitForClock(ctx, firstSetAt + 2 * TTL_SECONDS / 3)
        local secondSetFrom = now()
        cache:Set("probe", "second")
        local secondSetUntil = now()

        waitForClock(ctx, firstSetAt + TTL_SECONDS)
        local stillThere = cache:Get("probe")
        local readAt = now()
        requireReadBeforeExpiry(ctx, secondSetFrom, readAt, TTL_SECONDS)
        ctx:Expect(stillThere):ToBe("second")

        waitForClock(ctx, secondSetUntil + TTL_SECONDS)
        ctx:Log(
            ("second Set at %s, read at %s, gone at %s, all after the first Set"):format(
                milliseconds(secondSetFrom - firstSetAt),
                milliseconds(readAt - firstSetAt),
                milliseconds(now() - firstSetAt)
            )
        )
        ctx:Expect(cache:Get("probe")):ToBeNil()
    end
)

ttl:Test(
    "a 0.2-second negative entry answers nil and 'negative' as a hit, then expires on the real clock while an ordinary entry of its 60-second cache stays",
    function(ctx)
        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = LONG_TTL_SECONDS }))
        cache:Set("known", "value")
        local storedFrom = now()
        cache:PutNegative("nobody", NEGATIVE_TTL_SECONDS)
        local storedUntil = now()

        local value, outcome = cache:Get("nobody")
        local readAt = now()
        requireReadBeforeExpiry(ctx, storedFrom, readAt, NEGATIVE_TTL_SECONDS)
        ctx:Expect(value):ToBeNil()
        ctx:Expect(outcome):ToBe("negative")
        local peeked, peekOutcome = cache:Peek("nobody")
        ctx:Expect(peeked):ToBeNil()
        ctx:Expect(peekOutcome):ToBe("negative")
        ctx:Expect(cache:GetStats().hits):ToBe(1)
        ctx:Expect(cache:GetCount()):ToBe(2)

        waitForClock(ctx, storedUntil + NEGATIVE_TTL_SECONDS)
        ctx:Log(
            ("negative entry gone at %s after PutNegative"):format(milliseconds(now() - storedFrom))
        )
        value, outcome = cache:Get("nobody")
        ctx:Expect(value):ToBeNil()
        ctx:Expect(outcome):ToBeNil()
        ctx:Expect(cache:GetStats().misses):ToBe(1)
        ctx:Expect(cache:Get("known")):ToBe("value")
        ctx:Expect(cache:GetCount()):ToBe(1)
    end
)

-- cacheKit.memoize ----------------------------------------------------------------------------

local memoize = newSuite("memoize")

memoize:Test(
    "Memoize over C_Item.GetItemInfoInstant reads the Hearthstone (6948) once and answers the second call with the same table",
    function(ctx)
        local getItemInfoInstant = requireItemInfoInstant(ctx)
        local reads = 0
        local itemShape, cache = CacheKit:Memoize(function(itemId)
            reads = reads + 1
            return readItemShape(getItemInfoInstant, itemId)
        end, {
            maxEntries = 8,
            cacheable = function(shape)
                return shape.itemId ~= false
            end,
        })
        track(cache)

        local first = itemShape(HEARTHSTONE_ITEM_ID)
        local second = itemShape(HEARTHSTONE_ITEM_ID)
        local direct = readItemShape(getItemInfoInstant, HEARTHSTONE_ITEM_ID)
        ctx:Log(
            ("C_Item.GetItemInfoInstant(%d): icon %s, class %s"):format(
                HEARTHSTONE_ITEM_ID,
                tostring(direct.icon),
                tostring(direct.classId)
            )
        )
        ctx:Expect(first.itemId):ToBe(HEARTHSTONE_ITEM_ID)
        ctx:Expect(second):ToBe(first)
        ctx:Expect(direct).Not:ToBe(first)
        ctx:Expect(first):ToEqual(direct)
        ctx:Expect(reads):ToBe(1)
        ctx:Expect(cache:GetCount()):ToBe(1)
        ctx:Expect(cache:GetStats().hits):ToBe(1)
        ctx:Expect(cache:GetStats().misses):ToBe(1)
    end
)

memoize:Test(
    "cacheable keeps item 0, which C_Item.GetItemInfoInstant answers with nothing, out of the cache, so the client is asked on every call",
    function(ctx)
        local getItemInfoInstant = requireItemInfoInstant(ctx)
        local reads = 0
        local predicateCalls = 0
        local itemShape, cache = CacheKit:Memoize(function(itemId)
            reads = reads + 1
            return readItemShape(getItemInfoInstant, itemId)
        end, {
            maxEntries = 8,
            cacheable = function(shape, itemId)
                predicateCalls = predicateCalls + 1
                ctx:Expect(type(itemId)):ToBe("number")
                return shape.itemId ~= false
            end,
        })
        track(cache)

        ctx:Expect(itemShape(MISSING_ITEM_ID).itemId):ToBe(false)
        ctx:Expect(itemShape(MISSING_ITEM_ID).itemId):ToBe(false)
        ctx:Expect(reads):ToBe(2)
        ctx:Expect(predicateCalls):ToBe(2)
        ctx:Expect(cache:GetCount()):ToBe(0)

        -- The same memo remembers an item the client knows.
        itemShape(HEARTHSTONE_ITEM_ID)
        itemShape(HEARTHSTONE_ITEM_ID)
        ctx:Expect(reads):ToBe(3)
        ctx:Expect(cache:GetCount()):ToBe(1)
    end
)

memoize:Test(
    "Memoize with a 0.3-second limit over C_Spell.GetSpellInfo hands back Auto Attack's (6603) info table until the limit passes, then asks the client again",
    function(ctx)
        local getSpellInfo = readHostFunction("C_Spell", "GetSpellInfo")
        if type(getSpellInfo) == "nil" then
            Harness:SkipTest(ctx, "the client has no C_Spell.GetSpellInfo")
        end
        ---@cast getSpellInfo function
        local reads = 0
        local spellInfo, cache = CacheKit:Memoize(function(spellId)
            reads = reads + 1
            return getSpellInfo(spellId)
        end, {
            maxEntries = 8,
            ttlSeconds = TTL_SECONDS,
            cacheable = function(info)
                return type(info) == "table" and type(info.name) == "string"
            end,
        })
        track(cache)

        local storedFrom = now()
        local first = spellInfo(AUTO_ATTACK_SPELL_ID)
        local storedUntil = now()
        ctx:Expect(type(first)):ToBe("table")
        ctx:Log(
            ("C_Spell.GetSpellInfo(%d).name: %s"):format(AUTO_ATTACK_SPELL_ID, tostring(first.name))
        )
        local second = spellInfo(AUTO_ATTACK_SPELL_ID)
        requireReadBeforeExpiry(ctx, storedFrom, now(), TTL_SECONDS)
        ctx:Expect(second):ToBe(first)
        ctx:Expect(reads):ToBe(1)

        waitForClock(ctx, storedUntil + TTL_SECONDS)
        local third = spellInfo(AUTO_ATTACK_SPELL_ID)
        ctx:Expect(reads):ToBe(2)
        ctx:Expect(third).Not:ToBe(first)
        ctx:Expect(third.name):ToBe(first.name)
    end
)

-- cacheKit.clearOn ----------------------------------------------------------------------------

local clearOn = newSuite("clearOn")

clearOn:Test(
    "ClearOn('CVAR_UPDATE') empties the cache inside C_CVar.SetCVar of chatBubbles, every time, and leaves a cache without ClearOn alone",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 8 }))
        local bystander = track(CacheKit:NewLru({ maxEntries = 8 }))
        cache:Set("a", 1)
        cache:Set("b", 2)
        cache:Get("a")
        bystander:Set("kept", true)

        ctx:Expect(cache:ClearOn(CVAR_EVENT)):ToBe(true)
        ctx:Expect(cache:ClearOn(CVAR_EVENT)):ToBe(false)
        ctx:Expect(cache:GetCount()):ToBe(2)

        flipProbeCVar(ctx)
        ctx:Log("entries right after the first SetCVar returned: " .. cache:GetCount())
        ctx:Expect(cache:GetCount()):ToBe(0)
        ctx:Expect(cache:Get("a")):ToBeNil()
        -- Clearing keeps the statistics: one hit before, one miss just now.
        ctx:Expect(cache:GetStats().hits):ToBe(1)
        ctx:Expect(cache:GetStats().misses):ToBe(1)
        ctx:Expect(bystander:Get("kept")):ToBe(true)

        cache:Set("c", 3)
        flipProbeCVar(ctx)
        ctx:Expect(cache:GetCount()):ToBe(0)
        ctx:Expect(bystander:GetCount()):ToBe(1)
    end
)

clearOn:Test(
    "a cache closed after ClearOn stays closed and empty through a later chatBubbles change that still clears an open cache on the same event",
    function(ctx)
        local closing = track(CacheKit:NewLru({ maxEntries = 8 }))
        ctx:Expect(closing:ClearOn(CVAR_EVENT)):ToBe(true)
        -- A second cache on the same event shows that the event still arrives.
        local witness = track(CacheKit:NewLru({ maxEntries = 8 }))
        ctx:Expect(witness:ClearOn(CVAR_EVENT)):ToBe(true)
        witness:Set("w", true)

        ctx:Expect(closing:Close()):ToBe(true)
        flipProbeCVar(ctx)
        ctx:Expect(witness:GetCount()):ToBe(0)
        ctx:Expect(closing:IsClosed()):ToBe(true)
        ctx:Expect(closing:GetCount()):ToBe(0)
        ctx:Expect(closing:Close()):ToBe(false)
    end
)

clearOn:Test(
    "ClearOn with an event name the client does not know is refused at the calling line with EventKit's reason, and a retry is refused the same way",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 8 }))
        local expectedStart = "CacheKit.Cache:ClearOn could not connect " .. UNKNOWN_EVENT .. ": "
        for attempt = 1, 2 do
            local startLine = 0
            local succeeded, message = pcall(function()
                startLine = currentLine()
                cache:ClearOn(UNKNOWN_EVENT)
            end)
            ctx:Expect(succeeded):ToBe(false)
            ctx:Log(("attempt %d: %s"):format(attempt, tostring(message)))
            local line = expectThisFile(ctx, message)
            ctx:Expect(line):ToBe(startLine + 1)
            ctx:Expect(tostring(message):find(expectedStart, 1, true) ~= nil):ToBe(true)
        end
        -- The refusal kept nothing: the same cache still connects a real event.
        ctx:Expect(cache:ClearOn(CVAR_EVENT)):ToBe(true)
    end
)

-- cacheKit.lazy -------------------------------------------------------------------------------

local lazy = newSuite("lazy")

lazy:Test(
    "a Lazy tree resolves each path once, and Invalidate forgets the path's descendants and its ancestors' values but not a sibling",
    function(ctx)
        local resolved = {}
        local tree = track(CacheKit:Lazy(function(...)
            local path = table.concat({ ... }, "/")
            resolved[path] = (resolved[path] or 0) + 1
            return "value of " .. path
        end, { maxEntries = 16 }))

        ctx:Expect(tree:Get("a")):ToBe("value of a")
        ctx:Expect(tree:Get("a", "b", "c")):ToBe("value of a/b/c")
        ctx:Expect(tree:Get("a", "x")):ToBe("value of a/x")
        ctx:Expect(tree:Get("a", "b", "c")):ToBe("value of a/b/c")
        ctx:Expect(resolved["a/b/c"]):ToBe(1)
        ctx:Expect(tree:GetCount()):ToBe(3)
        ctx:Expect(tree:GetStats().hits):ToBe(1)
        ctx:Expect(tree:GetStats().misses):ToBe(3)

        ctx:Expect(tree:Invalidate("a", "b")):ToBe(2)
        ctx:Expect(tree:Peek("a", "b", "c")):ToBeNil()
        ctx:Expect(tree:Peek("a")):ToBeNil()
        ctx:Expect(tree:Peek("a", "x")):ToBe("value of a/x")
        ctx:Expect(tree:GetCount()):ToBe(1)

        tree:Get("a", "b", "c")
        tree:Get("a")
        ctx:Expect(resolved["a/b/c"]):ToBe(2)
        ctx:Expect(resolved["a"]):ToBe(2)
        ctx:Expect(resolved["a/x"]):ToBe(1)
    end
)

lazy:Test(
    "a Lazy tree over C_Item.GetItemInfoInstant expands ('item', 6948, 'icon') on first read and keeps item 0's nil answer out of the tree",
    function(ctx)
        local getItemInfoInstant = requireItemInfoInstant(ctx)
        local reads = 0
        local tree = track(CacheKit:Lazy(function(kind, itemId, field)
            if kind ~= "item" then
                return nil
            end
            reads = reads + 1
            local shape = readItemShape(getItemInfoInstant, itemId)
            if shape.itemId == false then
                return nil
            end
            return shape[field]
        end))

        local icon = tree:Get("item", HEARTHSTONE_ITEM_ID, "icon")
        ctx:Expect(icon).Not:ToBeNil()
        ctx:Expect(tree:Get("item", HEARTHSTONE_ITEM_ID, "icon")):ToBe(icon)
        ctx:Expect(reads):ToBe(1)

        ctx:Expect(tree:Get("item", MISSING_ITEM_ID, "icon")):ToBeNil()
        ctx:Expect(tree:Get("item", MISSING_ITEM_ID, "icon")):ToBeNil()
        ctx:Expect(reads):ToBe(3)
        ctx:Expect(tree:GetCount()):ToBe(1)
    end
)

lazy:Test(
    "a Lazy tree of maxEntries 2 forgets the least recently read path when a third expands, counting one eviction",
    function(ctx)
        local tree = track(CacheKit:Lazy(function(part)
            return part
        end, { maxEntries = 2 }))
        tree:Get("first")
        tree:Get("second")
        tree:Get("first")
        tree:Get("third")

        ctx:Expect(tree:GetCount()):ToBe(2)
        ctx:Expect(tree:Peek("second")):ToBeNil()
        ctx:Expect(tree:Peek("first")):ToBe("first")
        ctx:Expect(tree:Peek("third")):ToBe("third")
        ctx:Expect(tree:GetStats().evictions):ToBe(1)
    end
)

-- cacheKit.queue ------------------------------------------------------------------------------

local queue = newSuite("queue")

queue:Test(
    "on a full queue of capacity 2, dropOldest stores and returns the oldest, dropNewest returns the value pushed, and reject returns false",
    function(ctx)
        local dropOldest = CacheKit:NewQueue(2, "dropOldest")
        local dropNewest = CacheKit:NewQueue(2, "dropNewest")
        local reject = CacheKit:NewQueue(2, "reject")
        for _, ring in ipairs({ dropOldest, dropNewest, reject }) do
            ctx:Expect(ring:Push("one")):ToBe(true)
            ctx:Expect(ring:Push("two")):ToBe(true)
        end

        local stored, dropped = dropOldest:Push("three")
        ctx:Expect(stored):ToBe(true)
        ctx:Expect(dropped):ToBe("one")
        ctx:Expect(dropOldest:Peek()):ToBe("two")

        stored, dropped = dropNewest:Push("three")
        ctx:Expect(stored):ToBe(false)
        ctx:Expect(dropped):ToBe("three")
        ctx:Expect(dropNewest:Peek()):ToBe("one")

        stored, dropped = reject:Push("three")
        ctx:Expect(stored):ToBe(false)
        ctx:Expect(dropped):ToBeNil()
        ctx:Expect(reject:GetCount()):ToBe(2)
        ctx:Expect(reject:GetCapacity()):ToBe(2)
    end
)

queue:Test(
    "Push and Pop keep first-in first-out order across the ring's wrap-around, and Iterate walks oldest to newest from position 1",
    function(ctx)
        local ring = CacheKit:NewQueue(3, "reject")
        ring:Push(1)
        ring:Push(2)
        ctx:Expect(ring:Pop()):ToBe(1)
        ring:Push(3)
        ring:Push(false)
        ctx:Expect(ring:GetCount()):ToBe(3)

        local positions, values = {}, {}
        for position, value in ring:Iterate() do
            positions[#positions + 1] = position
            values[#values + 1] = value
        end
        ctx:Expect(positions):ToEqual({ 1, 2, 3 })
        ctx:Expect(values):ToEqual({ 2, 3, false })

        ctx:Expect(ring:Pop()):ToBe(2)
        ctx:Expect(ring:Pop()):ToBe(3)
        ctx:Expect(ring:Pop()):ToBe(false)
        ctx:Expect(ring:Pop()):ToBeNil()
        ctx:Expect(ring:GetCount()):ToBe(0)
        ring:Push("again")
        ctx:Expect(ring:Clear()):ToBe(1)
        ctx:Expect(ring:Peek()):ToBeNil()
    end
)

-- cacheKit.allocation -------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
    "Get hits, a Get miss, Peek and Set of a stored key on a full NewLru cache allocate nothing over 5000 cycles",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 4 }))
        for index = 1, 4 do
            cache:Set(index, index)
        end
        -- GetStats allocates its table once per cache; take that out of the measurement.
        cache:GetStats()

        expectNoAllocation(ctx, "5000 NewLru cycles", function()
            for cycle = 1, ALLOCATION_CYCLES do
                cache:Get(1)
                cache:Get(4)
                cache:Get("missing")
                cache:Peek(2)
                cache:Set(3, cycle)
            end
        end)
        ctx:Expect(cache:GetCount()):ToBe(4)
        ctx:Expect(cache:GetStats().evictions):ToBe(0)
    end
)

allocation:Test(
    "a NewTtl Get hit, a negative-entry Get and PutNegative and Set over stored keys allocate nothing over 5000 cycles",
    function(ctx)
        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = LONG_TTL_SECONDS }))
        cache:Set("known", 1)
        cache:PutNegative("nobody", LONG_TTL_SECONDS)

        expectNoAllocation(ctx, "5000 NewTtl cycles", function()
            for cycle = 1, ALLOCATION_CYCLES do
                cache:Get("known")
                cache:Get("nobody")
                cache:PutNegative("nobody", LONG_TTL_SECONDS)
                cache:Set("known", cycle)
            end
        end)
        local value, outcome = cache:Get("nobody")
        ctx:Expect(value):ToBeNil()
        ctx:Expect(outcome):ToBe("negative")
        ctx:Expect(cache:GetCount()):ToBe(2)
    end
)

allocation:Test(
    "a memoised hit on a C_Item.GetItemInfoInstant memo with cacheable allocates nothing over 5000 calls",
    function(ctx)
        local getItemInfoInstant = requireItemInfoInstant(ctx)
        local reads = 0
        local itemShape, cache = CacheKit:Memoize(function(itemId)
            reads = reads + 1
            return readItemShape(getItemInfoInstant, itemId)
        end, {
            cacheable = function(shape)
                return shape.itemId ~= false
            end,
        })
        track(cache)
        itemShape(HEARTHSTONE_ITEM_ID)

        expectNoAllocation(ctx, "5000 memoised hits", function()
            for _ = 1, ALLOCATION_CYCLES do
                itemShape(HEARTHSTONE_ITEM_ID)
            end
        end)
        ctx:Expect(reads):ToBe(1)
    end
)

allocation:Test(
    "a Lazy tree Get hit on a three-part path allocates nothing over 5000 reads",
    function(ctx)
        local tree = track(CacheKit:Lazy(function()
            return true
        end))
        tree:Get("profile", "unitFrames", 1)
        tree:GetStats()

        expectNoAllocation(ctx, "5000 lazy hits", function()
            for _ = 1, ALLOCATION_CYCLES do
                tree:Get("profile", "unitFrames", 1)
            end
        end)
        ctx:Expect(tree:GetStats().misses):ToBe(1)
    end
)

allocation:Test(
    "Push onto a full dropOldest queue and Pop allocate nothing over 5000 cycles",
    function(ctx)
        local ring = CacheKit:NewQueue(8, "dropOldest")
        for index = 1, 8 do
            ring:Push(index)
        end

        expectNoAllocation(ctx, "5000 queue cycles", function()
            for cycle = 1, ALLOCATION_CYCLES do
                ring:Push(cycle)
                ring:Pop()
                ring:Push(cycle)
            end
        end)
        ctx:Expect(ring:GetCount()):ToBe(8)
    end
)

allocation:Test("500 full Iterate walks over a queue of 64 values allocate nothing", function(ctx)
    local ring = CacheKit:NewQueue(ITERATE_QUEUE_SIZE, "reject")
    for index = 1, ITERATE_QUEUE_SIZE do
        ring:Push(index)
    end
    local steps = 0

    expectNoAllocation(ctx, "500 Iterate walks", function()
        for _ = 1, ITERATE_WALKS do
            for _ in ring:Iterate() do
                steps = steps + 1
            end
        end
    end)
    ctx:Expect(steps):ToBe(ITERATE_QUEUE_SIZE * ITERATE_WALKS)
end)

-- cacheKit.errors -----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test("NewLru without maxEntries names CacheKitSuite.lua at the calling line", function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        CacheKit:NewLru({})
    end, lines, "CacheKit:NewLru maxEntries is required")
end)

errors:Test("NewTtl with ttlSeconds 0 names CacheKitSuite.lua at the calling line", function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 0 })
    end, lines, "CacheKit:NewTtl ttlSeconds must be a finite number greater than zero")
end)

errors:Test(
    "a nil key, a closed cache's Set and a cache method called with UIParent are each refused at the calling line",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 4 }))
        local get = cache.Get
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            cache:Get(nil)
        end, lines, "CacheKit.Cache:Get key must not be nil")
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            get(uiParent, "key")
        end, lines, "CacheKit.Cache:Get must be called on a CacheKit cache")
        cache:Close()
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            cache:Set("key", 1)
        end, lines, "CacheKit.Cache:Set cannot write to a closed cache")
    end
)

errors:Test(
    "PutNegative on a NewLru cache is refused at the calling line because nothing would expire it",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 4 }))
        local lines = { start = 0 }
        expectErrorAtCallingLine(
            ctx,
            function()
                lines.start = currentLine()
                cache:PutNegative("nobody", 1)
            end,
            lines,
            "CacheKit.Cache:PutNegative requires a cache with an age limit (CacheKit:NewTtl, or CacheKit:Memoize with ttlSeconds)"
        )
        ctx:Expect(cache:GetCount()):ToBe(0)
    end
)

errors:Test(
    "a memoised function called with a table key names CacheKitSuite.lua at the calling line and never runs",
    function(ctx)
        local runs = 0
        local memoised, cache = CacheKit:Memoize(function()
            runs = runs + 1
            return true
        end)
        track(cache)
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            memoised(uiParent)
        end, lines, "CacheKit memoized function key must be a string or a number")
        ctx:Expect(runs):ToBe(0)
    end
)

errors:Test(
    "NewQueue with an unknown overflow policy or a capacity above maxQueueCapacity is refused at the calling line",
    function(ctx)
        local maxCapacity = CacheKit:GetLimits().maxQueueCapacity
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:NewQueue(4, "dropAll")
        end, lines, 'CacheKit:NewQueue overflow must be "dropOldest", "dropNewest" or "reject"')
        expectErrorAtCallingLine(
            ctx,
            function()
                lines.start = currentLine()
                CacheKit:NewQueue(maxCapacity + 1, "reject")
            end,
            lines,
            ("CacheKit:NewQueue capacity must be an integer from 1 to %d (CacheKit:SetLimits maxQueueCapacity)"):format(
                maxCapacity
            )
        )
    end
)

errors:Test(
    "a Lazy path part that is a table, a nil queue value and Get on a closed tree are each refused at the calling line",
    function(ctx)
        local tree = track(CacheKit:Lazy(function()
            return true
        end))
        local ring = CacheKit:NewQueue(2, "reject")
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            tree:Get("profile", uiParent)
        end, lines, "CacheKit.LazyTree:Get path part 2 must be a string or a number")
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            ring:Push(nil)
        end, lines, "CacheKit.Queue:Push value must not be nil")
        tree:Close()
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            tree:Get("profile")
        end, lines, "CacheKit.LazyTree:Get cannot expand a closed tree")
        ctx:Expect(ring:GetCount()):ToBe(0)
    end
)

-- cacheKit.secrets ----------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
    "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
    if SECRETS_AVAILABLE then
        secrets:Test(name, body)
    else
        secrets:Skip(name, SECRETS_SKIP_REASON)
    end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
    local succeeded, secret = pcall(secretWrap, value)
    if not succeeded then
        ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
    end
    if isSecretValue(secret) ~= true then
        ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
    end
    return secret
end

---Check that `received` is still secret and of the secret's type. Identity
---cannot be checked: comparing a secret with a value of its own type raises,
---`rawequal(secret, secret)` included (measured on Retail 12.1.0 b69933).
---@param ctx TestKit.Context
---@param received any
---@param secret any
local function expectSameSecret(ctx, received, secret)
    ctx:Expect(isSecretValue(received)):ToBe(true)
    ctx:Expect(type(received)):ToBe(type(secret))
end

---Describe a pcall outcome for the log without formatting a secret.
---@param ok boolean
---@param value any
---@return string
local function describeOutcome(ok, value)
    if not ok then
        return "raised: " .. tostring(value)
    end
    if isSecretValue(value) then
        return "returned a secret " .. type(value)
    end
    return "returned " .. type(value) .. " " .. tostring(value)
end

secretTest(
    "the client's handling of secrets is logged: rawequal, ==, type, table keys, and CacheKit's read paths",
    function(ctx)
        local secret = makeSecret(ctx, 42)
        local plainTable = {}
        ctx:Log("type(secret): " .. type(secret))
        ctx:Log("rawequal(secret, secret): " .. describeOutcome(pcall(rawequal, secret, secret)))
        ctx:Log("rawequal(secret, {}): " .. describeOutcome(pcall(rawequal, secret, plainTable)))
        ctx:Log("rawequal({}, secret): " .. describeOutcome(pcall(rawequal, plainTable, secret)))
        ctx:Log("secret == nil: " .. describeOutcome(pcall(function()
            return secret == nil
        end)))
        ctx:Log("type(secret) == 'nil': " .. describeOutcome(pcall(function()
            return type(secret) == "nil"
        end)))
        ctx:Log("plainTable[secret] read: " .. describeOutcome(pcall(function()
            return plainTable[secret]
        end)))
        ctx:Log("select('#', secret): " .. describeOutcome(pcall(select, "#", secret)))

        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = LONG_TTL_SECONDS }))
        ctx:Log(
            "cache:Set(key, secret): " .. describeOutcome(pcall(cache.Set, cache, "health", secret))
        )
        ctx:Log("cache:Get(key): " .. describeOutcome(pcall(cache.Get, cache, "health")))
        ctx:Log("cache:Peek(key): " .. describeOutcome(pcall(cache.Peek, cache, "health")))
        local probeQueue = CacheKit:NewQueue(4, "reject")
        ctx:Log(
            "queue:Push(secret): " .. describeOutcome(pcall(probeQueue.Push, probeQueue, secret))
        )
        ctx:Log("queue:Pop(): " .. describeOutcome(pcall(probeQueue.Pop, probeQueue)))
        local memoised, memoCache = CacheKit:Memoize(function()
            return secret
        end)
        track(memoCache)
        ctx:Log("memoised(1) first: " .. describeOutcome(pcall(memoised, 1)))
        ctx:Log("memoised(1) second: " .. describeOutcome(pcall(memoised, 1)))
        ctx:Expect(isSecretValue(secret)):ToBe(true)
    end
)

secretTest(
    "a secret value stored with Set comes back from Get and Peek still secret and untouched",
    function(ctx)
        local cache = track(CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = LONG_TTL_SECONDS }))
        local secret = makeSecret(ctx, 42)
        cache:Set("health", secret)

        local fromGet, getOutcome = cache:Get("health")
        expectSameSecret(ctx, fromGet, secret)
        ctx:Expect(getOutcome):ToBeNil()
        local fromPeek, peekOutcome = cache:Peek("health")
        expectSameSecret(ctx, fromPeek, secret)
        ctx:Expect(peekOutcome):ToBeNil()
        ctx:Expect(cache:GetCount()):ToBe(1)
        ctx:Expect(cache:GetStats().hits):ToBe(1)
    end
)

secretTest(
    "a memoised function that returns a secret hands it back still secret on the second call without running again",
    function(ctx)
        local secret = makeSecret(ctx, "secret name")
        local runs = 0
        local memoised, cache = CacheKit:Memoize(function()
            runs = runs + 1
            return secret
        end)
        track(cache)

        expectSameSecret(ctx, memoised(1), secret)
        expectSameSecret(ctx, memoised(1), secret)
        ctx:Expect(runs):ToBe(1)
        ctx:Expect(cache:GetCount()):ToBe(1)
    end
)

secretTest(
    "a secret value pushed on a queue comes back from Iterate and Pop still secret",
    function(ctx)
        local ring = CacheKit:NewQueue(2, "dropOldest")
        local secret = makeSecret(ctx, 7)
        ctx:Expect(ring:Push(secret)):ToBe(true)
        local walked = 0
        for _, value in ring:Iterate() do
            walked = walked + 1
            expectSameSecret(ctx, value, secret)
        end
        ctx:Expect(walked):ToBe(1)
        expectSameSecret(ctx, ring:Pop(), secret)
        ctx:Expect(ring:GetCount()):ToBe(0)
    end
)

secretTest(
    "a secret maxEntries is refused by NewLru, NewTtl, Memoize and Lazy at the calling line",
    function(ctx)
        local secret = makeSecret(ctx, 8)
        local suffix = " maxEntries must be a positive integer or CacheKit.UNBOUNDED"
        local lines = { start = 0 }
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:NewLru({ maxEntries = secret })
        end, lines, "CacheKit:NewLru" .. suffix)
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:NewTtl({ maxEntries = secret, ttlSeconds = 1 })
        end, lines, "CacheKit:NewTtl" .. suffix)
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:Memoize(tostring, { maxEntries = secret })
        end, lines, "CacheKit:Memoize" .. suffix)
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:Lazy(tostring, { maxEntries = secret })
        end, lines, "CacheKit:Lazy" .. suffix)
    end
)

secretTest(
    "a secret NewQueue capacity and a secret SetLimits maxQueueCapacity are refused at the calling line and the limits stay as they were",
    function(ctx)
        local before = CacheKit:GetLimits().maxQueueCapacity
        local secret = makeSecret(ctx, 16)
        local lines = { start = 0 }
        expectErrorAtCallingLine(
            ctx,
            function()
                lines.start = currentLine()
                CacheKit:NewQueue(secret, "reject")
            end,
            lines,
            ("CacheKit:NewQueue capacity must be an integer from 1 to %d (CacheKit:SetLimits maxQueueCapacity)"):format(
                before
            )
        )
        expectErrorAtCallingLine(ctx, function()
            lines.start = currentLine()
            CacheKit:SetLimits({ maxQueueCapacity = secret })
        end, lines, "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536")
        ctx:Expect(CacheKit:GetLimits().maxQueueCapacity):ToBe(before)
    end
)

secretTest(
    "a snapshot read that fills a secret value fails Refresh at the fill line in CacheKitSuite.lua and keeps nothing",
    function(ctx)
        local secret = makeSecret(ctx, 99)
        local fillLine = 0
        local snapshot = track(CacheKit:NewSnapshot(function(fill)
            fill("plain", 1)
            fillLine = currentLine()
            fill("hidden", secret)
        end))

        local succeeded, message = pcall(snapshot.Refresh, snapshot)
        ctx:Expect(succeeded):ToBe(false)
        ctx:Log("client message: " .. tostring(message))
        local line = expectThisFile(ctx, message)
        ctx:Expect(line):ToBe(fillLine + 1)
        local expected = "CacheKit.Snapshot fill value must not be a secret value"
        ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
        ctx:Expect(snapshot:GetCount()):ToBe(0)
        ctx:Expect(snapshot:Get("plain")):ToBeNil()
    end
)

secretTest(
    "a secret key reaching Get raises the client's own error, as docs/API.md says, and the cache is unchanged",
    function(ctx)
        local cache = track(CacheKit:NewLru({ maxEntries = 4 }))
        cache:Set("plain", 1)
        local secretKey = makeSecret(ctx, "plain")
        local succeeded, message = pcall(cache.Get, cache, secretKey)
        ctx:Log("client message: " .. tostring(message))
        ctx:Expect(succeeded):ToBe(false)
        ctx:Expect(cache:GetCount()):ToBe(1)
        ctx:Expect(cache:Get("plain")):ToBe(1)
    end
)
