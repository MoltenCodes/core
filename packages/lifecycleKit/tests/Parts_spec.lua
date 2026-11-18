local TestEnv = require("LifecycleKitTestEnv")

-- The core and its two parts (docs/API.md, "Parts"): without a part its
-- members raise at the caller's line with the file to embed, `HasPart` answers
-- for each, and what stays in the core works alone.

local SPEC_FILE = "packages/lifecycleKit/tests/Parts_spec.lua:"

---Assert that `callback` fails at a line of this spec file with `expected`.
---@param expected string
---@param callback fun()
local function expectAtCaller(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)
  assert.is_false(ok)
  assert.is_not_nil(string.find(message, expected, 1, true), message)
  assert.is_not_nil(string.find(message, SPEC_FILE, 1, true), message)
end

---The refusal a stub of `partName` raises for `label`.
---@param label string
---@param partName string
---@return string
local function stubMessage(label, partName)
  return label
    .. " is in LifecycleKit's "
    .. partName
    .. " part, which is not loaded: add lifecycleKit\\parts\\LifecycleKit-"
    .. partName
    .. ".lua to embeds.xml after lifecycleKit\\LifecycleKit.lua"
end

describe("LifecycleKit without its parts", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewCore()
  end)
  after_each(TestEnv.Reset)

  it("answers HasPart false for both parts", function()
    assert.is_false(LifecycleKit:HasPart("CombatGate"))
    assert.is_false(LifecycleKit:HasPart("Halt"))
    assert.is_false(LifecycleKit:HasPart("Elsewhere"))
  end)

  it("raises HasPart's argument error at the caller", function()
    expectAtCaller("LifecycleKit:HasPart name must be a part name string", function()
      LifecycleKit:HasPart(42)
    end)
  end)

  it("raises every CombatGate member at the caller, naming the file", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local noop = function() end
    expectAtCaller(stubMessage("LifecycleKit:IsInCombat", "CombatGate"), function()
      LifecycleKit:IsInCombat()
    end)
    for _, name in ipairs({ "WhenOutOfCombat", "OnCombatStart", "OnCombatEnd" }) do
      expectAtCaller(stubMessage("LifecycleKit.Instance:" .. name, "CombatGate"), function()
        life[name](life, noop)
      end)
    end
    expectAtCaller(
      stubMessage("LifecycleKit.Instance:SetCombatQueueLimit", "CombatGate"),
      function()
        life:SetCombatQueueLimit(8)
      end
    )
    expectAtCaller(
      stubMessage("LifecycleKit.Instance:GetCombatQueueLimit", "CombatGate"),
      function()
        life:GetCombatQueueLimit()
      end
    )
    local call = setmetatable({}, { __index = LifecycleKit.DeferredCall })
    expectAtCaller(stubMessage("LifecycleKit.DeferredCall:Cancel", "CombatGate"), function()
      call:Cancel()
    end)
    expectAtCaller(stubMessage("LifecycleKit.DeferredCall:IsPending", "CombatGate"), function()
      call:IsPending()
    end)
  end)

  it("raises every Halt member at the caller, naming the file", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    expectAtCaller(stubMessage("LifecycleKit.Instance:Halt", "Halt"), function()
      life:Halt("broken")
    end)
    expectAtCaller(stubMessage("LifecycleKit.Instance:DependsOn", "Halt"), function()
      life:DependsOn("Other")
    end)
    expectAtCaller(stubMessage("LifecycleKit.Instance:OnDependencyHalted", "Halt"), function()
      life:OnDependencyHalted(function() end)
    end)
  end)

  it("runs every phase and closes the addon's event scope", function()
    local EventKit = require("EventKit")
    local life = LifecycleKit:ForAddon("MyAddon")
    local scope = EventKit:ForAddon("MyAddon")
    local seen = {}
    life:OnLoaded(function()
      seen[#seen + 1] = "loaded"
    end)
    life:OnReady(function()
      seen[#seen + 1] = "ready"
    end)
    life:OnShutdown(function()
      seen[#seen + 1] = "shutdown"
    end)

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    TestEnv.Logout()

    assert.are.same({ "loaded", "ready", "shutdown" }, seen)
    assert.is_true(scope:IsClosed())
  end)

  it("hands out an OnHalted subscription that never fires and ends at shutdown", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local calls = 0
    local subscription = life:OnHalted(function()
      calls = calls + 1
    end)
    assert.is_true(subscription:IsConnected())
    assert.is_false(life:IsHalted())
    assert.is_nil(life:GetHaltReason())

    TestEnv.Logout()

    assert.are.equal(0, calls)
    assert.is_false(subscription:IsConnected())
  end)

  it("keeps SetLimits and GetLimits for both limits", function()
    LifecycleKit:SetLimits({ maxDependencies = 4, defaultCombatQueueLimit = LifecycleKit.UNBOUNDED })
    assert.are.same(
      { maxDependencies = 4, defaultCombatQueueLimit = LifecycleKit.UNBOUNDED },
      LifecycleKit:GetLimits()
    )
  end)

  it("installs no combat watcher", function()
    LifecycleKit:ForAddon("MyAddon")
    local watchers = rawget(LifecycleKit, "_state").globalWatchers
    assert.is_nil(watchers.combatStart)
    assert.is_nil(watchers.combatEnd)
  end)
end)

describe("LifecycleKit parts loaded after the core", function()
  after_each(TestEnv.Reset)

  it("answers HasPart true and replaces the stubs", function()
    local LifecycleKit = TestEnv.NewPackage()
    assert.is_true(LifecycleKit:HasPart("CombatGate"))
    assert.is_true(LifecycleKit:HasPart("Halt"))
    assert.is_false(LifecycleKit:IsInCombat())
  end)

  it("serves an instance created before the parts loaded", function()
    local LifecycleKit = TestEnv.NewCore()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.LoadParts()

    local starts = 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)
    TestEnv.EnterCombat()
    assert.is_true(LifecycleKit:IsInCombat())
    assert.are.equal(1, starts)
    assert.are.equal(64, life:GetCombatQueueLimit())
    assert.is_true(life:Halt("broken"))
    assert.are.equal("halted", life:GetState())
  end)

  it("keeps its members across a reload of the core", function()
    local LifecycleKit = TestEnv.NewPackage()
    local whenOutOfCombat = LifecycleKit.Instance.WhenOutOfCombat
    local halt = LifecycleKit.Instance.Halt
    TestEnv.ReloadPackage()
    assert.are.equal(whenOutOfCombat, LifecycleKit.Instance.WhenOutOfCombat)
    assert.are.equal(halt, LifecycleKit.Instance.Halt)
  end)

  it("loads an equal part revision a second time without effect", function()
    local LifecycleKit = TestEnv.NewPackage()
    local halt = LifecycleKit.Instance.Halt
    package.loaded["LifecycleKit-Halt"] = nil
    assert.are.equal(LifecycleKit, require("LifecycleKit-Halt"))
    assert.are.equal(halt, LifecycleKit.Instance.Halt)
  end)

  it("loads an equal CombatGate revision a second time without a second watcher", function()
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local whenOutOfCombat = LifecycleKit.Instance.WhenOutOfCombat
    package.loaded["LifecycleKit-CombatGate"] = nil
    assert.are.equal(LifecycleKit, require("LifecycleKit-CombatGate"))
    assert.are.equal(whenOutOfCombat, LifecycleKit.Instance.WhenOutOfCombat)

    local starts = 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)
    TestEnv.EnterCombat()
    assert.are.equal(1, starts)
  end)

  it("replaces an older CombatGate revision's watchers with its own", function()
    local LifecycleKit = TestEnv.NewPackage()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local starts, ends = 0, 0
    life:OnCombatStart(function()
      starts = starts + 1
    end)
    life:OnCombatEnd(function()
      ends = ends + 1
    end)
    local watchers = LifecycleKit._state.globalWatchers
    local olderStart, olderEnd = watchers.combatStart, watchers.combatEnd

    local path = "packages/lifecycleKit/src/parts/LifecycleKit-CombatGate.lua"
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    local patched, count = source:gsub("local PART_REVISION = 1", "local PART_REVISION = 2", 1)
    assert.are.equal(1, count)
    assert(loadstring(patched, "@" .. path))()
    assert.is_false(olderStart:IsConnected())
    assert.is_false(olderEnd:IsConnected())
    assert.is_true(watchers.combatStart:IsConnected())
    assert.is_true(watchers.combatEnd:IsConnected())

    -- One watcher per event: the older revision's are disconnected, so each
    -- event reaches a subscriber once, through the newer revision's handlers.
    TestEnv.EnterCombat()
    assert.is_true(LifecycleKit:IsInCombat())
    TestEnv.LeaveCombat()
    assert.is_false(LifecycleKit:IsInCombat())
    assert.are.equal(1, starts)
    assert.are.equal(1, ends)
  end)

  it("refuses to load a part before the core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.expectErrorContaining(
      "MoltenCodes LifecycleKit part CombatGate requires LifecycleKit API 1 to be loaded first",
      function()
        require("LifecycleKit-CombatGate")
      end
    )
    TestEnv.expectErrorContaining(
      "MoltenCodes LifecycleKit part Halt requires LifecycleKit API 1 to be loaded first",
      function()
        require("LifecycleKit-Halt")
      end
    )
  end)
end)

describe("LifecycleKit phase lists", function()
  local LifecycleKit
  before_each(function()
    LifecycleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("creates no list until the first subscription", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    assert.is_nil(rawget(life, "_lists"))
    life:OnReady(function() end)
    assert.is_table(rawget(rawget(life, "_lists"), "ready"))
  end)

  it("delivers in subscription order and drops a one-shot list after delivery", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local seen = {}
    for index = 1, 3 do
      life:OnLoaded(function()
        seen[#seen + 1] = index
      end)
    end
    TestEnv.LoadAddon("MyAddon")
    assert.are.same({ 1, 2, 3 }, seen)
    assert.is_nil(rawget(rawget(life, "_lists"), "loaded"))
  end)

  it("makes a notice subscription made during a delivery wait for the next one", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local seen = {}
    life:OnCombatStart(function()
      seen[#seen + 1] = "first"
      life:OnCombatStart(function()
        seen[#seen + 1] = "late"
      end)
    end)

    TestEnv.EnterCombat()
    assert.are.same({ "first" }, seen)
    TestEnv.LeaveCombat()
    TestEnv.EnterCombat()
    assert.are.same({ "first", "first", "late" }, seen)
  end)

  it("takes a disconnect made during a delivery into effect at once", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    TestEnv.LoadAddon("MyAddon")
    local seen = {}
    local second
    life:OnCombatStart(function()
      seen[#seen + 1] = "first"
      second:Disconnect()
    end)
    second = life:OnCombatStart(function()
      seen[#seen + 1] = "second"
    end)

    TestEnv.EnterCombat()
    assert.are.same({ "first" }, seen)
    assert.is_false(second:IsConnected())
  end)

  it("keeps delivering after a raising callback and re-raises the first error", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local seen = {}
    life:OnLoaded(function()
      error("first failed", 0)
    end)
    life:OnLoaded(function()
      seen[#seen + 1] = "second"
    end)

    TestEnv.LoadAddon("MyAddon")

    assert.are.same({ "second" }, seen)
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.are.equal("first failed", reported[1].value)
  end)

  it("removes a disconnected subscription from its list", function()
    local life = LifecycleKit:ForAddon("MyAddon")
    local subscription = life:OnReady(function() end)
    assert.is_true(subscription:Disconnect())
    assert.are.equal(0, #rawget(rawget(life, "_lists"), "ready"))
    assert.is_false(subscription:Disconnect())
  end)
end)
