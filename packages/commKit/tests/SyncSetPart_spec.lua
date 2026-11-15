local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKSyncPart"
local FIELDS = { fields = { "name", "level" } }

---The line `error` names for a failure raised at `level` 2 from the caller.
---@param failure string
---@return string|nil
local function lineOf(failure)
  return tostring(failure):match("SyncSetPart_spec%.lua:(%d+):")
end

describe("CommKit SyncSet part", function()
  after_each(TestEnv.Reset)

  describe("without the part", function()
    local CommKit, scope
    before_each(function()
      CommKit = TestEnv.Load({ syncSet = false })
      scope = CommKit:CreateScope()
    end)

    it("reports it absent", function()
      assert.is_false(CommKit:HasPart("SyncSet"))
    end)

    it("raises at the caller's line with the file to embed", function()
      local ok, failure = pcall(function()
        scope:SyncSet(PREFIX, FIELDS) -- the line the error names
      end)
      assert.is_false(ok)
      assert.are.equal(
        "CommKit.Scope:SyncSet is in CommKit's SyncSet part, which is not loaded: add "
          .. "commKit\\parts\\CommKit-SyncSet.lua to embeds.xml after commKit\\CommKit.lua",
        tostring(failure):gsub("^.-:%d+: ", "")
      )
      assert.is_truthy(lineOf(failure))
    end)

    it("refuses a closed scope with nil and closed first, as the part does", function()
      scope:Close()
      assert.are.same({ nil, "closed" }, { scope:SyncSet(PREFIX, FIELDS) })
    end)

    it("refuses a receiver that is not a scope before anything else", function()
      local ok, failure = pcall(CommKit.Scope.SyncSet, {}, PREFIX, FIELDS)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("CommKit.Scope:SyncSet must be called on a CommKit scope", 1, true)
      )
    end)

    it("keeps every SyncSet member present for other copies' surface checks", function()
      for _, name in ipairs({
        "Set",
        "Get",
        "GetHash",
        "GetRemote",
        "Request",
        "OnChanged",
        "Close",
        "IsClosed",
      }) do
        assert.are.equal("function", type(CommKit.SyncSet[name]), name)
      end
    end)

    it("still closes scopes, unregisters and sends", function()
      scope:Register(PREFIX, function() end)
      assert.are.equal(1, scope:UnregisterAll())
      local handle = scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
      assert.are.equal("sent", handle:GetState())
      assert.is_true(scope:Close())
    end)

    it("keeps the SyncSet limits and statistics", function()
      CommKit:SetLimits({ maxSyncPeers = 8, maxSyncReplyBytes = 1024 })
      assert.are.equal(8, CommKit:GetLimits().maxSyncPeers)
      assert.are.equal(0, CommKit:GetStatistics().syncRequests)
    end)
  end)

  describe("bootstrap", function()
    it("requires its core", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local ok, failure = pcall(require, "CommKit-SyncSet")
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          "MoltenCodes CommKit part SyncSet requires CommKit API 1 to be loaded first",
          1,
          true
        )
      )
    end)

    it("is installed by the default chain and reported present", function()
      local CommKit = TestEnv.Load()
      assert.is_true(CommKit:HasPart("SyncSet"))
      assert.are.same({ revision = 1 }, CommKit._state.parts.SyncSet)
    end)

    it("returns without changes when an equal revision is installed", function()
      local CommKit = TestEnv.Load()
      local before = CommKit.Scope.SyncSet
      package.loaded["CommKit-SyncSet"] = nil
      assert.are.equal(CommKit, require("CommKit-SyncSet"))
      assert.are.equal(before, CommKit.Scope.SyncSet)
    end)

    it("upgrades in place over a lower part revision, keeping live SyncSets", function()
      local CommKit = TestEnv.Load()
      local scope = CommKit:CreateScope()
      local sync = assert(scope:SyncSet(PREFIX, FIELDS))
      sync:Set("name", "Alice")
      CommKit._state.parts.SyncSet.revision = 0
      local before = CommKit.Scope.SyncSet
      package.loaded["CommKit-SyncSet"] = nil
      require("CommKit-SyncSet")
      assert.are_not.equal(before, CommKit.Scope.SyncSet)
      assert.are.equal("Alice", sync:Get("name"))
      assert.are.equal(1, CommKit._state.parts.SyncSet.revision)
    end)

    it("keeps its members when a newer core loads after it", function()
      local CommKit = TestEnv.Load()
      local member = CommKit.Scope.SyncSet
      package.loaded["CommKit"] = nil
      TestEnv.LoadRevision(CommKit.REVISION + 1)
      assert.are.equal(member, CommKit.Scope.SyncSet)
      assert.is_truthy(CommKit:CreateScope():SyncSet(PREFIX, FIELDS))
    end)
  end)

  describe("over the whole revision 10", function()
    it("keeps a live SyncSet when the part is loaded with the core", function()
      local older, loaded = TestEnv.Load({ commKitRevision = 10 })
      local CodecKit = loaded.CodecKit
      local scope = older:CreateScope()
      local sync = assert(scope:SyncSet(PREFIX, FIELDS))
      sync:Set("level", 70)
      package.loaded["CommKit"] = nil
      local CommKit = require("CommKit")
      require("CommKit-SyncSet")
      assert.are.equal(older, CommKit)
      TestEnv.TakeReportedErrors()
      TestEnv.Advance(0)
      assert.are.same({}, TestEnv.TakeReportedErrors())
      assert.is_false(sync:IsClosed())
      assert.are.equal(70, sync:Get("level"))
      -- It still answers a request under the new code.
      local ok, request = CodecKit:Encode({ 1, {} }, { channel = "addon" })
      assert.is_true(ok)
      TestEnv.Deliver(PREFIX, "\001" .. request, "WHISPER", "Peer-Realm")
      TestEnv.Advance(0)
      assert.are.equal(1, #TestEnv.TakeOutbox())
    end)

    it("closes an addon scope's SyncSet and reports once when the part never loads", function()
      local older = TestEnv.Load({ commKitRevision = 10 })
      local sync = assert(older:ForAddon("Older"):SyncSet(PREFIX, FIELDS))
      local manual = assert(older:CreateScope():SyncSet(PREFIX .. "M", FIELDS))
      package.loaded["CommKit"] = nil
      local CommKit = require("CommKit")
      TestEnv.TakeReportedErrors()
      TestEnv.Advance(0)
      local reports = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reports)
      assert.is_truthy(tostring(reports[1].value):find("CommKit-SyncSet.lua", 1, true))
      assert.is_true(rawget(sync, "_closed"))
      assert.is_false(CommKit:HasPart("SyncSet"))
      -- A manual scope's SyncSet cannot be found: it stops receiving, says so
      -- no more than once, and its methods raise with the file to embed.
      TestEnv.Deliver(PREFIX .. "M", "\001x", "WHISPER", "Peer-Realm")
      assert.are.same({}, TestEnv.TakeReportedErrors())
      local ok, failure = pcall(function()
        manual:Get("name")
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("CommKit-SyncSet.lua", 1, true))
    end)

    it("yields when revision 10 loads after a core-only revision 11", function()
      local CommKit = TestEnv.Load({ syncSet = false })
      package.loaded["CommKit"] = nil
      local older = TestEnv.LoadWholeRevision10()
      assert.are.equal(CommKit, older)
      assert.is_true(older.REVISION >= 11)
      local ok, failure = pcall(function()
        older:CreateScope():SyncSet(PREFIX, FIELDS)
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("CommKit-SyncSet.lua", 1, true))
    end)
  end)
end)
