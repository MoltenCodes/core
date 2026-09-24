local Env = require("PoolKitTestEnv")

describe("PoolKit retention contracts", function()
  before_each(function()
    Env.Reset()
  end)
  after_each(function()
    Env.Reset()
  end)

  it("hands back objects carrying their previous state when a pool has no reset", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
    })

    local first = pool:Acquire()
    first.name = "stale"
    first[1] = "left behind"
    pool:Release(first)

    -- Acquire never cleans. Without a reset callback the pool is a pure
    -- identity cache and the caller owns object hygiene.
    local second = pool:Acquire()
    assert.are.equal(first, second)
    assert.are.equal("stale", second.name)
    assert.are.equal("left behind", second[1])
  end)

  it("clears state on reuse when a reset callback is supplied", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function(object)
        for key in next, object do
          rawset(object, key, nil)
        end
      end,
    })

    local first = pool:Acquire()
    first.name = "stale"
    pool:Release(first)

    local second = pool:Acquire()
    assert.are.equal(first, second)
    assert.is_nil(second.name)
  end)

  it("clears state on reuse for table pools", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:NewTablePool()

    local first = pool:Acquire()
    first.name = "stale"
    pool:Release(first)

    local second = pool:Acquire()
    assert.are.equal(first, second)
    assert.is_nil(next(second))
  end)

  it("refuses to construct a strictReset pool without a reset callback", function()
    local PoolKit = Env.NewPackage()

    local ok, message = pcall(PoolKit.New, PoolKit, {
      create = function()
        return {}
      end,
      strictReset = true,
    })
    assert.is_false(ok)
    assert.is_not_nil(
      string.find(tostring(message), "PoolKit:New strictReset requires a reset callback", 1, true)
    )

    ok, message = pcall(PoolKit.New, PoolKit, {
      create = function()
        return {}
      end,
      strictReset = "yes",
    })
    assert.is_false(ok)
    assert.is_not_nil(
      string.find(tostring(message), "PoolKit:New strictReset must be a boolean", 1, true)
    )
  end)

  it("accepts strictReset when a reset callback is present", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      reset = function() end,
      strictReset = true,
    })

    -- The flag is a construction-time assertion only: it is not stored and
    -- adds nothing to the acquire/release path.
    assert.is_nil(rawget(pool, "_strictReset"))
    local object = pool:Acquire()
    pool:Release(object)
    assert.are.equal(1, pool:GetAvailableCount())
  end)

  it("does not warn about borrowed objects unless a threshold is configured", function()
    local PoolKit = Env.NewPackage()
    Env.InstallHostErrorHandler()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxRetained = PoolKit.UNBOUNDED,
    })

    for _ = 1, 200 do
      pool:Acquire()
    end
    assert.are.equal(200, pool:GetActiveCount())
    assert.are.equal(0, #Env.ReportedWarnings())
  end)

  it("reports the leak threshold once through the host error handler", function()
    local PoolKit = Env.NewPackage()
    Env.InstallHostErrorHandler()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxActiveWarning = 3,
    })

    local borrowed = {}
    for index = 1, 2 do
      borrowed[index] = pool:Acquire()
    end
    assert.are.equal(0, #Env.ReportedWarnings())

    borrowed[3] = pool:Acquire()
    assert.are.equal(1, #Env.ReportedWarnings())
    assert.is_true(Env.ReportedWarnings()[1]:find("maxActiveWarning", 1, true) ~= nil)

    -- Once, not once per acquire: a leaking caller must not be spammed.
    for index = 4, 10 do
      borrowed[index] = pool:Acquire()
    end
    assert.are.equal(10, pool:GetActiveCount())
    assert.are.equal(1, #Env.ReportedWarnings())

    pool:Release(borrowed[1])
    borrowed[1] = pool:Acquire()
    assert.are.equal(1, #Env.ReportedWarnings())
  end)

  it("stays silent when the host publishes no error handler", function()
    local PoolKit = Env.NewPackage()
    local pool = PoolKit:New({
      create = function()
        return {}
      end,
      maxActiveWarning = 1,
    })

    -- PoolKit is pure Lua and must work outside the WoW client.
    assert.is_not_nil(pool:Acquire())
    assert.are.equal(1, pool:GetActiveCount())
  end)

  it("rejects an invalid leak threshold", function()
    local PoolKit = Env.NewPackage()
    assert.has_error(function()
      PoolKit:New({
        create = function()
          return {}
        end,
        maxActiveWarning = -1,
      })
    end)
    assert.has_error(function()
      PoolKit:NewTablePool({ maxActiveWarning = 1.5 })
    end)
  end)
end)
