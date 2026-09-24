local TestEnv = require("EventKitTestEnv")

local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"
local SPEC_FILE = "packages/eventKit/tests/CombatLog_spec.lua:"

local function noop() end

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

---Assert `callback` raises `expected`, reported at a line of this spec file.
---@param expected string
---@param callback function
local function expectCallerError(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true))
    assert.is_not_nil(string.find(message, SPEC_FILE, 1, true))
    assert.is_nil(string.find(message, "src/EventKit.lua", 1, true))
end

---Copy a call's arguments into an array that also remembers their count, so
---a spec can see `nil` holes and trailing `nil`s the array alone would hide.
---@return table call the arguments, with the count under `count`
local function recordArguments(...)
    local call = { ... }
    call.count = select("#", ...)
    return call
end

---Connect a listener that records every call through `recordArguments`.
---@param subscribe fun(callback: function): table
---@return table[] calls
---@return table connection
local function recordCalls(subscribe)
    local calls = {}
    local connection = subscribe(function(...)
        calls[#calls + 1] = recordArguments(...)
    end)
    return calls, connection
end

describe("EventKit combat-log routing", function()
    local EventKit
    before_each(function()
        EventKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    describe("routing", function()
        it("delivers a sub-event only to the listeners of that sub-event", function()
            local damage = recordCalls(function(callback)
                return EventKit:ConnectCombatLog("SPELL_DAMAGE", callback)
            end)
            local swings = recordCalls(function(callback)
                return EventKit:ConnectCombatLog("SWING_DAMAGE", callback)
            end)

            TestEnv.EmitCombatLogEvent(1.5, "SPELL_DAMAGE", false, "Player-1")
            TestEnv.EmitCombatLogEvent(2.5, "SWING_DAMAGE", false, "Player-2")
            TestEnv.EmitCombatLogEvent(3.5, "SPELL_HEAL", false, "Player-3")

            assert.are.equal(1, #damage)
            assert.are.equal("SPELL_DAMAGE", damage[1][2])
            assert.are.equal(1, #swings)
            assert.are.equal("SWING_DAMAGE", swings[1][2])
        end)

        it("forwards every return unchanged, whatever their count", function()
            local calls = recordCalls(function(callback)
                return EventKit:ConnectCombatLog("SPELL_DAMAGE", callback)
            end)

            -- The eleven base values, holes included.
            TestEnv.EmitCombatLogEvent(
                1.5,
                "SPELL_DAMAGE",
                false,
                "Player-1",
                nil,
                0x511,
                0,
                "Creature-2",
                "Target",
                0x10a48,
                0
            )
            -- The same base values with a spell suffix, and a trailing nil.
            TestEnv.EmitCombatLogEvent(
                2.5,
                "SPELL_DAMAGE",
                false,
                "Player-1",
                "Source",
                0x511,
                0,
                "Creature-2",
                "Target",
                0x10a48,
                0,
                12345,
                "Fireball",
                4,
                987,
                nil
            )

            assert.are.equal(2, #calls)
            local first = calls[1]
            assert.are.equal(11, first.count)
            assert.are.equal(1.5, first[1])
            assert.are.equal("SPELL_DAMAGE", first[2])
            assert.is_false(first[3])
            assert.are.equal("Player-1", first[4])
            assert.is_nil(first[5])
            assert.are.equal(0x511, first[6])
            assert.are.equal(0, first[11])

            local second = calls[2]
            assert.are.equal(16, second.count)
            assert.are.equal("Source", second[5])
            assert.are.equal(12345, second[12])
            assert.are.equal("Fireball", second[13])
            assert.are.equal(987, second[15])
            assert.is_nil(second[16])
        end)

        it("forwards payloads wider than the inline isolation slots", function()
            local calls = recordCalls(function(callback)
                return EventKit:ConnectCombatLog("*", callback)
            end)
            local wide = {}
            for index = 1, 24 do
                wide[index] = index
            end
            wide[2] = "SPELL_PERIODIC_DAMAGE"

            TestEnv.EmitCombatLogEvent(unpack(wide, 1, 24))

            assert.are.equal(24, calls[1].count)
            assert.are.equal(1, calls[1][1])
            assert.are.equal("SPELL_PERIODIC_DAMAGE", calls[1][2])
            assert.are.equal(24, calls[1][24])
        end)

        it("reads CombatLogGetCurrentEventInfo exactly once per event", function()
            for _ = 1, 3 do
                EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
                EventKit:ConnectCombatLog("SWING_DAMAGE", noop)
                EventKit:ConnectCombatLog("*", noop)
            end
            -- A plain listener on the event reads nothing through EventKit.
            EventKit:Connect(COMBAT_LOG_EVENT, noop)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(1, TestEnv.CombatLogEventInfoReads())

            TestEnv.EmitCombatLogEvent(2, "SWING_DAMAGE")
            TestEnv.EmitCombatLogEvent(3, "SPELL_HEAL")
            assert.are.equal(3, TestEnv.CombatLogEventInfoReads())
        end)

        it("costs one read and nothing else for a sub-event nobody listens for", function()
            local calls = 0
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
            end)

            TestEnv.EmitCombatLogEvent(1, "UNIT_DIED", false, "Creature-1")

            assert.are.equal(0, calls)
            assert.are.equal(1, TestEnv.CombatLogEventInfoReads())
            assert.is_nil(EventKit._state.combatLog.routes.UNIT_DIED)
        end)

        it("delivers every sub-event to a wildcard listener, after the sub-event's own", function()
            local order = {}
            EventKit:ConnectCombatLog("*", function(_, subEvent)
                order[#order + 1] = "any:" .. subEvent
            end)
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function(_, subEvent)
                order[#order + 1] = "own:" .. subEvent
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            TestEnv.EmitCombatLogEvent(2, "SWING_DAMAGE")

            assert.are.same({ "own:SPELL_DAMAGE", "any:SPELL_DAMAGE", "any:SWING_DAMAGE" }, order)
        end)

        it("runs the listeners of one sub-event in connection order", function()
            local order = {}
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                order[#order + 1] = "first"
            end)
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                order[#order + 1] = "second"
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

            assert.are.same({ "first", "second" }, order)
        end)

        it("does not run a listener connected during the current dispatch", function()
            local calls = 0
            local added = false
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
                if not added then
                    added = true
                    EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                        calls = calls + 10
                    end)
                end
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(1, calls)
            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")
            assert.are.equal(12, calls)
        end)

        it(
            "does not deliver the current event to a wildcard listener connected during it",
            function()
                local wildcardCalls = 0
                local added = false
                EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                    if not added then
                        added = true
                        EventKit:ConnectCombatLog("*", function()
                            wildcardCalls = wildcardCalls + 1
                        end)
                    end
                end)

                TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
                assert.are.equal(0, wildcardCalls)
                TestEnv.EmitCombatLogEvent(2, "SWING_DAMAGE")
                assert.are.equal(1, wildcardCalls)
            end
        )

        it(
            "still fires a wildcard route dropped by a sub-event listener during the event",
            function()
                local wildcardCalls = 0
                local wildcard = EventKit:ConnectCombatLog("*", function()
                    wildcardCalls = wildcardCalls + 1
                end)
                EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                    wildcard:Disconnect()
                end)

                TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

                assert.are.equal(0, wildcardCalls)
                assert.is_false(EventKit._state.combatLog.anyRoute)
                assert.is_true(TestEnv.Frames()[1].registrations[COMBAT_LOG_EVENT] ~= nil)
            end
        )

        it("allocates nothing per event across sub-events and the wildcard #allocation", function()
            local sink = 0
            for _ = 1, 4 do
                EventKit:ConnectCombatLog(
                    "SPELL_DAMAGE",
                    function(timestamp, _, _, _, _, _, _, _, _, _, _, amount)
                        sink = sink + timestamp + amount
                    end
                )
                EventKit:ConnectCombatLog("*", function(timestamp)
                    sink = sink + timestamp
                end)
            end
            TestEnv.SetCombatLogEventInfo(
                1,
                "SPELL_DAMAGE",
                false,
                "Player-1",
                "Source",
                0x511,
                0,
                "Creature-2",
                "Target",
                0x10a48,
                0,
                12345,
                "Fireball",
                4,
                987
            )

            -- Tolerance covers interpreter bookkeeping unrelated to dispatch. A
            -- per-event closure or argument table would be orders of magnitude
            -- larger than this across 20000 events.
            local allocated = allocatedKilobytes(function()
                for _ = 1, 20000 do
                    TestEnv.Emit(COMBAT_LOG_EVENT)
                end
            end)

            assert.is_true(allocated < 4)
        end)
    end)

    describe("host registration", function()
        it("registers the combat-log event with the first listener only", function()
            assert.are.equal(0, #TestEnv.Frames())

            local first = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            local frame = TestEnv.Frames()[1]
            assert.are.same({ COMBAT_LOG_EVENT }, frame.registerEventCalls)

            local second = EventKit:ConnectCombatLog("SWING_DAMAGE", noop)
            local third = EventKit:ConnectCombatLog("*", noop)
            assert.are.equal(1, #frame.registerEventCalls)

            first:Disconnect()
            second:Disconnect()
            assert.are.equal(0, #frame.unregisterEventCalls)
            assert.is_not_nil(frame.registrations[COMBAT_LOG_EVENT])

            third:Disconnect()
            assert.are.same({ COMBAT_LOG_EVENT }, frame.unregisterEventCalls)
            assert.is_nil(frame.registrations[COMBAT_LOG_EVENT])
        end)

        it("detaches the router with its last listener and re-attaches for the next", function()
            local state = EventKit._state
            local connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.are.equal(1, state.combatLog.listenerCount)
            assert.is_table(state.combatLog.channel)
            assert.is_function(state.combatLog.readEventInfo)

            connection:Disconnect()
            assert.are.equal(0, state.combatLog.listenerCount)
            assert.is_false(state.combatLog.channel)
            assert.is_false(state.combatLog.inner)
            assert.is_false(state.combatLog.readEventInfo)
            assert.is_nil(next(state.combatLog.routes))
            assert.is_false(state.combatLog.anyRoute)

            local calls = 0
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
            end)
            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(1, calls)
            assert.are.equal(2, #TestEnv.Frames()[1].registerEventCalls)
        end)

        it("keeps the registration for a plain Connect made before the router", function()
            local plainCalls = {}
            local plain = EventKit:Connect(COMBAT_LOG_EVENT, function(...)
                plainCalls[#plainCalls + 1] = recordArguments(...)
            end)
            local frame = TestEnv.Frames()[1]
            local routed = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.are.equal(1, #frame.registerEventCalls)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            -- The plain listener still sees the payload-free event.
            assert.are.equal(1, plainCalls[1].count)
            assert.are.equal(COMBAT_LOG_EVENT, plainCalls[1][1])

            routed:Disconnect()
            assert.are.equal(0, #frame.unregisterEventCalls)
            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")
            assert.are.equal(2, #plainCalls)

            plain:Disconnect()
            assert.are.same({ COMBAT_LOG_EVENT }, frame.unregisterEventCalls)
        end)

        it("keeps the registration for a plain Connect made after the router", function()
            local routedCalls = 0
            local routed = EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                routedCalls = routedCalls + 1
            end)
            local frame = TestEnv.Frames()[1]
            local plain = EventKit:Connect(COMBAT_LOG_EVENT, noop)
            assert.are.equal(1, #frame.registerEventCalls)

            plain:Disconnect()
            assert.are.equal(0, #frame.unregisterEventCalls)
            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(1, routedCalls)

            routed:Disconnect()
            assert.are.same({ COMBAT_LOG_EVENT }, frame.unregisterEventCalls)
        end)

        it("leaves nothing behind when the host refuses the registration", function()
            TestEnv.FailNextRegisterEvent()
            expectCallerError("EventKit:ConnectCombatLog could not register event", function()
                EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            end)

            local state = EventKit._state
            assert.is_false(state.combatLog.channel)
            assert.are.equal(0, state.combatLog.listenerCount)
            assert.is_nil(next(state.combatLog.routes))
            assert.is_nil(TestEnv.Frames()[1].registrations[COMBAT_LOG_EVENT])

            local connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.is_true(connection:IsConnected())
        end)

        it("refuses at the caller's line without a client reader, registering nothing", function()
            -- The package resolves this host global when its first combat-log listener connects.
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            local scope = EventKit:CreateScope()

            expectCallerError(
                "EventKit:ConnectCombatLog the combat log is not available to addons on this client"
                    .. " (no CombatLogGetCurrentEventInfo reader);"
                    .. " check EventKit:IsCombatLogAvailable() first",
                function()
                    EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
                end
            )
            expectCallerError(
                "EventKit.Scope:ConnectCombatLog the combat log is not available to addons",
                function()
                    scope:ConnectCombatLog("*", noop)
                end
            )

            assert.is_false(EventKit:IsCombatLogAvailable())
            assert.are.equal(0, #TestEnv.Frames())
            assert.are.equal(0, EventKit._state.combatLog.listenerCount)
            assert.is_false(EventKit._state.combatLog.channel)
            assert.is_nil(next(EventKit._state.combatLog.routes))
            assert.are.equal(0, scope:GetActiveCount())
        end)

        it("reads C_CombatLog.GetCurrentEventInfo when the global is absent", function()
            -- Current classic clients document only the namespaced function; the package resolves either
            -- host API when its first listener connects.
            -- selene: allow(global_usage)
            local readGlobal = rawget(_G, "CombatLogGetCurrentEventInfo")
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            -- selene: allow(global_usage)
            rawset(_G, "C_CombatLog", { GetCurrentEventInfo = readGlobal })

            local calls = recordCalls(function(callback)
                return EventKit:ConnectCombatLog("SPELL_DAMAGE", callback)
            end)
            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE", false)

            assert.are.equal(1, #calls)
            assert.are.equal(3, calls[1].count)
            assert.are.equal("SPELL_DAMAGE", calls[1][2])
            assert.are.equal(1, TestEnv.CombatLogEventInfoReads())
        end)

        it("keeps routing across duplicate embedding", function()
            local calls = 0
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
            end)
            local reloaded = TestEnv.ReloadPackage()

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

            assert.are.equal(EventKit, reloaded)
            assert.are.equal(1, calls)
        end)
    end)

    describe("IsCombatLogAvailable", function()
        it("answers true when the global reader exists", function()
            assert.is_true(EventKit:IsCombatLogAvailable())
        end)

        it("answers true with only C_CombatLog.GetCurrentEventInfo", function()
            -- The package resolves these host APIs on every call.
            -- selene: allow(global_usage)
            local readGlobal = rawget(_G, "CombatLogGetCurrentEventInfo")
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            -- selene: allow(global_usage)
            rawset(_G, "C_CombatLog", { GetCurrentEventInfo = readGlobal })

            assert.is_true(EventKit:IsCombatLogAvailable())
        end)

        it("answers false on a client that gives addon code no reader", function()
            -- A Retail 12 client: C_CombatLog exists without the reader.
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            -- selene: allow(global_usage)
            rawset(_G, "C_CombatLog", {
                IsCombatLogRestricted = function()
                    return true
                end,
            })

            assert.is_false(EventKit:IsCombatLogAvailable())
        end)

        it("follows a reader installed after load, and ConnectCombatLog agrees", function()
            -- selene: allow(global_usage)
            local readGlobal = rawget(_G, "CombatLogGetCurrentEventInfo")
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            assert.is_false(EventKit:IsCombatLogAvailable())
            assert.is_false(pcall(EventKit.ConnectCombatLog, EventKit, "SPELL_DAMAGE", noop))

            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", readGlobal)
            assert.is_true(EventKit:IsCombatLogAvailable())
            local connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.is_true(connection:IsConnected())
        end)

        it("does not read the combat log, register anything or care about the receiver", function()
            assert.is_true(EventKit.IsCombatLogAvailable())
            assert.are.equal(0, TestEnv.CombatLogEventInfoReads())
            assert.are.equal(0, #TestEnv.Frames())
        end)

        it("allocates nothing #allocation", function()
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", nil)
            -- selene: allow(global_usage)
            rawset(_G, "C_CombatLog", {})
            local isAvailable = EventKit.IsCombatLogAvailable
            isAvailable(EventKit)

            local allocated = allocatedKilobytes(function()
                for _ = 1, 10000 do
                    isAvailable(EventKit)
                end
            end)

            assert.is_true(allocated < 1, "allocated " .. allocated .. " KiB")
        end)
    end)

    describe("connections", function()
        it("returns an ordinary connection handle that disconnects exactly once", function()
            local connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", noop)
            assert.are.equal(EventKit.Connection.Disconnect, connection.Disconnect)
            assert.is_true(connection:IsConnected())
            assert.is_true(connection:Disconnect())
            assert.is_false(connection:Disconnect())
            assert.is_false(connection:IsConnected())
        end)

        it("stops delivering to a disconnected listener and keeps the others", function()
            local firstCalls, secondCalls = 0, 0
            local first = EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                firstCalls = firstCalls + 1
            end)
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                secondCalls = secondCalls + 1
            end)

            first:Disconnect()
            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

            assert.are.equal(0, firstCalls)
            assert.are.equal(1, secondCalls)
        end)

        it("lets a listener disconnect the last listener mid-dispatch", function()
            local calls = 0
            local connection
            connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
                connection:Disconnect()
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")

            assert.are.equal(1, calls)
            assert.is_nil(TestEnv.Frames()[1].registrations[COMBAT_LOG_EVENT])
        end)

        it(
            "lets a plain listener disconnect the last combat-log listener before the router runs",
            function()
                -- The plain listener is connected first, so it runs before the
                -- router on the channel. Detaching the router mid-fire delivers
                -- nothing and keeps the registration for the plain listener.
                local routedCalls = 0
                local routed
                EventKit:Connect(COMBAT_LOG_EVENT, function()
                    if routed ~= nil then
                        routed:Disconnect()
                    end
                end)
                routed = EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                    routedCalls = routedCalls + 1
                end)

                TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

                assert.are.equal(0, routedCalls)
                assert.is_false(routed:IsConnected())
                assert.is_false(EventKit._state.combatLog.channel)
                assert.are.equal(0, #TestEnv.ReportedErrors())
                local frame = TestEnv.Frames()[1]
                assert.is_not_nil(frame.registrations[COMBAT_LOG_EVENT])
                assert.are.equal(0, #frame.unregisterEventCalls)
            end
        )

        it("lets a plain listener connect the first combat-log listener mid-fire", function()
            local routedCalls = 0
            local connected = false
            EventKit:Connect(COMBAT_LOG_EVENT, function()
                if not connected then
                    connected = true
                    EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                        routedCalls = routedCalls + 1
                    end)
                end
            end)

            -- The router joins the channel beyond the current fire boundary,
            -- so the event being dispatched is not delivered to it.
            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(0, routedCalls)
            assert.are.equal(0, #TestEnv.ReportedErrors())
            assert.are.equal(1, #TestEnv.Frames()[1].registerEventCalls)

            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")
            assert.are.equal(1, routedCalls)
        end)

        it("lets the last listener disconnect and reconnect inside its own callback", function()
            local calls = 0
            local connection
            local function listener()
                calls = calls + 1
                connection:Disconnect()
                connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", listener)
            end
            connection = EventKit:ConnectCombatLog("SPELL_DAMAGE", listener)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")

            assert.are.equal(2, calls)
            assert.is_true(connection:IsConnected())
            assert.are.equal(0, #TestEnv.ReportedErrors())
            -- Each reconnect unregisters and re-registers the host event
            -- within the dispatch, the documented price of this pattern.
            local frame = TestEnv.Frames()[1]
            assert.are.equal(3, #frame.registerEventCalls)
            assert.are.equal(2, #frame.unregisterEventCalls)
            assert.is_not_nil(frame.registrations[COMBAT_LOG_EVENT])
        end)
    end)

    describe("isolation", function()
        it("reports a raising listener and keeps delivering to the rest", function()
            local laterCalls = 0
            local plainCalls = 0
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                error("first tenant failure")
            end)
            EventKit:ConnectCombatLog("SPELL_DAMAGE", function()
                laterCalls = laterCalls + 1
            end)
            EventKit:ConnectCombatLog("*", function()
                laterCalls = laterCalls + 1
            end)
            EventKit:Connect(COMBAT_LOG_EVENT, function()
                plainCalls = plainCalls + 1
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

            assert.are.equal(2, laterCalls)
            assert.are.equal(1, plainCalls)
            local reported = TestEnv.ReportedErrors()
            assert.are.equal(1, #reported)
            assert.is_not_nil(string.find(reported[1], "first tenant failure", 1, true))
        end)

        it("reports a raising client read and still delivers to plain listeners", function()
            -- The package resolves this host global when its first combat-log listener connects.
            -- selene: allow(global_usage)
            rawset(_G, "CombatLogGetCurrentEventInfo", function()
                error("client read failure")
            end)
            local routedCalls, plainCalls = 0, 0
            EventKit:ConnectCombatLog("*", function()
                routedCalls = routedCalls + 1
            end)
            EventKit:Connect(COMBAT_LOG_EVENT, function()
                plainCalls = plainCalls + 1
            end)

            TestEnv.Emit(COMBAT_LOG_EVENT)

            assert.are.equal(0, routedCalls)
            assert.are.equal(1, plainCalls)
            local reported = TestEnv.ReportedErrors()
            assert.are.equal(1, #reported)
            assert.is_not_nil(string.find(reported[1], "client read failure", 1, true))
        end)

        it("isolates through securecallfunction when the client has it", function()
            TestEnv.Reset()
            TestEnv.InstallWowApi()
            TestEnv.InstallSecureCallFunction()
            require("Registry")
            require("SignalKit")
            local isolated = require("EventKit")

            local laterCalls = 0
            isolated:ConnectCombatLog("SPELL_DAMAGE", function()
                error("first tenant failure")
            end)
            isolated:ConnectCombatLog("SPELL_DAMAGE", function(_, subEvent)
                laterCalls = laterCalls + 1
                assert.are.equal("SPELL_DAMAGE", subEvent)
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")

            assert.are.equal(1, laterCalls)
            assert.are.equal(1, #TestEnv.ReportedErrors())
        end)
    end)

    describe("scopes", function()
        it("owns scoped combat-log connections like any other", function()
            local scope = EventKit:CreateScope()
            local calls = 0
            local connection = scope:ConnectCombatLog("SPELL_DAMAGE", function()
                calls = calls + 1
            end)
            assert.are.equal(1, scope:GetActiveCount())

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            assert.are.equal(1, calls)

            assert.are.equal(1, scope:DisconnectAll())
            assert.is_false(connection:IsConnected())
            assert.are.equal(0, scope:GetActiveCount())
            assert.is_nil(TestEnv.Frames()[1].registrations[COMBAT_LOG_EVENT])
        end)

        it("closes an addon scope through CloseAddonScopes", function()
            local scope = EventKit:ForAddon("MyAddon")
            scope:ConnectCombatLog("SPELL_DAMAGE", noop)
            scope:ConnectCombatLog("*", noop)

            assert.is_true(EventKit:CloseAddonScopes("MyAddon"))

            assert.are.equal(0, scope:GetActiveCount())
            assert.are.equal(0, EventKit._state.combatLog.listenerCount)
            assert.is_false(EventKit._state.combatLog.anyRoute)
        end)

        it("defers the sweep when a listener closes its scope mid-dispatch", function()
            local scope = EventKit:CreateScope()
            local order = {}
            scope:ConnectCombatLog("SPELL_DAMAGE", function()
                order[#order + 1] = "closer"
                scope:Close()
            end)
            scope:ConnectCombatLog("SPELL_DAMAGE", function()
                order[#order + 1] = "later"
            end)

            TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
            TestEnv.EmitCombatLogEvent(2, "SPELL_DAMAGE")

            -- The delivery in flight completes; nothing is delivered afterwards.
            assert.are.same({ "closer", "later" }, order)
            assert.is_true(scope:IsClosed())
            assert.are.equal(0, scope:GetActiveCount())
            assert.is_nil(TestEnv.Frames()[1].registrations[COMBAT_LOG_EVENT])
        end)

        it("refuses a closed scope at the caller's line", function()
            local scope = EventKit:CreateScope()
            scope:Close()
            expectCallerError(
                "EventKit.Scope:ConnectCombatLog cannot connect in a closed scope",
                function()
                    scope:ConnectCombatLog("SPELL_DAMAGE", noop)
                end
            )
        end)

        it("validates the scope receiver", function()
            expectCallerError(
                "EventKit.Scope:ConnectCombatLog must be called on an EventKit scope",
                function()
                    EventKit.Scope.ConnectCombatLog({}, "SPELL_DAMAGE", noop)
                end
            )
        end)
    end)

    describe("argument errors", function()
        it("rejects an invalid sub-event at the caller's line", function()
            expectCallerError(
                "EventKit:ConnectCombatLog subEvent must be a non-empty string",
                function()
                    EventKit:ConnectCombatLog("", noop)
                end
            )
            expectCallerError(
                "EventKit:ConnectCombatLog subEvent must be a non-empty string",
                function()
                    EventKit:ConnectCombatLog(nil, noop)
                end
            )
            expectCallerError(
                "EventKit:ConnectCombatLog subEvent must be a non-empty string",
                function()
                    EventKit:ConnectCombatLog(42, noop)
                end
            )
        end)

        it("rejects a non-function callback at the caller's line", function()
            expectCallerError("EventKit:ConnectCombatLog callback must be a function", function()
                EventKit:ConnectCombatLog("SPELL_DAMAGE", "nope")
            end)
        end)

        it("names the scope method in errors raised through a scope", function()
            local scope = EventKit:CreateScope()
            expectCallerError(
                "EventKit.Scope:ConnectCombatLog subEvent must be a non-empty string",
                function()
                    scope:ConnectCombatLog("", noop)
                end
            )
            expectCallerError(
                "EventKit.Scope:ConnectCombatLog callback must be a function",
                function()
                    scope:ConnectCombatLog("SPELL_DAMAGE", nil)
                end
            )
        end)

        it("registers nothing when an argument is refused", function()
            pcall(function()
                EventKit:ConnectCombatLog("SPELL_DAMAGE", "nope")
            end)
            assert.are.equal(0, #TestEnv.Frames())
            assert.are.equal(0, EventKit._state.combatLog.listenerCount)
        end)
    end)
end)
