local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit:Open", function()
    local SettingsKit, S
    before_each(function()
        local _
        SettingsKit, _, _, _, S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local function schema()
        return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
    end

    it("creates a missing saved variable with the full layout", function()
        SettingsKit:Open("MyAddonDB", schema())
        local raw = TestEnv.GetGlobal("MyAddonDB")
        assert.are.same({
            global = {},
            profiles = { Default = {} },
            profileKeys = {},
            char = {},
            realm = {},
            class = {},
            faction = {},
            namespaces = {},
        }, raw)
    end)

    it("adopts the saved variable the client loaded", function()
        local loaded = { profiles = { Default = { scale = 1.5 } } }
        TestEnv.SavedVariable("MyAddonDB", loaded)
        local db = SettingsKit:Open("MyAddonDB", schema())
        assert.are.equal(loaded, TestEnv.GetGlobal("MyAddonDB"))
        assert.are.equal(1.5, db.profile.scale)
        assert.are.equal("MyAddonDB", db:GetSavedVariable())
    end)

    it("returns the same database when the same name is opened again", function()
        local definition = schema()
        local db = SettingsKit:Open("MyAddonDB", definition)
        assert.are.equal(db, SettingsKit:Open("MyAddonDB", definition))
        assert.are.equal(db, SettingsKit:Open("MyAddonDB"))
        TestEnv.expectErrorContaining(
            "MyAddonDB is already open with a different schema table",
            function()
                SettingsKit:Open("MyAddonDB", schema())
            end
        )
    end)

    it("notices a saved variable replaced after it was opened", function()
        SettingsKit:Open("MyAddonDB", schema())
        TestEnv.SavedVariable("MyAddonDB", {})
        TestEnv.expectErrorContaining("MyAddonDB was replaced after it was opened", function()
            SettingsKit:Open("MyAddonDB")
        end)
    end)

    it("accepts a node or a sealed schema, sealing its own copy", function()
        local sealed = S:Seal(S.table({ fields = { a = S.optional(S.number(), 2) } }))
        local db = SettingsKit:Open("MyAddonDB", { global = sealed })
        assert.are.equal(2, db.global.a)

        -- A consumer's own failure table is never overwritten by a write.
        local _, failure = sealed:Check({ a = "x" })
        local path = failure.path
        pcall(function()
            db.global.a = "y"
        end)
        assert.are.equal(path, failure.path)
    end)

    it("refuses a saved variable that is not a table", function()
        TestEnv.SavedVariable("MyAddonDB", "oops")
        TestEnv.expectErrorContaining(
            "SettingsKit:Open MyAddonDB must be a table or nil",
            function()
                SettingsKit:Open("MyAddonDB", schema())
            end
        )
    end)

    it("refuses a section that is not a table", function()
        TestEnv.SavedVariable("MyAddonDB", { profiles = 3 })
        TestEnv.expectErrorContaining(
            "SettingsKit:Open MyAddonDB.profiles must be a table",
            function()
                SettingsKit:Open("MyAddonDB", schema())
            end
        )
    end)

    it("refuses a schema field that is not optional, naming its path", function()
        TestEnv.expectErrorContaining(
            "SettingsKit:Open schema.profile.frame.x must be optional: a saved variable starts empty",
            function()
                SettingsKit:Open("MyAddonDB", {
                    profile = S.table({
                        fields = { frame = S.optional(S.table({ fields = { x = S.number() } })) },
                    }),
                })
            end
        )
        assert.is_nil(TestEnv.GetGlobal("MyAddonDB"))
    end)

    it("refuses required fields inside the records of a keyed section", function()
        TestEnv.expectErrorContaining("schema.profile.auras[*].id must be optional", function()
            SettingsKit:Open("MyAddonDB", {
                profile = S.table({
                    fields = {
                        auras = S.optional(S.map({
                            keys = S.string(),
                            values = S.table({ fields = { id = S.number() } }),
                            max = 4,
                        })),
                    },
                }),
            })
        end)
    end)

    it("refuses a scope schema that is not a table schema", function()
        TestEnv.expectErrorContaining(
            "SettingsKit:Open schema.global must be a SchemaKit.table schema",
            function()
                SettingsKit:Open("MyAddonDB", { global = S.number() })
            end
        )
    end)

    it("refuses malformed schema tables", function()
        TestEnv.expectErrorContaining("schema must be a table of scope schemas", function()
            SettingsKit:Open("MyAddonDB", nil)
        end)
        TestEnv.expectErrorContaining('schema contains unknown scope "account"', function()
            SettingsKit:Open("MyAddonDB", { account = S.table({ fields = {} }) })
        end)
        TestEnv.expectErrorContaining(
            "schema.profile must be a SchemaKit schema node or sealed schema",
            function()
                SettingsKit:Open("MyAddonDB", { profile = {} })
            end
        )
        TestEnv.expectErrorContaining("schema must declare at least one scope", function()
            SettingsKit:Open("MyAddonDB", {})
        end)
    end)

    it("refuses malformed options", function()
        TestEnv.expectErrorContaining("options must be a table", function()
            SettingsKit:Open("MyAddonDB", schema(), 3)
        end)
        TestEnv.expectErrorContaining('options contains unknown field "profile"', function()
            SettingsKit:Open("MyAddonDB", schema(), { profile = "x" })
        end)
        TestEnv.expectErrorContaining("options.version must be a positive integer", function()
            SettingsKit:Open("MyAddonDB", schema(), { version = 1.5 })
        end)
        TestEnv.expectErrorContaining("options.migrations requires options.version", function()
            SettingsKit:Open("MyAddonDB", schema(), { migrations = {} })
        end)
        TestEnv.expectErrorContaining(
            "options.migrations keys must be integers from 1 to options.version",
            function()
                SettingsKit:Open(
                    "MyAddonDB",
                    schema(),
                    { version = 2, migrations = { [3] = function() end } }
                )
            end
        )
        TestEnv.expectErrorContaining("options.migrations[1] must be a function", function()
            SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = { [1] = true } })
        end)
        TestEnv.expectErrorContaining(
            "options.defaultProfile must be a non-empty string",
            function()
                SettingsKit:Open("MyAddonDB", schema(), { defaultProfile = false })
            end
        )
    end)

    it("refuses a saved-variable name that is not an identifier", function()
        TestEnv.expectErrorContaining(
            "savedVariable must be the name of a saved variable",
            function()
                SettingsKit:Open("My Addon", schema())
            end
        )
        TestEnv.expectErrorContaining(
            "savedVariable must be the name of a saved variable",
            function()
                SettingsKit:Open(nil, schema())
            end
        )
    end)
end)
