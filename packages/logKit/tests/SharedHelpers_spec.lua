-- The shared helper blocks LogKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 5, whose file is kept verbatim as a fixture.
local TestEnv = require("LogKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 5 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table LogKit
local function loadPreviousRevision()
  local path = FIXTURE_DIRECTORY .. "LogKit-revision5.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load LogKit's dependencies, run `beforeLoad`, then load `loadKit`'s copy.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table LogKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.NewPackageWithout("LogKit")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return require("LogKit")
end

---Replace the host's `issecretvalue` with one that reports nothing secret.
local function replaceProbeWithNone()
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function()
    return false
  end)
end

describe("LogKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local LogKit = loadWith(nil, requireCurrent)
    local secret = TestEnv.NewSecretValue()
    replaceProbeWithNone()
    TestEnv.expectErrorContaining("LogKit:ForAddon addonName must not be a secret value", function()
      LogKit:ForAddon(secret)
    end)
  end)

  it("asks a probe installed after load when there was none at load", function()
    local LogKit = loadWith(function()
      TestEnv.SetGlobal("issecretvalue", nil)
    end, requireCurrent)
    TestEnv.InstallSecretProbe("Hidden")
    TestEnv.expectErrorContaining("LogKit:ForAddon addonName must not be a secret value", function()
      LogKit:ForAddon("Hidden")
    end)
  end)

  it("keeps the facade message of the shared validateFacade", function()
    local LogKit = loadWith(nil, requireCurrent)
    TestEnv.expectErrorContaining(
      "LogKit:GetLimits must be called on the LogKit facade; use LogKit:GetLimits(...)",
      function()
        LogKit.GetLimits({})
      end
    )
  end)

  it(
    "upgrades in place over revision 5: loggers, levels, sinks, limits and the probe rule",
    function()
      local older = loadWith(nil, loadPreviousRevision)
      assert.are.equal(5, older.REVISION)
      local logger = older:ForAddon("Kept")
      logger:SetLevel("info")
      local delivered = {}
      older:AddSink(function(record)
        delivered[#delivered + 1] = record.message
      end)
      older:SetLimits({ maxSinks = 4 })

      local LogKit = require("LogKit")
      assert.are.equal(older, LogKit)
      assert.are.equal(6, LogKit.REVISION)
      assert.are.equal(logger, LogKit:ForAddon("Kept"))
      assert.are.equal("info", (logger:GetLevel()))
      assert.are.equal(4, LogKit:GetLimits().maxSinks)
      logger:Info("after")
      assert.are.same({ "after" }, delivered)

      local secret = TestEnv.NewSecretValue()
      replaceProbeWithNone()
      TestEnv.expectErrorContaining(
        "LogKit:ForAddon addonName must not be a secret value",
        function()
          LogKit:ForAddon(secret)
        end
      )
    end
  )
end)
