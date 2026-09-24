local Env = require("PoolKitTestEnv")

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload function
---@return number kilobytes
local function allocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Acquire and release one object `count` times.
---@param pool table
---@param count integer
local function cycle(pool, count)
  for _ = 1, count do
    pool:Release(pool:Acquire())
  end
end

describe("PoolKit steady-state allocation #allocation", function()
  local PoolKit
  before_each(function()
    PoolKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  it("allocates nothing to acquire and release through a generic pool", function()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function() end,
      destroy = function() end,
    })
    cycle(pool, 1)

    assert.are.equal(
      0,
      allocatedKilobytes(function()
        cycle(pool, 1000)
      end)
    )
  end)

  it("allocates nothing to acquire and release through a table pool", function()
    local pool = PoolKit:NewTablePool()
    cycle(pool, 1)

    assert.are.equal(
      0,
      allocatedKilobytes(function()
        cycle(pool, 1000)
      end)
    )
  end)

  it("allocates nothing to acquire and release through a capped pool", function()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function() end,
      maxCreated = 2,
      maxActive = 1,
      maxWaiting = 1,
    })
    cycle(pool, 1)

    assert.are.equal(
      0,
      allocatedKilobytes(function()
        cycle(pool, 1000)
      end)
    )
  end)

  it("allocates nothing to attach and cascade once the link maps exist", function()
    local frames = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function() end,
    })
    local textures = PoolKit:NewTablePool()
    local function attachAndRelease()
      local frame, texture = frames:Acquire(), textures:Acquire()
      frames:AttachChild(frame, texture, textures)
      frames:Release(frame)
    end
    attachAndRelease()

    assert.are.equal(
      0,
      allocatedKilobytes(function()
        for _ = 1, 1000 do
          attachAndRelease()
        end
      end)
    )
  end)
end)
