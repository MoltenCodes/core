-- The shared helper blocks ToastKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 1, whose file is kept verbatim as a fixture.
local TestEnv = require("ToastKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 1 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table ToastKit
local function loadRevision1()
  local path = FIXTURE_DIRECTORY .. "ToastKit-revision1.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---What `ToastKitTestEnv.NewPackage` arranges after the module chain loads.
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

describe("ToastKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local ToastKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    -- A newer copy loaded while the probe is installed resolves it at load.
    ToastKit = TestEnv.LoadRevision(ToastKit.REVISION + 1)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxVisible must not be a secret value", function()
      ToastKit:SetLimits({ maxVisible = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local ToastKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxVisible must not be a secret value", function()
      ToastKit:SetLimits({ maxVisible = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local ToastKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "ToastKit:GetLimits must be called on the ToastKit facade; use ToastKit:GetLimits(...)",
      function()
        ToastKit.GetLimits({})
      end
    )
  end)

  it("prints a toast's raising onClick when the host error handler raises", function()
    local ToastKit = TestEnv.NewPackage()
    local printed, restore = installRaisingHandler()
    local toast = ToastKit:Show({
      title = "y",
      onClick = function()
        error("click failed", 0)
      end,
    })
    local ok = pcall(TestEnv.Run, rawget(toast, "_record").frame, "OnMouseUp", "LeftButton")
    restore()
    assert.is_true(ok, "the failure reached the caller of the script")
    assert.are.same({ "click failed" }, printed)
  end)

  it("upgrades in place over revision 1, keeping what the older copy made", function()
    TestEnv.NewPackageWithout("ToastKit")
    local older = loadRevision1()
    prepareHost()
    assert.are.equal(1, older.REVISION)
    local toast = older:Show({ title = "kept" })
    older:SetLimits({ maxVisible = 3 })

    local Kit = require("ToastKit")
    assert.are.equal(older, Kit)
    assert.are.equal(2, Kit.REVISION)
    assert.are.equal(3, Kit:GetLimits().maxVisible)
    assert.is_true(toast:IsShown())
    toast:Dismiss()
    assert.is_false(toast:IsShown())
  end)
end)
