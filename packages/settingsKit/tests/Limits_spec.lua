local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that an action failed with `message` reported at `expectedLine` of
---this spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---Return a table of `count` numeric entries.
---@param count integer
---@return table
local function tableOf(count)
    local value = {}
    for index = 1, count do
        value[index] = index
    end
    return value
end

describe("SettingsKit limits", function()
    local SettingsKit, S
    before_each(function()
        local loaded, _, _, _, SchemaKit = TestEnv.NewPackage()
        SettingsKit, S = loaded, SchemaKit
    end)
    after_each(TestEnv.Reset)

    ---A schema with one free-form profile field and one keyed section.
    local function schema()
        return {
            profile = S.table({
                fields = {
                    data = S.optional(S.any()),
                    notes = S.optional(
                        S.map({
                            keys = S.string(),
                            values = S.optional(
                                S.table({ fields = { text = S.optional(S.any()) } }),
                                {}
                            ),
                            max = 8,
                        }),
                        {}
                    ),
                },
            }),
        }
    end

    it("publishes one UNBOUNDED sentinel and the default limits", function()
        assert.are.equal("table", type(SettingsKit.UNBOUNDED))
        assert.are.equal(SettingsKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
        assert.are.same({ maxProfileNameLength = 64, pathKeyLimit = 32 }, SettingsKit:GetLimits())
    end)

    it("returns a fresh table from GetLimits", function()
        local first = SettingsKit:GetLimits()
        first.pathKeyLimit = 1
        assert.are_not.equal(first, SettingsKit:GetLimits())
        assert.are.equal(32, SettingsKit:GetLimits().pathKeyLimit)
    end)

    it("refuses a written table past the default scan bound of 65536 entries", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        TestEnv.expectErrorContaining("refused a table too large or too deep to scan", function()
            db.profile.data = tableOf(65537)
        end)
        db.profile.data = tableOf(65536)
        assert.are.equal(65536, #db.profile.data)
    end)

    ---Return a chain of `depth` nested tables, the outermost counted as 1.
    ---@param depth integer
    ---@return table
    local function nested(depth)
        local value = { leaf = true }
        for _ = 2, depth do
            value = { inner = value }
        end
        return value
    end

    it("follows SchemaKit's maxDepth as set at write time, not at load", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        TestEnv.expectErrorContaining("refused a table too large or too deep to scan", function()
            db.profile.data = nested(20)
        end)

        S:SetLimits({ maxDepth = 32 })
        db.profile.data = nested(20)
        assert.is_true(db.profile.data.inner ~= nil)

        S:SetLimits({ maxDepth = 8 })
        TestEnv.expectErrorContaining("refused a table too large or too deep to scan", function()
            db.profile.data = nested(10)
        end)
    end)

    it("bounds CopyProfile by SchemaKit's maxDepth when it runs", function()
        S:SetLimits({ maxDepth = 32 })
        local db = SettingsKit:Open("MyAddonDB", schema())
        db:SetProfile("Deep")
        db.profile.data = nested(20)
        db:SetProfile("Default")

        S:SetLimits({ maxDepth = 16 })
        TestEnv.expectErrorContaining("CopyProfile from nests more than 16 tables", function()
            db:CopyProfile("Deep")
        end)
        S:SetLimits({ maxDepth = 32 })
        db:CopyProfile("Deep")
        assert.is_true(db.profile.data.inner ~= nil)
    end)

    it("honours maxScannedEntries given to Open", function()
        local db = SettingsKit:Open("MyAddonDB", schema(), { maxScannedEntries = 10 })
        TestEnv.expectErrorContaining("refused a table too large or too deep to scan", function()
            db.profile.data = tableOf(11)
        end)
        db.profile.data = tableOf(10)
        local ok, reason = db:Validate("profile", "data", tableOf(11))
        assert.is_false(ok)
        assert.is_truthy(reason:find("too large or too deep to scan", 1, true))
    end)

    it("scans any number of entries when maxScannedEntries is UNBOUNDED", function()
        local db =
            SettingsKit:Open("MyAddonDB", schema(), { maxScannedEntries = SettingsKit.UNBOUNDED })
        db.profile.data = tableOf(70000)
        assert.are.equal(70000, #db.profile.data)
    end)

    it("refuses an invalid maxScannedEntries at the caller's line", function()
        for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                SettingsKit:Open("MyAddonDB", schema(), { maxScannedEntries = invalid })
            end)
            assertReportedAt(
                line,
                "SettingsKit:Open options.maxScannedEntries must be a positive integer or SettingsKit.UNBOUNDED",
                ok,
                value
            )
        end
    end)

    it("enforces and raises maxProfileNameLength", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        TestEnv.expectErrorContaining("must be at most 64 bytes long", function()
            db:SetProfile(string.rep("x", 65))
        end)

        SettingsKit:SetLimits({ maxProfileNameLength = 128 })
        assert.are.equal(128, SettingsKit:GetLimits().maxProfileNameLength)
        assert.is_true(db:SetProfile(string.rep("x", 128)))
        TestEnv.expectErrorContaining("must be at most 128 bytes long", function()
            db:SetProfile(string.rep("x", 129))
        end)
        -- The facade constant stays the default.
        assert.are.equal(64, SettingsKit.MAX_PROFILE_NAME_LENGTH)
    end)

    it("honours a raised maxProfileNameLength for a stored profile key", function()
        local name = string.rep("y", 100)
        TestEnv.SavedVariable("MyAddonDB", {
            profileKeys = { ["Tester - Silvermoon"] = name },
            profiles = { [name] = {} },
        })
        SettingsKit:SetLimits({ maxProfileNameLength = 100 })
        local db = SettingsKit:Open("MyAddonDB", schema())
        assert.are.equal(name, db:GetProfile())
    end)

    it("cuts path keys at pathKeyLimit", function()
        local db = SettingsKit:Open("MyAddonDB", schema())
        local paths = {}
        db:OnChange("profile", function(_, _, _, _, path)
            paths[#paths + 1] = path
        end)
        local long = string.rep("k", 40)
        db.profile.notes[long].text = "x"
        SettingsKit:SetLimits({ pathKeyLimit = 64 })
        local longer = string.rep("m", 40)
        db.profile.notes[longer].text = "y"
        assert.are.same({
            'notes["' .. string.rep("k", 32) .. '..."]',
            "notes." .. longer,
        }, paths)
    end)

    it("refuses UNBOUNDED for the shared limits at the caller's line, with the reason", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            SettingsKit:SetLimits({ pathKeyLimit = SettingsKit.UNBOUNDED })
        end)
        assertReportedAt(
            line,
            "SettingsKit:SetLimits limits.pathKeyLimit cannot be SettingsKit.UNBOUNDED: paths show keys other players can send, and every message must stay short and printable",
            ok,
            value
        )

        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            SettingsKit:SetLimits({ maxProfileNameLength = SettingsKit.UNBOUNDED })
        end)
        assertReportedAt(
            nameLine,
            "SettingsKit:SetLimits limits.maxProfileNameLength cannot be SettingsKit.UNBOUNDED: profile names are typed by players and shown in option screens and dropdowns",
            nameOk,
            nameValue
        )
    end)

    it("refuses invalid limits at the caller's line and changes nothing", function()
        local cases = {
            { 1, "SettingsKit:SetLimits limits must be a table" },
            {
                { pathKeyLimit = 0 },
                "SettingsKit:SetLimits limits.pathKeyLimit must be an integer from 1 to 1024",
            },
            {
                { pathKeyLimit = 1025 },
                "SettingsKit:SetLimits limits.pathKeyLimit must be an integer from 1 to 1024",
            },
            {
                { maxProfileNameLength = 63 },
                "SettingsKit:SetLimits limits.maxProfileNameLength must be an integer from 64 to 1024",
            },
            {
                { maxProfileNameLength = 100.5 },
                "SettingsKit:SetLimits limits.maxProfileNameLength must be an integer from 64 to 1024",
            },
            { { maxDepth = 8 }, "SettingsKit:SetLimits limits.maxDepth is not a recognised limit" },
        }
        for index = 1, #cases do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                SettingsKit:SetLimits(cases[index][1])
            end)
            assertReportedAt(line, cases[index][2], ok, value)
        end

        -- Atomic: a valid entry beside a refused one is not applied.
        local ok = pcall(function()
            SettingsKit:SetLimits({ maxProfileNameLength = 200, pathKeyLimit = 0 })
        end)
        assert.is_false(ok)
        assert.are.same({ maxProfileNameLength = 64, pathKeyLimit = 32 }, SettingsKit:GetLimits())

        local receiverLine
        local receiverOk, receiverValue = pcall(function()
            receiverLine = currentLine() + 1
            SettingsKit.GetLimits({})
        end)
        assertReportedAt(
            receiverLine,
            "SettingsKit:GetLimits must be called on the SettingsKit facade; use SettingsKit:GetLimits(...)",
            receiverOk,
            receiverValue
        )
    end)

    it(
        "keeps the sentinel, the set limits and each database's scan bound across an upgrade",
        function()
            local sentinel = SettingsKit.UNBOUNDED
            SettingsKit:SetLimits({ maxProfileNameLength = 256, pathKeyLimit = 48 })
            local db = SettingsKit:Open("MyAddonDB", schema(), { maxScannedEntries = sentinel })

            local upgraded = TestEnv.LoadRevision(2)
            assert.are.equal(2, upgraded.REVISION)
            assert.are.equal(sentinel, upgraded.UNBOUNDED)
            assert.are.equal(sentinel, upgraded._state.unbounded)
            assert.are.same({ maxProfileNameLength = 256, pathKeyLimit = 48 }, upgraded:GetLimits())

            assert.is_true(db:SetProfile(string.rep("z", 256)))
            db.profile.data = tableOf(70000)
            assert.are.equal(70000, #db.profile.data)
        end
    )
end)
