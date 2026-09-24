local TestEnv = require("HookKitTestEnv")

describe("HookKit scopes", function()
  local HookKit
  before_each(function()
    HookKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("refuses a second hook of the same target in one scope", function()
    local target = { Method = function() end }
    local scope = HookKit:CreateScope()
    scope:Hook(target, "Method", function() end)
    TestEnv.expectErrorContaining(
      'HookKit.Scope:SecureHook "Method" is already hooked in this scope; Unhook it first',
      function()
        scope:SecureHook(target, "Method", function() end)
      end
    )
    assert.is_true(HookKit:CreateScope():Hook(target, "Method", function() end))
  end)

  it("refuses a target that is not a function", function()
    local scope = HookKit:CreateScope()
    TestEnv.expectErrorContaining(
      'HookKit.Scope:Hook target "Missing" is not a function',
      function()
        scope:Hook({}, "Missing", function() end)
      end
    )
    TestEnv.expectErrorContaining(
      'HookKit.Scope:RawHook target "Value" is not a function',
      function()
        scope:RawHook({ Value = 1 }, "Value", function() end)
      end
    )
  end)

  it("returns nil, full beyond MAX_HOOKS and frees room on Unhook", function()
    local scope = HookKit:CreateScope()
    local target = {}
    for index = 1, HookKit.MAX_HOOKS + 1 do
      target["Method" .. index] = function() end
    end
    for index = 1, HookKit.MAX_HOOKS do
      assert.is_true(scope:Hook(target, "Method" .. index, function() end))
    end

    local extra = "Method" .. (HookKit.MAX_HOOKS + 1)
    local extraOriginal = target[extra]
    local installed, reason = scope:Hook(target, extra, function() end)
    assert.is_nil(installed)
    assert.are.equal("full", reason)
    assert.are.equal(extraOriginal, rawget(target, extra))
    assert.are.equal(HookKit.MAX_HOOKS, scope:GetActiveCount())

    scope:Unhook(target, "Method1")
    assert.is_true(scope:Hook(target, extra, function() end))
  end)

  it("reports hooks in creation order with their kinds", function()
    local target = { A = function() end, B = function() end, C = function() end }
    local frame = TestEnv.NewFrame()
    local scope = HookKit:CreateScope()
    scope:RawHook(target, "C", function() end)
    scope:SecureHookScript(frame, "OnShow", function() end)
    scope:Hook(target, "A", function() end)
    scope:SecureHook(target, "B", function() end)
    scope:HookScript(frame, "OnHide", function() end)
    scope:RawHookScript(frame, "OnEnter", function() end)

    assert.are.same({
      { object = target, method = "C", kind = "rawHook" },
      { object = frame, method = "OnShow", kind = "secureScript" },
      { object = target, method = "A", kind = "hook" },
      { object = target, method = "B", kind = "secure" },
      { object = frame, method = "OnHide", kind = "hookScript" },
      { object = frame, method = "OnEnter", kind = "rawHookScript" },
    }, scope:Hooks())
    assert.are_not.equal(scope:Hooks(), scope:Hooks())
    assert.are.equal(6, scope:GetActiveCount())
    assert.is_false((scope:IsHooked(target, "Missing")))
    assert.is_false((scope:IsHooked({}, "A")))
  end)

  it("does not create records when asked about an unknown object", function()
    local scope = HookKit:CreateScope()
    scope:IsHooked({}, "Method")
    scope:Original({}, "Method")
    scope:Unhook({}, "Method")
    assert.is_nil(next(rawget(scope, "_records")))
  end)

  it("undoes every hook with UnhookAll and stays usable", function()
    local target = { A = function() end, B = function() end }
    local originalA, originalB = target.A, target.B
    local scope = HookKit:CreateScope()
    scope:Hook(target, "A", function() end)
    scope:RawHook(target, "B", function() end)

    assert.are.equal(2, scope:UnhookAll())
    assert.are.equal(originalA, target.A)
    assert.are.equal(originalB, target.B)
    assert.are.same({}, scope:Hooks())
    assert.are.equal(0, scope:UnhookAll())
    assert.is_true(scope:Hook(target, "A", function() end))
  end)

  it("attempts every release and re-raises the first failure", function()
    local frame = TestEnv.NewFrame()
    local target = { A = function() end }
    local scope = HookKit:CreateScope()
    scope:HookScript(frame, "OnShow", function() end)
    scope:Hook(target, "A", function() end)
    local originalA = scope:Original(target, "A")
    frame.SetScript = function()
      error("set failed", 0)
    end

    local ok, value = pcall(scope.UnhookAll, scope)
    assert.is_false(ok)
    assert.are.equal("set failed", value)
    assert.are.equal(originalA, target.A)
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("closes terminally and refuses new hooks at the caller", function()
    local target = { A = function() end }
    local original = target.A
    local scope = HookKit:CreateScope()
    scope:Hook(target, "A", function() end)

    assert.is_true(scope:Close())
    assert.is_false(scope:Close())
    assert.is_true(scope:IsClosed())
    assert.are.equal(original, target.A)
    for _, method in ipairs({ "Hook", "RawHook", "SecureHook" }) do
      TestEnv.expectErrorContaining(
        "HookKit.Scope:" .. method .. " cannot hook in a closed scope",
        function()
          scope[method](scope, target, "A", function() end)
        end
      )
    end
    local frame = TestEnv.NewFrame()
    for _, method in ipairs({ "HookScript", "RawHookScript", "SecureHookScript" }) do
      TestEnv.expectErrorContaining(
        "HookKit.Scope:" .. method .. " cannot hook in a closed scope",
        function()
          scope[method](scope, frame, "OnShow", function() end)
        end
      )
    end
    assert.is_false(scope:Unhook(target, "A"))
    assert.are.equal(0, scope:UnhookAll())
  end)

  it("keeps one canonical scope per addon, closed by CloseAddonScopes", function()
    local scope = HookKit:ForAddon("MyAddon")
    assert.are.equal(scope, HookKit:ForAddon("MyAddon"))
    assert.are.equal("MyAddon", scope:GetAddonName())
    assert.is_nil(HookKit:CreateScope():GetAddonName())

    local target = { A = function() end }
    local original = target.A
    scope:Hook(target, "A", function() end)
    assert.is_true(HookKit:CloseAddonScopes("MyAddon"))
    assert.is_false(HookKit:CloseAddonScopes("MyAddon"))
    assert.are.equal(original, target.A)
    assert.are.equal(scope, HookKit:ForAddon("MyAddon"))
    assert.is_true(scope:IsClosed())
  end)

  it("records nothing for an addon that never asked for a scope", function()
    assert.is_false(HookKit:CloseAddonScopes("Quiet"))
    assert.is_nil(rawget(rawget(HookKit, "_state").addonScopes, "Quiet"))
    assert.is_false(HookKit:ForAddon("Quiet"):IsClosed())
  end)

  it("refuses the package methods called without the facade", function()
    TestEnv.expectErrorContaining(
      "HookKit:ForAddon must be called on the HookKit facade; use HookKit:ForAddon(...)",
      function()
        HookKit.ForAddon("MyAddon")
      end
    )
    TestEnv.expectErrorContaining(
      "HookKit:CloseAddonScopes must be called on the HookKit facade",
      function()
        HookKit.CloseAddonScopes({}, "MyAddon")
      end
    )
  end)

  it("never closes a manual scope through CloseAddonScopes", function()
    local manual = HookKit:CreateScope()
    HookKit:CloseAddonScopes("MyAddon")
    assert.is_false(manual:IsClosed())
  end)

  it("does not keep a hooked table alive", function()
    local scope = HookKit:CreateScope()
    local target = { A = function() end }
    scope:Hook(target, "A", function() end)
    local probe = setmetatable({ target }, { __mode = "v" })
    target = nil
    collectgarbage()
    collectgarbage()
    assert.is_nil(probe[1])
    assert.are.equal(0, scope:GetActiveCount())
  end)
end)
