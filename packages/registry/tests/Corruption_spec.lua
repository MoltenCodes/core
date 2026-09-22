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
end)
