local TestEnv = require("ApiKitTestEnv")

--- The committed Retail flavour file, loaded the way an addon embeds it: after
--- the facade, on a Retail client, against the shared fixture's host. The
--- exhaustive binding check lives in the tooling suite
--- (`tooling/tests/test_api_committed_flavours.py`); this spec proves the
--- file works with the real facade and the host stubs every Kit's specs use.
describe("ApiKit Retail bindings", function()
  after_each(function()
    package.loaded["flavours.Retail"] = nil
    TestEnv.Reset()
  end)

  ---Read the build the committed metadata was captured from.
  ---@return integer build
  local function committedBuild()
    local file = assert(io.open("packages/apiKit/metadata/retail/provenance.json", "r"))
    local text = file:read("*a")
    file:close()
    return assert(tonumber(text:match('"build":%s*(%d+)')), "provenance.json names no build")
  end

  it("installs on a Retail client and binds the host's functions by direct alias", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    require("flavours.Retail")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.retail.api
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

    local version, build = ApiKit:GetMetadataBuild("retail")
    assert.is_string(version)
    assert.are.equal(committedBuild(), build)
  end)

  it("does not bind a namespace the host lacks", function()
    TestEnv.NewPackageFor("retail")
    require("flavours.Retail")

    -- selene: allow(global_usage)
    local api = rawget(_G, "MoltenCodes").wow.retail.api
    assert.is_nil(api.addOnProfiler)
    assert.is_nil(api.profiler)
  end)

  it(
    "binds a function its documentation places outside its system's namespace from where it lives",
    function()
      -- `InCombatLockdown` is documented in the `C_RestrictedActions` system with
      -- `Namespace = ""`: the client has it as a global, and a client without the
      -- `C_RestrictedActions` table still gets the wrapper (CHANGELOG 0.1.4).
      local function inCombatLockdown()
        return false
      end
      TestEnv.NewPackageFor("retail")
      -- The fixture stands in for the client, whose globals only exist in the global table.
      -- selene: allow(global_usage)
      rawset(_G, "InCombatLockdown", inCombatLockdown)
      -- selene: allow(global_usage)
      assert.is_nil(rawget(_G, "C_RestrictedActions"))
      require("flavours.Retail")

      -- selene: allow(global_usage)
      local api = rawget(_G, "MoltenCodes").wow.retail.api
      -- selene: allow(global_usage)
      rawset(_G, "InCombatLockdown", nil)
      assert.are.equal(inCombatLockdown, api.restrictedActions.inCombatLockdown)
      assert.is_nil(api.restrictedActions.checkAllowProtectedFunctions)
    end
  )

  it("costs nothing but its registration on another flavour", function()
    local ApiKit = TestEnv.NewPackageFor("classic-era")
    require("flavours.Retail")

    -- selene: allow(global_usage)
    local root = rawget(_G, "MoltenCodes").wow
    assert.are.same({}, root.retail.api)
    assert.are.same({}, root.classic.era.api)
    local _, build = ApiKit:GetMetadataBuild("retail")
    assert.are.equal(committedBuild(), build)
  end)

  it("refuses to load before the facade", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.SetClient({ projectId = 1, testBuild = false, betaBuild = false })
    require("Registry")
    TestEnv.expectErrorContaining("requires ApiKit API 1 to be loaded first", function()
      TestEnv.requireAfterFailedLoad("flavours.Retail")
    end)
  end)
end)
