local TestEnv = require("SignalKitTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("SignalKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to be loaded first", function()
        TestEnv.Reset()

        expectErrorContaining("requires Registry API 2", function()
            require("SignalKit")
        end)
    end)

    it("rejects an incomplete existing SignalKit facade before registration", function()
        TestEnv.Reset()
        local Registry = require("Registry")
        Registry:Register("signalKit", 1, 1)

        expectErrorContaining("corrupted or incomplete", function()
            require("SignalKit")
        end)
    end)

    it("rejects an incompatible Registry facade", function()
        TestEnv.Reset()
        rawset(_G, "MoltenCodes", { Registry = { API = 1 } })

        expectErrorContaining("requires Registry API 2", function()
            require("SignalKit")
        end)
    end)

    it("registers itself as SignalKit API 1 revision 1", function()
        local SignalKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("signalKit", 1)

        assert.are.equal(SignalKit, selected)
        assert.are.equal(1, revision)
        assert.are.equal(1, SignalKit.API)
        assert.are.equal(1, SignalKit.REVISION)
    end)

    it("reuses the same package facade on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local second = TestEnv.ReloadPackage()

        assert.are.equal(first, second)
    end)

    it("does not reset existing signals on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local signal = first:New()
        local calls = 0

        signal:Connect(function()
            calls = calls + 1
        end)

        local second = TestEnv.ReloadPackage()
        signal:Fire()

        assert.are.equal(first, second)
        assert.are.equal(1, calls)
    end)

    it("keeps the connection method table stable on duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local connectionMethods = first.Connection
        local second = TestEnv.ReloadPackage()

        assert.are.equal(connectionMethods, second.Connection)
    end)
end)
