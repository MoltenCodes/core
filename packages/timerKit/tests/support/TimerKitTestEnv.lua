local TimerKitTestEnv = {}

TimerKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
TimerKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local frames = {}
local addonLoaded = {}
local loggedIn = false
local nativeTimers = {}
local failNextCreate = nil
local failNextCancel = nil
local nextNativeOverride = nil

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

local function newNative(seconds, callback, repeating)
    if nextNativeOverride ~= nil then
        local value = nextNativeOverride
        nextNativeOverride = nil
        return value
    end

    if failNextCreate ~= nil then
        local value = failNextCreate
        failNextCreate = nil
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
        if failNextCancel ~= nil then
            local value = failNextCancel
            failNextCancel = nil
            error(value, 0)
        end
    end

    function native:IsCancelled()
        return self.cancelled
    end

    nativeTimers[#nativeTimers + 1] = native
    return native
end

function TimerKitTestEnv.InstallWowApi()
    rawset(_G, "CreateFrame", function(frameType)
        assert.are.equal("Frame", frameType)
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
            return newNative(seconds, callback, false)
        end,
        NewTicker = function(seconds, callback)
            return newNative(seconds, callback, true)
        end,
    })
end

function TimerKitTestEnv.Reset()
    package.loaded["TimerKit"] = nil
    package.loaded["LifecycleKit"] = nil
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, TimerKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, TimerKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    rawset(_G, "C_AddOns", nil)
    rawset(_G, "IsAddOnLoaded", nil)
    rawset(_G, "IsLoggedIn", nil)
    rawset(_G, "C_Timer", nil)
    frames = {}
    addonLoaded = {}
    loggedIn = false
    nativeTimers = {}
    failNextCreate = nil
    failNextCancel = nil
    nextNativeOverride = nil
end

function TimerKitTestEnv.NewPackage()
    TimerKitTestEnv.Reset()
    TimerKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    local TimerKit = require("TimerKit")
    return TimerKit, Registry, SignalKit, EventKit, LifecycleKit
end

function TimerKitTestEnv.ReloadPackage()
    package.loaded["TimerKit"] = nil
    return require("TimerKit")
end

function TimerKitTestEnv.NativeTimers()
    return nativeTimers
end

function TimerKitTestEnv.FireNative(index)
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

function TimerKitTestEnv.InvokeRaw(index)
    local native = nativeTimers[index]
    assert.is_not_nil(native)
    native.callback(native)
end

function TimerKitTestEnv.FailNextCreate(value)
    failNextCreate = value
end

function TimerKitTestEnv.FailNextCancel(value)
    failNextCancel = value
end

function TimerKitTestEnv.ReturnNextNative(value)
    nextNativeOverride = value
end

function TimerKitTestEnv.Emit(eventName, ...)
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

function TimerKitTestEnv.MarkAddonLoaded(addonName)
    addonLoaded[addonName] = true
end

function TimerKitTestEnv.SetLoggedIn(value)
    loggedIn = value == true
end

function TimerKitTestEnv.LoadAddon(addonName)
    addonLoaded[addonName] = true
    TimerKitTestEnv.Emit("ADDON_LOADED", addonName)
end

function TimerKitTestEnv.Login()
    loggedIn = true
    TimerKitTestEnv.Emit("PLAYER_LOGIN")
end

function TimerKitTestEnv.Logout()
    TimerKitTestEnv.Emit("PLAYER_LOGOUT")
    loggedIn = false
end

return TimerKitTestEnv
