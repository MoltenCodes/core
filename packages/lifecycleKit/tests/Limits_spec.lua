local TestEnv = require("LifecycleKitTestEnv")

-- The escape hatch of design principle 4a: LifecycleKit's two retained lists,
-- an addon's `DependsOn` list and its combat queue, are bounded by default and
-- opened through `SetLimits`, `SetCombatQueueLimit` and `LifecycleKit.UNBOUNDED`.
describe("LifecycleKit limits", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports the defaults as a fresh table on every call", function()
    local limits = LifecycleKit:GetLimits()

    assert.are.same({ maxDependencies = 16, defaultCombatQueueLimit = 64 }, limits)
    limits.maxDependencies = 1
    assert.are_not.equal(limits, LifecycleKit:GetLimits())
    assert.are.equal(16, LifecycleKit:GetLimits().maxDependencies)
  end)

  it("publishes one UNBOUNDED sentinel that survives a reload", function()
    local sentinel = LifecycleKit.UNBOUNDED

    assert.are.equal("table", type(sentinel))
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(sentinel, reloaded.UNBOUNDED)
  end)

  it("raises maxDependencies for every addon", function()
    LifecycleKit:SetLimits({ maxDependencies = 20 })
    local consumer = LifecycleKit:ForAddon("MyConsumer")
    for index = 1, 20 do
      assert.is_true(consumer:DependsOn("Library" .. index))
    end

    local recorded, reason = consumer:DependsOn("Library21")

    assert.is_nil(recorded)
    assert.are.equal("full", reason)
  end)

  it("lifts maxDependencies with UNBOUNDED", function()
    LifecycleKit:SetLimits({ maxDependencies = LifecycleKit.UNBOUNDED })
    local consumer = LifecycleKit:ForAddon("MyConsumer")

    for index = 1, 100 do
      assert.is_true(consumer:DependsOn("Library" .. index))
    end
    assert.are.equal(LifecycleKit.UNBOUNDED, LifecycleKit:GetLimits().maxDependencies)
  end)

  it("forgets nothing when maxDependencies is lowered", function()
    local consumer = LifecycleKit:ForAddon("MyConsumer")
    for index = 1, 4 do
      consumer:DependsOn("Library" .. index)
    end

    LifecycleKit:SetLimits({ maxDependencies = 2 })

    assert.is_false(consumer:DependsOn("Library4"))
    local recorded, reason = consumer:DependsOn("Library5")
    assert.is_nil(recorded)
    assert.are.equal("full", reason)
  end)

  it("gives new instances the default combat queue limit and leaves existing ones", function()
    local existing = LifecycleKit:ForAddon("Existing")

    LifecycleKit:SetLimits({ defaultCombatQueueLimit = 3 })
    local created = LifecycleKit:ForAddon("Created")

    assert.are.equal(64, existing:GetCombatQueueLimit())
    assert.are.equal(3, created:GetCombatQueueLimit())
    TestEnv.EnterCombat()
    for _ = 1, 3 do
      assert.is_not_nil(created:WhenOutOfCombat(function() end))
    end
    local handle, reason = created:WhenOutOfCombat(function() end)
    assert.is_nil(handle)
    assert.are.equal("full", reason)
  end)

  it("lets a default of UNBOUNDED reach new instances", function()
    LifecycleKit:SetLimits({ defaultCombatQueueLimit = LifecycleKit.UNBOUNDED })
    local life = LifecycleKit:ForAddon("MyAddon")

    assert.are.equal(LifecycleKit.UNBOUNDED, life:GetCombatQueueLimit())
  end)

  it("queues past 64 calls with an UNBOUNDED combat queue and runs them in order", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    life:SetCombatQueueLimit(LifecycleKit.UNBOUNDED)
    TestEnv.EnterCombat()
    local order = {}
    for index = 1, 200 do
      assert.is_not_nil(life:WhenOutOfCombat(function()
        order[#order + 1] = index
      end))
    end

    TestEnv.LeaveCombat()

    assert.are.equal(200, #order)
    assert.are.equal(1, order[1])
    assert.are.equal(200, order[200])
  end)

  it("keeps an UNBOUNDED combat queue compact while calls are cancelled", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    life:SetCombatQueueLimit(LifecycleKit.UNBOUNDED)
    TestEnv.EnterCombat()
    local runs = 0
    for _ = 1, 1000 do
      local handle = life:WhenOutOfCombat(function()
        runs = runs + 1
      end)
      handle:Cancel()
    end
    life:WhenOutOfCombat(function()
      runs = runs + 1
    end)

    -- Cancelled slots are reclaimed as the queue grows, so the array never
    -- holds more than the compaction floor while almost nothing is pending.
    assert.is_true(rawget(life, "_combatQueueLength") <= 64)
    TestEnv.LeaveCombat()
    assert.are.equal(1, runs)
  end)

  it("applies a SetLimits table atomically", function()
    TestEnv.expectErrorContaining(
      "limits.defaultCombatQueueLimit must be a positive integer",
      function()
        LifecycleKit:SetLimits({ maxDependencies = 4, defaultCombatQueueLimit = 0 })
      end
    )

    assert.are.same(
      { maxDependencies = 16, defaultCombatQueueLimit = 64 },
      LifecycleKit:GetLimits()
    )
  end)

  it("refuses unknown limits, non-tables and invalid values", function()
    TestEnv.expectErrorContaining("LifecycleKit:SetLimits limits must be a table", function()
      LifecycleKit:SetLimits(4)
    end)
    TestEnv.expectErrorContaining("limits.maxQueue is not a recognised limit", function()
      LifecycleKit:SetLimits({ maxQueue = 4 })
    end)
    for _, invalid in ipairs({ 0, -1, 1.5, "8", math.huge, 0 / 0, {} }) do
      TestEnv.expectErrorContaining(
        "LifecycleKit:SetLimits limits.maxDependencies must be a positive integer or LifecycleKit.UNBOUNDED",
        function()
          LifecycleKit:SetLimits({ maxDependencies = invalid })
        end
      )
    end
  end)

  it("must be called on the facade", function()
    TestEnv.expectErrorContaining("must be called on the LifecycleKit facade", function()
      LifecycleKit.SetLimits({}, { maxDependencies = 4 })
    end)
    TestEnv.expectErrorContaining("must be called on the LifecycleKit facade", function()
      LifecycleKit.GetLimits({})
    end)
  end)

  it("reports SetLimits and GetLimits errors at the caller's line", function()
    local source = debug.getinfo(1, "S").short_src
    local callLine
    local ok, message = pcall(function()
      callLine = debug.getinfo(1, "l").currentline + 1
      LifecycleKit:SetLimits({ maxDependencies = 0 })
    end)
    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. callLine
        .. ": LifecycleKit:SetLimits limits.maxDependencies must be a positive integer"
        .. " or LifecycleKit.UNBOUNDED",
      message
    )

    local facadeLine
    local facadeOk, facadeMessage = pcall(function()
      facadeLine = debug.getinfo(1, "l").currentline + 1
      LifecycleKit.GetLimits({})
    end)
    assert.is_false(facadeOk)
    assert.are.equal(
      source
        .. ":"
        .. facadeLine
        .. ": LifecycleKit:GetLimits must be called on the LifecycleKit facade; "
        .. "use LifecycleKit:GetLimits()",
      facadeMessage
    )
  end)
end)

describe("LifecycleKit limits across an upgrade", function()
  after_each(TestEnv.Reset)

  it("seeds the defaults into state an older revision wrote and keeps what was set", function()
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("MyAddon")
    LifecycleKit:SetLimits({ maxDependencies = 5 })
    local state = rawget(LifecycleKit, "_state")

    -- A revision-11 state has neither field; a same-revision reload keeps
    -- what a consumer set.
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(5, reloaded:GetLimits().maxDependencies)

    rawset(state, "unbounded", nil)
    rawset(state, "limits", nil)
    reloaded = TestEnv.ReloadPackage()

    assert.are.same({ maxDependencies = 16, defaultCombatQueueLimit = 64 }, reloaded:GetLimits())
    assert.are.equal("table", type(reloaded.UNBOUNDED))
    assert.are.equal(64, life:GetCombatQueueLimit())
  end)
end)
