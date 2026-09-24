local TestEnv = require("CacheKitTestEnv")

describe("CacheKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local CacheKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 2 })
        cache:Set("a", 1)

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(CacheKit, reloaded)
        assert.are.equal(1, cache:Get("a"))
    end)

    it("publishes through Registry", function()
        local CacheKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("cacheKit", 1)
        assert.are.equal(CacheKit, registered)
        assert.are.equal(CacheKit.REVISION, revision)
    end)

    it("loads with Registry alone", function()
        local CacheKit, Registry = TestEnv.NewPackageWithoutEventKit()
        assert.are.equal(CacheKit, Registry:Get("cacheKit", 1))
        local cache = CacheKit:NewLru({ maxEntries = 1 })
        cache:Set("a", 1)
        assert.are.equal(1, cache:Get("a"))
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local CacheKit, Registry = TestEnv.NewPackage()
        local shippedRevision = CacheKit.REVISION
        local upgraded, previous = Registry:Register("cacheKit", 1, 99)
        assert.are.equal(CacheKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(CacheKit, "REVISION", 99)
        rawset(CacheKit, "_state", { schema = 999 })
        package.loaded["CacheKit"] = nil

        local reloaded = require("CacheKit")
        assert.are.equal(CacheKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps every cache, entry and subscription", function()
        local CacheKit = TestEnv.NewPackage()
        local cachePrototype = CacheKit.Cache
        local lru = CacheKit:NewLru({ maxEntries = 2 })
        lru:Set("a", 1)
        lru:Set("b", 2)
        lru:Get("a")
        local ttl = CacheKit:NewTtl({ maxEntries = 2, ttlSeconds = 5 })
        ttl:Set("t", "timed")
        local calls = 0
        local compute, memoCache = CacheKit:Memoize(function(key)
            calls = calls + 1
            return key
        end)
        compute("m")
        memoCache:ClearOn("SPELLS_CHANGED")
        local source = { x = 1 }
        local snapshot = CacheKit:NewSnapshot(function(fill)
            for key, value in pairs(source) do
                fill(key, value)
            end
        end)
        snapshot:Refresh()

        local nextRevision = CacheKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(CacheKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(cachePrototype, upgraded.Cache)

        -- Entries, recency and statistics survive: "b" is still the least
        -- recently used entry, so it is the one evicted.
        assert.are.equal(2, lru:GetCount())
        lru:Set("c", 3)
        assert.is_nil(lru:Peek("b"))
        assert.are.equal(1, lru:Peek("a"))
        assert.are.equal(1, lru:GetStats().hits)

        TestEnv.AdvanceMs(5000)
        assert.is_nil(ttl:Get("t"))

        compute("m")
        assert.are.equal(1, calls)
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(0, memoCache:GetCount())

        source.y = 2
        local added = snapshot:Refresh()
        assert.are.same({ "y" }, added)
    end)

    it("carries lazy trees, queues and negative entries into a newer revision", function()
        local CacheKit = TestEnv.NewPackage()
        local lazyPrototype = CacheKit.LazyTree
        local queuePrototype = CacheKit.Queue
        local calls = 0
        local tree = CacheKit:Lazy(function(...)
            calls = calls + 1
            return select("#", ...)
        end, { maxEntries = 4 })
        tree:Get("a", "b")
        local queue = CacheKit:NewQueue(2, "dropOldest")
        queue:Push("first")
        queue:Push("second")
        local ttl = CacheKit:NewTtl({ maxEntries = 2, ttlSeconds = 60 })
        ttl:PutNegative("gone", 5)

        local upgraded = TestEnv.LoadRevision(CacheKit.REVISION + 1)
        assert.are.equal(CacheKit, upgraded)
        assert.are.equal(CacheKit.REVISION, upgraded.REVISION)
        assert.are.equal(lazyPrototype, upgraded.LazyTree)
        assert.are.equal(queuePrototype, upgraded.Queue)

        assert.are.equal(2, tree:Get("a", "b"))
        assert.are.equal(1, calls)
        assert.are.equal(1, tree:Invalidate("a"))
        assert.are.same({ true, "first" }, { queue:Push("third") })
        assert.are.equal("second", queue:Pop())
        assert.are.equal("negative", select(2, ttl:Get("gone")))
        assert.are.equal("negative", select(2, ttl:Peek("gone")))
    end)

    it("upgrades revision-1 state in place to schema 2", function()
        local shippedRevision = TestEnv.NewPackage().REVISION
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        local previous = TestEnv.LoadRevision(1)
        assert.are.equal(1, previous.REVISION)
        local ttl = previous:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
        ttl:Set("kept", 1)
        local calls = 0
        local compute, memoCache = previous:Memoize(function(key)
            calls = calls + 1
            return key
        end, { ttlSeconds = 60 })
        compute("m")
        -- A memoised closure as revision 1 built it: three arguments, no
        -- predicate.
        local dispatch = rawget(previous._state, "dispatch")
        local function legacyMemoized(key)
            return rawget(dispatch, "memoizedCall")(memoCache, function(value)
                calls = calls + 1
                return value
            end, key)
        end

        -- Reduce the facade and the state to the shape revision 1 left behind.
        local state = rawget(previous, "_state")
        rawset(state, "schema", 1)
        rawset(state, "lazyMetatable", nil)
        rawset(state, "queueMetatable", nil)
        rawset(state, "negative", nil)
        rawset(state, "limits", nil)
        rawset(previous, "LazyTree", nil)
        rawset(previous, "Queue", nil)
        rawset(previous, "Lazy", nil)
        rawset(previous, "NewQueue", nil)
        rawset(previous, "SetLimits", nil)
        rawset(previous, "GetLimits", nil)
        rawset(previous.Cache, "PutNegative", nil)

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.are.equal(shippedRevision, upgraded.REVISION)
        assert.are.equal(2, rawget(state, "schema"))
        assert.are.equal("table", type(rawget(state, "lazyMetatable")))
        assert.are.equal("table", type(rawget(state, "queueMetatable")))
        assert.are.equal("table", type(rawget(state, "negative")))
        assert.are.same({ maxQueueCapacity = 1024 }, upgraded:GetLimits())
        assert.are.equal("table", type(upgraded.LazyTree))
        assert.are.equal("table", type(upgraded.Queue))

        -- Revision 1 objects gain the new surface without being replaced.
        assert.are.equal(1, ttl:Get("kept"))
        ttl:PutNegative("gone", 5)
        assert.are.equal("negative", select(2, ttl:Get("gone")))
        assert.are.equal("m", legacyMemoized("m"))
        assert.are.equal("m", compute("m"))
        assert.are.equal(1, calls)
        assert.are.equal("n", legacyMemoized("n"))
        assert.are.equal(2, calls)

        local tree = upgraded:Lazy(function(...)
            return select("#", ...)
        end)
        assert.are.equal(2, tree:Get("a", "b"))
        local queue = upgraded:NewQueue(1, "reject")
        assert.is_true(queue:Push(1))
        assert.is_false(queue:Push(2))
    end)

    it("upgrades revision-2 state in place and repairs lazy tree expansion", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        -- Revisions 3 and 4 changed no state or object layout, so a copy
        -- labelled revision 2 leaves exactly the state revision 2 wrote.
        local previous = TestEnv.LoadRevision(2)
        assert.are.equal(2, previous.REVISION)
        local state = rawget(previous, "_state")
        local calls = 0
        local tree = previous:Lazy(function(...)
            calls = calls + 1
            return table.concat({ ... }, "/")
        end, { maxEntries = 1 })
        tree:Get("a", "b")
        local ttl = previous:NewTtl({ maxEntries = 2, ttlSeconds = 60 })
        ttl:PutNegative("gone", 5)
        local queue = previous:NewQueue(2, "reject")
        queue:Push("kept")
        previous:SetLimits({ maxQueueCapacity = 2048 })

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.are.equal(4, upgraded.REVISION)
        assert.are.equal(state, rawget(upgraded, "_state"))
        assert.are.equal(4, rawget(state, "runtimeRevision"))
        assert.are.equal(2048, upgraded:GetLimits().maxQueueCapacity)

        -- The tree revision 2 built runs the repaired expansion: "a" is kept
        -- although eviction takes "a/b", its only expanded descendant.
        assert.are.equal("a", tree:Get("a"))
        assert.are.equal("a", tree:Peek("a"))
        assert.are.equal("a", tree:Get("a"))
        assert.are.equal(2, calls)
        assert.are.equal("negative", select(2, ttl:Get("gone")))
        assert.are.equal("kept", queue:Pop())
    end)

    it("upgrades a revision 3 package in place to the working file", function()
        local previousRevision = 3
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        local previous = TestEnv.LoadRevision(previousRevision)
        local state = rawget(previous, "_state")
        local cache = previous:NewLru({ maxEntries = 2 })
        cache:Set("kept", 1)
        local ttl = previous:NewTtl({ maxEntries = 2, ttlSeconds = 60 })
        ttl:PutNegative("gone", 5)
        previous:SetLimits({ maxQueueCapacity = 2048 })

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.are.equal(previousRevision + 1, upgraded.REVISION)
        assert.are.equal(state, rawget(upgraded, "_state"))
        assert.are.equal(2048, upgraded:GetLimits().maxQueueCapacity)
        assert.are.equal(1, cache:Get("kept"))
        assert.are.equal("negative", select(2, ttl:Get("gone")))
    end)

    it("rejects a same-revision state whose limits are invalid", function()
        local CacheKit = TestEnv.NewPackage()
        rawset(rawget(rawget(CacheKit, "_state"), "limits"), "maxQueueCapacity", 0)
        TestEnv.expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("rejects a same-revision facade whose negative marker is missing", function()
        local CacheKit = TestEnv.NewPackage()
        rawset(rawget(CacheKit, "_state"), "negative", nil)
        TestEnv.expectErrorContaining("corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "CacheKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        Registry:Register("cacheKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CacheKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes CacheKit", 1, true) ~= nil)
    end)
end)
