local TestEnv = require("WidgetKitTestEnv")

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

---A dropdown value table of `count` entries.
---@param count integer
---@return table<integer, string>
local function entries(count)
    local values = {}
    for index = 1, count do
        values[index] = "Entry " .. index
    end
    return values
end

---A constructor building one plain widget per call.
---@return table widget
local function plainConstructor()
    return { frame = TestEnv.GetGlobal("CreateFrame")("Frame") }
end

-- `SetLimits` is shared by the whole session. Every spec starts from a fresh
-- package (`TestEnv.NewPackage` reloads it), so a limit one spec sets never
-- reaches the next.
describe("WidgetKit limits", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("publishes one UNBOUNDED sentinel and the default limits", function()
        assert.are.equal("table", type(WidgetKit.UNBOUNDED))
        assert.are.same(
            { maxCreatedCeiling = 4096, maxDropdownEntries = 1024 },
            WidgetKit:GetLimits()
        )
        assert.are_not.equal(WidgetKit:GetLimits(), WidgetKit:GetLimits())
    end)

    it("refuses maxCreated past the default ceiling of 4096", function()
        TestEnv.expectErrorContaining("maxCreated must be at most 4096", function()
            WidgetKit:RegisterType("Big", plainConstructor, 1, { maxCreated = 4097 })
        end)
    end)

    it("honours a raised maxCreatedCeiling for registrations and upgrades", function()
        WidgetKit:SetLimits({ maxCreatedCeiling = 8192 })
        assert.are.equal(8192, WidgetKit:GetLimits().maxCreatedCeiling)
        assert.is_true(WidgetKit:RegisterType("Big", plainConstructor, 1, { maxCreated = 8000 }))
        assert.are.equal(8000, WidgetKit:GetStatistics().byType.Big.maxCreated)

        local held = {}
        for index = 1, 300 do
            held[index] = WidgetKit:Create("Big")
        end
        WidgetKit:RegisterType("Big", plainConstructor, 2, { maxCreated = 8000 })
        -- The upgrade grows the cap by the 300 borrowed frames, clamped to the
        -- ceiling in force.
        assert.are.equal(8192, WidgetKit:GetStatistics().byType.Big.maxCreated)
    end)

    it("keeps caps already given when the ceiling is lowered", function()
        WidgetKit:RegisterType("Big", plainConstructor, 1, { maxCreated = 4000 })
        WidgetKit:SetLimits({ maxCreatedCeiling = 1000 })
        assert.are.equal(4000, WidgetKit:GetStatistics().byType.Big.maxCreated)
        TestEnv.expectErrorContaining("maxCreated must be at most 1000", function()
            WidgetKit:RegisterType("Other", plainConstructor, 1, { maxCreated = 1001 })
        end)
    end)

    it("refuses UNBOUNDED frames at the caller's line", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            WidgetKit:SetLimits({ maxCreatedCeiling = WidgetKit.UNBOUNDED })
        end)
        assertReportedAt(
            line,
            "WidgetKit:SetLimits limits.maxCreatedCeiling cannot be WidgetKit.UNBOUNDED:"
                .. " the client never frees a frame",
            ok,
            value
        )

        local typeLine
        local typeOk, typeValue = pcall(function()
            typeLine = currentLine() + 1
            WidgetKit:RegisterType("Big", plainConstructor, 1, { maxCreated = WidgetKit.UNBOUNDED })
        end)
        assertReportedAt(
            typeLine,
            "WidgetKit:RegisterType options.maxCreated cannot be WidgetKit.UNBOUNDED:"
                .. " the client never frees a frame",
            typeOk,
            typeValue
        )
    end)

    it("refuses invalid limits at the caller's line and changes nothing", function()
        for _, invalid in ipairs({ 255, 16385, 300.5, 0 / 0, "4096", {} }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                WidgetKit:SetLimits({ maxCreatedCeiling = invalid })
            end)
            assertReportedAt(
                line,
                "WidgetKit:SetLimits limits.maxCreatedCeiling must be an integer from 256 to 16384",
                ok,
                value
            )
        end

        local unknownLine
        local unknownOk, unknownValue = pcall(function()
            unknownLine = currentLine() + 1
            WidgetKit:SetLimits({ maxCreatedCeiling = 8192, maxFrames = 1 })
        end)
        assertReportedAt(
            unknownLine,
            "WidgetKit:SetLimits limits.maxFrames is not a recognised limit",
            unknownOk,
            unknownValue
        )

        -- A table key is named by its type; its `__tostring` never runs.
        local ran = false
        local key = setmetatable({}, {
            __tostring = function()
                ran = true
                return "caller text"
            end,
        })
        local keyLine
        local keyOk, keyValue = pcall(function()
            keyLine = currentLine() + 1
            WidgetKit:SetLimits({ [key] = 1 })
        end)
        assertReportedAt(
            keyLine,
            "WidgetKit:SetLimits limits.<table> is not a recognised limit",
            keyOk,
            keyValue
        )
        assert.is_false(ran)

        local tableLine
        local tableOk, tableValue = pcall(function()
            tableLine = currentLine() + 1
            WidgetKit:SetLimits(8192)
        end)
        assertReportedAt(
            tableLine,
            "WidgetKit:SetLimits limits must be a table",
            tableOk,
            tableValue
        )
        assert.are.same(
            { maxCreatedCeiling = 4096, maxDropdownEntries = 1024 },
            WidgetKit:GetLimits()
        )

        WidgetKit:SetLimits({ maxCreatedCeiling = 16384 })
        WidgetKit:SetLimits({})
        assert.are.equal(16384, WidgetKit:GetLimits().maxCreatedCeiling)
    end)

    it("honours maxCallbacks and UNBOUNDED callbacks per widget type", function()
        WidgetKit:RegisterType("Few", plainConstructor, 1, { maxCallbacks = 2 })
        local few = WidgetKit:Create("Few") ---@cast few -nil
        few:SetCallback("A", function() end)
        few:SetCallback("B", function() end)
        TestEnv.expectErrorContaining("holds at most 2 callbacks per widget", function()
            few:SetCallback("C", function() end)
        end)

        WidgetKit:RegisterType("Many", plainConstructor, 1, { maxCallbacks = WidgetKit.UNBOUNDED })
        local many = WidgetKit:Create("Many") ---@cast many -nil
        for index = 1, 100 do
            many:SetCallback("C" .. index, function() end)
        end
        assert.is_true(many:Fire("C100"))

        -- The base types keep the default of sixteen.
        local label = WidgetKit:Create("Label") ---@cast label -nil
        for index = 1, 16 do
            label:SetCallback("C" .. index, function() end)
        end
        TestEnv.expectErrorContaining("at most 16 callbacks", function()
            label:SetCallback("C17", function() end)
        end)
    end)

    it("refuses an invalid maxCallbacks at the caller's line", function()
        for _, invalid in ipairs({ 0, 1.5, math.huge, "8", {} }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                WidgetKit:RegisterType("Bad", plainConstructor, 1, { maxCallbacks = invalid })
            end)
            assertReportedAt(
                line,
                "WidgetKit:RegisterType options.maxCallbacks must be a positive integer or WidgetKit.UNBOUNDED",
                ok,
                value
            )
        end
    end)

    it(
        "honours SetMaxChildren and UNBOUNDED children, and restores the default on release",
        function()
            WidgetKit:RegisterType("Tiny", plainConstructor, 1, { maxCreated = 400 })
            local group = WidgetKit:Create("Group") ---@cast group -nil
            assert.are.equal(256, group:GetMaxChildren())
            group:PauseLayout()

            group:SetMaxChildren(2)
            assert.are.equal(2, group:GetMaxChildren())
            assert.is_true(group:AddChild(WidgetKit:Create("Tiny")))
            assert.is_true(group:AddChild(WidgetKit:Create("Tiny")))
            local added, reason = group:AddChild(WidgetKit:Create("Tiny"))
            assert.is_nil(added)
            assert.are.equal("full", reason)

            group:SetMaxChildren(WidgetKit.UNBOUNDED)
            assert.are.equal(WidgetKit.UNBOUNDED, group:GetMaxChildren())
            for _ = 1, 298 do
                assert.is_true(group:AddChild(WidgetKit:Create("Tiny")))
            end
            assert.are.equal(300, group:GetNumChildren())

            group:SetMaxChildren(10)
            local refused, full = group:AddChild(WidgetKit:Create("Tiny"))
            assert.is_nil(refused)
            assert.are.equal("full", full)
            assert.are.equal(300, group:GetNumChildren())

            WidgetKit:Release(group)
            local again = WidgetKit:Create("Group") ---@cast again -nil
            assert.are.equal(group, again)
            assert.are.equal(256, again:GetMaxChildren())
        end
    )

    it("refuses an invalid SetMaxChildren at the caller's line", function()
        local group = WidgetKit:Create("Group") ---@cast group -nil
        for _, invalid in ipairs({ 0, -3, 2.5, 0 / 0, "5", {} }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                group:SetMaxChildren(invalid)
            end)
            assertReportedAt(
                line,
                "WidgetKit.Container:SetMaxChildren limit must be a positive integer or WidgetKit.UNBOUNDED",
                ok,
                value
            )
        end

        local label = WidgetKit:Create("Label")
        local receiverLine
        local receiverOk, receiverValue = pcall(function()
            receiverLine = currentLine() + 1
            WidgetKit.Container.SetMaxChildren(label, 4)
        end)
        assertReportedAt(
            receiverLine,
            "WidgetKit.Container:SetMaxChildren must be called on a WidgetKit container",
            receiverOk,
            receiverValue
        )
    end)

    it("keeps the sentinel, the limits and opened bounds across an in-place upgrade", function()
        local sentinel = WidgetKit.UNBOUNDED
        WidgetKit:SetLimits({ maxCreatedCeiling = 10000, maxDropdownEntries = sentinel })
        WidgetKit:RegisterType("Many", plainConstructor, 1, { maxCallbacks = sentinel })
        local group = WidgetKit:Create("Group") ---@cast group -nil
        group:SetMaxChildren(sentinel)

        local nextRevision = WidgetKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(sentinel, upgraded._state.unbounded)
        assert.are.same(
            { maxCreatedCeiling = 10000, maxDropdownEntries = sentinel },
            upgraded:GetLimits()
        )
        assert.are.equal(sentinel, group:GetMaxChildren())

        local many = upgraded:Create("Many") ---@cast many -nil
        for index = 1, 40 do
            many:SetCallback("C" .. index, function() end)
        end
        assert.is_true(upgraded:RegisterType("Big", plainConstructor, 1, { maxCreated = 9000 }))
        local dropdown = upgraded:Create("Dropdown") ---@cast dropdown -nil
        dropdown:SetList(entries(2000))
        assert.are.equal(2000, dropdown:GetNumEntries())
    end)

    it("refuses a dropdown list past the default of 1024 entries", function()
        local dropdown = WidgetKit:Create("Dropdown") ---@cast dropdown -nil
        dropdown:SetList(entries(1024))
        assert.are.equal(1024, dropdown:GetNumEntries())
        TestEnv.expectErrorContaining(
            "holds at most 1024 entries (WidgetKit:SetLimits maxDropdownEntries)",
            function()
                dropdown:SetList(entries(1025))
            end
        )
        assert.are.equal(1024, dropdown:GetNumEntries())
    end)

    it("honours a raised, lowered or UNBOUNDED maxDropdownEntries", function()
        local dropdown = WidgetKit:Create("Dropdown") ---@cast dropdown -nil
        WidgetKit:SetLimits({ maxDropdownEntries = 3000 })
        assert.are.equal(3000, WidgetKit:GetLimits().maxDropdownEntries)
        dropdown:SetList(entries(3000))
        assert.are.equal(3000, dropdown:GetNumEntries())

        WidgetKit:SetLimits({ maxDropdownEntries = 2 })
        TestEnv.expectErrorContaining("holds at most 2 entries", function()
            dropdown:SetList(entries(3))
        end)
        -- The list already set is kept; the limit applies to the next list.
        assert.are.equal(3000, dropdown:GetNumEntries())

        WidgetKit:SetLimits({ maxDropdownEntries = WidgetKit.UNBOUNDED })
        assert.are.equal(WidgetKit.UNBOUNDED, WidgetKit:GetLimits().maxDropdownEntries)
        dropdown:SetList(entries(5000))
        assert.are.equal(5000, dropdown:GetNumEntries())
        -- Rows stay the fixed visible set however long the list is.
        dropdown:Open()
        assert.is_true(#dropdown._rows <= 16)
    end)

    it("refuses an invalid maxDropdownEntries at the caller's line and changes nothing", function()
        for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                WidgetKit:SetLimits({ maxCreatedCeiling = 8192, maxDropdownEntries = invalid })
            end)
            assertReportedAt(
                line,
                "WidgetKit:SetLimits limits.maxDropdownEntries must be a positive integer"
                    .. " or WidgetKit.UNBOUNDED",
                ok,
                value
            )
        end
        assert.are.same(
            { maxCreatedCeiling = 4096, maxDropdownEntries = 1024 },
            WidgetKit:GetLimits()
        )
    end)
end)
