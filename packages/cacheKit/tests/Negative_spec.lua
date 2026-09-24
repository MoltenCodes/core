local TestEnv = require("CacheKitTestEnv")

describe("CacheKit negative entries", function()
  local CacheKit
  before_each(function()
    CacheKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("answers Get with nil and the negative outcome while the entry is live", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("missing", 5)

    local value, outcome = cache:Get("missing")
    assert.is_nil(value)
    assert.are.equal("negative", outcome)
    assert.are.equal(1, cache:GetCount())

    -- An ordinary miss and an ordinary hit both leave the outcome nil.
    local missValue, missOutcome = cache:Get("unknown")
    assert.is_nil(missValue)
    assert.is_nil(missOutcome)
    cache:Set("present", 1)
    local hitValue, hitOutcome = cache:Get("present")
    assert.are.equal(1, hitValue)
    assert.is_nil(hitOutcome)
  end)

  it("counts a negative answer as a hit", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("missing", 5)
    cache:Get("missing")
    cache:Get("missing")

    local stats = cache:GetStats()
    assert.are.equal(2, stats.hits)
    assert.are.equal(0, stats.misses)
  end)

  it("expires by its own age limit, not the cache's", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("short", 2)
    cache:Set("long", 1)

    TestEnv.AdvanceMs(1999)
    assert.are.equal("negative", select(2, cache:Get("short")))

    TestEnv.AdvanceMs(1)
    local value, outcome = cache:Get("short")
    assert.is_nil(value)
    assert.is_nil(outcome)
    assert.are.equal(1, cache:Get("long"))
    assert.are.equal(1, cache:GetCount())

    -- A longer negative age limit outlives the cache's own limit.
    cache:PutNegative("patient", 120)
    TestEnv.AdvanceMs(60000)
    assert.is_nil(cache:Get("long"))
    assert.are.equal("negative", select(2, cache:Get("patient")))
  end)

  it("reads as negative through Peek without side effects", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("missing", 5)

    local value, outcome = cache:Peek("missing")
    assert.is_nil(value)
    assert.are.equal("negative", outcome)
    assert.are.equal(0, cache:GetStats().hits)

    TestEnv.AdvanceMs(5000)
    local expiredValue, expiredOutcome = cache:Peek("missing")
    assert.is_nil(expiredValue)
    assert.is_nil(expiredOutcome)
    assert.are.equal(1, cache:GetCount())
  end)

  it("is replaced by Set and removed by Delete and Clear", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("a", 5)
    cache:Set("a", 1)
    local value, outcome = cache:Get("a")
    assert.are.equal(1, value)
    assert.is_nil(outcome)

    cache:PutNegative("a", 5)
    assert.are.equal("negative", select(2, cache:Get("a")))
    assert.is_true(cache:Delete("a"))
    assert.is_nil(select(2, cache:Get("a")))

    cache:PutNegative("b", 5)
    assert.are.equal(1, cache:Clear())
    assert.is_nil(select(2, cache:Get("b")))
  end)

  it("takes an ordinary slot and is evicted by recency", function()
    local cache = CacheKit:NewTtl({ maxEntries = 2, ttlSeconds = 60 })
    cache:PutNegative("a", 5)
    cache:Set("b", 2)
    cache:Get("a")
    cache:Set("c", 3)

    assert.is_nil(cache:Peek("b"))
    assert.are.equal("negative", select(2, cache:Peek("a")))
    assert.are.equal(1, cache:GetStats().evictions)
  end)

  it("restarts the age limit when put again", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    cache:PutNegative("a", 2)
    TestEnv.AdvanceMs(1500)
    cache:PutNegative("a", 2)
    TestEnv.AdvanceMs(1500)
    assert.are.equal("negative", select(2, cache:Get("a")))
  end)

  it("makes a memoised function return nil without calling fn", function()
    local calls = 0
    local lookup, cache = CacheKit:Memoize(function(key)
      calls = calls + 1
      return key
    end, { ttlSeconds = 60 })

    cache:PutNegative("gone", 5)
    assert.is_nil(lookup("gone"))
    assert.are.equal(0, calls)

    TestEnv.AdvanceMs(5000)
    assert.are.equal("gone", lookup("gone"))
    assert.are.equal(1, calls)
  end)

  it("is refused on a cache without an age limit", function()
    local lru = CacheKit:NewLru({ maxEntries = 4 })
    TestEnv.expectErrorContaining(
      "CacheKit.Cache:PutNegative requires a cache with an age limit",
      function()
        lru:PutNegative("a", 5)
      end
    )
    assert.are.equal(0, lru:GetCount())

    local _, memoCache = CacheKit:Memoize(function(key)
      return key
    end)
    TestEnv.expectErrorContaining("requires a cache with an age limit", function()
      memoCache:PutNegative("a", 5)
    end)
  end)

  it("validates its arguments and refuses a closed cache", function()
    local cache = CacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 60 })
    TestEnv.expectErrorContaining("CacheKit.Cache:PutNegative key must not be nil", function()
      cache:PutNegative(nil, 5)
    end)
    TestEnv.expectErrorContaining("CacheKit.Cache:PutNegative ttlSeconds is required", function()
      cache:PutNegative("a")
    end)
    for _, invalid in ipairs({ 0, -1, 0 / 0, math.huge, "5" }) do
      TestEnv.expectErrorContaining(
        "CacheKit.Cache:PutNegative ttlSeconds must be a finite number greater than zero",
        function()
          cache:PutNegative("a", invalid)
        end
      )
    end

    cache:Close()
    TestEnv.expectErrorContaining(
      "CacheKit.Cache:PutNegative cannot write to a closed cache",
      function()
        cache:PutNegative("a", 5)
      end
    )
  end)

  it("never expires on a host without GetTimePreciseSec", function()
    local ClocklessCacheKit = TestEnv.NewPackageWithoutClock()
    local cache = ClocklessCacheKit:NewTtl({ maxEntries = 4, ttlSeconds = 1 })
    cache:PutNegative("a", 1)
    TestEnv.AdvanceMs(60000)
    assert.are.equal("negative", select(2, cache:Get("a")))
  end)
end)
