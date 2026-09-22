--- Shared World of Warcraft test fixture for every MoltenCodes package suite.
---
--- Every package used to carry its own near-identical copy of the same stubs:
--- a fake `CreateFrame`, a fake `C_Timer`, controllable clocks, a capture for
--- the host error handler, and the `package.loaded` bookkeeping a bootstrap spec
--- needs. Keeping seven copies in step by hand meant a fix to one of them —
--- the two-slot `RegisterUnitEvent` limit, say — silently missed the rest.
---
--- `FrameworkTestEnv.New` builds one environment per package. Each environment
--- owns its own stub state, so nothing leaks between environments even when a
--- process builds more than one.
---
--- A package keeps `tests/support/<Kit>TestEnv.lua` for what is genuinely its
--- own: the load order of its module chain, and any helper that only its specs
--- can describe.
---
--- Busted injects `describe`, `it` and luassert's `assert` into spec chunks
--- only. This module is loaded through plain `require`, so it names luassert
--- explicitly for the handful of helpers that assert a genuine expectation, and
--- raises ordinary `error(..., 2)` for stub preconditions.

local assert = require("luassert")

local FrameworkTestEnv = {}

--- Private bootstrap-state key the Registry API 2 implementation publishes.
FrameworkTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"

--- The retired API 1 bootstrap-state key. Specs that prove it is *not* adopted
--- still have to clear it between attempts.
FrameworkTestEnv.LEGACY_REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V1"

--- The documented public namespace every package hands off through.
FrameworkTestEnv.NAMESPACE_KEY = "MoltenCodes"

--- The host's `Frame:RegisterUnitEvent(event, unit1, unit2)` slot count.
FrameworkTestEnv.MAXIMUM_UNIT_TOKENS = 2

--- Globals an environment owns and therefore always clears on `Reset`.
local OWNED_GLOBALS = {
    "CreateFrame",
    "C_AddOns",
    "IsAddOnLoaded",
    "IsLoggedIn",
    "C_Timer",
    "GetTimePreciseSec",
    "debugprofilestop",
    "geterrorhandler",
    "securecallfunction",
    "CombatLogGetCurrentEventInfo",
}

---@param values any[]
---@return any[]
local function copyArray(values)
    local copy = {}
    for index = 1, #values do
        copy[index] = values[index]
    end
    return copy
end

---Clear `package.loaded` for `moduleName` and require it again.
---
---Lua 5.1 marks a module as in-progress in `package.loaded` before running its
---chunk and does not clear that marker when the chunk raises. A second
---`require` of the same module would otherwise report `loop or previous error
---loading module` instead of re-running the bootstrap guard under test.
---@param moduleName string
---@return any
function FrameworkTestEnv.requireAfterFailedLoad(moduleName)
    package.loaded[moduleName] = nil
    return require(moduleName)
end

---Assert that `callback` fails with a message containing `expected`.
---@param expected string substring the failure must contain
---@param callback fun()
function FrameworkTestEnv.expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

---Options accepted by `FrameworkTestEnv.New`.
---@class FrameworkTestEnv.Options
---@field modules string[]? Module names in load order; the last one is the package under test. Omit it for a suite that loads its subject some other way, such as the example addon.
---@field wowApi boolean? Whether `NewPackage` installs the WoW stubs. Defaults to `true`.
---@field legacyRegistryState boolean? Whether `Reset` also clears the retired API 1 state key.

---Build one package's test environment.
---@param options FrameworkTestEnv.Options
---@return table environment
function FrameworkTestEnv.New(options)
    if type(options) ~= "table" then
        error("FrameworkTestEnv.New requires an options table", 2)
    end

    local modules = options.modules
    if modules == nil then
        modules = {}
    elseif type(modules) ~= "table" then
        error("FrameworkTestEnv.New options.modules must be an array of module names", 2)
    end

    local installsWowApi = options.wowApi ~= false
    local clearsLegacyState = options.legacyRegistryState == true
    local packageModule = modules[#modules]

    local environment = {}

    environment.REGISTRY_STATE_KEY = FrameworkTestEnv.REGISTRY_STATE_KEY
    environment.LEGACY_REGISTRY_STATE_KEY = FrameworkTestEnv.LEGACY_REGISTRY_STATE_KEY
    environment.NAMESPACE_KEY = FrameworkTestEnv.NAMESPACE_KEY
    environment.MAXIMUM_UNIT_TOKENS = FrameworkTestEnv.MAXIMUM_UNIT_TOKENS
    environment.requireAfterFailedLoad = FrameworkTestEnv.requireAfterFailedLoad
    environment.expectErrorContaining = FrameworkTestEnv.expectErrorContaining

    -- Stub state. Every field below is reset by `Reset`, which is what keeps
    -- specs independent of each other's execution order.
    local frames = {}
    local nativeTimers = {}
    local addonLoaded = {}
    local loggedIn = false
    local reportedErrors = {}
    local combatLogEvent = {}
    local wallClockMs = 0
    local profileClockMs = 0
    local profilingClockAvailable = true
    local nextRegisterEventResult = nil
    local nextRegisterUnitEventResult = nil
    local nextNativeOverride = nil
    local failNextTimerCreate = nil
    local failNextTimerCancel = nil
    local failNextSetScript = nil

    -- Frames ----------------------------------------------------------------

    ---Whether a registration would deliver an event with this payload.
    ---
    ---A unit registration only fires for its own filter tokens, which is how a
    ---spec sees a package that registered the wrong filter set.
    ---@param registration table
    ---@return boolean
    local function registrationAccepts(registration, ...)
        if registration.kind ~= "unit" then
            return true
        end

        local unit = select(1, ...)
        for index = 1, #registration.units do
            if registration.units[index] == unit then
                return true
            end
        end
        return false
    end

    local function newFrame()
        local frame = {
            scripts = {},
            registrations = {},
            registerEventCalls = {},
            registerUnitEventCalls = {},
            unregisterEventCalls = {},
        }

        function frame:SetScript(scriptName, callback)
            if failNextSetScript ~= nil then
                local value = failNextSetScript
                failNextSetScript = nil
                error(value, 0)
            end
            self.scripts[scriptName] = callback
        end

        function frame:RegisterEvent(eventName)
            self.registerEventCalls[#self.registerEventCalls + 1] = eventName
            local result = nextRegisterEventResult
            nextRegisterEventResult = nil
            if result == false then
                return false
            end
            self.registrations[eventName] = { kind = "event" }
            return result == nil and true or result
        end

        function frame:RegisterUnitEvent(eventName, ...)
            local unitCount = select("#", ...)
            -- Stub precondition, not a test expectation: the real host has two
            -- unit slots. Modelling that faithfully is the only way a suite can
            -- see a package bug that passes a third token.
            if unitCount > FrameworkTestEnv.MAXIMUM_UNIT_TOKENS then
                error(
                    "RegisterUnitEvent stub accepts at most "
                        .. FrameworkTestEnv.MAXIMUM_UNIT_TOKENS
                        .. " unit tokens, received "
                        .. unitCount,
                    2
                )
            end

            local units = { ... }
            self.registerUnitEventCalls[#self.registerUnitEventCalls + 1] = {
                eventName = eventName,
                units = copyArray(units),
            }
            local result = nextRegisterUnitEventResult
            nextRegisterUnitEventResult = nil
            if result == false then
                return false
            end
            self.registrations[eventName] = { kind = "unit", units = copyArray(units) }
            return result == nil and true or result
        end

        function frame:UnregisterEvent(eventName)
            self.unregisterEventCalls[#self.unregisterEventCalls + 1] = eventName
            local existed = self.registrations[eventName] ~= nil
            self.registrations[eventName] = nil
            return existed
        end

        frames[#frames + 1] = frame
        return frame
    end

    -- Native timers ---------------------------------------------------------

    local function newNativeTimer(seconds, callback, repeating)
        if nextNativeOverride ~= nil then
            local value = nextNativeOverride
            nextNativeOverride = nil
            return value
        end

        if failNextTimerCreate ~= nil then
            local value = failNextTimerCreate
            failNextTimerCreate = nil
            error(value, 0)
        end

        local native = {
            seconds = seconds,
            callback = callback,
            repeating = repeating,
            cancelled = false,
            fired = false,
        }

        function native:Cancel()
            self.cancelled = true
            if failNextTimerCancel ~= nil then
                local value = failNextTimerCancel
                failNextTimerCancel = nil
                error(value, 0)
            end
        end

        function native:IsCancelled()
            return self.cancelled
        end

        nativeTimers[#nativeTimers + 1] = native
        return native
    end

    -- Installation ----------------------------------------------------------

    ---Install only the host error sink.
    ---
    ---A pure-Lua package stays silent without it, so its specs opt in rather
    ---than having diagnostics captured for them.
    function environment.InstallHostErrorHandler()
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "geterrorhandler", function()
            return function(value)
                reportedErrors[#reportedErrors + 1] = { value = value }
            end
        end)
    end

    ---Install a `securecallfunction` stub so a spec can exercise the
    ---modern-client isolation path. Must run before the package loads.
    function environment.InstallSecureCallFunction()
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "securecallfunction", function(callback, ...)
            local ok, message = pcall(callback, ...)
            if not ok then
                reportedErrors[#reportedErrors + 1] = { value = message }
            end
        end)
    end

    ---Install every World of Warcraft API the framework packages touch.
    function environment.InstallWowApi()
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "CreateFrame", function(frameType)
            -- Stub precondition, not a test expectation: support modules are
            -- plain `require`d modules, so a misuse must surface as an ordinary
            -- Lua error rather than as a failed assertion.
            if frameType ~= "Frame" then
                error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
            end
            return newFrame()
        end)

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_AddOns", {
            -- The real C_AddOns.IsAddOnLoaded returns (loaded, finished). An
            -- addon whose files are executing but whose ADDON_LOADED transition
            -- has not completed answers (true, false), so the stub reports that
            -- state separately from "finished".
            IsAddOnLoaded = function(addonName)
                local status = addonLoaded[addonName]
                if status == "loading" then
                    return true, false
                end
                local finished = status == true
                return finished, finished
            end,
        })

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "IsLoggedIn", function()
            return loggedIn
        end)

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "C_Timer", {
            NewTimer = function(seconds, callback)
                return newNativeTimer(seconds, callback, false)
            end,
            NewTicker = function(seconds, callback)
                return newNativeTimer(seconds, callback, true)
            end,
        })

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "GetTimePreciseSec", function()
            return wallClockMs / 1000
        end)

        -- A frame budget is defined in addon CPU milliseconds. The stub keeps
        -- that clock independent from the wall clock so a spec can simulate a
        -- hitch: wall time moves while CPU time does not.
        if profilingClockAvailable then
            -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
            -- selene: allow(global_usage)
            rawset(_G, "debugprofilestop", function()
                return profileClockMs
            end)
        end

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "CombatLogGetCurrentEventInfo", function()
            return unpack(combatLogEvent)
        end)

        environment.InstallHostErrorHandler()
    end

    -- Lifecycle -------------------------------------------------------------

    ---Clear every module, global and stub this environment owns.
    function environment.Reset()
        for index = #modules, 1, -1 do
            package.loaded[modules[index]] = nil
        end

        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, FrameworkTestEnv.REGISTRY_STATE_KEY, nil)
        -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
        -- selene: allow(global_usage)
        rawset(_G, FrameworkTestEnv.NAMESPACE_KEY, nil)
        if clearsLegacyState then
            -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
            -- selene: allow(global_usage)
            rawset(_G, FrameworkTestEnv.LEGACY_REGISTRY_STATE_KEY, nil)
        end
        for index = 1, #OWNED_GLOBALS do
            -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
            -- selene: allow(global_usage)
            rawset(_G, OWNED_GLOBALS[index], nil)
        end

        frames = {}
        nativeTimers = {}
        addonLoaded = {}
        loggedIn = false
        reportedErrors = {}
        combatLogEvent = {}
        wallClockMs = 0
        profileClockMs = 0
        profilingClockAvailable = true
        nextRegisterEventResult = nil
        nextRegisterUnitEventResult = nil
        nextNativeOverride = nil
        failNextTimerCreate = nil
        failNextTimerCancel = nil
        failNextSetScript = nil
    end

    ---Reset, install the host stubs, then load the module chain in order.
    ---
    ---The package under test is returned first, then its dependencies in
    ---load order, so a spec can name only what it needs.
    ---@return ... loaded modules, package under test first
    function environment.NewPackage()
        if packageModule == nil then
            error("this environment was built without a module chain to load", 2)
        end

        environment.Reset()
        if installsWowApi then
            environment.InstallWowApi()
        end

        local loaded = {}
        for index = 1, #modules do
            loaded[index] = require(modules[index])
        end

        local ordered = { loaded[#loaded] }
        for index = 1, #loaded - 1 do
            ordered[index + 1] = loaded[index]
        end
        return unpack(ordered, 1, #ordered)
    end

    ---Re-run the package under test against the state it already published.
    ---@return any
    function environment.ReloadPackage()
        if packageModule == nil then
            error("this environment was built without a module chain to load", 2)
        end

        package.loaded[packageModule] = nil
        return require(packageModule)
    end

    -- Frame inspection ------------------------------------------------------

    ---@return table[] frames Every Frame created, in creation order.
    function environment.Frames()
        return frames
    end

    ---Deliver `eventName` to every Frame whose registration accepts it.
    ---
    ---Frames are walked in creation order. That order is an artefact of this
    ---stub, not a guarantee any package makes.
    function environment.Emit(eventName, ...)
        local frameCount = #frames
        for index = 1, frameCount do
            local frame = frames[index]
            local registration = frame.registrations[eventName]
            if registration ~= nil and registrationAccepts(registration, ...) then
                local onEvent = frame.scripts.OnEvent
                if onEvent ~= nil then
                    onEvent(frame, eventName, ...)
                end
            end
        end
    end

    ---Run every installed `OnUpdate` handler once.
    ---@param elapsed number? seconds since the previous frame
    function environment.Tick(elapsed)
        local count = #frames
        for index = 1, count do
            local callback = frames[index].scripts.OnUpdate
            if callback ~= nil then
                callback(frames[index], elapsed or 0.016)
            end
        end
    end

    ---@return integer count Frames currently carrying an `OnUpdate` handler.
    function environment.ActiveOnUpdateCount()
        local count = 0
        for index = 1, #frames do
            if frames[index].scripts.OnUpdate ~= nil then
                count = count + 1
            end
        end
        return count
    end

    function environment.FailNextRegisterEvent()
        nextRegisterEventResult = false
    end

    function environment.FailNextRegisterUnitEvent()
        nextRegisterUnitEventResult = false
    end

    ---Make the next `Frame:SetScript` raise `value`.
    function environment.FailNextSetScript(value)
        failNextSetScript = value
    end

    -- Native timers ---------------------------------------------------------

    ---@return table[] timers Every native timer created, in creation order.
    function environment.NativeTimers()
        return nativeTimers
    end

    ---Fire native timer `index` the way the host would.
    ---@param index integer
    ---@return boolean fired `false` when the timer was cancelled or spent.
    function environment.FireNative(index)
        local native = nativeTimers[index]
        assert.is_not_nil(native)
        if native.cancelled then
            return false
        end
        if not native.repeating and native.fired then
            return false
        end
        if not native.repeating then
            native.fired = true
        end
        native.callback(native)
        return true
    end

    ---Invoke native timer `index`'s callback without the host's own guards, so
    ---a spec can prove the package rejects a stale callback on its own.
    ---@param index integer
    function environment.InvokeRaw(index)
        local native = nativeTimers[index]
        assert.is_not_nil(native)
        native.callback(native)
    end

    ---Make the next `C_Timer` constructor raise `value`.
    function environment.FailNextTimerCreate(value)
        failNextTimerCreate = value
    end

    ---Make the next native `Cancel` raise `value`.
    function environment.FailNextTimerCancel(value)
        failNextTimerCancel = value
    end

    ---Make the next `C_Timer` constructor return `value` instead of a stub.
    function environment.ReturnNextNative(value)
        nextNativeOverride = value
    end

    -- Clocks ----------------------------------------------------------------

    ---Advance both clocks, which is what an ordinary busy slice looks like.
    function environment.AdvanceMs(milliseconds)
        wallClockMs = wallClockMs + milliseconds
        profileClockMs = profileClockMs + milliseconds
    end

    ---Advance only addon CPU time.
    function environment.AdvanceProfileMs(milliseconds)
        profileClockMs = profileClockMs + milliseconds
    end

    ---Advance only wall-clock time, as a garbage-collection pause or client
    ---hitch does: the frame stalls without the running job consuming any CPU.
    function environment.AdvanceWallMs(milliseconds)
        wallClockMs = wallClockMs + milliseconds
    end

    ---@return number milliseconds Current addon CPU time.
    function environment.NowMs()
        return profileClockMs
    end

    ---Withhold `debugprofilestop` from the next `InstallWowApi`, so a spec can
    ---exercise the documented wall-clock fallback. Must be called before the
    ---package is loaded, because the clock is bound once at load.
    function environment.WithoutProfilingClock()
        profilingClockAvailable = false
    end

    -- Host state ------------------------------------------------------------

    function environment.MarkAddonLoaded(addonName)
        addonLoaded[addonName] = true
    end

    ---Mark an addon as loading but not finished: the (true, false) host state.
    function environment.MarkAddonLoading(addonName)
        addonLoaded[addonName] = "loading"
    end

    function environment.SetLoggedIn(value)
        loggedIn = value == true
    end

    function environment.LoadAddon(addonName)
        environment.MarkAddonLoaded(addonName)
        environment.Emit("ADDON_LOADED", addonName)
    end

    function environment.Login()
        loggedIn = true
        environment.Emit("PLAYER_LOGIN")
    end

    function environment.Logout()
        environment.Emit("PLAYER_LOGOUT")
        loggedIn = false
    end

    ---Set the payload `CombatLogGetCurrentEventInfo()` returns.
    ---
    ---`COMBAT_LOG_EVENT_UNFILTERED` carries no event payload; a listener reads
    ---the event through this function instead.
    function environment.SetCombatLogEvent(...)
        combatLogEvent = { ... }
    end

    -- Error capture ---------------------------------------------------------

    ---Every value the host error handler received, in order.
    ---
    ---Entries are the raw error objects. Use `TakeReportedErrors` when a `nil`
    ---or `false` error object has to stay distinguishable from "nothing was
    ---reported".
    ---@return any[]
    function environment.ReportedErrors()
        local values = {}
        for index = 1, #reportedErrors do
            values[index] = reportedErrors[index].value
        end
        return values
    end

    ---Return and clear every error reported since the last call.
    ---
    ---Each entry is `{ value = <error object> }`, so `nil` and `false` error
    ---objects stay representable.
    ---@return { value: any }[]
    function environment.TakeReportedErrors()
        local taken = reportedErrors
        reportedErrors = {}
        return taken
    end

    return environment
end

return FrameworkTestEnv
