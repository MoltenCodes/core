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

    it("raises a SettingsKit refusal at the caller of Set, keeping its message", function()
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

        -- Validate knows only the option's own schema: SettingsKit API 1 has no
        -- way to check a value without writing it (docs/API.md, "Bound options").
        assert.are.same({ true }, { tree:Validate("x", 5) })
    end)

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
end)
