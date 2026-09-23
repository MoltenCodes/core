local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into SettingsKit. A wrong `error` level shows up either
---as a different line number or as a message with no `file:line` prefix.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into SettingsKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
    local expectedLine = nil
    local function mark()
        expectedLine = debug.getinfo(2, "l").currentline + 1
    end
    local ok, value = pcall(action, mark)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---Assert `call` failed with `message` reported at the line inside `call`
---that called into SettingsKit: the line after `function()`.
---@param message string
---@param call fun()
local function assertCaseAtCaller(message, call)
    local expectedLine = debug.getinfo(call, "S").linedefined + 1
    local ok, value = pcall(call)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local function noop() end

describe("SettingsKit error levels", function()
    local SettingsKit, S
    before_each(function()
        local _
        SettingsKit, _, _, _, S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local function schema()
        return { profile = S.table({ fields = { scale = S.optional(S.number({ max = 2 }), 1) } }) }
    end

    it("points Open argument errors at the caller", function()
        local cases = {
            {
                "SettingsKit:Open savedVariable must be the name of a saved variable",
                function()
                    SettingsKit:Open("1bad", schema())
                end,
            },
            {
                "SettingsKit:Open schema must be a table of scope schemas",
                function()
                    SettingsKit:Open("MyAddonDB", 1)
                end,
            },
            {
                "SettingsKit:Open schema.profile must be a SchemaKit.table schema",
                function()
                    SettingsKit:Open("MyAddonDB", { profile = S.string() })
                end,
            },
            {
                "SettingsKit:Open schema.profile.x must be optional: a saved variable starts empty",
                function()
                    SettingsKit:Open(
                        "MyAddonDB",
                        { profile = S.table({ fields = { x = S.number() } }) }
                    )
                end,
            },
            {
                "SettingsKit:Open options.defaultProfile must contain a character other than whitespace",
                function()
                    SettingsKit:Open("MyAddonDB", schema(), { defaultProfile = " " })
                end,
            },
            {
                "SettingsKit:Open options.version must be a positive integer",
                function()
                    SettingsKit:Open("MyAddonDB", schema(), { version = 0 })
                end,
            },
        }
        for _, case in ipairs(cases) do
            assertCaseAtCaller(case[1], case[2])
        end
    end)

    it("points Open saved-table errors at the caller", function()
        TestEnv.SavedVariable("MyAddonDB", { version = 1, data = 1 })
        assertReportedAtCaller(
            "SettingsKit:Open migration 2 of MyAddonDB failed: nope",
            function(mark)
                mark()
                SettingsKit:Open("MyAddonDB", schema(), {
                    version = 2,
                    migrations = {
                        [2] = function()
                            error("nope", 0)
                        end,
                    },
                })
            end
        )

        TestEnv.SavedVariable("OtherDB", { char = true })
        assertReportedAtCaller("SettingsKit:Open OtherDB.char must be a table", function(mark)
            mark()
            SettingsKit:Open("OtherDB", schema())
        end)

        local db = SettingsKit:Open("ThirdDB", schema())
        assert.is_table(db)
        assertReportedAtCaller(
            "SettingsKit:Open ThirdDB is already open with a different schema table",
            function(mark)
                mark()
                SettingsKit:Open("ThirdDB", schema())
            end
        )
    end)

    it("points every database method's receiver error at the caller", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        local methods = {
            "GetProfile",
            "SetProfile",
            "GetProfiles",
            "CopyProfile",
            "ResetProfile",
            "DeleteProfile",
            "ResetDatabase",
            "OnChange",
            "OnProfileChanged",
            "OnProfileCopied",
            "OnProfileReset",
            "OnProfileDeleted",
            "Compact",
            "GetSavedVariable",
        }
        for _, method in ipairs(methods) do
            assertReportedAtCaller(
                "SettingsKit.Database:" .. method .. " must be called on a SettingsKit database",
                function(mark)
                    mark()
                    db[method]({}, "profile", noop)
                end
            )
        end
    end)

    it("points database method argument errors at the caller", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        db:SetProfile("Other")
        db:SetProfile("Default")
        local cases = {
            {
                "SettingsKit.Database:SetProfile name must be a non-empty string",
                function()
                    db:SetProfile(nil)
                end,
            },
            {
                "SettingsKit.Database:CopyProfile cannot copy the current profile onto itself",
                function()
                    db:CopyProfile("Default")
                end,
            },
            {
                "SettingsKit.Database:CopyProfile from names a profile that does not exist",
                function()
                    db:CopyProfile("Missing")
                end,
            },
            {
                "SettingsKit.Database:DeleteProfile cannot delete the current profile",
                function()
                    db:DeleteProfile("Default")
                end,
            },
            {
                "SettingsKit.Database:DeleteProfile name names a profile that does not exist",
                function()
                    db:DeleteProfile("Missing")
                end,
            },
            {
                "SettingsKit.Database:OnChange scope must name a declared, available scope",
                function()
                    db:OnChange("global", noop)
                end,
            },
            {
                "SettingsKit.Database:OnChange callback must be a function",
                function()
                    db:OnChange("profile", nil)
                end,
            },
            {
                "SettingsKit.Database:OnProfileChanged callback must be a function",
                function()
                    db:OnProfileChanged(1)
                end,
            },
            {
                "SettingsKit.Database:OnProfileCopied callback must be a function",
                function()
                    db:OnProfileCopied(1)
                end,
            },
            {
                "SettingsKit.Database:OnProfileReset callback must be a function",
                function()
                    db:OnProfileReset(1)
                end,
            },
            {
                "SettingsKit.Database:OnProfileDeleted callback must be a function",
                function()
                    db:OnProfileDeleted(1)
                end,
            },
        }
        for _, case in ipairs(cases) do
            assertCaseAtCaller(case[1], case[2])
        end
    end)

    it("points view and database refusals at the line that wrote or read", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        local profile = db.profile
        assertReportedAtCaller(
            "SettingsKit (MyAddonDB) profile.scale: expected number <= 2, found larger number",
            function(mark)
                mark()
                profile.scale = 9
            end
        )
        assertReportedAtCaller(
            "SettingsKit databases are read-only; write through db.<scope> instead",
            function(mark)
                mark()
                db.global = {}
            end
        )
        assertReportedAtCaller(
            "SettingsKit (MyAddonDB) db.char is not declared; pass schema.char to SettingsKit:Open",
            function(mark)
                mark()
                local _ = db.char
            end
        )
    end)
end)
