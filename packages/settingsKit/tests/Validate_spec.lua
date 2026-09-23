local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit db:Validate", function()
    local db
    before_each(function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        db = SettingsKit:Open("MyAddonDB", {
            global = S.table({ fields = { seen = S.optional(S.number(), 0) } }),
            profile = S.table({
                fields = {
                    scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
                    frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
                    data = S.optional(S.table({ fields = {}, open = true })),
                    auras = S.optional(
                        S.map({
                            keys = S.number({ integer = true, min = 1 }),
                            values = S.optional(
                                S.table({ fields = { shown = S.optional(S.boolean(), true) } }),
                                {}
                            ),
                            max = 2,
                        }),
                        {}
                    ),
                },
            }),
        })
    end)
    after_each(TestEnv.Reset)

    local function saved()
        return TestEnv.GetGlobal("MyAddonDB")
    end

    ---The message a write raises, without its `file:line: ` prefix.
    local function writeRefusal(write)
        local ok, message = pcall(write)
        assert.is_false(ok)
        return (tostring(message):gsub("^[^:]+:%d+: ", ""))
    end

    it("accepts what a write accepts and writes nothing", function()
        local calls = 0
        db:OnChange("profile", function()
            calls = calls + 1
        end)

        assert.are.same({ true }, { db:Validate("profile", "scale", 1.5) })
        assert.are.same({ true }, { db:Validate("profile", { "frame", "x" }, 3) })
        assert.are.same({ true }, { db:Validate("profile", "auras.7.shown", false) })
        assert.are.same({ true }, { db:Validate("profile", { "auras", 7 }, { shown = false }) })
        assert.are.same({ true }, { db:Validate("global", "seen", 2) })
        assert.are.same({}, saved().profiles.Default)
        assert.are.same({}, saved().global)
        assert.are.equal(0, calls)
    end)

    it("refuses with exactly the text a refused write raises", function()
        local cases = {
            {
                { "profile", "scale", 5 },
                function()
                    db.profile.scale = 5
                end,
            },
            {
                { "profile", { "frame", "x" }, "wide" },
                function()
                    db.profile.frame.x = "wide"
                end,
            },
            {
                { "profile", "typo", 1 },
                function()
                    db.profile.typo = 1
                end,
            },
            {
                { "profile", "auras.0", {} },
                function()
                    db.profile.auras[0] = {}
                end,
            },
            {
                { "profile", "data", db.profile.frame },
                function()
                    db.profile.data = db.profile.frame
                end,
            },
            {
                { "profile", "data", setmetatable({}, {}) },
                function()
                    db.profile.data = setmetatable({}, {})
                end,
            },
        }
        for _, case in ipairs(cases) do
            local ok, message = db:Validate(case[1][1], case[1][2], case[1][3])
            assert.is_false(ok)
            assert.are.equal(writeRefusal(case[2]), message)
        end
    end)

    it("checks a keyed section's max without creating the entry", function()
        db.profile.auras[1] = {}
        db.profile.auras[2] = {}
        local ok, message = db:Validate("profile", { "auras", 3, "shown" }, false)
        assert.is_false(ok)
        assert.are.equal(
            "SettingsKit (MyAddonDB) profile.auras: expected at most 2 entries",
            message
        )
        assert.is_true((db:Validate("profile", { "auras", 2, "shown" }, false)))
        assert.is_nil(saved().profiles.Default.auras[3])
    end)

    it("refuses secret values and keys like a write", function()
        TestEnv.InstallSecretProbe()
        local secret = TestEnv.NewSecret()
        local ok, message = db:Validate("profile", "data", { value = secret })
        assert.is_false(ok)
        assert.are.equal(
            "SettingsKit (MyAddonDB) profile.data refused a secret value: saved variables never hold secret values",
            message
        )
        ok, message = db:Validate("profile", { "auras", secret }, {})
        assert.is_false(ok)
        assert.are.equal(
            "SettingsKit (MyAddonDB) profile.auras refused a secret key: saved variables never hold secret values",
            message
        )
    end)

    it("reports a path through something that is not a record or keyed section", function()
        local ok, message = db:Validate("profile", "scale.x", 1)
        assert.is_false(ok)
        assert.are.equal(
            "SettingsKit (MyAddonDB) profile.scale is not a record or keyed section",
            message
        )
        ok, message = db:Validate("profile", { "frame", 0 / 0 }, 1)
        assert.is_false(ok)
        assert.are.equal(
            "SettingsKit (MyAddonDB) profile.frame key must not be nil or NaN",
            message
        )
    end)

    it("validates against the current profile", function()
        db:SetProfile("Other")
        assert.is_true((db:Validate("profile", "scale", 2)))
        assert.are.same({}, saved().profiles.Other)
    end)

    it("allocates nothing for a valid check with an array path", function()
        local topLevel = { "scale" }
        local nested = { "frame", "x" }
        local entry = { "auras", 7, "shown" }
        -- Entry views are cached while referenced; hold this one so the full
        -- collection the measurement starts with cannot drop it.
        local held = db.profile.auras[7]
        db:Validate("profile", entry, true)
        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, 2000 do
                db:Validate("profile", topLevel, 1 + (index % 2) / 2)
                db:Validate("profile", nested, index)
                db:Validate("profile", entry, index % 2 == 0)
            end
        end)
        assert.is_true(allocated < 1, "Validate allocated " .. allocated .. " KiB")
        assert.is_true(held.shown)
    end)

    it("refuses malformed arguments at the caller", function()
        TestEnv.expectErrorContaining(
            "SettingsKit.Database:Validate scope must name a declared, available scope",
            function()
                db:Validate("char", "x", 1)
            end
        )
        TestEnv.expectErrorContaining(
            "path must be a dotted string or a non-empty array of keys",
            function()
                db:Validate("profile", {}, 1)
            end
        )
        TestEnv.expectErrorContaining(
            "path must be a dotted string or a non-empty array of keys",
            function()
                db:Validate("profile", 3, 1)
            end
        )
        TestEnv.expectErrorContaining("path must not contain an empty segment", function()
            db:Validate("profile", "frame..x", 1)
        end)
    end)
end)
