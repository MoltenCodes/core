local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit:Format and secret values", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret argument at the caller", function()
    local secret = {}
    TestEnv.InstallSecretProbe(secret)
    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, failure = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      LocaleKit:Format("%s %s", "name", secret)
    end)
    assert.is_false(ok)
    assert.are.equal(
      source .. ":" .. line .. ": LocaleKit:Format argument 2 must not be a secret value",
      failure
    )
  end)

  it("looks the probe up at call time, after the package loaded", function()
    assert.are.equal("x", LocaleKit:Format("%s", "x"))
    TestEnv.InstallSecretProbe("x")
    TestEnv.expectErrorContaining("argument 1 must not be a secret value", function()
      LocaleKit:Format("%s", "x")
    end)
  end)

  it("refuses a secret template before string.gsub sees it", function()
    local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    default["Hello"] = true
    local L = LocaleKit:GetLocale("MyAddon")
    -- A string stand-in, read through the table only to obtain a plain
    -- string: string.gsub would run over it unless Format asked first.
    TestEnv.InstallSecretProbe("%s is here")
    local template = L["%s is here"]
    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, failure = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      LocaleKit:Format(template, "Alice")
    end)
    assert.is_false(ok)
    assert.are.equal(
      source .. ":" .. line .. ": LocaleKit:Format template must not be a secret value",
      failure
    )
  end)

  it("formats ordinary values when the probe exists", function()
    TestEnv.InstallSecretProbe({})
    assert.are.equal("a 1", LocaleKit:Format("%s %d", "a", 1))
  end)

  it(
    "asks no probe about a key read from a read table (the client refuses a secret key first)",
    function()
      local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
      default["Hello"] = true
      local L = LocaleKit:GetLocale("MyAddon")
      TestEnv.TakeReportedErrors()
      local asked = 0
      -- issecretvalue is a World of Warcraft client global; the fixture owns and clears it.
      -- selene: allow(global_usage)
      rawset(_G, "issecretvalue", function()
        asked = asked + 1
        return false
      end)

      -- Retail 12.1.0 b69933 refuses a secret key at the index, before __index
      -- runs (the client suite's secret-key test), so readMissing needs no check.
      assert.are.equal("Other", L.Other)
      assert.are.equal("Hello", L.Hello)
      assert.are.equal(0, asked)
      assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end
  )

  it("keeps the probe it resolved at load when the global changes later", function()
    -- A fresh load with the probe present: Reset clears the published state.
    TestEnv.Reset()
    TestEnv.InstallSecretProbe("x")
    package.loaded["Registry"] = nil
    package.loaded["LocaleKit"] = nil
    require("Registry")
    local loaded = require("LocaleKit")
    -- issecretvalue is a World of Warcraft client global; the fixture owns and clears it.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    TestEnv.expectErrorContaining("argument 1 must not be a secret value", function()
      loaded:Format("%s", "x")
    end)
  end)
end)

describe("LocaleKit arguments and secret values", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage("deDE")
  end)
  after_each(TestEnv.Reset)

  ---Call `callback` and assert it raised `message` at the line that called
  ---LocaleKit. The callback calls `mark` on the line just before that call.
  ---@param message string
  ---@param callback fun(mark: fun())
  local function expectRefusedAtCaller(message, callback)
    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, failure = pcall(callback, function()
      line = debug.getinfo(2, "l").currentline + 1
    end)
    assert.is_false(ok)
    assert.are.equal(source .. ":" .. line .. ": " .. message, failure)
  end

  -- On Retail 12.x a secret compared with a value of its own type, tested as
  -- a boolean or used as a table key raises (measured on Retail 12.1.0
  -- b69933), so each of these arguments is asked about before any of that.
  -- The stub's secret is an ordinary value LocaleKit would otherwise accept,
  -- so a check that comes too late (or not at all) lets the call succeed.

  it("refuses a secret NewLocale addonName at the caller and registers nothing", function()
    TestEnv.InstallSecretProbe("MyAddon")
    expectRefusedAtCaller("LocaleKit:NewLocale addonName must not be a secret value", function(mark)
      mark()
      LocaleKit:NewLocale("MyAddon", "deDE")
    end)
    TestEnv.InstallSecretProbe({})
    TestEnv.expectErrorContaining("found no locale registered for MyAddon", function()
      LocaleKit:GetLocale("MyAddon")
    end)
  end)

  it("refuses a secret NewLocale locale at the caller", function()
    TestEnv.InstallSecretProbe("deDE")
    expectRefusedAtCaller("LocaleKit:NewLocale locale must not be a secret value", function(mark)
      mark()
      LocaleKit:NewLocale("MyAddon", "deDE")
    end)
  end)

  it("refuses a secret NewLocale isDefault at the caller", function()
    TestEnv.InstallSecretProbe(true)
    expectRefusedAtCaller("LocaleKit:NewLocale isDefault must not be a secret value", function(mark)
      mark()
      LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    end)
  end)

  it("refuses a secret GetLocale addonName and missing mode at the caller", function()
    LocaleKit:NewLocale("MyAddon", "deDE")
    TestEnv.InstallSecretProbe("MyAddon")
    expectRefusedAtCaller("LocaleKit:GetLocale addonName must not be a secret value", function(mark)
      mark()
      LocaleKit:GetLocale("MyAddon")
    end)
    TestEnv.InstallSecretProbe("silent")
    expectRefusedAtCaller("LocaleKit:GetLocale missing must not be a secret value", function(mark)
      mark()
      LocaleKit:GetLocale("MyAddon", { missing = "silent" })
    end)
    -- The refused call fixed no mode: a later call may still choose one.
    TestEnv.InstallSecretProbe({})
    local L = LocaleKit:GetLocale("MyAddon", { missing = "raw" })
    assert.is_nil(L.Unknown)
  end)

  it("refuses a secret MissingKeys addonName at the caller", function()
    TestEnv.InstallSecretProbe("MyAddon")
    expectRefusedAtCaller(
      "LocaleKit:MissingKeys addonName must not be a secret value",
      function(mark)
        mark()
        LocaleKit:MissingKeys("MyAddon")
      end
    )
  end)

  it("refuses a secret SetLocaleOverride locale at the caller and keeps the override", function()
    TestEnv.InstallSecretProbe("frFR")
    expectRefusedAtCaller(
      "LocaleKit:SetLocaleOverride locale must not be a secret value",
      function(mark)
        mark()
        LocaleKit:SetLocaleOverride("frFR")
      end
    )
    TestEnv.InstallSecretProbe({})
    assert.is_table(LocaleKit:NewLocale("MyAddon", "deDE"))
  end)
end)
