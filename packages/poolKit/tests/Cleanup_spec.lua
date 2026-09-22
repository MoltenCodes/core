local Env = require("PoolKitTestEnv")

describe("PoolKit cleanup", function()
    before_each(function() Env.Reset() end)
    after_each(function() Env.Reset() end)

    it("clears retained objects without affecting active objects", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({ create = function() return {} end, prewarm = 3 })
        local active = pool:Acquire()
        assert.are.equal(2, pool:GetAvailableCount())
        assert.are.equal(2, pool:Clear())
        assert.are.equal(0, pool:GetAvailableCount())
        assert.is_true(pool:IsActive(active))
        pool:Release(active)
    end)

    it("closes terminally but still accepts outstanding releases", function()
        local PoolKit = Env.NewPackage()
        local destroyed = 0
        local pool = PoolKit:New({
            create = function() return {} end,
            destroy = function() destroyed = destroyed + 1 end,
            prewarm = 2,
        })
        local active = pool:Acquire()
        assert.is_true(pool:Close())
        assert.is_true(pool:IsClosed())
        assert.has_error(function() pool:Acquire() end)
        assert.has_error(function() pool:Prewarm(1) end)
        pool:Release(active)
        assert.are.equal(2, destroyed)
        assert.is_false(pool:Close())
    end)

    it("continues bulk destroy after an error and rethrows the first", function()
        local PoolKit = Env.NewPackage()
        local calls = 0
        local pool = PoolKit:New({
            create = function() return {} end,
            destroy = function()
                calls = calls + 1
                if calls == 1 then error("first", 0) end
            end,
            prewarm = 3,
        })
        local ok, value = pcall(function() pool:Clear() end)
        assert.is_false(ok)
        assert.are.equal("first", value)
        assert.are.equal(3, calls)
        assert.are.equal(0, pool:GetAvailableCount())
        assert.are.equal(3, pool:GetDiscardedCount())
    end)
    it("publishes the detached trim snapshot and rejects destroy-time mutation", function()
        local PoolKit = Env.NewPackage()
        local pool
        local observedAvailable = -1
        pool = PoolKit:New({
            create = function() return {} end,
            destroy = function()
                observedAvailable = pool:GetAvailableCount()
                assert.has_error(function() pool:Acquire() end)
            end,
            prewarm = 2,
        })
        assert.are.equal(2, pool:Clear())
        assert.are.equal(0, observedAvailable)
        assert.are.equal(0, pool:GetAvailableCount())
    end)

end)
