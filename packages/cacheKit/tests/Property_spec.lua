local TestEnv = require("CacheKitTestEnv")

---A deliberately naive LRU model: an array ordered from least to most recently
---used, searched linearly. Slow and obviously correct, which is the point.
---@param maxEntries integer
---@return table model
local function newModel(maxEntries)
  local model = { order = {}, values = {}, evictions = 0 }

  local function indexOf(key)
    for index = 1, #model.order do
      if model.order[index] == key then
        return index
      end
    end
    return nil
  end

  local function moveToEnd(key)
    table.remove(model.order, indexOf(key))
    model.order[#model.order + 1] = key
  end

  function model.Get(key)
    if model.values[key] == nil then
      return nil
    end
    moveToEnd(key)
    return model.values[key]
  end

  function model.Set(key, value)
    if model.values[key] ~= nil then
      model.values[key] = value
      moveToEnd(key)
      return
    end
    if #model.order >= maxEntries then
      local evicted = table.remove(model.order, 1)
      model.values[evicted] = nil
      model.evictions = model.evictions + 1
    end
    model.values[key] = value
    model.order[#model.order + 1] = key
  end

  function model.Delete(key)
    if model.values[key] == nil then
      return false
    end
    table.remove(model.order, indexOf(key))
    model.values[key] = nil
    return true
  end

  return model
end

describe("CacheKit LRU property", function()
  after_each(TestEnv.Reset)

  it("matches a naive LRU model over 5,000 deterministic operations", function()
    local CacheKit = TestEnv.NewPackage()
    local maxEntries = 7
    local cache = CacheKit:NewLru({ maxEntries = maxEntries })
    local model = newModel(maxEntries)

    -- A fixed linear congruential generator keeps the sequence identical
    -- on every run and every Lua build.
    local seed = 12345
    local function nextRandom(limit)
      seed = (seed * 1103515245 + 12345) % 2147483648
      -- The low bits of a power-of-two modulus repeat with short
      -- periods, so the draw uses the high ones.
      return math.floor(seed / 65536) % limit + 1
    end

    for step = 1, 5000 do
      local key = nextRandom(12)
      local operation = nextRandom(10)
      if operation <= 4 then
        assert.are.equal(model.Get(key), cache:Get(key), "Get at step " .. step)
      elseif operation <= 8 then
        model.Set(key, step)
        cache:Set(key, step)
      elseif operation == 9 then
        assert.are.equal(model.Delete(key), cache:Delete(key), "Delete at step " .. step)
      else
        cache:Clear()
        model = newModel(maxEntries)
        model.evictions = cache:GetStats().evictions
      end

      assert.are.equal(#model.order, cache:GetCount(), "count at step " .. step)
      assert.are.equal(model.evictions, cache:GetStats().evictions, "evictions at step " .. step)
      -- The invariant that keeps a bounded cache's free list within its
      -- bound: live plus free entries never exceed `maxEntries`.
      assert.is_true(
        cache:GetCount() + cache._freeCount <= maxEntries,
        "free list within the bound at step " .. step
      )
      for index = 1, #model.order do
        local stored = model.order[index]
        assert.are.equal(model.values[stored], cache:Peek(stored))
      end
    end
  end)
end)
