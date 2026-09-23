local TestEnv = require("OptionsKitTestEnv")

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

---A root group of `count` headers.
---@param count integer
---@return table
local function flatTree(count)
    local args = {}
    for index = 1, count do
        args["h" .. index] = { type = "header", name = "h" }
    end
    return { type = "group", args = args }
end

---A root group whose single header sits `depth` keys deep.
---@param depth integer
---@return table
local function deepTree(depth)
    local node = { type = "header", name = "leaf" }
    for level = depth - 1, 1, -1 do
        node = { type = "group", name = "level" .. level, args = { child = node } }
    end
    return { type = "group", args = { top = node } }
end

---A `values` table of `count` entries.
---@param count integer
---@return table
local function manyValues(count)
    local values = {}
    for index = 1, count do
        values[index] = "v" .. index
    end
    return values
end

describe("OptionsKit limits", function()
    local OptionsKit
    before_each(function()
        OptionsKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("publishes one UNBOUNDED sentinel table", function()
        assert.are.equal("table", type(OptionsKit.UNBOUNDED))
        assert.are.equal(OptionsKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
    end)

    it("honours maxOptions and accepts UNBOUNDED for it", function()
        local tree = OptionsKit:Define("Small", flatTree(3), { maxOptions = 3 })
        assert.are.equal(3, tree:Walk(function() end))
        assert.has_error(function()
            OptionsKit:Define("TooMany", flatTree(4), { maxOptions = 3 })
        end, nil)

        local large = OptionsKit:Define("Large", flatTree(3000), { maxOptions = 4096 })
        assert.are.equal(3000, large:Walk(function() end))
        local open =
            OptionsKit:Define("Open", flatTree(5000), { maxOptions = OptionsKit.UNBOUNDED })
        assert.are.equal(5000, open:Walk(function() end))
    end)

    it("reports a maxOptions refusal with the tree's own bound", function()
        local ok, value = pcall(OptionsKit.Define, OptionsKit, "Four", flatTree(4), {
            maxOptions = 3,
        })
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("tree has more than 3 options", 1, true))
    end)

    it("honours maxDepth up to the ceiling of 32", function()
        local ok, value = pcall(OptionsKit.Define, OptionsKit, "Nine", deepTree(9))
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("is deeper than 8 levels", 1, true))

        local tree = OptionsKit:Define("Twelve", deepTree(12), { maxDepth = 12 })
        assert.are.equal(12, tree:Walk(function() end))
        local deepest = OptionsKit:Define("ThirtyTwo", deepTree(32), { maxDepth = 32 })
        assert.are.equal(32, deepest:Walk(function() end))
        local node = deepest:Describe()
        while node.children ~= nil do
            node = node.children[1]
        end
        assert.are.equal(32, node.depth)

        local shallowOk, shallowValue =
            pcall(OptionsKit.Define, OptionsKit, "Three", deepTree(3), { maxDepth = 2 })
        assert.is_false(shallowOk)
        assert.is_truthy(tostring(shallowValue):find("is deeper than 2 levels", 1, true))
    end)

    it("refuses UNBOUNDED and values past the ceiling for maxDepth at the caller's line", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            OptionsKit:Define("Open", deepTree(2), { maxDepth = OptionsKit.UNBOUNDED })
        end)
        assertReportedAt(
            line,
            "OptionsKit:Define options.maxDepth cannot be OptionsKit.UNBOUNDED: "
                .. "the tree is built on the Lua stack, so the ceiling is 32",
            ok,
            value
        )

        for _, invalid in ipairs({ 0, 33, 1.5, 0 / 0, math.huge, "8", {} }) do
            local invalidLine
            local invalidOk, invalidValue = pcall(function()
                invalidLine = currentLine() + 1
                OptionsKit:Define("Bad", deepTree(2), { maxDepth = invalid })
            end)
            assertReportedAt(
                invalidLine,
                "OptionsKit:Define options.maxDepth must be an integer from 1 to 32",
                invalidOk,
                invalidValue
            )
        end
    end)

    it("honours maxDynamicEntries on a values table", function()
        assert.has_error(function()
            OptionsKit:Define("Default", {
                type = "group",
                args = {
                    pick = {
                        type = "select",
                        name = "Pick",
                        values = manyValues(1025),
                        get = function() end,
                        set = function() end,
                    },
                },
            })
        end)

        local function selectTree(count)
            return {
                type = "group",
                args = {
                    pick = {
                        type = "select",
                        name = "Pick",
                        values = manyValues(count),
                        get = function() end,
                        set = function() end,
                    },
                },
            }
        end
        local tree = OptionsKit:Define("Raised", selectTree(2000), { maxDynamicEntries = 2000 })
        assert.is_true(tree:Validate("pick", 2000))
        local ok, value = pcall(
            OptionsKit.Define,
            OptionsKit,
            "Lowered",
            selectTree(3),
            { maxDynamicEntries = 2 }
        )
        assert.is_false(ok)
        assert.is_truthy(tostring(value):find("must have at most 2 entries", 1, true))

        local open = OptionsKit:Define(
            "Open",
            selectTree(5000),
            { maxDynamicEntries = OptionsKit.UNBOUNDED }
        )
        assert.is_true(open:Validate("pick", 5000))
    end)

    it("bounds a multiselect over a values function by maxDynamicEntries", function()
        local values = manyValues(10)
        local function multiTree()
            return {
                type = "group",
                args = {
                    pick = {
                        type = "multiselect",
                        name = "Pick",
                        values = function()
                            return values
                        end,
                        get = function() end,
                        set = function() end,
                    },
                },
            }
        end
        local selection = {}
        for index = 1, 5 do
            selection[index] = true
        end

        local small = OptionsKit:Define("Small", multiTree(), { maxDynamicEntries = 4 })
        assert.is_false((small:Validate("pick", selection)))
        local open =
            OptionsKit:Define("Open", multiTree(), { maxDynamicEntries = OptionsKit.UNBOUNDED })
        assert.is_true(open:Validate("pick", selection))
    end)

    it("refuses invalid maxOptions and maxDynamicEntries at the caller's line", function()
        for _, name in ipairs({ "maxOptions", "maxDynamicEntries" }) do
            for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
                local line
                local ok, value = pcall(function()
                    line = currentLine() + 1
                    OptionsKit:Define("Bad", flatTree(1), { [name] = invalid })
                end)
                assertReportedAt(
                    line,
                    "OptionsKit:Define options."
                        .. name
                        .. " must be a positive integer or OptionsKit.UNBOUNDED",
                    ok,
                    value
                )
            end
        end
    end)

    it("keeps the sentinel and trees defined under opened limits across an upgrade", function()
        local sentinel = OptionsKit.UNBOUNDED
        local tree = OptionsKit:Define("Addon", deepTree(12), {
            maxOptions = sentinel,
            maxDepth = 12,
            maxDynamicEntries = 4,
        })

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(2, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(sentinel, upgraded._state.unbounded)
        assert.are.equal(tree, upgraded:Get("Addon"))
        assert.are.equal(math.huge, tree._maxOptions)
        assert.are.equal(12, tree._maxDepth)
        assert.are.equal(4, tree._maxDynamicEntries)
        assert.are.equal(12, tree:Walk(function() end))

        local after = upgraded:Define("After", flatTree(2000), { maxOptions = sentinel })
        assert.are.equal(2000, after:Walk(function() end))
    end)
end)
