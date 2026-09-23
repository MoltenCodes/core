local TestEnv = require("CacheKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CacheKit allocation", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing for a Get hit, a Get miss or a Peek", function()
        local cache = CacheKit:NewLru({ maxEntries = 8 })
        for index = 1, 8 do
            cache:Set(index, index)
        end

        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                cache:Get(index % 8 + 1)
                cache:Get("missing")
                cache:Peek(index % 8 + 1)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Get allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing when Set overwrites an existing key", function()
        local cache = CacheKit:NewTtl({ maxEntries = 8, ttlSeconds = 60 })
        for index = 1, 8 do
            cache:Set(index, index)
        end

        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                cache:Set(index % 8 + 1, index)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Set allocated " .. allocated .. " KiB")
    end)

    it("reuses the evicted entry when Set adds a key to a full cache", function()
        local cache = CacheKit:NewLru({ maxEntries = 8 })
        local keys = {}
        for index = 1, 16 do
            keys[index] = "key" .. index
        end
        -- Warm the hash part with every key once so the measured loop does not
        -- pay for the entries table growing to its steady-state size.
        for round = 1, 2 do
            for index = 1, 16 do
                cache:Set(keys[index], round)
            end
        end

        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                cache:Set(keys[index % 16 + 1], index)
            end
        end)
        assert.is_true(allocated < 4, "eviction allocated " .. allocated .. " KiB")
        assert.are.equal(8, cache:GetCount())
    end)

    it("reuses entries from the free list after a Delete", function()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:Set("a", 1)
        cache:Set("b", 2)

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                cache:Delete("a")
                cache:Set("a", 1)
            end
        end)
        assert.is_true(allocated < 4, "delete and set allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing for a memoised hit", function()
        local compute = CacheKit:Memoize(function(key)
            return key * 2
        end)
        compute(1)

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                compute(1)
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "memoised hit allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing for a snapshot refresh in which nothing changed", function()
        local keys = {}
        local values = {}
        for index = 1, 64 do
            keys[index] = "unit" .. index
            values[index] = index
        end
        local snapshot = CacheKit:NewSnapshot(function(fill)
            for index = 1, #keys do
                fill(keys[index], values[index])
            end
        end)
        snapshot:Refresh()
        snapshot:Refresh()

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 200 do
                snapshot:Refresh()
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "refresh allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing per unchanged key when some keys do change", function()
        local keys = {}
        local values = {}
        for index = 1, 64 do
            keys[index] = "unit" .. index
            values[index] = index
        end
        local snapshot = CacheKit:NewSnapshot(function(fill)
            for index = 1, #keys do
                fill(keys[index], values[index])
            end
        end)
        snapshot:Refresh()
        values[1] = -1
        snapshot:Refresh()

        local mismatches = 0
        local allocated = TestEnv.AllocatedKilobytes(function()
            for round = 1, 200 do
                values[1] = round
                local _, _, changed = snapshot:Refresh()
                if #changed ~= 1 then
                    mismatches = mismatches + 1
                end
            end
        end)
        assert.are.equal(0, mismatches)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "refresh allocated " .. allocated .. " KiB")
    end)
end)
