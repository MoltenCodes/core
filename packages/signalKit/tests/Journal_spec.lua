local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/Journal_spec.lua:"

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

---Collect the first argument of every recorded entry, oldest to newest, and
---the positions the iterator reported.
---@param journal table
---@return any[] firstArguments
---@return integer[] positions
local function collectHistory(journal)
    local firstArguments = {}
    local positions = {}
    for position, entry in journal:History() do
        firstArguments[#firstArguments + 1] = entry[1]
        positions[#positions + 1] = position
    end
    return firstArguments, positions
end

describe("SignalKit journals", function()
    local SignalKit

    before_each(function()
        SignalKit = TestEnv.NewPackage()
    end)

    after_each(TestEnv.Reset)

    describe("NewJournal", function()
        it("creates a signal with the ordinary signal methods", function()
            local journal = SignalKit:NewJournal()
            local received = {}
            local connection = journal:Connect(function(...)
                received[#received + 1] = select("#", ...)
            end)

            journal:Fire(1, nil, 3)
            assert.are.same({ 3 }, received)
            assert.is_true(connection:IsConnected())
            assert.are.equal(1, journal:DisconnectAll())
            assert.are.equal(1, journal:GetGeneration())
        end)

        it("defaults to a capacity of 128", function()
            local journal = SignalKit:NewJournal()
            for index = 1, 130 do
                journal:Fire(index)
            end

            local firstArguments = collectHistory(journal)
            assert.are.equal(128, #firstArguments)
            assert.are.equal(3, firstArguments[1])
            assert.are.equal(130, firstArguments[128])
        end)

        it("accepts a capacity from 1 up to maxJournalCapacity", function()
            local single = SignalKit:NewJournal(1)
            single:Fire("a")
            single:Fire("b")
            assert.are.same({ "b" }, (collectHistory(single)))
            assert.is_not_nil(SignalKit:NewJournal(1024))
        end)

        it("accepts the hook options", function()
            local log = {}
            local journal = SignalKit:NewJournal(2, {
                onFirst = function()
                    log[#log + 1] = "first"
                end,
                onLast = function()
                    log[#log + 1] = "last"
                end,
            })
            journal:Connect(function() end)
            journal:DisconnectAll()
            assert.are.same({ "first", "last" }, log)
        end)

        it("refuses invalid capacities, UNBOUNDED and bad options at the caller", function()
            local invalid = { 0, -1, 1.5, 0 / 0, math.huge, "128", true, {} }
            for _, value in ipairs(invalid) do
                expectRefusalAtCaller(
                    "SignalKit:NewJournal capacity must be an integer from 1 to 1024",
                    function()
                        SignalKit:NewJournal(value)
                    end
                )
            end
            expectRefusalAtCaller(
                "SignalKit:NewJournal capacity cannot be SignalKit.UNBOUNDED",
                function()
                    SignalKit:NewJournal(SignalKit.UNBOUNDED)
                end
            )
            expectRefusalAtCaller("SignalKit:NewJournal options must be a table or nil", function()
                SignalKit:NewJournal(4, "options")
            end)
            expectRefusalAtCaller(
                "SignalKit:NewJournal options.onFirst must be a function or nil",
                function()
                    SignalKit:NewJournal(4, { onFirst = 1 })
                end
            )
        end)

        it("refuses a call without the facade receiver at the caller", function()
            expectRefusalAtCaller(
                "SignalKit:NewJournal must be called on the SignalKit facade",
                function()
                    SignalKit.NewJournal(4)
                end
            )
            expectRefusalAtCaller(
                "SignalKit:NewJournal must be called on the SignalKit facade",
                function()
                    SignalKit:New():NewJournal(4)
                end
            )
        end)
    end)

    describe("History", function()
        it("walks the recorded firings oldest to newest with 1-based positions", function()
            local journal = SignalKit:NewJournal(4)
            for index = 1, 3 do
                journal:Fire(index * 10)
            end

            local firstArguments, positions = collectHistory(journal)
            assert.are.same({ 10, 20, 30 }, firstArguments)
            assert.are.same({ 1, 2, 3 }, positions)
        end)

        it("is empty for a journal that never fired", function()
            local journal = SignalKit:NewJournal(4)
            assert.are.same({}, (collectHistory(journal)))
        end)

        it("keeps only the last capacity firings once the ring wraps", function()
            local journal = SignalKit:NewJournal(3)
            for index = 1, 7 do
                journal:Fire(index)
            end

            assert.are.same({ 5, 6, 7 }, (collectHistory(journal)))
            journal:Fire(8)
            assert.are.same({ 6, 7, 8 }, (collectHistory(journal)))
        end)

        it("exposes count, the arguments including nil, and the generation", function()
            local journal = SignalKit:NewJournal(2)
            journal:Fire()
            journal:Fire("a", nil, false)

            local entries = {}
            for _, entry in journal:History() do
                entries[#entries + 1] = entry
            end
            assert.are.equal(0, entries[1].count)
            assert.are.equal(1, entries[1].generation)
            assert.are.equal(3, entries[2].count)
            assert.are.equal(2, entries[2].generation)
            assert.are.equal("a", entries[2][1])
            assert.is_nil(entries[2][2])
            assert.is_false(entries[2][3])
            assert.are.equal(journal:GetGeneration(), entries[2].generation)
        end)

        it("clears the arguments a wider earlier firing left in a reused slot", function()
            local journal = SignalKit:NewJournal(1)
            SignalKit:SetLimits({ maxJournalArguments = 12 })
            journal:Fire(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
            journal:Fire("only")

            for _, entry in journal:History() do
                assert.are.equal(1, entry.count)
                assert.are.equal("only", entry[1])
                for index = 2, 12 do
                    assert.is_nil(entry[index])
                end
            end
        end)

        it("does not replay anything to a listener that connects", function()
            local journal = SignalKit:NewJournal(4)
            journal:Fire("past")
            local received = {}

            journal:Connect(function(value)
                received[#received + 1] = value
            end)
            journal:Fire("present")

            assert.are.same({ "present" }, received)
            assert.are.same({ "past", "present" }, (collectHistory(journal)))
        end)

        it("records the firing before listeners run, and keeps it if one raises", function()
            local journal = SignalKit:NewJournal(4)
            local newestDuringDispatch
            journal:Connect(function()
                local firstArguments = collectHistory(journal)
                newestDuringDispatch = firstArguments[#firstArguments]
                error("listener failure")
            end)

            assert.has_error(function()
                journal:Fire("delivered")
            end)

            assert.are.equal("delivered", newestDuringDispatch)
            assert.are.same({ "delivered" }, (collectHistory(journal)))
        end)

        it("reuses its slot tables rather than allocating entries", function()
            local journal = SignalKit:NewJournal(2)
            journal:Fire("a")
            journal:Fire("b")
            local firstWalk = {}
            for _, entry in journal:History() do
                firstWalk[#firstWalk + 1] = entry
            end

            journal:Fire("c")
            journal:Fire("d")
            local secondWalk = {}
            for _, entry in journal:History() do
                secondWalk[#secondWalk + 1] = entry
            end

            assert.are.equal(firstWalk[1], secondWalk[1])
            assert.are.equal(firstWalk[2], secondWalk[2])
            assert.are.equal("c", secondWalk[1][1])
        end)

        it(
            "never errors when the journal fires during a walk, and keeps positions in range",
            function()
                local journal = SignalKit:NewJournal(3)
                local firedDuringWalk = 0
                journal:Connect(function()
                    -- A listener firing the journal again while a walk is in progress
                    -- moves the window under the walk; stop after a few so the
                    -- nested firings end.
                    if firedDuringWalk < 5 then
                        firedDuringWalk = firedDuringWalk + 1
                        journal:Fire(firedDuringWalk)
                    end
                end)
                journal:Fire("start")

                local positions = {}
                local entriesSeen = 0
                for position, entry in journal:History() do
                    positions[#positions + 1] = position
                    entriesSeen = entriesSeen + 1
                    assert.is_not_nil(entry)
                    assert.are.equal("number", type(entry.count))
                    journal:Fire("during walk", position)
                end

                assert.is_true(entriesSeen >= 1)
                assert.is_true(entriesSeen <= 3)
                for index = 1, #positions do
                    assert.is_true(positions[index] >= 1 and positions[index] <= 3)
                end
                local recorded = 0
                for _ in journal:History() do
                    recorded = recorded + 1
                end
                assert.are.equal(3, recorded)
            end
        )

        it("refuses a call without a journal receiver at the caller", function()
            local journal = SignalKit:NewJournal(2)
            expectRefusalAtCaller(
                "SignalKit.Journal:History must be called on a journal; use journal:History()",
                function()
                    journal.History()
                end
            )
            expectRefusalAtCaller(
                "SignalKit.Journal:History must be called on a journal",
                function()
                    journal.History(SignalKit:New())
                end
            )
            expectRefusalAtCaller(
                "SignalKit.Journal:Fire must be called on a journal; use journal:Fire(...)",
                function()
                    journal.Fire("payload")
                end
            )
        end)
    end)

    describe("argument cap", function()
        it(
            "refuses a firing wider than maxJournalArguments at the caller, delivering nothing",
            function()
                local journal = SignalKit:NewJournal(2)
                local calls = 0
                journal:Connect(function()
                    calls = calls + 1
                end)

                expectRefusalAtCaller(
                    "SignalKit.Journal:Fire records at most 8 arguments per firing; received 9",
                    function()
                        journal:Fire(1, 2, 3, 4, 5, 6, 7, 8, 9)
                    end
                )

                assert.are.equal(0, calls)
                assert.are.same({}, (collectHistory(journal)))
                assert.are.equal(0, journal:GetGeneration())
            end
        )

        it("never places an argument value in the refusal message", function()
            local journal = SignalKit:NewJournal(2)
            local ok, message = pcall(function()
                journal:Fire("visible", 2, 3, 4, 5, 6, 7, 8, 9)
            end)

            assert.is_false(ok)
            assert.is_nil(string.find(tostring(message), "visible", 1, true))
        end)

        it("stores secret values without comparing them", function()
            local secret = setmetatable({}, {
                __eq = function()
                    error("compared a secret value")
                end,
            })
            local journal = SignalKit:NewJournal(1)

            journal:Fire(secret, secret)
            journal:Fire(secret)

            for _, entry in journal:History() do
                assert.is_true(rawequal(secret, entry[1]))
                assert.are.equal(1, entry.count)
            end
        end)
    end)

    describe("allocation behaviour", function()
        it("allocates nothing per Fire after the ring is created", function()
            local journal = SignalKit:NewJournal(16)
            local sink = 0
            journal:Connect(function(a, b)
                sink = sink + a + b
            end)

            -- Fresh slots are sized in advance for eight arguments, so even the first
            -- pass over the ring stays within the tolerance the suite accepts.
            local allocated = TestEnv.AllocatedKilobytes(function()
                for _ = 1, 20000 do
                    journal:Fire(1, 2, nil, 4, 5, 6, 7, 8)
                end
            end)

            assert.is_true(allocated < 4, allocated .. " KB allocated")
        end)

        it("allocates nothing per Fire when widths alternate past eight, once warmed up", function()
            SignalKit:SetLimits({ maxJournalArguments = 12 })
            local journal = SignalKit:NewJournal(4)
            for _ = 1, 4 do
                journal:Fire(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
            end

            local allocated = TestEnv.AllocatedKilobytes(function()
                for _ = 1, 10000 do
                    journal:Fire(1, 2, 3)
                    journal:Fire(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
                end
            end)

            assert.is_true(allocated < 4, allocated .. " KB allocated")
        end)

        it("allocates nothing per History walk", function()
            local journal = SignalKit:NewJournal(8)
            for index = 1, 12 do
                journal:Fire(index)
            end
            local sink = 0

            local allocated = TestEnv.AllocatedKilobytes(function()
                for _ = 1, 20000 do
                    for _, entry in journal:History() do
                        sink = sink + entry.count
                    end
                end
            end)

            assert.is_true(allocated < 4, allocated .. " KB allocated")
        end)
    end)
end)
