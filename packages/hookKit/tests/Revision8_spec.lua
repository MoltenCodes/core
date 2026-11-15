local TestEnv = require("HookKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

-- Revision 8: the capacity check keeps an upper bound of each bounded scope's
-- live records instead of counting them at every install; pre-hooks and
-- post-hooks call their handler under `pcall` themselves; a closed manual
-- scope can be reopened.

---Fill `target` with `count` methods named `Method1` .. `MethodN`.
---@param target table
---@param count integer
---@return table target
local function withMethods(target, count)
  for index = 1, count do
    target["Method" .. index] = function() end
  end
  return target
end

local function noop() end

describe("HookKit record bound", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("keeps the bound equal to the live hooks through installs and releases", function()
    local bounds = HookKit._state.recordBounds
    local scope = HookKit:CreateScope({ maxHooks = 3 })
    local target = withMethods({}, 4)

    assert.is_true(scope:Hook(target, "Method1", noop))
    assert.are.equal(1, bounds[scope])
    scope:Hook(target, "Method2", noop)
    scope:SecureHook(target, "Method3", noop)
    assert.are.equal(3, bounds[scope])
    local installed, reason = scope:Hook(target, "Method4", noop)
    assert.is_nil(installed)
    assert.are.equal("full", reason)

    assert.is_true(scope:Unhook(target, "Method1"))
    assert.are.equal(2, bounds[scope])
    assert.is_true(scope:Hook(target, "Method4", noop))
    assert.are.equal(3, scope:UnhookAll())
    assert.are.equal(0, bounds[scope])
  end)

  it("frees the room of a collected target at the limit", function()
    local scope = HookKit:CreateScope({ maxHooks = 2 })
    do
      local temporary = withMethods({}, 2)
      scope:Hook(temporary, "Method1", noop)
      scope:Hook(temporary, "Method2", noop)
    end
    collectgarbage()
    collectgarbage()

    -- The bound still says two; the count it falls back to at the limit
    -- finds none, so the install succeeds and the bound is corrected.
    local kept = withMethods({}, 1)
    assert.is_true(scope:Hook(kept, "Method1", noop))
    assert.are.equal(1, HookKit._state.recordBounds[scope])
  end)

  it("counts a scope without a bound, as an older copy built it, before admitting", function()
    local scope = HookKit:CreateScope({ maxHooks = 2 })
    local target = withMethods({}, 3)
    scope:Hook(target, "Method1", noop)
    scope:Hook(target, "Method2", noop)
    HookKit._state.recordBounds[scope] = nil

    local installed, reason = scope:Hook(target, "Method3", noop)
    assert.is_nil(installed)
    assert.are.equal("full", reason)
    assert.are.equal(2, HookKit._state.recordBounds[scope])
  end)

  it("never counts an unbounded scope", function()
    local scope = HookKit:CreateScope({ maxHooks = HookKit.UNBOUNDED })
    local target = withMethods({}, 300)
    for index = 1, 300 do
      assert.is_true(scope:Hook(target, "Method" .. index, noop))
    end
    assert.is_nil(HookKit._state.recordBounds[scope])
    assert.are.equal(300, scope:GetActiveCount())
  end)
end)

describe("HookKit handler isolation", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it(
    "reports a pre-hook failure through dispatch and still returns the original's results",
    function()
      local target = {
        Method = function(_, value)
          return value, nil, "last"
        end,
      }
      local scope = HookKit:CreateScope()
      scope:Hook(target, "Method", function()
        error("handler failed", 0)
      end)
      TestEnv.TakeReportedErrors()

      local first, second, third = target:Method("value")
      assert.are.equal("value", first)
      assert.is_nil(second)
      assert.are.equal("last", third)
      assert.are.equal(3, select("#", target:Method("value")))
      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal("handler failed", reported[1].value)
    end
  )

  it("lets a newer copy's reportFailure take over installed closures", function()
    local target = { Method = function() end }
    local scope = HookKit:CreateScope()
    scope:SecureHook(target, "Method", function()
      error("post failed", 0)
    end)
    local dispatch = HookKit._state.dispatch
    local original = dispatch.reportFailure
    local received
    dispatch.reportFailure = function(failure)
      received = failure
    end

    target.Method()
    dispatch.reportFailure = original
    assert.are.equal("post failed", received)
  end)

  it("keeps isolatedCall published for closures older copies installed", function()
    local dispatch = HookKit._state.dispatch
    assert.are.equal("function", type(dispatch.isolatedCall))
    local seen
    dispatch.isolatedCall({
      _handler = function(value)
        seen = value
      end,
    }, "argument")
    assert.are.equal("argument", seen)
  end)
end)

describe("HookKit Scope:Reopen", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reopens a closed manual scope with its limit and answers false when open", function()
    local scope = HookKit:CreateScope({ maxHooks = 1 })
    local target = withMethods({}, 2)
    local original = target.Method1
    scope:Hook(target, "Method1", noop)

    assert.is_false(scope:Reopen())
    scope:Close()
    assert.are.equal(original, target.Method1)
    assert.is_true(scope:Reopen())
    assert.is_false(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal(1, scope:GetMaxHooks())

    assert.is_true(scope:Hook(target, "Method2", noop))
    local installed, reason = scope:Hook(target, "Method1", noop)
    assert.is_nil(installed)
    assert.are.equal("full", reason)
  end)

  it("refuses an addon scope at the caller's line", function()
    local scope = HookKit:ForAddon("MyAddon")
    HookKit:CloseAddonScopes("MyAddon")

    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      scope:Reopen()
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE .. ":" .. line .. ": HookKit.Scope:Reopen cannot reopen an addon scope",
      message
    )
    assert.is_true(scope:IsClosed())
  end)

  it("refuses receivers that are not HookKit scopes", function()
    local receivers = { "scope", 1, {}, setmetatable({}, {}) }
    for index = 1, #receivers do
      local ok, message = pcall(HookKit.Scope.Reopen, receivers[index])
      assert.is_false(ok)
      assert.is_truthy(
        string.find(message, "HookKit.Scope:Reopen must be called on a HookKit scope", 1, true)
      )
    end
  end)

  it("reopens a scope the previous revision closed, after the upgrade", function()
    local scope = HookKit:CreateScope()
    scope:Close()
    local upgraded = TestEnv.LoadRevision(HookKit.REVISION + 1)
    assert.are.equal(HookKit, upgraded)
    assert.is_true(scope:Reopen())
    assert.is_true(scope:Hook(withMethods({}, 1), "Method1", noop))
  end)
end)
