-- The shared helper blocks ReadinessKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 5, whose file is kept verbatim as a fixture.
local TestEnv = require("ReadinessKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 5 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table ReadinessKit
local function loadRevisionFive()
  local path = FIXTURE_DIRECTORY .. "ReadinessKit-revision5.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Write a host global.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Load ReadinessKit's dependencies, run `beforeLoad`, then load ReadinessKit.
---@param beforeLoad fun()|nil
---@return table ReadinessKit
local function loadWith(beforeLoad)
  TestEnv.NewPackageWithout("ReadinessKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return require("ReadinessKit")
end

local function plainProbe()
  return false
end

describe("ReadinessKit shared helpers", function()
  local printed
  -- selene: allow(global_usage)
  local hostPrint = _G.print
  before_each(function()
    printed = {}
    setGlobal("print", function(value)
      printed[#printed + 1] = value
    end)
  end)
  after_each(function()
    setGlobal("print", hostPrint)
    setGlobal("issecretvalue", nil)
    setGlobal("geterrorhandler", nil)
    TestEnv.Reset()
  end)

  it("prints a probe failure when the host error handler itself raises", function()
    local ReadinessKit = TestEnv.NewPackage()
    setGlobal("geterrorhandler", function()
      return function()
        error("the error handler failed")
      end
    end)

    local gate = ReadinessKit:Gate("broken", function()
      error("probe failure", 0)
    end)
    assert.is_false(gate:IsReady())
    assert.are.same({ "probe failure" }, printed)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local ReadinessKit = loadWith(nil)
    local secret = {}
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    TestEnv.expectErrorContaining("ReadinessKit:Gate name must not be a secret value", function()
      ReadinessKit:Gate(secret, plainProbe)
    end)
  end)

  it("keeps the probe it found at load when the global is replaced", function()
    local secret = {}
    local ReadinessKit = loadWith(function()
      setGlobal("issecretvalue", function(value)
        return rawequal(value, secret)
      end)
    end)
    setGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining("ReadinessKit:Gate name must not be a secret value", function()
      ReadinessKit:Gate(secret, plainProbe)
    end)
  end)

  it("counts only a plain true from the probe as secret", function()
    local ReadinessKit = loadWith(function()
      setGlobal("issecretvalue", function()
        return 1
      end)
    end)
    local gate = ReadinessKit:Gate("spells", function()
      return true
    end)
    assert.is_true(gate:IsReady())
  end)

  it("upgrades in place over revision 5: gates keep their state and run the new code", function()
    TestEnv.NewPackageWithout("ReadinessKit")
    local older = loadRevisionFive()
    assert.are.equal(5, older.REVISION)
    local answer = false
    local gate = older:Gate("spells", function()
      return answer
    end)
    assert.is_false(gate:IsReady())

    local ReadinessKit = require("ReadinessKit")
    assert.are.equal(older, ReadinessKit)
    assert.are.equal(6, ReadinessKit.REVISION)
    assert.are.equal(gate, ReadinessKit:Get("spells"))
    answer = true
    TestEnv.Poll(500)
    assert.is_true(gate:IsReady())

    local secret = {}
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    TestEnv.expectErrorContaining("ReadinessKit:Gate name must not be a secret value", function()
      ReadinessKit:Gate(secret, plainProbe)
    end)
  end)
end)
