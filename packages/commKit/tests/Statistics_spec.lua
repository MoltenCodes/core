local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

describe("CommKit statistics", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("starts at zero for every counter", function()
        local statistics = CommKit:GetStatistics()
        for name, value in pairs(statistics) do
            assert.are.equal(0, value, name)
        end
        assert.are.equal(
            37,
            (function()
                local count = 0
                for _ in pairs(statistics) do
                    count = count + 1
                end
                return count
            end)()
        )
    end)

    it("counts what was queued, sent, cancelled, failed and received", function()
        scope:Register(PREFIX, function() end)
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
        scope:Send({ prefix = PREFIX, text = "short", distribution = "PARTY" })
        scope:Send({ prefix = PREFIX, text = "cancel me", distribution = "GUILD" }):Cancel()
        TestEnv.QueueSendResults(0, 0, 0, TestEnv.SEND_RESULT.AddonMessageThrottle)
        TestEnv.Advance(0)
        TestEnv.Advance(1)
        TestEnv.Loopback("Friend-Realm")

        local statistics = CommKit:GetStatistics()
        assert.are.equal(3, statistics.messagesQueued)
        assert.are.equal(2, statistics.messagesSent)
        assert.are.equal(1, statistics.messagesCancelled)
        assert.are.equal(0, statistics.messagesFailed)
        assert.are.equal(4, statistics.chunksSent)
        assert.are.equal(255 + 255 + 102 + 6, statistics.bytesSent)
        assert.are.equal(1, statistics.throttled)
        assert.are.equal(2, statistics.messagesReceived)
        assert.are.equal(605, statistics.bytesReceived)
        assert.are.equal(4, statistics.chunksReceived)
        assert.are.equal(1, statistics.streamsOpened)
        assert.are.equal(1, statistics.streamsCompleted)
        assert.are.equal(0, statistics.queuedMessages)
        assert.are.equal(0, statistics.openStreams)
    end)

    it("returns a fresh table on every call", function()
        local first = CommKit:GetStatistics()
        first.messagesSent = 99
        assert.are.equal(0, CommKit:GetStatistics().messagesSent)
        assert.are_not.equal(first, CommKit:GetStatistics())
    end)
end)
