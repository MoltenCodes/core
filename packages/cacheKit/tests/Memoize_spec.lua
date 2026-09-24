local TestEnv = require("CacheKitTestEnv")

describe("CacheKit memoisation", function()
  local CacheKit
  before_each(function()
    CacheKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("computes once per key and answers repeats from the cache", function()
    local calls = 0
    local square, cache = CacheKit:Memoize(function(value)
      calls = calls + 1
      return value * value
    end)

    assert.are.equal(9, square(3))
    assert.are.equal(9, square(3))
    assert.are.equal(16, square(4))
    assert.are.equal(2, calls)

    local stats = cache:GetStats()
    assert.are.equal(1, stats.hits)
    assert.are.equal(2, stats.misses)
  end)

  it("keeps string and number keys apart", function()
    local lookup = CacheKit:Memoize(function(key)
      return type(key)
    end)
    assert.are.equal("number", lookup(1))
    assert.are.equal("string", lookup("1"))
  end)

  it("clears through the returned handle", function()
    local calls = 0
    local compute, cache = CacheKit:Memoize(function(key)
      calls = calls + 1
      return key .. "!"
    end)

    compute("a")
    compute("b")
    assert.are.equal(2, cache:Clear())
    compute("a")
    assert.are.equal(3, calls)

    cache:Delete("a")
    compute("a")
    assert.are.equal(4, calls)
  end)

  it("remembers false but not nil", function()
    local calls = 0
    local known = CacheKit:Memoize(function(key)
      calls = calls + 1
      if key == "unknown" then
        return nil
      end
      return false
    end)

    assert.is_false(known("absent"))
    assert.is_false(known("absent"))
    assert.are.equal(1, calls)

    assert.is_nil(known("unknown"))
    assert.is_nil(known("unknown"))
    assert.are.equal(3, calls)
  end)

  it("is bounded by 128 entries unless told otherwise", function()
    local identity, cache = CacheKit:Memoize(function(key)
      return key
    end)
    for index = 1, 200 do
      identity(index)
    end
    assert.are.equal(128, cache:GetCount())

    local small, smallCache = CacheKit:Memoize(function(key)
      return key
    end, { maxEntries = 2 })
    small(1)
    small(2)
    small(3)
    assert.are.equal(2, smallCache:GetCount())
    assert.is_nil(smallCache:Peek(1))
  end)

  it("expires remembered results when ttlSeconds is given", function()
    local calls = 0
    local compute = CacheKit:Memoize(function(key)
      calls = calls + 1
      return key
    end, { ttlSeconds = 1 })

    compute("a")
    TestEnv.AdvanceMs(999)
    compute("a")
    assert.are.equal(1, calls)
    TestEnv.AdvanceMs(1)
    compute("a")
    assert.are.equal(2, calls)
  end)

  it("propagates an error from fn and remembers nothing", function()
    local fail = true
    local compute, cache = CacheKit:Memoize(function(key)
      if fail then
        error("boom", 0)
      end
      return key
    end)

    local ok, message = pcall(compute, "a")
    assert.is_false(ok)
    assert.are.equal("boom", message)
    assert.are.equal(0, cache:GetCount())

    fail = false
    assert.are.equal("a", compute("a"))
  end)

  it("allows fn to call the memoised function for other keys", function()
    local fibonacci
    fibonacci = CacheKit:Memoize(function(index)
      if index < 2 then
        return index
      end
      return fibonacci(index - 1) + fibonacci(index - 2)
    end)
    assert.are.equal(832040, fibonacci(30))
  end)

  it("returns an incomplete result without remembering it when cacheable says so", function()
    local loaded = false
    local calls = 0
    local itemInfo, cache = CacheKit:Memoize(function(itemId)
      calls = calls + 1
      return { id = itemId, loaded = loaded }
    end, {
      cacheable = function(info)
        return info.loaded
      end,
    })

    assert.is_false(itemInfo(1).loaded)
    assert.is_false(itemInfo(1).loaded)
    assert.are.equal(2, calls)
    assert.are.equal(0, cache:GetCount())

    loaded = true
    assert.is_true(itemInfo(1).loaded)
    assert.is_true(itemInfo(1).loaded)
    assert.are.equal(3, calls)
    assert.are.equal(1, cache:GetCount())
  end)

  it("hands cacheable the result and the key, and is not consulted for nil", function()
    local seen = {}
    local compute = CacheKit:Memoize(function(key)
      if key == "nothing" then
        return nil
      end
      return key .. "!", "second result"
    end, {
      cacheable = function(...)
        seen[#seen + 1] = { ... }
        return true
      end,
    })

    assert.are.equal("a!", compute("a"))
    assert.is_nil(compute("nothing"))
    assert.are.same({ { "a!", "a" } }, seen)
  end)

  it("treats a nil answer from cacheable as not cacheable", function()
    local calls = 0
    local compute = CacheKit:Memoize(function(key)
      calls = calls + 1
      return key
    end, {
      cacheable = function() end,
    })
    compute("a")
    compute("a")
    assert.are.equal(2, calls)
  end)

  it("propagates an error from cacheable and remembers nothing", function()
    local compute, cache = CacheKit:Memoize(function(key)
      return key
    end, {
      cacheable = function()
        error("undecided", 0)
      end,
    })
    local ok, message = pcall(compute, "a")
    assert.is_false(ok)
    assert.are.equal("undecided", message)
    assert.are.equal(0, cache:GetCount())
  end)

  it("does not store a result when cacheable closed the cache", function()
    local cache
    local compute
    compute, cache = CacheKit:Memoize(function(key)
      return key
    end, {
      cacheable = function()
        cache:Close()
        return true
      end,
    })
    assert.are.equal("a", compute("a"))
    assert.is_true(cache:IsClosed())
  end)

  it("requires cacheable to be a function", function()
    TestEnv.expectErrorContaining("CacheKit:Memoize cacheable must be a function", function()
      CacheKit:Memoize(function() end, { cacheable = true })
    end)
  end)

  it("refuses to run once its cache is closed", function()
    local compute, cache = CacheKit:Memoize(function(key)
      return key
    end)
    compute("a")
    cache:Close()
    TestEnv.expectErrorContaining("cannot run after its cache was closed", function()
      compute("a")
    end)
  end)

  it("returns the result without storing it when fn closes the cache", function()
    local cache
    local compute
    compute, cache = CacheKit:Memoize(function(key)
      cache:Close()
      return key
    end)
    assert.are.equal("a", compute("a"))
    assert.is_true(cache:IsClosed())
  end)
end)
