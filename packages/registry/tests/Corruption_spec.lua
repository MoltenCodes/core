local TestEnv = require("RegistryTestEnv")

local function expectCorruption(callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "package state is corrupted", 1, true))
end

describe("Registry package-state corruption handling", function()
    local Registry
    local state

    before_each(function()
        Registry = TestEnv.NewRegistry()
        state = TestEnv.GetState()
    end)

    after_each(TestEnv.Reset)

    it("rejects a corrupted package bucket consistently", function()
        state.entries.exampleKit = "corrupted"

        expectCorruption(function()
            Registry:Get("exampleKit", 1)
        end)
        expectCorruption(function()
            Registry:GetInfo("exampleKit", 1)
        end)
        expectCorruption(function()
            Registry:Register("exampleKit", 1, 2)
        end)
    end)

    it("rejects malformed package entries consistently", function()
        local malformedEntries = {
            "corrupted",
            {},
            { revision = 0, implementation = {} },
            { revision = 1, implementation = "corrupted" },
        }

        for index = 1, #malformedEntries do
            state.entries.exampleKit = { [1] = malformedEntries[index] }

            expectCorruption(function()
                Registry:Get("exampleKit", 1)
            end)
            expectCorruption(function()
                Registry:GetInfo("exampleKit", 1)
            end)
            expectCorruption(function()
                Registry:Register("exampleKit", 1, 2)
            end)
        end
    end)

    it("raises corrupted state at the calling line, not inside Registry", function()
        state.entries.exampleKit = { [1] = "corrupted" }
        rawset(state.entries, "otherKit", "corrupted")
        local source = debug.getinfo(1, "S").short_src
        local calls = {
            function()
                Registry:Get("exampleKit", 1)
            end,
            function()
                Registry:GetInfo("exampleKit", 1)
            end,
            function()
                Registry:Find("exampleKit", 1)
            end,
            function()
                Registry:OnRetire("exampleKit", 1, function() end)
            end,
            function()
                Registry:Register("exampleKit", 1, 2)
            end,
            function()
                Registry:Get("otherKit", 1)
            end,
            function()
                Registry:Packages()
            end,
        }

        for index = 1, #calls do
            local ok, message = pcall(calls[index])
            message = tostring(message)

            assert.is_false(ok)
            assert.is_not_nil(string.find(message, "package state is corrupted", 1, true))
            assert.are.equal(1, string.find(message, source .. ":", 1, true), message)
        end
    end)

    it("refuses to list malformed state instead of returning it as rows", function()
        local malformedBuckets = {
            { [1] = { revision = 0, implementation = {} } },
            { [1] = { revision = 1, implementation = "corrupted" } },
            { api = { revision = 1, implementation = {} } },
            "corrupted",
        }

        for index = 1, #malformedBuckets do
            TestEnv.Reset()
            Registry = TestEnv.NewRegistry()
            state = TestEnv.GetState()
            Registry:Register("healthyKit", 1, 1)
            state.entries.exampleKit = malformedBuckets[index]

            expectCorruption(function()
                Registry:Packages()
            end)
        end
    end)
end)
