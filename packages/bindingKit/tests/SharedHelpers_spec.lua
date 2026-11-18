-- The shared helper blocks BindingKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local TestEnv = require("BindingKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 2 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table BindingKit
local function loadRevision2()
  local path = FIXTURE_DIRECTORY .. "BindingKit-revision2.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---What `BindingKitTestEnv.NewPackage` arranges after the module chain loads.
local function prepareHost()
  TestEnv.InstallBindingApi()
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

describe("BindingKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local BindingKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    -- A newer copy loaded while the probe is installed resolves it at load.
    BindingKit = TestEnv.LoadRevision(BindingKit.REVISION + 1)
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxScopes must not be a secret value", function()
      BindingKit:SetLimits({ maxScopes = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local BindingKit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxScopes must not be a secret value", function()
      BindingKit:SetLimits({ maxScopes = TestEnv.NewSecret() })
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local BindingKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "BindingKit:GetLimits must be called on the BindingKit facade; use BindingKit:GetLimits(...)",
      function()
        BindingKit.GetLimits({})
      end
    )
  end)

  it("prints a function key whose function raises when the host error handler raises", function()
    local BindingKit = TestEnv.NewPackage()
    local printed, restore = installRaisingHandler()
    local scope = BindingKit:CreateScope("MyAddon")
    scope:BindFunction("F5", function()
      error("key failed", 0)
    end)
    local owner = BindingKit._state.records[scope].owner
    local button = TestEnv.GetGlobal(TestEnv.Bindings(owner)["F5"].click)
    local ok = pcall(button:GetScript("OnClick"), button, "LeftButton")
    restore()
    assert.is_true(ok, "the failure reached the caller of the script")
    assert.are.same({ "key failed" }, printed)
  end)

  it("upgrades in place over revision 2, keeping what the older copy made", function()
    TestEnv.NewPackageWithout("BindingKit")
    local older = loadRevision2()
    prepareHost()
    assert.are.equal(2, older.REVISION)
    local scope = older:CreateScope("MyAddon")
    scope:BindCommand("F6", "TOGGLEWORLDMAP")
    older:SetLimits({ maxScopes = 100 })

    local Kit = require("BindingKit")
    assert.are.equal(older, Kit)
    assert.are.equal(3, Kit.REVISION)
    assert.are.equal(100, Kit:GetLimits().maxScopes)
    assert.are.equal("command", (scope:GetBinding("F6")))
    assert.is_true(scope:Unbind("F6"))
  end)
end)
