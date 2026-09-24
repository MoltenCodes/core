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
        local listed = {}
        for index = 1, 5 do
            listed[index] = ApiKit.SUPPORTED_FLAVORS[index]
        end
        assert.are.same({ "retail", "classic-era", "classic-mop", "ptr", "beta" }, listed)
        assert.is_nil(ApiKit.SUPPORTED_FLAVORS[6])
        assert.has_error(function()
            ApiKit.SUPPORTED_FLAVORS[6] = "wrath"
        end, 'ApiKit.SUPPORTED_FLAVORS is read-only; index "6" cannot be written')
    end)

    it("rejects corrupted inherited state", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        rawset(ApiKit, "_state", { schema = 1 })
        package.loaded["ApiKit"] = nil
        TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
            TestEnv.requireAfterFailedLoad("ApiKit")
        end)
    end)
end)
