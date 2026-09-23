local TestEnv = require("CommandKitTestEnv")

describe("CommandKit dispatch", function()
    local CommandKit, SchemaKit, scope, sink
    before_each(function()
        local _
        CommandKit, _, _, SchemaKit = TestEnv.NewPackage()
        scope = CommandKit:ForAddon("MyAddon")
        sink = CommandKit:CaptureSink()
        scope:SetSink(sink)
    end)
    after_each(TestEnv.Reset)

    it("calls the handler with the context and every token", function()
        local received
        scope:Register("echo", {
            handler = function(context, ...)
                received = { context:GetCommandPath(), context:GetRawText(), ... }
            end,
        })
        TestEnv.RunSlash('/echo one "two words"')
        assert.are.same({ "/echo", 'one "two words"', "one", "two words" }, received)
    end)

    it("dispatches sub-commands three levels deep, case-insensitively", function()
        local received
        scope:Register("tool", {
            subcommands = {
                one = {
                    subcommands = {
                        two = {
                            subcommands = {
                                three = {
                                    handler = function(context, ...)
                                        received = { context:GetCommandPath(), ... }
                                    end,
                                },
                            },
                        },
                    },
                },
            },
        })
        TestEnv.RunSlash("/tool ONE Two three rest of it")
        assert.are.same({ "/tool one two three", "rest", "of", "it" }, received)
    end)

    it("prints generated usage for a command without a handler", function()
        scope:Register("tool", {
            description = "Tools.",
            subcommands = {
                scale = {
                    handler = function() end,
                    arguments = {
                        SchemaKit.number({ min = 0.5, max = 2 }),
                        SchemaKit.optional(SchemaKit.enum({ "TOP", "CENTER" })),
                    },
                    description = "Set the scale.",
                },
                show = { handler = function() end, usage = "<frame>" },
                mode = { handler = function() end, arguments = { SchemaKit.boolean() } },
            },
        })
        TestEnv.RunSlash("/tool")
        assert.are.same({
            "Usage: /tool <mode|scale|show>",
            "Tools.",
            "  /tool mode <on|off>",
            "  /tool scale <number 0.5..2> [TOP|CENTER] - Set the scale.",
            "  /tool show <frame>",
        }, sink:Messages())
        sink:Clear()
        TestEnv.RunSlash("/tool nothing")
        assert.are.equal('/tool: unknown sub-command "nothing"', sink:Messages()[1])
        assert.are.equal("Usage: /tool <mode|scale|show>", sink:Messages()[2])
    end)

    it("coerces tokens for number and boolean schemas", function()
        local received
        scope:Register("set", {
            handler = function(_, ...)
                received = { count = select("#", ...), values = { ... } }
            end,
            arguments = {
                SchemaKit.number({ integer = true }),
                SchemaKit.boolean(),
                SchemaKit.optional(SchemaKit.string()),
            },
        })
        TestEnv.RunSlash("/set 42 ON")
        assert.are.same({ count = 3, values = { 42, true } }, received)
        TestEnv.RunSlash("/set 7 no label")
        assert.are.same({ count = 3, values = { 7, false, "label" } }, received)
    end)

    it("prints the schema failure and usage when an argument is refused", function()
        local calls = 0
        scope:Register("scale", {
            handler = function()
                calls = calls + 1
            end,
            arguments = { SchemaKit.number({ min = 0.5, max = 2 }) },
        })
        TestEnv.RunSlash("/scale big")
        assert.are.same({
            "/scale: argument 1: expected number, found string",
            "Usage: /scale <number 0.5..2>",
        }, sink:Messages())
        sink:Clear()
        TestEnv.RunSlash("/scale 3")
        assert.are.equal(
            "/scale: argument 1: expected number <= 2, found larger number",
            sink:Messages()[1]
        )
        sink:Clear()
        TestEnv.RunSlash("/scale")
        assert.are.equal("/scale: argument 1: expected number, found nil", sink:Messages()[1])
        sink:Clear()
        TestEnv.RunSlash("/scale 1 2")
        assert.are.equal("/scale: expected at most 1 arguments", sink:Messages()[1])
        assert.are.equal(0, calls)
    end)

    it("checks an array schema over every argument", function()
        local received
        scope:Register("sum", {
            handler = function(_, ...)
                received = { ... }
            end,
            arguments = SchemaKit.array({ of = SchemaKit.number(), min = 1, max = 3 }),
        })
        TestEnv.RunSlash("/sum 1 2 3")
        assert.are.same({ 1, 2, 3 }, received)
        TestEnv.RunSlash("/sum 1 x")
        assert.are.same({
            "/sum: arguments[2]: expected number, found string",
            "Usage: /sum <number...>",
        }, sink:Messages())
    end)

    it("reports an unterminated quote with the usage", function()
        scope:Register("speak", { handler = function() end, usage = "<text>" })
        TestEnv.RunSlash('/speak "open')
        assert.are.same({ "/speak: unterminated quote", "Usage: /speak <text>" }, sink:Messages())
    end)

    it("isolates a handler error and reports it to the sink and the host", function()
        scope:Register("boom", {
            handler = function()
                error("kaboom", 0)
            end,
        })
        local ran = false
        scope:Register("after", {
            handler = function()
                ran = true
            end,
        })
        TestEnv.RunSlash("/boom")
        TestEnv.RunSlash("/after")
        assert.is_true(ran)
        assert.are.same({ "/boom failed: kaboom" }, sink:Messages())
        assert.are.same({ "kaboom" }, TestEnv.ReportedErrors())
    end)

    it("gives the context Print, Printf, Usage and Fail", function()
        scope:Register("ctx", {
            usage = "<anything>",
            handler = function(context)
                context:Print("a", 1, true, nil)
                context:Printf("%s=%d", "x", 5)
                context:Fail("no good")
                context:Usage()
            end,
        })
        TestEnv.RunSlash("/ctx")
        assert.are.same({
            "a 1 true nil",
            "x=5",
            "/ctx: no good",
            "Usage: /ctx <anything>",
        }, sink:Messages())
    end)

    it("refuses a context kept after its command returned", function()
        local kept
        scope:Register("keep", {
            handler = function(context)
                kept = context
            end,
        })
        TestEnv.RunSlash("/keep")
        TestEnv.expectErrorContaining(
            "CommandKit.Context:Print cannot be used after its command returned",
            function()
                kept:Print("late")
            end
        )
    end)

    it("runs a command from inside another, each with its own context", function()
        local paths = {}
        scope:Register("inner", {
            handler = function(context, word)
                paths[#paths + 1] = context:GetCommandPath() .. " " .. word
            end,
        })
        scope:Register("outer", {
            handler = function(context)
                TestEnv.RunSlash("/inner nested")
                paths[#paths + 1] = context:GetCommandPath()
            end,
        })
        TestEnv.RunSlash("/outer")
        assert.are.same({ "/inner nested", "/outer" }, paths)
    end)

    it("stops nesting past four levels", function()
        local depth = 0
        scope:Register("loop", {
            handler = function()
                depth = depth + 1
                TestEnv.RunSlash("/loop")
            end,
        })
        TestEnv.RunSlash("/loop")
        assert.are.equal(4, depth)
        assert.are.same({ "/loop: commands nested too deeply" }, sink:Messages())
    end)

    it("formats Printf through LocaleKit when it is registered", function()
        TestEnv.Reset()
        local LocaleKitCommandKit = TestEnv.NewPackageWithLocaleKit()
        local localeScope = LocaleKitCommandKit:CreateScope()
        local capture = LocaleKitCommandKit:CaptureSink()
        localeScope:SetSink(capture)
        localeScope:Register("hello", {
            handler = function(context)
                context:Printf("%2$s, %1$s!", "Alice", "Hello")
            end,
        })
        TestEnv.RunSlash("/hello")
        assert.are.same({ "Hello, Alice!" }, capture:Messages())
    end)
end)
