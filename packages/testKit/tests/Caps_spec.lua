local TestEnv = require("TestKitTestEnv")

local function noop() end

describe("TestKit bounds", function()
  local TestKit
  before_each(function()
    TestKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("refuses a 65th suite with full and a duplicate name with taken", function()
    for index = 1, 64 do
      assert.is_not_nil(TestKit:Suite("Suite" .. index))
    end
    local suite, reason = TestKit:Suite("Suite65")
    assert.is_nil(suite)
    assert.are.equal("full", reason)

    suite, reason = TestKit:Suite("Suite1")
    assert.is_nil(suite)
    assert.are.equal("taken", reason)
  end)

  it("refuses a 257th test with full, Skip included", function()
    local suite = TestKit:Suite("MyAddon")
    for index = 1, 255 do
      assert.is_true(suite:Test("test " .. index, noop))
    end
    assert.is_true(suite:Skip("skipped"))
    local ok, reason = suite:Test("one too many", noop)
    assert.is_nil(ok)
    assert.are.equal("full", reason)
    ok, reason = suite:Skip("also too many")
    assert.is_nil(ok)
    assert.are.equal("full", reason)
  end)

  it("refuses a 17th Before or After hook with full", function()
    local suite = TestKit:Suite("MyAddon")
    for _ = 1, 16 do
      assert.is_true(suite:Before(noop))
      assert.is_true(suite:After(noop))
    end
    assert.are.same({ nil, "full" }, { suite:Before(noop) })
    assert.are.same({ nil, "full" }, { suite:After(noop) })
  end)

  it("refuses a 17th OnFinished callback with full", function()
    for _ = 1, 16 do
      assert.is_true(TestKit:OnFinished(noop))
    end
    assert.are.same({ nil, "full" }, { TestKit:OnFinished(noop) })
  end)

  it("raises for a duplicate test name", function()
    local suite = TestKit:Suite("MyAddon")
    suite:Test("same", noop)
    TestEnv.expectErrorContaining(
      'TestKit.Suite:Test suite already has a test named "same"',
      function()
        suite:Test("same", noop)
      end
    )
    TestEnv.expectErrorContaining(
      'TestKit.Suite:Skip suite already has a test named "same"',
      function()
        suite:Skip("same")
      end
    )
  end)
end)
