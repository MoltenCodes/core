local TestEnv = require("HookKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

-- Every hook method takes a receiver table in the handler's place, then an
-- optional handler name that defaults to the hooked name, as AceHook's
-- `self:Hook(object, "Method"[, "Handler"])` does. The method must exist when
-- the hook is made; it is looked up on the receiver at every call.

---Assert that `action` raises `message` at the line `mark` points after.
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

describe("HookKit method-name handlers", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("pre-hooks with the receiver's method named after the hooked method by default", function()
    local calls = {}
    local target = {
      Refresh = function(_, reason)
        calls[#calls + 1] = "original " .. reason
        return "done"
      end,
    }
    local receiver = {}
    function receiver:Refresh(object, reason)
      assert.are.equal(receiver, self)
      calls[#calls + 1] = "handler " .. reason
      assert.are.equal(target, object)
    end
    local scope = HookKit:CreateScope()

    assert.is_true(scope:Hook(target, "Refresh", receiver))
    assert.are.equal("done", target:Refresh("now"))
    assert.are.same({ "handler now", "original now" }, calls)
  end)

  it("takes an explicit handler name and options after the receiver", function()
    local target = { Method = function() end }
    local receiver = { seen = 0 }
    function receiver:OnMethod()
      self.seen = self.seen + 1
    end
    local scope = HookKit:CreateScope()

    assert.is_true(scope:Hook(target, "Method", receiver, "OnMethod", { forceSecure = false }))
    target.Method()
    assert.are.equal(1, receiver.seen)

    -- The options may follow the receiver directly; the name then defaults.
    local other = { Method = function() end }
    local defaulted = { seen = 0 }
    function defaulted:Method()
      self.seen = self.seen + 1
    end
    assert.is_true(scope:Hook(other, "Method", defaulted, { forceSecure = false }))
    other.Method()
    assert.are.equal(1, defaulted.seen)
  end)

  it("passes the original first to a raw handler method", function()
    local target = {
      Format = function(_, value)
        return "<" .. value .. ">"
      end,
    }
    local receiver = {}
    function receiver:Format(original, object, value)
      assert.are.equal(receiver, self)
      return "[" .. original(object, value) .. "]"
    end
    local scope = HookKit:CreateScope()

    scope:RawHook(target, "Format", receiver)
    assert.are.equal("[<x>]", target:Format("x"))
  end)

  it("hooks globals, secure targets and scripts with a receiver", function()
    local calls = {}
    TestEnv.SetGlobal("MyGlobalFunction", function()
      calls[#calls + 1] = "global"
    end)
    local receiver = {}
    function receiver:MyGlobalFunction()
      calls[#calls + 1] = "pre"
    end
    function receiver:AfterGlobal()
      calls[#calls + 1] = "post"
    end
    function receiver:OnShow(frame)
      calls[#calls + 1] = "show " .. tostring(frame ~= nil)
    end
    function receiver:Shown()
      calls[#calls + 1] = "shown"
    end
    function receiver:OnHide(previous, frame)
      calls[#calls + 1] = "hide " .. tostring(previous == nil) .. " " .. tostring(frame ~= nil)
    end
    local frame = TestEnv.NewFrame()
    local scope = HookKit:CreateScope()

    assert.is_true(scope:Hook("MyGlobalFunction", receiver))
    local secureScope = HookKit:CreateScope()
    assert.is_true(secureScope:SecureHook("MyGlobalFunction", receiver, "AfterGlobal"))
    assert.is_true(scope:HookScript(frame, "OnShow", receiver))
    assert.is_true(secureScope:SecureHookScript(frame, "OnShow", receiver, "Shown"))
    assert.is_true(scope:RawHookScript(frame, "OnHide", receiver))

    TestEnv.GetGlobal("MyGlobalFunction")()
    TestEnv.RunScript(frame, "OnShow")
    TestEnv.RunScript(frame, "OnHide")
    assert.are.same({ "pre", "global", "post", "show true", "shown", "hide true true" }, calls)
  end)

  it("looks the method up at every call, so a later replacement runs", function()
    local target = { Method = function() end }
    local receiver = {}
    local seen = {}
    function receiver:Method()
      seen[#seen + 1] = "first"
    end
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", receiver)

    target.Method()
    function receiver:Method()
      seen[#seen + 1] = "second"
    end
    target.Method()
    assert.are.same({ "first", "second" }, seen)
  end)

  it("reports a method gone by call time and still runs the original", function()
    local ran = 0
    local target = {
      Method = function()
        ran = ran + 1
      end,
    }
    local receiver = { Method = function() end }
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", receiver)
    TestEnv.TakeReportedErrors()

    receiver.Method = nil
    target.Method()

    assert.are.equal(1, ran)
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_truthy(
      string.find(
        tostring(reported[1].value),
        'HookKit.Scope:Hook receiver has no method "Method"',
        1,
        true
      )
    )
    assert.is_true(scope:IsHooked(target, "Method"))
  end)

  it("propagates a raw handler method gone by call time", function()
    local target = { Method = function() end }
    local receiver = { Method = function() end }
    local scope = HookKit:CreateScope()
    scope:RawHook(target, "Method", receiver)

    receiver.Method = nil
    local ok, message = pcall(target.Method)
    assert.is_false(ok)
    assert.is_truthy(
      string.find(message, 'HookKit.Scope:RawHook receiver has no method "Method"', 1, true)
    )
  end)

  it(
    "refuses a missing or non-function method, an empty name and stray options at the caller",
    function()
      local target = { Method = function() end }
      local receiver = { Value = 1 }
      local scope = HookKit:CreateScope()

      assertReportedAtCaller('HookKit.Scope:Hook receiver has no method "Method"', function(mark)
        mark()
        scope:Hook(target, "Method", receiver)
      end)
      assertReportedAtCaller('HookKit.Scope:RawHook receiver has no method "Value"', function(mark)
        mark()
        scope:RawHook(target, "Method", receiver, "Value")
      end)
      assertReportedAtCaller(
        "HookKit.Scope:SecureHook handlerName must be a non-empty string",
        function(mark)
          mark()
          scope:SecureHook(target, "Method", receiver, "")
        end
      )
      -- After a receiver, anything but a string is the option table.
      receiver.OnShow = function() end
      assertReportedAtCaller("HookKit.Scope:HookScript options must be a table", function(mark)
        mark()
        scope:HookScript(TestEnv.NewFrame(), "OnShow", receiver, 7)
      end)
      assertReportedAtCaller(
        "HookKit.Scope:Hook handler must be a function, or a receiver table followed by an optional handler name",
        function(mark)
          mark()
          scope:Hook(target, "Method", "OnMethod")
        end
      )
      assert.are.equal(0, scope:GetActiveCount())
    end
  )

  it("refuses a secret handler name at the caller before comparing it", function()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == "SecretName"
    end)
    local target = { Method = function() end }
    local scope = HookKit:CreateScope()

    assertReportedAtCaller(
      "HookKit.Scope:Hook handlerName must not be a secret value",
      function(mark)
        mark()
        scope:Hook(target, "Method", {}, "SecretName")
      end
    )
  end)
end)
