local Env = require("PoolKitTestEnv")

describe("PoolKit error semantics", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("preserves arbitrary reset error objects", function()
        local PoolKit = Env.NewPackage()
        local marker = {}
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                error(marker, 0)
            end,
        })
        local object = pool:Acquire()
        local ok, value = pcall(function()
            pool:Release(object)
        end)
        assert.is_false(ok)
        assert.are.equal(marker, value)
        assert.is_true(pool:IsActive(object))
    end)

    it("finalizes discard state before propagating destroy errors", function()
        local PoolKit = Env.NewPackage()
        local marker = {}
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 0,
            destroy = function()
                error(marker, 0)
            end,
        })
        local object = pool:Acquire()
        local ok, value = pcall(function()
            pool:Release(object)
        end)
        assert.is_false(ok)
        assert.are.equal(marker, value)
        assert.are.equal(0, pool:GetActiveCount())
        assert.are.equal(1, pool:GetDiscardedCount())
        assert.is_false(pool:Owns(object))
    end)
    it("rejects same-pool mutation from lifecycle callbacks without corrupting state", function()
        local PoolKit = Env.NewPackage()
        local pool
        pool = PoolKit:New({
            create = function(owner)
                assert.are.equal(pool, owner)
                assert.has_error(function()
                    owner:Prewarm(1)
                end)
                return {}
            end,
            reset = function(_, owner)
                assert.has_error(function()
                    owner:Clear()
                end)
            end,
        })
        local object = pool:Acquire()
        pool:Release(object)
        assert.are.equal(0, pool:GetActiveCount())
        assert.are.equal(1, pool:GetAvailableCount())
    end)
end)
