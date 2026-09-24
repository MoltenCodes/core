local TestEnv = require("SignalKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

---The package-wide limits a fresh session starts with.
local DEFAULT_LIMITS = { maxBuses = 64, maxJournalCapacity = 1024, maxJournalArguments = 8 }

describe("SignalKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to be loaded first", function()
        TestEnv.Reset()

        expectErrorContaining("requires Registry API 2", function()
            require("SignalKit")
        end)
    end)

    it("rejects an incomplete existing SignalKit facade before registration", function()
        TestEnv.Reset()
        local Registry = require("Registry")
        Registry:Register("signalKit", 1, 1)

        expectErrorContaining("corrupted or incomplete", function()
            require("SignalKit")
        end)
    end)

    it("rejects an incompatible Registry facade", function()
        TestEnv.Reset()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "MoltenCodes", { Registry = { API = 1 } })

        expectErrorContaining("requires Registry API 2", function()
            require("SignalKit")
        end)
    end)

    it("registers itself as SignalKit API 1 revision 7", function()
        local SignalKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("signalKit", 1)

        assert.are.equal(SignalKit, selected)
        assert.are.equal(7, revision)
        assert.are.equal(1, SignalKit.API)
        assert.are.equal(7, SignalKit.REVISION)
    end)

    it("reuses the same package facade on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local second = TestEnv.ReloadPackage()

        assert.are.equal(first, second)
    end)

    it("does not reset existing signals on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local signal = first:New()
        local calls = 0

        signal:Connect(function()
            calls = calls + 1
        end)

        local second = TestEnv.ReloadPackage()
        signal:Fire()

        assert.are.equal(first, second)
        assert.are.equal(1, calls)
    end)

    it("does not reset buses, topics or subscriptions on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local bus = first:Bus("Kept")
        bus:DeclareTopic("Topic", { arguments = 1 })
        local received
        bus:Subscribe("Topic", function(value)
            received = value
        end)

        local second = TestEnv.ReloadPackage()
        second:Bus("Kept"):Publish("Topic", "still here")

        assert.are.equal(bus, second:Bus("Kept"))
        assert.are.equal("still here", received)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local SignalKit, Registry = TestEnv.NewPackage()
        local shippedRevision = SignalKit.REVISION
        local upgraded, previous = Registry:Register("signalKit", 1, 99)
        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        local futureState = { schema = 999 }
        rawset(SignalKit, "REVISION", 99)
        rawset(SignalKit, "_state", futureState)

        local reloaded = TestEnv.ReloadPackage()

        assert.are.equal(SignalKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
        assert.are.equal(futureState, rawget(reloaded, "_state"))
        assert.are.same({ schema = 999 }, futureState)
    end)

    it("upgrades a revision-3 copy, which had no buses and no state, in place", function()
        TestEnv.Reset()
        require("Registry")
        local SignalKit = TestEnv.LoadRevision(3)
        -- Strip what revision 3 never had, so the facade looks like it did.
        rawset(SignalKit, "_state", nil)
        rawset(SignalKit, "Bus", nil)
        rawset(SignalKit, "ForAddon", nil)
        rawset(SignalKit, "CloseAddonBus", nil)
        rawset(SignalKit, "UNBOUNDED", nil)
        rawset(SignalKit, "SetLimits", nil)
        rawset(SignalKit, "GetLimits", nil)
        rawset(SignalKit, "NewJournal", nil)
        rawset(SignalKit, "GetGeneration", nil)
        local signal = SignalKit:New()
        local calls = 0
        signal:Connect(function()
            calls = calls + 1
        end)

        local upgraded = TestEnv.ReloadPackage()
        signal:Fire()
        local bus = upgraded:Bus("New", { openTopics = true })
        local received
        bus:Subscribe("Topic", function(value)
            received = value
        end)
        bus:Publish("Topic", "delivered")

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(7, upgraded.REVISION)
        assert.are.equal(1, calls)
        assert.are.equal("delivered", received)
    end)

    it("upgrades revision-4 state in place through both later schemas", function()
        TestEnv.Reset()
        require("Registry")
        local SignalKit = TestEnv.LoadRevision(4)
        local bus = SignalKit:Bus("Older")
        -- Reduce the state and the bus to the shape revision 4 left behind.
        local state = rawget(SignalKit, "_state")
        rawset(state, "schema", 1)
        rawset(state, "unbounded", nil)
        rawset(state, "limits", nil)
        for _, field in ipairs({
            "_maxTopics",
            "_maxTopicsStated",
            "_maxListeners",
            "_maxListenersStated",
        }) do
            rawset(bus, field, nil)
        end
        rawset(SignalKit, "UNBOUNDED", nil)
        rawset(SignalKit, "SetLimits", nil)
        rawset(SignalKit, "GetLimits", nil)
        rawset(SignalKit, "NewJournal", nil)
        rawset(SignalKit, "GetGeneration", nil)

        local upgraded = TestEnv.ReloadPackage()

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(7, upgraded.REVISION)
        assert.are.equal(4, rawget(state, "schema"))
        assert.are.equal("table", type(upgraded.UNBOUNDED))
        assert.are.equal(rawget(state, "unbounded"), upgraded.UNBOUNDED)
        assert.are.same(DEFAULT_LIMITS, upgraded:GetLimits())
        for index = 1, 256 do
            assert.is_true((bus:DeclareTopic("Topic" .. index)))
        end
        local declared, reason = bus:DeclareTopic("Beyond")
        assert.is_nil(declared)
        assert.are.equal("full", reason)
        -- The upgraded bus carries unstated defaults, so a first statement sets them.
        assert.are.equal(bus, upgraded:Bus("Older", { maxTopics = 300 }))
        assert.is_true((bus:DeclareTopic("Beyond")))
    end)

    it("keeps set limits and the sentinel identity across a newer revision", function()
        local SignalKit = TestEnv.NewPackage()
        local sentinel = SignalKit.UNBOUNDED
        SignalKit:SetLimits({ maxBuses = 200 })
        local bus = SignalKit:Bus("Opened", { maxTopics = sentinel, maxListeners = 2 })

        local upgraded = TestEnv.LoadRevision(8)

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.same(
            { maxBuses = 200, maxJournalCapacity = 1024, maxJournalArguments = 8 },
            upgraded:GetLimits()
        )
        assert.are.equal(bus, upgraded:Bus("Opened", { maxTopics = sentinel, maxListeners = 2 }))
        for index = 1, 300 do
            assert.is_true((bus:DeclareTopic("Topic" .. index)))
        end
        assert.is_not_nil((bus:Subscribe("Topic1", function() end)))
        assert.is_not_nil((bus:Subscribe("Topic1", function() end)))
        local refused, reason = bus:Subscribe("Topic1", function() end)
        assert.is_nil(refused)
        assert.are.equal("full", reason)
    end)

    it("rejects a same-revision facade whose sentinel differs from its state", function()
        local SignalKit = TestEnv.NewPackage()
        rawset(SignalKit, "UNBOUNDED", {})

        expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("rejects a same-revision state whose limits are invalid", function()
        local SignalKit = TestEnv.NewPackage()
        rawset(rawget(rawget(SignalKit, "_state"), "limits"), "maxBuses", 0)

        expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("carries buses, topics, scopes and subscriptions into a newer revision", function()
        local SignalKit = TestEnv.NewPackage()
        TestEnv.InstallHostErrorHandler()
        local bus = SignalKit:Bus("Carried")
        bus:DeclareTopic("Topic", { arguments = 1 })
        local scope = bus:CreateScope()
        local received = {}
        local connection = scope:Subscribe("Topic", function(value)
            received[#received + 1] = value
        end)

        local upgraded = TestEnv.LoadRevision(8)
        bus:Publish("Topic", "after upgrade")

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(8, upgraded.REVISION)
        assert.are.equal(bus, upgraded:Bus("Carried"))
        assert.are.same({ "Topic" }, bus:Topics())
        assert.are.same({ "after upgrade" }, received)
        assert.has_error(function()
            bus:Publish("Topic")
        end)
        assert.are.equal(1, scope:DisconnectAll())
        assert.is_false(connection:IsConnected())
    end)

    it("upgrades revision-6 state in place: journal prototype, limits, generation", function()
        TestEnv.Reset()
        require("Registry")
        local SignalKit = TestEnv.LoadRevision(6)
        local signal = SignalKit:New()
        local calls = 0
        local connection = signal:Connect(function()
            calls = calls + 1
        end)
        -- Reduce the state, the facade and the signal to the shape revision 6
        -- left behind: no journal tables, no journal limits, no generation and
        -- no hook fields.
        local state = rawget(SignalKit, "_state")
        rawset(state, "schema", 3)
        rawset(state, "journalPrototype", nil)
        rawset(state, "journalMetatable", nil)
        rawset(rawget(state, "limits"), "maxJournalCapacity", nil)
        rawset(rawget(state, "limits"), "maxJournalArguments", nil)
        rawset(SignalKit, "NewJournal", nil)
        rawset(SignalKit, "GetGeneration", nil)
        rawset(signal, "_generation", nil)
        rawset(signal, "_onFirst", nil)
        rawset(signal, "_onLast", nil)

        local upgraded = TestEnv.ReloadPackage()

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(7, upgraded.REVISION)
        assert.are.equal(4, rawget(state, "schema"))
        assert.are.same(DEFAULT_LIMITS, upgraded:GetLimits())
        -- The older signal reports generation 0 until it fires, and connects
        -- and disconnects without hooks.
        assert.are.equal(0, signal:GetGeneration())
        signal:Fire()
        assert.are.equal(1, signal:GetGeneration())
        assert.are.equal(1, calls)
        assert.is_true(connection:Disconnect())
        assert.is_not_nil(signal:Connect(function() end))
        assert.are.equal(1, signal:DisconnectAll())
        -- Journals can be created against the upgraded state.
        local journal = upgraded:NewJournal(2)
        journal:Fire("recorded")
        local entries = 0
        for _, entry in journal:History() do
            entries = entries + 1
            assert.are.equal("recorded", entry[1])
        end
        assert.are.equal(1, entries)
    end)

    it("carries journals, their history and their generation into a newer revision", function()
        local SignalKit = TestEnv.NewPackage()
        SignalKit:SetLimits({ maxJournalCapacity = 4, maxJournalArguments = 3 })
        local journal = SignalKit:NewJournal(2)
        local received = {}
        journal:Connect(function(value)
            received[#received + 1] = value
        end)
        journal:Fire("before")

        local upgraded = TestEnv.LoadRevision(8)
        journal:Fire("after")

        assert.are.equal(SignalKit, upgraded)
        assert.are.equal(8, upgraded.REVISION)
        assert.are.same(
            { maxBuses = 64, maxJournalCapacity = 4, maxJournalArguments = 3 },
            upgraded:GetLimits()
        )
        assert.are.same({ "before", "after" }, received)
        assert.are.equal(2, journal:GetGeneration())
        local values = {}
        for _, entry in journal:History() do
            values[#values + 1] = entry[1]
        end
        assert.are.same({ "before", "after" }, values)
        -- The upgraded copy refilled the prototype the journal resolves through.
        assert.are.equal(
            rawget(rawget(rawget(SignalKit, "_state"), "journalPrototype"), "History"),
            journal.History
        )
        assert.has_error(function()
            journal:Fire(1, 2, 3, 4)
        end)
    end)

    it("rejects schema-3 state that carries no limits table instead of indexing it", function()
        TestEnv.Reset()
        require("Registry")
        local SignalKit = TestEnv.LoadRevision(6)
        local state = rawget(SignalKit, "_state")
        rawset(state, "schema", 3)
        rawset(state, "journalPrototype", nil)
        rawset(state, "journalMetatable", nil)
        rawset(state, "limits", nil)
        rawset(SignalKit, "NewJournal", nil)
        rawset(SignalKit, "GetGeneration", nil)

        expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("rejects a same-revision facade whose journal prototype is incomplete", function()
        local SignalKit = TestEnv.NewPackage()
        rawset(rawget(SignalKit, "_state"), "journalPrototype", {})

        expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("rejects a same-revision facade whose bus state is incomplete", function()
        local SignalKit = TestEnv.NewPackage()
        rawset(rawget(SignalKit, "_state"), "busPrototype", {})

        expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("keeps the connection method table stable on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local connectionMethods = first.Connection
        local second = TestEnv.ReloadPackage()

        assert.are.equal(connectionMethods, second.Connection)
    end)
end)
