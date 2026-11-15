local TestEnv = require("AddonKitTestEnv")

describe("AddonKit addon object", function()
  after_each(TestEnv.Reset)

  ---A fresh package with ModuleKit's chain and a facade for MyAddon.
  ---@return MoltenCodesFacade
  local function newFacade()
    TestEnv.NewPackage()
    TestEnv.LoadKits(TestEnv.CHAINS.modules)
    return TestEnv.Namespace():For("MyAddon")
  end

  it("is ModuleKit's module Main, with the three hooks at the lifecycle phases", function()
    local MC = newFacade()
    local addon = MC:NewAddon()
    local calls = {}
    function addon:OnInitialize()
      calls[#calls + 1] = "initialize"
    end
    function addon:OnEnable()
      calls[#calls + 1] = "enable"
      assert.is_table(self.scope.Events)
    end
    function addon:OnDisable()
      calls[#calls + 1] = "disable"
    end
    assert.are.equal("Main", addon:GetName())
    assert.are.equal(MC.ModuleKit:ForAddon("MyAddon"):GetModule("Main"), addon)
    TestEnv.LoadAddon("MyAddon")
    assert.are.same({ "initialize" }, calls)
    TestEnv.Login()
    assert.are.same({ "initialize", "enable" }, calls)
    addon:Disable()
    assert.are.same({ "initialize", "enable", "disable" }, calls)
    assert.are.equal(addon, MC:GetAddon())
  end)

  it("passes a definition table to ModuleKit as it is", function()
    local MC = newFacade()
    local initialized = false
    local addon = MC:NewAddon({
      onInitialize = function()
        initialized = true
      end,
    })
    TestEnv.LoadAddon("MyAddon")
    assert.is_true(initialized)
    assert.are.equal("initialized", addon:GetState())
  end)

  it("refuses a second addon object with the fix", function()
    local MC = newFacade()
    MC:NewAddon()
    local message = TestEnv.ErrorOf(function()
      MC:NewAddon()
    end)
    assert.is_truthy(
      string.find(
        message,
        "MyAddon already has its addon object; read it with MC:GetAddon()",
        1,
        true
      )
    )
  end)

  it(
    "makes modules depend on the addon: it enables first, and disabling it disables them",
    function()
      local MC = newFacade()
      local order = {}
      local addon = MC:NewAddon()
      local bags = MC:NewModule("Bags")
      function bags:OnEnable()
        order[#order + 1] = "Bags"
      end
      function addon:OnEnable()
        order[#order + 1] = "Main"
      end
      TestEnv.LogIn("MyAddon")
      assert.are.same({ "Main", "Bags" }, order)
      addon:Disable()
      assert.is_false(bags:IsEnabled())
      assert.are.equal(bags, MC:GetModule("Bags"))
    end
  )

  it("adds the addon to a definition's dependsOn, once", function()
    local MC = newFacade()
    MC:NewAddon()
    local first = MC:NewModule("First", { dependsOn = { "Main", "Second" } })
    MC:NewModule("Second", { optionalDependencies = {} })
    assert.is_table(first)
    local order = MC.ModuleKit:ForAddon("MyAddon"):GetActivationOrder()
    assert.are.same({ "Main", "Second", "First" }, order)
  end)

  it("works when the module file loads before the addon object's", function()
    local MC = newFacade()
    local bags = MC:NewModule("Bags")
    MC:NewAddon()
    TestEnv.LogIn("MyAddon")
    assert.is_true(bags:IsEnabled())
  end)

  it("refuses the name Main for a module", function()
    local MC = newFacade()
    local message = TestEnv.ErrorOf(function()
      MC:NewModule("Main")
    end)
    assert.is_truthy(string.find(message, "the name Main belongs to the addon object", 1, true))
  end)

  it("raises with the fix for a missing addon object or module", function()
    local MC = newFacade()
    local message = TestEnv.ErrorOf(function()
      MC:GetAddon()
    end)
    assert.is_truthy(
      string.find(message, "MyAddon has no addon object yet; create it with MC:NewAddon()", 1, true)
    )
    message = TestEnv.ErrorOf(function()
      MC:GetModule("Bags")
    end)
    assert.is_truthy(
      string.find(message, 'has no module named Bags; create it with MC:NewModule("Bags")', 1, true)
    )
  end)

  it("names ModuleKit's file when it is not loaded", function()
    TestEnv.NewPackage()
    local MC = TestEnv.Namespace():For("MyAddon")
    local message = TestEnv.ErrorOf(function()
      MC:NewAddon()
    end)
    assert.is_truthy(
      string.find(
        message,
        "MyAddon uses MoltenCodes ModuleKit (API 1), which is not loaded",
        1,
        true
      )
    )
  end)

  it("raises a ModuleKit refusal at the author's line", function()
    local MC = newFacade()
    TestEnv.ExpectRaisedInside('definition contains unknown field "unknownField"', function()
      MC:NewAddon({ unknownField = true })
    end)
  end)

  it(
    "works with method-name callbacks through the scope when the runtime Kits provide them",
    function()
      local MC = newFacade()
      local addon = MC:NewAddon()
      local supported = nil
      function addon:OnEnable()
        supported =
          pcall(self.scope.Events.Connect, self.scope.Events, "BAG_UPDATE", self, "OnBagUpdate")
      end
      local received = 0
      function addon:OnBagUpdate()
        received = received + 1
      end
      TestEnv.LogIn("MyAddon")
      if not supported then
        pending("EventKit does not take method-name callbacks in this revision (decision 19c)")
        return
      end
      TestEnv.Emit("BAG_UPDATE", 0)
      assert.are.equal(1, received)
    end
  )
end)
