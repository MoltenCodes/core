local ModuleKitTestEnv = {}

ModuleKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
ModuleKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local frames = {}
local addonLoaded = {}
local loggedIn = false
local reportedErrors = {}

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
        -- Stub precondition, not a test expectation: support modules are plain
        -- `require`d modules, so Busted's injected `assert` global is unavailable
        -- here and a misuse must surface as an ordinary Lua error.
        if frameType ~= "Frame" then
            error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
        end
        return newFrame()
    end)

    rawset(_G, "C_AddOns", {
        -- The real C_AddOns.IsAddOnLoaded returns (loaded, finished). An addon
        -- whose files are being executed but whose ADDON_LOADED transition has
        -- not completed answers (true, false), so the stub must be able to
        -- report that state separately from "finished".
        IsAddOnLoaded = function(addonName)
            local status = addonLoaded[addonName]
            if status == "loading" then
                return true, false
            end
            local finished = status == true
            return finished, finished
        end,
    })

    rawset(_G, "IsLoggedIn", function()
        return loggedIn
    end)

    -- EventKit isolates listener errors at the event-bus boundary: it reports
    -- them through the host error handler instead of letting them escape the
    -- dispatch. Capturing that handler is how a spec observes an error that
    -- LifecycleKit re-raised from inside a host event delivery.
    rawset(_G, "geterrorhandler", function()
        return function(message)
            reportedErrors[#reportedErrors + 1] = { value = message }
        end
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
    rawset(_G, "geterrorhandler", nil)

    frames = {}
    addonLoaded = {}
    loggedIn = false
    reportedErrors = {}
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

--- Mark an addon as loading but not finished, the (true, false) host state.
function ModuleKitTestEnv.MarkAddonLoading(addonName)
    addonLoaded[addonName] = "loading"
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

--- Return and clear every error EventKit reported through the host error
--- handler since the last call. Each entry is `{ value = <error object> }`,
--- so `nil` and `false` error objects stay representable.
function ModuleKitTestEnv.TakeReportedErrors()
    local taken = reportedErrors
    reportedErrors = {}
    return taken
end

function ModuleKitTestEnv.Frames()
    return frames
end

return ModuleKitTestEnv
