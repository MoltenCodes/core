local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

describe("CommKit queue bounds and refusals", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    ---@param overrides table
    ---@return table request
    local function request(overrides)
        local value = { prefix = PREFIX, text = "hello", distribution = "PARTY" }
        for key, field in pairs(overrides) do
            value[key] = field
        end
        return value
    end

    it("refuses a message larger than the byte bound with tooLarge", function()
        CommKit:SetLimits({ maxQueuedBytes = 1000 })
        assert.are.same({ nil, "tooLarge" }, { scope:Send(request({ text = TestEnv.Text(1001) })) })
        assert.is_truthy(scope:Send(request({ text = TestEnv.Text(1000) })))
    end)

    it("refuses with queueFull when the queued bytes would pass the bound", function()
        CommKit:SetLimits({ maxQueuedBytes = 1000 })
        assert.is_truthy(scope:Send(request({ text = TestEnv.Text(600) })))
        assert.are.same({ nil, "queueFull" }, { scope:Send(request({ text = TestEnv.Text(600) })) })
        assert.are.same({ 1, 600 }, { CommKit:GetQueueDepth() })
    end)

    it("refuses with queueFull when the queued messages would pass the bound", function()
        CommKit:SetLimits({ maxQueuedMessages = 3 })
        for _ = 1, 3 do
            assert.is_truthy(scope:Send(request({})))
        end
        assert.are.same({ nil, "queueFull" }, { scope:Send(request({})) })
        TestEnv.Advance(0)
        assert.is_truthy(scope:Send(request({})))
    end)

    it("drops nothing already queued when a bound is lowered", function()
        for _ = 1, 4 do
            assert.is_truthy(scope:Send(request({})))
        end
        CommKit:SetLimits({ maxQueuedMessages = 2 })
        assert.are.same({ 4, 20 }, { CommKit:GetQueueDepth() })
        assert.are.same({ nil, "queueFull" }, { scope:Send(request({})) })
        TestEnv.Advance(0)
        assert.are.equal(4, #TestEnv.TakeOutbox())
    end)

    it("refuses every byte the addon channel cannot carry", function()
        for _, text in ipairs({ "a\0b", "a\nb", "a\rb", "a|b" }) do
            assert.are.same({ nil, "forbiddenByte" }, { scope:Send(request({ text = text })) })
        end
        assert.is_truthy(scope:Send(request({ text = "\1\2\3\255 ok" })))
    end)

    it("refuses an unknown distribution or a missing target with badDistribution", function()
        assert.are.same(
            { nil, "badDistribution" },
            { scope:Send(request({ distribution = "EMOTE" })) }
        )
        assert.are.same(
            { nil, "badDistribution" },
            { scope:Send(request({ distribution = "WHISPER" })) }
        )
        assert.are.same(
            { nil, "badDistribution" },
            { scope:Send(request({ distribution = "WHISPER", target = "" })) }
        )
        assert.are.same(
            { nil, "badDistribution" },
            { scope:Send(request({ distribution = "CHANNEL" })) }
        )
        assert.is_truthy(scope:Send(request({ distribution = "CHANNEL", target = 5 })))
        assert.is_truthy(scope:Send(request({ distribution = "WHISPER", target = "Friend-Realm" })))
    end)

    it("ignores a target on a distribution that takes none", function()
        assert.is_truthy(scope:Send(request({ distribution = "GUILD", target = "Nobody" })))
        TestEnv.Advance(0)
        local sent = TestEnv.TakeOutbox()
        assert.are.equal("GUILD", sent[1].distribution)
        assert.is_nil(sent[1].target)
    end)

    it("refuses with closed after the scope closed", function()
        scope:Close()
        assert.are.same({ nil, "closed" }, { scope:Send(request({})) })
    end)

    it("sends logged messages through SendAddonMessageLogged", function()
        assert.is_truthy(scope:Send(request({ constraints = { logged = true, battleNet = true } })))
        assert.is_truthy(scope:Send(request({ constraints = { logged = false } })))
        TestEnv.Advance(0)
        local sent = TestEnv.TakeOutbox()
        assert.are.equal(2, #sent)
        assert.is_true(sent[1].logged)
        assert.is_false(sent[2].logged)
    end)

    it("refuses with unavailable when the client lacks the send function", function()
        -- selene: allow(global_usage)
        rawget(_G, "C_ChatInfo").SendAddonMessageLogged = nil
        assert.are.same(
            { nil, "unavailable" },
            { scope:Send(request({ constraints = { logged = true } })) }
        )
    end)

    it("reports depth per priority and drains to zero", function()
        assert.is_truthy(scope:Send(request({ priority = CommKit.Priority.ALERT })))
        assert.is_truthy(scope:Send(request({ priority = CommKit.Priority.BULK, text = "abc" })))
        assert.is_truthy(scope:Send(request({})))
        assert.are.same({ 1, 5 }, { CommKit:GetQueueDepth(CommKit.Priority.ALERT) })
        assert.are.same({ 1, 5 }, { CommKit:GetQueueDepth(CommKit.Priority.NORMAL) })
        assert.are.same({ 1, 3 }, { CommKit:GetQueueDepth(CommKit.Priority.BULK) })
        assert.are.same({ 3, 13 }, { CommKit:GetQueueDepth() })
        TestEnv.Advance(0)
        assert.are.same({ 0, 0 }, { CommKit:GetQueueDepth() })
    end)

    it("counts every refusal by reason", function()
        CommKit:SetLimits({ maxQueuedMessages = 1 })
        scope:Send(request({}))
        scope:Send(request({}))
        scope:Send(request({ text = "|" }))
        scope:Send(request({ distribution = "NOPE" }))
        local statistics = CommKit:GetStatistics()
        assert.are.equal(1, statistics.messagesQueued)
        assert.are.equal(1, statistics.refusedQueueFull)
        assert.are.equal(1, statistics.refusedForbiddenByte)
        assert.are.equal(1, statistics.refusedBadDistribution)
    end)

    it("leaves no per-frame handler, job or timer once the queue is empty", function()
        for _ = 1, 3 do
            scope:Send(request({}))
        end
        assert.are.equal(1, TestEnv.ActiveOnUpdateCount())
        TestEnv.Advance(0)
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
        local live = 0
        for _, native in ipairs(TestEnv.NativeTimers()) do
            if not native.cancelled and (native.repeating or not native.fired) then
                live = live + 1
            end
        end
        assert.are.equal(0, live)
    end)
end)

describe("CommKit priorities", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    ---The texts the stub accepted, in order.
    ---@return string[]
    local function sentTexts()
        local texts = {}
        for index, entry in ipairs(TestEnv.TakeOutbox()) do
            texts[index] = entry.text:sub(2)
        end
        return texts
    end

    it("serves ALERT four times, NORMAL twice and BULK once per turn", function()
        for index = 1, 5 do
            scope:Send({
                prefix = PREFIX,
                text = "A" .. index,
                distribution = "PARTY",
                priority = CommKit.Priority.ALERT,
            })
        end
        for index = 1, 3 do
            scope:Send({
                prefix = PREFIX,
                text = "B" .. index,
                distribution = "PARTY",
                priority = CommKit.Priority.BULK,
            })
        end
        for index = 1, 3 do
            scope:Send({ prefix = PREFIX, text = "N" .. index, distribution = "PARTY" })
        end
        TestEnv.Advance(0)
        assert.are.same(
            { "A1", "A2", "A3", "A4", "N1", "N2", "B1", "A5", "N3", "B2", "B3" },
            sentTexts()
        )
    end)

    it("never starves BULK behind a steady stream of ALERT", function()
        CommKit:SetLimits({ maxQueuedMessages = 64 })
        for index = 1, 40 do
            scope:Send({
                prefix = PREFIX,
                text = "A" .. index,
                distribution = "PARTY",
                priority = CommKit.Priority.ALERT,
            })
        end
        scope:Send({
            prefix = PREFIX,
            text = "B",
            distribution = "PARTY",
            priority = CommKit.Priority.BULK,
        })
        TestEnv.Advance(0)
        local texts = sentTexts()
        assert.are.equal("B", texts[5])
    end)

    it("rotates destinations inside one priority", function()
        for _, name in ipairs({ "X", "Y", "Z" }) do
            for index = 1, 2 do
                scope:Send({
                    prefix = PREFIX,
                    text = name .. index,
                    distribution = "WHISPER",
                    target = name .. "-Realm",
                })
            end
        end
        TestEnv.Advance(0)
        assert.are.same({ "X1", "Y1", "Z1", "X2", "Y2", "Z2" }, sentTexts())
    end)

    it("interleaves the chunks of a long message with other destinations", function()
        scope:Send({
            prefix = PREFIX,
            text = TestEnv.Text(600),
            distribution = "WHISPER",
            target = "Long-Realm",
        })
        scope:Send({ prefix = PREFIX, text = "short", distribution = "WHISPER", target = "S-Realm" })
        TestEnv.Advance(0)
        local sent = TestEnv.TakeOutbox()
        local targets = {}
        for index, entry in ipairs(sent) do
            targets[index] = entry.target
        end
        assert.are.same({ "Long-Realm", "S-Realm", "Long-Realm", "Long-Realm" }, targets)
    end)

    it("keeps one destination's messages in order", function()
        for index = 1, 4 do
            scope:Send({ prefix = PREFIX, text = "m" .. index, distribution = "GUILD" })
        end
        TestEnv.Advance(0)
        assert.are.same({ "m1", "m2", "m3", "m4" }, sentTexts())
    end)
end)
