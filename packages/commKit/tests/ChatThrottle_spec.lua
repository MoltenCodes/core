local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKBnet"
local ACCOUNT = 4242

---Write a host global, as the client defines them.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

describe("CommKit ChatThrottle part", function()
  local CommKit, scope
  before_each(function()
    CommKit = TestEnv.Load()
    scope = CommKit:CreateScope()
  end)
  after_each(TestEnv.Reset)

  describe("bootstrap", function()
    it("is installed by the default chain", function()
      assert.is_true(CommKit:HasPart("ChatThrottle"))
      assert.are.equal(1, CommKit._state.parts.ChatThrottle.revision)
    end)

    it("requires its core", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local ok, failure = pcall(require, "CommKit-ChatThrottle")
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          "MoltenCodes CommKit part ChatThrottle requires CommKit API 1 to be loaded first",
          1,
          true
        )
      )
    end)

    it("upgrades in place over a lower revision, keeping Battle.net registrations", function()
      local received = {}
      scope:RegisterBattleNet(PREFIX, function(_, text)
        received[#received + 1] = text
      end)
      CommKit._state.parts.ChatThrottle.revision = 0
      package.loaded["CommKit-ChatThrottle"] = nil
      require("CommKit-ChatThrottle")
      assert.are.equal(1, CommKit._state.parts.ChatThrottle.revision)
      TestEnv.DeliverBattleNet(PREFIX, "\001hello", ACCOUNT)
      assert.are.same({ "hello" }, received)
    end)

    it("returns without changes when an equal revision is installed", function()
      local before = CommKit.Scope.SendChat
      package.loaded["CommKit-ChatThrottle"] = nil
      assert.are.equal(CommKit, require("CommKit-ChatThrottle"))
      assert.are.equal(before, CommKit.Scope.SendChat)
    end)
  end)

  describe("without the part", function()
    before_each(function()
      CommKit = TestEnv.Load({ chatThrottle = false })
      scope = CommKit:CreateScope()
    end)

    it("raises at the caller's line with the file to embed", function()
      for _, name in ipairs({ "SendChat", "SendBattleNet", "RegisterBattleNet" }) do
        local ok, failure = pcall(function()
          scope[name](scope, {})
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("ChatThrottle_spec%.lua:%d+: "), name)
        assert.is_truthy(
          tostring(failure):find(
            "CommKit.Scope:"
              .. name
              .. " is in CommKit's ChatThrottle part, which is not loaded: add commKit\\parts\\CommKit-ChatThrottle.lua",
            1,
            true
          ),
          name
        )
      end
      assert.is_false(CommKit:HasPart("ChatThrottle"))
    end)

    it("answers a closed scope with nil and closed", function()
      scope:Close()
      assert.are.same({ nil, "closed" }, { scope:SendChat({ text = "x", chatType = "GUILD" }) })
    end)
  end)

  describe("SendChat", function()
    it("queues an ordinary chat type through the bucket and sends it", function()
      local handle = assert(scope:SendChat({ text = "hello guild", chatType = "GUILD" }))
      TestEnv.Advance(0)
      assert.are.equal("sent", handle:GetState())
      local lines = TestEnv.TakeChatOutbox()
      assert.are.same(
        { { text = "hello guild", distribution = "GUILD", language = nil, target = nil } },
        lines
      )
      assert.are.equal(0, #TestEnv.TakeOutbox())
    end)

    it("waits for the bucket and shares the rotation with addon messages", function()
      TestEnv.HoldSends(CommKit)
      local chatHandle =
        assert(scope:SendChat({ text = "line", chatType = "PARTY", languageID = 7 }))
      local addonHandle =
        assert(scope:Send({ prefix = "CKChat", text = "data", distribution = "PARTY" }))
      assert.are.equal("queued", chatHandle:GetState())
      local messages = CommKit:GetQueueDepth()
      assert.are.equal(2, messages)
      TestEnv.ReleaseSends(CommKit)
      assert.are.equal("sent", chatHandle:GetState())
      assert.are.equal("sent", addonHandle:GetState())
      assert.are.equal(7, TestEnv.TakeChatOutbox()[1].language)
      assert.are.equal(1, #TestEnv.TakeOutbox())
    end)

    it("addresses a whisper to its target and refuses one without", function()
      assert(scope:SendChat({ text = "psst", chatType = "WHISPER", target = "Friend-Realm" }))
      TestEnv.Advance(0)
      assert.are.equal("Friend-Realm", TestEnv.TakeChatOutbox()[1].target)
      assert.are.same(
        { nil, "badDistribution" },
        { scope:SendChat({ text = "psst", chatType = "WHISPER" }) }
      )
    end)

    it("sends SAY, YELL and CHANNEL inside the call, never queued", function()
      for _, chatType in ipairs({ "SAY", "YELL", "CHANNEL" }) do
        local target = chatType == "CHANNEL" and 2 or nil
        local handle =
          assert(scope:SendChat({ text = chatType, chatType = chatType, target = target }))
        assert.are.equal("sent", handle:GetState())
        assert.are.equal(chatType, TestEnv.TakeChatOutbox()[1].text)
      end
      assert.are.equal(0, CommKit:GetQueueDepth())
    end)

    it("refuses SAY with hardwareEvent when the bucket cannot pay now", function()
      TestEnv.HoldSends(CommKit)
      assert.are.same(
        { nil, "hardwareEvent" },
        { scope:SendChat({ text = "hi", chatType = "say" }) }
      )
      assert.are.equal(0, CommKit:GetQueueDepth())
      TestEnv.Advance(10)
      assert.are.same({}, TestEnv.TakeChatOutbox())
    end)

    it("charges a SAY line to the bucket", function()
      local before = CommKit:GetBudget()
      scope:SendChat({ text = TestEnv.Text(100), chatType = "SAY" })
      assert.are.equal(before - 140, (CommKit:GetBudget()))
    end)

    it("calls a SAY line's completion back after the call returns", function()
      local calls = {}
      local returned = false
      scope:SendChat({
        text = "hi",
        chatType = "SAY",
        onComplete = function(_, completed)
          assert.is_true(returned)
          calls[#calls + 1] = completed
        end,
      })
      returned = true
      assert.are.same({}, calls)
      TestEnv.Advance(0)
      assert.are.same({ "sent" }, calls)
    end)

    it("fails a SAY line the client raises on, and reports it", function()
      TestEnv.TakeReportedErrors()
      -- selene: allow(global_usage)
      local chatInfo = rawget(_G, "C_ChatInfo")
      setGlobal(
        "C_ChatInfo",
        setmetatable({
          SendChatMessage = function()
            error("refused", 0)
          end,
        }, { __index = chatInfo })
      )
      local handle = assert(scope:SendChat({ text = "hi", chatType = "SAY" }))
      assert.are.equal("failed", handle:GetState())
      assert.are.same({ { value = "refused" } }, TestEnv.TakeReportedErrors())
    end)

    it("refuses what it can never send", function()
      assert.are.same(
        { nil, "tooLarge" },
        { scope:SendChat({ text = TestEnv.Text(256), chatType = "GUILD" }) }
      )
      assert.are.same({ nil, "nulByte" }, { scope:SendChat({ text = "a\0b", chatType = "GUILD" }) })
      scope:Close()
      assert.are.same({ nil, "closed" }, { scope:SendChat({ text = "x", chatType = "GUILD" }) })
    end)

    it("refuses with unavailable on a client without SendChatMessage", function()
      setGlobal("C_ChatInfo", {})
      assert.are.same(
        { nil, "unavailable" },
        { scope:SendChat({ text = "x", chatType = "GUILD" }) }
      )
    end)

    it("raises at the caller for a malformed request or a secret", function()
      local function failureOf(request)
        local ok, failure = pcall(function()
          scope:SendChat(request)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("ChatThrottle_spec%.lua:%d+: "))
        return tostring(failure)
      end
      assert.is_truthy(failureOf(nil):find("request must be a table", 1, true))
      assert.is_truthy(
        failureOf({ text = 1, chatType = "SAY" }):find(".text must be a string", 1, true)
      )
      assert.is_truthy(
        failureOf({ text = "x" }):find(".chatType must be a non-empty string", 1, true)
      )
      assert.is_truthy(
        failureOf({ text = "x", chatType = "SAY", bogus = true }):find(
          'unknown field "bogus"',
          1,
          true
        )
      )
      assert.is_truthy(
        failureOf({ text = "x", chatType = "SAY", priority = "LOUD" }):find(
          ".priority must be",
          1,
          true
        )
      )
      setGlobal("issecretvalue", function(value)
        return value == "secret"
      end)
      assert.is_truthy(
        failureOf({ text = "secret", chatType = "SAY" }):find(
          ".text must not be a secret value",
          1,
          true
        )
      )
      setGlobal("issecretvalue", nil)
    end)

    it("is not charged twice by CommKit's own chat hook, and charges foreign chat", function()
      CommKit = TestEnv.Load({ hookKit = true })
      scope = CommKit:CreateScope()
      scope:SendChat({ text = "mine", chatType = "SAY" })
      assert.are.equal(0, CommKit:GetStatistics().outsideMessages)
      -- selene: allow(global_usage)
      _G.C_ChatInfo.SendChatMessage("theirs", "GUILD")
      assert.are.equal(1, CommKit:GetStatistics().outsideMessages)
    end)
  end)

  describe("Battle.net", function()
    it("sends a one-chunk message to a game account", function()
      local handle =
        assert(scope:SendBattleNet({ prefix = PREFIX, text = "hi", gameAccountID = ACCOUNT }))
      TestEnv.Advance(0)
      assert.are.equal("sent", handle:GetState())
      assert.are.same(
        { { gameAccountID = ACCOUNT, prefix = PREFIX, text = "\001hi", result = 0 } },
        TestEnv.TakeBattleNetOutbox()
      )
    end)

    it("chunks a long message and the receiver reassembles it, apart from realm traffic", function()
      local received, realm = {}, {}
      local connection = assert(scope:RegisterBattleNet(PREFIX, function(prefix, text, senderID)
        received[#received + 1] = { prefix, text, senderID }
      end))
      assert.are.equal(PREFIX, connection:GetPrefix())
      scope:Register(PREFIX, function(_, text)
        realm[#realm + 1] = text
      end)
      local text = TestEnv.Text(700)
      scope:SendBattleNet({ prefix = PREFIX, text = text, gameAccountID = ACCOUNT })
      TestEnv.Advance(10)
      local chunks = TestEnv.TakeBattleNetOutbox()
      assert.are.equal(3, #chunks)
      for index = 1, #chunks do
        assert.is_nil(chunks[index].text:find("[\128-\255]"))
        TestEnv.DeliverBattleNet(PREFIX, chunks[index].text, 99)
      end
      assert.are.same({ { PREFIX, text, 99 } }, received)
      assert.are.same({}, realm)
    end)

    it("sets a throttled Battle.net pipe aside and sends again after the backoff", function()
      TestEnv.QueueBattleNetResults(TestEnv.SEND_RESULT.AddonMessageThrottle)
      local handle =
        assert(scope:SendBattleNet({ prefix = PREFIX, text = "x", gameAccountID = ACCOUNT }))
      TestEnv.Advance(0)
      assert.are.equal("queued", handle:GetState())
      assert.are.equal(1, CommKit:GetStatistics().throttled)
      TestEnv.Advance(1)
      assert.are.equal("sent", handle:GetState())
    end)

    it("counts toward maxRegistrations and is released with the scope", function()
      local small = CommKit:CreateScope({ maxRegistrations = 1 })
      assert(small:RegisterBattleNet(PREFIX, function() end))
      assert.are.same({ nil, "full" }, { small:RegisterBattleNet(PREFIX .. "2", function() end) })
      assert.are.equal(1, small:GetRegistrationCount())
      small:Close()
      assert.are.equal(0, small:GetRegistrationCount())
    end)

    it("drops a secret or malformed delivery", function()
      local received = {}
      scope:RegisterBattleNet(PREFIX, function(_, text)
        received[#received + 1] = text
      end)
      TestEnv.Emit("BN_CHAT_MSG_ADDON", PREFIX, "\001x", "WHISPER", "not a number")
      setGlobal("issecretvalue", function(value)
        return value == "\001secret"
      end)
      TestEnv.DeliverBattleNet(PREFIX, "\001secret", ACCOUNT)
      setGlobal("issecretvalue", nil)
      assert.are.same({}, received)
      assert.are.equal(1, CommKit:GetStatistics().secretsDropped)
    end)

    it("refuses forbidden bytes, a missing client function and a closed scope", function()
      assert.are.same(
        { nil, "forbiddenByte" },
        { scope:SendBattleNet({ prefix = PREFIX, text = "a|b", gameAccountID = ACCOUNT }) }
      )
      setGlobal("C_BattleNet", nil)
      assert.are.same(
        { nil, "unavailable" },
        { scope:SendBattleNet({ prefix = PREFIX, text = "x", gameAccountID = ACCOUNT }) }
      )
      scope:Close()
      assert.are.same(
        { nil, "closed" },
        { scope:SendBattleNet({ prefix = PREFIX, text = "x", gameAccountID = ACCOUNT }) }
      )
    end)

    it("fails a queued Battle.net message when the client function disappears", function()
      TestEnv.HoldSends(CommKit)
      local handle =
        assert(scope:SendBattleNet({ prefix = PREFIX, text = "x", gameAccountID = ACCOUNT }))
      setGlobal("C_BattleNet", nil)
      TestEnv.ReleaseSends(CommKit)
      assert.are.equal("failed", handle:GetState())
    end)

    it("raises at the caller for a malformed request", function()
      for _, request in ipairs({
        { prefix = PREFIX, text = "x", gameAccountID = 0 },
        { prefix = PREFIX, text = "x", gameAccountID = 1.5 },
        { prefix = PREFIX, text = "x" },
        { prefix = PREFIX, gameAccountID = ACCOUNT },
        { text = "x", gameAccountID = ACCOUNT },
      }) do
        local ok, failure = pcall(function()
          scope:SendBattleNet(request)
        end)
        assert.is_false(ok)
        assert.is_truthy(
          tostring(failure):find("ChatThrottle_spec%.lua:%d+: CommKit.Scope:SendBattleNet")
        )
      end
    end)

    it("charges another addon's Battle.net traffic once HookKit hooks it", function()
      CommKit = TestEnv.Load({ hookKit = true })
      scope = CommKit:CreateScope()
      -- The first wake from idle finds HookKit and installs the hooks.
      scope:Send({ prefix = "CKWake", text = "x", distribution = "PARTY" })
      -- selene: allow(global_usage)
      _G.C_BattleNet.SendGameData(ACCOUNT, "Other", "payload")
      assert.are.equal(1, CommKit:GetStatistics().outsideMessages)
      scope:SendBattleNet({ prefix = PREFIX, text = "mine", gameAccountID = ACCOUNT })
      TestEnv.Advance(0)
      assert.are.equal(1, CommKit:GetStatistics().outsideMessages)
    end)

    it("hooks Battle.net at once when the core's hooks came first", function()
      CommKit = TestEnv.Load({ hookKit = true, chatThrottle = false })
      CommKit:CreateScope():Send({ prefix = "CKWake", text = "x", distribution = "PARTY" })
      require("CommKit-ChatThrottle")
      -- selene: allow(global_usage)
      _G.C_BattleNet.SendGameData(ACCOUNT, "Other", "payload")
      assert.are.equal(1, CommKit:GetStatistics().outsideMessages)
    end)
  end)
end)
