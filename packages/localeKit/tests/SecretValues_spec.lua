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

    it("formats ordinary values when the probe exists", function()
        TestEnv.InstallSecretProbe({})
        assert.are.equal("a 1", LocaleKit:Format("%s %d", "a", 1))
    end)

    it("hands a secret key back from a read table without storing or reporting it", function()
        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        default["Hello"] = true
        local L = LocaleKit:GetLocale("MyAddon")
        TestEnv.TakeReportedErrors()
        TestEnv.InstallSecretProbe("Secret Name")

        assert.are.equal("Secret Name", L["Secret Name"])
        assert.are.equal("Secret Name", L["Secret Name"])
        assert.is_nil(rawget(L, "Secret Name"))
        assert.are.equal(0, #TestEnv.TakeReportedErrors())
        assert.are.same({}, LocaleKit:MissingKeys("MyAddon"))

        -- Ordinary keys keep the usual behaviour while the probe exists.
        assert.are.equal("Hello", L.Hello)
        assert.are.equal("Other", L.Other)
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
    end)
end)
