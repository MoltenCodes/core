local TestEnv = require("RegistryTestEnv")

describe("RegistryTestEnv", function()
    before_each(TestEnv.Reset)
    after_each(TestEnv.Reset)

    it("creates a fresh Registry instance", function()
        local first = TestEnv.NewRegistry()
        local implementation = first:Register("exampleKit", 1, 1)
        implementation.marker = true

        local second = TestEnv.NewRegistry()

        assert.are_not.equal(first, second)
        assert.is_nil(second:Get("exampleKit", 1))
    end)

    it("clears the Registry module cache", function()
        require("Registry")
        assert.is_not_nil(package.loaded["Registry"])

        TestEnv.Reset()

        assert.is_nil(package.loaded["Registry"])
    end)

    it("clears the Registry bootstrap state", function()
        require("Registry")
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_not_nil(rawget(_G, TestEnv.STATE_KEY))

        TestEnv.Reset()

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, TestEnv.STATE_KEY))
    end)

    it("clears the public test namespace", function()
        require("Registry")
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_not_nil(rawget(_G, TestEnv.NAMESPACE_KEY))

        TestEnv.Reset()

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, TestEnv.NAMESPACE_KEY))
    end)

    it("is safe to reset repeatedly", function()
        TestEnv.Reset()
        TestEnv.Reset()

        assert.is_nil(package.loaded["Registry"])
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, TestEnv.STATE_KEY))
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, TestEnv.NAMESPACE_KEY))
    end)

    it("preserves unrelated loaded modules", function()
        local marker = {}
        package.loaded["registry-test-unrelated"] = marker

        TestEnv.Reset()

        assert.are.equal(marker, package.loaded["registry-test-unrelated"])
        package.loaded["registry-test-unrelated"] = nil
    end)
end)
