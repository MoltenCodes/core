-- The shared helper blocks CacheKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 7, whose file is kept verbatim as a fixture.
local TestEnv = require("CacheKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 7 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table CacheKit
local function loadPreviousRevision()
  local path = FIXTURE_DIRECTORY .. "CacheKit-revision7.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Write a host global; `issecretvalue` exists only in the global table, and
---the shared fixture's `Reset` clears it.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Load CacheKit's dependencies, run `beforeLoad`, then load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table CacheKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("CacheKit")
  -- The shared fixture's default profile publishes no probe; these specs
  -- choose whether one exists at load.
  setGlobal("issecretvalue", nil)
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("CacheKit")
end

---Make `issecretvalue` report `secret` (compared with `rawequal`) as secret.
---@param secret any
local function installProbe(secret)
  setGlobal("issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

describe("CacheKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("adds the hint to the facade message of SetLimits and GetLimits", function()
    local CacheKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "CacheKit:SetLimits must be called on the CacheKit facade; use CacheKit:SetLimits(...)",
      function()
        CacheKit.SetLimits({}, { maxQueueCapacity = 8 })
      end
    )
    TestEnv.expectErrorContaining(
      "CacheKit:GetLimits must be called on the CacheKit facade; use CacheKit:GetLimits(...)",
      function()
        CacheKit.GetLimits("x")
      end
    )
  end)

  it("asks a probe installed after load when there was none at load", function()
    local CacheKit = loadWith(nil, requireCurrent)
    local secret = 64
    installProbe(secret)
    TestEnv.expectErrorContaining(
      "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
      function()
        CacheKit:SetLimits({ maxQueueCapacity = secret })
      end
    )
    assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
  end)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local secret = 64
    local CacheKit = loadWith(function()
      installProbe(secret)
    end, requireCurrent)
    setGlobal("issecretvalue", function()
      return false
    end)
    TestEnv.expectErrorContaining(
      "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
      function()
        CacheKit:SetLimits({ maxQueueCapacity = secret })
      end
    )
  end)

  it("upgrades in place over revision 7: caches, limits and the new probe rule", function()
    local older = loadWith(nil, loadPreviousRevision)
    assert.are.equal(7, older.REVISION)
    local cache = older:NewLru({ maxEntries = 4 })
    cache:Set("kept", 1)
    older:SetLimits({ maxQueueCapacity = 16 })

    local CacheKit = require("CacheKit")
    assert.are.equal(older, CacheKit)
    assert.are.equal(8, CacheKit.REVISION)
    assert.are.equal(16, CacheKit:GetLimits().maxQueueCapacity)
    assert.are.equal(1, cache:Get("kept"))

    local secret = 32
    installProbe(secret)
    TestEnv.expectErrorContaining(
      "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
      function()
        CacheKit:SetLimits({ maxQueueCapacity = secret })
      end
    )
    TestEnv.expectErrorContaining(
      "CacheKit:GetLimits must be called on the CacheKit facade; use CacheKit:GetLimits(...)",
      function()
        CacheKit.GetLimits({})
      end
    )
  end)
end)
