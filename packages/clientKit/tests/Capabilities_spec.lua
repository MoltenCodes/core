local Env = require("ClientKitTestEnv")

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    workload()
    local after = collectgarbage("count")
    collectgarbage("restart")
    return after - before
end

local CAPABILITIES = {
    "C_AddOns",
    "C_Spell",
    "C_Item",
    "C_Timer",
    "spellbookApi",
    "eventValidity",
    "secretValues",
    "forbiddenFrames",
    "restrictedFrames",
    "secureCall",
    "profilingClock",
    "preciseClock",
}

-- What each profile's host exposes, flag by flag. The shared host every
-- profile builds on provides `C_AddOns`, `C_Timer` and both clocks, but not
-- `securecallfunction`, which a spec installs explicitly; `classic` removes
-- `C_AddOns` in favour of the legacy globals.
local EXPECTED = {
    mainline = {
        C_AddOns = true,
        C_Spell = true,
        C_Item = true,
        C_Timer = true,
        spellbookApi = true,
        eventValidity = true,
        secretValues = true,
        forbiddenFrames = true,
        restrictedFrames = true,
        secureCall = false,
        profilingClock = true,
        preciseClock = true,
    },
    mists = {
        C_AddOns = true,
        C_Spell = true,
        C_Item = true,
        C_Timer = true,
        spellbookApi = true,
        eventValidity = true,
        secretValues = false,
        forbiddenFrames = true,
        restrictedFrames = false,
        secureCall = false,
        profilingClock = true,
        preciseClock = true,
    },
    tbc = {
        C_AddOns = true,
        C_Spell = false,
        C_Item = true,
        C_Timer = true,
        spellbookApi = false,
        eventValidity = true,
        secretValues = false,
        forbiddenFrames = true,
        restrictedFrames = false,
        secureCall = false,
        profilingClock = true,
        preciseClock = true,
    },
    classic = {
        C_AddOns = false,
        C_Spell = false,
        C_Item = false,
        C_Timer = true,
        spellbookApi = false,
        eventValidity = false,
        secretValues = false,
        forbiddenFrames = true,
        restrictedFrames = false,
        secureCall = false,
        profilingClock = true,
        preciseClock = true,
    },
    noProjectId = {
        C_AddOns = true,
        C_Spell = false,
        C_Item = false,
        C_Timer = true,
        spellbookApi = false,
        eventValidity = false,
        secretValues = false,
        forbiddenFrames = false,
        restrictedFrames = false,
        secureCall = false,
        profilingClock = true,
        preciseClock = true,
    },
}

describe("ClientKit:Has", function()
    after_each(function()
        Env.Reset()
    end)

    for _, profileName in ipairs(Env.WOW_PROFILES) do
        it("reports what the " .. profileName .. " host exposes", function()
            local ClientKit = Env.NewPackageFor(profileName)
            for _, capability in ipairs(CAPABILITIES) do
                local expected = EXPECTED[profileName][capability]
                assert.are.equal(expected, ClientKit:Has(capability), capability)
            end
        end)
    end

    it("reports secureCall once the host publishes securecallfunction", function()
        Env.Reset()
        Env.SetWowProfile("mainline")
        Env.InstallWowApi()
        Env.InstallSecureCallFunction()
        require("Registry")
        assert.is_true(require("ClientKit"):Has("secureCall"))
    end)

    it("never reports every capability when WOW_PROJECT_ID is absent", function()
        local ClientKit = Env.NewPackageFor("noProjectId")
        local trueCount = 0
        for _, capability in ipairs(CAPABILITIES) do
            if ClientKit:Has(capability) then
                trueCount = trueCount + 1
            end
        end
        assert.is_true(trueCount < #CAPABILITIES)
        assert.is_false(ClientKit:Has("secretValues"))
        assert.is_false(ClientKit:Has("restrictedFrames"))
    end)

    it("reads every flag as false on a host that exposes nothing", function()
        -- `wowApi` stubs off: no C_AddOns, no C_Timer, no clocks, no identity.
        Env.Reset()
        require("Registry")
        local ClientKit = require("ClientKit")
        for _, capability in ipairs(CAPABILITIES) do
            assert.is_false(ClientKit:Has(capability), capability)
        end
        assert.are.equal("classic", ClientKit:GetFlavor())
    end)

    it("probes the host, not the flavour", function()
        -- A mainline project id on a host with no modern surface answers from
        -- the surface: the flavour never turns a flag on.
        Env.NewPackageFor("classic")
        -- The spec stands in for a client whose API only exists in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "WOW_PROJECT_ID", 1)
        package.loaded["Registry"] = nil
        package.loaded["ClientKit"] = nil
        -- selene: allow(global_usage)
        rawset(_G, Env.NAMESPACE_KEY, nil)
        -- selene: allow(global_usage)
        rawset(_G, Env.REGISTRY_STATE_KEY, nil)
        require("Registry")
        local ClientKit = require("ClientKit")

        assert.are.equal("mainline", ClientKit:GetFlavor())
        assert.is_false(ClientKit:Has("C_Spell"))
        assert.is_false(ClientKit:Has("secretValues"))
    end)

    it("rejects a capability outside the fixed table", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.expectErrorContaining('ClientKit:Has does not know capability "C_Foo"', function()
            ClientKit:Has("C_Foo")
        end)
        Env.expectErrorContaining("ClientKit:Has capability must be a string", function()
            ClientKit:Has(nil)
        end)
    end)

    it("refuses a secret capability name before using it as a key", function()
        local ClientKit = Env.NewPackageFor("mainline", { secretStrings = { "C_Spell" } })
        Env.expectErrorContaining("ClientKit:Has capability must not be a secret value", function()
            ClientKit:Has("C_Spell")
        end)
        assert.is_true(ClientKit:Has("C_Item"))
    end)

    it("allocates nothing after bootstrap #allocation", function()
        local ClientKit = Env.NewPackageFor("mainline")
        local frame = Env.NewFrame({ forbidden = false, accessible = true })
        local allocated = allocatedKilobytes(function()
            for _ = 1, 1000 do
                ClientKit:Has("C_Spell")
                ClientKit:GetFlavor()
                ClientKit:GetInterfaceNumber()
                ClientKit:IsAtLeast(120000)
                ClientKit:GetBuild()
                ClientKit:IsSecret(frame)
                ClientKit:IsEventValid("PLAYER_LOGIN")
                ClientKit:IsAddOnLoaded("MyAddon")
            end
        end)
        assert.are.equal(0, allocated)

        -- CanAccessFrame on a frame double records its calls, so it is
        -- measured on a frame without methods.
        local bare = Env.NewFrame()
        assert.are.equal(
            0,
            allocatedKilobytes(function()
                for _ = 1, 1000 do
                    ClientKit:CanAccessFrame(bare)
                end
            end)
        )
    end)
end)
