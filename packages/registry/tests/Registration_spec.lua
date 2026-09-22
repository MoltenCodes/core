local TestEnv = require("RegistryTestEnv")

describe("Registry registration", function()
    local Registry

    before_each(function()
        Registry = TestEnv.NewRegistry()
    end)

    after_each(TestEnv.Reset)

    it("creates one shared package table for the first revision", function()
        local implementation, previousRevision = Registry:Register("exampleKit", 1, 1)
        local selected, selectedRevision = Registry:Get("exampleKit", 1)

        assert.is_not_nil(implementation)
        assert.is_nil(previousRevision)
        assert.are.equal(implementation, selected)
        assert.are.equal(1, selectedRevision)
    end)

    it("upgrades the same package table in place", function()
        local first = Registry:Register("exampleKit", 1, 2)
        first.marker = "revision-2"

        local upgraded, previousRevision = Registry:Register("exampleKit", 1, 8)
        upgraded.marker = "revision-8"

        local selected, selectedRevision = Registry:Get("exampleKit", 1)

        assert.are.equal(first, upgraded)
        assert.are.equal(first, selected)
        assert.are.equal(2, previousRevision)
        assert.are.equal(8, selectedRevision)
        assert.are.equal("revision-8", first.marker)
    end)

    it("rejects a lower revision without exposing the shared table for mutation", function()
        local current = Registry:Register("exampleKit", 1, 8)
        current.marker = "current"

        local rejected = Registry:Register("exampleKit", 1, 3)
        local selected, selectedRevision = Registry:Get("exampleKit", 1)

        assert.is_nil(rejected)
        assert.are.equal(current, selected)
        assert.are.equal(8, selectedRevision)
        assert.are.equal("current", selected.marker)
    end)

    it("rejects an equal revision", function()
        local first = Registry:Register("exampleKit", 1, 5)
        first.marker = "first"

        local rejected = Registry:Register("exampleKit", 1, 5)

        assert.is_nil(rejected)
        assert.are.equal("first", Registry:Get("exampleKit", 1).marker)
    end)

    it("keeps package namespaces independent", function()
        local example = Registry:Register("exampleKit", 1, 1)
        local other = Registry:Register("signalKit", 1, 1)

        assert.are_not.equal(example, other)
        assert.are.equal(example, Registry:Get("exampleKit", 1))
        assert.are.equal(other, Registry:Get("signalKit", 1))
    end)

    it("keeps API generations independent", function()
        local api1 = Registry:Register("exampleKit", 1, 1)
        local api2 = Registry:Register("exampleKit", 2, 1)

        assert.are_not.equal(api1, api2)
        assert.are.equal(api1, Registry:Get("exampleKit", 1))
        assert.are.equal(api2, Registry:Get("exampleKit", 2))
    end)

    it("returns nil for an unknown package", function()
        assert.is_nil(Registry:Get("missing", 1))
    end)

    it("returns nil for an unknown API generation", function()
        Registry:Register("exampleKit", 1, 1)

        assert.is_nil(Registry:Get("exampleKit", 2))
    end)
end)
