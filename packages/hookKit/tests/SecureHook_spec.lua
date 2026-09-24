local TestEnv = require("HookKitTestEnv")

local GLOBAL_NAME = "HookKitSpecSecureGlobal"

describe("HookKit secure post-hooks", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(function()
    TestEnv.SetGlobal(GLOBAL_NAME, nil)
    TestEnv.Reset()
  end)

  it("runs the handler after the original with the same arguments", function()
    local order = {}
    local target = {}
    function target:Method(first, second)
      order[#order + 1] = "original"
      return first + second, "second result"
    end
    local scope = HookKit:CreateScope()

    assert.is_true(scope:SecureHook(target, "Method", function(receiver, first, second)
      assert.are.equal(target, receiver)
      order[#order + 1] = "handler " .. first .. " " .. second
    end))

    local sum, text = target:Method(2, 3)
    assert.are.equal(5, sum)
    assert.are.equal("second result", text)
    assert.are.same({ "original", "handler 2 3" }, order)
    assert.is_true((scope:IsHooked(target, "Method")))
    assert.are.equal("secure", select(2, scope:IsHooked(target, "Method")))
  end)

  it("hooks a global by name", function()
    local seen = nil
    TestEnv.SetGlobal(GLOBAL_NAME, function(value)
      return value * 2
    end)
    local scope = HookKit:CreateScope()
    scope:SecureHook(GLOBAL_NAME, function(value)
      seen = value
    end)

    assert.are.equal(8, TestEnv.GetGlobal(GLOBAL_NAME)(4))
    assert.are.equal(4, seen)
    assert.is_true((scope:IsHooked(GLOBAL_NAME)))
  end)

  it("keeps a secure target secure", function()
    local target = {}
    target.Method = TestEnv.MarkSecure(function() end)
    HookKit:CreateScope():SecureHook(target, "Method", function() end)
    assert.is_true(TestEnv.GetGlobal("issecurevariable")(target, "Method"))
  end)

  it("turns the closure inert on Unhook and leaves it installed", function()
    local calls = 0
    local target = {
      Method = function()
        return "original"
      end,
    }
    local scope = HookKit:CreateScope()
    scope:SecureHook(target, "Method", function()
      calls = calls + 1
    end)
    local installed = target.Method

    assert.is_true(scope:Unhook(target, "Method"))
    assert.is_false(scope:Unhook(target, "Method"))
    assert.are.equal(installed, target.Method)
    assert.are.equal("original", target.Method())
    assert.are.equal(0, calls)
    assert.is_false((scope:IsHooked(target, "Method")))
    assert.is_nil(scope:Original(target, "Method"))
  end)

  it("hooks the same method again after Unhook with a new closure", function()
    local calls = {}
    local target = { Method = function() end }
    local scope = HookKit:CreateScope()
    scope:SecureHook(target, "Method", function()
      calls[#calls + 1] = "first"
    end)
    scope:Unhook(target, "Method")
    scope:SecureHook(target, "Method", function()
      calls[#calls + 1] = "second"
    end)

    target.Method()
    assert.are.same({ "second" }, calls)
  end)

  it("reports a handler error without breaking the host call", function()
    local target = {
      Method = function()
        return "original"
      end,
    }
    HookKit:CreateScope():SecureHook(target, "Method", function()
      error("handler failed", 0)
    end)

    assert.are.equal("original", target.Method())
    assert.are.same({ "handler failed" }, TestEnv.ReportedErrors())
  end)

  it("post-hooks a frame script with HookScript and makes it inert on Unhook", function()
    local calls = {}
    local frame = TestEnv.NewFrame()
    frame:SetScript("OnShow", function()
      calls[#calls + 1] = "script"
    end)
    local scope = HookKit:CreateScope()
    scope:SecureHookScript(frame, "OnShow", function(receiver, argument)
      assert.are.equal(frame, receiver)
      calls[#calls + 1] = "handler " .. argument
    end)

    TestEnv.RunScript(frame, "OnShow", "x")
    assert.are.same({ "script", "handler x" }, calls)
    assert.are.equal("secureScript", select(2, scope:IsHooked(frame, "OnShow")))

    assert.is_true(scope:Unhook(frame, "OnShow"))
    TestEnv.RunScript(frame, "OnShow", "y")
    assert.are.same({ "script", "handler x", "script" }, calls)
  end)

  it("allows a secure script hook of a protected script on a protected frame", function()
    local calls = 0
    local frame = TestEnv.NewFrame({ protected = true })
    HookKit:CreateScope():SecureHookScript(frame, "OnClick", function()
      calls = calls + 1
    end)
    TestEnv.RunScript(frame, "OnClick")
    assert.are.equal(1, calls)
  end)

  it("refuses without hooksecurefunc and a frame without HookScript", function()
    local WithoutHost = TestEnv.NewPackageWithoutHookApi()
    local scope = WithoutHost:CreateScope()
    TestEnv.expectErrorContaining(
      "HookKit.Scope:SecureHook requires the host's hooksecurefunc",
      function()
        scope:SecureHook({ Method = function() end }, "Method", function() end)
      end
    )
    TestEnv.expectErrorContaining(
      "HookKit.Scope:SecureHookScript frame must have a HookScript method",
      function()
        scope:SecureHookScript({}, "OnShow", function() end)
      end
    )
    assert.are.equal(0, scope:GetActiveCount())
  end)
end)
