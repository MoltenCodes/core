local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"
local THROTTLE = TestEnv.SEND_RESULT.AddonMessageThrottle

describe("CommKit budget", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("starts full, in the normal mode, at 800 bytes per second", function()
        assert.are.same({ 4000, 800, 4000, "normal" }, { CommKit:GetBudget() })
    end)

    it("charges prefix, text and 40 bytes of overhead per message", function()
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(99), distribution = "PARTY" })
        TestEnv.Advance(0)
        -- 6 bytes of prefix, 100 bytes of chunk (control byte included), 40 overhead.
        assert.are.equal(4000 - 146, (CommKit:GetBudget()))
    end)

    it("waits for the bucket instead of sending past it", function()
        CommKit:SetLimits({ burst = 1000, maxCps = 100 })
        local handles = {}
        for index = 1, 10 do
            -- Each costs 6 + 95 + 40 = 141 bytes.
            handles[index] = scope:Send({
                prefix = PREFIX,
                text = TestEnv.Text(94),
                distribution = "PARTY",
            })
        end
        TestEnv.Advance(0)
        assert.are.equal(7, #TestEnv.TakeOutbox())
        -- 13 bytes left; the eighth needs 128 more, 1.28 s at 100 bytes per second.
        TestEnv.Advance(1.2)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        TestEnv.Advance(0.1)
        assert.are.equal(1, #TestEnv.TakeOutbox())
        assert.are.equal("queued", handles[9]:GetState())
        TestEnv.Advance(10)
        assert.are.equal(2, #TestEnv.TakeOutbox())
        assert.are.equal("sent", handles[10]:GetState())
    end)

    it("refills at a tenth and holds half a second for five seconds after zoning", function()
        CommKit:SetLimits({ burst = 4000 })
        TestEnv.Emit("PLAYER_ENTERING_WORLD")
        assert.are.same({ 400, 80, 400, "zoning" }, { CommKit:GetBudget() })
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(254), distribution = "PARTY" })
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(254), distribution = "PARTY" })
        TestEnv.Advance(0)
        -- 301 bytes each: one fits in 400, the second waits for 202 bytes at 80 per second.
        assert.are.equal(1, #TestEnv.TakeOutbox())
        TestEnv.Advance(2.4)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        TestEnv.Advance(0.2)
        assert.are.equal(1, #TestEnv.TakeOutbox())
        TestEnv.Advance(3)
        local _, rate, capacity, mode = CommKit:GetBudget()
        assert.are.same({ 800, 4000, "normal" }, { rate, capacity, mode })
    end)

    it("halves the refill below 20 frames per second, sampled on a timer", function()
        local calls = 0
        -- selene: allow(global_usage)
        local original = rawget(_G, "GetFramerate")
        -- selene: allow(global_usage)
        rawset(_G, "GetFramerate", function()
            calls = calls + 1
            return original()
        end)
        TestEnv.SetFramerate(12)
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        for _ = 1, 6 do
            scope:Send({ prefix = PREFIX, text = TestEnv.Text(94), distribution = "PARTY" })
        end
        TestEnv.Advance(0)
        local _, rate, _, mode = CommKit:GetBudget()
        assert.are.same({ 50, "lowFrameRate" }, { rate, mode })
        assert.are.equal(1, calls)
        TestEnv.Advance(3.5)
        -- One sample when the driver woke, then one per second of the ticker.
        assert.are.equal(4, calls)
        TestEnv.SetFramerate(60)
        TestEnv.Advance(1)
        assert.are.equal("normal", select(4, CommKit:GetBudget()))
        TestEnv.Advance(60)
        local sampled = calls
        assert.are.equal(0, (CommKit:GetQueueDepth()))
        TestEnv.Advance(10)
        assert.are.equal(sampled, calls)
    end)

    it("sends a chunk that costs more than a small burst once the bucket is full", function()
        CommKit:SetLimits({ burst = 255, maxCps = 100 })
        local handle =
            scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.TakeOutbox())
        TestEnv.Advance(60)
        assert.are.equal("sent", handle:GetState())
        assert.are.equal(2, #TestEnv.TakeOutbox())
    end)

    it("does not charge outside traffic without HookKit", function()
        -- selene: allow(global_usage)
        rawget(_G, "C_ChatInfo").SendAddonMessage("Other", TestEnv.Text(100), "PARTY")
        assert.are.equal(4000, (CommKit:GetBudget()))
        assert.are.equal(0, CommKit:GetStatistics().outsideMessages)
    end)

    it("validates every limit before changing any", function()
        assert.has_error(function()
            CommKit:SetLimits({ maxCps = 100, burst = 0 })
        end)
        assert.are.equal(800, CommKit:GetLimits().maxCps)
        CommKit:SetLimits({ reassemblyTimeout = 2.5 })
        assert.are.equal(2.5, CommKit:GetLimits().reassemblyTimeout)
        assert.are.same({
            maxQueuedBytes = 65536,
            maxQueuedMessages = 256,
            maxReassemblyStreams = 64,
            maxReassemblyBytesPerSender = 16384,
            maxInFlightPerSender = 4,
            reassemblyTimeout = 2.5,
            maxCps = 800,
            burst = 4000,
            messageOverhead = 40,
        }, CommKit:GetLimits())
        local copy = CommKit:GetLimits()
        copy.maxCps = 1
        assert.are.equal(800, CommKit:GetLimits().maxCps)
    end)
end)

describe("CommKit outside traffic", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.Load({ hookKit = true })
        scope = CommKit:CreateScope()
        -- The hooks are installed when the driver first wakes.
        scope:Send({ prefix = PREFIX, text = "own", distribution = "PARTY" })
        TestEnv.Advance(0)
        TestEnv.TakeOutbox()
    end)
    after_each(TestEnv.Reset)

    it("charges addon and chat messages other code sends, once", function()
        local before = CommKit:GetBudget()
        -- selene: allow(global_usage)
        local chatInfo = rawget(_G, "C_ChatInfo")
        chatInfo.SendAddonMessage("Other", TestEnv.Text(100), "PARTY")
        chatInfo.SendAddonMessageLogged("Other", TestEnv.Text(10), "PARTY")
        chatInfo.SendChatMessage(TestEnv.Text(60), "SAY")
        local statistics = CommKit:GetStatistics()
        assert.are.equal(3, statistics.outsideMessages)
        assert.are.equal((5 + 100 + 40) + (5 + 10 + 40) + (60 + 40), statistics.outsideBytes)
        assert.are.equal(before - statistics.outsideBytes, (CommKit:GetBudget()))
    end)

    it("does not count its own sends as outside traffic", function()
        for _ = 1, 3 do
            scope:Send({ prefix = PREFIX, text = "mine", distribution = "PARTY" })
        end
        TestEnv.Advance(0)
        assert.are.equal(3, #TestEnv.TakeOutbox())
        assert.are.equal(0, CommKit:GetStatistics().outsideMessages)
    end)

    it("lets outside traffic drive the bucket into debt, down to two seconds", function()
        -- selene: allow(global_usage)
        local chatInfo = rawget(_G, "C_ChatInfo")
        for _ = 1, 40 do
            chatInfo.SendAddonMessage("Other", TestEnv.Text(250), "PARTY")
        end
        assert.are.equal(-1600, (CommKit:GetBudget()))
        assert.are.equal(40, #TestEnv.TakeOutbox())
        scope:Send({ prefix = PREFIX, text = "late", distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        -- 1600 bytes of debt plus 51 for the message, at 800 per second.
        TestEnv.Advance(2.1)
        assert.are.equal(1, #TestEnv.TakeOutbox())
    end)
end)

describe("CommKit throttled sends", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("sets a throttled pipe aside and keeps serving the others", function()
        TestEnv.QueueSendResults(THROTTLE)
        local first = scope:Send({
            prefix = PREFIX,
            text = "to A",
            distribution = "WHISPER",
            target = "A-Realm",
        })
        local second = scope:Send({
            prefix = PREFIX,
            text = "to B",
            distribution = "WHISPER",
            target = "B-Realm",
        })
        TestEnv.Advance(0)
        assert.are.equal("queued", first:GetState())
        assert.are.equal("sent", second:GetState())
        assert.are.equal(1, CommKit:GetStatistics().throttled)

        TestEnv.Advance(0.3)
        assert.are.equal("queued", first:GetState())
        TestEnv.Advance(0.1)
        assert.are.equal("sent", first:GetState())
        local attempts = TestEnv.Chat().attempts
        assert.are.same(
            { "A-Realm", "B-Realm", "A-Realm" },
            { attempts[1].target, attempts[2].target, attempts[3].target }
        )
    end)

    it("doubles the backoff on consecutive throttles and resets it on success", function()
        local attempts = TestEnv.Chat().attempts
        TestEnv.QueueSendResults(
            THROTTLE,
            TestEnv.SEND_RESULT.ChannelThrottle,
            THROTTLE,
            TestEnv.SEND_RESULT.Success,
            THROTTLE
        )
        local first = scope:Send({ prefix = PREFIX, text = "x", distribution = "GUILD" })
        local second = scope:Send({ prefix = PREFIX, text = "y", distribution = "GUILD" })
        TestEnv.Advance(0)
        assert.are.equal(1, #attempts)
        -- Set aside for 0.35 s, then 0.7 s, then 1.4 s.
        TestEnv.Advance(0.35)
        assert.are.equal(2, #attempts)
        TestEnv.Advance(0.69)
        assert.are.equal(2, #attempts)
        TestEnv.Advance(0.02)
        assert.are.equal(3, #attempts)
        TestEnv.Advance(1.38)
        assert.are.equal(3, #attempts)
        TestEnv.Advance(0.02)
        -- The first went out; the second was throttled at once, for 0.35 s again.
        assert.are.equal(5, #attempts)
        assert.are.same({ "sent", "queued" }, { first:GetState(), second:GetState() })
        TestEnv.Advance(0.33)
        assert.are.equal(5, #attempts)
        TestEnv.Advance(0.02)
        assert.are.equal("sent", second:GetState())
        assert.are.equal(4, CommKit:GetStatistics().throttled)
    end)

    it("resumes a throttled long message at the chunk that was refused", function()
        local received = {}
        scope:Register(PREFIX, function(_, text)
            received[#received + 1] = text
        end)
        local text = TestEnv.Text(700)
        TestEnv.QueueSendResults(0, THROTTLE)
        scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.Chat().outbox)
        TestEnv.Advance(1)
        TestEnv.Loopback("Friend-Realm")
        assert.are.same({ text }, received)
    end)

    it("fails a message on a result the enum names, and retries one it does not", function()
        TestEnv.QueueSendResults(TestEnv.SEND_RESULT.NotInGroup, 42)
        local outcomes = {}
        local function onComplete(handle, state, reason)
            outcomes[#outcomes + 1] = { handle:GetState(), state, reason }
        end
        scope:Send({ prefix = PREFIX, text = "a", distribution = "PARTY", onComplete = onComplete })
        local second = scope:Send({
            prefix = PREFIX,
            text = "b",
            distribution = "PARTY",
            onComplete = onComplete,
        })
        TestEnv.Advance(0)
        assert.are.same({ { "failed", "failed", "NotInGroup" } }, outcomes)
        assert.are.equal("queued", second:GetState())
        assert.are.equal(1, CommKit:GetStatistics().throttled)
        TestEnv.Advance(0.35)
        assert.are.same({ "sent", "sent" }, { outcomes[2][1], outcomes[2][2] })
        assert.are.equal(1, CommKit:GetStatistics().messagesFailed)
    end)

    it("fails a message whose send raises, and reports the error", function()
        TestEnv.TakeReportedErrors()
        -- selene: allow(global_usage)
        rawget(_G, "C_ChatInfo").SendAddonMessage = function()
            error("client refused", 0)
        end
        local handle = scope:Send({ prefix = PREFIX, text = "a", distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("failed", handle:GetState())
        assert.are.same({ { value = "client refused" } }, TestEnv.TakeReportedErrors())
    end)
end)
