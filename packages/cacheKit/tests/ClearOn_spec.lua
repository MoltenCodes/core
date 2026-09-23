local TestEnv = require("CacheKitTestEnv")

describe("CacheKit clear-on-event", function()
    after_each(TestEnv.Reset)

    it("clears the cache when the event fires", function()
        local CacheKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        assert.is_true(cache:ClearOn("SPELLS_CHANGED"))
        cache:Set("a", 1)
        cache:Set("b", 2)

        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(0, cache:GetCount())
        assert.is_nil(cache:Get("a"))

        cache:Set("c", 3)
        TestEnv.Emit("UNRELATED_EVENT")
        assert.are.equal(3, cache:Get("c"))
    end)

    it("clears on each of several events and connects each event once", function()
        local CacheKit, _, _, EventKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        assert.is_true(cache:ClearOn("SPELLS_CHANGED"))
        assert.is_true(cache:ClearOn("PLAYER_TALENT_UPDATE"))
        assert.is_false(cache:ClearOn("SPELLS_CHANGED"))
        assert.is_not_nil(EventKit)

        cache:Set("a", 1)
        TestEnv.Emit("PLAYER_TALENT_UPDATE")
        assert.are.equal(0, cache:GetCount())
        cache:Set("a", 1)
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(0, cache:GetCount())
    end)

    it("works for the cache behind a memoised function", function()
        local CacheKit = TestEnv.NewPackage()
        local calls = 0
        local compute, cache = CacheKit:Memoize(function(key)
            calls = calls + 1
            return key
        end)
        cache:ClearOn("SPELLS_CHANGED")

        compute("a")
        TestEnv.Emit("SPELLS_CHANGED")
        compute("a")
        assert.are.equal(2, calls)
    end)

    it("releases its connections on Close", function()
        local CacheKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:ClearOn("SPELLS_CHANGED")
        cache:ClearOn("BAG_UPDATE")

        local frame = TestEnv.Frames()[1]
        assert.is_not_nil(frame.registrations.SPELLS_CHANGED)
        assert.is_not_nil(frame.registrations.BAG_UPDATE)

        cache:Close()
        assert.is_nil(frame.registrations.SPELLS_CHANGED)
        assert.is_nil(frame.registrations.BAG_UPDATE)
        TestEnv.Emit("SPELLS_CHANGED")
    end)

    it("leaves a cache closed during the dispatch in flight alone", function()
        local CacheKit, _, _, EventKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        EventKit:Connect("SPELLS_CHANGED", function()
            cache:Close()
        end)
        cache:ClearOn("SPELLS_CHANGED")
        cache:Set("a", 1)

        TestEnv.Emit("SPELLS_CHANGED")
        assert.is_true(cache:IsClosed())
        assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("reports a refused host registration and can connect again later", function()
        local CacheKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })

        TestEnv.FailNextRegisterEvent()
        TestEnv.expectErrorContaining(
            "CacheKit.Cache:ClearOn could not connect SPELLS_CHANGED: ",
            function()
                cache:ClearOn("SPELLS_CHANGED")
            end
        )

        assert.is_true(cache:ClearOn("SPELLS_CHANGED"))
        cache:Set("a", 1)
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(0, cache:GetCount())
    end)

    it("refuses to subscribe a closed cache", function()
        local CacheKit = TestEnv.NewPackage()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:Close()
        TestEnv.expectErrorContaining("cannot subscribe a closed cache", function()
            cache:ClearOn("SPELLS_CHANGED")
        end)
    end)

    it("raises a clear message when EventKit is not loaded", function()
        local CacheKit = TestEnv.NewPackageWithoutEventKit()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:Set("a", 1)

        TestEnv.expectErrorContaining(
            "CacheKit.Cache:ClearOn requires EventKit API 1, which is not loaded (absent)",
            function()
                cache:ClearOn("SPELLS_CHANGED")
            end
        )
        assert.are.equal(1, cache:Get("a"))
        assert.is_true(cache:Close())
    end)

    it("names Registry:Find when the embedded Registry predates it", function()
        local CacheKit, Registry = TestEnv.NewPackageWithoutEventKit()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        rawset(Registry, "Find", nil)

        TestEnv.expectErrorContaining(
            "CacheKit.Cache:ClearOn requires Registry:Find (Registry API 2 revision 7 or newer)",
            function()
                cache:ClearOn("SPELLS_CHANGED")
            end
        )
    end)

    it("refuses an EventKit facade without CreateScope", function()
        local CacheKit, Registry = TestEnv.NewPackageWithoutEventKit()
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        rawset(Registry, "Find", function()
            return {}
        end)

        TestEnv.expectErrorContaining(
            "CacheKit.Cache:ClearOn requires a valid EventKit API 1 facade",
            function()
                cache:ClearOn("SPELLS_CHANGED")
            end
        )
    end)

    it("finds an EventKit loaded after CacheKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local CacheKit = require("CacheKit")
        require("SignalKit")
        require("EventKit")

        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:ClearOn("SPELLS_CHANGED")
        cache:Set("a", 1)
        TestEnv.Emit("SPELLS_CHANGED")
        assert.are.equal(0, cache:GetCount())
    end)
end)
