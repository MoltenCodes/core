local TestEnv = require("OptionsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into OptionsKit: `mark()` records the line after it.
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

describe("OptionsKit and secret values", function()
    local OptionsKit
    local secret
    local stored
    local tree

    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        secret = TestEnv.NewSecretValue()
        -- The shared fixture installs no client identity by default, so this
        -- suite installs the `issecretvalue` probe itself.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return rawequal(value, secret)
        end)
        stored = "name"
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                label = {
                    type = "input",
                    name = "Label",
                    get = function()
                        return stored
                    end,
                    set = function(_, value)
                        stored = value
                    end,
                },
            },
        })
    end)
    after_each(function()
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", nil)
        TestEnv.Reset()
    end)

    it("refuses a secret value at Set without writing it", function()
        TestEnv.expectErrorContaining(
            "OptionsKit.Tree:Set value must not be a secret value",
            function()
                tree:Set("label", secret)
            end
        )
        assert.are.equal("name", stored)
    end)

    it("reports a secret value as invalid from Validate", function()
        assert.are.same({ false, "secret value" }, { tree:Validate("label", secret) })
    end)

    it("refuses a secret path before indexing with it", function()
        TestEnv.expectErrorContaining(
            "OptionsKit.Tree:Get path must not be a secret value",
            function()
                tree:Get(secret)
            end
        )
        TestEnv.expectErrorContaining(
            "OptionsKit.Tree:Set path must not be a secret value",
            function()
                tree:Set(secret, "x")
            end
        )
    end)

    it("refuses a secret addon name", function()
        TestEnv.expectErrorContaining(
            "OptionsKit:Get addonName must not be a secret value",
            function()
                OptionsKit:Get(secret)
            end
        )
    end)

    it("returns what a getter returns, secret or not, untouched", function()
        stored = secret
        assert.is_true(rawequal(secret, tree:Get("label")))
    end)

    it("Describe replaces a cyclic or too deep table value instead of handing it out", function()
        local cyclic = { r = 0 }
        cyclic.self = cyclic
        local deep = {}
        local cursor = deep
        for _ = 1, 12 do
            cursor.next = {}
            cursor = cursor.next
        end
        local values = { cyclic = cyclic, deep = deep }
        local described = OptionsKit:Define("Shapes", {
            type = "group",
            args = {
                cyclic = {
                    type = "color",
                    name = "C",
                    get = function()
                        return values.cyclic
                    end,
                    set = function() end,
                },
                deep = {
                    type = "color",
                    name = "D",
                    get = function()
                        return values.deep
                    end,
                    set = function() end,
                },
            },
        })
            :Describe().children

        local cyclicCopy = described[1].value
        assert.is_false(rawequal(cyclic, cyclicCopy))
        assert.are.equal("<cycle>", cyclicCopy.self)
        assert.are.equal(0, cyclicCopy.r)

        -- The eighth nested table is still copied; the ninth is replaced.
        local level = described[2].value
        for _ = 1, 7 do
            level = level.next
        end
        assert.are.equal("<depth exceeded>", level.next)
    end)

    it("Describe passes a secret value through uncopied, at the top and nested", function()
        stored = secret
        local label = tree:Describe().children[1]
        assert.is_true(rawequal(secret, label.value))

        -- A table value is copied, but a secret inside it is passed through.
        local colour = { r = secret, g = 0, b = 0 }
        local withColour = OptionsKit:Define("Colours", {
            type = "group",
            args = {
                tint = {
                    type = "color",
                    name = "Tint",
                    get = function()
                        return colour
                    end,
                    set = function() end,
                },
            },
        })
        local described = withColour:Describe().children[1].value
        assert.is_false(rawequal(colour, described))
        assert.is_true(rawequal(secret, described.r))
    end)

    it("refuses a secret limit option at the caller before comparing it", function()
        for _, name in ipairs({ "maxOptions", "maxDepth", "maxDynamicEntries" }) do
            assertReportedAtCaller(
                "OptionsKit:Define options." .. name .. " must not be a secret value",
                function(mark)
                    mark()
                    OptionsKit:Define("Limited", { type = "group", args = {} }, { [name] = secret })
                end
            )
        end
        assert.is_nil(OptionsKit:Get("Limited"))
    end)

    it("counts a secret returned by validate as a refusal without comparing it", function()
        local written = 0
        local guarded = OptionsKit:Define("Guarded", {
            type = "group",
            args = {
                label = {
                    type = "input",
                    name = "Label",
                    get = function() end,
                    set = function()
                        written = written + 1
                    end,
                    validate = function()
                        return secret
                    end,
                },
            },
        })
        assert.are.same({ false, "refused by validate" }, { guarded:Set("label", "x") })
        assert.are.same({ false, "refused by validate" }, { guarded:Validate("label", "x") })
        assert.are.equal(0, written)
    end)
    it("refuses a secret flag or field of a tree at the caller before testing it", function()
        -- `true` stands in for a secret boolean: without the probe asked
        -- first, it would pass as a boolean and be tested for truth.
        secret = true
        for _, field in ipairs({ "disabled", "hidden", "tristate" }) do
            assertReportedAtCaller(
                "OptionsKit:Define tree.args.enabled." .. field .. " must not be a secret value",
                function(mark)
                    mark()
                    OptionsKit:Define("Flagged", {
                        type = "group",
                        args = {
                            enabled = {
                                type = "toggle",
                                name = "Enabled",
                                get = function() end,
                                set = function() end,
                                [field] = true,
                            },
                        },
                    })
                end
            )
        end
        assertReportedAtCaller(
            "OptionsKit:Define tree.args.color.hasAlpha must not be a secret value",
            function(mark)
                mark()
                OptionsKit:Define("Flagged", {
                    type = "group",
                    args = {
                        color = {
                            type = "color",
                            name = "Colour",
                            get = function() end,
                            set = function() end,
                            hasAlpha = true,
                        },
                    },
                })
            end
        )
        assert.is_nil(OptionsKit:Get("Flagged"))
    end)

    it("refuses a secret option type at the caller before using it as a key", function()
        secret = "toggle"
        assertReportedAtCaller(
            "OptionsKit:Define tree.args.enabled.type must not be a secret value",
            function(mark)
                mark()
                OptionsKit:Define("Typed", {
                    type = "group",
                    args = {
                        enabled = {
                            type = "toggle",
                            name = "Enabled",
                            get = function() end,
                            set = function() end,
                        },
                    },
                })
            end
        )
    end)

    it("counts a secret disabled or hidden answer as no", function()
        local answer = TestEnv.NewSecretValue()
        secret = answer
        local calls = 0
        local predicate = function()
            calls = calls + 1
            return answer
        end
        local guarded = OptionsKit:Define("Predicated", {
            type = "group",
            args = {
                label = {
                    type = "input",
                    name = "Label",
                    get = function() end,
                    set = function() end,
                    disabled = predicate,
                    hidden = predicate,
                },
            },
        })
        assert.is_false(guarded:IsDisabled("label"))
        assert.is_false(guarded:IsHidden("label"))
        local node = guarded:Describe().children[1]
        assert.is_false(node.disabled)
        assert.is_false(node.hidden)
        assert.are.equal(4, calls)
    end)

    it("Describe passes a secret desc a desc function returns through", function()
        secret = "hidden text"
        local described = OptionsKit:Define("Described", {
            type = "group",
            args = {
                label = {
                    type = "input",
                    name = "Label",
                    desc = function()
                        return secret
                    end,
                    get = function() end,
                    set = function() end,
                },
            },
        })
        assert.are.equal(secret, described:Describe().children[1].desc)
    end)
end)
