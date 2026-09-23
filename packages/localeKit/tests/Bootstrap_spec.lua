local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local LocaleKit = TestEnv.NewPackage()
        LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })["Hello"] = true

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(LocaleKit, reloaded)
        assert.are.equal("Hello", reloaded:GetLocale("MyAddon").Hello)
    end)

    it("publishes through Registry", function()
        local LocaleKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("localeKit", 1)
        assert.are.equal(LocaleKit, registered)
        assert.are.equal(LocaleKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local LocaleKit, Registry = TestEnv.NewPackage()
        local shippedRevision = LocaleKit.REVISION
        local upgraded, previous = Registry:Register("localeKit", 1, 99)
        assert.are.equal(LocaleKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(LocaleKit, "REVISION", 99)
        rawset(LocaleKit, "_state", { schema = 999 })
        package.loaded["LocaleKit"] = nil

        local reloaded = require("LocaleKit")
        assert.are.equal(LocaleKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps every table, mode, proxy and the override", function()
        local LocaleKit = TestEnv.NewPackage("deDE")
        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        default["Hello"] = true
        default["Goodbye"] = true
        local german = LocaleKit:NewLocale("MyAddon", "deDE")
        german["Hello"] = "Hallo"
        local L = LocaleKit:GetLocale("MyAddon")
        local _ = L.Seen
        LocaleKit:NewLocale("Quiet", "enUS", { isDefault = true })["Key"] = true
        local quiet = LocaleKit:GetLocale("Quiet", { missing = "silent" })
        LocaleKit:SetLocaleOverride("frFR")
        TestEnv.TakeReportedErrors()

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(LocaleKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)

        -- The read tables are the same objects with the same contents.
        assert.are.equal(L, upgraded:GetLocale("MyAddon"))
        assert.are.equal("Hallo", L.Hello)
        assert.are.equal("Goodbye", L.Goodbye)

        -- The modes are kept: "report" still reports a new key once, a key
        -- already reported stays quiet, "silent" still never reports, and a
        -- different mode is still refused.
        _ = L.Seen
        _ = L.Fresh
        _ = L.Fresh
        _ = quiet.Unknown
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal(
            'LocaleKit: missing translation "Fresh" for MyAddon (deDE)',
            reported[1].value
        )
        TestEnv.expectErrorContaining('already uses missing mode "silent"', function()
            upgraded:GetLocale("Quiet", { missing = "report" })
        end)
        assert.are.same({ "Fresh", "Seen" }, upgraded:MissingKeys("MyAddon"))

        -- Proxies an older copy handed out keep their write rules.
        default["Hello"] = "Hello!"
        german["Seen"] = "Gesehen"
        assert.are.equal("Hallo", L.Hello)
        assert.are.equal("Gesehen", L.Seen)
        assert.are.same({ "Fresh" }, upgraded:MissingKeys("MyAddon"))

        -- The override is kept for addons registered after the upgrade.
        assert.is_table(upgraded:NewLocale("Later", "frFR"))
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "LocaleKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        Registry:Register("localeKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "LocaleKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes LocaleKit", 1, true) ~= nil)
    end)
end)
