local TestEnv = require("RegistryTestEnv")

---A request for `demoKit` API 1 at `revision`, with `overrides` applied.
---@param revision integer
---@param overrides table?
---@return table
local function newRequest(revision, overrides)
  local request = {
    package = "demoKit",
    api = 1,
    revision = revision,
    label = "MoltenCodes DemoKit",
    validatePublicSurface = function(implementation)
      return type(implementation) == "table" and rawget(implementation, "API") == 1
    end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      request[key] = value
    end
  end
  return request
end

---Load one embedded copy the way a Kit's file scope does: bootstrap, then
---commit the facade fields through `rawset`.
---@param Registry Registry
---@param revision integer
---@param overrides table?
---@return table|nil implementation
---@return integer|nil previousRevision
---@return table|nil selected
---@return any state
local function loadCopy(Registry, revision, overrides)
  local implementation, previousRevision, selected, state =
    Registry:Bootstrap(newRequest(revision, overrides))
  if implementation ~= nil then
    rawset(implementation, "API", 1)
    rawset(implementation, "REVISION", revision)
  end
  return implementation, previousRevision, selected, state
end

describe("Registry retirement and migration", function()
  after_each(TestEnv.Reset)

  it("runs migrations 5 and 6, in order, when revision 6 replaces revision 4", function()
    local Registry = TestEnv.NewRegistry()
    loadCopy(Registry, 4, {
      retire = function()
        return { layout = 4 }
      end,
    })
    local ran = {}
    local function step(revision)
      return function(state)
        ran[#ran + 1] = revision
        state.layout = revision
        return state
      end
    end

    local implementation, previousRevision, _, state = loadCopy(Registry, 6, {
      migrations = { [3] = step(3), [5] = step(5), [6] = step(6), [7] = step(7) },
    })

    assert.is_table(implementation)
    assert.are.equal(4, previousRevision)
    assert.are.same({ 5, 6 }, ran)
    assert.are.same({ layout = 6 }, state)
  end)

  it("never runs a step twice when a copy loads over already-migrated state", function()
    local Registry = TestEnv.NewRegistry()
    loadCopy(Registry, 4)
    local runs = 0
    local migrations = {
      [5] = function()
        runs = runs + 1
      end,
      [6] = function()
        runs = runs + 1
      end,
    }
    loadCopy(Registry, 6, { migrations = migrations })
    assert.are.equal(2, runs)

    -- A second revision-6 copy that resumes from the revision it believes
    -- it inherits must not replay the steps the first copy already ran.
    local implementation, previousRevision = loadCopy(Registry, 6, {
      migrations = migrations,
      resume = function()
        return 4
      end,
    })

    assert.is_table(implementation)
    assert.are.equal(4, previousRevision)
    assert.are.equal(2, runs)
  end)

  it("asks the outgoing copy to retire exactly once, before the incoming one registers", function()
    local Registry = TestEnv.NewRegistry()
    local calls = {}
    local older = loadCopy(Registry, 1, {
      retire = function(implementation, incomingRevision)
        calls[#calls + 1] = {
          implementation = implementation,
          incomingRevision = incomingRevision,
          selectedRevision = select(2, Registry:Get("demoKit", 1)),
        }
        return "handover"
      end,
    })

    local _, _, _, state = loadCopy(Registry, 2)
    loadCopy(Registry, 3)

    assert.are.equal(1, #calls)
    assert.are.equal(older, calls[1].implementation)
    assert.are.equal(2, calls[1].incomingRevision)
    assert.are.equal(1, calls[1].selectedRevision)
    assert.are.equal("handover", state)
  end)

  it("accepts a retire hook registered through OnRetire", function()
    local Registry = TestEnv.NewRegistry()
    loadCopy(Registry, 1)
    Registry:OnRetire("demoKit", 1, function()
      return "late handover"
    end)

    local _, _, _, state = loadCopy(Registry, 2)

    assert.are.equal("late handover", state)
  end)

  it("reports a failing retire hook and continues from no hand-over", function()
    local Registry = TestEnv.NewRegistry()
    TestEnv.InstallHostErrorHandler()
    loadCopy(Registry, 1, {
      retire = function()
        error("drain failed")
      end,
    })
    local received = "untouched"

    local implementation, previousRevision, _, state = loadCopy(Registry, 2, {
      migrations = {
        [2] = function(handover)
          received = handover
        end,
      },
    })

    assert.is_table(implementation)
    assert.are.equal(1, previousRevision)
    assert.is_nil(state)
    assert.is_nil(received)
    local reported = TestEnv.ReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_not_nil(string.find(reported[1], "MoltenCodes DemoKit retire hook failed", 1, true))
    assert.are.equal(2, select(2, Registry:Find("demoKit", 1)))
  end)

  it("refuses at the caller when a migration step fails, and keeps the entry retired", function()
    local Registry = TestEnv.NewRegistry()
    loadCopy(Registry, 1)
    local function failingStep()
      error("boom", 0)
    end

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      Registry:Bootstrap(newRequest(2, { migrations = { [2] = failingStep } }))
    end)

    assert.is_false(ok)
    assert.are.equal(
      source .. ":" .. line .. ": MoltenCodes DemoKit migration to revision 2 failed: boom",
      message
    )
    assert.are.equal("retired", Registry:Packages()[1].status)
  end)

  it("retries a failed step with the handed-over state instead of skipping it", function()
    local Registry = TestEnv.NewRegistry()
    loadCopy(Registry, 1, {
      retire = function()
        return { steps = {} }
      end,
    })
    local runs = { [2] = 0, [3] = 0 }
    local failStepTwo = true
    local migrations = {
      [2] = function(state)
        runs[2] = runs[2] + 1
        if failStepTwo then
          error("layout cannot be converted yet", 0)
        end
        state.steps[#state.steps + 1] = 2
      end,
      [3] = function(state)
        runs[3] = runs[3] + 1
        state.steps[#state.steps + 1] = 3
      end,
    }

    assert.has_error(function()
      loadCopy(Registry, 2, { migrations = migrations })
    end)
    assert.are.equal("retired", select(2, Registry:Find("demoKit", 1)))

    failStepTwo = false
    local implementation, previousRevision, _, state =
      loadCopy(Registry, 3, { migrations = migrations })

    assert.is_table(implementation)
    assert.are.equal(2, previousRevision)
    -- Step 2 ran twice in total: once failing, once succeeding.
    assert.are.equal(2, runs[2])
    assert.are.equal(1, runs[3])
    assert.are.same({ steps = { 2, 3 } }, state)
    assert.are.equal(3, select(2, Registry:Find("demoKit", 1)))
  end)

  it(
    "keeps an unfinished run across an in-place upgrade from the previous Registry revision",
    function()
      local Registry = TestEnv.NewRegistry()
      loadCopy(Registry, 1, {
        retire = function()
          return { steps = {} }
        end,
      })
      local failStepTwo = true
      local migrations = {
        [2] = function(state)
          if failStepTwo then
            error("layout cannot be converted yet", 0)
          end
          state.steps[#state.steps + 1] = 2
        end,
      }
      assert.has_error(function()
        loadCopy(Registry, 2, { migrations = migrations })
      end)

      -- Make the installed Registry look like the previous revision, which
      -- kept the unfinished run in the same entry fields.
      local currentRevision = Registry.REVISION
      local registryState = TestEnv.GetState()
      local previousGet = function() end
      rawset(registryState, "registryRevision", currentRevision - 1)
      rawset(Registry, "REVISION", currentRevision - 1)
      rawset(Registry, "Get", previousGet)

      local upgraded = TestEnv.Reload()
      failStepTwo = false
      local implementation, previousRevision, _, state =
        loadCopy(upgraded, 3, { migrations = migrations })

      assert.are.equal(Registry, upgraded)
      assert.are.equal(currentRevision, upgraded.REVISION)
      assert.are_not.equal(previousGet, upgraded.Get)
      assert.is_table(implementation)
      assert.are.equal(2, previousRevision)
      assert.are.same({ steps = { 2 } }, state)
      assert.are.equal(3, select(2, upgraded:Find("demoKit", 1)))
    end
  )

  it("does not hand a stale retire hook to a later revision", function()
    local Registry = TestEnv.NewRegistry()
    local calls = 0
    loadCopy(Registry, 1, {
      retire = function()
        calls = calls + 1
      end,
    })
    -- Revision 2 upgrades through the raw primitive and registers no hook.
    local shared = Registry:Register("demoKit", 1, 2)
    rawset(shared, "REVISION", 2)

    loadCopy(Registry, 3)

    assert.are.equal(0, calls)
  end)

  it("resolves the outgoing copy's entry points and instances to the incoming revision", function()
    local Registry = TestEnv.NewRegistry()

    -- Revision 1 publishes a method and a prototype, and a consumer keeps
    -- both the facade and an instance built from it.
    local older = loadCopy(Registry, 1)
    local Widget = {}
    rawset(Widget, "Describe", function()
      return "revision 1"
    end)
    rawset(older, "Widget", Widget)
    rawset(older, "Version", function()
      return 1
    end)
    local consumerFacade = older
    local consumerInstance = setmetatable({}, { __index = Widget })

    -- Revision 2 upgrades both in place, as every Kit does.
    local newer = loadCopy(Registry, 2)
    rawset(newer, "Version", function()
      return 2
    end)
    rawset(rawget(newer, "Widget"), "Describe", function()
      return "revision 2"
    end)

    assert.are.equal(newer, consumerFacade)
    assert.are.equal(2, consumerFacade.Version())
    assert.are.equal("revision 2", consumerInstance.Describe())
  end)

  it("validates the new request fields", function()
    local Registry = TestEnv.NewRegistry()

    local expectErrorContaining = TestEnv.expectErrorContaining
    expectErrorContaining("Registry:Bootstrap request.retire must be a function", function()
      Registry:Bootstrap(newRequest(1, { retire = 7 }))
    end)
    expectErrorContaining("Registry:Bootstrap request.migrations must be a table", function()
      Registry:Bootstrap(newRequest(1, { migrations = true }))
    end)
    expectErrorContaining("Registry:Bootstrap request.sealFacade must be a boolean", function()
      Registry:Bootstrap(newRequest(1, { sealFacade = "yes" }))
    end)
    expectErrorContaining("request.migrations must map positive revisions", function()
      Registry:Bootstrap(newRequest(1, { migrations = { [1.5] = function() end } }))
    end)
    expectErrorContaining('Registry:OnRetire package "absentKit" is not registered', function()
      Registry:OnRetire("absentKit", 1, function() end)
    end)
    expectErrorContaining("Registry:OnRetire retire must be a function", function()
      Registry:OnRetire("otherKit", 1, "not a function")
    end)
  end)
end)
