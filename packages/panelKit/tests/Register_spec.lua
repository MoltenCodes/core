local TestEnv = require("PanelKitTestEnv")

describe("PanelKit:Register", function()
  local PanelKit, settings
  before_each(function()
    PanelKit, settings = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("registers a canvas category in the AddOns list, named after the tree by default", function()
    local panel = PanelKit:Register("MyAddon")
    assert.are.equal(1, #settings.categories)
    local category = settings.categories[1]
    assert.are.equal("MyAddon", category.name)
    assert.are.same({ category }, settings.addOns)
    assert.are.equal("MyAddon", panel:GetName())
    assert.are.equal(category.ID, panel:GetCategoryID())
    assert.is_false(category.frame:IsShown())
  end)

  it("uses options.name as the title", function()
    local panel = PanelKit:Register("MyAddon", { name = "My Addon" })
    assert.are.equal("My Addon", settings.categories[1].name)
    assert.are.equal("My Addon", panel:GetName())
    assert.are.equal(panel, PanelKit:Get("My Addon"))
    assert.is_nil(PanelKit:Get("MyAddon"))
  end)

  it("registers a subcategory under a parent panel, outside the AddOns list", function()
    local parent = PanelKit:Register("MyAddon")
    local child = PanelKit:Register("MyAddonProfiles", { name = "Profiles", parent = parent })
    local category = settings.categories[2]
    assert.are.equal(settings.categories[1], category.parent)
    assert.are.equal("Profiles", category.name)
    assert.are.equal(1, #settings.addOns)
    assert.are.equal(child, PanelKit:Get("Profiles", parent))
    assert.is_nil(PanelKit:Get("Profiles"))
  end)

  it("reads the category ID from an ID field when the category has no GetID", function()
    settings.RegisterCanvasLayoutCategory = function(frame, name)
      return { ID = "id:" .. name, frame = frame }
    end
    assert.are.equal("id:MyAddon", PanelKit:Register("MyAddon"):GetCategoryID())
  end)

  it("refuses a name taken at the same level and accepts it under another parent", function()
    local first = PanelKit:Register("First")
    local second = PanelKit:Register("Second")
    PanelKit:Register("FirstGeneral", { name = "General", parent = first })
    PanelKit:Register("SecondGeneral", { name = "General", parent = second })
    TestEnv.expectErrorContaining("a panel named First is already registered there", function()
      PanelKit:Register("First")
    end)
    TestEnv.expectErrorContaining("a panel named General is already registered there", function()
      PanelKit:Register("Other", { name = "General", parent = first })
    end)
    assert.are.equal(4, #settings.categories)
  end)

  it("refuses invalid arguments without registering anything", function()
    local cases = {
      { "treeName must be a non-empty string", nil },
      { "treeName must be a non-empty string", "" },
      { "treeName must be a non-empty string", 1 },
      { "options must be a table or nil", "MyAddon", "options" },
      { "options holds an unknown field; it accepts name and parent", "MyAddon", { title = "x" } },
      { "options holds an unknown field; it accepts name and parent", "MyAddon", { [1] = "x" } },
      { "options.name must be a non-empty string", "MyAddon", { name = "" } },
      { "options.parent must be a PanelKit panel", "MyAddon", { parent = {} } },
    }
    for _, case in ipairs(cases) do
      TestEnv.expectErrorContaining("PanelKit:Register " .. case[1], function()
        PanelKit:Register(case[2], case[3])
      end)
    end
    assert.are.equal(0, #settings.categories)
  end)

  it("refuses to register on a host without the Settings API", function()
    TestEnv.SetGlobal("Settings", nil)
    TestEnv.expectErrorContaining("needs the client's Settings API", function()
      PanelKit:Register("MyAddon")
    end)
    TestEnv.SetGlobal("Settings", { RegisterCanvasLayoutCategory = function() end })
    TestEnv.expectErrorContaining("needs the client's Settings API", function()
      PanelKit:Register("MyAddon")
    end)
    assert.is_nil(PanelKit:Get("MyAddon"))
  end)

  it("checks Get's arguments", function()
    TestEnv.expectErrorContaining("PanelKit:Get name must be a non-empty string", function()
      PanelKit:Get(nil)
    end)
    TestEnv.expectErrorContaining("PanelKit:Get parent must be a PanelKit panel or nil", function()
      PanelKit:Get("MyAddon", {})
    end)
    assert.is_nil(PanelKit:Get("Nothing"))
  end)

  it("refuses a facade method called without the facade", function()
    for _, call in ipairs({
      function()
        PanelKit.Register({}, "MyAddon")
      end,
      function()
        PanelKit.Get(nil, "MyAddon")
      end,
      function()
        PanelKit.SetLimits({}, {})
      end,
      function()
        PanelKit.GetLimits("PanelKit")
      end,
    }) do
      TestEnv.expectErrorContaining("must be called on the PanelKit facade", call)
    end
  end)

  it("refuses a panel method called without a panel", function()
    local panel = PanelKit:Register("MyAddon")
    for _, name in ipairs({
      "Open",
      "GetName",
      "GetCategoryID",
      "GetRendering",
      "SetDefaultHandler",
    }) do
      TestEnv.expectErrorContaining(
        "PanelKit.Panel:" .. name .. " must be called on a PanelKit panel",
        function()
          panel[name]({})
        end
      )
    end
  end)

  it("hides the handle's metatable", function()
    local panel = PanelKit:Register("MyAddon")
    assert.are.equal("PanelKit.Panel", getmetatable(panel))
  end)
end)
