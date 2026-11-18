-- The shared helper blocks AddonKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local TestEnv = require("AddonKitTestEnv")

local MODULE = "AddonKit"
local FIXTURE = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./")
  .. "fixtures/AddonKit-revision2.lua"

---A `package.preload` loader that runs the Lua file at `path`.
---@param path string
---@return fun(): table
local function fileLoader(path)
  return function()
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return assert(loadstring(text, "@" .. path))()
  end
end

---Build the package as the environment does, with `loader` loading AddonKit.
---@param loader fun(): table
---@return table AddonKit
local function newPackageThrough(loader)
  rawset(package.preload, MODULE, loader)
  local ok, result = pcall(TestEnv.NewPackage)
  rawset(package.preload, MODULE, nil)
  if not ok then
    error(result, 0)
  end
  return result
end

---Run `action` with `print` captured and the host error handler raising.
---@param action fun()
---@return boolean ok
---@return any failure
---@return string[] printed
local function withRaisingHandler(action)
  local savedHandlerReader = TestEnv.GetGlobal("geterrorhandler")
  local savedPrint = TestEnv.GetGlobal("print")
  TestEnv.SetGlobal("geterrorhandler", function()
    return function()
      error("handler failed", 0)
    end
  end)
  local printed = {}
  TestEnv.SetGlobal("print", function(value)
    printed[#printed + 1] = value
  end)
  local ok, failure = pcall(action)
  TestEnv.SetGlobal("print", savedPrint)
  TestEnv.SetGlobal("geterrorhandler", savedHandlerReader)
  return ok, failure, printed
end

describe("AddonKit shared helpers", function()
  after_each(function()
    rawset(package.preload, MODULE, nil)
    TestEnv.Reset()
  end)

  it("prints the foreign-entry report when the host error handler raises", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    rawset(TestEnv.Namespace(), "For", function() end)
    local ok, failure, printed = withRaisingHandler(function()
      require(MODULE)
    end)
    assert.is_true(ok, tostring(failure))
    assert.are.equal(1, #printed)
    assert.is_truthy(string.find(printed[1], 'Get("addonKit", 1):For(...)', 1, true))
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    TestEnv.NewPackage()
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.ExpectRaisedInside("addonName must not be a secret value", function()
      TestEnv.Namespace():For(secret)
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local AddonKit = TestEnv.NewPackage()
    TestEnv.ExpectRaisedInside(
      "AddonKit:GetLimits must be called on the AddonKit facade; use AddonKit:GetLimits(...)",
      function()
        AddonKit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 2, keeping facades and limits", function()
    local older = newPackageThrough(fileLoader(FIXTURE))
    assert.are.equal(2, older.REVISION)
    local MC = older:For("MyAddon")
    older:SetLimits({ maxFacades = 9 })
    local entry = older.For

    rawset(package.loaded, MODULE, nil)
    local current = require(MODULE)
    assert.are.equal(older, current)
    assert.are.equal(3, current.REVISION)
    assert.are.equal(9, current:GetLimits().maxFacades)
    assert.are.equal(entry, current.For)
    assert.are.equal(MC, TestEnv.Namespace():For("MyAddon"))

    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.ExpectRaisedInside("addonName must not be a secret value", function()
      TestEnv.Namespace():For(secret)
    end)
  end)
end)
