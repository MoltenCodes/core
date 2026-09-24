local TestEnv = require("ApiKitTestEnv")

--- The committed Classic Era flavour file, loaded the way an addon embeds it: after
--- the facade, on a Classic Era client, against the shared fixture's host. The
--- exhaustive binding check lives in the tooling suite
--- (`tooling/tests/test_api_committed_flavours.py`); this spec proves the
--- file works with the real facade and the host stubs every Kit's specs use.
describe("ApiKit Classic Era bindings", function()
  after_each(function()
    package.loaded["flavours.ClassicEra"] = nil
    TestEnv.Reset()
  end)

  ---Read the build the committed metadata was captured from.
  ---@return integer build
  local function committedBuild()
    local file = assert(io.open("packages/apiKit/metadata/classic-era/provenance.json", "r"))
    local text = file:read("*a")
    file:close()
    return assert(tonumber(text:match('"build":%s*(%d+)')), "provenance.json names no build")
  end

  it("installs on a Classic Era client and binds the host's functions by direct alias", function()
    local ApiKit = TestEnv.NewPackageFor("classic-era")
    require("flavours.ClassicEra")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.classic.era.api
    -- selene: allow(global_usage)
    assert.are.equal(rawget(_G, "C_Timer").After, api.timer.after)
    -- selene: allow(global_usage)
    assert.are.equal(rawget(_G, "C_Timer").NewTicker, api.timer.newTicker)
    -- selene: allow(global_usage)
    assert.are.equal(rawget(_G, "C_AddOns").IsAddOnLoaded, api.addOns.isAddOnLoaded)
    assert.are.equal("PLAYER_LOGIN", api.events.playerLogin)
    assert.are.equal("ADDON_LOADED", api.events.addonLoaded)
    assert.is_table(api.enums)
    assert.is_table(api.constants)

    local version, build = ApiKit:GetMetadataBuild("classic-era")
    assert.is_string(version)
    assert.are.equal(committedBuild(), build)
  end)

  it("does not bind a namespace the host lacks", function()
    TestEnv.NewPackageFor("classic-era")
    require("flavours.ClassicEra")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.classic.era.api
    assert.is_nil(api.addOnProfiler)
    assert.is_nil(api.profiler)
  end)

  it("costs nothing but its registration on another flavour", function()
    local ApiKit = TestEnv.NewPackageFor("classic-mop")
    require("flavours.ClassicEra")

    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow
    assert.are.same({}, root.classic.era.api)
    assert.are.same({}, root.classic.mop.api)
    local _, build = ApiKit:GetMetadataBuild("classic-era")
    assert.are.equal(committedBuild(), build)
  end)

  it("refuses to load before the facade", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 2, testBuild = false, betaBuild = false })
    require("Registry")
    TestEnv.expectErrorContaining("requires ApiKit API 1 to be loaded first", function()
      TestEnv.requireAfterFailedLoad("flavours.ClassicEra")
    end)
  end)
end)
