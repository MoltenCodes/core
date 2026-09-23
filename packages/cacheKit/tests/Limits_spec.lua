local TestEnv = require("CacheKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("CacheKit limits", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("publishes one UNBOUNDED sentinel table", function()
        assert.are.equal("table", type(CacheKit.UNBOUNDED))
        assert.are.equal(CacheKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
    end)

    it("keeps the default bounds of Memoize and NewSnapshot", function()
        local compute, cache = CacheKit:Memoize(function(key)
            return key
        end)
        for key = 1, 200 do
            compute(key)
        end
        assert.are.equal(128, cache:GetCount())

        local snapshot = CacheKit:NewSnapshot(function(fill)
            for key = 1, 1025 do
                fill(key, true)
            end
        end)
        assert.has_error(function()
            snapshot:Refresh()
        end)
        assert.are.equal(0, snapshot:GetCount())
    end)

    it("holds every entry of an LRU or TTL cache opened with UNBOUNDED", function()
        local lru = CacheKit:NewLru({ maxEntries = CacheKit.UNBOUNDED })
        local ttl = CacheKit:NewTtl({ maxEntries = CacheKit.UNBOUNDED, ttlSeconds = 5 })
        for key = 1, 5000 do
            lru:Set(key, key)
            ttl:Set(key, key)
        end
        assert.are.equal(5000, lru:GetCount())
        assert.are.equal(5000, ttl:GetCount())
        assert.are.equal(0, lru:GetStats().evictions)
        assert.are.equal(1, lru:Get(1))

        TestEnv.AdvanceMs(5000)
        assert.is_nil(ttl:Get(1))
    end)

    it("remembers every result of a memoised function opened with UNBOUNDED", function()
        local calls = 0
        local compute, cache = CacheKit:Memoize(function(key)
            calls = calls + 1
            return key
        end, { maxEntries = CacheKit.UNBOUNDED })
        for key = 1, 3000 do
            compute(key)
        end
        assert.are.equal(3000, cache:GetCount())
        compute(1)
        assert.are.equal(3000, calls)
    end)

    it("fills any number of keys into a snapshot opened with UNBOUNDED", function()
        local snapshot = CacheKit:NewSnapshot(function(fill)
            for key = 1, 5000 do
                fill(key, key)
            end
        end, { maxEntries = CacheKit.UNBOUNDED })
        local added = snapshot:Refresh()
        assert.are.equal(5000, #added)
        assert.are.equal(5000, snapshot:GetCount())
    end)

    it("keeps at most 1024 blank entries on an unbounded cache's free list", function()
        local cache = CacheKit:NewLru({ maxEntries = CacheKit.UNBOUNDED })
        for key = 1, 3000 do
            cache:Set(key, key)
        end
        assert.are.equal(3000, cache:Clear())
        assert.are.equal(1024, cache._freeCount)

        for key = 1, 3000 do
            cache:Set(key, key)
        end
        assert.are.equal(0, cache._freeCount)
        for key = 1, 2000 do
            cache:Delete(key)
        end
        assert.are.equal(1024, cache._freeCount)
    end)

    it("refuses another table as maxEntries at the caller's line", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            CacheKit:NewLru({ maxEntries = {} })
        end)
        assertReportedAt(
            line,
            "CacheKit:NewLru maxEntries must be a positive integer or CacheKit.UNBOUNDED",
            ok,
            value
        )

        local ttlLine
        local ttlOk, ttlValue = pcall(function()
            ttlLine = currentLine() + 1
            CacheKit:NewTtl({ maxEntries = math.huge, ttlSeconds = 1 })
        end)
        assertReportedAt(
            ttlLine,
            "CacheKit:NewTtl maxEntries must be a positive integer or CacheKit.UNBOUNDED",
            ttlOk,
            ttlValue
        )
    end)

    it("keeps the sentinel and unbounded caches across an in-place upgrade", function()
        local sentinel = CacheKit.UNBOUNDED
        local cache = CacheKit:NewLru({ maxEntries = sentinel })
        for key = 1, 300 do
            cache:Set(key, key)
        end

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(2, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(sentinel, upgraded._state.unbounded)

        for key = 301, 2000 do
            cache:Set(key, key)
        end
        assert.are.equal(2000, cache:GetCount())
        assert.are.equal(0, cache:GetStats().evictions)

        local after = upgraded:Memoize(function(key)
            return key
        end, { maxEntries = sentinel })
        assert.are.equal(1, after(1))
    end)
end)
