local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit option kinds", function()
    local OptionsKit
    local store
    local tree

    ---Define a tree holding one value option `spec` at the path `option`,
    ---stored in `store.option`.
    local function defineOne(spec)
        spec.name = spec.name or "Option"
        spec.get = function()
            return store.option
        end
        spec.set = function(_, value)
            store.option = value
        end
        tree = OptionsKit:Define("Addon", { type = "group", args = { option = spec } })
        return tree
    end

    ---Assert `value` is accepted: `Set` writes it and `Validate` agrees.
    local function assertAccepted(value)
        assert.are.same({ true }, { tree:Validate("option", value) })
        assert.is_true(tree:Set("option", value))
        assert.are.equal(value, store.option)
    end

    ---Assert `value` is refused by the schema with a message containing
    ---`expected`, without being written.
    local function assertRefused(value, expected)
        local before = store.option
        local valid, message = tree:Validate("option", value)
        assert.is_false(valid)
        assert.is_truthy(message:find(expected, 1, true), message)
        TestEnv.expectErrorContaining("OptionsKit.Tree:Set option", function()
            tree:Set("option", value)
        end)
        assert.are.equal(before, store.option)
    end

    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        store = {}
    end)
    after_each(TestEnv.Reset)

    it("toggle takes a boolean", function()
        defineOne({ type = "toggle" })
        assertAccepted(true)
        assertAccepted(false)
        assertRefused(nil, "expected boolean")
        assertRefused(1, "expected boolean")
    end)

    it("a tristate toggle also takes nil", function()
        defineOne({ type = "toggle", tristate = true })
        assertAccepted(true)
        store.option = true
        assert.is_true(tree:Set("option", nil))
        assert.is_nil(store.option)
        assertRefused("on", "expected boolean")
    end)

    it("range takes a number between min and max", function()
        defineOne({ type = "range", min = 0.5, max = 2, step = 0.1 })
        assertAccepted(0.5)
        assertAccepted(2)
        assertRefused(2.5, "expected number <= 2")
        assertRefused(0, "expected number >= 0.5")
        assertRefused("1", "expected number")
        assertRefused(0 / 0, "found NaN")
    end)

    it("select over a table takes one of its keys", function()
        defineOne({ type = "select", values = { small = "Small", [3] = "Three" } })
        assertAccepted("small")
        assertAccepted(3)
        assertRefused("Small", "expected one of")
        assertRefused(4, "expected one of")
    end)

    it("select over a function takes a key of what the function returns now", function()
        local current = { a = "A" }
        local seenInfo
        defineOne({
            type = "select",
            values = function(info)
                seenInfo = info
                return current
            end,
        })
        assertAccepted("a")
        assert.are.equal("option", seenInfo.path)
        assertRefused("b", "a key of the values of option")
        current = { b = "B" }
        assertAccepted("b")
        assertRefused({}, "a key of the values of option")
    end)

    it("multiselect takes a map of its keys to booleans", function()
        defineOne({ type = "multiselect", values = { a = "A", b = "B" } })
        assertAccepted({ a = true, b = false })
        assertAccepted({})
        assertRefused({ c = true }, "expected key one of")
        assertRefused({ a = 1 }, "expected boolean")
        assertRefused("a", "expected table")
    end)

    it("multiselect over a function takes keys the function returns", function()
        defineOne({
            type = "multiselect",
            values = function()
                return { x = "X" }
            end,
        })
        assertAccepted({ x = true })
        assertRefused({ y = true }, "a key of the values of option")
    end)

    it("input takes a string matching its pattern", function()
        defineOne({ type = "input", pattern = "^%d+$" })
        assertAccepted("42")
        assertRefused("forty", "non-matching string")
        assertRefused(42, "expected string")
    end)

    it("input without a pattern takes any string", function()
        defineOne({ type = "input", multiline = true })
        assertAccepted("")
        assertAccepted("two\nlines")
        assertRefused(false, "expected string")
    end)

    it("color takes r, g, b between 0 and 1, and a only with hasAlpha", function()
        defineOne({ type = "color" })
        assertAccepted({ r = 1, g = 0.5, b = 0 })
        assertRefused({ r = 1, g = 0.5, b = 0, a = 1 }, "a: expected")
        assertRefused({ r = 2, g = 0, b = 0 }, "r: expected number <= 1")
        assertRefused({ r = 1, g = 0 }, "b: expected")
        OptionsKit:Undefine("Addon")

        defineOne({ type = "color", hasAlpha = true })
        assertAccepted({ r = 0, g = 0, b = 0, a = 0.25 })
        assertRefused({ r = 0, g = 0, b = 0 }, "a: expected")
    end)

    it("keybinding takes a string", function()
        defineOne({ type = "keybinding" })
        assertAccepted("CTRL-SHIFT-F")
        assertAccepted("")
        assertRefused(nil, "expected string")
    end)

    it("refuses Set, Get and Reset on options without a value", function()
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                group = { type = "group", name = "G", args = {} },
                header = { type = "header", name = "H" },
                text = { type = "description", name = "T" },
                run = { type = "execute", name = "R", func = function() end },
            },
        })
        for _, path in ipairs({ "group", "header", "text", "run" }) do
            TestEnv.expectErrorContaining('path "' .. path .. '" is a', function()
                tree:Set(path, true)
            end)
            TestEnv.expectErrorContaining("not a value option", function()
                tree:Get(path)
            end)
            TestEnv.expectErrorContaining("not a value option", function()
                tree:Reset(path)
            end)
        end
    end)
end)
