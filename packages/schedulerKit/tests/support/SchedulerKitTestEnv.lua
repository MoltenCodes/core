-- Busted injects luassert only into spec chunks. This support module is loaded
-- through `require`, so it names the library explicitly for the few helpers that
-- assert a genuine test expectation rather than a stub precondition.
local assert = require("luassert")

local SchedulerKitTestEnv = {}

SchedulerKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
SchedulerKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local frames = {}
local addonLoaded = {}
local loggedIn = false
local nativeTimers = {}
local wallClockMs = 0
local profileClockMs = 0
local profilingClockAvailable = true
local reportedErrors = {}
local failNextTimerCreate = nil
local failNextTimerCancel = nil
local failNextSetScript = nil

local function copyArray(values)
    local result = {}
    for index = 1, #values do
        result[index] = values[index]
    end
    return result
end

local function newFrame()
    local frame = {
        scripts = {},
        registrations = {},
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
        self.registrations[eventName] = { kind = "event" }
        return true
    end

    function frame:RegisterUnitEvent(eventName, ...)
        self.registrations[eventName] = { kind = "unit", units = copyArray({ ... }) }
        return true
    end

    function frame:UnregisterEvent(eventName)
        local existed = self.registrations[eventName] ~= nil
        self.registrations[eventName] = nil
        return existed
    end

    frames[#frames + 1] = frame
    return frame
end

local function newNativeTimer(seconds, callback, repeating)
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

function SchedulerKitTestEnv.InstallWowApi()
    rawset(_G, "CreateFrame", function(frameType)
        -- Stub precondition, not a test expectation: support modules are plain
        -- `require`d modules, so Busted's injected `assert` global is unavailable
        -- here and a misuse must surface as an ordinary Lua error.
        if frameType ~= "Frame" then
            error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
        end
        return newFrame()
    end)

    rawset(_G, "C_AddOns", {
        IsAddOnLoaded = function(addonName)
            local finished = addonLoaded[addonName] == true
            return finished, finished
        end,
    })

    rawset(_G, "IsLoggedIn", function()
        return loggedIn
    end)

    rawset(_G, "C_Timer", {
        NewTimer = function(seconds, callback)
            return newNativeTimer(seconds, callback, false)
        end,
        NewTicker = function(seconds, callback)
            return newNativeTimer(seconds, callback, true)
        end,
    })

    rawset(_G, "GetTimePreciseSec", function()
        return wallClockMs / 1000
    end)

    -- SchedulerKit measures its frame budget in addon CPU milliseconds. The
    -- stub keeps that clock independent from the wall clock so a spec can
    -- simulate a hitch: wall time moves while CPU time does not.
    if profilingClockAvailable then
        rawset(_G, "debugprofilestop", function()
            return profileClockMs
        end)
    end

    rawset(_G, "geterrorhandler", function()
        return function(value)
            reportedErrors[#reportedErrors + 1] = value
        end
    end)
end

function SchedulerKitTestEnv.Reset()
    package.loaded["SchedulerKit"] = nil
    package.loaded["TimerKit"] = nil
    package.loaded["LifecycleKit"] = nil
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil

    rawset(_G, SchedulerKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, SchedulerKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    rawset(_G, "C_AddOns", nil)
    rawset(_G, "IsLoggedIn", nil)
    rawset(_G, "C_Timer", nil)
    rawset(_G, "GetTimePreciseSec", nil)
    rawset(_G, "debugprofilestop", nil)
    rawset(_G, "geterrorhandler", nil)

    frames = {}
    addonLoaded = {}
    loggedIn = false
    nativeTimers = {}
    wallClockMs = 0
    profileClockMs = 0
    profilingClockAvailable = true
    reportedErrors = {}
    failNextTimerCreate = nil
    failNextTimerCancel = nil
    failNextSetScript = nil
end

function SchedulerKitTestEnv.NewPackage()
    SchedulerKitTestEnv.Reset()
    SchedulerKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    local TimerKit = require("TimerKit")
    local SchedulerKit = require("SchedulerKit")
    return SchedulerKit, Registry, SignalKit, EventKit, LifecycleKit, TimerKit
end

function SchedulerKitTestEnv.ReloadPackage()
    package.loaded["SchedulerKit"] = nil
    return require("SchedulerKit")
end

---Advance both clocks, which is what an ordinary busy slice looks like.
function SchedulerKitTestEnv.AdvanceMs(milliseconds)
    wallClockMs = wallClockMs + milliseconds
    profileClockMs = profileClockMs + milliseconds
end

---Advance only addon CPU time.
function SchedulerKitTestEnv.AdvanceProfileMs(milliseconds)
    profileClockMs = profileClockMs + milliseconds
end

---Advance only wall-clock time, as a garbage-collection pause or client hitch
---does: the frame stalls without the running job consuming any CPU.
function SchedulerKitTestEnv.AdvanceWallMs(milliseconds)
    wallClockMs = wallClockMs + milliseconds
end

---Withhold `debugprofilestop` from the next `InstallWowApi`, so a spec can
---exercise the documented wall-clock fallback. Must be called before the
---package is loaded, because the clock is bound once at load.
function SchedulerKitTestEnv.WithoutProfilingClock()
    profilingClockAvailable = false
end

function SchedulerKitTestEnv.NowMs()
    return profileClockMs
end

function SchedulerKitTestEnv.Tick(elapsed)
    local count = #frames
    for index = 1, count do
        local callback = frames[index].scripts.OnUpdate
        if callback ~= nil then
            callback(frames[index], elapsed or 0.016)
        end
    end
end

function SchedulerKitTestEnv.ActiveOnUpdateCount()
    local count = 0
    for index = 1, #frames do
        if frames[index].scripts.OnUpdate ~= nil then
            count = count + 1
        end
    end
    return count
end

function SchedulerKitTestEnv.NativeTimers()
    return nativeTimers
end

function SchedulerKitTestEnv.FireNative(index)
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

function SchedulerKitTestEnv.ReportedErrors()
    return reportedErrors
end

function SchedulerKitTestEnv.FailNextTimerCreate(value)
    failNextTimerCreate = value
end

function SchedulerKitTestEnv.FailNextTimerCancel(value)
    failNextTimerCancel = value
end

function SchedulerKitTestEnv.FailNextSetScript(value)
    failNextSetScript = value
end

function SchedulerKitTestEnv.Emit(eventName, ...)
    local frameCount = #frames
    for index = 1, frameCount do
        local frame = frames[index]
        if frame.registrations[eventName] ~= nil then
            local onEvent = frame.scripts.OnEvent
            if onEvent ~= nil then
                onEvent(frame, eventName, ...)
            end
        end
    end
end

function SchedulerKitTestEnv.MarkAddonLoaded(addonName)
    addonLoaded[addonName] = true
end

function SchedulerKitTestEnv.LoadAddon(addonName)
    addonLoaded[addonName] = true
    SchedulerKitTestEnv.Emit("ADDON_LOADED", addonName)
end

function SchedulerKitTestEnv.Login()
    loggedIn = true
    SchedulerKitTestEnv.Emit("PLAYER_LOGIN")
end

function SchedulerKitTestEnv.Logout()
    SchedulerKitTestEnv.Emit("PLAYER_LOGOUT")
    loggedIn = false
end

return SchedulerKitTestEnv
