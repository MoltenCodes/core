local TestEnv = require("CacheKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CacheKit allocation #allocation", function()
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

  it("allocates nothing for a negative hit or for renewing a negative entry", function()
    local cache = CacheKit:NewTtl({ maxEntries = 8, ttlSeconds = 60 })
    cache:PutNegative("missing", 30)

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        local _, outcome = cache:Get("missing")
        if outcome ~= "negative" then
          error("expected a negative answer")
        end
        cache:PutNegative("missing", 30)
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "negative allocated " .. allocated .. " KiB")
  end)

  it("allocates nothing for a memoised result the predicate lets through", function()
    local compute = CacheKit:Memoize(function(key)
      return key
    end, {
      cacheable = function()
        return false
      end,
    })
    compute(1)

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        compute(1)
      end
    end)
    assert.is_true(
      allocated < THRESHOLD_KILOBYTES,
      "cacheable pass-through allocated " .. allocated .. " KiB"
    )
  end)

  it("allocates nothing for a lazy tree hit or peek", function()
    local tree = CacheKit:Lazy(function(...)
      return select("#", ...)
    end)
    tree:Get("realm", "player", 3)
    tree:Get("realm", "other", 3)

    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, ITERATIONS do
        if index % 2 == 0 then
          tree:Get("realm", "player", 3)
        else
          tree:Get("realm", "other", 3)
        end
        tree:Peek("realm", "player", 3)
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "lazy hit allocated " .. allocated .. " KiB")
  end)

  it("reuses nodes when a lazy tree re-expands an invalidated path", function()
    local tree = CacheKit:Lazy(function()
      return true
    end, { maxEntries = 8 })
    tree:Get("a", "b", "c")
    tree:Invalidate("a")
    tree:Get("a", "b", "c")

    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        tree:Invalidate("a")
        tree:Get("a", "b", "c")
      end
    end)
    assert.is_true(allocated < 4, "invalidate and re-expand allocated " .. allocated .. " KiB")
  end)

  it("allocates nothing for queue pushes, pops and iteration", function()
    local queue = CacheKit:NewQueue(8, "dropOldest")
    for value = 1, 12 do
      queue:Push(value)
    end

    local visited = 0
    local allocated = TestEnv.AllocatedKilobytes(function()
      for round = 1, ITERATIONS do
        queue:Push(round)
        queue:Pop()
        queue:Push(round)
        queue:Peek()
        for _, value in queue:Iterate() do
          if value ~= nil then
            visited = visited + 1
          end
        end
      end
    end)
    assert.are.equal(ITERATIONS * 8, visited)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "queue allocated " .. allocated .. " KiB")
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
