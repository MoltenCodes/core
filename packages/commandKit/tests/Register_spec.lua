local TestEnv = require("CommandKitTestEnv")

local function noop() end

describe("CommandKit registration", function()
    local CommandKit, SchemaKit
    before_each(function()
        local _
        CommandKit, _, _, SchemaKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it(
        "writes SlashCmdList[<key>] and SLASH_<key>1 with a key from the addon and command",
        function()
            local scope = CommandKit:ForAddon("My-Addon")
            assert.is_true(scope:Register("MyCmd", { handler = noop }))
            local key = "MOLTENCODES_MY_ADDON_MYCMD"
            assert.are.equal("function", type(TestEnv.GetGlobal("SlashCmdList")[key]))
            assert.are.equal("/mycmd", TestEnv.GetGlobal("SLASH_" .. key .. "1"))
            assert.is_true(scope:IsRegistered("MYCMD"))
            assert.are.equal(1, scope:GetActiveCount())
        end
    )

    it("derives a key without an addon name for a manual scope", function()
        CommandKit:CreateScope():Register("tool", { handler = noop })
        assert.are.equal("/tool", TestEnv.GetGlobal("SLASH_MOLTENCODES_TOOL1"))
    end)

    it("refuses a slash name another addon already uses", function()
        TestEnv.GetGlobal("SlashCmdList").OTHERADDON = noop
        TestEnv.SetGlobal("SLASH_OTHERADDON1", "/other")
        TestEnv.SetGlobal("SLASH_OTHERADDON2", "/Taken")
        local scope = CommandKit:ForAddon("MyAddon")
        assert.are.same({ nil, "taken" }, { scope:Register("taken", { handler = noop }) })
        assert.is_false(scope:IsRegistered("taken"))
        assert.is_nil(TestEnv.GetGlobal("SLASH_MOLTENCODES_MYADDON_TAKEN1"))
    end)

    it("refuses a slash name the client keeps in SecureCmdList", function()
        TestEnv.SetGlobal("SecureCmdList", { CAST = noop })
        TestEnv.SetGlobal("SLASH_CAST1", "/cast")
        assert.are.same(
            { nil, "taken" },
            { CommandKit:CreateScope():Register("cast", { handler = noop }) }
        )
    end)

    it("refuses a chat type's slash name, which the client resolves first", function()
        local scope = CommandKit:CreateScope()
        assert.are.same({ nil, "taken" }, { scope:Register("s", { handler = noop }) })
        assert.are.same({ nil, "taken" }, { scope:Register("Guild", { handler = noop }) })
        assert.is_true(scope:Register("guilds", { handler = noop }))
    end)

    it("refuses an emote's slash name with nil, emote", function()
        local scope = CommandKit:CreateScope()
        assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
        assert.are.same({ nil, "emote" }, { scope:Register("greet", { handler = noop }) })
        assert.is_nil(TestEnv.GetGlobal("SLASH_MOLTENCODES_DANCE1"))
    end)

    it("reads emotes only up to the host's MAXEMOTEINDEX", function()
        TestEnv.SetGlobal("MAXEMOTEINDEX", 1)
        local scope = CommandKit:CreateScope()
        assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
        assert.is_true(scope:Register("wave", { handler = noop }))
    end)

    it("refuses a slash name another scope registered", function()
        CommandKit:ForAddon("First"):Register("shared", { handler = noop })
        assert.are.same(
            { nil, "taken" },
            { CommandKit:ForAddon("Second"):Register("shared", { handler = noop }) }
        )
    end)

    it("raises on a second registration of one name in one scope", function()
        local scope = CommandKit:CreateScope()
        scope:Register("twice", { handler = noop })
        TestEnv.expectErrorContaining('"twice" is already registered in this scope', function()
            scope:Register("Twice", { handler = noop })
        end)
    end)

    it("returns nil, full past MAX_COMMANDS", function()
        local scope = CommandKit:CreateScope()
        for index = 1, CommandKit.MAX_COMMANDS do
            assert.is_true(scope:Register("command" .. index, { handler = noop }))
        end
        assert.are.same({ nil, "full" }, { scope:Register("onemore", { handler = noop }) })
        assert.are.equal(64, scope:GetActiveCount())
    end)

    it(
        "unregisters, leaves the globals inert, and reuses the key on a later registration",
        function()
            local calls = 0
            local first = CommandKit:ForAddon("First")
            first:Register("again", {
                handler = function()
                    calls = calls + 1
                end,
            })
            local key = TestEnv.FindSlashKey("/again")
            local dispatcher = TestEnv.GetGlobal("SlashCmdList")[key]
            assert.is_true(first:Unregister("again"))
            assert.is_false(first:Unregister("again"))
            assert.are.equal(dispatcher, TestEnv.GetGlobal("SlashCmdList")[key])
            dispatcher("")
            assert.are.equal(0, calls)

            local second = CommandKit:ForAddon("Second")
            assert.is_true(second:Register("again", {
                handler = function()
                    calls = calls + 10
                end,
            }))
            assert.are.equal(key, TestEnv.FindSlashKey("/again"))
            dispatcher("")
            assert.are.equal(10, calls)
        end
    )

    it("refuses malformed names and specs at the caller", function()
        local scope = CommandKit:CreateScope()
        TestEnv.expectErrorContaining("name must be a non-empty string", function()
            scope:Register("", { handler = noop })
        end)
        TestEnv.expectErrorContaining('name "has space" must be letters', function()
            scope:Register("has space", { handler = noop })
        end)
        TestEnv.expectErrorContaining("spec must be a table", function()
            scope:Register("x", noop)
        end)
        TestEnv.expectErrorContaining('spec contains unknown field "handle"', function()
            scope:Register("x", { handle = noop })
        end)
        TestEnv.expectErrorContaining("spec needs a handler or subcommands", function()
            scope:Register("x", { usage = "<x>" })
        end)
        TestEnv.expectErrorContaining("spec.subcommands.a.handler must be a function", function()
            scope:Register("x", { subcommands = { a = { handler = true } } })
        end)
        TestEnv.expectErrorContaining("spec.arguments needs a handler to receive them", function()
            scope:Register("x", {
                arguments = { SchemaKit.number() },
                subcommands = { a = { handler = noop } },
            })
        end)
        TestEnv.expectErrorContaining("spec.arguments[1] must be a SchemaKit schema", function()
            scope:Register("x", { handler = noop, arguments = { "number" } })
        end)
        TestEnv.expectErrorContaining('spec.subcommands declares "dup" twice', function()
            scope:Register(
                "x",
                { subcommands = { dup = { handler = noop }, DUP = { handler = noop } } }
            )
        end)
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("refuses sub-commands nested deeper than MAX_DEPTH", function()
        local scope = CommandKit:CreateScope()
        local leaf = { handler = noop }
        local three =
            { subcommands = { c = { subcommands = { b = { subcommands = { a = leaf } } } } } }
        assert.is_true(scope:Register("deep", three))
        local four = { subcommands = { d = three } }
        TestEnv.expectErrorContaining("nests sub-commands deeper than 3 levels", function()
            scope:Register("deeper", four)
        end)
    end)

    it("raises without the host's SlashCmdList", function()
        TestEnv.SetGlobal("SlashCmdList", nil)
        TestEnv.expectErrorContaining("requires the host's SlashCmdList table", function()
            CommandKit:CreateScope():Register("x", { handler = noop })
        end)
    end)
end)
