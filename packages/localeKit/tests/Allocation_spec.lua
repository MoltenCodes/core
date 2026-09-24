local TestEnv = require("LocaleKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("LocaleKit allocation #allocation", function()
    local LocaleKit
    before_each(function()
        LocaleKit = TestEnv.NewPackage("deDE")
        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        default["Hello"] = true
        default["Goodbye"] = true
        LocaleKit:NewLocale("MyAddon", "deDE")["Hello"] = "Hallo"
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing for a translated or a default lookup", function()
        local L = LocaleKit:GetLocale("MyAddon")
        local mismatches = 0
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                if L["Hello"] ~= "Hallo" or L["Goodbye"] ~= "Goodbye" then
                    mismatches = mismatches + 1
                end
            end
        end)
        assert.are.equal(0, mismatches)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "lookup allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing for a missing key after its first read", function()
        local L = LocaleKit:GetLocale("MyAddon")
        local _ = L["Unknown"]
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                _ = L["Unknown"]
            end
        end)
        assert.are.equal(1, #TestEnv.TakeReportedErrors())
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "missing lookup allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates no table and no function for a repeated Format", function()
        local template = "%2$s: %1$d / %3$.2f"
        LocaleKit:Format(template, 3, "Alice", 1.5)
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                LocaleKit:Format(template, 3, "Alice", 1.5)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Format allocated " .. allocated .. " KiB")
    end)
end)
