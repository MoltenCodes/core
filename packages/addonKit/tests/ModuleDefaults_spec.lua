local TestEnv = require("AddonKitTestEnv")

-- Revision 2: the module defaults and the module-created notice on the
-- facade, forwarded to ModuleKit, and the addon object kept on when the
-- module default is off (docs/API.md, "Module defaults").

describe("AddonKit module defaults", function()
  after_each(TestEnv.Reset)

  ---A fresh package with ModuleKit's chain and a facade for MyAddon.
  ---@return MoltenCodesFacade
  local function newFacade()
    TestEnv.NewPackage()
    TestEnv.LoadKits(TestEnv.CHAINS.modules)
    return TestEnv.Namespace():For("MyAddon")
  end

  it("keeps the addon object on while modules start off", function()
    local MC = newFacade()
    assert.is_true(MC:SetDefaultModuleState(false))
    local addon = MC:NewAddon()
    local bags = MC:NewModule("Bags")
    local chosen = MC:NewModule("Chosen", { enabledState = true })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.is_true(addon:IsEnabled())
    assert.is_false(bags:IsEnabled())
    assert.is_true(chosen:IsEnabled())
  end)

  it("lets a definition keep the addon object off", function()
    local MC = newFacade()
    MC:SetDefaultModuleState(false)
    local addon = MC:NewAddon({ enabledState = false })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()

    assert.is_false(addon:IsEnabled())
  end)

  it("gives later modules the default prototype and a definition its own", function()
    local MC = newFacade()
    MC:NewAddon()
    local prototype = {
      Describe = function(self)
        return "module " .. self:GetName()
      end,
    }
    assert.is_nil(MC:SetDefaultModulePrototype(prototype))
    local bags = MC:NewModule("Bags")
    local own = MC:NewModule(
      "Own",
      { prototype = {
        Describe = function()
          return "own"
        end,
      } }
    )

    assert.are.equal("module Bags", bags:Describe())
    assert.are.equal("own", own:Describe())
  end)

  it("tells a listener about every later module", function()
    local MC = newFacade()
    local addon = MC:NewAddon()
    local names = {}
    function addon:OnModuleCreated(module)
      names[#names + 1] = module:GetName()
    end
    assert.is_table(MC:OnModuleCreated(addon))

    MC:NewModule("Bags")
    MC:NewModule("Bank")

    assert.are.same({ "Bags", "Bank" }, names)
  end)

  it("raises ModuleKit's refusals at the author's line", function()
    local MC = newFacade()
    local ok, message = pcall(function()
      MC:SetDefaultModuleState("off")
    end)

    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("ModuleDefaults_spec.lua:", 1, true))
    assert.is_not_nil(tostring(message):find("enabled must be a boolean", 1, true))
  end)

  it("names the ModuleKit update when the embedded revision is too old", function()
    local MC = newFacade()
    local Addon = MC.ModuleKit.Addon
    local saved = rawget(Addon, "SetDefaultModuleState")
    rawset(Addon, "SetDefaultModuleState", nil)

    local ok, message = pcall(function()
      MC:SetDefaultModuleState(false)
    end)
    rawset(Addon, "SetDefaultModuleState", saved)

    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("ModuleDefaults_spec.lua:", 1, true))
    assert.is_not_nil(
      tostring(message):find(
        "MC:SetDefaultModuleState needs ModuleKit revision 23 or later; update the copy of moduleKit your addon embeds",
        1,
        true
      )
    )
  end)

  it("adds the forwarders to facades a revision without them made", function()
    local MC = newFacade()
    local AddonKit = TestEnv.Namespace().Registries[2]:Get("addonKit", 1)
    local methods = rawget(AddonKit, "_state").methods
    -- What revision 1 had: none of the three methods.
    methods.SetDefaultModuleState = nil
    methods.SetDefaultModulePrototype = nil
    methods.OnModuleCreated = nil

    TestEnv.LoadRevision(AddonKit.REVISION + 1)

    assert.is_true(MC:SetDefaultModuleState(false))
    assert.is_false(MC.ModuleKit:ForAddon("MyAddon"):GetDefaultModuleState())
  end)
end)
