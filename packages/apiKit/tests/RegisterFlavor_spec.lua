local TestEnv = require("ApiKitTestEnv")

describe("ApiKit:RegisterFlavor", function()
    after_each(TestEnv.Reset)

    it(
        "runs the installer of the running flavour at once, with its api table and the host",
        function()
            local ApiKit = TestEnv.NewPackageFor("retail")
            local received = {}
            local installed = ApiKit:RegisterFlavor("retail", function(api, host)
                received.api = api
                received.host = host
                api.timer = { after = host.C_Timer.After }
            end, { version = "12.1.0", build = 69933 })

            assert.is_true(installed)
            -- selene: allow(global_usage)
            local root = rawget(_G, "MoltenCodes").wow
            assert.are.equal(root.retail.api, received.api)
            -- selene: allow(global_usage)
            assert.are.equal(_G, received.host)
            -- selene: allow(global_usage)
            assert.are.equal(rawget(_G, "C_Timer").After, root.retail.api.timer.after)
        end
    )

    it("drops an installer for another flavour without running it", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local ran = false
        local installed = ApiKit:RegisterFlavor("classic-era", function()
            ran = true
        end)

        assert.is_false(installed)
        assert.is_false(ran)
        -- selene: allow(global_usage)
        assert.are.same({}, rawget(_G, "MoltenCodes").wow.classic.era.api)
    end)

    it("installs nothing on an unsupported client", function()
        local ApiKit = TestEnv.NewPackageFor("tbc")
        local ran = false
        assert.is_false(ApiKit:RegisterFlavor("retail", function()
            ran = true
        end))
        assert.is_false(ran)
    end)

    it("keeps the first installer of a flavour and drops later copies", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        assert.is_true(ApiKit:RegisterFlavor("retail", function(api)
            api.first = true
        end, { build = 1 }))
        assert.is_false(ApiKit:RegisterFlavor("retail", function(api)
            api.second = true
        end, { build = 2 }))

        -- selene: allow(global_usage)
        local api = rawget(_G, "MoltenCodes").wow.retail.api
        assert.is_true(api.first)
        assert.is_nil(api.second)
        local _, build = ApiKit:GetMetadataBuild("retail")
        assert.are.equal(1, build)
    end)

    it("records the metadata build of every registered flavour", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        ApiKit:RegisterFlavor("classic-era", function() end, { version = "1.15.9", build = 69722 })

        local version, build = ApiKit:GetMetadataBuild("classic-era")
        assert.are.equal("1.15.9", version)
        assert.are.equal(69722, build)
        assert.is_nil(ApiKit:GetMetadataBuild("ptr"))
    end)

    it("records nothing for a registration without info", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        ApiKit:RegisterFlavor("retail", function() end)
        local version, build = ApiKit:GetMetadataBuild("retail")
        assert.is_nil(version)
        assert.is_nil(build)
    end)

    it("lets an installer failure propagate and does not retry that flavour", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        assert.has_error(function()
            ApiKit:RegisterFlavor("retail", function()
                error("generated file is broken", 0)
            end)
        end, "generated file is broken")
        local ran = false
        assert.is_false(ApiKit:RegisterFlavor("retail", function()
            ran = true
        end))
        assert.is_false(ran)
    end)

    it("survives a reload with the installed flavour intact", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        ApiKit:RegisterFlavor("retail", function(api)
            api.kept = true
        end, { build = 5 })
        local reloaded = TestEnv.ReloadPackage()

        -- selene: allow(global_usage)
        assert.is_true(rawget(_G, "MoltenCodes").wow.retail.api.kept)
        assert.is_false(reloaded:RegisterFlavor("retail", function(api)
            api.again = true
        end))
        local _, build = reloaded:GetMetadataBuild("retail")
        assert.are.equal(5, build)
    end)

    it("validates its arguments", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        assert.has_error(function()
            ApiKit:RegisterFlavor("wrath", function() end)
        end)
        assert.has_error(function()
            ApiKit:RegisterFlavor("retail", "not a function")
        end)
        assert.has_error(function()
            ApiKit:RegisterFlavor("retail", function() end, "info")
        end)
        assert.has_error(function()
            ApiKit:RegisterFlavor("retail", function() end, { build = 1.5 })
        end)
        assert.has_error(function()
            ApiKit:RegisterFlavor("retail", function() end, { version = 12 })
        end)
        assert.has_error(function()
            ApiKit.RegisterFlavor({}, "retail", function() end)
        end)
    end)
end)
