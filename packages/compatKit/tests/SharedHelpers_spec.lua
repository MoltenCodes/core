-- The shared helper blocks CompatKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 4, whose file is kept verbatim as a fixture.
local TestEnv = require("CompatKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 4 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table CompatKit
local function loadPreviousRevision()
  local path = FIXTURE_DIRECTORY .. "CompatKit-revision4.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load CompatKit's dependencies, run `beforeLoad`, then load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table CompatKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("CompatKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("CompatKit")
end

---Replace the host's `issecretvalue` with one that reports nothing secret.
local function replaceProbeWithNone()
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function()
    return false
  end)
end

describe("CompatKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = {}
    local CompatKit = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, requireCurrent)
    replaceProbeWithNone()
    TestEnv.expectErrorContaining("CompatKit:Shim name must not be a secret value", function()
      CompatKit:Shim(secret, 1, function() end)
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local CompatKit = loadWith(nil, requireCurrent)
    local secret = {}
    TestEnv.InstallSecretProbe(secret)
    TestEnv.expectErrorContaining("CompatKit:Shim name must not be a secret value", function()
      CompatKit:Shim(secret, 1, function() end)
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local CompatKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "CompatKit:GetLimits must be called on the CompatKit facade; use CompatKit:GetLimits(...)",
      function()
        CompatKit.GetLimits({})
      end
    )
  end)

  it("prints a shim failure when the host error handler itself raises", function()
    local CompatKit = loadWith(nil, requireCurrent)
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", function()
      return function()
        error("the error display failed")
      end
    end)
    local printed = {}
    -- selene: allow(global_usage)
    local originalPrint = rawget(_G, "print")
    -- selene: allow(global_usage)
    rawset(_G, "print", function(value)
      printed[#printed + 1] = value
    end)
    CompatKit:Shim("broken", 1, function()
      error("shim failed")
    end)
    local ok = pcall(CompatKit.Apply, CompatKit)
    -- selene: allow(global_usage)
    rawset(_G, "print", originalPrint)
    assert.is_true(ok)
    assert.are.equal(1, #printed)
    assert.is_truthy(tostring(printed[1]):find("shim failed", 1, true))
  end)

  it("upgrades in place over revision 4: shims, limits and the new probe rule", function()
    local secret = {}
    local older = loadWith(function()
      TestEnv.InstallSecretProbe(secret)
    end, loadPreviousRevision)
    assert.are.equal(4, older.REVISION)
    older:Shim("kept", 1, function() end)
    older:SetLimits({ maxShims = 100 })

    local CompatKit = require("CompatKit")
    assert.are.equal(older, CompatKit)
    assert.are.equal(5, CompatKit.REVISION)
    assert.are.equal(100, CompatKit:GetLimits().maxShims)
    assert.are.equal("kept", CompatKit:GetShims()[1].name)

    replaceProbeWithNone()
    TestEnv.expectErrorContaining("CompatKit:Shim name must not be a secret value", function()
      CompatKit:Shim(secret, 1, function() end)
    end)
  end)
end)
