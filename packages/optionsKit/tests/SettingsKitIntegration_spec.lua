local TestEnv = require("OptionsKitTestEnv")

-- SettingsKit is an optional dependency. When its package is on `LUA_PATH`
-- (the runner puts it there once it exists), this spec binds a tree to a real
-- database; until then it is pending, and `Bind_spec.lua` covers binding
-- against a stand-in with the documented database shape.

---Whether `moduleName` is on `package.path`, without loading it: SettingsKit
---needs Registry loaded first, so a trial `require` would fail either way.
---@param moduleName string
---@return boolean
local function isOnPath(moduleName)
    for template in package.path:gmatch("[^;]+") do
        local file = io.open((template:gsub("%?", moduleName)), "r")
        if file ~= nil then
            file:close()
            return true
        end
    end
    return false
end

local SAVED_VARIABLE = "OptionsKitIntegrationDB"
local settingsKitAvailable = isOnPath("SettingsKit")

describe("OptionsKit with the real SettingsKit", function()
    after_each(function()
        package.loaded["SettingsKit"] = nil
        -- SettingsKit creates the saved-variable global; the fixture does not own it.
        -- selene: allow(global_usage)
        rawset(_G, SAVED_VARIABLE, nil)
        TestEnv.Reset()
    end)

    if not settingsKitAvailable then
        pending("binds to a real SettingsKit database (SettingsKit has not landed yet)")
        return
    end

    it("binds to a real SettingsKit database, sets and resets a value", function()
        local OptionsKit = TestEnv.NewPackage()
        local SettingsKit = require("SettingsKit")
        local SchemaKit = require("SchemaKit")
        local S = SchemaKit
        local db = SettingsKit:Open(SAVED_VARIABLE, {
            profile = S.table({
                fields = { scale = S.optional(S.number({ min = 0.5, max = 2 }), 1) },
            }),
        })
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                scale = {
                    type = "range",
                    name = "Scale",
                    min = 0.5,
                    max = 2,
                    bind = "profile.scale",
                },
            },
        }, { db = db })

        assert.are.equal(1, tree:Get("scale"))
        assert.is_true(tree:Set("scale", 1.5))
        assert.are.equal(1.5, db.profile.scale)
        assert.are.equal(1, tree:Reset("scale"))
        assert.are.equal(1, db.profile.scale)
    end)

    ---Load the chain with SettingsKit and open a database whose profile has a
    ---record `frame` without a default, holding `x` in 0..3 (default 2).
    ---@return table OptionsKit
    ---@return table db
    local function openFrameDatabase()
        local OptionsKit = TestEnv.NewPackage()
        local SettingsKit = require("SettingsKit")
        local S = require("SchemaKit")
        local db = SettingsKit:Open(SAVED_VARIABLE, {
            profile = S.table({
                fields = {
                    frame = S.optional(S.table({
                        fields = { x = S.optional(S.number({ min = 0, max = 3 }), 2) },
                    })),
                },
            }),
        })
        return OptionsKit, db
    end

    it(
        "refuses a value the database refuses: Validate returns its message, Set raises it at the caller",
        function()
            local OptionsKit, db = openFrameDatabase()
            -- The option accepts 0..10; the database only 0..3.
            local tree = OptionsKit:Define("Addon", {
                type = "group",
                args = {
                    x = { type = "range", name = "X", min = 0, max = 10, bind = "profile.frame.x" },
                },
            }, { db = db })
            tree:Set("x", 1)

            local source = debug.getinfo(1, "S").short_src
            local expectedLine
            local ok, message = pcall(function()
                expectedLine = debug.getinfo(1, "l").currentline + 1
                tree:Set("x", 5)
            end)
            assert.is_false(ok)
            assert.are.equal(
                source
                    .. ":"
                    .. expectedLine
                    .. ": OptionsKit.Tree:Set x refused by the database: SettingsKit ("
                    .. SAVED_VARIABLE
                    .. ") profile.frame.x: expected number <= 3, found larger number",
                message
            )
            assert.are.equal(1, db.profile.frame.x)

            -- Validate asks the database after the option's own schema, so it
            -- refuses what Set refuses, with the text Set raises after its prefix.
            local valid, reason = tree:Validate("x", 5)
            assert.is_false(valid)
            assert.are.equal(
                "SettingsKit ("
                    .. SAVED_VARIABLE
                    .. ") profile.frame.x: expected number <= 3, found larger number",
                reason
            )
            assert.are.equal(
                "refused by the database: " .. reason,
                message:match("refused by the database: .*$")
            )
            assert.are.same({ true }, { tree:Validate("x", 3) })
            assert.are.equal(1, db.profile.frame.x)
        end
    )

    it("binds through a record without a default, across a profile switch", function()
        local OptionsKit, db = openFrameDatabase()
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                x = { type = "range", name = "X", min = 0, max = 3, bind = "profile.frame.x" },
            },
        }, { db = db })

        assert.is_nil(db.profile.frame)
        assert.is_nil(tree:Get("x"))
        -- The database checks a path through a record that does not exist yet.
        assert.are.same({ true }, { tree:Validate("x", 2) })
        assert.is_false((tree:Validate("x", 3.5)))
        assert.is_nil(db.profile.frame)
        assert.is_nil(tree:Reset("x"))
        assert.is_true(tree:Set("x", 1))
        assert.are.equal(1, db.profile.frame.x)
        assert.are.equal(1, tree:Get("x"))

        db:SetProfile("Other")
        assert.is_nil(tree:Get("x"))
        assert.is_true(tree:Set("x", 3))
        assert.are.equal(3, tree:Get("x"))

        db:SetProfile(require("SettingsKit").DEFAULT_PROFILE)
        assert.are.equal(1, tree:Get("x"))
        assert.are.equal(2, tree:Reset("x"))
    end)

    it("refuses a bind to a scope the database did not declare, at the caller", function()
        local OptionsKit, db = openFrameDatabase()
        local source = debug.getinfo(1, "S").short_src
        local expectedLine
        local ok, message = pcall(function()
            expectedLine = debug.getinfo(1, "l").currentline + 1
            OptionsKit:Define("Addon", {
                type = "group",
                args = { x = { type = "toggle", name = "X", bind = "realm.x" } },
            }, { db = db })
        end)
        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. expectedLine
                .. ': OptionsKit:Define tree.args.x.bind scope "realm" is not an available scope of options.db',
            message
        )
    end)
    it("re-raises a SettingsKit listener's error as it is, not as a refusal", function()
        local OptionsKit, db = openFrameDatabase()
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                -- Wider than the database's 0..3, so the database can refuse.
                x = { type = "range", name = "X", min = 0, max = 10, bind = "profile.frame.x" },
            },
        }, { db = db })
        db:OnChange("profile", function()
            error("listener broke", 0)
        end)

        -- The value is valid and stored; only the listener failed after it.
        local ok, message = pcall(tree.Set, tree, "x", 2)
        assert.is_false(ok)
        assert.are.equal("listener broke", message)
        assert.are.equal(2, db.profile.frame.x)

        -- A refused write is still reported as a refusal.
        local refused, refusal = pcall(tree.Set, tree, "x", 5)
        assert.is_false(refused)
        assert.is_truthy(tostring(refusal):find("refused by the database", 1, true))
    end)

    it("describes a bound table value as a plain copy, never as a SettingsKit view", function()
        local OptionsKit = TestEnv.NewPackage()
        local SettingsKit = require("SettingsKit")
        local S = require("SchemaKit")
        local db = SettingsKit:Open(SAVED_VARIABLE, {
            profile = S.table({
                fields = {
                    channels = S.optional(
                        S.map({ keys = S.string(), values = S.boolean(), max = 8 }),
                        { SAY = true }
                    ),
                    tint = S.optional(
                        S.table({
                            fields = {
                                r = S.optional(S.number({ min = 0, max = 1 }), 1),
                                g = S.optional(S.number({ min = 0, max = 1 }), 1),
                                b = S.optional(S.number({ min = 0, max = 1 }), 1),
                            },
                        }),
                        {}
                    ),
                },
            }),
        })
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                channels = {
                    type = "multiselect",
                    name = "Channels",
                    values = { SAY = "Say", YELL = "Yell" },
                    bind = "profile.channels",
                },
                tint = { type = "color", name = "Tint", bind = "profile.tint" },
            },
        }, { db = db })
        db.profile.channels.YELL = true
        db.profile.tint.g = 0.5

        local described = tree:Describe().children
        local channels, tint = described[1].value, described[2].value
        assert.are.equal(nil, getmetatable(channels))
        assert.are.same({ SAY = true, YELL = true }, channels)
        assert.are.same({ r = 1, g = 0.5, b = 1 }, tint)

        -- The description is safe to edit: nothing reaches the database.
        channels.SAY = false
        tint.r = 0
        assert.is_true(db.profile.channels.SAY)
        assert.are.equal(1, db.profile.tint.r)
    end)

    it("allocates nothing on Validate of a bound option once the path exists", function()
        local OptionsKit, db = openFrameDatabase()
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                x = { type = "range", name = "X", min = 0, max = 3, bind = "profile.frame.x" },
            },
        }, { db = db })
        tree:Set("x", 1)
        tree:Validate("x", 2)
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 2000 do
                tree:Validate("x", 2)
            end
        end)
        assert.is_true(allocated < 1, "Validate allocated " .. allocated .. " KiB")
    end)
end)
