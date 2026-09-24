local TestEnv = require("CacheKitTestEnv")

---Return the members of `keys` that `cache` still stores, in the order given.
---Reads through `Peek`, so asking does not change which entry is evicted next.
---@param cache table
---@param keys any[] every key that might be stored
---@return any[] stored keys
local function storedKeys(cache, keys)
  local stored = {}
  for index = 1, #keys do
    if cache:Peek(keys[index]) ~= nil then
      stored[#stored + 1] = keys[index]
    end
  end
  return stored
end

describe("CacheKit LRU cache", function()
  local CacheKit
  before_each(function()
    CacheKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("stores, reads, counts and deletes entries", function()
    local cache = CacheKit:NewLru({ maxEntries = 4 })
    assert.is_nil(cache:Get("a"))
    cache:Set("a", 1)
    cache:Set("b", false)
    assert.are.equal(1, cache:Get("a"))
    assert.is_false(cache:Get("b"))
    assert.are.equal(2, cache:GetCount())

    assert.is_true(cache:Delete("a"))
    assert.is_false(cache:Delete("a"))
    assert.is_nil(cache:Get("a"))
    assert.are.equal(1, cache:GetCount())
  end)

  it("accepts any non-nil key, including tables, booleans and numbers", function()
    local cache = CacheKit:NewLru({ maxEntries = 4 })
    local tableKey = {}
    cache:Set(tableKey, "table")
    cache:Set(false, "false")
    cache:Set(1.5, "number")
    assert.are.equal("table", cache:Get(tableKey))
    assert.are.equal("false", cache:Get(false))
    assert.are.equal("number", cache:Get(1.5))
  end)

  it("deletes a key when it is set to nil", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)
    cache:Set("a", nil)
    assert.is_nil(cache:Peek("a"))
    assert.are.equal(0, cache:GetCount())
    cache:Set("missing", nil)
    assert.are.equal(0, cache:GetCount())
  end)

  it("evicts the least recently used entry when full", function()
    local cache = CacheKit:NewLru({ maxEntries = 3 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    cache:Set("c", 3)
    cache:Get("a")
    cache:Set("d", 4)

    assert.is_nil(cache:Peek("b"))
    assert.are.same({ "a", "c", "d" }, storedKeys(cache, { "a", "b", "c", "d" }))
    assert.are.equal(3, cache:GetCount())

    cache:Set("e", 5)
    assert.is_nil(cache:Peek("c"))
    cache:Set("f", 6)
    assert.is_nil(cache:Peek("a"))
    assert.are.same({ "d", "e", "f" }, storedKeys(cache, { "a", "b", "c", "d", "e", "f" }))
  end)

  it("treats overwriting a key as a use", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    cache:Set("a", 10)
    cache:Set("c", 3)
    assert.are.equal(10, cache:Peek("a"))
    assert.is_nil(cache:Peek("b"))
  end)

  it("does not touch recency or statistics on Peek", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    assert.are.equal(1, cache:Peek("a"))
    assert.is_nil(cache:Peek("missing"))
    cache:Set("c", 3)

    assert.is_nil(cache:Peek("a"))
    assert.are.equal(2, cache:Peek("b"))
    local stats = cache:GetStats()
    assert.are.equal(0, stats.hits)
    assert.are.equal(0, stats.misses)
  end)

  it("keeps a single-entry cache working", function()
    local cache = CacheKit:NewLru({ maxEntries = 1 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    assert.is_nil(cache:Get("a"))
    assert.are.equal(2, cache:Get("b"))
    assert.is_true(cache:Delete("b"))
    cache:Set("c", 3)
    assert.are.equal(3, cache:Get("c"))
    assert.are.equal(1, cache:GetCount())
  end)

  it("counts hits, misses and evictions in one reused table", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    cache:Get("a")
    cache:Get("a")
    cache:Get("missing")
    cache:Set("c", 3)
    cache:Set("d", 4)

    local stats = cache:GetStats()
    assert.are.equal(2, stats.hits)
    assert.are.equal(1, stats.misses)
    assert.are.equal(2, stats.evictions)

    cache:Get("d")
    assert.are.equal(stats, cache:GetStats())
    assert.are.equal(3, stats.hits)
  end)

  it("does not count a deletion or a clear as an eviction", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    cache:Delete("a")
    cache:Clear()
    assert.are.equal(0, cache:GetStats().evictions)
  end)

  it("clears every entry, keeps the statistics and stays usable", function()
    local cache = CacheKit:NewLru({ maxEntries = 3 })
    cache:Set("a", 1)
    cache:Set("b", 2)
    cache:Get("a")

    assert.are.equal(2, cache:Clear())
    assert.are.equal(0, cache:GetCount())
    assert.is_nil(cache:Peek("a"))
    assert.are.equal(1, cache:GetStats().hits)

    cache:Set("c", 3)
    cache:Set("d", 4)
    cache:Set("e", 5)
    cache:Set("f", 6)
    assert.are.same({ "d", "e", "f" }, storedKeys(cache, { "c", "d", "e", "f" }))
  end)

  it("reads as empty once closed and refuses writes", function()
    local cache = CacheKit:NewLru({ maxEntries = 2 })
    cache:Set("a", 1)

    assert.is_false(cache:IsClosed())
    assert.is_true(cache:Close())
    assert.is_true(cache:IsClosed())
    assert.is_false(cache:Close())

    assert.is_nil(cache:Get("a"))
    assert.is_nil(cache:Peek("a"))
    assert.is_false(cache:Delete("a"))
    assert.are.equal(0, cache:Clear())
    assert.are.equal(0, cache:GetCount())
    assert.are.equal(0, cache:GetStats().misses)
    TestEnv.expectErrorContaining("cannot write to a closed cache", function()
      cache:Set("a", 2)
    end)
  end)

  it("keeps caches independent of each other", function()
    local first = CacheKit:NewLru({ maxEntries = 1 })
    local second = CacheKit:NewLru({ maxEntries = 1 })
    first:Set("a", 1)
    second:Set("a", 2)
    first:Close()
    assert.are.equal(2, second:Get("a"))
  end)
end)
