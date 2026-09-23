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

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(CacheKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)
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
