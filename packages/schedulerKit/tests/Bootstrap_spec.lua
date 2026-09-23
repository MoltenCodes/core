local TestEnv = require("SchedulerKitTestEnv")

---Load the SchedulerKit source as a copy carrying `revision`, the way an older
---embedded copy of the same file would have loaded first.
---@param revision integer
---@return table SchedulerKit
local function loadSchedulerKitAsRevision(revision)
    local path = nil
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "SchedulerKit")
        local file = io.open(candidate, "r")
        if file ~= nil then
            file:close()
            path = candidate
            break
        end
    end
    assert(path ~= nil, "SchedulerKit.lua is not on package.path")
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    local patched, replacements = text:gsub(
        "local IMPLEMENTATION_REVISION = %d+",
        "local IMPLEMENTATION_REVISION = " .. revision
    )
    assert(replacements == 1, "IMPLEMENTATION_REVISION not found")
    return assert(loadstring(patched, "@" .. path))()
end

describe("SchedulerKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local SchedulerKit = TestEnv.NewPackage()
        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchedulerKit, reloaded)
    end)

    it("preserves live job identity across compatible reload", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(1)
        local steps = 0
        local job = SchedulerKit:Schedule(function(context)
            steps = steps + 1
            context:Yield()
            steps = steps + 1
        end)
        TestEnv.Tick()
        assert.are.equal(1, steps)

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchedulerKit, reloaded)
        TestEnv.Tick()
        assert.are.equal(2, steps)
        assert.are.equal("completed", job:GetState())
    end)

    it("keeps the default TimerKit scope lazy during package bootstrap", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local TimerKit = require("TimerKit")

        local originalCreateScope = TimerKit.CreateScope
        TimerKit.CreateScope = function()
            error("scope creation unavailable", 0)
        end

        package.loaded["SchedulerKit"] = nil
        local ok, SchedulerKit = pcall(function()
            return require("SchedulerKit")
        end)
        assert.is_true(ok)
        assert.are.equal(12, SchedulerKit.REVISION)

        local scope = SchedulerKit:CreateScope()
        assert.is_false(scope:IsClosed())
        local delayedOk = pcall(function()
            scope:After(1, function() end)
        end)
        assert.is_false(delayedOk)
        assert.are.equal(0, scope:GetActiveCount())

        TimerKit.CreateScope = originalCreateScope
        local delayed = scope:After(1, function() end)
        assert.are.equal("delayed", delayed:GetState())
    end)

    it("adopts queues left behind by a revision-3 embedded copy", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("TimerKit")

        local old = Registry:Register("schedulerKit", 1, 3)
        local jobPrototype = {}
        local scopePrototype = {}
        local contextPrototype = {}
        local jobMetatable = { __index = jobPrototype }
        local scopeMetatable = { __index = scopePrototype }
        local contextMetatable = { __index = contextPrototype }
        local lowQueue = { items = {}, head = 1, tail = 0 }
        rawset(old, "API", 1)
        rawset(old, "REVISION", 3)
        rawset(old, "Job", jobPrototype)
        rawset(old, "Scope", scopePrototype)
        rawset(old, "Context", contextPrototype)
        rawset(old, "Priority", { HIGH = 1, NORMAL = 2, LOW = 3, IDLE = 4 })
        rawset(old, "_state", {
            schema = 1,
            addonScopes = {},
            defaultScope = false,
            dispatch = {},
            queues = {
                { items = {}, head = 1, tail = 0 },
                { items = {}, head = 1, tail = 0 },
                lowQueue,
                { items = {}, head = 1, tail = 0 },
            },
            config = {
                frameBudgetMs = 2,
                runawayThresholdMs = 8,
                maxResumesPerFrame = 1000,
            },
            jobMetatable = jobMetatable,
            scopeMetatable = scopeMetatable,
            contextMetatable = contextMetatable,
            yieldToken = {},
            priorityCursor = 1,
            activeCount = 1,
            frame = false,
            driverEnabled = false,
            driverTrampoline = false,
            currentJob = false,
            frameDeadline = false,
        })

        local legacyScope = setmetatable({
            _addonName = nil,
            _closed = false,
            _activeCount = 1,
            _head = false,
            _tail = false,
            _timerScope = false,
            _shutdownSubscription = false,
        }, scopeMetatable)
        local ran = false
        local legacyJob = setmetatable({
            _scope = legacyScope,
            _callback = function()
                ran = true
            end,
            _priority = 3,
            _name = nil,
            _interval = false,
            _state = "pending",
            _errorPresent = false,
            _generation = 1,
            _queued = true,
            _coroutine = false,
            _context = false,
            _delayTimer = false,
            _active = true,
            _scopePrev = false,
            _scopeNext = false,
        }, jobMetatable)
        rawset(legacyJob, "_context", setmetatable({ _job = legacyJob }, contextMetatable))
        rawset(legacyScope, "_head", legacyJob)
        rawset(legacyScope, "_tail", legacyJob)
        lowQueue.items[1] = legacyJob
        lowQueue.tail = 1

        local upgraded = require("SchedulerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(12, upgraded.REVISION)

        -- Revision 4's lane bookkeeping is derived from the inherited queues
        -- rather than assumed empty, so work an older copy had already queued
        -- still runs.
        local state = rawget(upgraded, "_state")
        assert.are.equal(1, rawget(state, "occupiedLaneCount"))
        assert.are.equal(0, rawget(state, "idleGuard"))

        legacyScope:Schedule(function() end)
        TestEnv.Tick()
        assert.is_true(ran)
        assert.are.equal("completed", legacyJob:GetState())
    end)

    it("adds the coalescing family to state left behind by a revision-6 copy", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("TimerKit")

        -- Revision 6 state: every field up to the monotonic frame reading, and
        -- none of the lanes, watch groups or handle metatables revision 7 adds.
        local old = Registry:Register("schedulerKit", 1, 6)
        local scopePrototype = {}
        local scopeMetatable = { __index = scopePrototype }
        rawset(old, "API", 1)
        rawset(old, "REVISION", 6)
        rawset(old, "Job", {})
        rawset(old, "Scope", scopePrototype)
        rawset(old, "Context", {})
        rawset(old, "Priority", { HIGH = 1, NORMAL = 2, LOW = 3, IDLE = 4 })
        rawset(old, "_state", {
            schema = 1,
            addonScopes = {},
            defaultScope = false,
            dispatch = {},
            queues = {
                { items = {}, head = 1, tail = 0 },
                { items = {}, head = 1, tail = 0 },
                { items = {}, head = 1, tail = 0 },
                { items = {}, head = 1, tail = 0 },
            },
            config = { frameBudgetMs = 2, runawayThresholdMs = 8, maxResumesPerFrame = 1000 },
            jobMetatable = {},
            scopeMetatable = scopeMetatable,
            contextMetatable = {},
            yieldToken = {},
            priorityCursor = 1,
            activeCount = 0,
            laneOccupied = { false, false, false, false },
            occupiedLaneCount = 0,
            idleGuard = 0,
            frame = false,
            driverEnabled = false,
            driverTrampoline = false,
            currentJob = false,
            frameDeadline = false,
            frameReading = false,
        })
        -- A scope revision 6 created carries no member links.
        local legacyScope = setmetatable({
            _addonName = nil,
            _closed = false,
            _activeCount = 0,
            _head = false,
            _tail = false,
            _timerScope = false,
            _shutdownSubscription = false,
        }, scopeMetatable)

        local upgraded = require("SchedulerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(12, upgraded.REVISION)
        local state = rawget(upgraded, "_state")
        assert.are.same({}, rawget(state, "lanes"))
        assert.are.equal(0, rawget(state, "laneCount"))
        assert.are.equal(0, rawget(state, "watchGroupCount"))
        assert.is_false(rawget(state, "familyTimerScope"))

        local calls = 0
        local debounced = legacyScope:Debounce(function()
            calls = calls + 1
        end, 0)
        local watcher = legacyScope:Watch(function() end, 1, function() end)
        debounced()
        -- Native timer 1 is the watch ticker; the debounce armed the second.
        TestEnv.FireNative(2)
        assert.are.equal(1, calls)

        assert.is_true(legacyScope:Close())
        assert.is_true(debounced:IsClosed())
        assert.is_false(watcher:IsActive())
    end)

    it("upgrades revision-7 lanes in place, adopting lanes without an admitted set", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("TimerKit")

        local old = loadSchedulerKitAsRevision(7)
        assert.are.equal(7, old.REVISION)
        local lane = old:Lane("upgraded", { retry = { attempts = 2, backoffSeconds = 1 } })
        -- Revision 7 lanes kept no admitted set.
        rawset(lane, "_admitted", nil)

        package.loaded["SchedulerKit"] = nil
        local upgraded = require("SchedulerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(12, upgraded.REVISION)
        assert.are.equal(lane, upgraded:Lane("upgraded"))

        local job = lane:Submit(function()
            error("again")
        end)
        TestEnv.Tick()
        assert.are.equal("delayed", job:GetState())
        lane:Close()
        assert.are.equal("cancelled", job:GetState())
    end)

    it("upgrades a revision-9 copy and releases its shutdown subscriptions", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("TimerKit")

        -- Revision 9 required LifecycleKit and subscribed each addon scope to
        -- its addon's shutdown. The copy below stands in for it: its addon
        -- scopes are given the subscription revision 9 would have stored, and
        -- the second one fails to disconnect, which must not stop the upgrade.
        local old = loadSchedulerKitAsRevision(9)
        local disconnects = 0
        local carried = old:ForAddon("Carried")
        local failing = old:ForAddon("Failing")
        rawset(carried, "_shutdownSubscription", {
            Disconnect = function()
                disconnects = disconnects + 1
                return true
            end,
        })
        rawset(failing, "_shutdownSubscription", {
            Disconnect = function()
                error("lifecycle gone", 0)
            end,
        })
        local ran = 0
        local job = carried:Schedule(function()
            ran = ran + 1
        end)

        package.loaded["SchedulerKit"] = nil
        local upgraded = require("SchedulerKit")

        assert.are.equal(old, upgraded)
        assert.are.equal(12, upgraded.REVISION)
        assert.are.equal(1, disconnects)
        assert.is_nil(rawget(carried, "_shutdownSubscription"))
        assert.is_nil(rawget(failing, "_shutdownSubscription"))

        -- The carried scope stays canonical and open, and its work still runs.
        assert.are.equal(carried, upgraded:ForAddon("Carried"))
        assert.is_false(carried:IsClosed())
        TestEnv.Tick()
        assert.are.equal(1, ran)
        assert.are.equal("completed", job:GetState())

        -- The two-step replaces the subscription.
        local pending = carried:Schedule(function() end)
        assert.is_true(upgraded:CloseAddonScopes("Carried"))
        assert.is_true(carried:IsClosed())
        assert.are.equal("cancelled", pending:GetState())
        assert.is_true(upgraded:CloseAddonScopes("Failing"))
    end)

    it("seeds the default limits into state a revision-10 copy wrote", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("TimerKit")

        local old = loadSchedulerKitAsRevision(10)
        rawset(old._state, "limits", nil)
        rawset(old._state, "unbounded", nil)

        package.loaded["SchedulerKit"] = nil
        local upgraded = require("SchedulerKit")

        assert.are.equal(old, upgraded)
        assert.are.equal("table", type(upgraded.UNBOUNDED))
        assert.are.same({
            maxLanes = 32,
            maxWatchIntervals = 32,
            maxWatchersPerInterval = 128,
            maxDebounceArguments = 8,
        }, upgraded:GetLimits())
    end)

    it("keeps live family handles working across a compatible reload", function()
        local SchedulerKit = TestEnv.NewPackage()
        local received = nil
        local debounced = SchedulerKit:Debounce(function(value)
            received = value
        end, 1)
        local lane = SchedulerKit:Lane("reload")
        debounced("before reload")

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchedulerKit, reloaded)
        assert.are.equal(lane, reloaded:Lane("reload"))
        TestEnv.AdvanceMs(1000)
        TestEnv.FireNative(1)
        assert.are.equal("before reload", received)
    end)

    it("releases terminal execution-only references", function()
        local SchedulerKit = TestEnv.NewPackage()
        local job = SchedulerKit:Schedule(function() end)
        TestEnv.Tick()

        assert.are.equal("completed", job:GetState())
        assert.is_false(rawget(job, "_callback"))
        assert.is_false(rawget(job, "_context"))
        assert.is_false(rawget(job, "_coroutine"))
    end)
end)
