local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/Limits_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)

    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true), message)
    assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
    assert.is_nil(string.find(message, "src/SignalKit.lua", 1, true), message)
end

---Values no limit accepts, with a label for the failure message.
local INVALID_VALUES = {
    { label = "a string", value = "10" },
    { label = "a boolean", value = true },
    { label = "an arbitrary table", value = {} },
    { label = "zero", value = 0 },
    { label = "a negative number", value = -1 },
    { label = "a fraction", value = 1.5 },
    { label = "NaN", value = 0 / 0 },
    { label = "infinity", value = math.huge },
}

---Declare `count` distinct topics on `bus`, asserting each is accepted.
---@param bus table
---@param count integer
local function declareTopics(bus, count)
    for index = 1, count do
        assert.is_true((bus:DeclareTopic("Topic" .. index)))
    end
end

---Subscribe `count` listeners to `topic` on `bus`, asserting each is accepted.
---@param bus table
---@param topic string
---@param count integer
local function subscribeListeners(bus, topic, count)
    for _ = 1, count do
        assert.is_not_nil((bus:Subscribe(topic, function() end)))
    end
end

---The package-wide limits a fresh session starts with.
local DEFAULT_LIMITS = { maxBuses = 64, maxJournalCapacity = 1024, maxJournalArguments = 8 }

---`DEFAULT_LIMITS` with one value changed.
---@param name string
---@param value integer
---@return table
local function limitsWith(name, value)
    local limits = {}
    for key, default in pairs(DEFAULT_LIMITS) do
        limits[key] = default
    end
    limits[name] = value
    return limits
end

describe("SignalKit limits", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    describe("UNBOUNDED", function()
        it("is one table published on the facade", function()
            assert.are.equal("table", type(SignalKit.UNBOUNDED))
            assert.are.equal(SignalKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
        end)
    end)

    describe("bus option maxTopics", function()
        it("defaults to 256", function()
            local bus = SignalKit:Bus("Default")
            declareTopics(bus, 256)

            local declared, reason = bus:DeclareTopic("Beyond")
            assert.is_nil(declared)
            assert.are.equal("full", reason)
        end)

        it("honours a smaller or larger integer", function()
            local small = SignalKit:Bus("Small", { maxTopics = 2 })
            declareTopics(small, 2)
            local subscribed, reason = small:Subscribe("Third", function() end)
            assert.is_nil(subscribed)
            assert.are.equal("full", reason)

            local large = SignalKit:Bus("Large", { maxTopics = 300 })
            declareTopics(large, 300)
            assert.is_nil((large:DeclareTopic("Beyond")))
        end)

        it("honours UNBOUNDED", function()
            local bus = SignalKit:Bus("Open", { maxTopics = SignalKit.UNBOUNDED })
            declareTopics(bus, 600)
            assert.are.equal(600, #bus:Topics())
        end)

        it("refuses invalid values at the caller", function()
            for _, case in ipairs(INVALID_VALUES) do
                expectRefusalAtCaller(
                    "SignalKit:Bus options.maxTopics must be a positive integer or SignalKit.UNBOUNDED",
                    function()
                        SignalKit:Bus("Invalid", { maxTopics = case.value })
                    end
                )
            end
            -- A refused call creates no bus.
            assert.is_nil(rawget(rawget(rawget(SignalKit, "_state"), "buses"), "Invalid"))
        end)
    end)

    describe("bus option maxListeners", function()
        it("defaults to 256 live listeners per topic", function()
            local bus = SignalKit:Bus("Default")
            subscribeListeners(bus, "Topic", 256)

            local subscribed, reason = bus:Subscribe("Topic", function() end)
            assert.is_nil(subscribed)
            assert.are.equal("full", reason)
        end)

        it("honours an integer, on scopes as well as on the bus", function()
            local bus = SignalKit:Bus("Small", { maxListeners = 1 })
            subscribeListeners(bus, "Topic", 1)

            local subscribed, reason = bus:CreateScope():Subscribe("Topic", function() end)
            assert.is_nil(subscribed)
            assert.are.equal("full", reason)
            -- The cap is per topic.
            assert.is_not_nil((bus:Subscribe("Other", function() end)))
        end)

        it("honours UNBOUNDED", function()
            local bus = SignalKit:Bus("Open", { maxListeners = SignalKit.UNBOUNDED })
            subscribeListeners(bus, "Topic", 600)
        end)

        it("refuses invalid values at the caller", function()
            for _, case in ipairs(INVALID_VALUES) do
                expectRefusalAtCaller(
                    "SignalKit:Bus options.maxListeners must be a positive integer or SignalKit.UNBOUNDED",
                    function()
                        SignalKit:Bus("Invalid", { maxListeners = case.value })
                    end
                )
            end
        end)
    end)

    describe("per-bus limits on a shared bus", function()
        it("lets the first caller that states a limit set it, in either load order", function()
            local unstatedFirst = SignalKit:Bus("First")
            assert.are.equal(unstatedFirst, SignalKit:Bus("First", { maxTopics = 1 }))
            declareTopics(unstatedFirst, 1)
            assert.is_nil((unstatedFirst:DeclareTopic("Beyond")))

            local statedFirst = SignalKit:Bus("Second", { maxTopics = 1 })
            assert.are.equal(statedFirst, SignalKit:Bus("Second"))
            assert.are.equal(statedFirst, SignalKit:ForAddon("Second"))
            assert.are.equal(statedFirst, SignalKit:Bus("Second", { maxTopics = 1 }))
            declareTopics(statedFirst, 1)
            assert.is_nil((statedFirst:DeclareTopic("Beyond")))
        end)

        it("lets ForAddon create the addon bus without fixing its limits", function()
            local bus = SignalKit:ForAddon("MyAddon")
            assert.are.equal(bus, SignalKit:Bus("MyAddon", { maxTopics = 1 }))
            assert.are.equal(bus, SignalKit:ForAddon("MyAddon"))
            declareTopics(bus, 1)
            assert.is_nil((bus:DeclareTopic("Beyond")))
            expectRefusalAtCaller(
                'SignalKit:Bus bus "MyAddon" already exists with a different maxTopics',
                function()
                    SignalKit:Bus("MyAddon", { maxTopics = 2 })
                end
            )
        end)

        it("refuses a different statement at the caller and changes nothing", function()
            local bus = SignalKit:Bus("Owned", { maxTopics = 1 })

            expectRefusalAtCaller(
                'SignalKit:Bus bus "Owned" already exists with a different maxTopics',
                function()
                    SignalKit:Bus("Owned", { maxTopics = 2, maxListeners = 1 })
                end
            )
            expectRefusalAtCaller(
                'SignalKit:Bus bus "Owned" already exists with a different maxTopics',
                function()
                    SignalKit:Bus("Owned", { maxTopics = SignalKit.UNBOUNDED })
                end
            )

            -- The refused call did not state maxListeners either.
            assert.are.equal(bus, SignalKit:Bus("Owned", { maxListeners = 2 }))
            expectRefusalAtCaller(
                'SignalKit:Bus bus "Owned" already exists with a different maxListeners',
                function()
                    SignalKit:Bus("Owned", { maxListeners = 3 })
                end
            )
        end)

        it("never evicts when a stated limit is below what the bus holds", function()
            local bus = SignalKit:Bus("Busy")
            declareTopics(bus, 5)
            subscribeListeners(bus, "Topic1", 3)

            SignalKit:Bus("Busy", { maxTopics = 2, maxListeners = 1 })

            assert.are.equal(5, #bus:Topics())
            assert.is_nil((bus:DeclareTopic("Topic6")))
            assert.is_nil((bus:Subscribe("Topic1", function() end)))
            assert.is_true((bus:DeclareTopic("Topic2")))
        end)
    end)

    describe("SetLimits maxBuses", function()
        it("defaults to 64", function()
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
            for index = 1, 64 do
                assert.is_not_nil((SignalKit:Bus("Bus" .. index)))
            end
            local bus, reason = SignalKit:Bus("Beyond")
            assert.is_nil(bus)
            assert.are.equal("full", reason)
        end)

        it("honours a larger value up to the ceiling", function()
            SignalKit:SetLimits({ maxBuses = 1024 })
            for index = 1, 1024 do
                assert.is_not_nil((SignalKit:Bus("Bus" .. index)))
            end
            assert.is_nil((SignalKit:Bus("Beyond")))
        end)

        it("never evicts when lowered below the current count", function()
            for index = 1, 3 do
                SignalKit:Bus("Bus" .. index)
            end
            SignalKit:SetLimits({ maxBuses = 1 })

            assert.is_not_nil((SignalKit:Bus("Bus3")))
            local bus, reason = SignalKit:Bus("Beyond")
            assert.is_nil(bus)
            assert.are.equal("full", reason)
        end)

        it("refuses UNBOUNDED at the caller with its reason", function()
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.maxBuses cannot be SignalKit.UNBOUNDED: "
                    .. "buses are shared by every addon and never freed",
                function()
                    SignalKit:SetLimits({ maxBuses = SignalKit.UNBOUNDED })
                end
            )
        end)

        it("refuses invalid values and values above the ceiling at the caller", function()
            local values = { { value = 1025 } }
            for _, case in ipairs(INVALID_VALUES) do
                values[#values + 1] = case
            end
            for _, case in ipairs(values) do
                expectRefusalAtCaller(
                    "SignalKit:SetLimits limits.maxBuses must be an integer from 1 to 1024",
                    function()
                        SignalKit:SetLimits({ maxBuses = case.value })
                    end
                )
            end
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
        end)

        it("refuses an unknown name, a non-string key and a non-table", function()
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.maxTopics is not a recognised limit",
                function()
                    SignalKit:SetLimits({ maxTopics = 10 })
                end
            )
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.1 is not a recognised limit",
                function()
                    SignalKit:SetLimits({ 10 })
                end
            )
            expectRefusalAtCaller("SignalKit:SetLimits limits must be a table", function()
                SignalKit:SetLimits(10)
            end)
            expectRefusalAtCaller(
                "SignalKit:SetLimits must be called on the SignalKit facade",
                function()
                    SignalKit.SetLimits({ maxBuses = 10 })
                end
            )
        end)

        it("is atomic: one invalid entry changes nothing", function()
            expectRefusalAtCaller("is not a recognised limit", function()
                SignalKit:SetLimits({ maxBuses = 10, unknown = 1 })
            end)
            expectRefusalAtCaller("limits.maxJournalArguments must be an integer", function()
                SignalKit:SetLimits({
                    maxBuses = 10,
                    maxJournalCapacity = 10,
                    maxJournalArguments = 0,
                })
            end)
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
        end)

        it("accepts an empty table as no change", function()
            SignalKit:SetLimits({})
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
        end)
    end)

    describe("SetLimits maxJournalCapacity", function()
        it("defaults to 1024 and bounds the capacity NewJournal accepts", function()
            assert.are.equal(1024, SignalKit:GetLimits().maxJournalCapacity)
            assert.is_not_nil(SignalKit:NewJournal(1024))
            expectRefusalAtCaller(
                "SignalKit:NewJournal capacity must be an integer from 1 to 1024",
                function()
                    SignalKit:NewJournal(1025)
                end
            )
        end)

        it("honours a larger value up to the 65536 ceiling", function()
            SignalKit:SetLimits({ maxJournalCapacity = 65536 })
            assert.is_not_nil(SignalKit:NewJournal(65536))
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.maxJournalCapacity must be an integer from 1 to 65536",
                function()
                    SignalKit:SetLimits({ maxJournalCapacity = 65537 })
                end
            )
        end)

        it("never shrinks an existing journal when lowered", function()
            local journal = SignalKit:NewJournal(4)
            SignalKit:SetLimits({ maxJournalCapacity = 2 })
            for index = 1, 4 do
                journal:Fire(index)
            end

            local recorded = 0
            for _ in journal:History() do
                recorded = recorded + 1
            end
            assert.are.equal(4, recorded)
            expectRefusalAtCaller(
                "SignalKit:NewJournal capacity must be an integer from 1 to 2",
                function()
                    SignalKit:NewJournal(3)
                end
            )
            assert.is_not_nil(SignalKit:NewJournal(2))
        end)

        it("refuses the default capacity once the limit is below it", function()
            SignalKit:SetLimits({ maxJournalCapacity = 64 })
            expectRefusalAtCaller(
                "SignalKit:NewJournal default capacity 128 exceeds maxJournalCapacity 64; pass a capacity",
                function()
                    SignalKit:NewJournal()
                end
            )
            assert.is_not_nil(SignalKit:NewJournal(64))
        end)

        it("refuses UNBOUNDED and invalid values at the caller", function()
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.maxJournalCapacity cannot be SignalKit.UNBOUNDED: "
                    .. "the ring is allocated when the journal is created",
                function()
                    SignalKit:SetLimits({ maxJournalCapacity = SignalKit.UNBOUNDED })
                end
            )
            for _, case in ipairs(INVALID_VALUES) do
                expectRefusalAtCaller(
                    "SignalKit:SetLimits limits.maxJournalCapacity must be an integer from 1 to 65536",
                    function()
                        SignalKit:SetLimits({ maxJournalCapacity = case.value })
                    end
                )
            end
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
        end)
    end)

    describe("SetLimits maxJournalArguments", function()
        it("defaults to 8 and is applied at the firing line", function()
            assert.are.equal(8, SignalKit:GetLimits().maxJournalArguments)
            local journal = SignalKit:NewJournal(2)
            journal:Fire(1, 2, 3, 4, 5, 6, 7, 8)
            expectRefusalAtCaller(
                "SignalKit.Journal:Fire records at most 8 arguments per firing; received 9",
                function()
                    journal:Fire(1, 2, 3, 4, 5, 6, 7, 8, 9)
                end
            )
        end)

        it(
            "honours a larger value up to the 64 ceiling, for journals that already exist",
            function()
                local journal = SignalKit:NewJournal(2)
                SignalKit:SetLimits({ maxJournalArguments = 64 })
                local wide = {}
                for index = 1, 64 do
                    wide[index] = index
                end
                journal:Fire(unpack(wide))
                for _, entry in journal:History() do
                    assert.are.equal(64, entry.count)
                    assert.are.equal(64, entry[64])
                end
                expectRefusalAtCaller(
                    "SignalKit:SetLimits limits.maxJournalArguments must be an integer from 1 to 64",
                    function()
                        SignalKit:SetLimits({ maxJournalArguments = 65 })
                    end
                )
            end
        )

        it("refuses UNBOUNDED and invalid values at the caller", function()
            expectRefusalAtCaller(
                "SignalKit:SetLimits limits.maxJournalArguments cannot be SignalKit.UNBOUNDED: "
                    .. "each firing is staged into a reused slot table",
                function()
                    SignalKit:SetLimits({ maxJournalArguments = SignalKit.UNBOUNDED })
                end
            )
            for _, case in ipairs(INVALID_VALUES) do
                expectRefusalAtCaller(
                    "SignalKit:SetLimits limits.maxJournalArguments must be an integer from 1 to 64",
                    function()
                        SignalKit:SetLimits({ maxJournalArguments = case.value })
                    end
                )
            end
            assert.are.same(DEFAULT_LIMITS, SignalKit:GetLimits())
        end)
    end)

    describe("GetLimits", function()
        it("reflects SetLimits and returns a fresh table each call", function()
            SignalKit:SetLimits({ maxBuses = 100 })
            local first = SignalKit:GetLimits()
            local second = SignalKit:GetLimits()

            assert.are.same(limitsWith("maxBuses", 100), first)
            assert.are_not.equal(first, second)
            first.maxBuses = 1
            assert.are.same(limitsWith("maxBuses", 100), SignalKit:GetLimits())
        end)

        it("refuses a call without the facade receiver at the caller", function()
            expectRefusalAtCaller(
                "SignalKit:GetLimits must be called on the SignalKit facade",
                function()
                    SignalKit.GetLimits()
                end
            )
        end)

        it("is reset for a fresh session", function()
            SignalKit:SetLimits({ maxBuses = 100, maxJournalArguments = 12 })
            TestEnv.Reset()
            assert.are.same(DEFAULT_LIMITS, TestEnv.NewPackage():GetLimits())
        end)
    end)
end)
