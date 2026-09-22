local TestEnv = require("RegistryTestEnv")

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

describe("Registry argument validation", function()
    local Registry

    before_each(function()
        Registry = TestEnv.NewRegistry()
    end)

    after_each(TestEnv.Reset)

    it("accepts lowerCamelCase Kit package names", function()
        local implementation = Registry:Register("signalKit", 1, 1)
        assert.is_table(implementation)
        assert.are.equal(implementation, Registry:Get("signalKit", 1))
    end)

    it("rejects invalid package names", function()
        expectErrorContaining("packageName", function()
            Registry:Register("EventKit", 1, 1)
        end)

        expectErrorContaining("packageName", function()
            Registry:Get("", 1)
        end)
    end)

    it("rejects invalid API generations", function()
        expectErrorContaining("api", function()
            Registry:Register("eventKit", 0, 1)
        end)

        expectErrorContaining("api", function()
            Registry:Get("eventKit", 1.5)
        end)
    end)

    it("rejects invalid revisions", function()
        expectErrorContaining("revision", function()
            Registry:Register("eventKit", 1, 0)
        end)

        expectErrorContaining("revision", function()
            Registry:Register("eventKit", 1, 2.5)
        end)
    end)

    it("rejects the obsolete implementation argument", function()
        expectErrorContaining("does not accept an implementation argument", function()
            Registry:Register("eventKit", 1, 1, {})
        end)
    end)

    it("rejects numbers too large to be exact integers", function()
        expectErrorContaining("revision must be a positive integer up to 2^53", function()
            Registry:Register("eventKit", 1, 1e300)
        end)

        expectErrorContaining("api must be a positive integer up to 2^53", function()
            Registry:Register("eventKit", 1e300, 1)
        end)

        expectErrorContaining("revision must be a positive integer", function()
            Registry:Register("eventKit", 1, math.huge)
        end)

        assert.is_table(Registry:Register("eventKit", 1, 2 ^ 53))
    end)

    it("points argument errors at the calling line, not at Registry", function()
        local function callerOfRegister()
            Registry:Register("eventKit", 1, 0)
        end

        local ok, message = pcall(callerOfRegister)
        message = tostring(message)

        assert.is_false(ok)
        assert.is_not_nil(
            string.find(message, "packages/registry/tests/Validation_spec.lua:", 1, true)
        )
        assert.is_nil(string.find(message, "src/Registry.lua", 1, true))
    end)

    it("does not create an entry when validation fails", function()
        pcall(function()
            Registry:Register("eventKit", 0, 1)
        end)

        assert.is_nil(Registry:Get("eventKit", 1))
    end)
end)
