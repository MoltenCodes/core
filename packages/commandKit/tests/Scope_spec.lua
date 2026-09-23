local TestEnv = require("CommandKitTestEnv")

local function noop() end

describe("CommandKit scopes", function()
    local CommandKit
    before_each(function()
        CommandKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("returns one canonical scope per addon", function()
        local scope = CommandKit:ForAddon("MyAddon")
        assert.are.equal(scope, CommandKit:ForAddon("MyAddon"))
        assert.are_not.equal(scope, CommandKit:ForAddon("Other"))
        assert.are.equal("MyAddon", scope:GetAddonName())
        assert.is_nil(CommandKit:CreateScope():GetAddonName())
        assert.are_not.equal(CommandKit:CreateScope(), CommandKit:CreateScope())
    end)

    it("leaves an inert global behind when a scope closes", function()
        local calls = 0
        local scope = CommandKit:ForAddon("MyAddon")
        scope:Register("gone", {
            handler = function()
                calls = calls + 1
            end,
        })
        scope:Register("also", { handler = noop })
        local key = TestEnv.FindSlashKey("/gone")
        TestEnv.RunSlash("/gone")
        assert.are.equal(1, calls)

        assert.is_true(scope:Close())
        assert.is_false(scope:Close())
        assert.is_true(scope:IsClosed())
        assert.are.equal(0, scope:GetActiveCount())
        assert.are.equal("function", type(TestEnv.GetGlobal("SlashCmdList")[key]))
        assert.are.equal("/gone", TestEnv.GetGlobal("SLASH_" .. key .. "1"))
        TestEnv.RunSlash("/gone with text")
        assert.are.equal(1, calls)
        assert.are.same({}, TestEnv.ChatLines())
        assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("refuses registration and completion on a closed scope", function()
        local scope = CommandKit:CreateScope()
        scope:Close()
        TestEnv.expectErrorContaining(
            "CommandKit.Scope:Register cannot be used on a closed scope",
            function()
                scope:Register("x", { handler = noop })
            end
        )
        TestEnv.expectErrorContaining(
            "CommandKit.Scope:EnableCompletion cannot be used on a closed scope",
            function()
                scope:EnableCompletion()
            end
        )
    end)

    it("closes an addon's scope through CloseAddonScopes", function()
        local scope = CommandKit:ForAddon("MyAddon")
        scope:Register("mine", { handler = noop })
        assert.is_true(CommandKit:CloseAddonScopes("MyAddon"))
        assert.is_false(CommandKit:CloseAddonScopes("MyAddon"))
        assert.is_true(scope:IsClosed())
        assert.are.equal(scope, CommandKit:ForAddon("MyAddon"))
        -- The closed scope's name is free for another owner.
        assert.is_true(CommandKit:ForAddon("Other"):Register("mine", { handler = noop }))
    end)

    it("records nothing for an addon that never had a scope", function()
        assert.is_false(CommandKit:CloseAddonScopes("Never"))
        assert.is_nil(rawget(CommandKit._state.addonScopes, "Never"))
    end)

    it("refuses facade methods called with a dot", function()
        TestEnv.expectErrorContaining(
            "CommandKit:ForAddon must be called on the CommandKit facade",
            function()
                CommandKit.ForAddon("MyAddon")
            end
        )
        TestEnv.expectErrorContaining(
            "CommandKit:CreateScope must be called on the CommandKit facade",
            function()
                CommandKit.CreateScope()
            end
        )
    end)
end)
