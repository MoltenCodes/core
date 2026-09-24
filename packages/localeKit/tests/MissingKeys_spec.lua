local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit:MissingKeys", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("returns the keys read but never defined, sorted", function()
    local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    default["Defined"] = true
    local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
    local _ = L.zeta
    _ = L.Alpha
    _ = L.Defined
    _ = L.beta
    _ = L.zeta
    assert.are.same({ "Alpha", "beta", "zeta" }, LocaleKit:MissingKeys("MyAddon"))
  end)

  it("returns a new array on every call", function()
    LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    local first = LocaleKit:MissingKeys("MyAddon")
    local second = LocaleKit:MissingKeys("MyAddon")
    assert.are_not.equal(first, second)
    first[1] = "changed"
    assert.are.same({}, LocaleKit:MissingKeys("MyAddon"))
  end)

  it("returns an empty array for an addon it does not know", function()
    assert.are.same({}, LocaleKit:MissingKeys("Nobody"))
  end)

  it("keeps each addon's keys apart", function()
    LocaleKit:NewLocale("First", "enUS", { isDefault = true })
    LocaleKit:NewLocale("Second", "enUS", { isDefault = true })
    local _ = LocaleKit:GetLocale("First", { missing = "silent" }).One
    _ = LocaleKit:GetLocale("Second", { missing = "silent" }).Two
    assert.are.same({ "One" }, LocaleKit:MissingKeys("First"))
    assert.are.same({ "Two" }, LocaleKit:MissingKeys("Second"))
  end)

  it("refuses a bad addon name", function()
    TestEnv.expectErrorContaining(
      "LocaleKit:MissingKeys addonName must be a non-empty string",
      function()
        LocaleKit:MissingKeys(42)
      end
    )
  end)
end)
