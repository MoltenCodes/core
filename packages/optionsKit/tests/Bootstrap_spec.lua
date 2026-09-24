local TestEnv = require("OptionsKitTestEnv")

-- The saved variable the revision 2 upgrade spec opens with the real
-- SettingsKit, an optional dependency the runner puts on `LUA_PATH`.
local PROFILE_SAVED_VARIABLE = "OptionsKitBootstrapDB"

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
    after_each(function()
        package.loaded["SettingsKit"] = nil
        -- selene: allow(global_usage)
        rawset(_G, PROFILE_SAVED_VARIABLE, nil)
        TestEnv.Reset()
    end)

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

        local nextRevision = OptionsKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(OptionsKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(tree, upgraded:Get("Addon"))

        -- The tree built by the older copy is served by the newer copy's methods.
        assert.are.equal(upgraded.Tree.Set, tree.Set)
        assert.is_true(tree:Set("enabled", true))
        assert.is_true(store.enabled)
        assert.are.equal(1, changes)
        assert.is_true(connection:IsConnected())
        assert.are.equal(1, tree:Walk(function() end))
    end)

    it("upgrades a revision 1 layout: the profile group map and each tree's link list", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("SchemaKit")
        local OptionsKit = TestEnv.LoadRevision(1)
        local tree = OptionsKit:Define("Addon", toggleTree({}))
        local state = rawget(OptionsKit, "_state")
        -- Strip what revision 1 never had.
        rawset(state, "profileGroups", nil)
        rawset(tree, "_profileLinks", nil)
        rawset(tree, "_schema", 1)

        -- The shipped file, at its own revision, loads over revision 1.
        local upgraded = require("OptionsKit")
        assert.are.equal(OptionsKit, upgraded)
        assert.is_true(upgraded.REVISION > 1)
        local groups = rawget(state, "profileGroups")
        assert.are.equal("table", type(groups))
        assert.are.equal("k", getmetatable(groups).__mode)
        assert.are.equal(2, rawget(tree, "_schema"))
        assert.are.same({}, rawget(tree, "_profileLinks"))
        assert.is_true(upgraded:Undefine("Addon"))
    end)

    it("upgrades a revision 2 state in place and keeps its profile groups attached", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("SchemaKit")
        local OptionsKit = TestEnv.LoadRevision(2)
        local SettingsKit = require("SettingsKit")
        local S = require("SchemaKit")
        local db = SettingsKit:Open(PROFILE_SAVED_VARIABLE, {
            profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
        })
        local group = OptionsKit:ProfileOptions(db)
        local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = group } })

        local upgraded = require("OptionsKit")
        assert.are.equal(OptionsKit, upgraded)
        assert.is_true(upgraded.REVISION > 2)
        assert.are.equal(tree, upgraded:Get("Addon"))
        assert.are.equal(2, rawget(tree, "_schema"))

        -- The link made under revision 2 still reaches the tree.
        local changes = {}
        tree:OnChange(function(_, path, value)
            changes[#changes + 1] = { path, value }
        end)
        db:SetProfile("Raid")
        assert.are.same({ { "profiles.current", "Raid" } }, changes)

        -- Undefine under the new revision frees the group for another tree.
        assert.is_true(upgraded:Undefine("Addon"))
        local again = upgraded:Define("Again", { type = "group", args = { profiles = group } })
        assert.are.equal("Raid", again:Get("profiles.current"))
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
