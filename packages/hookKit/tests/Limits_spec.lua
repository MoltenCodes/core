local TestEnv = require("HookKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line after
---the one that called `mark()`, the call into HookKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---A table with `count` distinct hookable methods named `Method1` onwards.
---@param count integer
---@return table
local function newTarget(count)
  local target = {}
  for index = 1, count do
    target["Method" .. index] = function() end
  end
  return target
end

---Hook `Method1` to `Method<count>` of `target` and return how many succeeded
---before the first refusal, with that refusal's reason.
---@param scope HookKit.Scope
---@param target table
---@param count integer
---@return integer installed, string|nil reason
local function hookMany(scope, target, count)
  for index = 1, count do
    local installed, reason = scope:Hook(target, "Method" .. index, function() end)
    if not installed then
      return index - 1, reason
    end
  end
  return count, nil
end

describe("HookKit limits", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("exposes one UNBOUNDED sentinel table and the default MAX_HOOKS", function()
    assert.are.equal("table", type(HookKit.UNBOUNDED))
    assert.are.equal(256, HookKit.MAX_HOOKS)
    assert.are.equal(256, HookKit:CreateScope():GetMaxHooks())
    assert.are.equal(256, HookKit:ForAddon("MyAddon"):GetMaxHooks())
  end)

  it("enforces the default of 256 hooks per scope with full", function()
    local scope = HookKit:CreateScope()
    local installed, reason = hookMany(scope, newTarget(257), 257)
    assert.are.equal(256, installed)
    assert.are.equal("full", reason)
  end)

  it("honours a smaller and a larger maxHooks on CreateScope", function()
    local small = HookKit:CreateScope({ maxHooks = 2 })
    local installed, reason = hookMany(small, newTarget(3), 3)
    assert.are.equal(2, installed)
    assert.are.equal("full", reason)

    local large = HookKit:CreateScope({ maxHooks = 300 })
    assert.are.equal(300, large:GetMaxHooks())
    installed, reason = hookMany(large, newTarget(301), 301)
    assert.are.equal(300, installed)
    assert.are.equal("full", reason)
  end)

  it("holds any number of hooks in a scope opened with UNBOUNDED", function()
    local scope = HookKit:CreateScope({ maxHooks = HookKit.UNBOUNDED })
    assert.are.equal(HookKit.UNBOUNDED, scope:GetMaxHooks())
    local installed, reason = hookMany(scope, newTarget(600), 600)
    assert.are.equal(600, installed)
    assert.is_nil(reason)
    assert.are.equal(600, scope:GetActiveCount())
    assert.are.equal(600, scope:UnhookAll())
  end)

  it(
    "fixes the ForAddon limit on the first call and returns the scope when options agree or are omitted",
    function()
      local scope = HookKit:ForAddon("MyAddon", { maxHooks = 1 })
      assert.are.equal(1, scope:GetMaxHooks())
      assert.are.equal(scope, HookKit:ForAddon("MyAddon"))
      assert.are.equal(scope, HookKit:ForAddon("MyAddon", { maxHooks = 1 }))
      assert.are.equal(1, scope:GetMaxHooks())

      local target = newTarget(2)
      assert.is_true(scope:Hook(target, "Method1", function() end))
      local installed, reason = scope:Hook(target, "Method2", function() end)
      assert.is_nil(installed)
      assert.are.equal("full", reason)
    end
  )

  it(
    "refuses a later ForAddon limit that differs at the caller's line and changes nothing",
    function()
      local message =
        "HookKit:ForAddon options.maxHooks differs from the limit this addon's scope was created with"
      local scope = HookKit:ForAddon("MyAddon")
      assert.are.equal(HookKit.MAX_HOOKS, scope:GetMaxHooks())
      assertReportedAtCaller(message, function(mark)
        mark()
        HookKit:ForAddon("MyAddon", { maxHooks = 2 })
      end)
      assertReportedAtCaller(message, function(mark)
        mark()
        HookKit:ForAddon("MyAddon", { maxHooks = HookKit.UNBOUNDED })
      end)
      assert.are.equal(HookKit.MAX_HOOKS, scope:GetMaxHooks())

      local open = HookKit:ForAddon("OtherAddon", { maxHooks = HookKit.UNBOUNDED })
      assert.are.equal(open, HookKit:ForAddon("OtherAddon", { maxHooks = HookKit.UNBOUNDED }))
      assertReportedAtCaller(message, function(mark)
        mark()
        HookKit:ForAddon("OtherAddon", { maxHooks = 256 })
      end)
    end
  )

  it("refuses invalid maxHooks values at the caller's line", function()
    local message =
      "HookKit:CreateScope options.maxHooks must be a positive integer or HookKit.UNBOUNDED"
    local invalid = { 0, -1, 1.5, 0 / 0, math.huge, -math.huge, "10", true, {} }
    for index = 1, #invalid do
      assertReportedAtCaller(message, function(mark)
        mark()
        HookKit:CreateScope({ maxHooks = invalid[index] })
      end)
    end
    assertReportedAtCaller(
      "HookKit:ForAddon options.maxHooks must be a positive integer or HookKit.UNBOUNDED",
      function(mark)
        mark()
        HookKit:ForAddon("MyAddon", { maxHooks = 0 })
      end
    )
    assertReportedAtCaller(
      'HookKit:CreateScope options contains unknown field "maxHook"',
      function(mark)
        mark()
        HookKit:CreateScope({ maxHook = 10 })
      end
    )
    assertReportedAtCaller("HookKit:ForAddon options must be a table", function(mark)
      mark()
      HookKit:ForAddon("MyAddon", 10)
    end)
    assertReportedAtCaller(
      "HookKit:CreateScope must be called on the HookKit facade; use HookKit:CreateScope(...)",
      function(mark)
        mark()
        HookKit.CreateScope({ maxHooks = 10 })
      end
    )
  end)

  it("leaves an existing addon scope unchanged when its options are refused", function()
    local scope = HookKit:ForAddon("MyAddon", { maxHooks = 5 })
    assert.is_false((pcall(HookKit.ForAddon, HookKit, "MyAddon", { maxHooks = -5 })))
    assert.are.equal(5, scope:GetMaxHooks())
  end)

  it("asks the secret probe before comparing maxHooks with UNBOUNDED", function()
    local askedAboutSentinel = false
    local sentinel = nil
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.InstallHookApi()
    TestEnv.SetGlobal("issecretvalue", function(value)
      if sentinel ~= nil and rawequal(value, sentinel) then
        askedAboutSentinel = true
      end
      return false
    end)
    require("Registry")
    HookKit = require("HookKit")
    sentinel = HookKit.UNBOUNDED
    local scope = HookKit:CreateScope({ maxHooks = sentinel })
    assert.are.equal(sentinel, scope:GetMaxHooks())
    assert.is_true(askedAboutSentinel)
  end)

  it("refuses a secret maxHooks at the caller", function()
    local secret = TestEnv.NewSecretValue()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.InstallHookApi()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    require("Registry")
    HookKit = require("HookKit")
    assertReportedAtCaller(
      "HookKit:CreateScope options.maxHooks must be a positive integer or HookKit.UNBOUNDED",
      function(mark)
        mark()
        HookKit:CreateScope({ maxHooks = secret })
      end
    )
  end)
end)
