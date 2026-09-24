local TestEnv = require("HookKitTestEnv")

local GLOBAL_NAME = "HookKitSpecHookGlobal"

---Return a fresh target whose `Method` records its calls and returns several
---values, including a `nil` in the middle.
---@param calls string[]
---@return table target
local function newTarget(calls)
  local target = {}
  function target:Method(value)
    calls[#calls + 1] = "original " .. tostring(value)
    return value, nil, "third"
  end
  return target
end

describe("HookKit safe pre-hooks", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(function()
    TestEnv.SetGlobal(GLOBAL_NAME, nil)
    TestEnv.Reset()
  end)

  it("runs the handler first, then the original, and returns untouched", function()
    local calls = {}
    local target = newTarget(calls)
    local scope = HookKit:CreateScope()
    assert.is_true(scope:Hook(target, "Method", function(receiver, value)
      assert.are.equal(target, receiver)
      calls[#calls + 1] = "handler " .. tostring(value)
      return "ignored"
    end))

    local first, second, third = target:Method(7)
    assert.are.equal(7, first)
    assert.is_nil(second)
    assert.are.equal("third", third)
    assert.are.equal(3, select("#", target:Method(8)))
    assert.are.same({ "handler 7", "original 7", "handler 8", "original 8" }, calls)
    assert.are.equal("hook", select(2, scope:IsHooked(target, "Method")))
  end)

  it("reports a handler error and still runs the original", function()
    local calls = {}
    local target = newTarget(calls)
    HookKit:CreateScope():Hook(target, "Method", function()
      error("handler failed", 0)
    end)

    assert.are.equal(1, (target:Method(1)))
    assert.are.same({ "original 1" }, calls)
    assert.are.same({ "handler failed" }, TestEnv.ReportedErrors())
  end)

  it("restores the original on Unhook when it is still installed", function()
    local calls = {}
    local target = newTarget(calls)
    local original = target.Method
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", function() end)

    assert.are.equal(original, scope:Original(target, "Method"))
    assert.is_true(scope:Unhook(target, "Method"))
    assert.are.equal(original, rawget(target, "Method"))
    assert.is_false((scope:IsHooked(target, "Method")))
  end)

  it("deletes the field on Unhook when the original came through __index", function()
    local frame = TestEnv.NewFrame()
    local inherited = frame.Show
    local scope = HookKit:CreateScope()
    scope:Hook(frame, "Show", function() end, { forceSecure = true })
    assert.are_not.equal(inherited, rawget(frame, "Show"))

    scope:Unhook(frame, "Show")
    assert.is_nil(rawget(frame, "Show"))
    assert.are.equal(inherited, frame.Show)
  end)

  it("keeps a later foreign hook working after our Unhook", function()
    local calls = {}
    local target = newTarget(calls)
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", function()
      calls[#calls + 1] = "ours"
    end)

    -- Another addon hooks after us, by hand, wrapping our closure.
    local ours = target.Method
    local function foreign(...)
      calls[#calls + 1] = "foreign"
      return ours(...)
    end
    target.Method = foreign

    assert.is_true(scope:Unhook(target, "Method"))
    assert.are.equal(foreign, target.Method)

    local first, second, third = target:Method(5)
    assert.are.same({ "foreign", "original 5" }, calls)
    assert.are.equal(5, first)
    assert.is_nil(second)
    assert.are.equal("third", third)
  end)

  it("forwards every argument and result through the inert closure", function()
    local received = nil
    local receivedCount = 0
    local target = {
      Method = function(...)
        received = { ... }
        receivedCount = select("#", ...)
        return ...
      end,
    }
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", function() end)
    local inert = target.Method
    target.Method = function(...)
      return inert(...)
    end
    scope:Unhook(target, "Method")

    local count = select("#", inert(1, nil, 3, nil))
    assert.are.equal(4, count)
    assert.are.equal(4, receivedCount)
    assert.are.equal(1, received[1])
    assert.is_nil(received[2])
    assert.are.equal(3, received[3])
    assert.is_nil(received[4])
  end)

  it("hooks a global by name and restores it", function()
    local calls = {}
    local original = function(value)
      calls[#calls + 1] = "original"
      return value + 1
    end
    TestEnv.SetGlobal(GLOBAL_NAME, original)
    local scope = HookKit:CreateScope()
    scope:Hook(GLOBAL_NAME, function()
      calls[#calls + 1] = "handler"
    end)

    assert.are.equal(3, TestEnv.GetGlobal(GLOBAL_NAME)(2))
    assert.are.same({ "handler", "original" }, calls)
    assert.are.equal(original, scope:Original(GLOBAL_NAME))
    assert.is_true(scope:Unhook(GLOBAL_NAME))
    assert.are.equal(original, TestEnv.GetGlobal(GLOBAL_NAME))
  end)

  it("chains two scopes and unhooks them in either order", function()
    local calls = {}
    local target = newTarget(calls)
    local original = target.Method
    local first = HookKit:CreateScope()
    local second = HookKit:CreateScope()
    first:Hook(target, "Method", function()
      calls[#calls + 1] = "first"
    end)
    second:Hook(target, "Method", function()
      calls[#calls + 1] = "second"
    end)

    target:Method(1)
    assert.are.same({ "second", "first", "original 1" }, calls)

    -- The first scope's closure is wrapped by the second: it goes inert.
    first:Unhook(target, "Method")
    second:Unhook(target, "Method")
    assert.are_not.equal(original, target.Method)
    for index = #calls, 1, -1 do
      calls[index] = nil
    end
    target:Method(2)
    assert.are.same({ "original 2" }, calls)
  end)
end)

describe("HookKit raw replacement", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("passes the original first and returns the handler's results", function()
    local calls = {}
    local target = newTarget(calls)
    local original = target.Method
    local scope = HookKit:CreateScope()
    assert.is_true(scope:RawHook(target, "Method", function(passed, receiver, value)
      assert.are.equal(original, passed)
      assert.are.equal(target, receiver)
      return "replaced", value * 10
    end))

    local first, second = target:Method(3)
    assert.are.equal("replaced", first)
    assert.are.equal(30, second)
    assert.are.same({}, calls)
    assert.are.equal(original, scope:Original(target, "Method"))
    assert.are.equal("rawHook", select(2, scope:IsHooked(target, "Method")))
  end)

  it("lets the handler call the original", function()
    local calls = {}
    local target = newTarget(calls)
    HookKit:CreateScope():RawHook(target, "Method", function(original, receiver, value)
      return original(receiver, value + 1)
    end)
    assert.are.equal(4, (target:Method(3)))
    assert.are.same({ "original 4" }, calls)
  end)

  it("propagates a handler error to the caller", function()
    local target = newTarget({})
    HookKit:CreateScope():RawHook(target, "Method", function()
      error("replacement failed", 0)
    end)
    local ok, value = pcall(target.Method, target, 1)
    assert.is_false(ok)
    assert.are.equal("replacement failed", value)
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("restores on Unhook and forwards through the inert closure otherwise", function()
    local calls = {}
    local target = newTarget(calls)
    local original = target.Method
    local scope = HookKit:CreateScope()
    scope:RawHook(target, "Method", function()
      return "replaced"
    end)
    scope:Unhook(target, "Method")
    assert.are.equal(original, target.Method)

    scope:RawHook(target, "Method", function()
      return "replaced"
    end)
    local inert = target.Method
    target.Method = function(...)
      return inert(...)
    end
    scope:Unhook(target, "Method")
    assert.are.equal(9, (target:Method(9)))
    assert.are.same({ "original 9" }, calls)
  end)
end)
