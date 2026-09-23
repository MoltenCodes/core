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
end)
