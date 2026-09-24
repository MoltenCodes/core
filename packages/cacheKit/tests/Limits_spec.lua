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

    describe("maxQueueCapacity", function()
        it("defaults to 1024 and bounds the capacity NewQueue accepts", function()
            assert.are.same({ maxQueueCapacity = 1024 }, CacheKit:GetLimits())
            assert.are.equal(1024, CacheKit:NewQueue(1024, "reject"):GetCapacity())
            TestEnv.expectErrorContaining(
                "CacheKit:NewQueue capacity must be an integer from 1 to 1024 "
                    .. "(CacheKit:SetLimits maxQueueCapacity)",
                function()
                    CacheKit:NewQueue(1025, "reject")
                end
            )
        end)

        it("honours a larger value up to the 65536 ceiling", function()
            CacheKit:SetLimits({ maxQueueCapacity = 65536 })
            assert.are.equal(65536, CacheKit:NewQueue(65536, "dropOldest"):GetCapacity())
            TestEnv.expectErrorContaining(
                "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
                function()
                    CacheKit:SetLimits({ maxQueueCapacity = 65537 })
                end
            )
            assert.are.equal(65536, CacheKit:GetLimits().maxQueueCapacity)
        end)

        it("never shrinks an existing queue when lowered", function()
            local queue = CacheKit:NewQueue(8, "reject")
            for value = 1, 8 do
                queue:Push(value)
            end
            CacheKit:SetLimits({ maxQueueCapacity = 4 })
            assert.are.equal(8, queue:GetCapacity())
            assert.are.equal(8, queue:GetCount())
            TestEnv.expectErrorContaining("capacity must be an integer from 1 to 4", function()
                CacheKit:NewQueue(5, "reject")
            end)
            assert.are.equal(4, CacheKit:NewQueue(4, "reject"):GetCapacity())
        end)

        it("refuses UNBOUNDED at the caller with its reason", function()
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                CacheKit:SetLimits({ maxQueueCapacity = CacheKit.UNBOUNDED })
            end)
            assertReportedAt(
                line,
                "CacheKit:SetLimits limits.maxQueueCapacity cannot be CacheKit.UNBOUNDED: "
                    .. "the ring is allocated when the queue is created",
                ok,
                value
            )

            local queueLine
            local queueOk, queueValue = pcall(function()
                queueLine = currentLine() + 1
                CacheKit:NewQueue(CacheKit.UNBOUNDED, "reject")
            end)
            assertReportedAt(
                queueLine,
                "CacheKit:NewQueue capacity cannot be CacheKit.UNBOUNDED: "
                    .. "the ring is allocated when the queue is created",
                queueOk,
                queueValue
            )
        end)

        it("refuses invalid values, unknown names and a non-table at the caller", function()
            for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", true }) do
                TestEnv.expectErrorContaining(
                    "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
                    function()
                        CacheKit:SetLimits({ maxQueueCapacity = invalid })
                    end
                )
            end
            TestEnv.expectErrorContaining(
                "CacheKit:SetLimits limits.maxEntries is not a recognised limit",
                function()
                    CacheKit:SetLimits({ maxEntries = 5 })
                end
            )
            TestEnv.expectErrorContaining(
                "CacheKit:SetLimits limits.1 is not a recognised limit",
                function()
                    CacheKit:SetLimits({ 5 })
                end
            )
            TestEnv.expectErrorContaining("CacheKit:SetLimits limits must be a table", function()
                CacheKit:SetLimits()
            end)
            assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
        end)

        it("is atomic: one invalid entry changes nothing", function()
            assert.has_error(function()
                CacheKit:SetLimits({ maxQueueCapacity = 16, unknown = 1 })
            end)
            assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
            CacheKit:SetLimits({})
            assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
        end)

        it("returns a fresh table from GetLimits and refuses a stray receiver", function()
            local first = CacheKit:GetLimits()
            first.maxQueueCapacity = 1
            assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
            assert.are_not.equal(first, CacheKit:GetLimits())
            TestEnv.expectErrorContaining(
                "CacheKit:SetLimits must be called on the CacheKit facade",
                function()
                    CacheKit.SetLimits({}, { maxQueueCapacity = 8 })
                end
            )
        end)

        it("is shared by every embedded copy and kept across an in-place upgrade", function()
            CacheKit:SetLimits({ maxQueueCapacity = 2048 })
            assert.are.equal(2048, TestEnv.ReloadPackage():GetLimits().maxQueueCapacity)
            local upgraded = TestEnv.LoadRevision(3)
            assert.are.same({ maxQueueCapacity = 2048 }, upgraded:GetLimits())
            assert.are.equal(2048, upgraded:NewQueue(2048, "reject"):GetCapacity())
        end)
    end)

    it("keeps the sentinel and unbounded caches across an in-place upgrade", function()
        local sentinel = CacheKit.UNBOUNDED
        local cache = CacheKit:NewLru({ maxEntries = sentinel })
        for key = 1, 300 do
            cache:Set(key, key)
        end

        local upgraded = TestEnv.LoadRevision(3)
        assert.are.equal(3, upgraded.REVISION)
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
