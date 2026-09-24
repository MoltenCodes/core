local TestEnv = require("MediaKitTestEnv")

describe("MediaKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load and keeps entries", function()
        local MediaKit = TestEnv.NewPackage()
        MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(MediaKit, reloaded)
        assert.are.equal("Interface\\Pack\\Bar", reloaded:Fetch("statusbar", "Pack Bar"))
        assert.are.same({ "Blizzard", "Pack Bar", "Solid" }, reloaded:List("statusbar"))
    end)

    it("publishes through Registry", function()
        local MediaKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("mediaKit", 1)
        assert.are.equal(MediaKit, registered)
        assert.are.equal(MediaKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local MediaKit, Registry = TestEnv.NewPackage()
        local shippedRevision = MediaKit.REVISION
        local upgraded, previous = Registry:Register("mediaKit", 1, 99)
        assert.are.equal(MediaKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(MediaKit, "REVISION", 99)
        rawset(MediaKit, "_state", { schema = 999 })
        package.loaded["MediaKit"] = nil

        local reloaded = require("MediaKit")
        assert.are.equal(MediaKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it(
        "upgrades in place and keeps entries, lists, connections, defaults and LibSharedMedia links",
        function()
            local MediaKit = TestEnv.NewPackage("enUS")
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
            MediaKit:Register("font", "Latin", "Fonts\\Latin.ttf", { scripts = { "latin" } })
            local list = MediaKit:List("statusbar")
            local seen = {}
            local connection = MediaKit:OnRegistered("statusbar", function(_, name)
                seen[#seen + 1] = name
            end)
            local defaults = MediaKit:Defaults("MyAddon")
            defaults:Set("statusbar", "Pack Bar")
            MediaKit:AdoptLibSharedMedia()
            MediaKit:MirrorToLibSharedMedia()
            local nextRevision = MediaKit.REVISION + 1

            local upgraded = TestEnv.LoadRevision(nextRevision)
            assert.are.equal(MediaKit, upgraded)
            assert.are.equal(nextRevision, upgraded.REVISION)

            -- Entries, the cached list and the built-ins are the same.
            assert.are.equal("Interface\\Pack\\Bar", upgraded:Fetch("statusbar", "Pack Bar"))
            assert.are.equal(list, upgraded:List("statusbar"))
            assert.are.equal("Fonts\\Latin.ttf", upgraded:Fetch("font", "Latin"))

            -- The defaults object is the same one and runs the new methods.
            assert.are.equal(defaults, upgraded:Defaults("MyAddon"))
            assert.are.equal("Pack Bar", defaults:Get("statusbar"))

            -- The connection an older copy handed out still fires.
            upgraded:Register("statusbar", "After Upgrade", "Interface\\Pack\\After")
            assert.are.same({ "After Upgrade" }, seen)
            assert.is_true(connection:IsConnected())

            -- Mirroring and the callback LibSharedMedia already holds keep working
            -- without a second subscription or an echo.
            assert.are.equal("Interface\\Pack\\After", library:Fetch("statusbar", "After Upgrade"))
            library:Register("statusbar", "From Pack", "Interface\\Pack\\From")
            assert.are.equal("Interface\\Pack\\From", upgraded:Fetch("statusbar", "From Pack"))
            assert.are.same({ "After Upgrade", "From Pack" }, seen)
            assert.are.equal(1, library.CallbackCount())
            assert.are.same({ true, 0 }, { upgraded:AdoptLibSharedMedia() })

            -- The built-ins were not registered a second time.
            assert.are.same(
                { "Arial Narrow", "Friz Quadrata TT", "Latin", "Morpheus", "Skurri" },
                upgraded:List("font", { anyScript = true })
            )
        end
    )

    it("upgrades in place and keeps the set limits and the UNBOUNDED sentinel", function()
        local MediaKit = TestEnv.NewPackage()
        local unbounded = MediaKit.UNBOUNDED
        MediaKit:SetLimits({ maxEntriesPerType = 4096, maxConsumers = unbounded })

        local upgraded = TestEnv.LoadRevision(MediaKit.REVISION + 1)
        assert.are.equal(unbounded, upgraded.UNBOUNDED)
        assert.are.same(
            { maxEntriesPerType = 4096, maxConsumers = unbounded },
            upgraded:GetLimits()
        )
        assert.are.equal(unbounded, upgraded:GetLimits().maxConsumers)
    end)

    it("upgrades revision 1 in place and keeps its entries, defaults and limits", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        TestEnv.SetClientLocale(TestEnv.DEFAULT_CLIENT_LOCALE)
        require("Registry")
        require("SignalKit")
        local old = TestEnv.LoadRevision(1)
        old:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
        local defaults = old:Defaults("MyAddon")
        defaults:Set("statusbar", "Pack Bar")
        old:SetLimits({ maxConsumers = old.UNBOUNDED })

        local upgraded = require("MediaKit")
        assert.are.equal(old, upgraded)
        assert.is_true(upgraded.REVISION > 1)
        assert.are.equal("Interface\\Pack\\Bar", upgraded:Fetch("statusbar", "Pack Bar"))
        assert.are.equal(defaults, upgraded:Defaults("MyAddon"))
        assert.are.equal("Pack Bar", defaults:Get("statusbar"))
        assert.are.equal(old.UNBOUNDED, upgraded:GetLimits().maxConsumers)
        -- The built-ins were registered once, by revision 1.
        assert.are.same({ "Blizzard", "Pack Bar", "Solid" }, upgraded:List("statusbar"))
        -- The corrected limit-key message runs for the carried state at once.
        local ok, message = pcall(upgraded.SetLimits, upgraded, { [{}] = 1 })
        assert.is_false(ok)
        assert.is_truthy(
            tostring(message):find(
                "MediaKit:SetLimits limits.<table> is not a recognised limit",
                1,
                true
            )
        )
    end)

    it("refuses shared state whose limits hold an invalid value", function()
        local MediaKit = TestEnv.NewPackage()
        rawset(MediaKit._state.limits, "maxEntriesPerType", MediaKit.UNBOUNDED)
        TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
            TestEnv.ReloadPackage()
        end)
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "MediaKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("requires SignalKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "MediaKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("SignalKit API 1", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        Registry:Register("mediaKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "MediaKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes MediaKit", 1, true) ~= nil)
    end)
end)
