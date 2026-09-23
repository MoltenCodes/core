local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"
local SENDER = "Friend-Realm"

---A chunk as the wire protocol writes it on the ordinary channel.
---@param control integer
---@param stream integer
---@param number integer
---@param payload string
---@return string
local function chunk(control, stream, number, payload)
    return string.char(control, 0x80 + stream, 0x80 + math.floor(number / 128), 0x80 + number % 128)
        .. payload
end

describe("CommKit send driver", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    ---Driver jobs alive in CommKit's scheduler scope.
    ---@return integer
    local function driverJobs()
        local schedulerScope = CommKit._state.kitScopes.scheduler
        if schedulerScope == false then
            return 0
        end
        return schedulerScope:GetActiveCount()
    end

    it("keeps one driver job while completion callbacks chain sends", function()
        CommKit:SetLimits({ burst = 400, maxCps = 400 })
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(2000), distribution = "GUILD" })
        local chained, most = 0, 0
        local function chain()
            if chained < 60 then
                chained = chained + 1
                scope:Send({
                    prefix = PREFIX,
                    text = "c",
                    distribution = "PARTY",
                    onComplete = chain,
                })
            end
        end
        chain()
        for _ = 1, 400 do
            TestEnv.Advance(0.05)
            most = math.max(most, driverJobs())
        end
        assert.are.equal(60, chained)
        assert.is_true(most <= 1, "driver jobs reached " .. most)
        assert.are.equal(0, (CommKit:GetQueueDepth()))
        assert.are.equal(0, driverJobs())
    end)

    ---Native timers still armed: the sampler ticker, a delayed driver run.
    ---@return integer
    local function liveTimers()
        local live = 0
        for _, native in ipairs(TestEnv.NativeTimers()) do
            if not native.cancelled and (native.repeating or not native.fired) then
                live = live + 1
            end
        end
        return live
    end

    it("disarms the driver when cancelling empties the queue while it waits", function()
        CommKit:SetLimits({ burst = 255, maxCps = 1 })
        scope:Send({ prefix = PREFIX, text = "first", distribution = "PARTY" })
        TestEnv.Advance(0)
        -- The bucket is now short by about 50 bytes: the driver waits 50 s.
        scope:Send({ prefix = PREFIX, text = TestEnv.Text(254), distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal(1, driverJobs())
        assert.is_true(liveTimers() > 0)
        assert.are.equal(1, scope:CancelAll())
        assert.are.equal(0, driverJobs())
        assert.are.equal(0, liveTimers())
    end)

    it("disarms the driver when a run fails with nothing left queued", function()
        -- A host whose securecallfunction lets a callback error escape.
        -- selene: allow(global_usage)
        rawset(_G, "securecallfunction", function(callback, ...)
            return callback(...)
        end)
        TestEnv.TakeReportedErrors()
        scope:Send({
            prefix = PREFIX,
            text = "last",
            distribution = "PARTY",
            onComplete = function()
                error("escaped", 0)
            end,
        })
        TestEnv.Advance(0)
        assert.are.same({ { value = "escaped" } }, TestEnv.TakeReportedErrors())
        assert.are.equal(0, driverJobs())
        assert.are.equal(0, liveTimers())
    end)

    it("sends at most 32 chunks per run even when callbacks keep sending", function()
        CommKit:SetLimits({ burst = 1000000, maxCps = 100000, maxQueuedMessages = 1000 })
        local function chain()
            scope:Send({ prefix = PREFIX, text = "c", distribution = "PARTY", onComplete = chain })
        end
        for _ = 1, 40 do
            chain()
        end
        TestEnv.Tick()
        assert.are.equal(32, #TestEnv.TakeOutbox())
        assert.is_true(driverJobs() <= 1)
        scope:CancelAll()
    end)
end)

describe("CommKit drop reports", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
        scope:Register(PREFIX, function() end)
        TestEnv.TakeReportedErrors()
    end)
    after_each(TestEnv.Reset)

    it("reports a flood of hostile first chunks at most once a minute per sender", function()
        for _ = 1, 100 do
            TestEnv.Deliver(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "PARTY", "Hostile-Realm")
        end
        assert.are.equal(99, CommKit:GetStatistics().streamsRestarted)
        assert.are.same(
            { { value = "CommKit dropped 1 incomplete message from Hostile-Realm: 1 restarted" } },
            TestEnv.TakeReportedErrors()
        )
        TestEnv.Advance(59)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
        TestEnv.Advance(1)
        -- The last stream expired at 30 s and joins the aggregate.
        assert.are.same({
            {
                value = "CommKit dropped 99 incomplete messages from Hostile-Realm: 1 expired, 98 restarted",
            },
        }, TestEnv.TakeReportedErrors())
        TestEnv.Advance(120)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)

    it("keeps the drop reports of different senders apart", function()
        TestEnv.Deliver(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "PARTY", "A-Realm")
        TestEnv.Deliver(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "PARTY", "A-Realm")
        TestEnv.Deliver(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "PARTY", "B-Realm")
        TestEnv.Deliver(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "PARTY", "B-Realm")
        assert.are.equal(2, #TestEnv.TakeReportedErrors())
    end)

    it("drops a stream silently when its sender cancels it", function()
        local receiver = CommKit:CreateScope()
        local received = 0
        receiver:Register("CKAbort", function()
            received = received + 1
        end)
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        local handle =
            scope:Send({ prefix = "CKAbort", text = TestEnv.Text(600), distribution = "PARTY" })
        TestEnv.Advance(0)
        TestEnv.Loopback(SENDER)
        assert.are.equal(1, CommKit:GetStatistics().openStreams)
        handle:Cancel()
        TestEnv.Advance(10)
        assert.are.equal(1, TestEnv.Loopback(SENDER))
        local statistics = CommKit:GetStatistics()
        assert.are.equal(0, statistics.openStreams)
        assert.are.equal(1, statistics.streamsAborted)
        TestEnv.Advance(120)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
        assert.are.equal(0, received)
    end)

    it("ignores an abort whose chunk count does not match the stream", function()
        TestEnv.Deliver(PREFIX, chunk(0x02, 2, 3, TestEnv.Text(251)), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x05, 2, 4, ""), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x05, 9, 3, ""), "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, chunk(0x05, 2, 3, "payload"), "PARTY", SENDER)
        local statistics = CommKit:GetStatistics()
        assert.are.equal(1, statistics.openStreams)
        assert.are.equal(3, statistics.chunksRefused)
    end)

    it("reports quota refusals, aggregated", function()
        for stream = 1, 6 do
            TestEnv.Deliver(PREFIX, chunk(0x02, stream, 3, TestEnv.Text(251)), "PARTY", SENDER)
        end
        assert.are.equal(2, CommKit:GetStatistics().chunksRefusedQuota)
        assert.are.same(
            { { value = "CommKit dropped 1 incomplete message from " .. SENDER .. ": 1 quota" } },
            TestEnv.TakeReportedErrors()
        )
    end)
end)

describe("CommKit sender-side stream bounds", function()
    local CommKit, scope, received
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
        received = {}
        scope:Register(PREFIX, function(_, text)
            received[#received + 1] = text
        end)
        TestEnv.TakeReportedErrors()
    end)
    after_each(TestEnv.Reset)

    it("delivers six concurrent 1000-byte sends across six pipes", function()
        local texts = {}
        local index = 0
        for _, priority in ipairs({ "ALERT", "NORMAL", "BULK" }) do
            for _, logged in ipairs({ false, true }) do
                index = index + 1
                texts[index] = string.rep(string.char(64 + index), 1000)
                assert(scope:Send({
                    prefix = PREFIX,
                    text = texts[index],
                    distribution = "PARTY",
                    priority = priority,
                    constraints = { logged = logged },
                }))
            end
        end
        for _ = 1, 40 do
            TestEnv.Advance(0.5)
            TestEnv.Loopback(SENDER)
        end
        table.sort(received)
        assert.are.same(texts, received)
        assert.are.equal(0, CommKit:GetStatistics().chunksRefusedQuota)
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)

    it("delivers two 9000-byte sends one after the other", function()
        local first, second = string.rep("a", 9000), string.rep("b", 9000)
        scope:Send({ prefix = PREFIX, text = first, distribution = "RAID" })
        scope:Send({ prefix = PREFIX, text = second, distribution = "RAID", priority = "ALERT" })
        for _ = 1, 60 do
            TestEnv.Advance(0.5)
            TestEnv.Loopback(SENDER)
        end
        table.sort(received)
        assert.are.same({ first, second }, received)
        assert.are.equal(0, CommKit:GetStatistics().chunksRefusedQuota)
    end)

    it("never reuses the stream id of a message still in flight", function()
        CommKit:SetLimits({
            maxQueuedBytes = 200000,
            maxReassemblyBytesPerSender = 65536,
            burst = 1000000,
            maxCps = 100000,
        })
        -- A 160-chunk BULK message on stream 0 is still in flight while 128
        -- two-chunk ALERT messages to the same receivers take the ids after
        -- it and wrap past 127.
        local long = string.rep("L", 40000)
        assert(
            scope:Send({ prefix = PREFIX, text = long, distribution = "PARTY", priority = "BULK" })
        )
        local expected = { long }
        for index = 1, 128 do
            local text = string.rep(string.char(65 + index % 26), 300)
            expected[#expected + 1] = text
            assert(scope:Send({
                prefix = PREFIX,
                text = text,
                distribution = "PARTY",
                priority = "ALERT",
            }))
        end
        for _ = 1, 100 do
            TestEnv.Advance(0.1)
            TestEnv.Loopback(SENDER)
        end
        table.sort(expected)
        table.sort(received)
        assert.are.same(expected, received)
        local statistics = CommKit:GetStatistics()
        assert.are.equal(0, statistics.streamsRestarted)
        assert.are.equal(0, statistics.streamsMalformed)
    end)

    it("keeps a cancelled stream's allowance until its abort leaves", function()
        CommKit:SetLimits({ maxInFlightPerSender = 1, burst = 1000000, maxCps = 100000 })
        local first = assert(scope:Send({
            prefix = PREFIX,
            text = TestEnv.Text(600),
            distribution = "PARTY",
            onProgress = function(handle)
                handle:Cancel()
            end,
        }))
        -- The abort is throttled; the next message must wait for it.
        TestEnv.QueueSendResults(
            TestEnv.SEND_RESULT.Success,
            TestEnv.SEND_RESULT.AddonMessageThrottle
        )
        local second = string.rep("s", 600)
        assert(scope:Send({ prefix = PREFIX, text = second, distribution = "RAID" }))
        TestEnv.Advance(0)
        assert.are.equal("cancelled", first:GetState())
        local controls = {}
        for index, entry in ipairs(TestEnv.Chat().outbox) do
            controls[index] = entry.text:byte(1)
        end
        assert.are.same({ 0x02 }, controls)
        TestEnv.Advance(1)
        TestEnv.Loopback(SENDER)
        assert.are.same({ second }, received)
        local statistics = CommKit:GetStatistics()
        assert.are.equal(1, statistics.streamsAborted)
        assert.are.equal(0, statistics.chunksRefusedQuota)
    end)

    it("aborts a stream whose send fails mid-message, holding its allowance", function()
        CommKit:SetLimits({ maxInFlightPerSender = 1, burst = 1000000, maxCps = 100000 })
        local first = assert(
            scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
        )
        -- The first chunk leaves, the second fails, and the abort is throttled;
        -- the next message must wait for the abort.
        TestEnv.QueueSendResults(
            TestEnv.SEND_RESULT.Success,
            TestEnv.SEND_RESULT.GeneralError,
            TestEnv.SEND_RESULT.AddonMessageThrottle
        )
        local second = string.rep("s", 600)
        assert(scope:Send({ prefix = PREFIX, text = second, distribution = "RAID" }))
        TestEnv.Advance(0)
        assert.are.equal("failed", first:GetState())
        local controls = {}
        for index, entry in ipairs(TestEnv.Chat().outbox) do
            controls[index] = entry.text:byte(1)
        end
        assert.are.same({ 0x02 }, controls)
        TestEnv.Advance(1)
        controls = {}
        for index, entry in ipairs(TestEnv.Chat().outbox) do
            controls[index] = entry.text:byte(1)
        end
        assert.are.equal(0x05, controls[2])
        TestEnv.Loopback(SENDER)
        assert.are.same({ second }, received)
        local statistics = CommKit:GetStatistics()
        assert.are.equal(1, statistics.streamsAborted)
        assert.are.equal(0, statistics.chunksRefusedQuota)
    end)

    it("refuses a message larger than one receiver accepts from one sender", function()
        assert.are.same(
            { nil, "tooLarge" },
            { scope:Send({ prefix = PREFIX, text = TestEnv.Text(16700), distribution = "RAID" }) }
        )
    end)
end)

describe("CommKit logged channel header", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("writes stream ids and chunk numbers as printable ASCII and reassembles them", function()
        local received = {}
        scope:Register(PREFIX, function(_, text, distribution)
            received[#received + 1] = { text, distribution }
        end)
        local text = TestEnv.Text(600)
        scope:Send({
            prefix = PREFIX,
            text = text,
            distribution = "GUILD",
            constraints = { logged = true },
        })
        TestEnv.Advance(0)
        local chunks = TestEnv.Chat().outbox
        assert.are.equal(3, #chunks)
        assert.are.same({ 0x02, 0x30, 0x30, 0x33 }, { chunks[1].text:byte(1, 4) })
        assert.are.same({ 0x03, 0x30, 0x30, 0x32 }, { chunks[2].text:byte(1, 4) })
        assert.are.same({ 0x04, 0x30, 0x30, 0x33 }, { chunks[3].text:byte(1, 4) })
        for _, entry in ipairs(chunks) do
            assert.is_true(entry.logged)
            for position = 2, 4 do
                local byte = entry.text:byte(position)
                assert.is_true(byte >= 0x30 and byte <= 0x7A)
            end
        end
        TestEnv.Loopback(SENDER)
        assert.are.same({ { text, "GUILD" } }, received)
    end)

    it("refuses ordinary-channel digits on the logged channel", function()
        scope:Register(PREFIX, function() end)
        TestEnv.DeliverLogged(PREFIX, chunk(0x02, 1, 3, TestEnv.Text(251)), "GUILD", SENDER)
        assert.are.equal(1, CommKit:GetStatistics().chunksRefused)
        assert.are.equal(0, CommKit:GetStatistics().openStreams)
    end)
end)

describe("CommKit CHANNEL targets", function()
    after_each(TestEnv.Reset)

    it("accepts a channel number or numeric string only", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local function send(target)
            return scope:Send({
                prefix = PREFIX,
                text = "x",
                distribution = "CHANNEL",
                target = target,
            })
        end
        assert.are.same({ nil, "badDistribution" }, { send("General") })
        assert.are.same({ nil, "badDistribution" }, { send("5a") })
        assert.is_truthy(send("5"))
        assert.is_truthy(send(7))
    end)
end)

describe("CommKit SyncSet reply bounds", function()
    local CommKit, CodecKit, scope, sync
    before_each(function()
        local loaded
        CommKit, loaded = TestEnv.Load()
        CodecKit = loaded.CodecKit
        scope = CommKit:CreateScope()
        sync = assert(scope:SyncSet("CKSync", { fields = { "name", "blob" } }))
    end)
    after_each(TestEnv.Reset)

    ---@param message table
    ---@param sender string
    ---@param distribution string?
    local function receive(message, sender, distribution)
        local ok, text = CodecKit:Encode(message, { channel = "addon" })
        assert.is_true(ok)
        TestEnv.Deliver("CKSync", "\001" .. text, distribution or "WHISPER", sender)
    end

    it("answers requests only when whispered", function()
        sync:Set("name", "Bob")
        receive({ 1, {} }, "Peer-Realm", "PARTY")
        receive({ 1, {} }, "Peer-Realm", "GUILD")
        TestEnv.Advance(0)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        assert.are.equal(2, CommKit:GetStatistics().syncRejected)
    end)

    it("keeps at most one reply per peer in the queue", function()
        CommKit:SetLimits({ burst = 255, maxCps = 1 })
        sync:Set("blob", TestEnv.Text(600))
        receive({ 1, {} }, "Peer-Realm")
        TestEnv.Advance(1.5)
        receive({ 1, {} }, "Peer-Realm")
        assert.are.equal(1, CommKit:GetStatistics().syncReplyDropped)
        assert.are.equal(1, scope:GetPendingCount())
    end)

    it("caps queued reply bytes across peers, keeping the queue for everyone else", function()
        CommKit:SetLimits({ burst = 255, maxCps = 1 })
        sync:Set("blob", TestEnv.Text(3000))
        for index = 1, 10 do
            receive({ 1, {} }, "Peer" .. index)
        end
        local statistics = CommKit:GetStatistics()
        assert.is_true(statistics.syncReplyDropped >= 7)
        assert.is_true(select(2, CommKit:GetQueueDepth()) <= 8192)
        assert.is_truthy(
            scope:Send({ prefix = PREFIX, text = "still room", distribution = "PARTY" })
        )
    end)

    it("keeps a peer's reply interval when the cache is full", function()
        for index = 1, 64 do
            receive({ 1, {} }, "Peer" .. index)
        end
        TestEnv.Advance(0)
        TestEnv.TakeOutbox()
        receive({ 1, {} }, "Peer65")
        receive({ 1, {} }, "Peer1")
        TestEnv.Advance(0)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        TestEnv.Advance(1)
        receive({ 1, {} }, "Peer65")
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.TakeOutbox())
    end)

    it("fires OnChanged once when a field is both delivered and removed", function()
        local changes = {}
        sync:OnChanged(function(_, field, value)
            changes[#changes + 1] = { field, value }
        end)
        receive({ 3, { name = "Ann" }, {} }, "Peer-Realm")
        receive({ 3, { name = "Other" }, { "name" } }, "Peer-Realm")
        assert.are.same({ { "name", "Ann" }, { "name" } }, changes)
        assert.is_nil(sync:GetRemote("Peer-Realm", "name"))
    end)
end)
