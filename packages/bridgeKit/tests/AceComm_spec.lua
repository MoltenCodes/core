-- BridgeKit's AceComm-3.0 channel against a CommKit stand-in with raw addon
-- messages (docs/BRIDGE_KIT_DESIGN.md, sections 5.7, 8.3, 8.4 and 13.1): the
-- send rules at their boundaries, the receive rules including replacement,
-- orphans and reserved controls, every bound and the drop report rate,
-- priority fixed per prefix, two channels on one prefix, closing with the
-- scope, and the statistics.
local Env = require("BridgeKitTestEnv")

local PREFIX = "AceTest"
local SENDER = "Peer-Realm"

describe("BridgeKit AceComm channel", function()
  local BridgeKit, commKit
  before_each(function()
    BridgeKit = Env.NewPackage()
    commKit = Env.InstallCommKitStandIn()
    Env.InstallHostErrorHandler()
  end)
  after_each(Env.Reset)

  ---Open a channel that records what it receives.
  local function openRecording(scope, options)
    local received = {}
    local channel = assert(
      BridgeKit:OpenAceComm(
        scope or commKit.NewScope(),
        PREFIX,
        function(prefix, message, distribution, sender)
          received[#received + 1] =
            { prefix = prefix, message = message, distribution = distribution, sender = sender }
        end,
        options
      )
    )
    return channel, received
  end

  ---The parts one Send produces.
  local function partsOf(channel, text)
    commKit.sent = {}
    assert(channel:Send({ text = text, distribution = "PARTY" }))
    return commKit.SentParts()
  end

  describe("sending", function()
    it("sends a short text as one message, unchanged", function()
      local channel = openRecording()
      assert.are.same({ "hello" }, partsOf(channel, "hello"))
      assert.are.same({ string.rep("x", 255) }, partsOf(channel, string.rep("x", 255)))
      assert.are.equal("NORMAL", commKit.sent[1].priority)
      assert.are.equal(PREFIX, commKit.sent[1].prefix)
    end)

    it("escapes a first byte 01 to 09 with 04 while it fits, and splits it otherwise", function()
      local channel = openRecording()
      local short = "\002" .. string.rep("x", 253)
      assert.are.same({ "\004" .. short }, partsOf(channel, short))
      local exact = "\001" .. string.rep("x", 254)
      local parts = partsOf(channel, exact)
      assert.are.equal(2, #parts)
      assert.are.equal("\001", parts[1]:sub(1, 1))
      assert.are.equal(exact, parts[1]:sub(2) .. parts[2]:sub(2))
    end)

    it("splits longer texts into 254-byte parts, the last holding the rest", function()
      local channel = openRecording()
      for _, length in ipairs({ 256, 254 * 2, 254 * 2 + 1, 254 * 3, 1000 }) do
        local text = string.rep("a", length)
        local parts = partsOf(channel, text)
        local joined = {}
        for index, part in ipairs(parts) do
          local control = part:byte(1)
          if index == 1 then
            assert.are.equal(1, control)
          elseif index == #parts then
            assert.are.equal(3, control)
          else
            assert.are.equal(2, control)
          end
          assert.is_true(#part <= 255)
          joined[#joined + 1] = part:sub(2)
        end
        assert.are.equal(text, table.concat(joined), "length " .. length)
        assert.are.equal(math.ceil(length / 254), #parts, "length " .. length)
      end
    end)

    it("refuses NUL, a closed channel and a text too long for one raw message", function()
      local channel = openRecording()
      assert.are.same(
        { nil, "nulByte" },
        { channel:Send({ text = "a\000b", distribution = "PARTY" }) }
      )
      assert.are.same(
        { nil, "tooLarge" },
        { channel:Send({ text = string.rep("x", 254 * 4097), distribution = "PARTY" }) }
      )
      channel:Close()
      assert.are.same({ nil, "closed" }, { channel:Send({ text = "x", distribution = "PARTY" }) })
    end)

    it("raises at the caller for a bad request, CommKit's own refusal included", function()
      local channel = openRecording()
      local cases = {
        { "x", "request must be a table" },
        { { text = "", distribution = "PARTY" }, "request.text must be a non-empty string" },
        { { text = "x", distribution = "PARTY", color = 1 }, "request has an unknown field" },
        {
          { text = "x", distribution = 5 },
          "BridgeKit channel:Send CommKit.Scope:SendRaw request.distribution must be a string",
        },
      }
      for _, case in ipairs(cases) do
        local ok, failure = pcall(channel.Send, channel, case[1])
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find(case[2], 1, true), case[2])
      end
      assert.is_false((pcall(channel.Send, {}, { text = "x" })))
    end)

    it("sends with the priority the channel was opened with", function()
      local channel = openRecording(nil, { priority = "BULK" })
      partsOf(channel, "x")
      assert.are.equal("BULK", commKit.sent[1].priority)
      assert.are.equal("BULK", channel:GetPriority())
      assert.are.equal(1, channel:GetWireVersion())
      assert.are.equal(PREFIX, channel:GetPrefix())
    end)
  end)

  describe("receiving", function()
    it("delivers a whole message, an escaped one, and a reassembled stream", function()
      local _, received = openRecording()
      commKit.Deliver(PREFIX, "plain", "WHISPER", SENDER)
      commKit.Deliver(PREFIX, "\004\002escaped", "WHISPER", SENDER)
      commKit.Deliver(PREFIX, "\001first ", "WHISPER", SENDER)
      commKit.Deliver(PREFIX, "\002middle ", "WHISPER", SENDER)
      commKit.Deliver(PREFIX, "\003last", "WHISPER", SENDER)
      assert.are.same({ "plain", "\002escaped", "first middle last" }, {
        received[1].message,
        received[2].message,
        received[3].message,
      })
      assert.are.same({ PREFIX, "WHISPER" }, { received[3].prefix, received[3].distribution })
    end)

    it("round-trips every send boundary through its own reassembly", function()
      local channel, received = openRecording()
      for _, text in ipairs({
        "x",
        string.rep("y", 255),
        "\001" .. string.rep("z", 300),
        string.rep("w", 254 * 3),
      }) do
        commKit.sent = {}
        channel:Send({ text = text, distribution = "PARTY" })
        for _, part in ipairs(commKit.SentParts()) do
          commKit.Deliver(PREFIX, part, "PARTY", SENDER)
        end
        assert.are.equal(text, received[#received].message)
      end
    end)

    it(
      "replaces a held stream on a new first part, and drops orphans and reserved controls",
      function()
        local _, received = openRecording()
        commKit.Deliver(PREFIX, "\001old", "PARTY", SENDER)
        commKit.Deliver(PREFIX, "\001new", "PARTY", SENDER)
        commKit.Deliver(PREFIX, "\003!", "PARTY", SENDER)
        commKit.Deliver(PREFIX, "\002orphan", "PARTY", "Other-Realm")
        commKit.Deliver(PREFIX, "\003orphan", "PARTY", "Other-Realm")
        commKit.Deliver(PREFIX, "\005reserved", "PARTY", SENDER)
        commKit.Deliver(PREFIX, "\009reserved", "PARTY", SENDER)
        assert.are.same({ "new!" }, { received[1].message })
        assert.are.equal(1, #received)
        local statistics = BridgeKit:GetStatistics()
        assert.are.same(
          { 1, 2, 2 },
          {
            statistics.aceStreamsReplaced,
            statistics.aceOrphanParts,
            statistics.aceReservedControl,
          }
        )
      end
    )

    it("keys streams by distribution and sender", function()
      local _, received = openRecording()
      commKit.Deliver(PREFIX, "\001a", "PARTY", SENDER)
      commKit.Deliver(PREFIX, "\001b", "RAID", SENDER)
      commKit.Deliver(PREFIX, "\001c", "PARTY", "Other-Realm")
      commKit.Deliver(PREFIX, "\003C", "PARTY", "Other-Realm")
      commKit.Deliver(PREFIX, "\003B", "RAID", SENDER)
      commKit.Deliver(PREFIX, "\003A", "PARTY", SENDER)
      assert.are.same(
        { "cC", "bB", "aA" },
        { received[1].message, received[2].message, received[3].message }
      )
    end)

    it("ambiguates the sender by default and keeps it when asked", function()
      -- selene: allow(global_usage)
      rawset(_G, "Ambiguate", function(name, context)
        assert.are.equal("none", context)
        return (name:gsub("%-.*$", ""))
      end)
      local _, short = openRecording()
      local _, full = openRecording(nil, { ambiguate = false })
      commKit.Deliver(PREFIX, "hi", "WHISPER", SENDER)
      assert.are.equal("Peer", short[1].sender)
      assert.are.equal(SENDER, full[1].sender)
    end)

    it("isolates a callback that raises and still calls the next channel", function()
      assert(BridgeKit:OpenAceComm(commKit.NewScope(), PREFIX, function()
        error("listener bug")
      end))
      local _, received = openRecording()
      commKit.Deliver(PREFIX, "hi", "WHISPER", SENDER)
      assert.are.equal(1, #received)
      assert.is_truthy(tostring(Env.ReportedErrors()[1]):find("listener bug", 1, true))
    end)
  end)

  describe("bounds", function()
    it("refuses a stream past maxAceStreamBytes and reports it", function()
      BridgeKit:SetLimits({ maxAceStreamBytes = 10 })
      local _, received = openRecording()
      commKit.Deliver(PREFIX, "\001123456", "PARTY", SENDER)
      commKit.Deliver(PREFIX, "\0027890ab", "PARTY", SENDER)
      commKit.Deliver(PREFIX, "\003c", "PARTY", SENDER)
      assert.are.equal(0, #received)
      local statistics = BridgeKit:GetStatistics()
      assert.are.same({ 1, 1 }, { statistics.aceStreamsOversize, statistics.aceOrphanParts })
      assert.is_truthy(tostring(Env.ReportedErrors()[1]):find("oversize", 1, true))
      commKit.Deliver(PREFIX, "\001" .. string.rep("x", 11), "PARTY", SENDER)
      assert.are.equal(2, BridgeKit:GetStatistics().aceStreamsOversize)
    end)

    it("refuses streams past maxAceStreams, per sender and past the spool", function()
      BridgeKit:SetLimits({ maxAceStreams = 2, maxAceStreamsPerSender = 1 })
      openRecording()
      commKit.Deliver(PREFIX, "\001a", "PARTY", SENDER)
      commKit.Deliver(PREFIX, "\001b", "RAID", SENDER)
      commKit.Deliver(PREFIX, "\001c", "PARTY", "Two-Realm")
      commKit.Deliver(PREFIX, "\001d", "PARTY", "Three-Realm")
      local statistics = BridgeKit:GetStatistics()
      assert.are.same({ 2, 2 }, { statistics.aceStreamsRefusedQuota, statistics.openStreams })
      BridgeKit:SetLimits({ maxAceStreams = 64, maxAceStreamsPerSender = 4, maxAceSpoolBytes = 3 })
      commKit.Deliver(PREFIX, "\002xy", "PARTY", SENDER)
      assert.are.equal(3, BridgeKit:GetStatistics().aceStreamsRefusedQuota)
    end)

    it("expires a stream whose last part is older than aceStreamTimeout", function()
      BridgeKit:SetLimits({ aceStreamTimeout = 5 })
      local _, received = openRecording()
      commKit.Deliver(PREFIX, "\001stale", "PARTY", SENDER)
      Env.AdvanceMs(6000)
      commKit.Deliver(PREFIX, "\003end", "PARTY", SENDER)
      assert.are.equal(0, #received)
      local statistics = BridgeKit:GetStatistics()
      assert.are.same(
        { 1, 1, 0 },
        { statistics.aceStreamsExpired, statistics.aceOrphanParts, statistics.openStreams }
      )
    end)

    it("reports drops at most once per sender per minute", function()
      BridgeKit:SetLimits({ maxAceStreamBytes = 1 })
      openRecording()
      for _ = 1, 5 do
        commKit.Deliver(PREFIX, "\001xx", "PARTY", SENDER)
      end
      assert.are.equal(1, #Env.ReportedErrors())
      Env.AdvanceMs(61000)
      commKit.Deliver(PREFIX, "\001xx", "PARTY", SENDER)
      assert.are.equal(2, #Env.ReportedErrors())
    end)

    it("lets past maxDropReportSenders senders share one report", function()
      BridgeKit:SetLimits({ maxAceStreamBytes = 1, maxDropReportSenders = 1 })
      openRecording()
      commKit.Deliver(PREFIX, "\001xx", "PARTY", "One-Realm")
      commKit.Deliver(PREFIX, "\001xx", "PARTY", "Two-Realm")
      commKit.Deliver(PREFIX, "\001xx", "PARTY", "Three-Realm")
      local reports = Env.ReportedErrors()
      assert.are.equal(2, #reports)
      assert.is_truthy(tostring(reports[2]):find("several senders", 1, true))
    end)
  end)

  describe("channels and prefixes", function()
    it("delivers each message once to every channel on a prefix, in the order opened", function()
      local order = {}
      for index = 1, 3 do
        assert(BridgeKit:OpenAceComm(commKit.NewScope(), PREFIX, function(_, message)
          order[#order + 1] = index .. message
        end))
      end
      commKit.Deliver(PREFIX, "\001a", "PARTY", SENDER)
      commKit.Deliver(PREFIX, "\003b", "PARTY", SENDER)
      assert.are.same({ "1ab", "2ab", "3ab" }, order)
      assert.are.equal(1, BridgeKit:GetStatistics().aceStreamsCompleted)
    end)

    it(
      "keeps reassembling when the first channel closes, and forgets the prefix with the last",
      function()
        local first, firstReceived = openRecording()
        local _, secondReceived = openRecording()
        commKit.Deliver(PREFIX, "\001a", "PARTY", SENDER)
        first:Close()
        assert.is_true(first:IsClosed())
        assert.is_false(first:Close())
        commKit.Deliver(PREFIX, "\003b", "PARTY", SENDER)
        assert.are.equal(0, #firstReceived)
        assert.are.same({ "ab" }, { secondReceived[1].message })
      end
    )

    it("fixes the priority per prefix while a channel is open on it", function()
      local channel = openRecording(nil, { priority = "ALERT" })
      local ok, failure = pcall(
        BridgeKit.OpenAceComm,
        BridgeKit,
        commKit.NewScope(),
        PREFIX,
        function() end,
        { priority = "BULK" }
      )
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          'options.priority "BULK" differs from "ALERT", which the first channel on prefix "AceTest" set',
          1,
          true
        )
      )
      channel:Close()
      assert.is_not_nil(
        BridgeKit:OpenAceComm(commKit.NewScope(), PREFIX, function() end, { priority = "BULK" })
      )
    end)

    it("closes with its CommKit scope", function()
      local scope = commKit.NewScope()
      local channel, received = openRecording(scope)
      scope:Close()
      assert.is_true(channel:IsClosed())
      commKit.Deliver(PREFIX, "hi", "PARTY", SENDER)
      assert.are.equal(0, #received)
      assert.are.same({ nil, "closed" }, { channel:Send({ text = "x", distribution = "PARTY" }) })
    end)

    it("passes CommKit's registration refusal on", function()
      local scope = commKit.NewScope()
      scope:Close()
      assert.are.same({ nil, "closed" }, { BridgeKit:OpenAceComm(scope, PREFIX, function() end) })
    end)
  end)

  describe("opening", function()
    it("raises at the caller for bad arguments and options", function()
      local scope = commKit.NewScope()
      local cases = {
        { { {}, PREFIX, print }, "scope must be a CommKit scope" },
        { { scope, "", print }, "prefix must be a string of 1 to 16 bytes" },
        { { scope, string.rep("p", 17), print }, "prefix must be a string of 1 to 16 bytes" },
        { { scope, PREFIX, "x" }, "callback must be a function" },
        { { scope, PREFIX, print, "x" }, "options must be a table or nil" },
        { { scope, PREFIX, print, { color = 1 } }, "options has no field named color" },
        {
          { scope, PREFIX, print, { priority = "URGENT" } },
          'options.priority must be "ALERT", "NORMAL" or "BULK"',
        },
        {
          { scope, PREFIX, print, { wire = 2 } },
          "options.wire must be a wire version this revision speaks: 1",
        },
        { { scope, PREFIX, print, { ambiguate = "yes" } }, "options.ambiguate must be a boolean" },
      }
      for _, case in ipairs(cases) do
        local ok, failure = pcall(BridgeKit.OpenAceComm, BridgeKit, unpack(case[1]))
        assert.is_false(ok)
        assert.is_truthy(
          tostring(failure):find(case[2], 1, true),
          case[2] .. " in " .. tostring(failure)
        )
      end
    end)

    it("needs CommKit with raw addon messages", function()
      Env.Reset()
      local Plain = Env.NewPackage()
      local ok, failure = pcall(Plain.OpenAceComm, Plain, {}, PREFIX, print)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          "requires CommKit API 1 with raw addon messages (RegisterRaw, SendRaw)",
          1,
          true
        )
      )
    end)

    it("counts what it sends and receives", function()
      local channel = openRecording()
      channel:Send({ text = string.rep("x", 600), distribution = "PARTY" })
      commKit.Deliver(PREFIX, "hello", "PARTY", SENDER)
      local statistics = BridgeKit:GetStatistics()
      assert.are.same({ 1, 3, 1, 5 }, {
        statistics.aceMessagesSent,
        statistics.acePartsSent,
        statistics.aceMessagesReceived,
        statistics.aceBytesReceived,
      })
      assert.are_not.equal(statistics, BridgeKit:GetStatistics())
    end)
  end)
end)
