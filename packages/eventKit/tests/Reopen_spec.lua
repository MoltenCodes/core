-- `Scope:Reopen`: a closed manual scope opened again, empty, so its owner
-- keeps the same object (ModuleKit's module scopes across enable cycles).
local TestEnv = require("EventKitTestEnv")

local SPEC_FILE = "packages/eventKit/tests/Reopen_spec.lua:"

local function noop() end

---Assert that `callback` fails with `expected` at a line of this spec file.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
end

describe("EventKit Scope:Reopen", function()
  local EventKit

  before_each(function()
    EventKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reopens a closed manual scope, empty and usable", function()
    local scope = EventKit:CreateScope()
    local before = scope:Connect("BAG_UPDATE", noop)
    assert.is_true(scope:Close())

    assert.is_true(scope:Reopen())

    assert.is_false(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_false(before:IsConnected())
    local calls = 0
    local after = scope:Connect("BAG_UPDATE", function()
      calls = calls + 1
    end)
    TestEnv.Emit("BAG_UPDATE")
    assert.are.equal(1, calls)
    assert.are.equal(1, scope:GetActiveCount())
    assert.is_true(scope:Close())
    assert.is_false(after:IsConnected())
  end)

  it("answers false for an open scope", function()
    local scope = EventKit:CreateScope()
    scope:Connect("BAG_UPDATE", noop)
    assert.is_false(scope:Reopen())
    assert.are.equal(1, scope:GetActiveCount())
  end)

  it("refuses an addon scope at the caller's line", function()
    local scope = EventKit:ForAddon("MyAddon")
    EventKit:CloseAddonScopes("MyAddon")
    expectRefusalAtCaller("EventKit.Scope:Reopen cannot reopen an addon scope", function()
      scope:Reopen()
    end)
    assert.is_true(scope:IsClosed())
  end)

  it("refuses a receiver that is not a scope at the caller's line", function()
    expectRefusalAtCaller("EventKit.Scope:Reopen must be called on an EventKit scope", function()
      EventKit.Scope.Reopen({})
    end)
  end)

  it("sweeps only what the scope held when it was closed during a dispatch", function()
    local scope = EventKit:CreateScope()
    local deliveries = {}
    local first = scope:Connect("BAG_UPDATE", function()
      deliveries[#deliveries + 1] = "first"
    end)
    local reconnected
    EventKit:Connect("BAG_UPDATE", function()
      if reconnected == nil then
        scope:Close()
        assert.is_true(scope:Reopen())
        reconnected = scope:Connect("BAG_UPDATE", function()
          deliveries[#deliveries + 1] = "reconnected"
        end)
      end
    end)
    local held = scope:Connect("BAG_UPDATE", function()
      deliveries[#deliveries + 1] = "held"
    end)

    TestEnv.Emit("BAG_UPDATE")

    -- The dispatch in flight still reached `held`; the sweep then released
    -- the two connections of the closed period and kept the new one.
    assert.are.same({ "first", "held" }, deliveries)
    assert.is_false(first:IsConnected())
    assert.is_false(held:IsConnected())
    assert.is_true(reconnected:IsConnected())
    assert.are.equal(1, scope:GetActiveCount())

    TestEnv.Emit("BAG_UPDATE")
    assert.are.same({ "first", "held", "reconnected" }, deliveries)
  end)

  it("releases a Coalesce or Derive handle with the rest of a deferred sweep", function()
    local Scheduled = TestEnv.Scheduled
    Scheduled.Reset()
    EventKit = Scheduled.NewEventKit()
    local scope = EventKit:CreateScope()
    local derived = scope:Derive("BAG_UPDATE", function()
      return 1
    end)
    EventKit:Connect("PLAYER_LOGIN", function()
      scope:Close()
      scope:Reopen()
    end)

    Scheduled.Emit("PLAYER_LOGIN")

    assert.is_true(derived:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_false(scope:IsClosed())
    Scheduled.Reset()
  end)
end)
