local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/Bus_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    TestEnv.ExpectRefusalAtCaller(SPEC_FILE, expected, callback)
end

describe("SignalKit named buses", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    it("shares one bus per name", function()
        local first = SignalKit:Bus("Alpha")
        local second = SignalKit:Bus("Alpha")
        local other = SignalKit:Bus("Beta")

        assert.are.equal(first, second)
        assert.are_not.equal(first, other)
    end)

    it("lets two parties that share no reference talk through a bus name", function()
        local received

        SignalKit:Bus("Shared"):Subscribe("Changed", function(value)
            received = value
        end)
        SignalKit:Bus("Shared"):DeclareTopic("Changed", { arguments = 1 })
        SignalKit:Bus("Shared"):Publish("Changed", 42)

        assert.are.equal(42, received)
    end)

    it("refuses a bus beyond maxBuses with nil and full", function()
        for index = 1, 64 do
            assert.is_not_nil(SignalKit:Bus("Bus" .. index))
        end

        local bus, reason = SignalKit:Bus("OneTooMany")

        assert.is_nil(bus)
        assert.are.equal("full", reason)
        -- An existing name is still answered once the cap is reached.
        assert.is_not_nil(SignalKit:Bus("Bus1"))
    end)

    it("validates bus names, options and the facade receiver at the caller", function()
        expectRefusalAtCaller("SignalKit:Bus name must be a non-empty string", function()
            SignalKit:Bus("")
        end)
        expectRefusalAtCaller("SignalKit:Bus options must be a table or nil", function()
            SignalKit:Bus("Alpha", true)
        end)
        expectRefusalAtCaller("options.openTopics must be a boolean or nil", function()
            SignalKit:Bus("Alpha", { openTopics = "yes" })
        end)
        expectRefusalAtCaller("must be called on the SignalKit facade", function()
            SignalKit.Bus("Alpha")
        end)
        expectRefusalAtCaller("must be called on the SignalKit facade", function()
            SignalKit:New():Bus("Alpha")
        end)
    end)

    it("refuses a second request that states a different topic policy", function()
        SignalKit:Bus("Alpha")

        expectRefusalAtCaller("already exists with a different openTopics policy", function()
            SignalKit:Bus("Alpha", { openTopics = true })
        end)
        -- Omitting the options accepts whatever policy the bus already has.
        assert.is_not_nil(SignalKit:Bus("Alpha"))
        assert.is_not_nil(SignalKit:Bus("Alpha", { openTopics = false }))
    end)

    it("names a bus method called without its receiver", function()
        local bus = SignalKit:Bus("Alpha")

        expectRefusalAtCaller("SignalKit.Bus:Publish must be called on a SignalKit bus", function()
            bus.Publish("Topic")
        end)
        expectRefusalAtCaller(
            "SignalKit.Bus:Subscribe must be called on a SignalKit bus",
            function()
                bus.Subscribe("Topic", function() end)
            end
        )
    end)
end)

describe("SignalKit bus topic policy", function()
    local SignalKit
    local bus

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        bus = SignalKit:Bus("Policy")
    end)

    after_each(TestEnv.Reset)

    it("refuses Publish on an undeclared topic at the caller", function()
        expectRefusalAtCaller('topic "Typo" is not declared on bus "Policy"', function()
            bus:Publish("Typo", 1)
        end)
    end)

    it("refuses an undeclared topic even when it has subscribers", function()
        local calls = 0
        bus:Subscribe("Pending", function()
            calls = calls + 1
        end)

        expectRefusalAtCaller("is not declared", function()
            bus:Publish("Pending")
        end)
        assert.are.equal(0, calls)
    end)

    it("delivers undeclared topics on a bus created with openTopics", function()
        local open = SignalKit:Bus("Open", { openTopics = true })
        local received

        open:Subscribe("Anything", function(value)
            received = value
        end)
        open:Publish("Anything", "delivered")
        -- Nobody subscribed: a no-op rather than a refusal.
        open:Publish("Nobody")

        assert.are.equal("delivered", received)
    end)

    it("still applies a declared policy on an open bus", function()
        local open = SignalKit:Bus("Open", { openTopics = true })
        open:DeclareTopic("Counted", { arguments = 2 })

        expectRefusalAtCaller("expected 2 arguments, got 1", function()
            open:Publish("Counted", 1)
        end)
    end)

    it("refuses the wrong argument count at the caller, counting explicit nils", function()
        bus:DeclareTopic("Pair", { arguments = 2 })
        local count

        bus:Subscribe("Pair", function(...)
            count = select("#", ...)
        end)

        expectRefusalAtCaller("expected 2 arguments, got 3", function()
            bus:Publish("Pair", 1, 2, 3)
        end)
        expectRefusalAtCaller("expected 2 arguments, got 1", function()
            bus:Publish("Pair", 1)
        end)

        bus:Publish("Pair", 1, nil)
        assert.are.equal(2, count)
    end)

    it("refuses arguments a validator rejects, with its reason, at the caller", function()
        bus:DeclareTopic("Level", {
            arguments = function(level)
                if type(level) ~= "number" then
                    return false, "level must be a number"
                end
                return true
            end,
            description = "The player's level changed.",
        })
        local received

        bus:Subscribe("Level", function(level)
            received = level
        end)

        expectRefusalAtCaller("refused its arguments: level must be a number", function()
            bus:Publish("Level", "sixty")
        end)
        assert.is_nil(received)

        bus:Publish("Level", 60)
        assert.are.equal(60, received)
    end)

    it("treats anything but true from a validator as a refusal", function()
        bus:DeclareTopic("Strict", {
            arguments = function()
                return 1
            end,
        })

        expectRefusalAtCaller("the validator gave no reason", function()
            bus:Publish("Strict")
        end)
    end)

    it("never prints a secret refusal reason", function()
        -- The package reads this host global at call time, so the spec installs it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return value == "secret reason"
        end)
        bus:DeclareTopic("Guarded", {
            arguments = function()
                return false, "secret reason"
            end,
        })

        local ok, message = pcall(function()
            bus:Publish("Guarded")
        end)
        -- The package reads this host global at call time, so the spec removes it from the global table.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", nil)

        assert.is_false(ok)
        assert.is_not_nil(
            string.find(tostring(message), "the validator gave a secret reason", 1, true)
        )
        assert.is_nil(string.find(tostring(message), ": secret reason", 1, true))
    end)

    it("turns a raising validator into a refusal at the publisher's line", function()
        local delivered = false
        bus:DeclareTopic("Fragile", {
            arguments = function(value)
                return value.missing.field == 1
            end,
        })
        bus:Subscribe("Fragile", function()
            delivered = true
        end)

        local ok, message = pcall(function()
            bus:Publish("Fragile", "sensitive argument")
        end)
        message = tostring(message)

        assert.is_false(ok)
        assert.is_not_nil(
            string.find(message, SPEC_FILE, 1, true),
            "the refusal must point at the publishing line: " .. message
        )
        assert.is_not_nil(
            string.find(
                message,
                'SignalKit.Bus:Publish validator for topic "Fragile" on bus "Policy" failed: ',
                1,
                true
            )
        )
        assert.is_nil(string.find(message, "sensitive argument", 1, true))
        assert.is_false(delivered)
    end)

    it("reports a validator that raises a non-string error without printing it", function()
        bus:DeclareTopic("Odd", {
            arguments = function()
                error({ code = 1 })
            end,
        })

        expectRefusalAtCaller("failed: a non-string error", function()
            bus:Publish("Odd")
        end)
    end)

    it("refuses a secret bus name or topic before comparing it", function()
        local secret = setmetatable({}, {
            __eq = function()
                error("compared a secret value")
            end,
        })
        -- The package reads this host global at call time, so the spec installs a local stub in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return rawequal(value, secret)
        end)

        expectRefusalAtCaller("SignalKit:Bus name must not be a secret value", function()
            SignalKit:Bus(secret)
        end)
        expectRefusalAtCaller("SignalKit.Bus:Publish topic must not be a secret value", function()
            bus:Publish(secret)
        end)
        expectRefusalAtCaller("SignalKit.Bus:Subscribe topic must not be a secret value", function()
            bus:Subscribe(secret, function() end)
        end)
        expectRefusalAtCaller(
            "SignalKit.Bus:DeclareTopic topic must not be a secret value",
            function()
                bus:DeclareTopic(secret)
            end
        )

        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", nil)
    end)

    it("accepts a repeated declaration with the same policy and refuses a different one", function()
        local validator = function()
            return true
        end

        assert.is_true(bus:DeclareTopic("Twice", { arguments = validator }))
        assert.is_true(bus:DeclareTopic("Twice", { arguments = validator }))

        expectRefusalAtCaller("already declared", function()
            bus:DeclareTopic("Twice", { arguments = 1 })
        end)
    end)

    it("validates DeclareTopic arguments at the caller", function()
        expectRefusalAtCaller("topic must be a non-empty string", function()
            bus:DeclareTopic(42)
        end)
        expectRefusalAtCaller("options must be a table or nil", function()
            bus:DeclareTopic("Topic", "options")
        end)
        expectRefusalAtCaller("count must be a finite non-negative integer", function()
            bus:DeclareTopic("Topic", { arguments = 1.5 })
        end)
        expectRefusalAtCaller("count must be a finite non-negative integer", function()
            bus:DeclareTopic("Topic", { arguments = math.huge })
        end)
        expectRefusalAtCaller("count must be a finite non-negative integer", function()
            bus:DeclareTopic("Topic", { arguments = 0 / 0 })
        end)
        expectRefusalAtCaller("count must be a finite non-negative integer", function()
            bus:DeclareTopic("Topic", { arguments = -1 })
        end)
        expectRefusalAtCaller("must be a count, a validator function or nil", function()
            bus:DeclareTopic("Topic", { arguments = "two" })
        end)
        expectRefusalAtCaller("options.description must be a string or nil", function()
            bus:DeclareTopic("Topic", { description = 7 })
        end)
    end)

    it("refuses a topic beyond maxTopics with nil and full", function()
        for index = 1, 256 do
            assert.is_true(bus:DeclareTopic("Topic" .. index))
        end

        local declared, reason = bus:DeclareTopic("OneTooMany")
        assert.is_nil(declared)
        assert.are.equal("full", reason)

        local connection, subscribeReason = bus:Subscribe("AlsoTooMany", function() end)
        assert.is_nil(connection)
        assert.are.equal("full", subscribeReason)
    end)

    it("lists declared topics sorted, leaving out topics only subscribed to", function()
        bus:DeclareTopic("Zulu")
        bus:DeclareTopic("Alpha")
        bus:DeclareTopic("Mike")
        bus:Subscribe("Undeclared", function() end)

        assert.are.same({ "Alpha", "Mike", "Zulu" }, bus:Topics())
        assert.are.same({}, SignalKit:Bus("Empty"):Topics())
    end)
end)

describe("SignalKit bus subscriptions", function()
    local SignalKit
    local bus

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        bus = SignalKit:Bus("Subscriptions", { openTopics = true })
    end)

    after_each(TestEnv.Reset)

    it("returns a SignalKit connection handle", function()
        local calls = 0
        local connection = bus:Subscribe("Topic", function()
            calls = calls + 1
        end)

        assert.are.equal(SignalKit.Connection.Disconnect, connection.Disconnect)
        assert.is_true(connection:IsConnected())

        bus:Publish("Topic")
        assert.is_true(connection:Disconnect())
        assert.is_false(connection:Disconnect())
        bus:Publish("Topic")

        assert.are.equal(1, calls)
        assert.is_false(connection:IsConnected())
    end)

    it("delivers a SubscribeOnce callback at most once, even when it republishes", function()
        local calls = 0
        local connection
        connection = bus:SubscribeOnce("Topic", function()
            calls = calls + 1
            assert.is_false(connection:IsConnected())
            bus:Publish("Topic")
        end)

        bus:Publish("Topic")
        bus:Publish("Topic")

        assert.are.equal(1, calls)
    end)

    it("forwards every argument including nil values", function()
        local count, first, second, third

        bus:Subscribe("Topic", function(...)
            count = select("#", ...)
            first, second, third = ...
        end)
        bus:Publish("Topic", "player", nil, 42)

        assert.are.equal(3, count)
        assert.are.equal("player", first)
        assert.is_nil(second)
        assert.are.equal(42, third)
    end)

    it("Unsubscribe disconnects every subscription of that callback to that topic", function()
        local calls = {}
        local shared = function(tag)
            calls[#calls + 1] = tag
        end
        local first = bus:Subscribe("Topic", shared)
        bus:Subscribe("Topic", shared)
        local other = bus:Subscribe("Other", shared)
        bus:Subscribe("Topic", function()
            calls[#calls + 1] = "kept"
        end)

        assert.are.equal(2, bus:Unsubscribe("Topic", shared))
        assert.are.equal(0, bus:Unsubscribe("Topic", shared))
        assert.are.equal(0, bus:Unsubscribe("Unknown", shared))

        bus:Publish("Topic", "topic")
        bus:Publish("Other", "other")

        assert.is_false(first:IsConnected())
        assert.is_true(other:IsConnected())
        assert.are.same({ "kept", "other" }, calls)
    end)

    it("refuses a subscription beyond maxListeners with nil and full", function()
        local connections = {}
        for index = 1, 256 do
            connections[index] = bus:Subscribe("Crowded", function() end)
            assert.is_not_nil(connections[index])
        end

        local refused, reason = bus:SubscribeOnce("Crowded", function() end)
        assert.is_nil(refused)
        assert.are.equal("full", reason)

        -- A disconnect frees a slot at once, tombstone or not.
        connections[1]:Disconnect()
        assert.is_not_nil(bus:Subscribe("Crowded", function() end))
    end)

    it("validates Subscribe, SubscribeOnce and Unsubscribe arguments at the caller", function()
        expectRefusalAtCaller("SignalKit.Bus:Subscribe topic must be a non-empty string", function()
            bus:Subscribe("", function() end)
        end)
        expectRefusalAtCaller("SignalKit.Bus:Subscribe callback must be a function", function()
            bus:Subscribe("Topic", "callback")
        end)
        expectRefusalAtCaller("SignalKit.Bus:SubscribeOnce callback must be a function", function()
            bus:SubscribeOnce("Topic", nil)
        end)
        expectRefusalAtCaller("SignalKit.Bus:Unsubscribe callback must be a function", function()
            bus:Unsubscribe("Topic", {})
        end)
        expectRefusalAtCaller("SignalKit.Bus:Publish topic must be a non-empty string", function()
            bus:Publish(nil)
        end)
    end)
end)

describe("SignalKit bus dispatch semantics", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
        TestEnv.InstallHostErrorHandler()
    end)

    after_each(TestEnv.Reset)

    ---Run one scenario covering order, connect and disconnect during dispatch,
    ---a once-listener and a nested dispatch, and return its trace.
    ---@param connect fun(callback: function): table connection handle
    ---@param once fun(callback: function): table connection handle
    ---@param dispatch fun(depth: integer)
    ---@return string[]
    local function runScenario(connect, once, dispatch)
        local trace = {}
        local victim
        local added = false

        connect(function(depth)
            trace[#trace + 1] = "first:" .. depth
            if not added then
                added = true
                connect(function(innerDepth)
                    trace[#trace + 1] = "late:" .. innerDepth
                end)
            end
            if depth == 1 then
                dispatch(2)
            end
        end)
        once(function(depth)
            trace[#trace + 1] = "once:" .. depth
        end)
        connect(function(depth)
            trace[#trace + 1] = "second:" .. depth
            if depth == 1 then
                victim:Disconnect()
            end
        end)
        victim = connect(function(depth)
            trace[#trace + 1] = "victim:" .. depth
        end)

        dispatch(1)
        dispatch(3)
        return trace
    end

    it("orders, mutates and re-enters exactly like a raw signal", function()
        local signal = SignalKit:New()
        local signalTrace = runScenario(function(callback)
            return signal:Connect(callback)
        end, function(callback)
            return signal:Once(callback)
        end, function(depth)
            signal:Fire(depth)
        end)

        local bus = SignalKit:Bus("Semantics")
        bus:DeclareTopic("Topic", { arguments = 1 })
        local busTrace = runScenario(function(callback)
            return bus:Subscribe("Topic", callback)
        end, function(callback)
            return bus:SubscribeOnce("Topic", callback)
        end, function(depth)
            bus:Publish("Topic", depth)
        end)

        assert.are.same(signalTrace, busTrace)
        assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("keeps topics of one bus and equal topics of two buses apart", function()
        local calls = {}
        local first = SignalKit:Bus("First", { openTopics = true })
        local second = SignalKit:Bus("Second", { openTopics = true })

        first:Subscribe("Topic", function()
            calls[#calls + 1] = "first"
        end)
        first:Subscribe("Other", function()
            calls[#calls + 1] = "other"
        end)
        second:Subscribe("Topic", function()
            calls[#calls + 1] = "second"
        end)

        first:Publish("Topic")

        assert.are.same({ "first" }, calls)
    end)
end)
