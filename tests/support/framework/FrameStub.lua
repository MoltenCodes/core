--- The fake `CreateFrame` and everything a spec does with the Frames it makes.
---
--- Frames are the framework's whole boundary with the World of Warcraft event
--- system, so this stub models the parts of that boundary a package can get
--- wrong: the two-slot `RegisterUnitEvent` limit, a registration the host
--- refuses, a `SetScript` that raises, and which Frames an emitted event
--- actually reaches.
---
--- Every function here takes the environment's shared state table rather than
--- closing over locals, so the stub can be built, reset and inspected without
--- the whole fixture being one function.

local FrameStub = {}

local Constants = require("framework.Constants")

---@param values any[]
---@return any[]
local function copyArray(values)
    local copy = {}
    for index = 1, #values do
        copy[index] = values[index]
    end
    return copy
end

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

---Build one Frame and record it in creation order.
---@param state table shared stub state
---@return table frame
local function newFrame(state)
    local frame = {
        scripts = {},
        registrations = {},
        registerEventCalls = {},
        registerUnitEventCalls = {},
        unregisterEventCalls = {},
    }

    function frame:SetScript(scriptName, callback)
        if state.failNextSetScript ~= nil then
            local value = state.failNextSetScript
            state.failNextSetScript = nil
            error(value, 0)
        end
        self.scripts[scriptName] = callback
    end

    function frame:RegisterEvent(eventName)
        self.registerEventCalls[#self.registerEventCalls + 1] = eventName
        local result = state.nextRegisterEventResult
        state.nextRegisterEventResult = nil
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
        if unitCount > Constants.MAXIMUM_UNIT_TOKENS then
            error(
                "RegisterUnitEvent stub accepts at most "
                    .. Constants.MAXIMUM_UNIT_TOKENS
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
        local result = state.nextRegisterUnitEventResult
        state.nextRegisterUnitEventResult = nil
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

    state.frames[#state.frames + 1] = frame
    return frame
end

---Return this stub's state fields to their initial values.
---@param state table shared stub state
function FrameStub.Reset(state)
    state.frames = {}
    state.nextRegisterEventResult = nil
    state.nextRegisterUnitEventResult = nil
    state.failNextSetScript = nil
end

---Install the globals this stub owns.
---@param state table shared stub state
function FrameStub.InstallGlobals(state)
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "CreateFrame", function(frameType)
        -- Stub precondition, not a test expectation: support modules are
        -- plain `require`d modules, so a misuse must surface as an ordinary
        -- Lua error rather than as a failed assertion.
        if frameType ~= "Frame" then
            error('CreateFrame stub supports only "Frame", received ' .. tostring(frameType), 2)
        end
        return newFrame(state)
    end)
end

---Attach this stub's public helpers to `environment`.
---@param environment table the fixture facade specs call
---@param state table shared stub state
function FrameStub.Attach(environment, state)
    ---@return table[] frames Every Frame created, in creation order.
    function environment.Frames()
        return state.frames
    end

    ---Deliver `eventName` to every Frame whose registration accepts it.
    ---
    ---Frames are walked in creation order. That order is an artefact of this
    ---stub, not a guarantee any package makes.
    function environment.Emit(eventName, ...)
        local frames = state.frames
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
        local frames = state.frames
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
        local frames = state.frames
        local count = 0
        for index = 1, #frames do
            if frames[index].scripts.OnUpdate ~= nil then
                count = count + 1
            end
        end
        return count
    end

    function environment.FailNextRegisterEvent()
        state.nextRegisterEventResult = false
    end

    function environment.FailNextRegisterUnitEvent()
        state.nextRegisterUnitEventResult = false
    end

    ---Make the next `Frame:SetScript` raise `value`.
    function environment.FailNextSetScript(value)
        state.failNextSetScript = value
    end
end

return FrameStub
