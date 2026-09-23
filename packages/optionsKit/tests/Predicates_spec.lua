local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit disabled and hidden", function()
    local OptionsKit
    local flags
    local seen
    local tree

    local function noop() end

    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        flags = { advanced = false, combat = false }
        seen = {}
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                advanced = {
                    type = "group",
                    name = "Advanced",
                    hidden = function(info)
                        seen[#seen + 1] = info.path
                        return not flags.advanced
                    end,
                    args = {
                        debug = { type = "toggle", name = "Debug", get = noop, set = noop },
                    },
                },
                combat = {
                    type = "group",
                    name = "Combat",
                    disabled = true,
                    args = {
                        enabled = { type = "toggle", name = "Enabled", get = noop, set = noop },
                    },
                },
                always = {
                    type = "toggle",
                    name = "Always",
                    disabled = function()
                        return flags.combat
                    end,
                    get = noop,
                    set = noop,
                },
                plain = { type = "header", name = "Plain" },
            },
        })
    end)
    after_each(TestEnv.Reset)

    it("evaluates predicates with the option's info on every call", function()
        assert.is_true(tree:IsHidden("advanced"))
        flags.advanced = true
        assert.is_false(tree:IsHidden("advanced"))
        assert.are.same({ "advanced", "advanced" }, seen)

        assert.is_false(tree:IsDisabled("always"))
        flags.combat = true
        assert.is_true(tree:IsDisabled("always"))
    end)

    it("applies a group's flag to everything below it", function()
        assert.is_true(tree:IsHidden("advanced.debug"))
        assert.is_true(tree:IsDisabled("combat.enabled"))
        assert.is_false(tree:IsHidden("combat.enabled"))
        flags.advanced = true
        assert.is_false(tree:IsHidden("advanced.debug"))
    end)

    it("reports options without flags as shown and enabled", function()
        assert.is_false(tree:IsHidden("plain"))
        assert.is_false(tree:IsDisabled("plain"))
    end)

    it("honours a flag on the root group", function()
        OptionsKit:Undefine("Addon")
        tree = OptionsKit:Define("Addon", {
            type = "group",
            disabled = true,
            args = { plain = { type = "header", name = "Plain" } },
        })
        assert.is_true(tree:IsDisabled("plain"))
        assert.is_true(tree:Describe().disabled)
    end)
end)
