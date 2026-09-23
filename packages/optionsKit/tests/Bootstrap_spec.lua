local TestEnv = require("OptionsKitTestEnv")

---A tree with one toggle over `store.enabled`.
local function toggleTree(store)
    return {
        type = "group",
        args = {
            enabled = {
                type = "toggle",
                name = "Enabled",
                get = function()
                    return store.enabled
                end,
                set = function(_, value)
                    store.enabled = value
                end,
            },
        },
    }
end

describe("OptionsKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade and keeps trees on duplicate embedded load", function()
        local OptionsKit = TestEnv.NewPackage()
        local tree = OptionsKit:Define("Addon", toggleTree({}))

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(OptionsKit, reloaded)
        assert.are.equal(tree, reloaded:Get("Addon"))
    end)

    it("publishes through Registry", function()
        local OptionsKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("optionsKit", 1)
        assert.are.equal(OptionsKit, registered)
        assert.are.equal(OptionsKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local OptionsKit, Registry = TestEnv.NewPackage()
        local shippedRevision = OptionsKit.REVISION
        local upgraded, previous = Registry:Register("optionsKit", 1, 99)
        assert.are.equal(OptionsKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(OptionsKit, "REVISION", 99)
        rawset(OptionsKit, "_state", { schema = 999 })
        package.loaded["OptionsKit"] = nil

        local reloaded = require("OptionsKit")
        assert.are.equal(OptionsKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps every tree and listener", function()
        local OptionsKit = TestEnv.NewPackage()
        local store = { enabled = false }
        local tree = OptionsKit:Define("Addon", toggleTree(store))
        local changes = 0
        local connection = tree:OnChange(function()
            changes = changes + 1
        end)

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(OptionsKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)
        assert.are.equal(tree, upgraded:Get("Addon"))

        -- The tree built by revision 1 is served by revision 2's methods.
        assert.are.equal(upgraded.Tree.Set, tree.Set)
        assert.is_true(tree:Set("enabled", true))
        assert.is_true(store.enabled)
        assert.are.equal(1, changes)
        assert.is_true(connection:IsConnected())
        assert.are.equal(1, tree:Walk(function() end))
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "OptionsKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires Registry API 2", 1, true))
    end)

    it("requires SchemaKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires SchemaKit API 1", 1, true))
    end)

    it("requires SignalKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SchemaKit")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("requires SignalKit API 1", 1, true))
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("SchemaKit")
        Registry:Register("optionsKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("MoltenCodes OptionsKit", 1, true))
    end)
end)
