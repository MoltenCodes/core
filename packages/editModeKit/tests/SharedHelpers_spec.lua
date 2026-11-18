-- The shared helper blocks EditModeKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local FrameworkTestEnv = require("FrameworkTestEnv")
local TestEnv = require("EditModeKitTestEnv")

local MODULE = "EditModeKit"
local FIXTURE = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./")
  .. "fixtures/EditModeKit-revision2.lua"

---A `package.preload` loader that runs the Lua file at `path`.
---@param path string
---@param beforeLoad fun()|nil runs first, after the environment's reset
---@return fun(): table
local function fileLoader(path, beforeLoad)
  return function()
    if beforeLoad ~= nil then
      beforeLoad()
    end
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return assert(loadstring(text, "@" .. path))()
  end
end

---Build the package as the environment does, with `loader` loading EditModeKit.
---@param loader fun(): table
---@return any ... what `TestEnv.NewPackage` returns
local function newPackageThrough(loader)
  rawset(package.preload, MODULE, loader)
  local results = { pcall(TestEnv.NewPackage) }
  rawset(package.preload, MODULE, nil)
  if not results[1] then
    error(results[2], 0)
  end
  return unpack(results, 2, table.maxn(results))
end

---Run `action` with `print` captured and the host error handler raising.
---@param action fun()
---@return boolean ok
---@return any failure
---@return string[] printed
local function withRaisingHandler(action)
  TestEnv.SetGlobal("geterrorhandler", function()
    return function()
      error("handler failed", 0)
    end
  end)
  local printed = {}
  local savedPrint = TestEnv.GetGlobal("print")
  TestEnv.SetGlobal("print", function(value)
    printed[#printed + 1] = value
  end)
  local ok, failure = pcall(action)
  TestEnv.SetGlobal("print", savedPrint)
  return ok, failure, printed
end

describe("EditModeKit shared helpers", function()
  after_each(function()
    rawset(package.preload, MODULE, nil)
    TestEnv.Reset()
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local path = FrameworkTestEnv.findModuleFile(MODULE)
    local kit = newPackageThrough(fileLoader(path, TestEnv.InstallSecretProbe))
    local secret = TestEnv.NewSecret()
    TestEnv.SetGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("limits.maxRegistrations must not be a secret value", function()
      kit:SetLimits({ maxRegistrations = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local kit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxRegistrations must not be a secret value", function()
      kit:SetLimits({ maxRegistrations = TestEnv.NewSecret() })
    end)
  end)

  it("prints a reported failure when the host error handler raises", function()
    local kit = TestEnv.NewPackage()
    local ok, failure, printed = withRaisingHandler(function()
      kit
        :Register(TestEnv.FrameAt(5, 5), function()
          error("storage failed", 0)
        end)
        :Refresh()
    end)
    assert.is_true(ok, tostring(failure))
    assert.is_true(#printed > 0)
    for _, value in ipairs(printed) do
      assert.are.equal("storage failed", value)
    end
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local kit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "EditModeKit:GetLimits must be called on the EditModeKit facade; use EditModeKit:GetLimits(...)",
      function()
        kit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 2 and keeps what it held", function()
    local older = newPackageThrough(fileLoader(FIXTURE))
    assert.are.equal(2, older.REVISION)
    local frame = TestEnv.FrameAt(300, 300)
    local registration = older:Register(frame, {})
    older:SetLimits({ maxRegistrations = 100 })

    rawset(package.loaded, MODULE, nil)
    local current = require(MODULE)
    assert.are.equal(older, current)
    assert.are.equal(3, current.REVISION)
    assert.are.equal(100, current:GetLimits().maxRegistrations)
    assert.are.equal(frame, registration:GetFrame())
    assert.is_true(registration:Unregister())
  end)
end)
