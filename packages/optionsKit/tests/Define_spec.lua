local TestEnv = require("OptionsKitTestEnv")

---A get/set pair over one field of `store`.
---@param store table
---@param field string
---@return table spec fields to merge into an option
local function accessors(store, field)
    return {
        get = function()
            return store[field]
        end,
        set = function(_, value)
            store[field] = value
        end,
    }
end

---Merge `extra` into `spec` and return `spec`.
local function with(spec, extra)
    for key, value in pairs(extra) do
        spec[key] = value
    end
    return spec
end

---A root group holding `option` under the key `option`.
local function rootWith(option)
    return { type = "group", args = { option = option } }
end

describe("OptionsKit:Define", function()
    local OptionsKit
    local store
    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        store = {}
    end)
    after_each(TestEnv.Reset)

    ---Assert that defining `tree` fails with a message containing `expected`.
    local function assertRefused(expected, tree, options)
        TestEnv.expectErrorContaining(expected, function()
            OptionsKit:Define("Refused", tree, options)
        end)
        assert.is_nil(OptionsKit:Get("Refused"))
    end

    it("accepts every option kind", function()
        local tree = OptionsKit:Define("Addon", {
            type = "group",
            name = "Addon",
            args = {
                group = { type = "group", name = "Group", inline = true, args = {} },
                toggle = with(
                    { type = "toggle", name = "Toggle", tristate = true },
                    accessors(store, "toggle")
                ),
                range = with({
                    type = "range",
                    name = "Range",
                    min = 0,
                    max = 10,
                    step = 1,
                    bigStep = 5,
                    softMin = 1,
                    softMax = 9,
                    isPercent = false,
                }, accessors(store, "range")),
                select = with(
                    { type = "select", name = "Select", values = { a = "A" }, sorting = { "a" } },
                    accessors(store, "select")
                ),
                multiselect = with(
                    { type = "multiselect", name = "Multi", values = { a = "A", [2] = "Two" } },
                    accessors(store, "multiselect")
                ),
                input = with({
                    type = "input",
                    name = "Input",
                    pattern = "^%w+$",
                    multiline = false,
                    usage = "<word>",
                }, accessors(store, "input")),
                color = with(
                    { type = "color", name = "Color", hasAlpha = true },
                    accessors(store, "color")
                ),
                keybinding = with(
                    { type = "keybinding", name = "Key" },
                    accessors(store, "keybinding")
                ),
                execute = {
                    type = "execute",
                    name = "Run",
                    func = function() end,
                    confirm = "Sure?",
                },
                header = { type = "header", name = "Header" },
                description = { type = "description", name = "Text", fontSize = "small" },
            },
        })
        assert.are.equal(tree, OptionsKit:Get("Addon"))
        assert.are.equal(11, tree:Walk(function() end))
    end)

    it("publishes its bounds", function()
        assert.are.equal(1024, OptionsKit.MAX_OPTIONS)
        assert.are.equal(8, OptionsKit.MAX_DEPTH)
    end)

    it("refuses a second tree for one addon until it is undefined", function()
        local first = OptionsKit:Define("Addon", { type = "group", args = {} })
        TestEnv.expectErrorContaining('"Addon" already has a tree', function()
            OptionsKit:Define("Addon", { type = "group", args = {} })
        end)
        assert.is_true(OptionsKit:Undefine("Addon"))
        assert.is_false(OptionsKit:Undefine("Addon"))
        assert.is_nil(OptionsKit:Get("Addon"))
        local second = OptionsKit:Define("Addon", { type = "group", args = {} })
        assert.are_not.equal(first, second)
    end)

    it("refuses every method on an undefined tree", function()
        local tree = OptionsKit:Define("Addon", { type = "group", args = {} })
        OptionsKit:Undefine("Addon")
        TestEnv.expectErrorContaining("cannot be called on an undefined tree", function()
            tree:Walk(function() end)
        end)
    end)

    it("copies the tree: later edits to the tables passed have no effect", function()
        local values = { a = "A" }
        local spec = rootWith(
            with({ type = "select", name = "Select", values = values }, accessors(store, "v"))
        )
        local tree = OptionsKit:Define("Addon", spec)
        values.b = "B"
        spec.args.option.name = "Changed"
        spec.args.extra = { type = "header", name = "Extra" }
        assert.are.equal(1, tree:Walk(function() end))
        assert.has_error(function()
            tree:Set("option", "b")
        end)
        local description = tree:Describe()
        assert.are.equal("Select", description.children[1].name)
        assert.are.same({ a = "A" }, description.children[1].values)
    end)

    it("refuses a root that is not a group, and malformed options", function()
        assertRefused('tree.type must be "group" at the root', { type = "toggle" })
        assertRefused("tree must be an option table", nil)
        assertRefused(
            "tree.args.option.type must be an option type",
            rootWith({ type = "slider", name = "x" })
        )
        assertRefused("tree.args.option must be an option table", rootWith(true))
        assertRefused("tree.args.option.name must be a string", rootWith({ type = "header" }))
        assertRefused(
            "tree.args.option.order must be a number",
            rootWith({ type = "header", name = "h", order = "1" })
        )
        assertRefused(
            "tree.args.option.disabled must be a boolean or a function",
            rootWith({ type = "header", name = "h", disabled = "yes" })
        )
        assertRefused("tree.args must be a table", { type = "group" })
        assertRefused(
            "tree.args keys must be identifiers",
            { type = "group", args = { ["a.b"] = { type = "header", name = "h" } } }
        )
    end)

    it("refuses an unknown field, naming it", function()
        assertRefused(
            'tree.args.option contains unknown field "witdh" for type "header"',
            rootWith({ type = "header", name = "h", witdh = "full" })
        )
        assertRefused(
            'contains unknown field "get" for type "execute"',
            rootWith({ type = "execute", name = "x", func = function() end, get = function() end })
        )
    end)

    it("refuses value options without a reader and writer, or with both kinds", function()
        assertRefused(
            "needs get and set functions, or bind",
            rootWith({ type = "toggle", name = "t" })
        )
        assertRefused(
            "needs get and set functions, or bind",
            rootWith({ type = "toggle", name = "t", get = function() end })
        )
        assertRefused(
            "must use either bind or get and set, not both",
            rootWith({ type = "toggle", name = "t", bind = "profile.t", get = function() end })
        )
        assertRefused(
            "bind needs a SettingsKit database passed as options.db",
            rootWith({ type = "toggle", name = "t", bind = "profile.t" })
        )
        assertRefused(
            "validate must be a function",
            rootWith(with({ type = "toggle", name = "t", validate = true }, accessors(store, "t")))
        )
    end)

    it("refuses malformed kind fields", function()
        local function range(extra)
            return rootWith(
                with(
                    with({ type = "range", name = "r", min = 0, max = 1 }, extra),
                    accessors(store, "r")
                )
            )
        end
        assertRefused("tree.args.option.min must be a number", range({ min = "0" }))
        assertRefused("tree.args.option.max must be a number", range({ max = 0 / 0 }))
        assertRefused("min must not be greater than max", range({ min = 2 }))
        assertRefused("step must be greater than 0", range({ step = 0 }))
        assertRefused("softMin must lie between min and max", range({ softMin = -1 }))
        assertRefused("softMax must lie between min and max", range({ softMax = 2 }))
        assertRefused(
            "softMin must not be greater than softMax",
            range({ softMin = 0.8, softMax = 0.2 })
        )

        local function select(extra)
            return rootWith(
                with(
                    with({ type = "select", name = "s", values = { a = "A" } }, extra),
                    accessors(store, "s")
                )
            )
        end
        assertRefused("values must be a table or a function", select({ values = "a" }))
        assertRefused("values must not be empty", select({ values = {} }))
        assertRefused("values labels must be strings", select({ values = { a = 1 } }))
        assertRefused(
            "values keys must be strings or numbers",
            select({ values = { [true] = "yes" } })
        )
        assertRefused("sorting entries must be keys of values", select({ sorting = { "b" } }))
        assertRefused("sorting must be an array", select({ sorting = { a = "a" } }))

        local function input(extra)
            return rootWith(
                with(with({ type = "input", name = "i" }, extra), accessors(store, "i"))
            )
        end
        assertRefused("pattern is not a valid Lua pattern", input({ pattern = "[a" }))
        assertRefused("pattern must be a string", input({ pattern = 1 }))
        assertRefused("multiline must be a boolean", input({ multiline = 1 }))

        assertRefused(
            "hasAlpha must be a boolean",
            rootWith(with({ type = "color", name = "c", hasAlpha = 1 }, accessors(store, "c")))
        )
        assertRefused("func must be a function", rootWith({ type = "execute", name = "e" }))
        assertRefused(
            "confirm must be a boolean or a string",
            rootWith({ type = "execute", name = "e", func = function() end, confirm = 1 })
        )
        assertRefused(
            'fontSize must be "small", "medium" or "large"',
            rootWith({ type = "description", name = "d", fontSize = "huge" })
        )
        assertRefused(
            "inline must be a boolean",
            rootWith({ type = "group", name = "g", inline = 1, args = {} })
        )
    end)

    it("refuses a tree deeper than MAX_DEPTH, and a cyclic tree", function()
        local deepest = { type = "header", name = "leaf" }
        local node = deepest
        for level = 9, 1, -1 do
            node = { type = "group", name = "level" .. level, args = { child = node } }
        end
        -- The outermost group is the root; the eight below it put the header
        -- nine keys deep.
        node.type = "group"
        assertRefused("is deeper than 8 levels", node)

        local cyclic = { type = "group", name = "loop", args = {} }
        cyclic.args.again = cyclic
        assertRefused("is deeper than 8 levels", cyclic)

        local fits = { type = "header", name = "leaf" }
        for level = 7, 1, -1 do
            fits = { type = "group", name = "level" .. level, args = { child = fits } }
        end
        fits.type = "group"
        local tree = OptionsKit:Define("Deep", { type = "group", args = { top = fits } })
        assert.are.equal(8, tree:Walk(function() end))
    end)

    it("refuses a tree with more than MAX_OPTIONS options", function()
        local args = {}
        for index = 1, 1024 do
            args["h" .. index] = { type = "header", name = "h" }
        end
        local tree = OptionsKit:Define("Full", { type = "group", args = args })
        assert.are.equal(1024, tree:Walk(function() end))

        args.one = { type = "header", name = "one more" }
        assertRefused(
            "OptionsKit:Define tree has more than 1024 options",
            { type = "group", args = args }
        )
    end)

    it("refuses malformed Define options and a database without SettingsKit", function()
        assertRefused(
            "OptionsKit:Define options must be a table",
            { type = "group", args = {} },
            true
        )
        assertRefused(
            'OptionsKit:Define options contains unknown field "database"',
            { type = "group", args = {} },
            { database = {} }
        )
        assertRefused(
            "OptionsKit:Define options.db needs SettingsKit API 1 to be loaded",
            { type = "group", args = {} },
            { db = TestEnv.NewDatabase() }
        )
    end)

    it("refuses an addon name that is not a non-empty string", function()
        TestEnv.expectErrorContaining(
            "OptionsKit:Define addonName must be a non-empty string",
            function()
                OptionsKit:Define("", { type = "group", args = {} })
            end
        )
        TestEnv.expectErrorContaining(
            "OptionsKit:Get addonName must be a non-empty string",
            function()
                OptionsKit:Get(nil)
            end
        )
        TestEnv.expectErrorContaining(
            "OptionsKit:Undefine addonName must be a non-empty string",
            function()
                OptionsKit:Undefine(1)
            end
        )
    end)
end)
