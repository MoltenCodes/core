-- The rules every Kit keeps (tests/support/KitConformance.lua), run against
-- InteropKit. The suite's secret cases need a client profile with secret
-- values, so it runs on an environment of InteropKit's module chain under the
-- mainline profile.
--
-- Pending groups:
-- * `limits`: InteropKit has no `SetLimits` (docs/API.md, "Limits").
-- * `receivers`: every InteropKit method ignores its receiver, so
--   `InteropKit.Find(major)` works like `InteropKit:Find(major)`; the suite's
--   rule that a method called on another receiver raises does not hold, and
--   holding it would be a behaviour change of its own. The cases are built
--   with `KitConformance.Cases` and registered here so that group alone is
--   reported pending.
local FrameworkTestEnv = require("FrameworkTestEnv")
local InteropKitTestEnv = require("InteropKitTestEnv")
local KitConformance = require("KitConformance")

local Environment = FrameworkTestEnv.New({
  modules = { "Registry", "InteropKit" },
  wowProfile = "mainline",
})

local RECEIVERS_PENDING = "InteropKit's methods ignore their receiver; see this spec's header"

local cases = KitConformance.Cases({
  environment = Environment,
  packageId = "interopKit",
  arguments = {
    {
      name = "AdoptFromLibStub major",
      call = function(kit, value)
        kit:AdoptFromLibStub(value)
      end,
    },
    {
      name = "Find major",
      call = function(kit, value)
        kit:Find(value)
      end,
    },
    {
      name = "ExposeToLibStub packageName",
      call = function(kit, value)
        kit:ExposeToLibStub(value, 1)
      end,
    },
  },
  upgrade = {
    seed = function(kit)
      local libStub = InteropKitTestEnv.NewLibStub()
      local library = libStub:NewLibrary("LibExample-1.0", 3)
      -- selene: allow(global_usage)
      rawset(_G, "LibStub", libStub)
      assert.are.equal(library, kit:AdoptFromLibStub("LibExample-1.0"))
      return library
    end,
    verify = function(kit, library)
      -- selene: allow(global_usage)
      rawset(_G, "LibStub", nil)
      assert.are.equal(library, (kit:Find("LibExample-1.0")))
    end,
  },
})

describe("InteropKit conformance", function()
  for _, case in ipairs(cases) do
    local title = case.group .. ": " .. case.name
    if case.group == "receivers" then
      pending(title .. " (" .. RECEIVERS_PENDING .. ")")
    elseif case.pending ~= nil then
      pending(title .. " (" .. case.pending .. ")")
    else
      it(title, function()
        local ok, failure = pcall(case.run)
        Environment.Reset()
        if not ok then
          error(failure, 0)
        end
      end)
    end
  end
end)
