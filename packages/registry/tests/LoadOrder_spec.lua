local TestEnv = require("RegistryTestEnv")

local function resolve(order)
    local Registry = TestEnv.NewRegistry()

    for index = 1, #order do
        local revision = order[index]
        local implementation = Registry:Register("exampleKit", 1, revision)
        if implementation ~= nil then
            implementation.marker = revision
        end
    end

    local info = Registry:GetInfo("exampleKit", 1)
    return info.revision, info.implementation.marker, info.implementation
end

describe("Registry load-order behavior", function()
    after_each(TestEnv.Reset)

    it("selects the highest revision regardless of registration order", function()
        local revisionA, markerA = resolve({ 2, 11, 5 })
        local revisionB, markerB = resolve({ 5, 2, 11 })
        local revisionC, markerC = resolve({ 11, 5, 2 })

        assert.are.equal(11, revisionA)
        assert.are.equal(11, revisionB)
        assert.are.equal(11, revisionC)
        assert.are.equal(11, markerA)
        assert.are.equal(11, markerB)
        assert.are.equal(11, markerC)
    end)

    it("keeps one stable implementation table across accepted upgrades", function()
        local Registry = TestEnv.NewRegistry()

        local first = Registry:Register("exampleKit", 1, 2)
        local second = Registry:Register("exampleKit", 1, 11)

        assert.are.equal(first, second)
    end)

    it("keeps the first initializer when equal revisions race", function()
        local Registry = TestEnv.NewRegistry()

        local first = Registry:Register("exampleKit", 1, 7)
        first.marker = "first"

        local second = Registry:Register("exampleKit", 1, 7)

        assert.is_nil(second)
        assert.are.equal("first", Registry:Get("exampleKit", 1).marker)
    end)
end)
