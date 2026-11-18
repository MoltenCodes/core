local TestEnv = require("AddonKitTestEnv")

describe("AddonKit database", function()
  after_each(TestEnv.Reset)

  ---A fresh package with the Database part and its Kits, MyAddon loaded.
  ---@return MoltenCodesFacade
  local function loadedFacade()
    TestEnv.NewPackage()
    TestEnv.LoadKits(TestEnv.CHAINS.database)
    require("AddonKit-Database")
    TestEnv.LoadAddon("MyAddon")
    return TestEnv.Namespace():For("MyAddon")
  end

  it("opens a database whose views read the plain defaults", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", {
      profile = { scale = 1, greet = true, name = "Ann", frame = { x = 10, y = -4 } },
      global = { installs = 0 },
    })
    assert.are.equal(1, db.profile.scale)
    assert.are.equal(true, db.profile.greet)
    assert.are.equal("Ann", db.profile.name)
    assert.are.equal(10, db.profile.frame.x)
    assert.are.equal(0, db.global.installs)
    db.profile.scale = 1.5
    db.profile.frame.y = 3
    assert.are.equal(1.5, TestEnv.GetGlobal("MyAddonDB").profiles.Default.scale)
    assert.are.equal(3, db.profile.frame.y)
  end)

  it(
    "infers types: a wrong type, an undeclared field and a string past its bound are refused",
    function()
      local MC = loadedFacade()
      local db = MC:Database("MyAddonDB", { profile = { scale = 1, name = "x" } })
      assert.has_error(function()
        db.profile.scale = "big"
      end)
      assert.has_error(function()
        db.profile.sclae = 2
      end)
      assert.has_error(function()
        db.profile.name = string.rep("a", 4097)
      end)
    end
  )

  it('reads a ["*"] wildcard\'s defaults for every key, records and plain values alike', function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", {
      profile = { auras = { ["*"] = { shown = true, size = 20 } }, flags = { ["*"] = false } },
    })
    assert.are.equal(true, db.profile.auras[118].shown)
    assert.are.equal(20, db.profile.auras.Renew.size)
    db.profile.auras[118].shown = false
    assert.are.equal(false, db.profile.auras[118].shown)
    assert.are.equal(true, db.profile.auras[119].shown)
    assert.are.equal(false, db.profile.flags.anything)
    db.profile.flags.anything = true
    assert.are.equal(true, db.profile.flags.anything)
  end)

  it("keeps {} as a bounded bag of anything", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", { profile = { notes = {} } })
    db.profile.notes.first = { 1, 2, 3 }
    db.profile.notes[2] = "two"
    assert.are.equal("two", db.profile.notes[2])
  end)

  it("infers a list of one primitive type", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", { profile = { order = { "a", "b" }, sizes = { 1, 2, 3 } } })
    assert.are.same({ "a", "b" }, { db.profile.order[1], db.profile.order[2] })
    assert.has_error(function()
      db.profile.sizes = { 1, "two" }
    end)
  end)

  it("takes inline schema nodes, MC.Range and MC.Enum, and keeps their bounds", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", {
      profile = {
        scale = MC.Range(0.5, 2, 1),
        anchor = MC.Enum({ "TOP", "CENTER" }, "TOP"),
        label = MC.S.string({ max = 8 }),
        width = MC.S.optional(MC.S.number({ integer = true }), 100),
      },
    })
    assert.are.equal(1, db.profile.scale)
    assert.are.equal("TOP", db.profile.anchor)
    assert.is_nil(db.profile.label)
    assert.are.equal(100, db.profile.width)
    assert.has_error(function()
      db.profile.scale = 5
    end)
    assert.has_error(function()
      db.profile.anchor = "LEFT"
    end)
    assert.has_error(function()
      db.profile.label = "much too long"
    end)
    assert.has_error(function()
      db.profile.width = 1.5
    end)
  end)

  it("takes a whole scope written as a schema node", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", {
      profile = MC.S.table({ fields = { scale = MC.S.optional(MC.S.number(), 2) } }),
    })
    assert.are.equal(2, db.profile.scale)
  end)

  it("passes SettingsKit options through", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", { profile = { scale = 1 } }, { defaultProfile = "Shared" })
    assert.are.equal("Shared", db:GetProfile())
  end)

  it("answers the same database for the same defaults, and raises for others", function()
    local MC = loadedFacade()
    local defaults = { profile = { scale = 1 } }
    local db = MC:Database("MyAddonDB", defaults)
    assert.are.equal(db, MC:Database("MyAddonDB", defaults))
    local message = TestEnv.ErrorOf(function()
      MC:Database("MyAddonDB", { profile = { scale = 1 } })
    end)
    assert.is_truthy(
      string.find(message, "MyAddonDB is already open with another defaults table", 1, true)
    )
  end)

  it("refuses to open before ADDON_LOADED, with the fix", function()
    TestEnv.NewPackage()
    TestEnv.LoadKits(TestEnv.CHAINS.database)
    require("AddonKit-Database")
    local MC = TestEnv.Namespace():For("MyAddon")
    local message = TestEnv.ExpectRaisedInside("", function()
      MC:Database("MyAddonDB", { profile = { scale = 1 } })
    end)
    assert.is_truthy(
      string.find(
        message,
        "MyAddon opened MyAddonDB before ADDON_LOADED; open it in OnInitialize, after the client restored it",
        1,
        true
      )
    )
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB"))
  end)

  it("refuses defaults it cannot turn into a schema, saying what to write", function()
    local MC = loadedFacade()
    local cases = {
      {
        { realms = { a = 1 } },
        "has the scope realms, which SettingsKit does not have; its scopes are profile, global, char,"
          .. " realm, class, faction, race, factionrealm, factionrealmregion, locale",
      },
      { {}, "must hold at least one scope" },
      { { profile = 1 }, "defaults.profile must be a table of defaults" },
      { { profile = { ["**"] = { a = 1 } } }, '["**"], which has no SettingsKit form' },
      { { profile = { list = { ["*"] = 1, named = 2 } } }, 'puts ["*"] beside named keys' },
      { { profile = { callback = print } }, "profile.callback is a function" },
      { { profile = { [5] = 1, a = 2 } }, "has a number key; record keys are non-empty strings" },
      {
        { profile = { mixed = { 1, "two" } } },
        "profile.mixed is a list of mixed or table values",
      },
    }
    for _, case in ipairs(cases) do
      local message = TestEnv.ErrorOf(function()
        MC:Database("MyAddonDB", case[1])
      end)
      assert.is_truthy(string.find(message, case[2], 1, true), message)
      assert.is_nil(string.find(message, "AddonKit-Database.lua", 1, true), message)
    end
    local deep = {}
    local cursor = deep
    for _ = 1, 20 do
      cursor.next = { leaf = 1 }
      cursor = cursor.next
    end
    local message = TestEnv.ErrorOf(function()
      MC:Database("MyAddonDB", { profile = deep })
    end)
    assert.is_truthy(string.find(message, "nest deeper than 16 tables", 1, true))
  end)

  it("opens the scopes SettingsKit added in its revision 15 too", function()
    local MC = loadedFacade()
    local db = MC:Database("MyAddonDB", {
      race = { shown = true },
      factionrealm = { count = 1 },
      factionrealmregion = { count = 2 },
      locale = { name = "x" },
    })
    -- Reading these views needs host answers (`UnitRace`, the faction, the
    -- region, the locale) the fake client does not give; opening a database
    -- that declares them is what MC:Database refused before.
    assert.is_table(db)
    assert.is_table(TestEnv.GetGlobal("MyAddonDB"))
  end)

  it("opens plain defaults without SchemaKit", function()
    TestEnv.NewPackage()
    TestEnv.LoadKits({
      "SignalKit",
      "EventKit",
      "LifecycleKit",
      "SettingsKit",
      "SettingsKit-Defaults",
    })
    require("AddonKit-Database")
    TestEnv.LoadAddon("MyAddon")
    local MC = TestEnv.Namespace():For("MyAddon")
    local db = MC:Database("MyAddonDB", { profile = { scale = 1 } })
    assert.are.equal(1, db.profile.scale)
    assert.has_error(function()
      db.profile.scale = "big"
    end)
  end)

  it("names SettingsKit's Defaults part when it is not loaded", function()
    TestEnv.NewPackage()
    TestEnv.LoadKits({ "SignalKit", "EventKit", "LifecycleKit", "SchemaKit", "SettingsKit" })
    require("AddonKit-Database")
    TestEnv.LoadAddon("MyAddon")
    local MC = TestEnv.Namespace():For("MyAddon")
    local message = TestEnv.ErrorOf(function()
      MC:Database("MyAddonDB", { profile = { scale = 1 } })
    end)
    assert.is_truthy(
      string.find(
        message,
        "plain defaults are in SettingsKit's Defaults part, which is not loaded: add settingsKit\\parts\\SettingsKit-Defaults.lua",
        1,
        true
      ),
      message
    )
    assert.is_nil(string.find(message, "AddonKit-Database.lua", 1, true), message)
  end)

  it("names the Kit to embed when SettingsKit is not loaded", function()
    TestEnv.NewPackage()
    TestEnv.LoadKits({ "SignalKit", "EventKit", "LifecycleKit", "SchemaKit" })
    require("AddonKit-Database")
    TestEnv.LoadAddon("MyAddon")
    local MC = TestEnv.Namespace():For("MyAddon")
    local message = TestEnv.ErrorOf(function()
      MC:Database("MyAddonDB", { profile = { scale = 1 } })
    end)
    assert.is_truthy(
      string.find(
        message,
        "MyAddon uses MoltenCodes SettingsKit (API 1), which is not loaded",
        1,
        true
      )
    )
  end)

  it("checks MC.Range and MC.Enum arguments", function()
    local MC = loadedFacade()
    local cases = {
      {
        function()
          MC:Range(0.5, 2, 1)
        end,
        "MC.Range is called with a dot",
      },
      {
        function()
          MC.Range(0.5, "2", 1)
        end,
        "MC.Range takes three numbers",
      },
      {
        function()
          MC.Range(2, 0.5, 1)
        end,
        "SchemaKit.number",
      },
      {
        function()
          MC.Range(0.5, 2, 5)
        end,
        "SchemaKit.optional",
      },
      {
        function()
          MC:Enum({ "A" }, "A")
        end,
        "MC.Enum is called with a dot",
      },
      {
        function()
          MC.Enum("A", "A")
        end,
        "MC.Enum values must be a list",
      },
      {
        function()
          MC.Enum({ "A" })
        end,
        "MC.Enum needs a default",
      },
      {
        function()
          MC.Enum({ "A" }, "B")
        end,
        "SchemaKit.optional",
      },
    }
    for _, case in ipairs(cases) do
      local message = TestEnv.ErrorOf(case[1])
      assert.is_truthy(string.find(message, case[2], 1, true), message)
      assert.is_truthy(string.find(message, "Database_spec.lua", 1, true), message)
    end
  end)

  it("names SchemaKit's file for MC.Range when it is not loaded", function()
    TestEnv.NewPackage()
    require("AddonKit-Database")
    local MC = TestEnv.Namespace():For("MyAddon")
    local message = TestEnv.ErrorOf(function()
      MC.Range(0, 1, 0)
    end)
    assert.is_truthy(
      string.find(message, "This needs MoltenCodes SchemaKit (API 1), which is not loaded", 1, true)
    )
  end)
end)
