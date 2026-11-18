-- The shared helper blocks TooltipKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local TestEnv = require("TooltipKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 2 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table TooltipKit
local function loadRevision2()
  local path = FIXTURE_DIRECTORY .. "TooltipKit-revision2.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---What `TooltipKitTestEnv.NewPackage` arranges after the module chain loads.
local function prepareHost()
  local uiParent = TestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
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

describe("TooltipKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local TooltipKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    -- A newer copy loaded while the probe is installed resolves it at load.
    TooltipKit = TestEnv.LoadRevision(TooltipKit.REVISION + 1)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxTooltips must not be a secret value", function()
      TooltipKit:SetLimits({ maxTooltips = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local TooltipKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxTooltips must not be a secret value", function()
      TooltipKit:SetLimits({ maxTooltips = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local TooltipKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "TooltipKit:GetLimits must be called on the TooltipKit facade; use TooltipKit:GetLimits(...)",
      function()
        TooltipKit.GetLimits({})
      end
    )
  end)

  it("prints a line script that raises when the host error handler raises", function()
    local TooltipKit = TestEnv.NewPackage()
    local printed, restore = installRaisingHandler()
    local tooltip = TooltipKit:Acquire("MyAddon", 1)
    local line = tooltip:AddLine("x")
    tooltip:SetLineScript(line, "OnEnter", function()
      error("enter failed", 0)
    end)
    local lineFrame = TooltipKit._state.records[tooltip].lines[line].frame
    local ok = pcall(TestEnv.Run, lineFrame, "OnEnter")
    restore()
    assert.is_true(ok, "the failure reached the caller of the script")
    assert.are.same({ "enter failed" }, printed)
  end)

  it("upgrades in place over revision 2, keeping what the older copy made", function()
    TestEnv.NewPackageWithout("TooltipKit")
    local older = loadRevision2()
    prepareHost()
    assert.are.equal(2, older.REVISION)
    older:Acquire("MyAddon", 1):AddLine("kept")
    older:SetLimits({ maxTooltips = 50 })

    local Kit = require("TooltipKit")
    assert.are.equal(older, Kit)
    assert.are.equal(3, Kit.REVISION)
    assert.are.equal(50, Kit:GetLimits().maxTooltips)
    assert.is_true(Kit:IsAcquired("MyAddon"))
  end)
end)
