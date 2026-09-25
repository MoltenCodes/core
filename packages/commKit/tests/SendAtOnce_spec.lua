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
