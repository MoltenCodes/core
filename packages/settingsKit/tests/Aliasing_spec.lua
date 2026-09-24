local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit refuses values a saved variable cannot hold", function()
    local db
    before_each(function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        local Point = S.table({ fields = { x = S.optional(S.number(), 0) } })
        db = SettingsKit:Open("MyAddonDB", {
            profile = S.table({
                fields = {
                    a = S.optional(Point, {}),
                    b = S.optional(Point, {}),
                    data = S.optional(S.table({ fields = {}, open = true })),
                },
            }),
        })
    end)
    after_each(TestEnv.Reset)

    local function saved()
        return TestEnv.GetGlobal("MyAddonDB").profiles.Default
    end

    it("refuses a view assigned as a value, without a secret probe on the host", function()
        assert.is_nil(TestEnv.GetGlobal("issecretvalue"))
        db.profile.a.x = 1

        TestEnv.expectErrorContaining(
            "SettingsKit (MyAddonDB) profile.b refused a SettingsKit view: assign a plain table, not a table read through db.<scope>",
            function()
                db.profile.b = db.profile.a
            end
        )
        assert.is_nil(saved().b)

        -- The probe from the review: none of this may alias or bypass validation.
        TestEnv.expectErrorContaining("expected number, found string", function()
            db.profile.a.x = "str"
        end)
        db.profile.b.x = 9
        assert.are.equal(1, db.profile.a.x)
        assert.are.equal(9, db.profile.b.x)
        assert.are_not.equal(saved().a, saved().b)
        assert.is_nil(getmetatable(saved().a))
    end)

    it("refuses a view nested inside a table value", function()
        TestEnv.expectErrorContaining("profile.data refused a SettingsKit view", function()
            db.profile.data = { inner = { view = db.profile.a } }
        end)
        assert.is_nil(saved().data)
    end)

    it("refuses a table carrying a metatable, top level or nested", function()
        TestEnv.expectErrorContaining(
            "profile.data refused a table with a metatable: saved variables cannot hold metatables",
            function()
                db.profile.data = setmetatable({}, {})
            end
        )
        TestEnv.expectErrorContaining("profile.data refused a table with a metatable", function()
            db.profile.data = { inner = setmetatable({}, { __index = {} }) }
        end)
        assert.is_nil(saved().data)
    end)
end)

describe("SettingsKit keyed-section reads never store", function()
    local SettingsKit, S
    before_each(function()
        local _
        SettingsKit, _, _, _, S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local function entries(raw)
        local count = 0
        for _ in pairs(raw.profiles.Default.colors or {}) do
            count = count + 1
        end
        return count
    end

    it(
        "stores nothing for reads of missing entries with a plain-table wildcard, however many",
        function()
            local db = SettingsKit:Open("MyAddonDB", {
                profile = S.table({
                    fields = {
                        colors = S.optional(
                            S.map({
                                keys = S.number({ integer = true, min = 1 }),
                                values = S.optional(
                                    S.array({ of = S.number(), max = 4 }),
                                    { 1, 1, 1 }
                                ),
                                max = 3,
                            }),
                            {}
                        ),
                    },
                }),
            })

            for spellId = 1, 12 do
                assert.are.same({ 1, 1, 1 }, db.profile.colors[spellId])
            end
            -- A key the key schema refuses reads the default and stores nothing.
            assert.are.same({ 1, 1, 1 }, db.profile.colors["not a number"])
            assert.are.equal(0, entries(TestEnv.GetGlobal("MyAddonDB")))

            -- Only a validated write creates an entry.
            db.profile.colors[1] = { 0, 0, 0 }
            assert.are.equal(1, entries(TestEnv.GetGlobal("MyAddonDB")))
        end
    )

    it(
        "stores nothing when a plain-table default is read inside an entry that is not saved",
        function()
            local db = SettingsKit:Open("MyAddonDB", {
                profile = S.table({
                    fields = {
                        auras = S.optional(
                            S.map({
                                keys = S.number(),
                                values = S.optional(
                                    S.table({
                                        fields = {
                                            color = S.optional(
                                                S.array({ of = S.number(), max = 4 }),
                                                { 1, 1, 1 }
                                            ),
                                        },
                                    }),
                                    {}
                                ),
                                max = 3,
                            }),
                            {}
                        ),
                    },
                }),
            })

            for spellId = 1, 12 do
                assert.are.same({ 1, 1, 1 }, db.profile.auras[spellId].color)
            end
            assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras)

            -- Inside a saved entry the first read stores its copy, as elsewhere.
            db.profile.auras[1] = {}
            db.profile.auras[1].color[1] = 0
            assert.are.same(
                { 0, 1, 1 },
                TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras[1].color
            )
        end
    )
end)

describe("SettingsKit db:Pairs", function()
    local SettingsKit, S
    before_each(function()
        local _
        SettingsKit, _, _, _, S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local function collect(db, view)
        local seen = {}
        for key, value in db:Pairs(view) do
            seen[key] = value
        end
        return seen
    end

    it(
        "iterates keys with defaults, then saved keys without one, with the values a read gives",
        function()
            TestEnv.SavedVariable(
                "MyAddonDB",
                { profiles = { Default = { legacy = "kept", scale = 2 } } }
            )
            local db = SettingsKit:Open("MyAddonDB", {
                profile = S.table({
                    fields = {
                        scale = S.optional(S.number(), 1),
                        anchor = S.optional(S.string(), "CENTER"),
                        label = S.optional(S.string()),
                        frame = S.optional(
                            S.table({ fields = { x = S.optional(S.number(), 0) } }),
                            {}
                        ),
                    },
                    open = true,
                }),
            })
            db.profile.label = "hi"

            local seen = collect(db, db.profile)
            assert.are.equal(2, seen.scale)
            assert.are.equal("CENTER", seen.anchor)
            assert.are.equal("hi", seen.label)
            assert.are.equal("kept", seen.legacy)
            assert.are.equal(db.profile.frame, seen.frame)
            local count = 0
            for _ in pairs(seen) do
                count = count + 1
            end
            assert.are.equal(5, count)
        end
    )

    it("iterates a keyed section's saved and default entries, never its wildcard", function()
        local db = SettingsKit:Open("MyAddonDB", {
            profile = S.table({
                fields = {
                    counts = S.optional(
                        S.map({ keys = S.string(), values = S.optional(S.number(), 0), max = 8 }),
                        { preset = 5 }
                    ),
                },
            }),
        })
        db.profile.counts.fireball = 3
        assert.are.same({ preset = 5, fireball = 3 }, collect(db, db.profile.counts))
    end)

    it("iterates without allocating #allocation", function()
        local db = SettingsKit:Open("MyAddonDB", {
            profile = S.table({
                fields = { a = S.optional(S.number(), 1), b = S.optional(S.number(), 2) },
            }),
        })
        db.profile.a = 3
        local view = db.profile
        local total = 0
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 1000 do
                for _, value in db:Pairs(view) do
                    total = total + value
                end
            end
        end)
        assert.is_true(allocated < 1, "Pairs allocated " .. allocated .. " KiB")
        assert.are.equal(5000, total)
    end)

    it("refuses anything but a view of this database", function()
        local db = SettingsKit:Open("MyAddonDB", { profile = S.table({ fields = {} }) })
        local other = SettingsKit:Open("OtherDB", { profile = S.table({ fields = {} }) })
        TestEnv.expectErrorContaining(
            "SettingsKit.Database:Pairs view must be a view of this database",
            function()
                db:Pairs({})
            end
        )
        TestEnv.expectErrorContaining(
            "SettingsKit.Database:Pairs view must be a view of this database",
            function()
                db:Pairs(other.profile)
            end
        )
    end)
end)

describe("SettingsKit record reads and Compact", function()
    after_each(TestEnv.Reset)

    it("refuses to read a record view with a secret key", function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        TestEnv.InstallSecretProbe()
        local db = SettingsKit:Open("MyAddonDB", { profile = S.table({ fields = {} }) })
        TestEnv.expectErrorContaining(
            "SettingsKit (MyAddonDB) profile cannot be read with a secret key",
            function()
                local _ = db.profile[TestEnv.NewSecret()]
            end
        )
    end)

    it("keeps undeclared keys through Compact", function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { legacy = 1, scale = 1 } } })
        local db = SettingsKit:Open("MyAddonDB", {
            profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
        })
        db:Compact()
        assert.are.same({ legacy = 1 }, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
    end)
end)
