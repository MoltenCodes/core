local Env = require("LogKitTestEnv")

describe("LogKit slash command", function()
    local LogKit

    before_each(function()
        LogKit = Env.NewPackage()
        Env.InstallChatApi()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("returns false, absent without CommandKit", function()
        local registered, reason = LogKit:RegisterCommand()
        assert.is_false(registered)
        assert.are.equal("absent", reason)
    end)

    it("returns false, unavailable without SlashCmdList", function()
        require("SchemaKit")
        require("CommandKit")
        local registered, reason = LogKit:RegisterCommand()
        assert.is_false(registered)
        assert.are.equal("unavailable", reason)
    end)

    describe("with CommandKit", function()
        before_each(function()
            Env.LoadCommandKit()
            assert.is_true(LogKit:RegisterCommand())
        end)

        it("answers a secret addon name or level word with the usage", function()
            Env.InstallSecretProbe("Hidden")
            Env.RunSlash("/log Hidden debug")
            Env.RunSlash("/log MyAddon Hidden")
            Env.RunSlash("/log show Hidden")
            local usages = 0
            for _, line in ipairs(Env.ChatLines()) do
                if line:find("Usage: /log", 1, true) then
                    usages = usages + 1
                end
            end
            assert.are.equal(3, usages)
            assert.is_nil(LogKit._state.addonLevels.Hidden)
            assert.are.equal("default", select(2, LogKit:ForAddon("MyAddon"):GetLevel()))
        end)

        it("is idempotent and registers /log once", function()
            assert.is_true(LogKit:RegisterCommand())
            local count = 0
            -- selene: allow(global_usage)
            for name, value in pairs(_G) do
                if type(name) == "string" and name:find("^SLASH_") and value == "/log" then
                    count = count + 1
                end
            end
            assert.are.equal(1, count)
        end)

        it("sets an addon override with /log <addon> <level>", function()
            Env.RunSlash("/log MyAddon debug")
            local logger = LogKit:ForAddon("MyAddon")
            local level, source = logger:GetLevel()
            assert.are.equal("debug", level)
            assert.are.equal("addon", source)
            assert.are.same({ "MyAddon: debug (addon)" }, Env.ChatLines())
        end)

        it("sets the global level with /log * <level> and clears with default", function()
            Env.RunSlash("/log * trace")
            assert.are.equal("trace", LogKit:GetGlobalLevel())
            Env.RunSlash("/log * default")
            assert.is_nil(LogKit:GetGlobalLevel())
            assert.are.same({ "global: trace", "global: not set" }, Env.ChatLines())
        end)

        it("clears an addon override with default", function()
            local logger = LogKit:ForAddon("MyAddon")
            logger:SetLevel("error")
            Env.RunSlash("/log MyAddon default")
            assert.are.equal("default", select(2, logger:GetLevel()))
        end)

        it("refuses an unknown level with a failure line", function()
            Env.RunSlash("/log MyAddon loud")
            assert.are.same({
                '/log: unknown level "loud"; use one of trace, debug, info, warn, error, off, or default to clear',
            }, Env.ChatLines())
            assert.is_nil(LogKit._state.addonLevels.MyAddon)
        end)

        it("prints the usage when an argument is missing", function()
            Env.RunSlash("/log MyAddon")
            local lines = Env.ChatLines()
            assert.is_not_nil(lines[1]:find("Usage: /log <addon|*> <level|default>", 1, true))
        end)

        it("shows every logger and the global level with /log show", function()
            LogKit:ForAddon("Beta")
            LogKit:ForAddon("Alpha"):SetLevel("info")
            LogKit:SetGlobalLevel("error")
            Env.RunSlash("/log show")
            assert.are.same({
                "global: error",
                "Alpha: info (addon)",
                "Beta: error (global)",
            }, Env.ChatLines())
        end)

        it("shows one addon with /log show <addon>", function()
            Env.RunSlash("/log show Nobody")
            assert.are.same({ "Nobody: warn (default)" }, Env.ChatLines())
        end)

        it("sets a level without creating a logger or consuming maxLoggers", function()
            LogKit:SetLimits({ maxLoggers = 1 })
            LogKit:ForAddon("Taken")
            Env.RunSlash("/log Another debug")
            assert.are.same({ "Another: debug (addon)" }, Env.ChatLines())
            assert.is_nil(LogKit._state.loggers.Another)
            assert.are.equal(1, LogKit._state.loggerCount)
            LogKit:SetLimits({ maxLoggers = 2 })
            assert.are.equal("debug", (LogKit:ForAddon("Another"):GetLevel()))
        end)

        it("reads the level word without case and ignores extra tokens", function()
            Env.RunSlash("/log MyAddon Debug now please")
            Env.RunSlash("/log * ERROR")
            assert.are.equal("debug", (LogKit:ForAddon("MyAddon"):GetLevel()))
            assert.are.equal("error", LogKit:GetGlobalLevel())
            assert.are.same({ "MyAddon: debug (addon)", "global: error" }, Env.ChatLines())
        end)
    end)

    it("returns CommandKit's refusal when /log is taken", function()
        local CommandKit = Env.LoadCommandKit()
        local scope = CommandKit:CreateScope()
        assert.is_true(scope:Register("log", {
            handler = function() end,
        }))
        local registered, reason = LogKit:RegisterCommand()
        assert.is_false(registered)
        assert.are.equal("taken", reason)
    end)

    it("dispatches through the newest revision after an upgrade", function()
        Env.LoadCommandKit()
        assert.is_true(LogKit:RegisterCommand())
        local upgraded = Env.LoadRevision(LogKit.REVISION + 1)
        assert.is_true(upgraded:RegisterCommand())
        Env.RunSlash("/log MyAddon trace")
        assert.are.equal("trace", (upgraded:ForAddon("MyAddon"):GetLevel()))
    end)
end)
