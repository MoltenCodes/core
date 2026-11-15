local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

-- Revision 6: a send made while the driver is idle leaves inside `Send` as
-- far as the bucket pays, and its progress and completion callbacks are held
-- until the next driver run, so none runs before `Send` returns. See "The
-- driver" and "Send states" in `docs/API.md`.

describe("CommKit sends at once", function()
  local CommKit, scope, state, calls
  before_each(function()
    CommKit = TestEnv.NewPackage()
    state = CommKit._state
    scope = CommKit:CreateScope()
    calls = {}
  end)
  after_each(TestEnv.Reset)

  ---A request whose callbacks record `progress` and `complete` calls in
  ---`calls`, in order, with the handle's name.
  ---@param name string
  ---@param text string
  ---@param distribution string?
  ---@return table
  local function tracked(name, text, distribution)
    return {
      prefix = PREFIX,
      text = text,
      distribution = distribution or "PARTY",
      onProgress = function(_, sent)
        calls[#calls + 1] = name .. " progress " .. sent
      end,
      onComplete = function(_, completed, reason)
        calls[#calls + 1] = name .. " " .. completed .. " " .. tostring(reason)
      end,
    }
  end

  ---Driver jobs alive in CommKit's scheduler scope.
  ---@return integer
  local function driverJobs()
    local schedulerScope = state.kitScopes.scheduler
    if schedulerScope == false then
      return 0
    end
    return schedulerScope:GetActiveCount()
  end

  it("sends a message the bucket pays for before Send returns, building no job", function()
    local handle = scope:Send({ prefix = PREFIX, text = "hello", distribution = "PARTY" })
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(5, handle:GetBytesSent())
    local outbox = TestEnv.TakeOutbox()
    assert.are.equal(1, #outbox)
    assert.are.equal("\001hello", outbox[1].text)
    assert.are.equal(0, driverJobs())
    assert.are.equal(0, scope:GetPendingCount())
    assert.are.same({ 0, 0 }, { CommKit:GetQueueDepth() })
    assert.are.equal(1, CommKit:GetStatistics().messagesSent)
  end)

  it("returns a sending handle when the bucket pays for part of a message", function()
    CommKit:SetLimits({ burst = 400, maxCps = 100 })
    local handle = scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
    assert.are.same({ "sending", 251 }, { handle:GetState(), handle:GetBytesSent() })
    assert.are.equal(1, #TestEnv.TakeOutbox())
    assert.are.equal(1, scope:GetPendingCount())
    TestEnv.Advance(30)
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(2, #TestEnv.TakeOutbox())
  end)

  it("queues a message the bucket cannot pay for, calling nothing", function()
    CommKit:SetLimits({ burst = 255, maxCps = 10 })
    assert.are.equal("sent", scope:Send(tracked("a", TestEnv.Text(200))):GetState())
    local handle = scope:Send(tracked("b", "later"))
    assert.are.equal("queued", handle:GetState())
    assert.are.equal(1, #TestEnv.TakeOutbox())
    assert.are.same({}, calls)
    TestEnv.Advance(0)
    assert.are.same({ "a progress 200", "a sent nil" }, calls)
    TestEnv.Advance(60)
    assert.are.equal("sent", handle:GetState())
    assert.are.same({ "a progress 200", "a sent nil", "b progress 5", "b sent nil" }, calls)
  end)

  it("never calls back before Send returns, and calls back on the next run", function()
    local returned = false
    local handle = scope:Send({
      prefix = PREFIX,
      text = TestEnv.Text(600),
      distribution = "PARTY",
      onProgress = function()
        assert.is_true(returned)
        calls[#calls + 1] = "progress"
      end,
      onComplete = function(own, completed)
        assert.is_true(returned)
        calls[#calls + 1] = completed
        assert.are.equal("sent", own:GetState())
      end,
    })
    returned = true
    assert.are.equal("sent", handle:GetState())
    assert.are.same({}, calls)
    TestEnv.Tick()
    assert.are.same({ "progress", "progress", "progress", "sent" }, calls)
    assert.are.equal(0, driverJobs())
    assert.are.equal(0, state.deferred.count)
  end)

  it("sends at once again while earlier callbacks are still held", function()
    scope:Send(tracked("a", "one"))
    scope:Send(tracked("b", "two"))
    assert.are.equal(2, #TestEnv.TakeOutbox())
    assert.are.equal(1, driverJobs())
    TestEnv.Tick()
    assert.are.same({ "a progress 3", "a sent nil", "b progress 3", "b sent nil" }, calls)
    assert.are.equal(0, driverJobs())
  end)

  it("queues a send made inside a held callback and sends it in the same run", function()
    local inner
    scope:Send({
      prefix = PREFIX,
      text = "outer",
      distribution = "PARTY",
      onComplete = function()
        inner = scope:Send({ prefix = PREFIX, text = "inner", distribution = "PARTY" })
        assert.are.equal("queued", inner:GetState())
      end,
    })
    assert.are.equal(1, #TestEnv.TakeOutbox())
    TestEnv.Tick()
    assert.are.equal("sent", inner:GetState())
    assert.are.equal("\001inner", TestEnv.TakeOutbox()[1].text)
    assert.are.equal(0, driverJobs())
  end)

  it("runs held callbacks first when a cancel completes a message", function()
    CommKit:SetLimits({ burst = 400, maxCps = 100 })
    local handle = scope:Send(tracked("a", TestEnv.Text(600)))
    assert.are.same({}, calls)
    assert.is_true(handle:Cancel())
    assert.are.same({ "a progress 251", "a cancelled cancelled" }, calls)
    TestEnv.Advance(30)
    assert.are.same({ "a progress 251", "a cancelled cancelled" }, calls)
    -- The first chunk and the abort that followed it.
    local outbox = TestEnv.TakeOutbox()
    assert.are.equal(2, #outbox)
    assert.are.equal(0x05, outbox[2].text:byte(1))
  end)

  it("runs held callbacks first when the scope closes", function()
    CommKit:SetLimits({ burst = 400, maxCps = 100 })
    scope:Send(tracked("a", "short"))
    scope:Send(tracked("b", TestEnv.Text(600), "GUILD"))
    scope:Close()
    assert.are.same({
      "a progress 5",
      "a sent nil",
      "b progress 251",
      "b cancelled closed",
    }, calls)
    assert.are.equal(0, state.deferred.count)
  end)

  it("disarms the driver when a cancel empties the queue while callbacks are held", function()
    -- Revision 9: the cancel used to leave the job armed after running the
    -- held callbacks, so the next send the bucket paid for stayed queued.
    CommKit:SetLimits({ burst = 255, maxCps = 10 })
    local first = scope:Send(tracked("a", TestEnv.Text(200)))
    assert.are.equal("sent", first:GetState())
    local second = scope:Send(tracked("b", "later"))
    assert.are.equal("queued", second:GetState())
    assert.is_true(second:Cancel())
    assert.are.same({ "a progress 200", "a sent nil", "b cancelled cancelled" }, calls)
    assert.is_false(state.driver.job)
    assert.are.equal(0, driverJobs())

    state.budget.tokens = 255
    local third = scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
    assert.are.equal("sent", third:GetState())
  end)

  it("keeps each handle's callbacks in order across the held and the driven chunks", function()
    CommKit:SetLimits({ burst = 700, maxCps = 1000 })
    scope:Send(tracked("a", TestEnv.Text(1000)))
    -- Two 301-byte chunks left inside `Send`; the rest follow on the driver.
    assert.are.equal(2, #TestEnv.TakeOutbox())
    TestEnv.Advance(5)
    assert.are.same(
      { "a progress 251", "a progress 502", "a progress 753", "a progress 1000", "a sent nil" },
      calls
    )
  end)

  it("reports an error a held callback lets escape and still sends at once", function()
    -- A host whose securecallfunction lets a callback error escape.
    -- selene: allow(global_usage)
    rawset(_G, "securecallfunction", function(callback, ...)
      return callback(...)
    end)
    TestEnv.TakeReportedErrors()
    scope:Send({
      prefix = PREFIX,
      text = "a",
      distribution = "PARTY",
      onComplete = function()
        error("escaped", 0)
      end,
    })
    TestEnv.Tick()
    assert.are.same({ { value = "escaped" } }, TestEnv.TakeReportedErrors())
    assert.are.equal(0, state.deferred.flushing)
    local handle = scope:Send({ prefix = PREFIX, text = "b", distribution = "PARTY" })
    assert.are.equal("sent", handle:GetState())
  end)

  it("fails a message the client refuses inside Send, calling back later", function()
    TestEnv.QueueSendResults(TestEnv.SEND_RESULT.NotInGroup)
    local handle = scope:Send(tracked("a", "hello"))
    assert.are.equal("failed", handle:GetState())
    assert.are.same({}, calls)
    TestEnv.Tick()
    assert.are.same({ "a failed NotInGroup" }, calls)
  end)

  it("sets a throttled pipe aside inside Send and retries it later", function()
    TestEnv.QueueSendResults(TestEnv.SEND_RESULT.AddonMessageThrottle)
    local handle = scope:Send({ prefix = PREFIX, text = "hello", distribution = "PARTY" })
    assert.are.equal("queued", handle:GetState())
    assert.are.equal(0, #TestEnv.TakeOutbox())
    TestEnv.Advance(1)
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(1, #TestEnv.TakeOutbox())
  end)

  it("samples the frame rate at most once a second across sends that leave at once", function()
    local sampled = 0
    -- selene: allow(global_usage)
    local original = rawget(_G, "GetFramerate")
    -- selene: allow(global_usage)
    rawset(_G, "GetFramerate", function()
      sampled = sampled + 1
      return original()
    end)
    for _ = 1, 5 do
      scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
    end
    assert.are.equal(1, sampled)
    TestEnv.Advance(1)
    scope:Send({ prefix = PREFIX, text = "y", distribution = "PARTY" })
    assert.are.equal(2, sampled)
    assert.are.equal(6, #TestEnv.TakeOutbox())
  end)
end)

describe("CommKit queue records", function()
  local CommKit, scope, state
  before_each(function()
    CommKit = TestEnv.NewPackage()
    state = CommKit._state
    scope = CommKit:CreateScope()
  end)
  after_each(TestEnv.Reset)

  it("reuses a finished record, keeping nothing of its message", function()
    local handle = scope:Send({
      prefix = PREFIX,
      text = "first",
      distribution = "PARTY",
      onComplete = function() end,
    })
    assert.are.equal("sent", handle:GetState())
    local records = state.spares.records
    assert.are.equal(1, #records)
    local record = records[1]
    assert.are.same({ false, false, false, false, false, false }, {
      record.text,
      record.handle,
      record.scope,
      record.onProgress,
      record.onComplete,
      record.pipe,
    })
    TestEnv.HoldSends(CommKit)
    local next = scope:Send({ prefix = PREFIX, text = "second", distribution = "PARTY" })
    assert.are.equal(0, #records)
    assert.are.equal(record, rawget(next, "_record"))
    TestEnv.ReleaseSends(CommKit)
    assert.are.equal("sent", next:GetState())
    assert.are.same({ record }, records)
  end)

  it("keeps at most 64 finished records", function()
    CommKit:SetLimits({ maxQueuedMessages = 100 })
    TestEnv.HoldSends(CommKit)
    for index = 1, 80 do
      scope:Send({ prefix = PREFIX, text = "m" .. index, distribution = "PARTY" })
    end
    TestEnv.ReleaseSends(CommKit, 5)
    assert.are.same({ 0, 0 }, { CommKit:GetQueueDepth() })
    assert.are.equal(64, #state.spares.records)
  end)

  it("recycles the record of an abort", function()
    CommKit:SetLimits({ burst = 400, maxCps = 100 })
    local handle = scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
    assert.is_true(handle:Cancel())
    -- The message's record is back; the abort took another.
    assert.are.equal(1, #state.spares.records)
    TestEnv.Advance(30)
    assert.are.equal(2, #state.spares.records)
    assert.are.equal(0, (CommKit:GetQueueDepth()))
  end)
end)

-- Revision 10: a one-chunk message without callbacks, sent while nothing is
-- queued and no driver run is under way or due, goes to the client at once
-- without a record, a pipe or a driver run (`SendPath.sendAtOnce`). A refusal
-- or a raise makes no second attempt: the message is queued and set aside, or
-- completed as failed, as a driver run would.
describe("CommKit sends one chunk at once without a record", function()
  local CommKit, scope, state
  before_each(function()
    CommKit = TestEnv.NewPackage()
    state = CommKit._state
    scope = CommKit:CreateScope()
  end)
  after_each(TestEnv.Reset)

  ---A plain one-chunk request.
  ---@param text string?
  ---@return table
  local function plain(text)
    return { prefix = PREFIX, text = text or "hello", distribution = "PARTY" }
  end

  it("makes one client call and keeps no record, counting as the queued path does", function()
    local handle = scope:Send(plain())
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(1, #TestEnv.Chat().attempts)
    assert.are.equal(0, #state.spares.records)
    assert.are.same({ 0, 0 }, { CommKit:GetQueueDepth() })
    assert.is_false(state.driver.running)
    assert.is_false(state.driver.job)
    local statistics = CommKit:GetStatistics()
    assert.are.equal(1, statistics.messagesQueued)
    assert.are.equal(1, statistics.messagesSent)
    assert.are.equal(1, statistics.chunksSent)
    assert.are.equal(6, statistics.bytesSent)
  end)

  it("gives a send handle no _schema field, on either path", function()
    local atOnce = scope:Send(plain())
    TestEnv.HoldSends(CommKit)
    local queued = scope:Send(plain("queued"))
    assert.is_nil(rawget(atOnce, "_schema"))
    assert.is_nil(rawget(queued, "_schema"))
    assert.are.equal("queued", queued:GetState())
  end)

  it("keeps the record path for a message with callbacks", function()
    local completed = false
    local handle = scope:Send({
      prefix = PREFIX,
      text = "hello",
      distribution = "PARTY",
      onComplete = function()
        completed = true
      end,
    })
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(1, #state.spares.records)
    assert.is_false(completed)
    TestEnv.Tick()
    assert.is_true(completed)
  end)

  it("queues behind a message already queued and sends nothing itself", function()
    TestEnv.HoldSends(CommKit)
    local first = scope:Send(plain("first"))
    local second = scope:Send(plain("second"))
    assert.are.same({ "queued", "queued" }, { first:GetState(), second:GetState() })
    assert.are.equal(0, #TestEnv.Chat().attempts)
    TestEnv.ReleaseSends(CommKit)
    assert.are.same({ "sent", "sent" }, { first:GetState(), second:GetState() })
  end)

  it("makes one attempt when the client throttles it, then retries from the queue", function()
    TestEnv.QueueSendResults(TestEnv.SEND_RESULT.AddonMessageThrottle)
    local handle = scope:Send(plain())
    assert.are.equal("queued", handle:GetState())
    assert.are.equal(1, #TestEnv.Chat().attempts)
    assert.are.equal(1, CommKit:GetStatistics().throttled)
    TestEnv.Advance(1)
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(2, #TestEnv.Chat().attempts)
  end)

  it("fails once when the client refuses it, without a second attempt", function()
    TestEnv.QueueSendResults(TestEnv.SEND_RESULT.NotInGroup)
    local handle = scope:Send(plain())
    assert.are.equal("failed", handle:GetState())
    assert.are.equal(1, #TestEnv.Chat().attempts)
    TestEnv.Advance(1)
    assert.are.equal(1, #TestEnv.Chat().attempts)
    assert.are.equal(1, CommKit:GetStatistics().messagesFailed)
  end)

  it("fails once and reports once when the client's send raises", function()
    local calls = 0
    -- selene: allow(global_usage)
    rawset(rawget(_G, "C_ChatInfo"), "SendAddonMessage", function()
      calls = calls + 1
      error("client send raised")
    end)
    TestEnv.TakeReportedErrors()
    local handle = scope:Send(plain())
    assert.are.equal("failed", handle:GetState())
    assert.are.equal(1, calls)
    assert.are.equal(1, #TestEnv.TakeReportedErrors())
    TestEnv.Advance(1)
    assert.are.equal(1, calls)
  end)

  it("uses a C_ChatInfo send function another addon replaced since the last send", function()
    scope:Send(plain("before"))
    local replaced = 0
    -- selene: allow(global_usage)
    rawset(rawget(_G, "C_ChatInfo"), "SendAddonMessage", function()
      replaced = replaced + 1
      return TestEnv.SEND_RESULT.Success
    end)
    local handle = scope:Send(plain("after"))
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(1, replaced)
  end)

  it("refuses each forbidden byte at the first, middle and last position", function()
    for _, byte in ipairs({ "\0", "\n", "\r", "|" }) do
      for _, text in ipairs({ byte .. "ab", "a" .. byte .. "b", "ab" .. byte }) do
        local handle, reason = scope:Send(plain(text))
        assert.is_nil(handle)
        assert.are.equal("forbiddenByte", reason)
      end
    end
    local handle = scope:Send(plain(TestEnv.Text(254)))
    assert.are.equal("sent", handle:GetState())
    assert.are.equal(0, #state.spares.records)
  end)

  it("keeps the probe a copy resolved at load after the global goes away", function()
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return value == "\001secret"
    end)
    package.loaded["CommKit"] = nil
    local upgraded = TestEnv.LoadRevision(CommKit.REVISION + 1)
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    TestEnv.Deliver(PREFIX, "\001secret", "PARTY", "Friend-Realm")
    assert.are.same({}, received)
    assert.are.equal(1, upgraded:GetStatistics().secretsDropped)
  end)

  it("builds a reassembly key suffix only for a stream id it receives", function()
    -- The suffix tables are file-local; the upvalue walk finds them.
    local wire
    local queue, seen, head = { CommKit }, { [CommKit] = true }, 1
    while queue[head] ~= nil and wire == nil do
      local item = queue[head]
      head = head + 1
      local function visit(name, value)
        if name == "WIRE" and type(value) == "table" then
          wire = value
        elseif (type(value) == "function" or type(value) == "table") and not seen[value] then
          seen[value] = true
          queue[#queue + 1] = value
        end
      end
      if type(item) == "function" then
        local index = 1
        while true do
          local name, value = debug.getupvalue(item, index)
          if name == nil then
            break
          end
          visit(name, value)
          index = index + 1
        end
      else
        for key, value in next, item do
          visit(nil, key)
          visit(nil, value)
        end
      end
    end
    assert.is_table(wire)
    assert.is_nil(next(wire.plain.keySuffix))
    assert.is_nil(next(wire.logged.keySuffix))
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local text = TestEnv.Text(700)
    scope:Send(plain(text))
    TestEnv.Advance(10)
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ text }, received)
    local count = 0
    for _ in pairs(wire.plain.keySuffix) do
      count = count + 1
    end
    assert.are.equal(1, count)
    assert.is_nil(next(wire.logged.keySuffix))
  end)
end)
