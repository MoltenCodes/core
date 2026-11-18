-- The shared helper blocks MenuKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 2, whose file is kept verbatim as a fixture.
local FrameworkTestEnv = require("FrameworkTestEnv")
local TestEnv = require("MenuKitTestEnv")

local MODULE = "MenuKit"
local FIXTURE = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./")
  .. "fixtures/MenuKit-revision2.lua"

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

---Build the package as the environment does, with `loader` loading MenuKit.
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

describe("MenuKit shared helpers", function()
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
    TestEnv.expectErrorContaining("limits.maxEntries must not be a secret value", function()
      kit:SetLimits({ maxEntries = secret })
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local kit = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining("limits.maxEntries must not be a secret value", function()
      kit:SetLimits({ maxEntries = TestEnv.NewSecret() })
    end)
  end)

  it("prints a reported failure when the host error handler raises", function()
    local kit, api = TestEnv.NewPackage()
    kit:OpenContextMenu({ name = "owner" }, {
      {
        kind = "button",
        text = "Click",
        onClick = function()
          error("callback failed", 0)
        end,
      },
    })
    local ok, failure, printed = withRaisingHandler(function()
      api.contextMenus[1].children[1]:Click()
    end)
    assert.is_true(ok, tostring(failure))
    assert.are.same({ "callback failed" }, printed)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local kit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "MenuKit:GetLimits must be called on the MenuKit facade; use MenuKit:GetLimits(...)",
      function()
        kit.GetLimits({})
      end
    )
  end)

  it("upgrades in place over revision 2 and keeps what it held", function()
    local older = newPackageThrough(fileLoader(FIXTURE))
    assert.are.equal(2, older.REVISION)
    older:SetLimits({ maxEntries = 100 })

    rawset(package.loaded, MODULE, nil)
    local current, api = require(MODULE), TestEnv.InstallMenu()
    assert.are.equal(older, current)
    assert.are.equal(3, current.REVISION)
    assert.are.equal(100, current:GetLimits().maxEntries)
    current:OpenContextMenu({ name = "owner" }, { { kind = "title", text = "Kept" } })
    assert.are.equal(1, #api.contextMenus)
  end)
end)
