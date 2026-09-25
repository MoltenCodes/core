local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

---Put a state this file built back into revision 5's layout: queue records
---leased from a PoolKit `records` pool (each queued record is replaced by a
---leased copy its handle points to), and none of the revision 6 fields: no
---record free list, no held callbacks, no inline flag, no sample time.
---@param olderState table
---@param PoolKit table
---@return table pool the `records` pool
local function rewindToRevision5(olderState, PoolKit)
  local pool = PoolKit:NewTablePool({ maxRetained = 64 })
  olderState.pools.records = pool
  for _, queue in pairs(olderState.queues) do
    for _, pipe in pairs(queue.pipes) do
      local fifo = pipe.fifo
      for index = 1, #fifo do
        local record = fifo[index]
        local leased = pool:Acquire()
        for key, value in pairs(record) do
          if key ~= "freeListed" then
            leased[key] = value
          end
        end
        fifo[index] = leased
        if record.handle then
          rawset(record.handle, "_record", leased)
        end
      end
    end
  end
  olderState.spares.records = nil
  olderState.deferred = nil
  olderState.driver.inline = nil
  olderState.budget.sampledAt = nil
  return pool
end

describe("CommKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("returns the same facade on duplicate embedded load", function()
    local CommKit = TestEnv.NewPackage()
    local scope = CommKit:CreateScope()
    local connection = scope:Register(PREFIX, function() end)
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(CommKit, reloaded)
    assert.is_true(connection:IsConnected())
    assert.are.same({ PREFIX }, TestEnv.Chat().registerCalls)
  end)

  it("publishes through Registry with its constants", function()
    local CommKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("commKit", 1)
    assert.are.equal(CommKit, registered)
    assert.are.equal(CommKit.REVISION, revision)
    assert.are.equal(255, CommKit.MAX_MESSAGE_BYTES)
    assert.are.equal(32, CommKit.MAX_REGISTRATIONS)
    assert.are.same({ ALERT = "ALERT", NORMAL = "NORMAL", BULK = "BULK" }, CommKit.Priority)
  end)

  it("loads and sends without CodecKit, HookKit or SchemaKit", function()
    local CommKit = TestEnv.Load({ codecKit = false })
    local handle = CommKit:CreateScope()
      :Send({ prefix = PREFIX, text = "x", distribution = "PARTY" })
    TestEnv.Advance(0)
    assert.are.equal("sent", handle:GetState())
  end)

  it("delivers through securecallfunction when the client has it", function()
    local CommKit = TestEnv.Load({ secureCall = true })
    TestEnv.TakeReportedErrors()
    CommKit:CreateScope():Register(PREFIX, function()
      error("isolated", 0)
    end)
    TestEnv.Deliver(PREFIX, "\001x", "PARTY", "Friend-Realm")
    assert.are.same({ { value = "isolated" } }, TestEnv.TakeReportedErrors())
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local CommKit, Registry = TestEnv.NewPackage()
    local shipped = CommKit.REVISION
    local upgraded, previous = Registry:Register("commKit", 1, 99)
    assert.are.equal(CommKit, upgraded)
    assert.are.equal(shipped, previous)

    rawset(CommKit, "REVISION", 99)
    rawset(CommKit, "_state", { schema = 999 })
    package.loaded["CommKit"] = nil
    local reloaded = require("CommKit")
    assert.are.equal(CommKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place with sends, streams, registrations and SyncSets alive", function()
    local CommKit = TestEnv.NewPackage()
    local prototypes = { CommKit.Scope, CommKit.SendHandle, CommKit.Connection, CommKit.SyncSet }
    CommKit:SetLimits({ burst = 400, maxCps = 100 })
    local scope = CommKit:ForAddon("MyAddon")
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local sync = assert(scope:SyncSet("CKSync", { fields = { "name" } }))
    sync:Set("name", "Bob")
    local text = TestEnv.Text(700)
    local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
    TestEnv.Advance(0)
    assert.are.equal("sending", handle:GetState())
    TestEnv.Loopback("Friend-Realm")

    local nextRevision = CommKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(CommKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.same(
      prototypes,
      { upgraded.Scope, upgraded.SendHandle, upgraded.Connection, upgraded.SyncSet }
    )
    assert.are.equal(scope, upgraded:ForAddon("MyAddon"))
    assert.are.equal(400, upgraded:GetLimits().burst)

    TestEnv.Advance(10)
    assert.are.equal("sent", handle:GetState())
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ text }, received)
    assert.are.equal("Bob", sync:Get("name"))
    assert.is_true(upgraded:CloseAddonScopes("MyAddon"))
    assert.is_true(sync:IsClosed())
  end)

  it("upgrades a revision 2 copy in place with a send in flight", function()
    local older = TestEnv.Load({ commKitRevision = 2 })
    assert.are.equal(2, older.REVISION)
    older:SetLimits({ burst = 400, maxCps = 100 })
    local scope = older:ForAddon("MyAddon")
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local text = TestEnv.Text(700)
    local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
    TestEnv.Advance(0)
    assert.are.equal("sending", handle:GetState())
    TestEnv.Loopback("Friend-Realm")

    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    assert.is_true(CommKit.REVISION > 2)
    assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
    assert.are.equal("playerLogout", rawget(scope, "_logoutCloser"))
    assert.are.equal(400, CommKit:GetLimits().burst)

    TestEnv.Advance(10)
    assert.are.equal("sent", handle:GetState())
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ text }, received)

    -- The inherited facade now refuses a secret before comparing it.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return value == 7
    end)
    TestEnv.expectErrorContaining(
      "CommKit:CreateScope options.maxRegistrations must not be a secret value",
      function()
        CommKit:CreateScope({ maxRegistrations = 7 })
      end
    )
  end)

  it("upgrades a revision 3 copy in place with a send in flight", function()
    local older = TestEnv.Load({ commKitRevision = 3 })
    assert.are.equal(3, older.REVISION)
    local olderState = rawget(older, "_state")
    local prototypes = { older.Scope, older.SendHandle, older.Connection, older.SyncSet }
    older:SetLimits({ burst = 400, maxCps = 100 })
    local scope = older:ForAddon("MyAddon")
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local text = TestEnv.Text(700)
    local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
    TestEnv.Advance(0)
    assert.are.equal("sending", handle:GetState())
    TestEnv.Loopback("Friend-Realm")

    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    assert.is_true(CommKit.REVISION > 3)
    assert.are.equal(olderState, rawget(CommKit, "_state"))
    assert.are.same(
      prototypes,
      { CommKit.Scope, CommKit.SendHandle, CommKit.Connection, CommKit.SyncSet }
    )
    assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
    assert.are.equal(400, CommKit:GetLimits().burst)

    -- The inherited driver now reads a secret send result as a throttle.
    local secret = {}
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return value == secret
    end)
    TestEnv.QueueSendResults(secret)
    TestEnv.Advance(10)
    assert.are.equal(1, CommKit:GetStatistics().throttled)
    assert.are.equal("sent", handle:GetState())
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ text }, received)
  end)

  it("upgrades a revision 4 state in place with a send and a stream in flight", function()
    local older, loaded = TestEnv.Load({ commKitRevision = 4 })
    assert.are.equal(4, older.REVISION)
    local olderState = rawget(older, "_state")
    older:SetLimits({ burst = 400, maxCps = 100 })
    local scope = older:ForAddon("MyAddon")
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local text = TestEnv.Text(700)
    local handle = scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" })
    TestEnv.Advance(0)
    assert.are.equal("sending", handle:GetState())
    local streamText = TestEnv.Text(300)
    TestEnv.Deliver(PREFIX, "\002\129\128\130" .. streamText:sub(1, 251), "PARTY", "Peer-Realm")

    -- The copy loaded above runs this file's code, so its state is put back
    -- into revision 4's layout: no free lists, no reusable expiry timer (the
    -- armed one is a plain one-shot), and the stream's chunks in a separate
    -- list leased from the `parts` pool.
    olderState.pools.parts = loaded.PoolKit:NewTablePool({ maxRetained = 32 })
    local stream = olderState.streamList[1]
    local parts = olderState.pools.parts:Acquire()
    parts[1], stream[1] = stream[1], nil
    stream.parts = parts
    olderState.expiry.idleTimer:Cancel()
    olderState.expiry.timer = olderState.kitScopes.timer:After(30, olderState.trampolines.expire)
    olderState.expiry.idleTimer = nil
    local records = rewindToRevision5(olderState, loaded.PoolKit)
    olderState.spares = nil

    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    assert.is_true(CommKit.REVISION > 4)
    assert.are.equal(olderState, rawget(CommKit, "_state"))
    assert.are.same({ pipes = {}, senders = {}, records = {} }, olderState.spares)
    assert.is_false(olderState.expiry.idleTimer)

    TestEnv.Deliver(PREFIX, "\004\129\128\130" .. streamText:sub(252), "PARTY", "Peer-Realm")
    assert.are.same({ streamText }, received)
    assert.are.equal(0, olderState.pools.parts:GetActiveCount())
    assert.are.equal(0, CommKit:GetStatistics().openStreams)
    assert.is_false(olderState.expiry.timer)
    assert.are.equal(1, #olderState.spares.senders)

    TestEnv.Advance(10)
    assert.are.equal("sent", handle:GetState())
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ streamText, text }, received)
    assert.are.equal(1, #olderState.spares.pipes)
    -- The record revision 4 leased went back to its pool.
    assert.are.equal(0, records:GetActiveCount())
    assert.are.same({}, olderState.spares.records)
  end)

  it("upgrades a revision 5 state in place with a send in flight", function()
    local older, loaded = TestEnv.Load({ commKitRevision = 5 })
    assert.are.equal(5, older.REVISION)
    local olderState = rawget(older, "_state")
    older:SetLimits({ burst = 400, maxCps = 100 })
    local scope = older:ForAddon("MyAddon")
    local received = {}
    scope:Register(PREFIX, function(_, text)
      received[#received + 1] = text
    end)
    local text = TestEnv.Text(700)
    local outcomes = {}
    local handle = scope:Send({
      prefix = PREFIX,
      text = text,
      distribution = "PARTY",
      onComplete = function(_, state)
        outcomes[#outcomes + 1] = state
      end,
    })
    TestEnv.Advance(0)
    assert.are.equal("sending", handle:GetState())
    local records = rewindToRevision5(olderState, loaded.PoolKit)
    assert.are.equal(1, records:GetActiveCount())

    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    assert.is_true(CommKit.REVISION > 5)
    assert.are.equal(olderState, rawget(CommKit, "_state"))
    assert.are.same({}, olderState.spares.records)
    assert.are.same({ count = 0, cursor = 0, flushing = 0 }, olderState.deferred)
    assert.is_false(olderState.driver.inline)
    assert.is_false(olderState.budget.sampledAt)

    -- The inherited driver finishes the message, and its record goes back
    -- to the pool it came from.
    TestEnv.Advance(10)
    assert.are.equal("sent", handle:GetState())
    assert.are.same({ "sent" }, outcomes)
    assert.are.equal(0, records:GetActiveCount())
    TestEnv.Loopback("Friend-Realm")
    assert.are.same({ text }, received)

    -- With the driver idle, a new message leaves inside `Send`.
    TestEnv.Advance(10)
    local next = scope:Send({ prefix = PREFIX, text = "after", distribution = "PARTY" })
    assert.are.equal("sent", next:GetState())
    assert.are.equal(1, #olderState.spares.records)
  end)

  it("upgrades a revision 6 state in place and keeps looking for HookKit", function()
    local older, loaded = TestEnv.Load({ commKitRevision = 6 })
    assert.are.equal(6, older.REVISION)
    local olderState = rawget(older, "_state")
    local scope = older:CreateScope()
    older:SetLimits({ burst = 400, maxCps = 100 })
    local handle = scope:Send({ prefix = PREFIX, text = TestEnv.Text(700), distribution = "PARTY" })
    assert.are.equal("sending", handle:GetState())
    -- Revision 6 had no lookup time.
    olderState.outsideLookupAt = nil

    package.loaded["CommKit"] = nil
    local CommKit = require("CommKit")
    assert.are.equal(older, CommKit)
    assert.is_true(CommKit.REVISION > 6)
    assert.are.equal(olderState, rawget(CommKit, "_state"))
    assert.is_false(olderState.outsideLookupAt)

    -- The inherited send finishes; a HookKit loaded meanwhile is found by
    -- the next wake from idle, because no lookup was made under the new rule.
    TestEnv.Advance(10)
    assert.are.equal("sent", handle:GetState())
    TestEnv.TakeOutbox()
    TestEnv.LoadHookKitLater()
    local lookups = 0
    local find = rawget(loaded.Registry, "Find")
    rawset(loaded.Registry, "Find", function(self, packageName, api)
      if packageName == "hookKit" then
        lookups = lookups + 1
      end
      return find(self, packageName, api)
    end)
    scope:Send({ prefix = PREFIX, text = "after", distribution = "PARTY" })
    rawset(loaded.Registry, "Find", find)
    assert.are.equal(1, lookups)
    assert.are_not.equal(false, olderState.outsideHooks)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "CommKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("Registry API 2", 1, true))
  end)

  it("names each required package that is missing", function()
    local chain = { "Registry", "SignalKit", "EventKit", "TimerKit", "SchedulerKit" }
    local expected = {
      [1] = "SignalKit API 1",
      [2] = "EventKit API 1",
      [3] = "TimerKit API 1",
      [4] = "SchedulerKit API 1",
      [5] = "PoolKit API 1",
    }
    for loadedCount, message in pairs(expected) do
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      for index = 1, loadedCount do
        require(chain[index])
      end
      local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommKit")
      assert.is_false(ok)
      assert.is_truthy(tostring(value):find(message, 1, true), message)
    end
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    local _, loaded = TestEnv.Load({ codecKit = false })
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    for _, name in ipairs({
      "Registry",
      "SignalKit",
      "EventKit",
      "TimerKit",
      "SchedulerKit",
      "PoolKit",
    }) do
      loaded[name] = require(name)
    end
    loaded.Registry:Register("commKit", 1, 1)
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes CommKit", 1, true))
  end)
end)
