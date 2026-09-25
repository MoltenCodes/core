local Env = require("LogKitTestEnv")

describe("LogKit bootstrap", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("refuses to load without Registry", function()
    Env.InstallWowApi()
    Env.expectErrorContaining("requires Registry API 2 to be loaded first", function()
      Env.requireAfterFailedLoad("LogKit")
    end)
  end)

  it("refuses to load without SignalKit", function()
    Env.InstallWowApi()
    require("Registry")
    Env.expectErrorContaining("requires SignalKit API 1 to be loaded first", function()
      Env.requireAfterFailedLoad("LogKit")
    end)
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    Env.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    Registry:Register("logKit", 1, 1)
    Env.expectErrorContaining("MoltenCodes LogKit", function()
      Env.requireAfterFailedLoad("LogKit")
    end)
  end)

  it("publishes through Registry", function()
    local LogKit, Registry = Env.NewPackage()
    assert.are.equal(LogKit, Registry:Get("logKit", 1))
    assert.are.equal(1, LogKit.API)
    assert.are.equal(4, LogKit.REVISION)
  end)

  it("reuses the shared facade, loggers, levels and journal on duplicate load", function()
    local LogKit = Env.NewPackage()
    local logger = LogKit:ForAddon("kept")
    logger:SetLevel("debug")
    logger:Debug("recorded")

    local reloaded = Env.ReloadPackage()
    assert.are.equal(LogKit, reloaded)
    assert.are.equal(logger, reloaded:ForAddon("kept"))
    assert.are.equal("debug", (logger:GetLevel()))
    local messages = {}
    for _, _, _, message in reloaded:History() do
      messages[#messages + 1] = message
    end
    assert.are.same({ "recorded" }, messages)
  end)

  it("does not downgrade a newer compatible embedded revision", function()
    local LogKit, Registry = Env.NewPackage()
    local shared = Registry:Register("logKit", 1, 99)
    assert.are.equal(LogKit, shared)
    rawset(shared, "REVISION", 99)

    local reloaded = Env.ReloadPackage()
    assert.are.equal(shared, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place, keeping loggers, levels, sinks, the journal and LEVELS", function()
    local LogKit = Env.NewPackage()
    local levels = LogKit.LEVELS
    local unbounded = LogKit.UNBOUNDED
    local logger = LogKit:ForAddon("upgraded")
    local oldWarn = logger.Warn
    LogKit:SetGlobalLevel("info")
    logger:SetLevel("debug")
    local delivered = {}
    local handle = LogKit:AddSink(function(record)
      delivered[#delivered + 1] = record.message
    end)
    logger:Debug("before")
    LogKit:SetLimits({ maxSinks = 3 })

    local nextRevision = LogKit.REVISION + 1
    local upgraded = Env.LoadRevision(nextRevision)

    assert.are.equal(LogKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(levels, upgraded.LEVELS)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.equal(logger, upgraded:ForAddon("upgraded"))
    -- The old copy's logger now resolves to the new copy's methods.
    assert.are_not.equal(oldWarn, logger.Warn)
    assert.are.equal("info", upgraded:GetGlobalLevel())
    local level, source = logger:GetLevel()
    assert.are.equal("debug", level)
    assert.are.equal("addon", source)
    assert.are.equal(3, upgraded:GetLimits().maxSinks)

    logger:Debug("after")
    assert.are.same({ "before", "after" }, delivered)
    local messages = {}
    for _, _, _, message in upgraded:History("upgraded") do
      messages[#messages + 1] = message
    end
    assert.are.same({ "before", "after" }, messages)
    assert.is_true(upgraded:RemoveSink(handle))
  end)

  it("upgrades revision 1 state in place and refuses a secret limit afterwards", function()
    Env.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local previous = Env.LoadRevision(1)
    assert.are.equal(1, previous.REVISION)
    local logger = previous:ForAddon("Kept")
    logger:SetLevel("info")
    previous:SetGlobalLevel("error")
    local delivered = {}
    local handle = previous:AddSink(function(record)
      delivered[#delivered + 1] = record.message
    end)
    logger:Info("before")
    previous:SetLimits({ maxSinks = 4 })

    local LogKit = Env.ReloadPackage()
    assert.are.equal(previous, LogKit)
    assert.are.equal(4, LogKit.REVISION)
    assert.are.equal(logger, LogKit:ForAddon("Kept"))
    assert.are.equal("info", (logger:GetLevel()))
    assert.are.equal("error", LogKit:GetGlobalLevel())
    assert.are.equal(4, LogKit:GetLimits().maxSinks)
    logger:Info("after")
    assert.are.same({ "before", "after" }, delivered)
    assert.is_true(LogKit:RemoveSink(handle))

    -- The fix revision 2 carries: a secret limit value is refused at the
    -- caller before it is compared.
    local secret = Env.NewSecretValue()
    Env.expectErrorContaining(
      "LogKit:SetLimits limits.maxSinks must not be a secret value",
      function()
        LogKit:SetLimits({ maxSinks = secret })
      end
    )
    assert.are.equal(4, LogKit:GetLimits().maxSinks)
  end)

  it(
    "upgrades the previous revision's state in place and refuses a secret receiver afterwards",
    function()
      local shippedRevision = Env.NewPackage().REVISION
      Env.Reset()
      Env.InstallWowApi()
      require("Registry")
      require("SignalKit")
      local previous = Env.LoadRevision(shippedRevision - 1)
      assert.are.equal(shippedRevision - 1, previous.REVISION)
      local state = previous._state
      local logger = previous:ForAddon("Kept")
      logger:SetLevel("debug")
      previous:SetGlobalLevel("warn")
      local delivered = {}
      previous:AddSink(function(record)
        delivered[#delivered + 1] = record.message
      end)
      logger:Debug("before")

      local LogKit = Env.ReloadPackage()
      assert.are.equal(previous, LogKit)
      assert.are.equal(shippedRevision, LogKit.REVISION)
      assert.are.equal(state, LogKit._state)
      assert.are.equal(logger, LogKit:ForAddon("Kept"))
      assert.are.equal("warn", LogKit:GetGlobalLevel())
      logger:Debug("after")
      assert.are.same({ "before", "after" }, delivered)

      -- The fix the shipped revision carries: a secret receiver is reported
      -- as a call without the facade, before it is compared.
      local secret = Env.NewSecretValue()
      Env.expectErrorContaining(
        "LogKit:SetGlobalLevel must be called on the LogKit facade",
        function()
          LogKit.SetGlobalLevel(secret, nil)
        end
      )
      assert.are.equal("warn", LogKit:GetGlobalLevel())
    end
  )

  it("upgrades in place and routes an older chat sink through the newest Write", function()
    local LogKit = Env.NewPackage()
    Env.InstallChatApi()
    local sink = LogKit:ChatSink()
    LogKit:AddSink(sink)
    local oldWrite = sink.Write

    local upgraded = Env.LoadRevision(LogKit.REVISION + 1)
    assert.are_not.equal(oldWrite, sink.Write)
    upgraded:ForAddon("MyAddon"):Warn("still printed")
    assert.are.same({ "[MyAddon] |cffffa500warn|r: still printed" }, Env.ChatLines())

    -- The method is looked up per call: a Write installed on the shared
    -- prototype after the sink was added is what the next message reaches.
    local received = {}
    rawset(upgraded._state.chatSinkPrototype, "Write", function(_, record)
      received[#received + 1] = record.message
    end)
    upgraded:ForAddon("MyAddon"):Warn("through the prototype")
    assert.are.same({ "through the prototype" }, received)
  end)

  it("refuses shared state whose limits hold an invalid value", function()
    local LogKit = Env.NewPackage()
    rawset(LogKit._state.limits, "maxSinks", 0)
    Env.expectErrorContaining("package state is corrupted or incomplete", function()
      Env.ReloadPackage()
    end)
  end)

  it("refuses corrupted shared state on reload", function()
    local LogKit = Env.NewPackage()
    rawset(LogKit._state, "loggers", false)
    Env.expectErrorContaining("package state is corrupted or incomplete", function()
      Env.ReloadPackage()
    end)
  end)

  for _, case in ipairs({
    { field = "delivering", value = 1 },
    { field = "pendingRemovals", value = false },
    { field = "binding", value = "db" },
  }) do
    it("refuses a corrupted " .. case.field .. " on reload", function()
      local LogKit = Env.NewPackage()
      rawset(LogKit._state, case.field, case.value)
      Env.expectErrorContaining("package state is corrupted or incomplete", function()
        Env.ReloadPackage()
      end)
    end)
  end

  it("refuses a global level outside the known levels on reload", function()
    local LogKit = Env.NewPackage()
    rawset(LogKit._state, "globalLevel", 9)
    Env.expectErrorContaining("package state is corrupted or incomplete", function()
      Env.ReloadPackage()
    end)
  end)
end)
