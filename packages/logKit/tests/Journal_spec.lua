local Env = require("LogKitTestEnv")

describe("LogKit journal", function()
    local LogKit

    before_each(function()
        LogKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    ---Collect what a `History` walk yields, as `{ position, addon, levelName, message }`.
    ---@param addonName string?
    ---@param minimumLevel any
    ---@return table[]
    local function collect(addonName, minimumLevel)
        local entries = {}
        for position, addon, levelName, message in LogKit:History(addonName, minimumLevel) do
            entries[#entries + 1] = { position, addon, levelName, message }
        end
        return entries
    end

    it("is always on and records every delivered message oldest to newest", function()
        local logger = LogKit:ForAddon("MyAddon")
        logger:Warn("first")
        logger:Error("second")
        assert.are.same({
            { 1, "MyAddon", "warn", "first" },
            { 2, "MyAddon", "error", "second" },
        }, collect())
    end)

    it("yields the time of each entry", function()
        Env.AdvanceWallMs(3000)
        LogKit:ForAddon("MyAddon"):Warn("stamped")
        local times = {}
        for _, _, _, _, time in LogKit:History() do
            times[#times + 1] = time
        end
        assert.are.same({ 3 }, times)
    end)

    it("keeps the newest journalCapacity entries as a ring", function()
        LogKit:SetLimits({ journalCapacity = 3 })
        local logger = LogKit:ForAddon("MyAddon")
        for index = 1, 5 do
            logger:Warn("message " .. index)
        end
        assert.are.same({
            { 1, "MyAddon", "warn", "message 3" },
            { 2, "MyAddon", "warn", "message 4" },
            { 3, "MyAddon", "warn", "message 5" },
        }, collect())
    end)

    it("filters by addon name", function()
        LogKit:ForAddon("A"):Warn("a1")
        LogKit:ForAddon("B"):Warn("b1")
        LogKit:ForAddon("A"):Error("a2")
        assert.are.same({ { 1, "A", "warn", "a1" }, { 3, "A", "error", "a2" } }, collect("A"))
        assert.are.same({ { 2, "B", "warn", "b1" } }, collect("B"))
        assert.are.same({}, collect("C"))
    end)

    it("filters by minimum level, by name or by LEVELS value", function()
        local logger = LogKit:ForAddon("A")
        logger:SetLevel("trace")
        logger:Trace("t")
        logger:Info("i")
        logger:Error("e")
        assert.are.same({ { 2, "A", "info", "i" }, { 3, "A", "error", "e" } }, collect(nil, "info"))
        assert.are.same({ { 3, "A", "error", "e" } }, collect(nil, LogKit.LEVELS.error))
        assert.are.same({}, collect(nil, "off"))
    end)

    it("combines both filters", function()
        LogKit:ForAddon("A"):Warn("a warn")
        LogKit:ForAddon("A"):Error("a error")
        LogKit:ForAddon("B"):Error("b error")
        assert.are.same({ { 2, "A", "error", "a error" } }, collect("A", "error"))
    end)

    it("re-creates the journal on a new capacity, keeping the newest entries that fit", function()
        local logger = LogKit:ForAddon("MyAddon")
        for index = 1, 5 do
            logger:Warn("message " .. index)
        end
        LogKit:SetLimits({ journalCapacity = 2 })
        assert.are.same({
            { 1, "MyAddon", "warn", "message 4" },
            { 2, "MyAddon", "warn", "message 5" },
        }, collect())

        LogKit:SetLimits({ journalCapacity = 4 })
        logger:Warn("message 6")
        assert.are.same({
            { 1, "MyAddon", "warn", "message 4" },
            { 2, "MyAddon", "warn", "message 5" },
            { 3, "MyAddon", "warn", "message 6" },
        }, collect())
    end)

    it("keeps the journal when SetLimits repeats the current capacity", function()
        local logger = LogKit:ForAddon("MyAddon")
        logger:Warn("kept")
        local journal = LogKit._state.journal
        LogKit:SetLimits({ journalCapacity = LogKit:GetLimits().journalCapacity })
        assert.are.equal(journal, LogKit._state.journal)
        assert.are.same({ { 1, "MyAddon", "warn", "kept" } }, collect())
    end)

    it("refuses a secret or empty addon filter and an unknown level at the caller", function()
        local secret = Env.NewSecretValue()
        Env.expectErrorContaining("LogKit:History addonName must not be a secret value", function()
            LogKit:History(secret)
        end)
        Env.expectErrorContaining("LogKit:History addonName must be a non-empty string", function()
            LogKit:History("")
        end)
        Env.expectErrorContaining("LogKit:History minimumLevel must be a level name", function()
            LogKit:History(nil, "loud")
        end)
    end)

    it("lets a History call inside a walk take over the shared filter, without error", function()
        LogKit:ForAddon("A"):Warn("a1")
        LogKit:ForAddon("B"):Warn("b1")
        LogKit:ForAddon("A"):Warn("a2")
        LogKit:ForAddon("B"):Warn("b2")
        local outer, inner = {}, {}
        for _, addon in LogKit:History() do
            outer[#outer + 1] = addon
            if #inner == 0 then
                for _, innerAddon in LogKit:History("B") do
                    inner[#inner + 1] = innerAddon
                end
            end
        end
        assert.are.same({ "B", "B" }, inner)
        -- The outer walk yielded its first entry, then continued from its own
        -- position under the inner walk's filter, skipping A's second entry:
        -- the documented "walks do not nest" behaviour.
        assert.are.same({ "A", "B", "B" }, outer)
    end)

    it("never errors when a message is logged during a walk over a full ring", function()
        LogKit:SetLimits({ journalCapacity = 3 })
        local logger = LogKit:ForAddon("MyAddon")
        for index = 1, 3 do
            logger:Warn("message " .. index)
        end
        local visited = 0
        assert.has_no.errors(function()
            for _, _, _, message in LogKit:History() do
                visited = visited + 1
                logger:Warn("during " .. message)
            end
        end)
        assert.is_true(visited >= 1 and visited <= 3)
        -- The window moved under the walk, so which entries it saw is not
        -- fixed; the ring itself holds the three newest messages, all logged
        -- during the walk.
        local entries = collect()
        assert.are.equal(3, #entries)
        for index = 1, 3 do
            assert.is_not_nil(entries[index][4]:find("^during "))
        end
    end)

    it("records a message logged from inside a sink without delivering it to sinks", function()
        local logger = LogKit:ForAddon("MyAddon")
        local sinkCalls = 0
        LogKit:AddSink(function(record)
            sinkCalls = sinkCalls + 1
            if record.message == "outer" then
                logger:Error("inner")
            end
        end)
        logger:Warn("outer")
        assert.are.equal(1, sinkCalls)
        assert.are.same({
            { 1, "MyAddon", "warn", "outer" },
            { 2, "MyAddon", "error", "inner" },
        }, collect())
    end)
end)
