local TestEnv = require("AddonKitTestEnv")

describe("AddonKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("publishes through Registry and installs MoltenCodes.For", function()
    local AddonKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("addonKit", 1)
    assert.are.equal(AddonKit, registered)
    assert.are.equal(AddonKit.REVISION, revision)
    assert.are.equal(AddonKit.For, rawget(TestEnv.Namespace(), "For"))
    assert.are.equal(AddonKit:For("MyAddon"), TestEnv.Namespace():For("MyAddon"))
  end)

  it("returns the same facade on a duplicate embedded load and keeps every facade", function()
    local AddonKit = TestEnv.NewPackage()
    local facade = AddonKit:For("MyAddon")
    local entry = AddonKit.For
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(AddonKit, reloaded)
    assert.are.equal(entry, rawget(TestEnv.Namespace(), "For"))
    assert.are.equal(facade, TestEnv.Namespace():For("MyAddon"))
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local AddonKit, Registry = TestEnv.NewPackage()
    local shippedRevision = AddonKit.REVISION
    local upgraded, previous = Registry:Register("addonKit", 1, 99)
    assert.are.equal(AddonKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(AddonKit, "REVISION", 99)
    rawset(AddonKit, "_state", { schema = 999 })
    package.loaded["AddonKit"] = nil
    local reloaded = require("AddonKit")
    assert.are.equal(AddonKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place: facades, cached Kits, pins, parts and the entry run the new code",
    function()
      local AddonKit = TestEnv.NewPackage()
      TestEnv.LoadKits({ "SignalKit" })
      TestEnv.LoadParts()
      local MC = AddonKit:For("MyAddon")
      local SignalKit = MC.SignalKit
      MC:Use("EventKit", 1)
      AddonKit:SetLimits({ maxFacades = 9 })
      local entry = AddonKit.For

      local upgraded = TestEnv.LoadRevision(AddonKit.REVISION + 1)
      assert.are.equal(AddonKit, upgraded)
      assert.are.equal(AddonKit.REVISION, upgraded.REVISION)
      assert.are.equal(9, upgraded:GetLimits().maxFacades)
      assert.are.equal(entry, upgraded.For)
      assert.are.equal(entry, rawget(TestEnv.Namespace(), "For"))
      assert.are.equal(MC, TestEnv.Namespace():For("MyAddon"))
      assert.are.equal(SignalKit, MC.SignalKit)
      -- The new revision's methods are found through the shared metatable.
      assert.are.equal(rawget(AddonKit, "_state").methods.NewAddon, MC.NewAddon)
      -- Parts installed before the upgrade still serve the facade.
      assert.is_function(MC.Database)
      assert.is_function(MC.Options)
      assert.are.equal(225, MC.LAUNCHER_DEFAULTS.minimapPos)
    end
  )

  it("keeps a part of an equal or newer revision and replaces an older one", function()
    local AddonKit = TestEnv.NewPackage()
    TestEnv.LoadParts()
    local state = rawget(AddonKit, "_state")
    local database = state.methods.Database
    TestEnv.LoadPartRevision("Database", 1)
    assert.are.equal(database, state.methods.Database)
    TestEnv.LoadPartRevision("Database", 2)
    assert.are_not.equal(database, state.methods.Database)
    assert.are.equal(2, state.parts.Database.revision)
    local options = state.methods.Options
    TestEnv.LoadPartRevision("Composition", 2)
    assert.are_not.equal(options, state.methods.Options)
    -- A lower revision loaded later leaves the newer one in place.
    local newer = state.methods.Options
    TestEnv.LoadPartRevision("Composition", 1)
    assert.are.equal(newer, state.methods.Options)
  end)

  it("leaves a foreign MoltenCodes.For alone and reports it once", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local foreign = function() end
    rawset(TestEnv.Namespace(), "For", foreign)
    local AddonKit = require("AddonKit")
    assert.are.equal(foreign, rawget(TestEnv.Namespace(), "For"))
    assert.is_table(AddonKit:For("MyAddon"))
    local reported = TestEnv.ReportedErrors()
    assert.are.equal(1, #reported)
    assert.is_truthy(string.find(reported[1], 'Get("addonKit", 1):For(...)', 1, true))
    TestEnv.ReloadPackage()
    TestEnv.LoadRevision(AddonKit.REVISION + 1)
    assert.are.equal(1, #TestEnv.ReportedErrors())
  end)

  it("refuses to load without Registry API 2", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.expectErrorContaining("requires Registry API 2 to be loaded first", function()
      TestEnv.requireAfterFailedLoad("AddonKit")
    end)
  end)

  it("refuses a Registry facade without Bootstrap or Find", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetGlobal("MoltenCodes", { Registries = { [2] = { API = 2 } } })
    TestEnv.expectErrorContaining("requires a valid Registry API 2 facade", function()
      TestEnv.requireAfterFailedLoad("AddonKit")
    end)
  end)

  it("refuses inherited state that is corrupted", function()
    local AddonKit = TestEnv.NewPackage()
    rawget(AddonKit, "_state").facades = false
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.LoadRevision(AddonKit.REVISION + 1)
    end)
  end)

  it("refuses state that holds a limit out of range", function()
    local AddonKit = TestEnv.NewPackage()
    rawget(AddonKit, "_state").limits.maxFacades = 0
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.LoadRevision(AddonKit.REVISION + 1)
    end)
  end)

  it("refuses to load a part before the core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.expectErrorContaining(
      "MoltenCodes AddonKit part Database requires AddonKit API 1 to be loaded first",
      function()
        TestEnv.requireAfterFailedLoad("AddonKit-Database")
      end
    )
    TestEnv.expectErrorContaining(
      "MoltenCodes AddonKit part Composition requires AddonKit API 1 to be loaded first",
      function()
        TestEnv.requireAfterFailedLoad("AddonKit-Composition")
      end
    )
  end)
end)
