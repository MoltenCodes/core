-- The shared helper blocks BarKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local TestEnv = require("BarKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 2 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table BarKit
local function loadRevision2()
  local path = FIXTURE_DIRECTORY .. "BarKit-revision2.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---What `BarKitTestEnv.NewPackage` arranges after the module chain loads.
local function prepareHost()
  local uiParent = TestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  TestEnv.SetGlobal("GetTime", function()
    return 100
  end)
end

---Replace the host error handler with one that raises, and `print` with a
---recorder; answer the printed values and a function that restores `print`.
---@return any[] printed
---@return fun() restore
local function installRaisingHandler()
  TestEnv.SetGlobal("geterrorhandler", function()
    return function()
      error("the error handler itself failed", 0)
    end
  end)
  local printed = {}
  local originalPrint = TestEnv.GetGlobal("print")
  TestEnv.SetGlobal("print", function(value)
    printed[#printed + 1] = value
  end)
  return printed, function()
    TestEnv.SetGlobal("print", originalPrint)
  end
end

describe("BarKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local BarKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    -- A newer copy loaded while the probe is installed resolves it at load.
    BarKit = TestEnv.LoadRevision(BarKit.REVISION + 1)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxBars must not be a secret value", function()
      BarKit:SetLimits({ maxBars = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local BarKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxBars must not be a secret value", function()
      BarKit:SetLimits({ maxBars = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local BarKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "BarKit:GetLimits must be called on the BarKit facade; use BarKit:GetLimits(...)",
      function()
        BarKit.GetLimits({})
      end
    )
  end)

  it("prints a timer's raising onFinished when the host error handler raises", function()
    local BarKit = TestEnv.NewPackage()
    local printed, restore = installRaisingHandler()
    local bar = BarKit:Acquire()
    bar:Start(1, {
      onFinished = function()
        error("finished failed", 0)
      end,
    })
    local ok = pcall(TestEnv.Advance, bar:GetFrame(), 2)
    restore()
    assert.is_true(ok, "the failure reached the caller of the script")
    assert.are.same({ "finished failed" }, printed)
  end)

  it("upgrades in place over revision 2, keeping what the older copy made", function()
    TestEnv.NewPackageWithout("BarKit")
    local older = loadRevision2()
    prepareHost()
    assert.are.equal(2, older.REVISION)
    local bar = older:Acquire()
    bar:SetLabel("kept")
    older:SetLimits({ maxBars = 100 })

    local Kit = require("BarKit")
    assert.are.equal(older, Kit)
    assert.are.equal(3, Kit.REVISION)
    assert.are.equal(100, Kit:GetLimits().maxBars)
    bar:SetLabel("after")
    assert.are.equal("after", bar:GetFrame().label:GetText())
  end)
end)
