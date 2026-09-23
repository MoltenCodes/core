local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"
local SENDER = "Friend-Realm"

---A chunk as the wire protocol writes it.
---@param control integer 2 first, 3 middle, 4 last
---@param stream integer
---@param number integer the total for a first chunk, the index otherwise
---@param payload string
---@return string
local function chunk(control, stream, number, payload)
    return string.char(control, 0x80 + stream, 0x80 + math.floor(number / 128), 0x80 + number % 128)
        .. payload
end

---Split `text` into the chunks CommKit would send on stream `stream`.
---@param text string
---@param stream integer
---@return string[]
local function split(text, stream)
    local total = math.ceil(#text / 251)
    local chunks = {}
    for index = 1, total do
        local payload = text:sub((index - 1) * 251 + 1, index * 251)
        if index == 1 then
            chunks[index] = chunk(0x02, stream, total, payload)
        elseif index == total then
            chunks[index] = chunk(0x04, stream, index, payload)
        else
            chunks[index] = chunk(0x03, stream, index, payload)
        end
    end
    return chunks
end

describe("CommKit reassembly", function()
    local CommKit, scope, received
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
        received = {}
        assert(scope:Register(PREFIX, function(prefix, text, distribution, sender)
            received[#received + 1] =
                { prefix = prefix, text = text, distribution = distribution, sender = sender }
        end))
    end)
    after_each(TestEnv.Reset)

    it("delivers a single chunk without its control byte", function()
        TestEnv.Deliver(PREFIX, "\001hello", "PARTY", SENDER)
        assert.are.same(
            { { prefix = PREFIX, text = "hello", distribution = "PARTY", sender = SENDER } },
            received
        )
    end)

    it("delivers messages from the logged channel", function()
        TestEnv.DeliverLogged(PREFIX, "\001logged", "GUILD", SENDER)
        assert.are.equal("logged", received[1].text)
        assert.are.equal("GUILD", received[1].distribution)
    end)

    it("reassembles what CommKit sent, in order, through the loopback", function()
        local text = TestEnv.Text(1000)
        assert(scope:Send({ prefix = PREFIX, text = text, distribution = "RAID" }))
        TestEnv.Advance(0)
        assert.are.equal(4, TestEnv.Loopback(SENDER))
        assert.are.equal(1, #received)
        assert.are.equal(text, received[1].text)
        assert.are.equal("RAID", received[1].distribution)
    end)

    it("never delivers a partial message", function()
        local chunks = split(TestEnv.Text(600), 5)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[2], "PARTY", SENDER)
        assert.are.equal(0, #received)
        TestEnv.Deliver(PREFIX, chunks[3], "PARTY", SENDER)
        assert.are.equal(1, #received)
    end)

    it("reassembles chunks that arrive out of order after the first", function()
        local text = TestEnv.Text(251 * 4 + 17)
        local chunks = split(text, 9)
        for _, index in ipairs({ 1, 5, 3, 2, 4 }) do
            TestEnv.Deliver(PREFIX, chunks[index], "PARTY", SENDER)
        end
        assert.are.equal(1, #received)
        assert.are.equal(text, received[1].text)
    end)

    it("keeps interleaved streams from one sender apart", function()
        local first, second = TestEnv.Text(600), string.rep("z", 400)
        local a, b = split(first, 1), split(second, 2)
        TestEnv.Deliver(PREFIX, a[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, b[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, a[2], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, b[2], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, a[3], "PARTY", SENDER)
        assert.are.same({ second, first }, { received[1].text, received[2].text })
    end)

    it("keeps the same stream id apart across senders and distributions", function()
        local text = TestEnv.Text(300)
        local chunks = split(text, 3)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[1], "GUILD", SENDER)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", "Other-Realm")
        assert.are.equal(3, CommKit:GetStatistics().openStreams)
        TestEnv.Deliver(PREFIX, chunks[2], "GUILD", SENDER)
        assert.are.equal("GUILD", received[1].distribution)
        assert.are.equal(2, CommKit:GetStatistics().openStreams)
    end)

    it("expires a stream with a missing chunk and reports it once", function()
        TestEnv.TakeReportedErrors()
        local chunks = split(TestEnv.Text(600), 4)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[3], "PARTY", SENDER)
        TestEnv.Advance(29)
        assert.are.equal(1, CommKit:GetStatistics().openStreams)
        TestEnv.Advance(2)
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
        local reports = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reports)
        assert.are.equal(
            "CommKit dropped 1 incomplete message from " .. SENDER .. ": 1 expired",
            reports[1].value
        )
        TestEnv.Advance(60)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
        TestEnv.Deliver(PREFIX, chunks[2], "PARTY", SENDER)
        assert.are.equal(0, #received)
        assert.are.equal(1, CommKit:GetStatistics().streamsExpired)
    end)

    it("counts the timeout from the last chunk", function()
        local chunks = split(TestEnv.Text(251 * 3 + 1), 4)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Advance(20)
        TestEnv.Deliver(PREFIX, chunks[2], "PARTY", SENDER)
        TestEnv.Advance(20)
        TestEnv.Deliver(PREFIX, chunks[3], "PARTY", SENDER)
        TestEnv.Advance(20)
        TestEnv.Deliver(PREFIX, chunks[4], "PARTY", SENDER)
        assert.are.equal(1, #received)
        assert.are.equal(0, CommKit:GetStatistics().streamsExpired)
    end)

    it("refuses a chunk for a stream it does not hold", function()
        TestEnv.Deliver(PREFIX, chunk(0x03, 1, 2, TestEnv.Text(251)), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x04, 1, 2, "tail"), "PARTY", SENDER)
        assert.are.equal(2, CommKit:GetStatistics().chunksRefused)
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
    end)

    it("refuses a hostile first chunk at quota before it holds anything", function()
        -- 9999 chunks declares far more than the 16 KB a sender may hold.
        TestEnv.Deliver(PREFIX, chunk(0x02, 1, 9999, TestEnv.Text(251)), "PARTY", SENDER)
        -- A total of zero, and a total of one.
        TestEnv.Deliver(PREFIX, chunk(0x02, 2, 0, TestEnv.Text(251)), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x02, 3, 1, TestEnv.Text(251)), "PARTY", SENDER)
        -- A first chunk that is not full, and a header with a digit below 0x80.
        TestEnv.Deliver(PREFIX, chunk(0x02, 4, 2, "short"), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, "\002\001\128\130" .. TestEnv.Text(251), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, "\002\129", "PARTY", SENDER)
        local statistics = CommKit:GetStatistics()
        assert.are.equal(6, statistics.chunksRefused)
        assert.are.equal(0, statistics.openStreams)
        assert.are.equal(0, statistics.streamsOpened)
    end)

    it("drops a stream whose chunk index is out of range, reporting it once", function()
        TestEnv.TakeReportedErrors()
        local chunks = split(TestEnv.Text(600), 6)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x03, 6, 7, TestEnv.Text(251)), "PARTY", SENDER)
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
        local reports = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reports)
        assert.is_truthy(reports[1].value:find("malformed", 1, true))
        TestEnv.Deliver(PREFIX, chunks[3], "PARTY", SENDER)
        assert.are.equal(0, #received)
    end)

    it("drops a stream on a duplicate chunk, a short middle or a last chunk too early", function()
        local chunks = split(TestEnv.Text(251 * 3 + 5), 7)
        TestEnv.Deliver(PREFIX, chunks[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[2], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[2], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunks[1], "GUILD", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x03, 7, 2, "short"), "GUILD", SENDER)
        TestEnv.Deliver(PREFIX, chunks[1], "RAID", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x04, 7, 3, "early"), "RAID", SENDER)
        assert.are.equal(3, CommKit:GetStatistics().streamsMalformed)
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
        -- One report at once; the other two wait for the sender's quiet minute.
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
        TestEnv.Advance(60)
        assert.are.same({
            {
                value = "CommKit dropped 2 incomplete messages from " .. SENDER .. ": 2 malformed",
            },
        }, TestEnv.TakeReportedErrors())
    end)

    it("bounds streams in flight per sender", function()
        for stream = 1, 5 do
            TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), stream)[1], "PARTY", SENDER)
        end
        assert.are.equal(4, CommKit:GetStatistics().openStreams)
        assert.are.equal(1, CommKit:GetStatistics().chunksRefused)
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "PARTY", "Other-Realm")
        assert.are.equal(5, CommKit:GetStatistics().openStreams)
    end)

    it("bounds the bytes one sender's streams may declare", function()
        CommKit:SetLimits({ maxReassemblyBytesPerSender = 1000 })
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(600), 1)[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(600), 2)[1], "PARTY", SENDER)
        assert.are.equal(1, CommKit:GetStatistics().openStreams)
        assert.are.equal(1, CommKit:GetStatistics().chunksRefused)
    end)

    it("bounds the streams held across every sender", function()
        CommKit:SetLimits({ maxReassemblyStreams = 2 })
        for index = 1, 3 do
            TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "PARTY", "Peer" .. index)
        end
        assert.are.equal(2, CommKit:GetStatistics().openStreams)
        assert.are.equal(1, CommKit:GetStatistics().chunksRefused)
    end)

    it("drops a restarted stream id and keeps the new one", function()
        TestEnv.TakeReportedErrors()
        local old = split(TestEnv.Text(600), 3)
        local new = split(string.rep("n", 300), 3)
        TestEnv.Deliver(PREFIX, old[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, new[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, new[2], "PARTY", SENDER)
        assert.are.equal(string.rep("n", 300), received[1].text)
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)

    it("evicts the group streams of a sender who left the group", function()
        TestEnv.TakeReportedErrors()
        TestEnv.SetGroupMembers({ SENDER, "Stays-Realm" })
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "RAID", "Stays-Realm")
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "GUILD", SENDER)
        TestEnv.Emit("GROUP_ROSTER_UPDATE")
        assert.are.equal(3, CommKit:GetStatistics().openStreams)

        TestEnv.SetGroupMembers({ "Stays-Realm" })
        TestEnv.Emit("GROUP_ROSTER_UPDATE")
        local statistics = CommKit:GetStatistics()
        assert.are.equal(2, statistics.openStreams)
        assert.are.equal(1, statistics.streamsEvicted)
        local reports = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reports)
        assert.is_truthy(reports[1].value:find("departed", 1, true))
    end)

    it("asks for a group member by the name before the realm too", function()
        TestEnv.SetGroupMembers({ "Friend" })
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "PARTY", SENDER)
        TestEnv.Emit("GROUP_ROSTER_UPDATE")
        assert.are.equal(1, CommKit:GetStatistics().openStreams)
    end)

    it("ignores prefixes nobody registered and unknown control bytes", function()
        TestEnv.Deliver("Other", "\001hello", "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, "\005future", "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, "plain", "PARTY", SENDER)
        assert.are.equal(0, #received)
        assert.are.equal(2, CommKit:GetStatistics().chunksRefused)
    end)

    it("drops a message carrying a secret before using it", function()
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return value == "\001secret"
        end)
        TestEnv.Deliver(PREFIX, "\001secret", "PARTY", SENDER)
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", nil)
        assert.are.equal(0, #received)
        assert.are.equal(1, CommKit:GetStatistics().secretsDropped)
    end)

    it("isolates a failing callback from the next one", function()
        TestEnv.TakeReportedErrors()
        assert(scope:Register(PREFIX, function()
            error("listener failed", 0)
        end))
        local later = 0
        assert(scope:Register(PREFIX, function()
            later = later + 1
        end))
        TestEnv.Deliver(PREFIX, "\001x", "PARTY", SENDER)
        assert.are.equal(1, #received)
        assert.are.equal(1, later)
        assert.are.same({ { value = "listener failed" } }, TestEnv.TakeReportedErrors())
    end)

    it("discards the streams of a prefix when its last registration goes", function()
        TestEnv.TakeReportedErrors()
        TestEnv.Deliver(PREFIX, split(TestEnv.Text(300), 1)[1], "PARTY", SENDER)
        scope:UnregisterAll()
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)
end)
