-- The shared helper blocks TestKit carries (tooling/shared/lua/reportError.lua
-- and validateFacade.lua), and the in-place upgrade from revision 5, whose
-- file is kept verbatim as a fixture. TestKit's own `isSecret` and limits loop
-- are opted out (tooling/shared/pins.json); `describeKey` is now
-- `describePathSegment`, whose path messages Matchers_spec.lua holds.
local TestEnv = require("TestKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"

---Load the committed revision 5 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table TestKit
local function loadRevisionFive()
  local path = FIXTURE_DIRECTORY .. "TestKit-revision5.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load TestKit's dependencies without TestKit itself.
local function loadDependencies()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  for _, moduleName in ipairs({
    "Registry",
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    "TimerKit",
    "SchedulerKit",
  }) do
    require(moduleName)
  end
end

---A host error handler that itself raises, as an error-display addon with a bug.
local function installRaisingErrorHandler()
  TestEnv.SetGlobal("geterrorhandler", function()
    return function()
      error("the error handler failed")
    end
  end)
end

describe("TestKit shared helpers", function()
  local printed
  -- selene: allow(global_usage)
  local hostPrint = _G.print
  before_each(function()
    printed = {}
    -- selene: allow(global_usage)
    rawset(_G, "print", function(value)
      printed[#printed + 1] = value
    end)
  end)
  after_each(function()
    -- selene: allow(global_usage)
    rawset(_G, "print", hostPrint)
    TestEnv.Reset()
  end)

  it("prints an OnFinished failure when the error handler raises, and the run ends", function()
    local TestKit = TestEnv.NewReadyPackage("MyAddon")
    local later = 0
    TestKit:OnFinished(function()
      error("the callback failed")
    end)
    TestKit:OnFinished(function()
      later = later + 1
    end)
    installRaisingErrorHandler()
    TestKit:Suite("MyAddon"):Test("passes", function() end)

    local report = TestEnv.RunToEnd(TestKit, "MyAddon")
    assert.is_not_nil(report)
    assert.are.equal(1, later)
    assert.are.equal(1, #printed)
    assert.is_truthy(tostring(printed[1]):find("the callback failed", 1, true))
  end)

  it("names the colon call in the facade message", function()
    local TestKit = TestEnv.NewReadyPackage("MyAddon")
    TestEnv.expectErrorContaining(
      "TestKit:Report must be called on the TestKit facade; use TestKit:Report(...)",
      function()
        TestKit.Report({})
      end
    )
  end)

  it("upgrades in place over revision 5: suites and limits kept, reports protected", function()
    loadDependencies()
    local older = loadRevisionFive()
    assert.are.equal(5, older.REVISION)
    local suite = assert(older:Suite("Carried", { addonName = "MyAddon" }))
    older:SetLimits({ maxEqualDepth = 24 })
    older:OnFinished(function()
      error("the callback failed")
    end)

    local TestKit = require("TestKit")
    assert.are.equal(older, TestKit)
    assert.are.equal(6, TestKit.REVISION)
    assert.are.equal(24, TestKit:GetLimits().maxEqualDepth)
    assert.is_true(suite:Test("still works", function() end))

    installRaisingErrorHandler()
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    local report = TestEnv.RunToEnd(TestKit, "Carried")
    assert.are.equal("passed", TestEnv.FindResult(report, "Carried", "still works").status)
    assert.are.equal(1, #printed)
  end)
end)
