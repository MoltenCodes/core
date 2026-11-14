-- Raw addon messages (revision 8): `scope:RegisterRaw` and `scope:SendRaw`,
-- the CommKit side of bridgeKit's prerequisite P1
-- (docs/BRIDGE_KIT_DESIGN.md, section 4.3). A raw message travels exactly as
-- written, through CommKit's queue, bucket and send states, with no framing.
local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKRaw"
local SENDER = "Peer-Realm"

---The texts of the addon messages that left, in order.
---@return string[]
local function sentTexts()
  local texts = {}
  for index, entry in ipairs(TestEnv.TakeOutbox()) do
    texts[index] = entry.text
  end
  return texts
end

---Call `fn` and return the error it raised, without the position prefix.
---@param fn function
---@return string
local function failureOf(fn)
  local ok, failure = pcall(fn)
  assert.is_false(ok)
  return (tostring(failure):gsub("^[^:]+:%d+: ", ""))
end

describe("CommKit raw messages", function()
  local CommKit, scope
  before_each(function()
    CommKit = TestEnv.NewPackage()
    scope = CommKit:CreateScope()
  end)
  after_each(TestEnv.Reset)

  describe("receiving with RegisterRaw", function()
    it("delivers every addon message on the prefix as it arrived", function()
      local received = {}
      assert(scope:RegisterRaw(PREFIX, function(prefix, text, distribution, sender)
        received[#received + 1] = { prefix, text, distribution, sender }
      end))
      -- AceComm's control bytes and CommKit's own are ordinary text here.
      TestEnv.Deliver(PREFIX, "\001start", "PARTY", SENDER)
      TestEnv.Deliver(PREFIX, "\005abort-looking", "RAID", SENDER)
      TestEnv.Deliver(PREFIX, "plain", "WHISPER", SENDER)

      assert.are.same({
        { PREFIX, "\001start", "PARTY", SENDER },
        { PREFIX, "\005abort-looking", "RAID", SENDER },
        { PREFIX, "plain", "WHISPER", SENDER },
      }, received)
      local statistics = CommKit:GetStatistics()
      assert.are.equal(3, statistics.chunksReceived)
      assert.are.equal(3, statistics.messagesReceived)
      assert.are.equal(0, statistics.chunksRefused)
      assert.are.equal(0, statistics.streamsOpened)
    end)

    it("isolates a callback that raises and still calls the next one", function()
      local reached = false
      assert(scope:RegisterRaw(PREFIX, function()
        error("listener failure")
      end))
      assert(scope:RegisterRaw(PREFIX, function()
        reached = true
      end))
      TestEnv.Deliver(PREFIX, "text", "PARTY", SENDER)
      assert.is_true(reached)
    end)

    it("refuses a framed registration on a raw prefix, and the reverse", function()
      assert(scope:RegisterRaw(PREFIX, function() end))
      assert.are.same({ nil, "framingConflict" }, { scope:Register(PREFIX, function() end) })

      local other = "CKFramed"
      assert(scope:Register(other, function() end))
      assert.are.same({ nil, "framingConflict" }, { scope:RegisterRaw(other, function() end) })
    end)

    it("refuses a SyncSet on a raw prefix", function()
      assert(scope:RegisterRaw(PREFIX, function() end))
      local syncSet, reason = scope:SyncSet(PREFIX, { fields = { "a" } })
      assert.is_nil(syncSet)
      assert.are.equal("framingConflict", reason)
    end)

    it("frees the prefix for the other framing once its last registration ends", function()
      local connection = assert(scope:RegisterRaw(PREFIX, function() end))
      assert.is_true(connection:Disconnect())
      local framed = {}
      assert(scope:Register(PREFIX, function(_, text)
        framed[#framed + 1] = text
      end))
      TestEnv.Deliver(PREFIX, "\001whole", "PARTY", SENDER)
      assert.are.same({ "whole" }, framed)
    end)

    it("keeps the framing while another scope still holds a registration", function()
      local other = CommKit:CreateScope()
      assert(other:RegisterRaw(PREFIX, function() end))
      local connection = assert(scope:RegisterRaw(PREFIX, function() end))
      connection:Disconnect()
      assert.are.same({ nil, "framingConflict" }, { scope:Register(PREFIX, function() end) })
    end)

    it("drops a message with a secret argument and counts it", function()
      local secret = "secret text"
      local delivered = false
      -- selene: allow(global_usage)
      rawset(_G, "issecretvalue", function(value)
        return value == secret
      end)
      assert(scope:RegisterRaw(PREFIX, function()
        delivered = true
      end))
      TestEnv.Deliver(PREFIX, secret, "PARTY", SENDER)
      assert.is_false(delivered)
      assert.are.equal(1, CommKit:GetStatistics().secretsDropped)
    end)

    it("checks its arguments like Register", function()
      assert.are.equal(
        "CommKit.Scope:RegisterRaw prefix must be a string of 1 to 16 bytes",
        failureOf(function()
          scope:RegisterRaw("", function() end)
        end)
      )
      assert.are.equal(
        "CommKit.Scope:RegisterRaw callback must be a function",
        failureOf(function()
          scope:RegisterRaw(PREFIX, "not a function")
        end)
      )
    end)

    it("refuses on a closed scope", function()
      scope:Close()
      assert.are.same({ nil, "closed" }, { scope:RegisterRaw(PREFIX, function() end) })
    end)
  end)

  describe("sending with SendRaw", function()
    it("sends each part as one addon message, as written and in order", function()
      local parts = { "\001first", "\002middle", "\003last" }
      local handle =
        assert(scope:SendRaw({ prefix = PREFIX, parts = parts, distribution = "PARTY" }))
      TestEnv.Advance(0)
      assert.are.equal("sent", handle:GetState())
      assert.are.same(parts, sentTexts())
      assert.are.equal(#"\001first" + #"\002middle" + #"\003last", handle:GetBytesTotal())
      assert.are.equal(handle:GetBytesTotal(), handle:GetBytesSent())
      local statistics = CommKit:GetStatistics()
      assert.are.equal(1, statistics.messagesQueued)
      assert.are.equal(1, statistics.messagesSent)
      assert.are.equal(3, statistics.chunksSent)
    end)

    it("sends a 255-byte part unchanged", function()
      local part = TestEnv.Text(255)
      assert(scope:SendRaw({ prefix = PREFIX, parts = { part }, distribution = "GUILD" }))
      TestEnv.Advance(0)
      assert.are.same({ part }, sentTexts())
    end)

    it("addresses a whisper to its target", function()
      assert(scope:SendRaw({
        prefix = PREFIX,
        parts = { "hello" },
        distribution = "WHISPER",
        target = SENDER,
      }))
      TestEnv.Advance(0)
      local outbox = TestEnv.TakeOutbox()
      assert.are.equal(SENDER, outbox[1].target)
      assert.are.equal("WHISPER", outbox[1].distribution)
      assert.is_false(outbox[1].logged)
    end)

    it("copies the parts, so the caller may reuse the array", function()
      local parts = { "one", "two" }
      TestEnv.HoldSends(CommKit)
      assert(scope:SendRaw({ prefix = PREFIX, parts = parts, distribution = "PARTY" }))
      parts[1], parts[2] = "changed", "changed"
      TestEnv.ReleaseSends(CommKit)
      assert.are.same({ "one", "two" }, sentTexts())
    end)

    it("reports progress per part and completion once, after SendRaw returns", function()
      local calls = {}
      local returned = false
      local handle = assert(scope:SendRaw({
        prefix = PREFIX,
        parts = { "aa", "bbb" },
        distribution = "PARTY",
        onProgress = function(_, sent, total)
          calls[#calls + 1] = { "progress", sent, total, returned }
        end,
        onComplete = function(_, finalState, reason)
          calls[#calls + 1] = { "complete", finalState, reason, returned }
        end,
      }))
      returned = true
      assert.are.equal("sent", handle:GetState())
      TestEnv.Advance(0)
      assert.are.same({
        { "progress", 2, 5, true },
        { "progress", 5, 5, true },
        { "complete", "sent", nil, true },
      }, calls)
    end)

    it("keeps another message to the same destination out from between its parts", function()
      TestEnv.HoldSends(CommKit)
      assert(
        scope:SendRaw({ prefix = PREFIX, parts = { "r1", "r2", "r3" }, distribution = "PARTY" })
      )
      assert(scope:Send({ prefix = PREFIX, text = "framed", distribution = "PARTY" }))
      TestEnv.ReleaseSends(CommKit)
      assert.are.same({ "r1", "r2", "r3", "\001framed" }, sentTexts())
    end)

    it("stops the remaining parts when cancelled and sends no abort", function()
      CommKit:SetLimits({ burst = 255, maxCps = 1 })
      local completed
      local handle = assert(scope:SendRaw({
        prefix = PREFIX,
        parts = { TestEnv.Text(200), TestEnv.Text(200), TestEnv.Text(200) },
        distribution = "PARTY",
        onComplete = function(_, finalState, reason)
          completed = { finalState, reason }
        end,
      }))
      assert.are.equal("sending", handle:GetState())
      local before = #TestEnv.Chat().outbox
      assert.is_true(handle:Cancel())
      assert.are.equal("cancelled", handle:GetState())
      assert.are.same({ "cancelled", "cancelled" }, completed)
      TestEnv.Advance(60)
      assert.are.equal(before, #TestEnv.Chat().outbox)
      assert.are.equal(0, CommKit:GetQueueDepth())
      assert.are.equal(0, rawget(CommKit, "_state").inFlightStreams)
    end)

    it("takes no in-flight stream allowance while its parts are sending", function()
      CommKit:SetLimits({ maxInFlightPerSender = 1, burst = 300, maxCps = 1 })
      -- A raw message of several parts starts and waits for the bucket ...
      local raw = assert(scope:SendRaw({
        prefix = PREFIX,
        parts = { TestEnv.Text(200), TestEnv.Text(200) },
        distribution = "PARTY",
      }))
      assert.are.equal("sending", raw:GetState())
      assert.are.equal(0, rawget(CommKit, "_state").inFlightStreams)
      -- ... and a framed multi-chunk message to another destination may
      -- still start when the bucket allows it.
      local framed =
        assert(scope:Send({ prefix = PREFIX, text = TestEnv.Text(600), distribution = "GUILD" }))
      CommKit:SetLimits({ burst = 4000, maxCps = 800 })
      TestEnv.ReleaseSends(CommKit, 600)
      assert.are.equal("sent", raw:GetState())
      assert.are.equal("sent", framed:GetState())
    end)

    describe("refusals", function()
      it("refuses a part holding NUL and counts it", function()
        assert.are.same({ nil, "nulByte" }, {
          scope:SendRaw({
            prefix = PREFIX,
            parts = { "ok", "bad\000byte" },
            distribution = "PARTY",
          }),
        })
        assert.are.equal(1, CommKit:GetStatistics().refusedNulByte)
        assert.are.equal(0, CommKit:GetQueueDepth())
      end)

      it("accepts the bytes Send refuses, other than NUL", function()
        assert(scope:SendRaw({ prefix = PREFIX, parts = { "a|b\nc\rd" }, distribution = "PARTY" }))
        TestEnv.Advance(0)
        assert.are.same({ "a|b\nc\rd" }, sentTexts())
      end)

      it("refuses an unknown distribution and a whisper without a target", function()
        assert.are.same(
          { nil, "badDistribution" },
          { scope:SendRaw({ prefix = PREFIX, parts = { "x" }, distribution = "NOWHERE" }) }
        )
        assert.are.same(
          { nil, "badDistribution" },
          { scope:SendRaw({ prefix = PREFIX, parts = { "x" }, distribution = "WHISPER" }) }
        )
      end)

      it("refuses a message larger than the queue and one the queue has no room for", function()
        CommKit:SetLimits({ maxQueuedBytes = 300 })
        assert.are.same({ nil, "tooLarge" }, {
          scope:SendRaw({
            prefix = PREFIX,
            parts = { TestEnv.Text(200), TestEnv.Text(200) },
            distribution = "PARTY",
          }),
        })
        TestEnv.HoldSends(CommKit)
        assert(
          scope:SendRaw({ prefix = PREFIX, parts = { TestEnv.Text(200) }, distribution = "PARTY" })
        )
        assert.are.same({ nil, "queueFull" }, {
          scope:SendRaw({
            prefix = PREFIX,
            parts = { TestEnv.Text(200) },
            distribution = "PARTY",
          }),
        })
      end)

      it("refuses on a closed scope", function()
        scope:Close()
        assert.are.same(
          { nil, "closed" },
          { scope:SendRaw({ prefix = PREFIX, parts = { "x" }, distribution = "PARTY" }) }
        )
      end)
    end)

    describe("argument errors", function()
      local function sendRaw(request)
        return failureOf(function()
          scope:SendRaw(request)
        end)
      end

      it("raises for a request that is not a table or has an unknown field", function()
        assert.are.equal("CommKit.Scope:SendRaw request must be a table", sendRaw("request"))
        assert.is_truthy(sendRaw({
          prefix = PREFIX,
          parts = { "x" },
          distribution = "PARTY",
          constraints = { logged = true },
        }):find("constraints", 1, true))
      end)

      it("raises for parts that are not 1 to 4096 strings of 1 to 255 bytes", function()
        local base = { prefix = PREFIX, distribution = "PARTY" }
        local function with(parts)
          return { prefix = base.prefix, distribution = base.distribution, parts = parts }
        end
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts must be an array of strings",
          sendRaw(with("x"))
        )
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts must hold 1 to 4096 strings",
          sendRaw(with({}))
        )
        local many = {}
        for index = 1, 4097 do
          many[index] = "x"
        end
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts must hold 1 to 4096 strings",
          sendRaw(with(many))
        )
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts[2] must be a string",
          sendRaw(with({ "x", 5 }))
        )
        local holed = { "a" }
        holed[3] = "c"
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts must be an array of strings",
          sendRaw(with(holed))
        )
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts must be an array of strings",
          sendRaw(with({ "a", label = "b" }))
        )
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts[1] must be 1 to 255 bytes",
          sendRaw(with({ "" }))
        )
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts[1] must be 1 to 255 bytes",
          sendRaw(with({ TestEnv.Text(256) }))
        )
      end)

      it("raises for a secret part", function()
        local secret = "secret part"
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
          return value == secret
        end)
        assert.are.equal(
          "CommKit.Scope:SendRaw request.parts[1] must not be a secret value",
          sendRaw({ prefix = PREFIX, parts = { secret }, distribution = "PARTY" })
        )
      end)

      it("raises for an unknown priority", function()
        assert.are.equal(
          "CommKit.Scope:SendRaw request.priority must be CommKit.Priority.ALERT, NORMAL or BULK",
          sendRaw({ prefix = PREFIX, parts = { "x" }, distribution = "PARTY", priority = "URGENT" })
        )
      end)
    end)
  end)
end)
