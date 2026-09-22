--- Narrow fake World of Warcraft Frame boundary for the EventKit suite.
---
--- The stub models the parts of the host contract EventKit depends on and
--- deliberately enforces the parts EventKit is not allowed to exceed:
---
--- * `RegisterUnitEvent` has exactly two unit-filter slots, and a third token is
---   an error rather than something the client quietly drops;
--- * a unit registration only delivers events whose first payload value matches
---   one of its filter tokens;
--- * `Emit` walks Frames in creation order. That order is **not** part of
---   EventKit's contract: EventKit does not define callback ordering between
---   different Frames, so no spec may depend on it.
local EventKitTestEnv = {}

EventKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
EventKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

--- The host's `Frame:RegisterUnitEvent(event, unit1, unit2)` slot count.
EventKitTestEnv.MAXIMUM_UNIT_TOKENS = 2

local frames = {}
local nextRegisterEventResult = nil
local nextRegisterUnitEventResult = nil
local reportedErrors = {}

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
        local unitCount = select("#", ...)
        -- Stub precondition, not a test expectation: the real host has two unit
        -- slots. Modelling that faithfully is the only way the suite can see a
        -- package bug that passes a third token.
        if unitCount > EventKitTestEnv.MAXIMUM_UNIT_TOKENS then
            error(
                "RegisterUnitEvent stub accepts at most "
                    .. EventKitTestEnv.MAXIMUM_UNIT_TOKENS
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

--- Installs the fake `CreateFrame` and the host error-handler hook EventKit
--- reports isolated listener failures through.
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

    rawset(_G, "geterrorhandler", function()
        return function(message)
            reportedErrors[#reportedErrors + 1] = tostring(message)
        end
    end)
end

function EventKitTestEnv.Reset()
    package.loaded["EventKit"] = nil
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, EventKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, EventKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "CreateFrame", nil)
    rawset(_G, "geterrorhandler", nil)
    rawset(_G, "securecallfunction", nil)
    frames = {}
    nextRegisterEventResult = nil
    nextRegisterUnitEventResult = nil
    reportedErrors = {}
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

--- Installs a `securecallfunction` stub so a spec can exercise the modern-client
--- isolation path. Must be called before `EventKit.lua` loads.
function EventKitTestEnv.InstallSecureCallFunction()
    rawset(_G, "securecallfunction", function(callback, ...)
        local ok, message = pcall(callback, ...)
        if not ok then
            reportedErrors[#reportedErrors + 1] = tostring(message)
        end
    end)
end

--- Every listener error EventKit has reported through the host error handler.
function EventKitTestEnv.ReportedErrors()
    return reportedErrors
end

--- Delivers `eventName` to every Frame whose registration accepts it.
---
--- Frames are walked in creation order. That order is an artefact of this stub,
--- not an EventKit guarantee.
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
