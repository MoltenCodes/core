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

    it("raises corrupted state found through Bootstrap at the Bootstrap call", function()
        ---A request for `demoKit` API 1 at `revision`.
        local function request(revision, fields)
            local built = {
                package = "demoKit",
                api = 1,
                revision = revision,
                label = "MoltenCodes DemoKit",
                validatePublicSurface = function()
                    return true
                end,
            }
            for key, value in pairs(fields or {}) do
                built[key] = value
            end
            return built
        end

        ---Install revision 1 of `demoKit` with a complete facade.
        local function installRevisionOne()
            local implementation = Registry:Bootstrap(request(1))
            implementation.API = 1
            implementation.REVISION = 1
        end

        ---Corrupt `demoKit`'s entry the way a hand edit would.
        local function corruptEntry()
            rawset(state.entries.demoKit, 1, "corrupted")
        end

        local source = debug.getinfo(1, "S").short_src
        local cases = {
            -- The existing-copy lookup: the bucket itself is damaged.
            function()
                rawset(state.entries, "demoKit", "corrupted")
                local line
                local ok, message = pcall(function()
                    line = debug.getinfo(1, "l").currentline + 1
                    Registry:Bootstrap(request(2))
                end)
                return line, ok, message
            end,
            -- Registration, after a retire hook damaged the entry it hands over.
            function()
                installRevisionOne()
                Registry:OnRetire("demoKit", 1, corruptEntry)
                local line
                local ok, message = pcall(function()
                    line = debug.getinfo(1, "l").currentline + 1
                    Registry:Bootstrap(request(2))
                end)
                return line, ok, message
            end,
            -- `adopt`, after a resume hook damaged the entry it adopts.
            function()
                installRevisionOne()
                local resume = function()
                    corruptEntry()
                    return 1
                end
                local line
                local ok, message = pcall(function()
                    line = debug.getinfo(1, "l").currentline + 1
                    Registry:Bootstrap(request(1, { resume = resume }))
                end)
                return line, ok, message
            end,
        }

        for index = 1, #cases do
            rawset(state.entries, "demoKit", nil)
            local line, ok, message = cases[index]()
            message = tostring(message)

            assert.is_false(ok, "case " .. index)
            assert.is_not_nil(string.find(message, "package state is corrupted", 1, true), message)
            assert.are.equal(
                1,
                string.find(message, source .. ":" .. line .. ":", 1, true),
                message
            )
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
