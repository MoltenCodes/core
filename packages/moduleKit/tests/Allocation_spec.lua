local TestEnv = require("ModuleKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

---Kilobytes allocated while `workload` runs, with the collector stopped so
---nothing allocated is reclaimed before it is counted.
---@param workload fun()
---@return number
local function allocatedKilobytes(workload)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local allocated = collectgarbage("count") - before
  collectgarbage("restart")
  return allocated
end

---@param label string
---@param workload fun()
local function assertAllocatesNothing(label, workload)
  -- The first run builds and caches what later runs reuse.
  workload()
  local allocated = allocatedKilobytes(function()
    for _ = 1, ITERATIONS do
      workload()
    end
  end)
  assert.is_true(allocated < THRESHOLD_KILOBYTES, label .. " allocated " .. allocated .. " KiB")
end

describe("ModuleKit allocation #allocation", function()
  local ModuleKit

  before_each(function()
    ModuleKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  local function noop() end

  ---A loaded, enabled addon with `count` modules, each with the three hooks.
  local function enabledAddon(count, definitionFor)
    local addon = ModuleKit:ForAddon("MyAddon")
    for index = 1, count do
      local module = addon:CreateModule("Module" .. index)
      module.OnInitialize = noop
      module.OnEnable = noop
      module.OnDisable = noop
      if definitionFor ~= nil then
        definitionFor(module, index)
      end
    end
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    return addon
  end

  it("allocates nothing to disable and enable a whole container", function()
    local addon = enabledAddon(10)
    assertAllocatesNothing("DisableAll/EnableAll", function()
      addon:DisableAll()
      addon:EnableAll()
    end)
    assert.is_true(addon:GetModule("Module10"):IsEnabled())
  end)

  it("allocates nothing for a whole-container cycle over a dependency chain", function()
    local addon = enabledAddon(6, function(module, index)
      if index > 1 then
        module:DependsOn("Module" .. (index - 1))
      end
      if index > 2 then
        module:After("Module1")
      end
    end)
    assertAllocatesNothing("chained DisableAll/EnableAll", function()
      addon:DisableAll()
      addon:EnableAll()
    end)
    assert.is_true(addon:GetModule("Module6"):IsEnabled())
  end)

  it("allocates nothing to disable and enable one module", function()
    local addon = enabledAddon(10)
    local module = addon:GetModule("Module1")
    assertAllocatesNothing("Disable/Enable", function()
      module:Disable()
      module:Enable()
    end)
    assert.is_true(module:IsEnabled())
  end)

  it("allocates nothing to validate a cached graph or ask for its order twice", function()
    local addon = enabledAddon(10)
    assertAllocatesNothing("ValidateGraph", function()
      addon:ValidateGraph()
    end)
  end)
end)

-- A container carries only what every container needs. Providers and the
-- resolution stack are the Injection part's and appear on first use; the
-- catch-up queue appears when a module first waits on a running pass.
describe("ModuleKit lazy container tables", function()
  after_each(TestEnv.Reset)

  it("creates no provider table, resolution stack or catch-up queue with a container", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:CreateModule("UI")

    assert.is_nil(rawget(addon, "_providers"))
    assert.is_nil(rawget(addon, "_resolutionStack"))
    assert.is_nil(rawget(addon, "_pendingCatchUp"))
  end)

  it(
    "creates the provider table on the first provider and the stack on the first factory run",
    function()
      local ModuleKit = TestEnv.NewPackage()
      local addon = ModuleKit:ForAddon("MyAddon")

      addon:ProvideValue("Settings", { scale = 1 })
      assert.is_table(rawget(addon, "_providers"))
      assert.are.same({ scale = 1 }, addon:Resolve("Settings"))
      assert.is_nil(rawget(addon, "_resolutionStack"))

      addon:ProvideSingleton("Database", function()
        return {}
      end)
      addon:Resolve("Database")
      assert.are.same({}, rawget(addon, "_resolutionStack"))
    end
  )

  it("creates the catch-up queue when a module created during a pass waits for it", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local late
    addon:CreateModule("Creator", {
      onInitialize = function()
        late = addon:CreateModule("Late", { onInitialize = function() end })
      end,
    })

    TestEnv.LoadAddon("MyAddon")

    assert.are.same({}, rawget(addon, "_pendingCatchUp"))
    assert.are.equal("initialized", late:GetState())
  end)
end)
