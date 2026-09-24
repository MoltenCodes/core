local TestEnv = require("CacheKitTestEnv")

describe("CacheKit argument validation", function()
  local CacheKit
  before_each(function()
    CacheKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("requires an option table with a positive integer maxEntries", function()
    TestEnv.expectErrorContaining("CacheKit:NewLru options must be a table", function()
      CacheKit:NewLru()
    end)
    for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8" }) do
      TestEnv.expectErrorContaining(
        "CacheKit:NewLru maxEntries must be a positive integer or CacheKit.UNBOUNDED",
        function()
          CacheKit:NewLru({ maxEntries = invalid })
        end
      )
    end
    TestEnv.expectErrorContaining(
      'CacheKit:NewLru options contains unknown field "ttlSeconds"',
      function()
        CacheKit:NewLru({ maxEntries = 1, ttlSeconds = 1 })
      end
    )
  end)

  it("requires ttlSeconds on a TTL cache", function()
    TestEnv.expectErrorContaining("CacheKit:NewTtl ttlSeconds is required", function()
      CacheKit:NewTtl({ maxEntries = 1 })
    end)
    TestEnv.expectErrorContaining("CacheKit:NewTtl maxEntries is required", function()
      CacheKit:NewTtl({ ttlSeconds = 1 })
    end)
    for _, invalid in ipairs({ 0, -1, 0 / 0, math.huge, "1" }) do
      TestEnv.expectErrorContaining(
        "ttlSeconds must be a finite number greater than zero",
        function()
          CacheKit:NewTtl({ maxEntries = 1, ttlSeconds = invalid })
        end
      )
    end
  end)

  it("validates Memoize and NewSnapshot options", function()
    TestEnv.expectErrorContaining("CacheKit:Memoize options must be a table", function()
      CacheKit:Memoize(function() end, 5)
    end)
    TestEnv.expectErrorContaining(
      'CacheKit:Memoize options contains unknown field "capacity"',
      function()
        CacheKit:Memoize(function() end, { capacity = 5 })
      end
    )
    TestEnv.expectErrorContaining("CacheKit:NewSnapshot read must be a function", function()
      CacheKit:NewSnapshot({})
    end)
    TestEnv.expectErrorContaining(
      'CacheKit:NewSnapshot options contains unknown field "ttlSeconds"',
      function()
        CacheKit:NewSnapshot(function() end, { ttlSeconds = 1 })
      end
    )
  end)

  it("refuses nil and NaN keys on every keyed method", function()
    local cache = CacheKit:NewLru({ maxEntries = 1 })
    TestEnv.expectErrorContaining("CacheKit.Cache:Peek key must not be nil", function()
      cache:Peek(nil)
    end)
    TestEnv.expectErrorContaining("CacheKit.Cache:Delete key must not be NaN", function()
      cache:Delete(0 / 0)
    end)
    TestEnv.expectErrorContaining("CacheKit memoized function key must not be NaN", function()
      local memoized = CacheKit:Memoize(function(key)
        return key
      end)
      memoized(0 / 0)
    end)
  end)

  it("refuses method calls without a receiver", function()
    local cache = CacheKit:NewLru({ maxEntries = 1 })
    TestEnv.expectErrorContaining(
      "CacheKit.Cache:GetCount must be called on a CacheKit cache",
      function()
        cache.GetCount()
      end
    )
    TestEnv.expectErrorContaining(
      "CacheKit.Cache:Close must be called on a CacheKit cache",
      function()
        CacheKit.Cache.Close(CacheKit:NewSnapshot(function() end))
      end
    )
  end)
end)
