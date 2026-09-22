local EventKitTestEnv = {}

EventKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
EventKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local frames = {}
local nextRegisterEventResult = nil
local nextRegisterUnitEventResult = nil

local function copyArray(values)
    local copy = {}
    for index = 1, #values do
        copy[index] = values[index]
    end
    return copy
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

function EventKitTestEnv.InstallWowApi()
    rawset(_G, "CreateFrame", function(frameType)
        -- Stub precondition, not a test expectation: support modules are plain
        -- `require`d modules, so Busted's injected `assert` global is unavailable
        -- here and a misuse must surface as an ordinary Lua error.
        if frameType ~= "Frame" then
            error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
        end
        return newFrame()
    end)
end

function EventKitTestEnv.Reset()
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, EventKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, EventKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    frames = {}
    nextRegisterEventResult = nil
    nextRegisterUnitEventResult = nil
end

function EventKitTestEnv.NewPackage()
    EventKitTestEnv.Reset()
    EventKitTestEnv.InstallWowApi()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    local EventKit = require("EventKit")
    return EventKit, Registry, SignalKit
end

function EventKitTestEnv.ReloadPackage()
    package.loaded["EventKit"] = nil
    return require("EventKit")
end

function EventKitTestEnv.Frames()
    return frames
end

function EventKitTestEnv.Emit(eventName, ...)
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

function EventKitTestEnv.FailNextRegisterEvent()
    nextRegisterEventResult = false
end

function EventKitTestEnv.FailNextRegisterUnitEvent()
    nextRegisterUnitEventResult = false
end

return EventKitTestEnv
