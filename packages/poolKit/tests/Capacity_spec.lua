local Env = require("PoolKitTestEnv")

describe("PoolKit capacity", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("discards overflow and calls destroy", function()
        local PoolKit = Env.NewPackage()
        local destroyed = 0
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            destroy = function()
                destroyed = destroyed + 1
            end,
            maxRetained = 1,
        })
        local a, b = pool:Acquire(), pool:Acquire()
        pool:Release(a)
        pool:Release(b)
        assert.are.equal(1, pool:GetAvailableCount())
        assert.are.equal(1, pool:GetDiscardedCount())
        assert.are.equal(1, destroyed)
    end)

    it("supports an explicit unbounded retention escape hatch", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = PoolKit.UNBOUNDED,
        })
        local values = {}
        for i = 1, 300 do
            values[i] = pool:Acquire()
        end
        for i = 1, 300 do
            pool:Release(values[i])
        end
        assert.are.equal(300, pool:GetAvailableCount())
        assert.are.equal(PoolKit.UNBOUNDED, pool:GetMaxRetained())
    end)

    it("prewarms to a target and is idempotent", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 8,
        })
        assert.are.equal(4, pool:Prewarm(4))
        assert.are.equal(0, pool:Prewarm(4))
        assert.are.equal(4, pool:GetAvailableCount())
        assert.are.equal(4, pool:GetCreatedCount())
        assert.has_error(function()
            pool:Prewarm(9)
        end)
    end)

    it("trims immediately when maxRetained is lowered", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            prewarm = 5,
            maxRetained = 5,
        })
        pool:SetMaxRetained(2)
        assert.are.equal(2, pool:GetAvailableCount())
        assert.are.equal(3, pool:GetDiscardedCount())
        assert.are.equal(pool, pool:SetMaxRetained(PoolKit.UNBOUNDED))
    end)
end)
