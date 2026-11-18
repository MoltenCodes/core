-- The shared helper blocks DialogKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local TestEnv = require("DialogKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 2 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table DialogKit
local function loadRevision2()
  local path = FIXTURE_DIRECTORY .. "DialogKit-revision2.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---What `DialogKitTestEnv.NewPackage` arranges after the module chain loads.
local function prepareHost()
  local uiParent = TestEnv.GetGlobal("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
  TestEnv.SetGlobal("GetTime", function()
    return 100
  end)
  TestEnv.SetGlobal("UISpecialFrames", { "ItemRefTooltip" })
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

describe("DialogKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local DialogKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    -- A newer copy loaded while the probe is installed resolves it at load.
    DialogKit = TestEnv.LoadRevision(DialogKit.REVISION + 1)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxQueued must not be a secret value", function()
      DialogKit:SetLimits({ maxQueued = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local DialogKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxQueued must not be a secret value", function()
      DialogKit:SetLimits({ maxQueued = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local DialogKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "DialogKit:GetLimits must be called on the DialogKit facade; use DialogKit:GetLimits(...)",
      function()
        DialogKit.GetLimits({})
      end
    )
  end)

  it("refuses a dot call whose receiver is a secret with the facade message", function()
    local DialogKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.expectErrorContaining(
      "DialogKit:GetLimits must be called on the DialogKit facade; use DialogKit:GetLimits(...)",
      function()
        DialogKit.GetLimits(secret)
      end
    )
  end)

  it("prints an onAccept that raises when the host error handler raises", function()
    local DialogKit = TestEnv.NewPackage()
    local printed, restore = installRaisingHandler()
    DialogKit:Show({
      text = "first",
      onAccept = function()
        error("accept failed", 0)
      end,
    })
    local frame = TestEnv.GetGlobal(DialogKit.FRAME_NAME)
    local ok = pcall(TestEnv.Run, frame.acceptButton, "OnClick", "LeftButton")
    restore()
    assert.is_true(ok, "the failure reached the caller of the script")
    assert.are.same({ "accept failed" }, printed)
  end)

  it("upgrades in place over revision 2, keeping what the older copy made", function()
    TestEnv.NewPackageWithout("DialogKit")
    local older = loadRevision2()
    prepareHost()
    assert.are.equal(2, older.REVISION)
    local dialog = older:Show({ text = "kept" })
    older:SetLimits({ maxQueued = 3 })

    local Kit = require("DialogKit")
    assert.are.equal(older, Kit)
    assert.are.equal(3, Kit.REVISION)
    assert.are.equal(3, Kit:GetLimits().maxQueued)
    assert.is_true(dialog:IsShown())
    dialog:Hide()
    assert.is_false(dialog:IsShown())
  end)
end)
