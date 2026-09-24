local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit client locale", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("folds an enGB client to enUS", function()
    TestEnv.SetClientLocale("enGB")
    assert.is_table(LocaleKit:NewLocale("MyAddon", "enUS"))
    assert.is_nil(LocaleKit:NewLocale("MyAddon", "enGB"))
  end)

  it("treats a client without GetLocale as enUS", function()
    TestEnv.SetClientLocale(nil)
    assert.is_table(LocaleKit:NewLocale("MyAddon", "enUS"))
    assert.is_nil(LocaleKit:NewLocale("Other", "deDE"))
  end)

  it("treats a GetLocale answer that is not a locale code as enUS", function()
    TestEnv.SetClientLocale("klingon")
    assert.is_table(LocaleKit:NewLocale("MyAddon", "enUS"))
  end)

  it("reads GetLocale at call time", function()
    TestEnv.SetClientLocale("frFR")
    assert.is_table(LocaleKit:NewLocale("MyAddon", "frFR"))
  end)

  it("uses the override for addons registered after it is set", function()
    LocaleKit:SetLocaleOverride("koKR")
    assert.is_nil(LocaleKit:NewLocale("MyAddon", "enUS"))
    local korean = LocaleKit:NewLocale("MyAddon", "koKR")
    korean["Hello"] = "안녕하세요"
    local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    default["Hello"] = true
    assert.are.equal("안녕하세요", LocaleKit:GetLocale("MyAddon").Hello)
  end)

  it("folds an enGB override to enUS", function()
    TestEnv.SetClientLocale("deDE")
    LocaleKit:SetLocaleOverride("enGB")
    assert.is_table(LocaleKit:NewLocale("MyAddon", "enUS"))
  end)

  it("clears the override with nil", function()
    TestEnv.SetClientLocale("deDE")
    LocaleKit:SetLocaleOverride("frFR")
    LocaleKit:SetLocaleOverride(nil)
    assert.is_table(LocaleKit:NewLocale("MyAddon", "deDE"))
    assert.is_nil(LocaleKit:NewLocale("MyAddon", "frFR"))
  end)

  it("keeps the locale an addon was registered with", function()
    LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    LocaleKit:SetLocaleOverride("deDE")
    assert.is_nil(LocaleKit:NewLocale("MyAddon", "deDE"))
    assert.is_table(LocaleKit:NewLocale("Later", "deDE"))
  end)

  it("names the addon's locale in a missing-key report", function()
    LocaleKit:SetLocaleOverride("ptBR")
    LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    TestEnv.TakeReportedErrors()
    local _ = LocaleKit:GetLocale("MyAddon").Unknown
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(
      'LocaleKit: missing translation "Unknown" for MyAddon (ptBR)',
      reported[1].value
    )
  end)

  it("refuses an override that is not a locale code", function()
    TestEnv.expectErrorContaining(
      'LocaleKit:SetLocaleOverride locale must be a client locale code such as "deDE"',
      function()
        LocaleKit:SetLocaleOverride("german")
      end
    )
  end)
end)
