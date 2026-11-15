local TestEnv = require("WidgetKitTestEnv")

---A minimal custom widget type: one frame, optional hooks.
---@param hooks table?
---@return fun(): table constructor
local function customType(hooks)
  return function()
    local widget = { frame = TestEnv.GetGlobal("CreateFrame")("Frame") }
    for name, hook in pairs(hooks or {}) do
      widget[name] = hook
    end
    return widget
  end
end

---Count the `pcall` calls `action` makes.
---@param action fun()
---@return integer
local function countProtectedCalls(action)
  local original = TestEnv.GetGlobal("pcall")
  local count = 0
  TestEnv.SetGlobal("pcall", function(...)
    count = count + 1
    return original(...)
  end)
  local ok, failure = original(action)
  TestEnv.SetGlobal("pcall", original)
  assert(ok, failure)
  return count
end

describe("WidgetKit pooling", function()
  local WidgetKit
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("makes a type's free list on its first Create, not at load", function()
    local types = WidgetKit._state.types
    for _, typeRecord in pairs(types) do
      assert.is_nil(typeRecord.free)
      assert.is_nil(typeRecord.pool)
    end
    local label = WidgetKit:Create("Label")
    assert.are.same({}, types.Label.free)
    assert.is_nil(types.Button.free)
    WidgetKit:Release(label)
    assert.are.same({ label }, types.Label.free)
    assert.are.equal(label, WidgetKit:Create("Label"))
  end)

  it("reports a type that was never created with its cap and zeros", function()
    local row = WidgetKit:GetStatistics().byType.Slider
    assert.are.same(
      { version = 4, maxCreated = 256, created = 0, active = 0, available = 0, discarded = 0 },
      row
    )
  end)

  it("counts, caps and reuses widgets", function()
    assert.is_true(WidgetKit:RegisterType("SpecCapped", customType(), 1, { maxCreated = 2 }))
    local first = WidgetKit:Create("SpecCapped")
    local second = WidgetKit:Create("SpecCapped")
    local third, reason = WidgetKit:Create("SpecCapped")
    assert.is_nil(third)
    assert.are.equal("exhausted", reason)
    WidgetKit:Release(first)
    local row = WidgetKit:GetStatistics().byType.SpecCapped
    assert.are.equal(2, row.created)
    assert.are.equal(1, row.active)
    assert.are.equal(1, row.available)
    assert.are.equal(first, WidgetKit:Create("SpecCapped"))
    WidgetKit:Release(second)
  end)

  it("retires idle widgets at a raised version and borrowed ones on release", function()
    assert.is_true(WidgetKit:RegisterType("SpecVersioned", customType(), 1))
    local idle = WidgetKit:Create("SpecVersioned")
    local borrowed = WidgetKit:Create("SpecVersioned")
    WidgetKit:Release(idle)
    assert.is_true(WidgetKit:RegisterType("SpecVersioned", customType(), 2))
    local row = WidgetKit:GetStatistics().byType.SpecVersioned
    assert.are.equal(1, row.discarded)
    assert.are.equal(0, row.available)
    -- The cap grew by the idle widget retired and the borrowed one replaced.
    assert.are.equal(258, row.maxCreated)
    WidgetKit:Release(borrowed)
    row = WidgetKit:GetStatistics().byType.SpecVersioned
    assert.are.equal(2, row.discarded)
    local fresh = WidgetKit:Create("SpecVersioned")
    assert.are_not.equal(idle, fresh)
    assert.are_not.equal(borrowed, fresh)
  end)

  it("runs WidgetKit's own hooks unprotected and a custom type's protected", function()
    local label = WidgetKit:Create("Label") ---@cast label -nil
    WidgetKit:Release(label)
    assert.are.equal(
      0,
      countProtectedCalls(function()
        local again = WidgetKit:Create("Label") ---@cast again -nil
        again:SetText("cycle")
        WidgetKit:Release(again)
      end)
    )

    local hooks = {
      OnAcquire = function() end,
      OnRelease = function() end,
    }
    assert.is_true(WidgetKit:RegisterType("SpecHooked", customType(hooks), 1))
    WidgetKit:Release(WidgetKit:Create("SpecHooked"))
    assert.are.equal(
      2,
      countProtectedCalls(function()
        WidgetKit:Release(WidgetKit:Create("SpecHooked"))
      end)
    )
    assert.is_false(WidgetKit._state.types.SpecHooked.trusted)
    assert.is_true(WidgetKit._state.types.Label.trusted)
  end)

  it("no longer trusts a built-in type a custom constructor replaced", function()
    assert.is_true(WidgetKit:RegisterType("Label", customType(), 9))
    assert.is_false(WidgetKit._state.types.Label.trusted)
    -- WidgetKit's own part keeps the higher custom version.
    package.loaded["WidgetKit-Text"] = nil
    TestEnv.LoadPart("Text", 2)
    assert.are.equal(9, WidgetKit:GetTypeVersion("Label"))
    assert.is_false(WidgetKit._state.types.Label.trusted)
  end)

  it("keeps one scratch table per layout depth", function()
    local outer = WidgetKit:Create("Group") ---@cast outer -nil
    local inner = WidgetKit:Create("Group") ---@cast inner -nil
    inner:AddChild(WidgetKit:Create("Label"))
    outer:AddChild(inner)
    for _ = 1, 5 do
      assert.is_true(outer:PerformLayout())
    end
    local free = WidgetKit._state.scratchFree
    assert.is_true(#free >= 1 and #free <= 2)
    assert.is_nil(next(free[1]))
    WidgetKit:Release(outer)
  end)
end)
