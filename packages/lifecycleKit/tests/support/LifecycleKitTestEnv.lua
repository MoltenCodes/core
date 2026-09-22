local LifecycleKitTestEnv = {}

LifecycleKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
LifecycleKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local frames = {}
local addonLoaded = {}
local loggedIn = false

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

function LifecycleKitTestEnv.InstallWowApi()
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
end

function LifecycleKitTestEnv.Reset()
    package.loaded["LifecycleKit"] = nil
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, LifecycleKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, LifecycleKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    rawset(_G, "C_AddOns", nil)
    rawset(_G, "IsAddOnLoaded", nil)
    rawset(_G, "IsLoggedIn", nil)
    frames = {}
    addonLoaded = {}
    loggedIn = false
end

function LifecycleKitTestEnv.NewPackage()
    LifecycleKitTestEnv.Reset()
    LifecycleKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    return LifecycleKit, Registry, SignalKit, EventKit
end

function LifecycleKitTestEnv.ReloadPackage()
    package.loaded["LifecycleKit"] = nil
    return require("LifecycleKit")
end

function LifecycleKitTestEnv.Emit(eventName, ...)
    for index = 1, #frames do
        local frame = frames[index]
        if frame.registrations[eventName] ~= nil then
            local onEvent = frame.scripts.OnEvent
            if onEvent ~= nil then
                onEvent(frame, eventName, ...)
            end
        end
    end
end

function LifecycleKitTestEnv.MarkAddonLoaded(addonName)
    addonLoaded[addonName] = true
end

function LifecycleKitTestEnv.SetLoggedIn(value)
    loggedIn = value == true
end

function LifecycleKitTestEnv.LoadAddon(addonName)
    LifecycleKitTestEnv.MarkAddonLoaded(addonName)
    LifecycleKitTestEnv.Emit("ADDON_LOADED", addonName)
end

function LifecycleKitTestEnv.Login()
    loggedIn = true
    LifecycleKitTestEnv.Emit("PLAYER_LOGIN")
end

function LifecycleKitTestEnv.Logout()
    LifecycleKitTestEnv.Emit("PLAYER_LOGOUT")
    loggedIn = false
end

function LifecycleKitTestEnv.Frames()
    return frames
end

return LifecycleKitTestEnv
