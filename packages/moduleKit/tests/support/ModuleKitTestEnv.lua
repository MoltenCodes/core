local ModuleKitTestEnv = {}

ModuleKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
ModuleKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

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

function ModuleKitTestEnv.InstallWowApi()
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
end

function ModuleKitTestEnv.Reset()
    package.loaded["ModuleKit"] = nil
    package.loaded["LifecycleKit"] = nil
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil

    rawset(_G, ModuleKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, ModuleKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    rawset(_G, "C_AddOns", nil)
    rawset(_G, "IsAddOnLoaded", nil)
    rawset(_G, "IsLoggedIn", nil)

    frames = {}
    addonLoaded = {}
    loggedIn = false
end

function ModuleKitTestEnv.NewPackage()
    ModuleKitTestEnv.Reset()
    ModuleKitTestEnv.InstallWowApi()

    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    local LifecycleKit = require("LifecycleKit")
    local ModuleKit = require("ModuleKit")

    return ModuleKit, Registry, LifecycleKit, EventKit, SignalKit
end

function ModuleKitTestEnv.ReloadPackage()
    package.loaded["ModuleKit"] = nil
    return require("ModuleKit")
end

function ModuleKitTestEnv.Emit(eventName, ...)
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

function ModuleKitTestEnv.MarkAddonLoaded(addonName)
    addonLoaded[addonName] = true
end

function ModuleKitTestEnv.SetLoggedIn(value)
    loggedIn = value == true
end

function ModuleKitTestEnv.LoadAddon(addonName)
    ModuleKitTestEnv.MarkAddonLoaded(addonName)
    ModuleKitTestEnv.Emit("ADDON_LOADED", addonName)
end

function ModuleKitTestEnv.Login()
    loggedIn = true
    ModuleKitTestEnv.Emit("PLAYER_LOGIN")
end

function ModuleKitTestEnv.Logout()
    ModuleKitTestEnv.Emit("PLAYER_LOGOUT")
    loggedIn = false
end

function ModuleKitTestEnv.Frames()
    return frames
end

return ModuleKitTestEnv
