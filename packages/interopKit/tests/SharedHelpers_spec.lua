-- The shared helper block InteropKit carries (tooling/shared/lua/isSecret.lua),
-- and the in-place upgrade from revision 3, whose file is kept verbatim as a
-- fixture.
local Env = require("InteropKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

--- A stand-in for a secret value: the probe of these specs reports this one table.
local SECRET = {}

local function reportsSecret(value)
  return rawequal(value, SECRET)
end

local function reportsNothing()
  return false
end

---Load the committed revision 3 file, the copy an addon embedded before the
---shared block, and return what it returns.
---@return table InteropKit
local function loadRevisionThree()
  local path = FIXTURE_DIRECTORY .. "InteropKit-revision3.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load Registry, run `beforeLoad`, then load InteropKit through `loadKit`.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table InteropKit
local function loadWith(beforeLoad, loadKit)
  Env.Reset()
  Env.InstallWowApi()
  require("Registry")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return Env.requireAfterFailedLoad("InteropKit")
end

local function installProbe()
  Env.InstallSecretProbe(reportsSecret)
end

describe("InteropKit shared helpers", function()
  after_each(function()
    Env.Reset()
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local InteropKit = loadWith(installProbe, requireCurrent)
    Env.InstallSecretProbe(reportsNothing)
    Env.expectErrorContaining(
      "InteropKit:AdoptFromLibStub major must not be a secret value",
      function()
        InteropKit:AdoptFromLibStub(SECRET)
      end
    )
  end)

  it("asks a probe installed after load when there was none at load", function()
    local InteropKit = loadWith(nil, requireCurrent)
    installProbe()
    Env.expectErrorContaining(
      "InteropKit:AdoptFromLibStub major must not be a secret value",
      function()
        InteropKit:AdoptFromLibStub(SECRET)
      end
    )
  end)

  it("upgrades in place over revision 3: adopted libraries and the new probe rule", function()
    local older = loadWith(installProbe, loadRevisionThree)
    assert.are.equal(3, older.REVISION)
    local libStub = Env.InstallLibStub()
    local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
    assert.are.equal(broker, older:AdoptFromLibStub("LibDataBroker-1.1"))

    local InteropKit = requireCurrent()
    assert.are.equal(older, InteropKit)
    assert.are.equal(4, InteropKit.REVISION)
    local library, minor = InteropKit:Find("LibDataBroker-1.1")
    assert.are.equal(broker, library)
    assert.are.equal(4, minor)

    Env.InstallSecretProbe(reportsNothing)
    Env.expectErrorContaining(
      "InteropKit:AdoptFromLibStub major must not be a secret value",
      function()
        InteropKit:AdoptFromLibStub(SECRET)
      end
    )
  end)
end)
