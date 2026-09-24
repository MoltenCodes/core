local TestEnv = require("ModuleKitTestEnv")

---Names `count` distinct addons for a `requiresAddons` list.
---@param count integer
---@return string[]
local function addonNames(count)
  local names = {}
  for index = 1, count do
    names[index] = "Required" .. index
  end
  return names
end

local expectCallerError = TestEnv.expectCallerError

---Make every LifecycleKit instance accept any number of `DependsOn`
---declarations, modelling a LifecycleKit whose own limit was opened. It is
---set on the shared instance prototype, which `Reset` discards.
---@param addon table a ModuleKit container
local function openLifecycleDependencies(addon)
  rawset(rawget(addon, "_lifecycle"), "DependsOn", function()
    return true
  end)
end

describe("ModuleKit package-wide limits", function()
  local ModuleKit, LifecycleKit
  before_each(function()
    local packageUnderTest, _, _, _, lifecycleKit = TestEnv.NewPackage()
    ModuleKit = packageUnderTest
    LifecycleKit = lifecycleKit
    -- These specs decide what LifecycleKit reports, whatever revision of
    -- it the chain loaded.
    rawset(LifecycleKit, "GetLimits", nil)
  end)
  after_each(TestEnv.Reset)

  it("publishes a table sentinel kept in package state", function()
    assert.are.equal("table", type(ModuleKit.UNBOUNDED))
    assert.are.equal(rawget(rawget(ModuleKit, "_state"), "unbounded"), ModuleKit.UNBOUNDED)
  end)

  it("reports the default in a fresh table on every call", function()
    local first = ModuleKit:GetLimits()
    local second = ModuleKit:GetLimits()

    assert.are.same({ maxRequiredAddons = 16 }, first)
    assert.are_not.equal(first, second)
    first.maxRequiredAddons = 1
    assert.are.equal(16, ModuleKit:GetLimits().maxRequiredAddons)
  end)

  it("enforces the default of 16 required addons per module", function()
    local addon = ModuleKit:ForAddon("MyAddon")

    assert.is_not_nil(addon:CreateModule("Sixteen", { requiresAddons = addonNames(16) }))
    expectCallerError(
      "requiresAddons must list at most 16 addons (ModuleKit:SetLimits maxRequiredAddons)",
      function()
        addon:CreateModule("Seventeen", { requiresAddons = addonNames(17) })
      end
    )
    assert.is_false(addon:HasModule("Seventeen"))
  end)

  it("honours a lower limit without removing what modules already declared", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local existing = addon:CreateModule("Existing", { requiresAddons = addonNames(3) })

    ModuleKit:SetLimits({ maxRequiredAddons = 2 })

    assert.are.equal(2, ModuleKit:GetLimits().maxRequiredAddons)
    assert.are.equal(3, #rawget(existing, "_requiredAddons"))
    assert.is_not_nil(addon:CreateModule("Two", { requiresAddons = addonNames(2) }))
    expectCallerError("requiresAddons must list at most 2 addons", function()
      addon:CreateModule("Three", { requiresAddons = addonNames(3) })
    end)
  end)

  it("honours a higher limit up to what LifecycleKit accepts for the addon", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    local other = ModuleKit:ForAddon("OtherAddon")
    openLifecycleDependencies(other)

    ModuleKit:SetLimits({ maxRequiredAddons = 20 })

    assert.is_not_nil(other:CreateModule("Twenty", { requiresAddons = addonNames(20) }))
    -- LifecycleKit still bounds one addon's declared dependencies.
    TestEnv.expectErrorContaining(
      "already declares the most addon dependencies LifecycleKit accepts",
      function()
        addon:CreateModule("Seventeen", { requiresAddons = addonNames(17) })
      end
    )
  end)

  it("honours ModuleKit.UNBOUNDED when LifecycleKit reports no limit", function()
    local addon = ModuleKit:ForAddon("MyAddon")
    openLifecycleDependencies(addon)

    ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })

    assert.are.equal(ModuleKit.UNBOUNDED, ModuleKit:GetLimits().maxRequiredAddons)
    local module = addon:CreateModule("Many", { requiresAddons = addonNames(40) })
    assert.are.equal(40, #rawget(module, "_requiredAddons"))
  end)

  it("refuses a value above LifecycleKit's reported maxDependencies", function()
    rawset(LifecycleKit, "GetLimits", function()
      return { maxDependencies = 24 }
    end)

    ModuleKit:SetLimits({ maxRequiredAddons = 24 })
    expectCallerError(
      "ModuleKit:SetLimits limits.maxRequiredAddons must be an integer from 1 to 24, LifecycleKit's maxDependencies",
      function()
        ModuleKit:SetLimits({ maxRequiredAddons = 25 })
      end
    )
    expectCallerError(
      "ModuleKit:SetLimits limits.maxRequiredAddons cannot be ModuleKit.UNBOUNDED: LifecycleKit accepts at most 24 dependencies per addon",
      function()
        ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })
      end
    )
    assert.are.equal(24, ModuleKit:GetLimits().maxRequiredAddons)
  end)

  it("accepts ModuleKit.UNBOUNDED when LifecycleKit reports its own UNBOUNDED", function()
    local lifecycleUnbounded = {}
    rawset(LifecycleKit, "GetLimits", function()
      return { maxDependencies = lifecycleUnbounded }
    end)

    ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })

    assert.are.equal(ModuleKit.UNBOUNDED, ModuleKit:GetLimits().maxRequiredAddons)
  end)

  it("refuses invalid values at the caller and changes nothing", function()
    ModuleKit:SetLimits({ maxRequiredAddons = 4 })
    local cases = {
      { 0, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { -1, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { 1.5, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { 0 / 0, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { math.huge, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { "8", "must be a positive integer or ModuleKit.UNBOUNDED" },
      { {}, "must be a positive integer or ModuleKit.UNBOUNDED" },
      { false, "must be a positive integer or ModuleKit.UNBOUNDED" },
    }

    for index = 1, #cases do
      expectCallerError("limits.maxRequiredAddons " .. cases[index][2], function()
        ModuleKit:SetLimits({ maxRequiredAddons = cases[index][1] })
      end)
    end
    expectCallerError("limits.maxModules is not a recognised limit", function()
      ModuleKit:SetLimits({ maxRequiredAddons = 8, maxModules = 8 })
    end)
    expectCallerError("limits.1 is not a recognised limit", function()
      ModuleKit:SetLimits({ 8 })
    end)
    expectCallerError("ModuleKit:SetLimits limits must be a table", function()
      ModuleKit:SetLimits(8)
    end)
    assert.are.equal(4, ModuleKit:GetLimits().maxRequiredAddons)
  end)

  it("accepts an empty table as a change to nothing", function()
    ModuleKit:SetLimits({})

    assert.are.same({ maxRequiredAddons = 16 }, ModuleKit:GetLimits())
  end)

  it("refuses a call that is not made on the facade", function()
    expectCallerError("ModuleKit:SetLimits must be called on the ModuleKit facade", function()
      ModuleKit.SetLimits({ maxRequiredAddons = 4 })
    end)
    expectCallerError("ModuleKit:GetLimits must be called on the ModuleKit facade", function()
      ModuleKit.GetLimits()
    end)
  end)

  it("shares the limits with every consumer in the session", function()
    ModuleKit:SetLimits({ maxRequiredAddons = 1 })
    local other = ModuleKit:ForAddon("OtherAddon")

    expectCallerError("requiresAddons must list at most 1 addons", function()
      other:CreateModule("Two", { requiresAddons = addonNames(2) })
    end)
  end)
end)
