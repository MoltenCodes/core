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
end)
