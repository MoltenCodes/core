local TestEnv = require("CommandKitTestEnv")

describe("CommandKit and secret values", function()
    local CommandKit, secret, sink, scope
    before_each(function()
        CommandKit = TestEnv.NewPackage()
        secret = TestEnv.NewSecretValue()
        TestEnv.SetGlobal("issecretvalue", function(value)
            return rawequal(value, secret) or value == "%s secret template"
        end)
        scope = CommandKit:CreateScope()
        sink = CommandKit:CaptureSink()
        scope:SetSink(sink)
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret argument to Print and Printf at the handler's line", function()
        local failures = {}
        scope:Register("leak", {
            handler = function(context)
                failures[1] = select(2, pcall(context.Print, context, "name", secret))
                failures[2] = select(2, pcall(context.Printf, context, "%s", secret))
                failures[3] = select(2, pcall(context.Printf, context, "%s secret template", 1))
            end,
        })
        TestEnv.RunSlash("/leak")
        assert.is_truthy(
            failures[1]:find(
                "CommandKit.Context:Print argument 2 must not be a secret value",
                1,
                true
            )
        )
        assert.is_truthy(
            failures[2]:find(
                "CommandKit.Context:Printf argument 2 must not be a secret value",
                1,
                true
            )
        )
        assert.is_truthy(
            failures[3]:find(
                "CommandKit.Context:Printf argument 1 must not be a secret value",
                1,
                true
            )
        )
        assert.are.same({}, sink:Messages())
    end)

    it("refuses secret text and names", function()
        TestEnv.expectErrorContaining("CommandKit:Parse text must be a string", function()
            CommandKit:Parse(secret)
        end)
        TestEnv.SetGlobal("issecretvalue", function(value)
            return value == "hidden"
        end)
        TestEnv.expectErrorContaining("CommandKit:Parse text must not be a secret value", function()
            CommandKit:Parse("hidden")
        end)
        TestEnv.expectErrorContaining(
            "CommandKit.Scope:Register name must not be a secret value",
            function()
                scope:Register("hidden", { handler = function() end })
            end
        )
    end)

    it("asks ClientKit when it is registered", function()
        TestEnv.Reset()
        local WithClientKit, ClientKit = TestEnv.NewPackageWithClientKit()
        TestEnv.SetGlobal("issecretvalue", nil)
        rawset(ClientKit, "IsSecret", function(_, value)
            return value == "hidden"
        end)
        TestEnv.expectErrorContaining("CommandKit:Parse text must not be a secret value", function()
            WithClientKit:Parse("hidden")
        end)
    end)

    it("shows a secret option value as a placeholder", function()
        TestEnv.Reset()
        local Kit, _, _, _, OptionsKit = TestEnv.NewPackage()
        TestEnv.SetGlobal("issecretvalue", function(value)
            return rawequal(value, secret)
        end)
        local tree = OptionsKit:Define("MyAddon", {
            type = "group",
            args = {
                name = {
                    type = "input",
                    name = "Name",
                    get = function()
                        return secret
                    end,
                    set = function() end,
                },
            },
        })
        local bound = Kit:CreateScope()
        local capture = Kit:CaptureSink()
        bound:SetSink(capture)
        bound:BindOptions(tree, "opts")
        TestEnv.RunSlash("/opts get name")
        assert.are.same({ "name = (secret value)" }, capture:Messages())
    end)
end)
