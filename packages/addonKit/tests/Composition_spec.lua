local TestEnv = require("AddonKitTestEnv")

describe("AddonKit composition", function()
  after_each(TestEnv.Reset)

  local TREE = {
    type = "group",
    name = "My Addon",
    args = {
      scale = {
        type = "range",
        name = "Scale",
        min = 0.5,
        max = 2,
        step = 0.1,
        bind = "profile.scale",
      },
    },
  }

  ---The client, every Kit and both parts, MyAddon loaded, and its database.
  ---@return MoltenCodesFacade
  ---@return table db
  ---@return table settings
  local function setUp()
    local _, settings = TestEnv.InstallClient()
    require("Registry")
    require("AddonKit")
    TestEnv.LoadKits(TestEnv.CHAINS.modules)
    TestEnv.LoadKits(TestEnv.CHAINS.composition)
    TestEnv.LoadParts()
    TestEnv.LoadAddon("MyAddon")
    local MC = TestEnv.Namespace():For("MyAddon")
    local db = MC:Database("MyAddonDB", { profile = { scale = 1, minimap = MC.LAUNCHER_DEFAULTS } })
    return MC, db, settings
  end

  it("registers the panel and a slash command that opens it", function()
    local MC, db, settings = setUp()
    local panel = MC:Options(TREE, { db = db, slash = "myaddon" })
    assert.is_table(panel)
    assert.are.equal(1, #settings.addOns)
    assert.are.equal("My Addon", settings.addOns[1].name)
    assert.is_true(TestEnv.RunSlash("/myaddon"))
    assert.are.equal(1, #settings.opened)
  end)

  it("takes a title, and works without a slash command or settings", function()
    local MC, _, settings = setUp()
    MC:Options({ type = "group", name = "Plain", args = {} }, { title = "Shown Title" })
    assert.are.equal("Shown Title", settings.addOns[1].name)
    local other = TestEnv.Namespace():For("OtherAddon")
    other:Options({ type = "group", args = {} })
    assert.are.equal("OtherAddon", settings.addOns[2].name)
  end)

  it("raises a taken slash name with the fix and leaves nothing behind", function()
    local MC, db, settings = setUp()
    MC.CommandKit:ForAddon("OtherAddon"):Register("myaddon", { handler = function() end })
    local message = TestEnv.ExpectRaisedInside("", function()
      MC:Options(TREE, { db = db, slash = "myaddon" })
    end)
    assert.is_truthy(
      string.find(
        message,
        "/myaddon is already used by another addon or a chat command; pass another slash name",
        1,
        true
      )
    )
    assert.are.equal(0, #settings.addOns)
    assert.is_nil(MC.OptionsKit:Get("MyAddon"))
  end)

  it("unregisters the command again when the tree is refused", function()
    local MC, db = setUp()
    local message = TestEnv.ErrorOf(function()
      MC:Options({ type = "nonsense" }, { db = db, slash = "myaddon" })
    end)
    assert.is_nil(string.find(message, "AddonKit-Composition.lua", 1, true), message)
    assert.is_truthy(string.find(message, "Composition_spec.lua", 1, true), message)
    assert.is_false(MC.CommandKit:ForAddon("MyAddon"):IsRegistered("myaddon"))
  end)

  it("checks its arguments", function()
    local MC = setUp()
    local cases = {
      {
        function()
          MC:Options("tree")
        end,
        "MC:Options tree must be an OptionsKit tree",
      },
      {
        function()
          MC:Options(TREE, 5)
        end,
        "MC:Options settings must be a table",
      },
      {
        function()
          MC:Options(TREE, { slsh = "x" })
        end,
        "settings holds an unknown field; it accepts db, slash and title",
      },
      {
        function()
          MC:Options(TREE, { slash = "" })
        end,
        "MC:Options settings.slash must be a non-empty string",
      },
      {
        function()
          MC:Options(TREE, { title = 4 })
        end,
        "MC:Options settings.title must be a non-empty string",
      },
    }
    for _, case in ipairs(cases) do
      local message = TestEnv.ErrorOf(case[1])
      assert.is_truthy(string.find(message, case[2], 1, true), message)
      assert.is_truthy(string.find(message, "Composition_spec.lua", 1, true), message)
    end
  end)

  it("places a launcher kept in the profile, and moves it on a profile switch", function()
    local MC, db = setUp()
    db.profile.minimap.minimapPos = 90
    local launcher = MC:Launcher({ icon = 134400 }, db)
    assert.are.equal(launcher, MC.LauncherKit:Get("MyAddon"))
    assert.are.equal("launcher", MC.BrokerKit:Get("MyAddon").type)
    local refreshed = 0
    local refresh = launcher.Refresh
    rawset(launcher, "Refresh", function(self)
      refreshed = refreshed + 1
      return refresh(self)
    end)
    db:SetProfile("Other")
    assert.are.equal(1, refreshed)
    assert.are.equal(225, db.profile.minimap.minimapPos)
  end)

  it("raises with the fix when the profile does not declare the launcher's field", function()
    local MC, db = setUp()
    local message = TestEnv.ErrorOf(function()
      MC:Launcher({ icon = 134400 }, db, "button")
    end)
    assert.is_truthy(
      string.find(message, "declare button = MC.LAUNCHER_DEFAULTS in the profile defaults", 1, true),
      message
    )
    assert.is_nil(MC.BrokerKit:Get("MyAddon"))
  end)

  it("checks the launcher's arguments", function()
    local MC, db = setUp()
    local cases = {
      {
        function()
          MC:Launcher(nil, db)
        end,
        "MC:Launcher definition must be a table",
      },
      {
        function()
          MC:Launcher({}, {})
        end,
        "MC:Launcher db must be a database",
      },
      {
        function()
          MC:Launcher({}, db, "")
        end,
        "MC:Launcher field must be a non-empty string",
      },
      {
        function()
          MC:Launcher({ text = 5 }, db)
        end,
        "BrokerKit:New",
      },
    }
    for _, case in ipairs(cases) do
      local message = TestEnv.ErrorOf(case[1])
      assert.is_truthy(string.find(message, case[2], 1, true), message)
      assert.is_truthy(string.find(message, "Composition_spec.lua", 1, true), message)
    end
  end)

  it("gives each addon its own LAUNCHER_DEFAULTS table", function()
    local MC = setUp()
    local other = TestEnv.Namespace():For("OtherAddon")
    assert.are.same({ hide = false, lock = false, minimapPos = 225 }, MC.LAUNCHER_DEFAULTS)
    assert.are.equal(MC.LAUNCHER_DEFAULTS, MC.LAUNCHER_DEFAULTS)
    assert.are_not.equal(MC.LAUNCHER_DEFAULTS, other.LAUNCHER_DEFAULTS)
  end)
end)
