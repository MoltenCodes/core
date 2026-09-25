local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"
local SENDER = "Friend-Realm"
local THROTTLE = TestEnv.SEND_RESULT.AddonMessageThrottle

-- What revision 5 made cheaper, pinned to the behaviour it must keep: pipes
-- and per-sender records recycled through bounded free lists, one expiry
-- timer restarted instead of rebuilt, the frame-rate ticker started only by a
-- run that leaves work behind, precomputed reassembly keys, and the head
-- shortcuts of the queue and the stream list. See `docs/INTERNALS.md`.

---A chunk as the wire protocol writes it.
---@param control integer 2 first, 3 middle, 4 last
---@param stream integer
---@param number integer the total for a first chunk, the index otherwise
---@param payload string
---@param logged boolean? the logged channel's printable digits
---@return string
local function chunk(control, stream, number, payload, logged)
  local offset, radix = 0x80, 128
  if logged then
    offset, radix = 0x30, 75
  end
  local high = math.floor(number / radix)
  return string.char(control, offset + stream, offset + high, offset + number - high * radix)
    .. payload
end

---The two chunks of a 300-byte message `text` on stream `stream`.
---@param text string
---@param stream integer
---@param logged boolean?
---@return string first, string last
local function twoChunks(text, stream, logged)
  return chunk(0x02, stream, 2, text:sub(1, 251), logged),
    chunk(0x04, stream, 2, text:sub(252), logged)
end

---Native timers that repeat, armed or not: the frame-rate ticker is the only
---repeating timer CommKit makes.
---@return integer
local function repeatingTimers()
  local found = 0
  for _, native in ipairs(TestEnv.NativeTimers()) do
    if native.repeating then
      found = found + 1
    end
  end
  return found
end

describe("CommKit fast paths", function()
  local CommKit, scope, received, state
  before_each(function()
    CommKit = TestEnv.NewPackage()
    state = CommKit._state
    scope = CommKit:CreateScope()
    received = {}
    assert(scope:Register(PREFIX, function(_, text, _, sender)
      received[#received + 1] = { text = text, sender = sender }
    end))
  end)
  after_each(TestEnv.Reset)

  describe("pipes", function()
    it("reuses an emptied pipe for the next destination, reset like a new one", function()
      TestEnv.QueueSendResults(THROTTLE)
      local handle = scope:Send({
        prefix = PREFIX,
        text = "first",
        distribution = "WHISPER",
        target = "Alpha",
      })
      TestEnv.Advance(0)
      local pipe = state.queues.NORMAL.pipes["WHISPER\tAlpha"]
      assert.is_true(pipe.blocked)
      assert.is_true(pipe.backoff > 0.35)
      handle:Cancel()
      assert.are.same({ pipe }, state.spares.pipes)

      -- Held, so the pipe is still in use when inspected.
      TestEnv.HoldSends(CommKit)
      local next = scope:Send({
        prefix = PREFIX,
        text = "second",
        distribution = "WHISPER",
        target = "Beta",
      })
      assert.are.equal(pipe, state.queues.NORMAL.pipes["WHISPER\tBeta"])
      assert.is_nil(state.queues.NORMAL.pipes["WHISPER\tAlpha"])
      assert.are.same({}, state.spares.pipes)
      assert.are.same({
        key = "WHISPER\tBeta",
        priority = "NORMAL",
        blocked = false,
        blockedUntil = 0,
        backoff = 0.35,
      }, {
        key = pipe.key,
        priority = pipe.priority,
        blocked = pipe.blocked,
        blockedUntil = pipe.blockedUntil,
        backoff = pipe.backoff,
      })
      TestEnv.ReleaseSends(CommKit)
      assert.are.equal("sent", next:GetState())
      local outbox = TestEnv.TakeOutbox()
      assert.are.equal("Beta", outbox[#outbox].target)
    end)

    it("keeps at most 16 emptied pipes", function()
      -- Held, so the twenty pipes exist at once.
      TestEnv.HoldSends(CommKit)
      for index = 1, 20 do
        scope:Send({
          prefix = PREFIX,
          text = "hello",
          distribution = "WHISPER",
          target = "Player" .. index,
        })
      end
      TestEnv.ReleaseSends(CommKit)
      assert.are.equal(0, (CommKit:GetQueueDepth()))
      assert.are.equal(16, #state.spares.pipes)
      assert.are.equal(20, #TestEnv.TakeOutbox())
    end)

    it("keeps order inside a pipe when a message behind the head is cancelled", function()
      TestEnv.HoldSends(CommKit)
      local handles = {}
      for index = 1, 3 do
        handles[index] =
          scope:Send({ prefix = PREFIX, text = "m" .. index, distribution = "PARTY" })
      end
      handles[2]:Cancel()
      TestEnv.ReleaseSends(CommKit)
      local texts = {}
      for _, entry in ipairs(TestEnv.TakeOutbox()) do
        texts[#texts + 1] = entry.text
      end
      assert.are.same({ "\001m1", "\001m3" }, texts)
      assert.are.same(
        { "sent", "cancelled", "sent" },
        { handles[1]:GetState(), handles[2]:GetState(), handles[3]:GetState() }
      )
    end)
  end)

  describe("the frame-rate sampler", function()
    local calls, original
    before_each(function()
      calls = 0
      -- selene: allow(global_usage)
      original = rawget(_G, "GetFramerate")
      -- selene: allow(global_usage)
      rawset(_G, "GetFramerate", function()
        calls = calls + 1
        return original()
      end)
    end)

    it("samples once and starts no ticker for a message the first run sends", function()
      scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
      assert.are.equal(1, calls)
      assert.are.equal(3, #TestEnv.TakeOutbox())
      TestEnv.Advance(0)
      assert.are.equal(0, repeatingTimers())
      assert.is_false(state.driver.sampler)
      TestEnv.Advance(5)
      assert.are.equal(1, calls)
    end)

    it("starts the ticker when a run leaves work queued, and stops it when idle", function()
      CommKit:SetLimits({ burst = 300, maxCps = 100 })
      -- The run inside `Send` sends one chunk and leaves two queued.
      scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "PARTY" })
      assert.are.equal(1, repeatingTimers())
      TestEnv.Advance(0)
      assert.are.equal(1, repeatingTimers())
      assert.is_true(state.driver.sampler ~= false)
      TestEnv.Advance(2.5)
      assert.are.equal(3, calls)
      TestEnv.Advance(30)
      assert.are.equal(0, (CommKit:GetQueueDepth()))
      assert.is_false(state.driver.sampler)
    end)
  end)

  describe("reassembly", function()
    it("reuses per-sender records and keeps at most 16", function()
      local texts, lasts = {}, {}
      for index = 1, 20 do
        texts[index] = TestEnv.Text(300 + index)
        local first, last = twoChunks(texts[index], 1)
        TestEnv.Deliver(PREFIX, first, "PARTY", "Sender" .. index)
        lasts[index] = last
      end
      for index = 1, 20 do
        TestEnv.Deliver(PREFIX, lasts[index], "PARTY", "Sender" .. index)
      end
      assert.are.equal(20, #received)
      assert.are.equal(texts[20], received[20].text)
      assert.are.equal(16, #state.spares.senders)
      assert.is_nil(next(state.senders))

      -- A reused record starts from nothing: the new sender still gets its
      -- full four streams, and a fifth is refused as over quota.
      local spare = state.spares.senders[16]
      for stream = 1, 4 do
        TestEnv.Deliver(PREFIX, (twoChunks(TestEnv.Text(300), stream)), "PARTY", "Newcomer")
      end
      assert.are.equal(spare, state.senders.Newcomer)
      assert.are.same({ streams = 4, bytes = 4 * 252 }, state.senders.Newcomer)
      TestEnv.Deliver(PREFIX, (twoChunks(TestEnv.Text(300), 5)), "PARTY", "Newcomer")
      assert.are.equal(1, CommKit:GetStatistics().chunksRefusedQuota)
      assert.are.equal(4, CommKit:GetStatistics().openStreams)
    end)

    it("restarts one expiry timer for consecutive streams and still expires them", function()
      local text = TestEnv.Text(300)
      local first, last = twoChunks(text, 1)
      TestEnv.Deliver(PREFIX, first, "PARTY", SENDER)
      local timer = state.expiry.timer
      assert.are.equal(state.expiry.idleTimer, timer)
      TestEnv.Deliver(PREFIX, last, "PARTY", SENDER)
      assert.is_false(state.expiry.timer)
      assert.is_false(timer:IsPending())

      TestEnv.Deliver(PREFIX, first, "PARTY", SENDER)
      assert.are.equal(timer, state.expiry.timer)
      assert.is_true(timer:IsPending())
      TestEnv.Advance(29.9)
      assert.are.equal(1, CommKit:GetStatistics().openStreams)
      TestEnv.Advance(0.2)
      assert.are.equal(0, CommKit:GetStatistics().openStreams)
      assert.are.equal(1, CommKit:GetStatistics().streamsExpired)
      assert.are.equal(1, #received)
    end)

    it("replaces the expiry timer when the reassembly timeout changes", function()
      local first = twoChunks(TestEnv.Text(300), 1)
      TestEnv.Deliver(PREFIX, first, "PARTY", SENDER)
      local timer = state.expiry.idleTimer
      scope:UnregisterAll()
      assert(scope:Register(PREFIX, function() end))

      CommKit:SetLimits({ reassemblyTimeout = 10 })
      TestEnv.Deliver(PREFIX, first, "PARTY", SENDER)
      assert.are_not.equal(timer, state.expiry.idleTimer)
      assert.are.equal(10, state.expiry.idleTimer:GetDelay())
      TestEnv.Advance(9.9)
      assert.are.equal(1, CommKit:GetStatistics().openStreams)
      TestEnv.Advance(0.2)
      assert.are.equal(0, CommKit:GetStatistics().openStreams)
    end)

    it("reassembles on every stream id of both digit schemes", function()
      for stream = 0, 127 do
        local text = TestEnv.Text(300 + stream)
        local first, last = twoChunks(text, stream)
        TestEnv.Deliver(PREFIX, first, "PARTY", SENDER)
        TestEnv.Deliver(PREFIX, last, "PARTY", SENDER)
        assert.are.equal(text, received[#received].text)
      end
      for stream = 0, 74 do
        local text = TestEnv.Text(300 + stream)
        local first, last = twoChunks(text, stream, true)
        TestEnv.DeliverLogged(PREFIX, first, "GUILD", SENDER)
        TestEnv.DeliverLogged(PREFIX, last, "GUILD", SENDER)
        assert.are.equal(text, received[#received].text)
      end
      assert.are.equal(128 + 75, #received)
      assert.are.equal(0, CommKit:GetStatistics().chunksRefused)
    end)

    it("keeps one stream id apart on the two channels", function()
      local plainText, loggedText = TestEnv.Text(301), TestEnv.Text(302)
      local plainFirst, plainLast = twoChunks(plainText, 7)
      local loggedFirst, loggedLast = twoChunks(loggedText, 7, true)
      TestEnv.Deliver(PREFIX, plainFirst, "GUILD", SENDER)
      TestEnv.DeliverLogged(PREFIX, loggedFirst, "GUILD", SENDER)
      TestEnv.DeliverLogged(PREFIX, loggedLast, "GUILD", SENDER)
      TestEnv.Deliver(PREFIX, plainLast, "GUILD", SENDER)
      assert.are.same({ loggedText, plainText }, { received[1].text, received[2].text })
    end)

    it("completes a younger stream before an older one", function()
      local older, younger = TestEnv.Text(400), TestEnv.Text(500)
      local olderFirst, olderLast = twoChunks(older, 1)
      local youngerFirst, youngerLast = twoChunks(younger, 2)
      TestEnv.Deliver(PREFIX, olderFirst, "PARTY", SENDER)
      TestEnv.Deliver(PREFIX, youngerFirst, "PARTY", SENDER)
      TestEnv.Deliver(PREFIX, youngerLast, "PARTY", SENDER)
      assert.are.same({ younger }, { received[1].text })
      assert.are.equal(1, #state.streamList)
      TestEnv.Deliver(PREFIX, olderLast, "PARTY", SENDER)
      assert.are.equal(older, received[2].text)
      assert.are.equal(0, CommKit:GetStatistics().openStreams)
      assert.is_false(state.expiry.timer)
    end)
  end)
end)
