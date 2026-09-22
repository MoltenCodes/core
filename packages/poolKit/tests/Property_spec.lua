local Env = require("PoolKitTestEnv")

describe("PoolKit state properties", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("keeps active plus available equal to currently owned objects", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 16,
        })
        local active = {}
        local seed = 99173
        local function random(maximum)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return (seed % maximum) + 1
        end

        for _ = 1, 5000 do
            if #active == 0 or random(3) ~= 1 then
                active[#active + 1] = pool:Acquire()
            else
                local index = random(#active)
                local object = active[index]
                active[index] = active[#active]
                active[#active] = nil
                pool:Release(object)
            end
            assert.are.equal(#active, pool:GetActiveCount())
            assert.is_true(pool:GetAvailableCount() <= 16)
            assert.are.equal(
                pool:GetCreatedCount(),
                pool:GetActiveCount() + pool:GetAvailableCount() + pool:GetDiscardedCount()
            )
        end
    end)
    it("preserves accounting through resizing, prewarming, and clearing", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:New({
            create = function()
                return {}
            end,
            maxRetained = 16,
        })
        local active = {}
        local seed = 171717
        local function random(maximum)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return (seed % maximum) + 1
        end

        for _ = 1, 5000 do
            local operation = random(5)
            if operation == 1 or #active == 0 then
                active[#active + 1] = pool:Acquire()
            elseif operation == 2 then
                local index = random(#active)
                local object = active[index]
                active[index] = active[#active]
                active[#active] = nil
                pool:Release(object)
            elseif operation == 3 then
                local limit = random(17) - 1
                pool:SetMaxRetained(limit)
            elseif operation == 4 then
                local maxRetained = pool:GetMaxRetained()
                local target = 0
                if maxRetained ~= PoolKit.UNBOUNDED then
                    target = random(maxRetained + 1) - 1
                end
                pool:Prewarm(target)
            else
                pool:Clear()
            end

            assert.are.equal(#active, pool:GetActiveCount())
            local maxRetained = pool:GetMaxRetained()
            if maxRetained ~= PoolKit.UNBOUNDED then
                assert.is_true(pool:GetAvailableCount() <= maxRetained)
            end
            assert.are.equal(
                pool:GetCreatedCount(),
                pool:GetActiveCount() + pool:GetAvailableCount() + pool:GetDiscardedCount()
            )
        end
    end)
end)
