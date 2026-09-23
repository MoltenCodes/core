local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

describe("SettingsKit scopes", function()
    local SettingsKit, S
    before_each(function()
        local _
        SettingsKit, _, _, _, S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local function valueSchema()
        return S.table({ fields = { value = S.optional(S.number(), 0) } })
    end

    local function openEveryScope()
        return SettingsKit:Open("MyAddonDB", {
            global = valueSchema(),
            char = valueSchema(),
            realm = valueSchema(),
            class = valueSchema(),
            faction = valueSchema(),
            profile = valueSchema(),
        })
    end

    it("keys each scope from the player identity read at Open", function()
        TestEnv.SetPlayer({
            name = "Yanki",
            realm = "Draenor",
            class = "WARLOCK",
            faction = "Horde",
        })
        local db = openEveryScope()

        db.global.value = 1
        db.char.value = 2
        db.realm.value = 3
        db.class.value = 4
        db.faction.value = 5
        db.profile.value = 6

        local raw = TestEnv.GetGlobal("MyAddonDB")
        assert.are.equal(1, raw.global.value)
        assert.are.equal(2, raw.char["Yanki - Draenor"].value)
        assert.are.equal(3, raw.realm.Draenor.value)
        assert.are.equal(4, raw.class.WARLOCK.value)
        assert.are.equal(5, raw.faction.Horde.value)
        assert.are.equal(6, raw.profiles.Default.value)
    end)

    it("resolves the keys once: a later identity change does not move the scopes", function()
        local db = openEveryScope()
        TestEnv.SetPlayer({
            name = "Other",
            realm = "Elsewhere",
            class = "ROGUE",
            faction = "Horde",
        })
        db.char.value = 1
        db.class.value = 1

        local raw = TestEnv.GetGlobal("MyAddonDB")
        assert.are.equal(1, raw.char["Tester - Silvermoon"].value)
        assert.are.equal(1, raw.class.MAGE.value)
    end)

    it("keeps other characters' entries apart", function()
        TestEnv.SavedVariable("MyAddonDB", { char = { ["Alt - Silvermoon"] = { value = 9 } } })
        local db = openEveryScope()
        assert.are.equal(0, db.char.value)
        db.char.value = 1
        assert.are.equal(9, TestEnv.GetGlobal("MyAddonDB").char["Alt - Silvermoon"].value)
    end)

    it(
        "makes a scope unavailable when its host function is missing, and says so at the reader's line",
        function()
            TestEnv.SetPlayer({ class = false, faction = false })
            local db = openEveryScope()

            assert.are.equal(0, db.char.value)
            local line = debug.getinfo(1, "l").currentline + 2
            local ok, message = pcall(function()
                return db.class
            end)
            assert.is_false(ok)
            assert.are.equal(
                SOURCE
                    .. ":"
                    .. line
                    .. ': SettingsKit (MyAddonDB) db.class is unavailable: UnitClass("player") returned no class when the database was opened',
                message
            )
            TestEnv.expectErrorContaining(
                'UnitFactionGroup("player") returned no faction',
                function()
                    return db.faction
                end
            )
        end
    )

    it("makes char unavailable without a realm name, and realm too", function()
        TestEnv.SetPlayer({ realm = false })
        local db = openEveryScope()
        TestEnv.expectErrorContaining("db.char is unavailable", function()
            return db.char
        end)
        TestEnv.expectErrorContaining(
            "db.realm is unavailable: GetRealmName() returned no realm",
            function()
                return db.realm
            end
        )
        assert.are.equal(0, db.class.value)
    end)

    it("treats an empty or secret identity as missing", function()
        TestEnv.InstallSecretProbe()
        local secret = TestEnv.NewSecret()
        TestEnv.SetPlayer({ name = "" })
        TestEnv.SetGlobal("UnitClass", function()
            return "Mage", secret
        end)
        local db = openEveryScope()
        TestEnv.expectErrorContaining("db.char is unavailable", function()
            return db.char
        end)
        TestEnv.expectErrorContaining("db.class is unavailable", function()
            return db.class
        end)
    end)

    it("raises for a scope the schema does not declare", function()
        local db = SettingsKit:Open("MyAddonDB", { profile = valueSchema() })
        TestEnv.expectErrorContaining(
            "SettingsKit (MyAddonDB) db.global is not declared; pass schema.global to SettingsKit:Open",
            function()
                return db.global
            end
        )
    end)

    it("refuses OnChange for an undeclared or unavailable scope", function()
        TestEnv.SetPlayer({ faction = false })
        local db =
            SettingsKit:Open("MyAddonDB", { profile = valueSchema(), faction = valueSchema() })
        TestEnv.expectErrorContaining("scope must name a declared, available scope", function()
            db:OnChange("faction", function() end)
        end)
        TestEnv.expectErrorContaining("scope must name a declared, available scope", function()
            db:OnChange("global", function() end)
        end)
    end)
end)
