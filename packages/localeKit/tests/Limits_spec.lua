local TestEnv = require("LocaleKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line after
---the one that called `mark()`, the call into LocaleKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
    local expectedLine = nil
    local function mark()
        expectedLine = debug.getinfo(2, "l").currentline + 1
    end
    local ok, value = pcall(action, mark)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local LIMIT_MESSAGE =
    "LocaleKit:GetLocale options.maxMissingKeys must be a positive integer or LocaleKit.UNBOUNDED"

describe("LocaleKit limits", function()
    local LocaleKit
    before_each(function()
        LocaleKit = TestEnv.NewPackage("deDE")
        LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })["Hello"] = true
        TestEnv.TakeReportedErrors()
    end)
    after_each(TestEnv.Reset)

    ---Read `count` distinct missing keys, `prefix1` onwards.
    ---@param L table
    ---@param prefix string
    ---@param count integer
    local function readMissing(L, prefix, count)
        for index = 1, count do
            local _ = L[prefix .. index]
        end
    end

    it("exposes one UNBOUNDED sentinel table", function()
        assert.are.equal("table", type(LocaleKit.UNBOUNDED))
    end)

    it("records 1024 missing keys by default", function()
        local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
        readMissing(L, "key", 1030)
        assert.are.equal(1024, #LocaleKit:MissingKeys("MyAddon"))
        assert.is_nil(rawget(L, "key1030"))
        assert.are.equal("key1030", L.key1030)
    end)

    it("honours a smaller and a larger maxMissingKeys", function()
        local L = LocaleKit:GetLocale("MyAddon", { maxMissingKeys = 3 })
        readMissing(L, "key", 5)
        assert.are.equal(3, #LocaleKit:MissingKeys("MyAddon"))
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(4, #reported)
        assert.is_truthy(
            tostring(reported[4].value):find("more than 3 missing translations", 1, true)
        )

        LocaleKit:NewLocale("Other", "enUS", { isDefault = true })["Hello"] = true
        local other = LocaleKit:GetLocale("Other", { missing = "silent", maxMissingKeys = 2000 })
        readMissing(other, "key", 2001)
        assert.are.equal(2000, #LocaleKit:MissingKeys("Other"))
    end)

    it("records every missing key with UNBOUNDED", function()
        local L = LocaleKit:GetLocale("MyAddon", {
            missing = "silent",
            maxMissingKeys = LocaleKit.UNBOUNDED,
        })
        readMissing(L, "key", 3000)
        assert.are.equal(3000, #LocaleKit:MissingKeys("MyAddon"))
        assert.are.equal("key3000", rawget(L, "key3000"))
    end)

    it(
        "fixes the limit on the first call and accepts a later call that agrees or names none",
        function()
            local L = LocaleKit:GetLocale("MyAddon", { maxMissingKeys = 1 })
            assert.are.equal(L, LocaleKit:GetLocale("MyAddon"))
            assert.are.equal(L, LocaleKit:GetLocale("MyAddon", { maxMissingKeys = 1 }))
            readMissing(L, "first", 2)
            assert.are.equal(1, #LocaleKit:MissingKeys("MyAddon"))
            assert.are.equal(2, #TestEnv.TakeReportedErrors())
        end
    )

    it("refuses a later limit that differs at the caller's line and changes nothing", function()
        local L = LocaleKit:GetLocale("MyAddon", { missing = "silent" })
        assertReportedAtCaller(
            "LocaleKit:GetLocale MyAddon already uses options.maxMissingKeys 1024, not 2",
            function(mark)
                mark()
                LocaleKit:GetLocale("MyAddon", { maxMissingKeys = 2 })
            end
        )
        assertReportedAtCaller(
            "LocaleKit:GetLocale MyAddon already uses options.maxMissingKeys 1024, not LocaleKit.UNBOUNDED",
            function(mark)
                mark()
                LocaleKit:GetLocale("MyAddon", { maxMissingKeys = LocaleKit.UNBOUNDED })
            end
        )
        readMissing(L, "key", 5)
        assert.are.equal(5, #LocaleKit:MissingKeys("MyAddon"))
    end)

    it("refuses invalid values at the caller's line and changes nothing", function()
        local invalid = { 0, -1, 1.5, 0 / 0, math.huge, -math.huge, "10", true, {} }
        for index = 1, #invalid do
            assertReportedAtCaller(LIMIT_MESSAGE, function(mark)
                mark()
                LocaleKit:GetLocale("MyAddon", { maxMissingKeys = invalid[index] })
            end)
        end

        local L = LocaleKit:GetLocale("MyAddon", { missing = "silent", maxMissingKeys = 1 })
        assert.is_false((pcall(LocaleKit.GetLocale, LocaleKit, "MyAddon", {
            missing = "raw",
            maxMissingKeys = 50,
        })))
        readMissing(L, "key", 2)
        assert.are.equal(1, #LocaleKit:MissingKeys("MyAddon"))
    end)

    it("refuses a secret maxMissingKeys at the caller", function()
        local secret = 5
        TestEnv.InstallSecretProbe(secret)
        assertReportedAtCaller(LIMIT_MESSAGE, function(mark)
            mark()
            LocaleKit:GetLocale("MyAddon", { maxMissingKeys = secret })
        end)
    end)
end)
