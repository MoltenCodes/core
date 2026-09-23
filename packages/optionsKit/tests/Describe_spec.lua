local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit tree Describe", function()
    local OptionsKit
    local store
    local tree

    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        store = { scale = 1.25, mode = "b", tags = { x = true } }
        tree = OptionsKit:Define("Addon", {
            type = "group",
            name = "My Addon",
            desc = "Everything",
            args = {
                display = {
                    type = "group",
                    name = "Display",
                    inline = true,
                    order = 1,
                    args = {
                        scale = {
                            type = "range",
                            name = "Scale",
                            desc = "Frame scale",
                            min = 0.5,
                            max = 2,
                            step = 0.05,
                            isPercent = true,
                            get = function()
                                return store.scale
                            end,
                            set = function() end,
                        },
                        mode = {
                            type = "select",
                            name = "Mode",
                            values = { a = "A", b = "B" },
                            sorting = { "b", "a" },
                            disabled = true,
                            get = function()
                                return store.mode
                            end,
                            set = function() end,
                        },
                        tags = {
                            type = "multiselect",
                            name = "Tags",
                            values = function()
                                return { x = "X", y = "Y" }
                            end,
                            get = function()
                                return store.tags
                            end,
                            set = function() end,
                        },
                    },
                },
                run = { type = "execute", name = "Run", confirm = "Really?", func = function() end },
                note = { type = "description", name = "Read me", fontSize = "large", order = 0 },
            },
        })
    end)
    after_each(TestEnv.Reset)

    it("describes the root with the addon name and sorted children", function()
        local root = tree:Describe()
        assert.are.equal("group", root.kind)
        assert.are.equal("Addon", root.addonName)
        assert.are.equal("My Addon", root.name)
        assert.are.equal("Everything", root.desc)
        assert.are.equal("", root.path)
        assert.are.equal(0, root.depth)
        assert.is_nil(root.key)
        assert.is_false(root.disabled)
        assert.is_false(root.hidden)
        assert.are.equal(3, #root.children)
        assert.are.equal("note", root.children[1].key)
        assert.are.equal("display", root.children[2].key)
        assert.are.equal("run", root.children[3].key)
    end)

    it("describes a value option with its fields, value and schema", function()
        local display = tree:Describe().children[2]
        assert.is_true(display.inline)
        local scale = display.children[2]
        assert.are.same({
            kind = "range",
            key = "scale",
            path = "display.scale",
            depth = 2,
            name = "Scale",
            desc = "Frame scale",
            order = 100,
            disabled = false,
            hidden = false,
            min = 0.5,
            max = 2,
            step = 0.05,
            isPercent = true,
            value = 1.25,
            schema = { kind = "number", min = 0.5, max = 2, integer = false },
        }, scale)
    end)

    it("copies values and sorting, calling a values function", function()
        local display = tree:Describe().children[2]
        local mode = display.children[1]
        assert.are.equal("mode", mode.key)
        assert.are.same({ a = "A", b = "B" }, mode.values)
        assert.are.same({ "b", "a" }, mode.sorting)
        assert.is_true(mode.disabled)
        assert.are.equal("b", mode.value)
        assert.are.equal("enum", mode.schema.kind)

        local tags = display.children[3]
        assert.are.same({ x = "X", y = "Y" }, tags.values)
        assert.is_nil(tags.sorting)
        assert.are.equal("map", tags.schema.kind)
    end)

    it("describes options without values with their hints only", function()
        local root = tree:Describe()
        assert.are.same({
            kind = "execute",
            key = "run",
            path = "run",
            depth = 1,
            name = "Run",
            order = 100,
            disabled = false,
            hidden = false,
            confirm = "Really?",
        }, root.children[3])
        assert.are.equal("large", root.children[1].fontSize)
    end)

    it("returns a fresh table on every call", function()
        local first = tree:Describe()
        first.children[2].children[1].values.c = "C"
        local second = tree:Describe()
        assert.are_not.equal(first, second)
        assert.is_nil(second.children[2].children[1].values.c)
    end)

    it("names the bind path of a bound option", function()
        OptionsKit:Undefine("Addon")
        local _, Registry = TestEnv.NewPackage()
        OptionsKit = require("OptionsKit")
        TestEnv.InstallSettingsKitStub(Registry)
        local db = TestEnv.NewDatabase({ profile = { shown = true } })
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = { shown = { type = "toggle", name = "Shown", bind = "profile.shown" } },
        }, { db = db })
        local shown = tree:Describe().children[1]
        assert.are.equal("profile.shown", shown.bind)
        assert.is_true(shown.value)
        assert.are.same({ kind = "boolean" }, shown.schema)
    end)

    it("raises when a values function returns no table", function()
        OptionsKit:Undefine("Addon")
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                pick = {
                    type = "select",
                    name = "Pick",
                    values = function()
                        return nil
                    end,
                    get = function() end,
                    set = function() end,
                },
            },
        })
        TestEnv.expectErrorContaining(
            'OptionsKit.Tree:Describe values function of "pick" returned no table',
            function()
                tree:Describe()
            end
        )
    end)
end)
