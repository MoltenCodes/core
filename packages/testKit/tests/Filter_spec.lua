local TestEnv = require("TestKitTestEnv")

describe("TestKit:Run filters", function()
  local TestKit
  local ran

  before_each(function()
    TestKit = TestEnv.NewReadyPackage("MyAddon")
    ran = {}
    for _, suiteName in ipairs({ "First", "Second" }) do
      local suite = TestKit:Suite(suiteName, { addonName = "MyAddon" })
      for _, testName in ipairs({ "a", "b/c" }) do
        suite:Test(testName, function()
          ran[#ran + 1] = suiteName .. ":" .. testName
        end)
      end
    end
  end)
  after_each(TestEnv.Reset)

  it("runs every suite in registration order without a filter", function()
    TestEnv.RunToEnd(TestKit)
    assert.are.same({ "First:a", "First:b/c", "Second:a", "Second:b/c" }, ran)
  end)

  it("runs one suite", function()
    TestEnv.RunToEnd(TestKit, "Second")
    assert.are.same({ "Second:a", "Second:b/c" }, ran)
  end)

  it("runs one test, splitting at the first slash", function()
    TestEnv.RunToEnd(TestKit, "First/b/c")
    assert.are.same({ "First:b/c" }, ran)
    local report = TestKit:Report()
    assert.are.equal(1, report.totals.tests)
  end)

  it("refuses a filter that names no suite or no test", function()
    local queued, reason = TestKit:Run("Missing")
    assert.is_nil(queued)
    assert.are.equal("unknown", reason)
    queued, reason = TestKit:Run("First/missing")
    assert.is_nil(queued)
    assert.are.equal("unknown", reason)
    TestEnv.RenderFrames(2)
    assert.are.same({}, ran)
  end)

  it("raises for a malformed filter", function()
    TestEnv.expectErrorContaining('TestKit:Run filter must be "suite" or "suite/test"', function()
      TestKit:Run("/a")
    end)
    TestEnv.expectErrorContaining('TestKit:Run filter must be "suite" or "suite/test"', function()
      TestKit:Run("First/")
    end)
    TestEnv.expectErrorContaining("TestKit:Run filter must be a non-empty string", function()
      TestKit:Run("")
    end)
  end)

  it("returns 0 and starts nothing when no suite is registered", function()
    TestEnv.Reset()
    local fresh = TestEnv.NewReadyPackage("MyAddon")
    assert.are.equal(0, fresh:Run())
  end)
end)
