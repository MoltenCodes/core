local Env = require("PoolKitTestEnv")

---Build a pool whose destroyed objects are recorded in `destroyed`.
local function newRecordingPool(PoolKit, destroyed, options)
    options = options or {}
    options.create = function()
        return {}
    end
    options.destroy = function(object)
        destroyed[#destroyed + 1] = object
    end
    -- Not a tail call, so an error raised at the caller's line names this file.
    local pool = PoolKit:New(options)
    return pool
end

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true))
    assert.is_not_nil(string.find(message, "packages/poolKit/tests/Generation_spec.lua:", 1, true))
end

describe("PoolKit generations", function()
    after_each(Env.Reset)

    it("defaults a pool's generation to the PoolKit revision that created it", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:NewTablePool()

        assert.are.equal(PoolKit.REVISION, pool:GetGeneration())
    end)

    it("accepts an explicit generation on both constructors", function()
        local PoolKit = Env.NewPackage()
        local generic = newRecordingPool(PoolKit, {}, { generation = 7 })
        local tables = PoolKit:NewTablePool({ generation = 2 })

        assert.are.equal(7, generic:GetGeneration())
        assert.are.equal(2, tables:GetGeneration())
    end)

    it("rejects a generation that is not a positive integer at the caller's line", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:NewTablePool()

        expectErrorAtThisSpec("PoolKit:New generation must be a positive integer", function()
            newRecordingPool(PoolKit, {}, { generation = 0 })
        end)
        expectErrorAtThisSpec(
            "PoolKit:NewTablePool generation must be a positive integer",
            function()
                PoolKit:NewTablePool({ generation = 1.5 })
            end
        )
        expectErrorAtThisSpec(
            "PoolKit.Pool:SetGeneration generation must be a positive integer",
            function()
                pool:SetGeneration("2")
            end
        )
    end)

    it("destroys retained objects of an older generation as soon as it is raised", function()
        local PoolKit = Env.NewPackage()
        local destroyed = {}
        local pool = newRecordingPool(PoolKit, destroyed, { generation = 1 })
        local first, second = pool:Acquire(), pool:Acquire()
        pool:Release(first)
        pool:Release(second)

        assert.are.equal(2, pool:SetGeneration(2))

        assert.are.equal(2, pool:GetGeneration())
        assert.are.equal(0, pool:GetAvailableCount())
        -- Stale objects are destroyed in stack order, bottom first.
        assert.are.same({ first, second }, destroyed)
        assert.is_false(pool:Owns(first))
    end)

    it("retires a borrowed object of an older generation when it comes back", function()
        local PoolKit = Env.NewPackage()
        local destroyed = {}
        local pool = newRecordingPool(PoolKit, destroyed, { generation = 1 })
        local old = pool:Acquire()

        pool:SetGeneration(2)
        local fresh = pool:Acquire()

        assert.is_true(pool:Release(old))
        assert.are.same({ old }, destroyed)
        assert.is_true(pool:Release(fresh))
        assert.are.equal(1, pool:GetAvailableCount())
        assert.are.equal(fresh, pool:Acquire())
    end)

    it("retires objects of every superseded generation, not just the first", function()
        local PoolKit = Env.NewPackage()
        local destroyed = {}
        local pool = newRecordingPool(PoolKit, destroyed, { generation = 1 })
        pool:SetGeneration(2)
        local second = pool:Acquire()
        pool:SetGeneration(3)
        local third = pool:Acquire()

        pool:Release(second)
        pool:Release(third)

        assert.are.same({ second }, destroyed)
        assert.are.equal(1, pool:GetAvailableCount())
    end)

    it("refuses to lower the generation and treats the same value as a no-op", function()
        local PoolKit = Env.NewPackage()
        local pool = newRecordingPool(PoolKit, {}, { generation = 5 })
        pool:Release(pool:Acquire())

        expectErrorAtThisSpec("cannot lower the generation from 5 to 4", function()
            pool:SetGeneration(4)
        end)
        assert.are.equal(0, pool:SetGeneration(5))
        assert.are.equal(1, pool:GetAvailableCount())
    end)

    it("stamps in a side table and never writes to the object", function()
        local PoolKit = Env.NewPackage()
        local pool = newRecordingPool(PoolKit, {}, { generation = 1 })
        pool:SetGeneration(2)
        local object = pool:Acquire()

        assert.is_nil(next(object))
        assert.is_nil(getmetatable(object))
    end)

    it("keeps generations and stamps across a duplicate embedded load", function()
        local PoolKit = Env.NewPackage()
        local destroyed = {}
        local pool = newRecordingPool(PoolKit, destroyed, { generation = 1 })
        local old = pool:Acquire()
        pool:SetGeneration(2)
        local fresh = pool:Acquire()

        local reloaded = Env.ReloadPackage()

        assert.are.equal(PoolKit, reloaded)
        assert.are.equal(2, pool:GetGeneration())
        pool:Release(old)
        pool:Release(fresh)
        assert.are.same({ old }, destroyed)
        assert.are.equal(1, pool:GetAvailableCount())
    end)
end)
