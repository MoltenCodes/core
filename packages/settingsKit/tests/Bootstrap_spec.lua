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

            local nextRevision = SettingsKit.REVISION + 1
            local upgraded = TestEnv.LoadRevision(nextRevision)
            assert.are.equal(SettingsKit, upgraded)
            assert.are.equal(nextRevision, upgraded.REVISION)
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

    it("repairs the defaults revision 1 gave entry views of a section without a default", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        local S = require("SchemaKit")
        local previous = TestEnv.LoadRevision(1)
        TestEnv.SetPlayer()
        assert.are.equal(1, previous.REVISION)

        TestEnv.SavedVariable("MyAddonDB", {
            profiles = { Default = { auras = { [5] = { glow = {} } } } },
        })
        local db = previous:Open("MyAddonDB", {
            profile = S.table({
                fields = {
                    auras = S.optional(S.map({
                        keys = S.number(),
                        max = 8,
                        values = S.optional(
                            S.table({
                                fields = {
                                    shown = S.optional(S.boolean(), true),
                                    glow = S.optional(
                                        S.table({ fields = { alpha = S.optional(S.number(), 0.5) } })
                                    ),
                                },
                            }),
                            { shown = true }
                        ),
                    })),
                },
            }),
        })
        local entry = db.profile.auras[5]
        local glow = entry.glow

        -- Leave the two nodes as revision 1 built them: `false` handed down
        -- from the section, which was declared without a default.
        local views = rawget(previous, "_state").views
        rawget(views, entry).defaults = false
        rawget(views, glow).defaults = false
        assert.is_nil(entry.shown)
        assert.is_nil(glow.alpha)

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.is_true(upgraded.REVISION > 1)
        assert.are.equal(entry, db.profile.auras[5])
        assert.are.equal(true, entry.shown)
        assert.are.equal(0.5, glow.alpha)
    end)

    it("upgrades revision 2 in place and applies the secret refusals at once", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        local S = require("SchemaKit")
        local previous = TestEnv.LoadRevision(2)
        TestEnv.SetPlayer()
        assert.are.equal(2, previous.REVISION)
        local state = rawget(previous, "_state")
        local prototype = previous.Database
        local unbounded = previous.UNBOUNDED
        previous:SetLimits({ pathKeyLimit = 48 })
        local db = previous:Open("MyAddonDB", schemaFor(S))
        local profile = db.profile
        local changes = 0
        db:OnChange("profile", function()
            changes = changes + 1
        end)

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.is_true(upgraded.REVISION > 2)
        assert.are.equal(state, rawget(upgraded, "_state"))
        assert.are.equal(upgraded.REVISION, state.runtimeRevision)
        assert.are.equal(prototype, upgraded.Database)
        assert.are.equal(unbounded, upgraded.UNBOUNDED)
        assert.are.equal(48, upgraded:GetLimits().pathKeyLimit)
        assert.are.equal(db, upgraded:Open("MyAddonDB"))
        assert.are.equal(profile, db.profile)
        profile.scale = 2
        assert.are.equal(1, changes)
        assert.are.equal(2, profile.scale)

        TestEnv.InstallSecretProbe()
        TestEnv.expectErrorContaining(
            "SettingsKit:SetLimits limits.pathKeyLimit must not be a secret value",
            function()
                upgraded:SetLimits({ pathKeyLimit = TestEnv.NewSecret() })
            end
        )
    end)

    it("upgrades revision 3 in place and refuses secret scope names and keys at once", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        local S = require("SchemaKit")
        local previous = TestEnv.LoadRevision(3)
        TestEnv.SetPlayer()
        assert.are.equal(3, previous.REVISION)
        local state = rawget(previous, "_state")
        local db = previous:Open("MyAddonDB", schemaFor(S))
        local profile = db.profile
        local changes = 0
        db:OnChange("profile", function()
            changes = changes + 1
        end)
        -- Revision 3 indexed the prototype with any key; its `__index` stays
        -- on the shared metatable until the newer copy replaces it.
        local metatable = getmetatable(db)
        local function legacyIndex() end
        rawset(metatable, "__index", legacyIndex)

        local upgraded = TestEnv.ReloadPackage()
        assert.are.equal(previous, upgraded)
        assert.are.equal(4, upgraded.REVISION)
        assert.are.equal(state, rawget(upgraded, "_state"))
        assert.are.equal(db, upgraded:Open("MyAddonDB"))
        assert.are.equal(profile, db.profile)
        assert.are_not.equal(legacyIndex, rawget(metatable, "__index"))
        profile.scale = 2
        assert.are.equal(1, changes)

        TestEnv.InstallSecretProbe()
        local secret = TestEnv.NewSecret()
        TestEnv.expectErrorContaining(
            "SettingsKit.Database:OnChange scope must not be a secret value",
            function()
                db:OnChange(secret, function() end)
            end
        )
        TestEnv.expectErrorContaining(
            "SettingsKit databases cannot be read with a secret key",
            function()
                return db[secret]
            end
        )
    end)

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
