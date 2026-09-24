local TestEnv = require("ApiKitTestEnv")

--- The committed Beta flavour file, loaded the way an addon embeds it: after
--- the facade, on a Beta client, against the shared fixture's host. The
--- exhaustive binding check lives in the tooling suite
--- (`tooling/tests/test_api_committed_flavours.py`); this spec proves the
--- file works with the real facade and the host stubs every Kit's specs use.
describe("ApiKit Beta bindings", function()
  after_each(function()
    package.loaded["flavours.Beta"] = nil
    TestEnv.Reset()
  end)

  ---Read the build the committed metadata was captured from.
  ---@return integer build
  local function committedBuild()
    local file = assert(io.open("packages/apiKit/metadata/beta/provenance.json", "r"))
    local text = file:read("*a")
    file:close()
    return assert(tonumber(text:match('"build":%s*(%d+)')), "provenance.json names no build")
  end

  it("installs on a Beta client and binds the host's functions by direct alias", function()
    local ApiKit = TestEnv.NewPackageFor("beta")
    require("flavours.Beta")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.beta.api
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

    local version, build = ApiKit:GetMetadataBuild("beta")
    assert.is_string(version)
    assert.are.equal(committedBuild(), build)
  end)

  it("does not bind a namespace the host lacks", function()
    TestEnv.NewPackageFor("beta")
    require("flavours.Beta")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.beta.api
    assert.is_nil(api.addOnProfiler)
    assert.is_nil(api.profiler)
  end)

  it("costs nothing but its registration on another flavour", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    require("flavours.Beta")

    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow
    assert.are.same({}, root.beta.api)
    assert.are.same({}, root.retail.api)
    local _, build = ApiKit:GetMetadataBuild("beta")
    assert.are.equal(committedBuild(), build)
  end)

  it("refuses to load before the facade", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1, testBuild = true, betaBuild = true })
    require("Registry")
    TestEnv.expectErrorContaining("requires ApiKit API 1 to be loaded first", function()
      TestEnv.requireAfterFailedLoad("flavours.Beta")
    end)
  end)
end)
