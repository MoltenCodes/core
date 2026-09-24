local TestEnv = require("RegistryTestEnv")

describe("Registry metadata", function()
  local Registry

  before_each(function()
    Registry = TestEnv.NewRegistry()
  end)

  after_each(TestEnv.Reset)

  it("returns registration metadata", function()
    local implementation = Registry:Register("exampleKit", 3, 7)
    local info = Registry:GetInfo("exampleKit", 3)

    assert.are.equal("exampleKit", info.package)
    assert.are.equal(3, info.api)
    assert.are.equal(7, info.revision)
    assert.are.equal(implementation, info.implementation)
  end)

  it("returns a new metadata table for every call", function()
    Registry:Register("exampleKit", 1, 1)

    local first = Registry:GetInfo("exampleKit", 1)
    local second = Registry:GetInfo("exampleKit", 1)

    assert.are_not.equal(first, second)
    assert.are.same(first, second)
  end)

  it("does not expose mutable registry-owned metadata", function()
    Registry:Register("exampleKit", 1, 6)

    local info = Registry:GetInfo("exampleKit", 1)
    info.revision = 999
    info.package = "mutated"

    local current = Registry:GetInfo("exampleKit", 1)
    assert.are.equal("exampleKit", current.package)
    assert.are.equal(6, current.revision)
  end)

  it("keeps an existing metadata snapshot unchanged after an upgrade", function()
    local implementation = Registry:Register("exampleKit", 1, 2)
    implementation.marker = "before"
    local snapshot = Registry:GetInfo("exampleKit", 1)

    local upgraded = Registry:Register("exampleKit", 1, 9)
    upgraded.marker = "after"
    local current = Registry:GetInfo("exampleKit", 1)

    assert.are.equal(2, snapshot.revision)
    assert.are.equal(9, current.revision)
    assert.are.equal(implementation, snapshot.implementation)
    assert.are.equal(implementation, current.implementation)
    assert.are.equal("after", snapshot.implementation.marker)
  end)

  it("returns nil for unknown metadata", function()
    assert.is_nil(Registry:GetInfo("missing", 1))
  end)
end)
