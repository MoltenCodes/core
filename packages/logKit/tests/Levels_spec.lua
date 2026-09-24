local Env = require("LogKitTestEnv")

describe("LogKit levels", function()
    local LogKit

    before_each(function()
        LogKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    ---Collect every `(addon, levelName, message)` the journal holds.
    ---@return table[]
    local function journalEntries()
        local entries = {}
        for _, addon, levelName, message in LogKit:History() do
            entries[#entries + 1] = { addon, levelName, message }
        end
        return entries
    end

    it("publishes the level ordering as a read-only table", function()
        assert.are.equal(1, LogKit.LEVELS.trace)
        assert.are.equal(2, LogKit.LEVELS.debug)
        assert.are.equal(3, LogKit.LEVELS.info)
        assert.are.equal(4, LogKit.LEVELS.warn)
        assert.are.equal(5, LogKit.LEVELS.error)
        assert.are.equal(6, LogKit.LEVELS.off)
        assert.is_true(LogKit.LEVELS.trace < LogKit.LEVELS.error)
        Env.expectErrorContaining("LogKit.LEVELS is read-only", function()
            LogKit.LEVELS.fatal = 7
        end)
        assert.are.equal("LogKit.Levels", getmetatable(LogKit.LEVELS))
    end)

    it("starts every logger at warn from the default", function()
        local logger = LogKit:ForAddon("MyAddon")
        assert.are.equal("warn", LogKit.DEFAULT_LEVEL)
        local level, source = logger:GetLevel()
        assert.are.equal("warn", level)
        assert.are.equal("default", source)
        assert.is_nil(LogKit:GetGlobalLevel())
    end)

    it("returns the same logger for the same addon name", function()
        local logger = LogKit:ForAddon("MyAddon")
        assert.are.equal(logger, LogKit:ForAddon("MyAddon"))
        assert.are_not.equal(logger, LogKit:ForAddon("Other"))
        assert.are.equal("MyAddon", logger:GetAddonName())
    end)

    it("gates messages below the effective level", function()
        local logger = LogKit:ForAddon("MyAddon")
        logger:Trace("t")
        logger:Debug("d")
        logger:Info("i")
        logger:Warn("w")
        logger:Error("e")
        assert.are.same(
            { { "MyAddon", "warn", "w" }, { "MyAddon", "error", "e" } },
            journalEntries()
        )
    end)

    it("answers IsEnabled by level name and by LEVELS value", function()
        local logger = LogKit:ForAddon("MyAddon")
        assert.is_false(logger:IsEnabled("info"))
        assert.is_true(logger:IsEnabled("warn"))
        assert.is_true(logger:IsEnabled(LogKit.LEVELS.error))
        logger:SetLevel("trace")
        assert.is_true(logger:IsEnabled("trace"))
        logger:SetLevel("off")
        assert.is_false(logger:IsEnabled("error"))
    end)

    it("delivers through Log with a level name or a LEVELS value", function()
        local logger = LogKit:ForAddon("MyAddon")
        logger:SetLevel("debug")
        logger:Log("debug", "by name %d", 1)
        logger:Log(LogKit.LEVELS.info, "by value")
        logger:Log("trace", "gated")
        assert.are.same(
            { { "MyAddon", "debug", "by name 1" }, { "MyAddon", "info", "by value" } },
            journalEntries()
        )
    end)

    it("prefers the addon override over the global level over the default", function()
        local logger = LogKit:ForAddon("MyAddon")
        local other = LogKit:ForAddon("Other")

        LogKit:SetGlobalLevel("debug")
        assert.are.equal("debug", LogKit:GetGlobalLevel())
        local level, source = logger:GetLevel()
        assert.are.equal("debug", level)
        assert.are.equal("global", source)
        assert.is_true(other:IsEnabled("debug"))

        logger:SetLevel("error")
        level, source = logger:GetLevel()
        assert.are.equal("error", level)
        assert.are.equal("addon", source)
        assert.is_false(logger:IsEnabled("warn"))
        assert.is_true(other:IsEnabled("debug"))

        logger:SetLevel(nil)
        level, source = logger:GetLevel()
        assert.are.equal("debug", level)
        assert.are.equal("global", source)

        LogKit:SetGlobalLevel(nil)
        level, source = logger:GetLevel()
        assert.are.equal("warn", level)
        assert.are.equal("default", source)
        assert.is_nil(LogKit:GetGlobalLevel())
    end)

    it("accepts a LEVELS value for SetLevel and SetGlobalLevel", function()
        local logger = LogKit:ForAddon("MyAddon")
        LogKit:SetGlobalLevel(LogKit.LEVELS.trace)
        assert.are.equal("trace", LogKit:GetGlobalLevel())
        logger:SetLevel(LogKit.LEVELS.off)
        assert.are.equal("off", (logger:GetLevel()))
        logger:Error("silenced")
        assert.are.same({}, journalEntries())
    end)

    it("applies an override set before the logger is created", function()
        LogKit:SetGlobalLevel("info")
        local logger = LogKit:ForAddon("Late")
        assert.is_true(logger:IsEnabled("info"))
        logger:Info("seen")
        assert.are.same({ { "Late", "info", "seen" } }, journalEntries())
    end)

    it("turns a logger off with the off level", function()
        local logger = LogKit:ForAddon("MyAddon")
        logger:SetLevel("off")
        logger:Error("nothing")
        assert.are.same({}, journalEntries())
        assert.is_false(logger:IsEnabled("error"))
    end)

    it("refuses off as a message level", function()
        local logger = LogKit:ForAddon("MyAddon")
        Env.expectErrorContaining("LogKit.Logger:Log level cannot be off", function()
            logger:Log("off", "never")
        end)
        Env.expectErrorContaining("LogKit.Logger:IsEnabled level cannot be off", function()
            logger:IsEnabled("off")
        end)
    end)

    it("refuses an unknown level", function()
        local logger = LogKit:ForAddon("MyAddon")
        Env.expectErrorContaining(
            "LogKit.Logger:SetLevel level must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value",
            function()
                logger:SetLevel("loud")
            end
        )
        Env.expectErrorContaining("LogKit:SetGlobalLevel level must be a level name", function()
            LogKit:SetGlobalLevel(7)
        end)
    end)

    it("caps the number of loggers and keeps returning existing ones", function()
        LogKit:SetLimits({ maxLoggers = 2 })
        assert.is_not_nil(LogKit:ForAddon("One"))
        assert.is_not_nil(LogKit:ForAddon("Two"))
        local logger, reason = LogKit:ForAddon("Three")
        assert.is_nil(logger)
        assert.are.equal("capped", reason)
        assert.is_not_nil(LogKit:ForAddon("One"))
        LogKit:SetLimits({ maxLoggers = LogKit.UNBOUNDED })
        assert.is_not_nil(LogKit:ForAddon("Three"))
    end)
end)
