local TestEnv = require("OptionsKitTestEnv")

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
end)
