local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit:GetLocale", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage("deDE")
    TestEnv.TakeReportedErrors()
  end)
  after_each(TestEnv.Reset)

  ---Register a default file with `Hello` and `Goodbye` and a German file
  ---translating `Hello` only.
  ---@param addonName string
  local function registerStrings(addonName)
    local default = LocaleKit:NewLocale(addonName, "enUS", { isDefault = true })
    default["Hello"] = true
    default["Goodbye"] = "Goodbye!"
    local german = LocaleKit:NewLocale(addonName, "deDE")
    german["Hello"] = "Hallo"
  end

  it("layers the client locale over the default", function()
    registerStrings("MyAddon")
    local L = LocaleKit:GetLocale("MyAddon")
    assert.are.equal("Hallo", L.Hello)
    assert.are.equal("Goodbye!", L.Goodbye)
  end)

  it("returns the same table on every call", function()
    registerStrings("MyAddon")
    assert.are.equal(LocaleKit:GetLocale("MyAddon"), LocaleKit:GetLocale("MyAddon"))
  end)

  it("sees translations registered after it was first called", function()
    registerStrings("MyAddon")
    local L = LocaleKit:GetLocale("MyAddon")
    LocaleKit:NewLocale("MyAddon", "deDE")["Late"] = "Spät"
    assert.are.equal("Spät", L.Late)
  end)

  describe('missing = "report"', function()
    it("returns the key and reports it once through the host error handler", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon")
      assert.are.equal("Unknown", L.Unknown)
      assert.are.equal("Unknown", L.Unknown)
      assert.are.equal("Unknown", L["Unknown"])

      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.are.equal(
        'LocaleKit: missing translation "Unknown" for MyAddon (deDE)',
        reported[1].value
      )
      assert.are.equal("Unknown", rawget(L, "Unknown"))
    end)

    it("is the default mode", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon", {})
      local _ = L.Unknown
      assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)

    it("prints the report when the host has no error handler", function()
      registerStrings("MyAddon")
      TestEnv.RemoveHostErrorHandler()
      local printed = {}
      local originalPrint = print
      -- The spec replaces the global print to observe the fallback and restores it below.
      -- selene: allow(global_usage)
      rawset(_G, "print", function(message)
        printed[#printed + 1] = message
      end)
      local ok, failure = pcall(function()
        local _ = LocaleKit:GetLocale("MyAddon").Unknown
      end)
      -- selene: allow(global_usage)
      rawset(_G, "print", originalPrint)
      assert.is_true(ok, tostring(failure))
      assert.are.same({ 'LocaleKit: missing translation "Unknown" for MyAddon (deDE)' }, printed)
    end)

    it("returns nil for a key that is not a string, without a report", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon")
      assert.is_nil(L[1])
      assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)
  end)

  describe('missing = "silent"', function()
    it("returns the key without reporting it", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
      assert.are.equal("Unknown", L.Unknown)
      assert.are.equal(0, #TestEnv.TakeReportedErrors())
      assert.are.same({ "Unknown" }, LocaleKit:MissingKeys("MyAddon"))
    end)
  end)

  describe('missing = "raw"', function()
    it("returns nil for an unknown key and has no metatable", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon", { missing = "raw" })
      assert.is_nil(L.Unknown)
      assert.is_nil(getmetatable(L))
      assert.are.equal("Hallo", L.Hello)
      assert.are.equal(0, #TestEnv.TakeReportedErrors())
      assert.are.same({}, LocaleKit:MissingKeys("MyAddon"))
    end)
  end)

  describe("mode fixing", function()
    it("raises when a later call names a different mode", function()
      registerStrings("MyAddon")
      LocaleKit:GetLocale("MyAddon", { missing = "silent" })
      TestEnv.expectErrorContaining(
        'LocaleKit:GetLocale MyAddon already uses missing mode "silent", not "report"',
        function()
          LocaleKit:GetLocale("MyAddon", { missing = "report" })
        end
      )
    end)

    it("accepts a later call that names no mode", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
      assert.are.equal(L, LocaleKit:GetLocale("MyAddon"))
      assert.are.equal(L, LocaleKit:GetLocale("MyAddon", { missing = "silent" }))
      local _ = L.Unknown
      assert.are.equal(0, #TestEnv.TakeReportedErrors())
    end)
  end)

  describe("a key read before it was defined", function()
    it("takes the translation registered later", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon")
      assert.are.equal("Late", L.Late)
      LocaleKit:NewLocale("MyAddon", "deDE")["Late"] = "Spät"
      assert.are.equal("Spät", L.Late)
      assert.are.same({}, LocaleKit:MissingKeys("MyAddon"))
    end)

    it("takes the default registered later", function()
      registerStrings("MyAddon")
      local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
      assert.are.equal("Late", L.Late)
      LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })["Late"] = "Late!"
      assert.are.equal("Late!", L.Late)
      assert.are.same({}, LocaleKit:MissingKeys("MyAddon"))
    end)
  end)

  it("stops recording and reporting past 1024 missing keys, still returning the key", function()
    registerStrings("MyAddon")
    local L = LocaleKit:GetLocale("MyAddon")
    for index = 1, 1024 do
      local _ = L["missing" .. index]
    end
    assert.are.equal(1024, #TestEnv.TakeReportedErrors())

    assert.are.equal("beyond1", L.beyond1)
    assert.are.equal("beyond2", L.beyond2)
    assert.is_nil(rawget(L, "beyond1"))
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_truthy(
      tostring(reported[1].value):find("more than 1024 missing translations", 1, true)
    )
    assert.are.equal(1024, #LocaleKit:MissingKeys("MyAddon"))
  end)

  it("raises when the addon registered nothing", function()
    TestEnv.expectErrorContaining(
      "LocaleKit:GetLocale found no locale registered for Nobody; load its translation files first",
      function()
        LocaleKit:GetLocale("Nobody")
      end
    )
  end)

  it("refuses bad arguments", function()
    registerStrings("MyAddon")
    TestEnv.expectErrorContaining('missing must be "report", "silent" or "raw"', function()
      LocaleKit:GetLocale("MyAddon", { missing = "warn" })
    end)
    TestEnv.expectErrorContaining('options contains unknown field "silent"', function()
      LocaleKit:GetLocale("MyAddon", { silent = true })
    end)
    TestEnv.expectErrorContaining("addonName must be a non-empty string", function()
      LocaleKit:GetLocale(nil)
    end)
  end)
end)
