local Env = require("PoolKitTestEnv")

describe("PoolKit ownership", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("rejects foreign and duplicate releases", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
        })
        local object = pool:Acquire()
        assert.has_error(function()
            pool:Release({})
        end)
        pool:Release(object)
        assert.has_error(function()
            pool:Release(object)
        end)
        assert.are.equal(0, pool:GetActiveCount())
        assert.are.equal(1, pool:GetAvailableCount())
    end)

    it("detects duplicate release after overflow without retaining the object", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 0,
        })
        local object = pool:Acquire()
        pool:Release(object)
        assert.are.equal(0, pool:GetAvailableCount())
        assert.are.equal(1, pool:GetDiscardedCount())
        assert.has_error(function()
            pool:Release(object)
        end)
        assert.is_false(pool:Owns(object))
    end)

    it("rolls reset errors back to active ownership", function()
        local PoolKit = Env.NewPackage()
        local fail = true
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                if fail then
                    error("reset failed")
                end
            end,
        })
        local object = pool:Acquire()
        assert.has_error(function()
            pool:Release(object)
        end)
        assert.is_true(pool:IsActive(object))
        assert.are.equal(1, pool:GetActiveCount())
        fail = false
        pool:Release(object)
        assert.are.equal(0, pool:GetActiveCount())
    end)

    it("rejects reentrant release of the same object", function()
        local PoolKit = Env.NewPackage()
        local pool
        pool = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function(object)
                assert.has_error(function()
                    pool:Release(object)
                end)
            end,
        })
        local object = pool:Acquire()
        pool:Release(object)
        assert.are.equal(1, pool:GetAvailableCount())
    end)
    it("keeps mandatory ownership safety when strict history is disabled", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 0,
            strict = false,
        })
        local object = pool:Acquire()
        pool:Release(object)
        assert.has_error(function()
            pool:Release(object)
        end)
        assert.has_error(function()
            pool:Release({})
        end)
        assert.are.equal(0, pool:GetActiveCount())
    end)
end)
