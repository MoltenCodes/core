local TestEnv = require("EventKitTestEnv")
local Scheduled = TestEnv.Scheduled

local SPEC_FILE = "packages/eventKit/tests/EventValidity_spec.lua:"
local UNKNOWN_EVENT = "NO_SUCH_EVENT"
local KNOWN_EVENTS = { "PLAYER_LOGIN", "UNIT_HEALTH", "UNIT_POWER_UPDATE", "BAG_UPDATE" }

local function noop() end

---Assert `callback` raises `expected`, reported at a line of this spec file,
---never inside EventKit.
---@param expected string
---@param callback function
local function expectCallerError(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
    assert.is_nil(string.find(message, "src/EventKit.lua", 1, true), message)
end

---The message EventKit raises for a name the client does not know.
---@param description string the method and argument, e.g. `EventKit:Connect eventName`
---@param eventName string
---@return string
local function unknownEventMessage(description, eventName)
    return description .. ' "' .. eventName .. '" is not an event this client knows'
end

---Assert that nothing was registered with the host: no Frame was created, or
---none of those created holds a registration.
local function expectNothingRegistered()
    local frames = TestEnv.Frames()
    for index = 1, #frames do
        assert.is_nil(next(frames[index].registrations))
    end
end

---Count the registrations of `eventName` across every Frame.
---@param eventName string
---@return integer
local function registrationsOf(eventName)
    local count = 0
    local frames = TestEnv.Frames()
    for index = 1, #frames do
        if frames[index].registrations[eventName] ~= nil then
            count = count + 1
        end
    end
    return count
end

describe("EventKit event-name validation", function()
    after_each(function()
        TestEnv.Reset()
        Scheduled.Reset()
    end)

    describe("on a client with C_EventUtils.IsEventValid", function()
        local EventKit
        before_each(function()
            EventKit = TestEnv.NewPackageKnowingEvents(KNOWN_EVENTS)
        end)

        it("refuses an unknown name at the caller's line in every package method", function()
            expectCallerError(
                unknownEventMessage("EventKit:Connect eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Connect(UNKNOWN_EVENT, noop)
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit:Once eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Once(UNKNOWN_EVENT, noop)
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit:ConnectUnit eventName", UNKNOWN_EVENT),
                function()
                    EventKit:ConnectUnit(UNKNOWN_EVENT, noop, "player")
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit:OnceUnit eventName", UNKNOWN_EVENT),
                function()
                    EventKit:OnceUnit(UNKNOWN_EVENT, noop, "player")
                end
            )

            assert.are.equal(0, #TestEnv.Frames())
            assert.is_nil(next(EventKit._state.regularChannels))
            assert.is_nil(next(EventKit._state.unitGroups))
        end)

        it("refuses an unknown name at the caller's line in every scope method", function()
            local scope = EventKit:CreateScope()
            expectCallerError(
                unknownEventMessage("EventKit.Scope:Connect eventName", UNKNOWN_EVENT),
                function()
                    scope:Connect(UNKNOWN_EVENT, noop)
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit.Scope:Once eventName", UNKNOWN_EVENT),
                function()
                    scope:Once(UNKNOWN_EVENT, noop)
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit.Scope:ConnectUnit eventName", UNKNOWN_EVENT),
                function()
                    scope:ConnectUnit(UNKNOWN_EVENT, noop, "player", "target")
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit.Scope:OnceUnit eventName", UNKNOWN_EVENT),
                function()
                    scope:OnceUnit(UNKNOWN_EVENT, noop, "player")
                end
            )

            assert.are.equal(0, scope:GetActiveCount())
            assert.are.equal(0, #TestEnv.Frames())
        end)

        it("connects a known name normally, asking the client once per call", function()
            local calls = 0
            local connection = EventKit:Connect("PLAYER_LOGIN", function()
                calls = calls + 1
            end)
            assert.are.equal(1, TestEnv.EventValidityChecks())
            local unit = EventKit:ConnectUnit("UNIT_HEALTH", noop, "player")
            assert.are.equal(2, TestEnv.EventValidityChecks())

            TestEnv.Emit("PLAYER_LOGIN")
            assert.are.equal(1, calls)
            assert.is_true(connection:IsConnected())
            assert.is_true(unit:IsConnected())
            assert.are.equal(1, registrationsOf("PLAYER_LOGIN"))
            assert.are.equal(1, registrationsOf("UNIT_HEALTH"))
        end)

        it("checks the type, then a secret, before it asks the client", function()
            expectCallerError("EventKit:Connect eventName must be a non-empty string", function()
                EventKit:Connect(42, noop)
            end)
            expectCallerError("EventKit:Connect eventName must be a non-empty string", function()
                EventKit:Connect("", noop)
            end)
            assert.are.equal(0, TestEnv.EventValidityChecks())

            -- The package reads this host global at call time, so the spec installs it in the global table.
            -- selene: allow(global_usage)
            rawset(_G, "issecretvalue", function(value)
                return value == "SECRET_EVENT"
            end)
            expectCallerError("EventKit:Connect eventName must not be a secret value", function()
                EventKit:Connect("SECRET_EVENT", noop)
            end)
            assert.are.equal(0, TestEnv.EventValidityChecks())
        end)

        it("refuses an unknown name before a bad callback or unit token", function()
            expectCallerError(
                unknownEventMessage("EventKit:Connect eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Connect(UNKNOWN_EVENT, "not a function")
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit:ConnectUnit eventName", UNKNOWN_EVENT),
                function()
                    EventKit:ConnectUnit(UNKNOWN_EVENT, noop)
                end
            )
        end)

        it("follows the client's answer when it changes", function()
            expectCallerError(
                unknownEventMessage("EventKit:Connect eventName", "LATER_EVENT"),
                function()
                    EventKit:Connect("LATER_EVENT", noop)
                end
            )
            TestEnv.SetEventKnown("LATER_EVENT", true)
            local connection = EventKit:Connect("LATER_EVENT", noop)
            assert.is_true(connection:IsConnected())
        end)

        it("does not check the events EventKit registers for itself", function()
            -- Neither PLAYER_LOGOUT nor the combat-log event is known to this client.
            local scope = EventKit:ForAddon("MyAddon")
            assert.are.equal(1, registrationsOf("PLAYER_LOGOUT"))
            local connection = scope:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.is_true(connection:IsConnected())
            assert.are.equal(1, registrationsOf("COMBAT_LOG_EVENT_UNFILTERED"))
            assert.are.equal(0, TestEnv.EventValidityChecks())

            TestEnv.Emit("PLAYER_LOGOUT")
            assert.is_true(scope:IsClosed())
        end)

        it("refuses an unknown Derive event, as a name or a list entry", function()
            expectCallerError(
                unknownEventMessage("EventKit:Derive eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Derive(UNKNOWN_EVENT, noop)
                end
            )
            expectCallerError(
                unknownEventMessage("EventKit:Derive events entry", UNKNOWN_EVENT),
                function()
                    EventKit:Derive({ "BAG_UPDATE", UNKNOWN_EVENT }, noop)
                end
            )
            local scope = EventKit:CreateScope()
            expectCallerError(
                unknownEventMessage("EventKit.Scope:Derive events entry", UNKNOWN_EVENT),
                function()
                    scope:Derive({ UNKNOWN_EVENT }, noop)
                end
            )
            expectNothingRegistered()
            assert.are.equal(0, scope:GetActiveCount())

            local derived = EventKit:Derive({ "BAG_UPDATE", "PLAYER_LOGIN" }, noop)
            assert.is_false(derived:IsClosed())
            assert.are.equal(1, registrationsOf("BAG_UPDATE"))
        end)

        it("asks the client once per distinct list entry, after the length bound", function()
            EventKit:Derive({ "BAG_UPDATE", "BAG_UPDATE", "PLAYER_LOGIN" }, noop)
            assert.are.equal(2, TestEnv.EventValidityChecks())

            local tooMany = {}
            for index = 1, 33 do
                tooMany[index] = "EVENT_" .. index
            end
            expectCallerError("EventKit:Derive accepts at most 32 distinct events", function()
                EventKit:Derive(tooMany, noop)
            end)
            assert.are.equal(2, TestEnv.EventValidityChecks())
        end)
    end)

    describe("with SchedulerKit, on a client with C_EventUtils.IsEventValid", function()
        it("refuses an unknown Coalesce event before anything is connected", function()
            local EventKit = Scheduled.NewEventKitKnowingEvents(KNOWN_EVENTS)
            expectCallerError(
                unknownEventMessage("EventKit:Coalesce eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Coalesce(UNKNOWN_EVENT, 0.1, noop)
                end
            )
            local scope = EventKit:CreateScope()
            expectCallerError(
                unknownEventMessage("EventKit.Scope:Coalesce events entry", UNKNOWN_EVENT),
                function()
                    scope:Coalesce({ "UNIT_HEALTH", UNKNOWN_EVENT }, 0.1, noop, {
                        units = { "player" },
                    })
                end
            )
            assert.are.equal(0, scope:GetActiveCount())
            assert.are.equal(0, #Scheduled.Frames())

            local handle = scope:Coalesce({ "UNIT_HEALTH", "UNIT_POWER_UPDATE" }, 0.1, noop)
            assert.is_false(handle:IsClosed())
            assert.are.equal(1, scope:GetActiveCount())
        end)
    end)

    describe("probing", function()
        it("reads C_EventUtils.IsEventValid once, when EventKit loads", function()
            local EventKit = TestEnv.NewPackageKnowingEvents(KNOWN_EVENTS)
            -- Removing the namespace after load changes nothing: the function was kept.
            -- selene: allow(global_usage)
            rawset(_G, "C_EventUtils", nil)
            expectCallerError(
                unknownEventMessage("EventKit:Connect eventName", UNKNOWN_EVENT),
                function()
                    EventKit:Connect(UNKNOWN_EVENT, noop)
                end
            )
        end)

        it("refuses only a plain false answer from the client", function()
            TestEnv.Reset()
            TestEnv.InstallWowApi()
            -- A client quirk (no answer, or a non-boolean one) must never refuse a real event.
            -- selene: allow(global_usage)
            rawset(_G, "C_EventUtils", {
                IsEventValid = function(eventName)
                    if eventName == "STRING_ANSWER" then
                        return "yes"
                    elseif eventName == "FALSE_ANSWER" then
                        return false
                    end
                    return nil
                end,
            })
            require("Registry")
            require("SignalKit")
            local EventKit = require("EventKit")

            assert.is_true(EventKit:Connect("NIL_ANSWER", noop):IsConnected())
            assert.is_true(EventKit:Connect("STRING_ANSWER", noop):IsConnected())
            expectCallerError(
                unknownEventMessage("EventKit:Connect eventName", "FALSE_ANSWER"),
                function()
                    EventKit:Connect("FALSE_ANSWER", noop)
                end
            )
        end)

        it("ignores a C_EventUtils installed after EventKit loaded", function()
            local EventKit = TestEnv.NewPackage()
            TestEnv.InstallEventValidity(KNOWN_EVENTS)

            local connection = EventKit:Connect(UNKNOWN_EVENT, noop)

            assert.is_true(connection:IsConnected())
            assert.are.equal(0, TestEnv.EventValidityChecks())
        end)
    end)

    describe("on a client without C_EventUtils.IsEventValid", function()
        local EventKit
        before_each(function()
            EventKit = TestEnv.NewPackage()
        end)

        it("leaves an unknown name to the host's registration, as before", function()
            local connection = EventKit:Connect(UNKNOWN_EVENT, noop)
            assert.is_true(connection:IsConnected())
            assert.are.equal(1, registrationsOf(UNKNOWN_EVENT))

            local derived = EventKit:Derive({ "OTHER_UNKNOWN_EVENT" }, noop)
            assert.is_false(derived:IsClosed())
        end)

        it("still raises the host's refusal at the caller's line", function()
            TestEnv.FailNextRegisterEvent()
            expectCallerError(
                "EventKit:Connect could not register event " .. UNKNOWN_EVENT,
                function()
                    EventKit:Connect(UNKNOWN_EVENT, noop)
                end
            )
            assert.is_nil(next(EventKit._state.regularChannels))
        end)
    end)
end)
