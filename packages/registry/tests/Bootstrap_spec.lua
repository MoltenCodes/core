local TestEnv = require("RegistryTestEnv")

---Build a request with the shape every case here shares.
---@param overrides table? fields replacing the defaults
---@return table
local function newRequest(overrides)
  local request = {
    package = "demoKit",
    api = 1,
    revision = 2,
    label = "MoltenCodes DemoKit",
    validatePublicSurface = function(implementation)
      return type(implementation) == "table"
        and rawget(implementation, "API") == 1
        and type(rawget(implementation, "REVISION")) == "number"
        and type(rawget(implementation, "Run")) == "function"
    end,
  }

  if overrides ~= nil then
    for key, value in pairs(overrides) do
      request[key] = value
    end
  end

  return request
end

---Populate a shared package table so it satisfies the request above.
---@param implementation table
---@param revision integer
---@return table implementation
local function completeSurface(implementation, revision)
  implementation.API = 1
  implementation.REVISION = revision
  implementation.Run = function() end
  return implementation
end

local expectErrorContaining = TestEnv.expectErrorContaining

describe("Registry:Bootstrap", function()
  before_each(TestEnv.Reset)
  after_each(TestEnv.Reset)

  it("hands a first embedded copy a fresh shared package table", function()
    local Registry = TestEnv.NewRegistry()

    local implementation, previousRevision, selected = Registry:Bootstrap(newRequest())

    assert.is_table(implementation)
    assert.is_nil(previousRevision)
    assert.is_nil(selected)
    assert.are.equal(implementation, (Registry:Get("demoKit", 1)))
  end)

  it("reports the inherited revision when it upgrades an older copy in place", function()
    local Registry = TestEnv.NewRegistry()
    local older = completeSurface(Registry:Register("demoKit", 1, 1), 1)

    local implementation, previousRevision, selected = Registry:Bootstrap(newRequest())

    assert.are.equal(older, implementation)
    assert.are.equal(1, previousRevision)
    assert.are.equal(older, selected)
  end)

  it("does not hold an older revision to this revision's public surface", function()
    local Registry = TestEnv.NewRegistry()
    -- A revision-1 copy published a smaller surface. It is about to be
    -- upgraded in place, and the caller validates what it inherits itself.
    local older = Registry:Register("demoKit", 1, 1)
    older.API = 1
    older.REVISION = 1

    local implementation, previousRevision = Registry:Bootstrap(newRequest())

    assert.are.equal(older, implementation)
    assert.are.equal(1, previousRevision)
  end)

  it("yields to a newer compatible revision without touching its private state", function()
    local Registry = TestEnv.NewRegistry()
    local newer = completeSurface(Registry:Register("demoKit", 1, 3), 3)
    local stateInspected = false

    local implementation, previousRevision, selected = Registry:Bootstrap(newRequest({
      validateState = function()
        stateInspected = true
        return false
      end,
    }))

    assert.is_nil(implementation)
    assert.is_nil(previousRevision)
    assert.are.equal(newer, selected)
    assert.is_false(stateInspected)
  end)

  it("returns a complete copy of its own revision without re-registering", function()
    local Registry = TestEnv.NewRegistry()
    local current = completeSurface(Registry:Register("demoKit", 1, 2), 2)

    local implementation, previousRevision, selected = Registry:Bootstrap(newRequest({
      validateState = function()
        return true
      end,
    }))

    assert.is_nil(implementation)
    assert.is_nil(previousRevision)
    assert.are.equal(current, selected)
  end)

  it("rejects a same-revision copy whose private state never committed", function()
    local Registry = TestEnv.NewRegistry()
    completeSurface(Registry:Register("demoKit", 1, 2), 2)

    expectErrorContaining("MoltenCodes DemoKit package state is corrupted or incomplete", function()
      Registry:Bootstrap(newRequest({
        validateState = function()
          return false
        end,
      }))
    end)
  end)

  it("lets a resume hook adopt an incomplete same-revision copy", function()
    local Registry = TestEnv.NewRegistry()
    local current = completeSurface(Registry:Register("demoKit", 1, 2), 2)
    local observedComplete = nil

    local implementation, previousRevision, selected = Registry:Bootstrap(newRequest({
      validateState = function()
        return false
      end,
      resume = function(_, complete)
        observedComplete = complete
        return 2
      end,
    }))

    assert.is_false(observedComplete)
    assert.are.equal(current, implementation)
    assert.are.equal(2, previousRevision)
    assert.are.equal(current, selected)
  end)

  it("lets a resume hook accept a complete same-revision copy unchanged", function()
    local Registry = TestEnv.NewRegistry()
    local current = completeSurface(Registry:Register("demoKit", 1, 2), 2)
    local observedComplete = nil

    local implementation, _, selected = Registry:Bootstrap(newRequest({
      validateState = function()
        return true
      end,
      resume = function(_, complete)
        observedComplete = complete
        return nil
      end,
    }))

    assert.is_true(observedComplete)
    assert.is_nil(implementation)
    assert.are.equal(current, selected)
  end)

  it("rejects a facade claiming a revision Registry never accepted", function()
    local Registry = TestEnv.NewRegistry()
    completeSurface(Registry:Register("demoKit", 1, 1), 9)

    expectErrorContaining("corrupted or incomplete", function()
      Registry:Bootstrap(newRequest())
    end)
  end)

  it("rejects a shared table that carries no API generation yet", function()
    local Registry = TestEnv.NewRegistry()
    Registry:Register("demoKit", 1, 1)

    expectErrorContaining("corrupted or incomplete", function()
      Registry:Bootstrap(newRequest())
    end)
  end)

  it("rejects a newer copy whose public surface is incomplete", function()
    local Registry = TestEnv.NewRegistry()
    local newer = Registry:Register("demoKit", 1, 3)
    newer.API = 1
    newer.REVISION = 3

    expectErrorContaining("corrupted or incomplete", function()
      Registry:Bootstrap(newRequest())
    end)
  end)

  it("validates the request before it touches Registry state", function()
    local Registry = TestEnv.NewRegistry()

    expectErrorContaining("Registry:Bootstrap request must be a table", function()
      Registry:Bootstrap("demoKit")
    end)
    expectErrorContaining("Registry:Bootstrap packageName", function()
      Registry:Bootstrap(newRequest({ package = "" }))
    end)
    expectErrorContaining("Registry:Bootstrap api", function()
      Registry:Bootstrap(newRequest({ api = 0 }))
    end)
    expectErrorContaining("Registry:Bootstrap revision", function()
      Registry:Bootstrap(newRequest({ revision = 1.5 }))
    end)
    expectErrorContaining("request.label", function()
      Registry:Bootstrap(newRequest({ label = "" }))
    end)
    expectErrorContaining("request.validatePublicSurface", function()
      Registry:Bootstrap(newRequest({ validatePublicSurface = true }))
    end)
    expectErrorContaining("request.validateState", function()
      Registry:Bootstrap(newRequest({ validateState = 7 }))
    end)
    expectErrorContaining("request.resume", function()
      Registry:Bootstrap(newRequest({ resume = 7 }))
    end)

    assert.is_nil((Registry:Get("demoKit", 1)))
  end)

  it("raises its api and revision argument errors at the Bootstrap call", function()
    local Registry = TestEnv.NewRegistry()
    local source = debug.getinfo(1, "S").short_src

    for _, case in ipairs({
      {
        field = "api",
        message = "Registry:Bootstrap api must be a positive integer up to 2^53",
      },
      {
        field = "revision",
        message = "Registry:Bootstrap revision must be a positive integer up to 2^53",
      },
    }) do
      local line
      local ok, message = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        Registry:Bootstrap(newRequest({ [case.field] = 1e300 }))
      end)

      assert.is_false(ok)
      assert.are.equal(source .. ":" .. line .. ": " .. case.message, message)
    end
  end)

  it("refuses a resume hook that returns something other than a revision", function()
    local Registry = TestEnv.NewRegistry()
    completeSurface(Registry:Register("demoKit", 1, 2), 2)
    local source = debug.getinfo(1, "S").short_src

    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      Registry:Bootstrap(newRequest({
        resume = function()
          return "again"
        end,
      }))
    end)

    assert.is_false(ok)
    assert.are.equal(
      source .. ":" .. line .. ": Registry:Bootstrap request.resume must return a revision",
      message
    )
  end)

  it("lets a resume hook return 0 to inherit nothing", function()
    local Registry = TestEnv.NewRegistry()
    local current = completeSurface(Registry:Register("demoKit", 1, 2), 2)

    local implementation, previousRevision = Registry:Bootstrap(newRequest({
      resume = function()
        return 0
      end,
    }))

    assert.are.equal(current, implementation)
    assert.are.equal(0, previousRevision)
  end)

  it("reports the failure against the package that called it", function()
    local Registry = TestEnv.NewRegistry()
    completeSurface(Registry:Register("demoKit", 1, 2), 2)

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      Registry:Bootstrap(newRequest({
        validateState = function()
          return false
        end,
      }))
    end)

    assert.is_false(ok)
    assert.are.equal(
      source .. ":" .. line .. ": MoltenCodes DemoKit package state is corrupted or incomplete",
      message
    )
  end)
end)
