local TestEnv = require("ApiKitTestEnv")

describe("ApiKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("returns the same facade on duplicate embedded load", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(ApiKit, reloaded)
  end)

  it("publishes through Registry", function()
    local ApiKit, Registry = TestEnv.NewPackageFor("retail")
    local registered, revision = Registry:Get("apiKit", 1)
    assert.are.equal(ApiKit, registered)
    assert.are.equal(ApiKit.REVISION, revision)
  end)

  it("requires Registry to be loaded first", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = false })
    TestEnv.expectErrorContaining("requires Registry API 2 to be loaded first", function()
      TestEnv.requireAfterFailedLoad("ApiKit")
    end)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local ApiKit, Registry = TestEnv.NewPackageFor("retail")
    local shippedRevision = ApiKit.REVISION
    local upgraded, previous = Registry:Register("apiKit", 1, 99)
    assert.are.equal(ApiKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(ApiKit, "REVISION", 99)
    rawset(ApiKit, "_state", { schema = 999 })
    package.loaded["ApiKit"] = nil

    local reloaded = require("ApiKit")
    assert.are.equal(ApiKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("publishes every flavour namespace under MoltenCodes.wow", function()
    TestEnv.NewPackageFor("retail")
    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow
    assert.is_table(root.retail.api)
    assert.is_table(root.classic.era.api)
    assert.is_table(root.classic.mop.api)
    assert.is_table(root.ptr.api)
    assert.is_table(root.beta.api)
  end)

  it("keeps the flavour a same-revision copy already probed", function()
    -- Registry returns a complete same-revision copy unchanged, so the
    -- re-probe every bootstrap runs is only reachable through an upgrade;
    -- the upgrade specs below cover it.
    local ApiKit = TestEnv.NewPackageFor("tbc")
    assert.are.equal("unsupported", ApiKit:GetFlavor())
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = false })
    package.loaded["ApiKit"] = nil
    require("ApiKit")
    assert.are.equal("unsupported", ApiKit:GetFlavor())
  end)

  it("upgrades a revision 1 copy in place and keeps the namespace and registrations", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = false })
    require("Registry")
    local old = TestEnv.LoadRevision(1)
    local state = old._state
    local runs = 0
    assert.is_true(old:RegisterFlavor("retail", function(api)
      runs = runs + 1
      api.marker = true
    end, { version = "12.0.1", build = 60000 }))
    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow

    local upgraded = TestEnv.requireAfterFailedLoad("ApiKit")

    assert.are.equal(old, upgraded)
    assert.is_true(upgraded.REVISION > 1)
    assert.are.equal(state, upgraded._state)
    -- selene: allow(global_usage)
    assert.are.equal(root, rawget(_G, "MoltenCodes").wow)
    assert.is_true(root.retail.api.marker)
    assert.are.equal("published", upgraded:GetGlobalStatus())
    assert.are.same({ "12.0.1", 60000 }, { upgraded:GetMetadataBuild("retail") })
    -- The installed flavour is not installed a second time.
    assert.is_false(upgraded:RegisterFlavor("retail", function()
      runs = runs + 1
    end))
    assert.are.equal(1, runs)
    -- Absent info is told apart with `type` by the current methods.
    assert.is_false(upgraded:RegisterFlavor("classic-era", function() end, nil))
  end)

  it("re-probes the client when a newer revision upgrades in place", function()
    local ApiKit = TestEnv.NewPackageFor("tbc")
    assert.are.equal("unsupported", ApiKit:GetFlavor())
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = false })

    local upgraded = TestEnv.LoadRevision(ApiKit.REVISION + 1)

    assert.are.equal(ApiKit, upgraded)
    assert.are.equal(ApiKit.REVISION, upgraded.REVISION)
    assert.are.equal("retail", upgraded:GetFlavor())
  end)

  it("keeps the namespace tables across a reload", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow
    ApiKit:RegisterFlavor("retail", function(api)
      api.marker = true
    end)

    TestEnv.ReloadPackage()

    -- selene: allow(global_usage)
    assert.are.equal(root, rawget(_G, "MoltenCodes").wow)
    assert.is_true(root.retail.api.marker)
  end)

  it("lists the supported flavours read-only, in table order", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    assert.are.equal(5, ApiKit.SUPPORTED_FLAVOR_COUNT)
    local listed = {}
    for index = 1, ApiKit.SUPPORTED_FLAVOR_COUNT do
      listed[index] = ApiKit.SUPPORTED_FLAVORS[index]
    end
    assert.are.same({ "retail", "classic-era", "classic-mop", "ptr", "beta" }, listed)
    assert.is_nil(ApiKit.SUPPORTED_FLAVORS[6])
    -- Lua 5.1 does not see through the read-only view; the count is the way to walk it.
    assert.are.equal(0, #ApiKit.SUPPORTED_FLAVORS)
    assert.has_error(function()
      ApiKit.SUPPORTED_FLAVORS[6] = "wrath"
    end, 'ApiKit.SUPPORTED_FLAVORS is read-only; index "6" cannot be written')
  end)

  it("refuses a same-revision copy whose state is incomplete", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    rawset(ApiKit, "_state", { schema = 1 })
    package.loaded["ApiKit"] = nil
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.requireAfterFailedLoad("ApiKit")
    end)
  end)
end)
