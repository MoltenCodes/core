local TestEnv = require("CommandKitTestEnv")

local function noop() end

describe("CommandKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local CommandKit = TestEnv.NewPackage()
        local scope = CommandKit:CreateScope()
        scope:Register("kept", { handler = noop })

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(CommandKit, reloaded)
        assert.is_true(scope:IsRegistered("kept"))
    end)

    it("publishes through Registry", function()
        local CommandKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("commandKit", 1)
        assert.are.equal(CommandKit, registered)
        assert.are.equal(CommandKit.REVISION, revision)
        assert.are.equal(64, CommandKit.MAX_COMMANDS)
        assert.are.equal(3, CommandKit.MAX_DEPTH)
        assert.are.equal("table", type(CommandKit.UNBOUNDED))
        assert.are.equal("function", type(CommandKit.SetLimits))
        assert.are.equal("function", type(CommandKit.GetLimits))
    end)

    it("upgrades in place and keeps the UNBOUNDED sentinel and the set limits", function()
        local CommandKit = TestEnv.NewPackage()
        local sentinel = CommandKit.UNBOUNDED
        CommandKit:SetLimits({ maxCaptured = sentinel, maxCompletions = 8 })

        local upgraded = TestEnv.LoadRevision(CommandKit.REVISION + 1)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.same(
            { maxCaptured = sentinel, maxCompletions = 8, maxEmotes = 1024 },
            upgraded:GetLimits()
        )
    end)

    it("refuses a facade whose UNBOUNDED disagrees with its package state", function()
        local CommandKit = TestEnv.NewPackage()
        rawset(CommandKit, "UNBOUNDED", {})
        package.loaded["CommandKit"] = nil

        local ok, value = pcall(require, "CommandKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes CommandKit", 1, true) ~= nil)
    end)

    it("loads and dispatches with Registry and SchemaKit alone", function()
        local CommandKit, Registry = TestEnv.NewPackageAlone()
        assert.are.equal(CommandKit, Registry:Get("commandKit", 1))
        local seen
        CommandKit:CreateScope():Register("solo", {
            handler = function(_, word)
                seen = word
            end,
        })
        TestEnv.RunSlash("/solo ok")
        assert.are.equal("ok", seen)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local CommandKit, Registry = TestEnv.NewPackage()
        local shippedRevision = CommandKit.REVISION
        local upgraded, previous = Registry:Register("commandKit", 1, 99)
        assert.are.equal(CommandKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(CommandKit, "REVISION", 99)
        rawset(CommandKit, "_state", { schema = 999 })
        package.loaded["CommandKit"] = nil

        local reloaded = require("CommandKit")
        assert.are.equal(CommandKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps commands, inert dispatchers and completion working", function()
        local CommandKit = TestEnv.NewPackage()
        local scopePrototype = CommandKit.Scope
        local contextPrototype = CommandKit.Context
        local calls = {}
        local scope = CommandKit:ForAddon("MyAddon")
        scope:Register("live", {
            subcommands = {
                run = {
                    handler = function(context, word)
                        calls[#calls + 1] = context:GetCommandPath() .. " " .. word
                    end,
                },
            },
        })
        scope:Register("dropped", { handler = noop })
        scope:EnableCompletion()
        local tabHandler = TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
        TestEnv.RunSlash("/live run before")
        scope:Unregister("dropped")

        local nextRevision = CommandKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(CommandKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(scopePrototype, upgraded.Scope)
        assert.are.equal(contextPrototype, upgraded.Context)
        assert.are.equal(scope, upgraded:ForAddon("MyAddon"))
        assert.are.equal(1, scope:GetActiveCount())
        assert.are.equal(tabHandler, TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))

        TestEnv.RunSlash("/live run after")
        TestEnv.RunSlash("/dropped")
        assert.are.same({ "/live run before", "/live run after" }, calls)
        local editBox = TestEnv.NewEditBox("/live r")
        assert.is_true(TestEnv.PressTab(editBox))
        assert.are.equal("/live run ", editBox.text)

        assert.is_true(upgraded:CloseAddonScopes("MyAddon"))
        TestEnv.RunSlash("/live run closed")
        assert.are.equal(2, #calls)
        assert.are.equal(
            TestEnv.OriginalTabPressed(),
            TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
        )
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local ok, value = pcall(require, "CommandKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("requires SchemaKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommandKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("SchemaKit API 1", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SchemaKit")
        Registry:Register("commandKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CommandKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes CommandKit", 1, true) ~= nil)
    end)
end)
