local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit bootstrap", function()
    after_each(TestEnv.Reset)

    local function schemaFor(S)
        return { profile = S.table({ fields = { scale = S.optional(S.number({ max = 2 }), 1) } }) }
    end

    it("returns the same facade on duplicate embedded load and keeps databases", function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        local db = SettingsKit:Open("MyAddonDB", schemaFor(S))

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SettingsKit, reloaded)
        assert.are.equal(db, reloaded:Open("MyAddonDB"))
    end)

    it("publishes through Registry", function()
        local SettingsKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("settingsKit", 1)
        assert.are.equal(SettingsKit, registered)
        assert.are.equal(SettingsKit.REVISION, revision)
        assert.are.equal(64, SettingsKit.MAX_PROFILE_NAME_LENGTH)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local SettingsKit, Registry = TestEnv.NewPackage()
        local shippedRevision = SettingsKit.REVISION
        local upgraded, previous = Registry:Register("settingsKit", 1, 99)
        assert.are.equal(SettingsKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(SettingsKit, "REVISION", 99)
        rawset(SettingsKit, "_state", { schema = 999 })
        package.loaded["SettingsKit"] = nil

        local reloaded = require("SettingsKit")
        assert.are.equal(SettingsKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it(
        "upgrades in place and keeps databases, views, listeners and the logout compaction",
        function()
            local SettingsKit, _, _, _, S = TestEnv.NewPackage()
            local prototype = SettingsKit.Database
            local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
            local profile = db.profile
            local changes = 0
            db:OnChange("profile", function()
                changes = changes + 1
            end)
            local switched = 0
            db:OnProfileChanged(function()
                switched = switched + 1
            end)

            local upgraded = TestEnv.LoadRevision(2)
            assert.are.equal(SettingsKit, upgraded)
            assert.are.equal(2, upgraded.REVISION)
            assert.are.equal(prototype, upgraded.Database)
            assert.are.equal(db, upgraded:Open("MyAddonDB"))
            assert.are.equal(profile, db.profile)

            assert.are.equal(1, profile.scale)
            profile.scale = 1
            assert.are.equal(1, changes)
            TestEnv.expectErrorContaining("expected number <= 2", function()
                profile.scale = 3
            end)
            db:SetProfile("Other")
            assert.are.equal(1, switched)

            db:SetProfile("Default")
            TestEnv.Logout()
            assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
        end
    )

    it("loads without EventKit", function()
        local SettingsKit, Registry = TestEnv.NewPackageWithoutEventKit()
        assert.are.equal(SettingsKit, Registry:Get("settingsKit", 1))
        assert.are.equal("absent", select(2, Registry:Find("eventKit", 1)))
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "SettingsKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("requires SchemaKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("requires SchemaKit API 1", 1, true) ~= nil)
    end)

    it("requires SignalKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SchemaKit")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("requires SignalKit API 1", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        require("SchemaKit")
        Registry:Register("settingsKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes SettingsKit", 1, true) ~= nil)
    end)
end)
