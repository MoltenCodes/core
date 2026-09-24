local Env = require("LogKitTestEnv")

local SAVED_VARIABLE = "LogKitSpecDB"

describe("LogKit BindLevels", function()
    local LogKit

    before_each(function()
        LogKit = Env.NewPackage()
        Env.SavedVariable(SAVED_VARIABLE)
    end)
    after_each(function()
        Env.Reset()
    end)

    ---Open a database whose global scope declares `logLevels` as documented.
    ---@param SettingsKit table
    ---@param S table SchemaKit
    ---@param maxEntries integer?
    ---@return table db
    local function openDatabase(SettingsKit, S, maxEntries)
        return SettingsKit:Open(SAVED_VARIABLE, {
            global = S.table({
                fields = {
                    logLevels = S.optional(
                        S.map({ keys = S.string(), values = S.string(), max = maxEntries or 64 }),
                        {}
                    ),
                },
            }),
        })
    end

    it("refuses without SettingsKit at the caller", function()
        Env.expectErrorContaining(
            "LogKit:BindLevels requires SettingsKit API 1, which is not loaded (absent)",
            function()
                LogKit:BindLevels({})
            end
        )
    end)

    it("refuses a value that is not a SettingsKit database", function()
        Env.LoadSettingsKit()
        Env.expectErrorContaining("LogKit:BindLevels db must be a SettingsKit database", function()
            LogKit:BindLevels({ global = {} })
        end)
    end)

    it("refuses a database whose global scope does not declare logLevels", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = SettingsKit:Open(SAVED_VARIABLE, {
            global = S.table({ fields = { other = S.optional(S.number(), 1) } }),
        })
        Env.expectErrorContaining(
            "LogKit:BindLevels db must declare global.logLevels as an optional map of addon name to level name",
            function()
                LogKit:BindLevels(db)
            end
        )
    end)

    it("refuses a database without a global scope", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = SettingsKit:Open(SAVED_VARIABLE, {
            profile = S.table({ fields = {} }),
        })
        Env.expectErrorContaining("LogKit:BindLevels db must declare global.logLevels", function()
            LogKit:BindLevels(db)
        end)
    end)

    it("stores overrides and the global level in the database", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = openDatabase(SettingsKit, S)
        assert.is_true(LogKit:BindLevels(db))

        LogKit:ForAddon("MyAddon"):SetLevel("debug")
        LogKit:SetGlobalLevel("error")
        assert.are.equal("debug", db.global.logLevels.MyAddon)
        assert.are.equal("error", db.global.logLevels["*"])

        LogKit:ForAddon("MyAddon"):SetLevel(nil)
        LogKit:SetGlobalLevel(nil)
        assert.is_nil(db.global.logLevels.MyAddon)
        assert.is_nil(db.global.logLevels["*"])
    end)

    it("restores what the database holds on bind, ignoring unknown levels", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = openDatabase(SettingsKit, S)
        db.global.logLevels.Restored = "trace"
        db.global.logLevels["*"] = "info"
        db.global.logLevels.Odd = "loud"

        local logger = LogKit:ForAddon("Restored")
        assert.is_true(LogKit:BindLevels(db))
        local level, source = logger:GetLevel()
        assert.are.equal("trace", level)
        assert.are.equal("addon", source)
        assert.are.equal("info", LogKit:GetGlobalLevel())
        -- "loud" is not a level, so Odd has no override and follows the global.
        local oddLevel, oddSource = LogKit:ForAddon("Odd"):GetLevel()
        assert.are.equal("info", oddLevel)
        assert.are.equal("global", oddSource)
        -- A logger created after the bind sees its restored override too.
        db.global.logLevels.Later = "error"
        LogKit:BindLevels(db)
        assert.are.equal("error", (LogKit:ForAddon("Later"):GetLevel()))
    end)

    it("skips a secret level name in the database on bind", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = openDatabase(SettingsKit, S)
        db.global.logLevels.Hidden = "trace"
        db.global.logLevels.Plain = "info"
        Env.InstallSecretProbe("trace")
        assert.is_true(LogKit:BindLevels(db))
        assert.are.equal("default", select(2, LogKit:ForAddon("Hidden"):GetLevel()))
        assert.are.equal("info", (LogKit:ForAddon("Plain"):GetLevel()))
    end)

    it("writes the database once per change, not once per call", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = openDatabase(SettingsKit, S)
        LogKit:BindLevels(db)
        local writes = 0
        db:OnChange("global", function()
            writes = writes + 1
        end)
        local logger = LogKit:ForAddon("MyAddon")
        logger:SetLevel("debug")
        logger:SetLevel("debug")
        logger:SetLevel(LogKit.LEVELS.debug)
        assert.are.equal(1, writes)
        logger:SetLevel(nil)
        logger:SetLevel(nil)
        assert.are.equal(2, writes)
        LogKit:SetGlobalLevel("info")
        LogKit:SetGlobalLevel("info")
        LogKit:SetGlobalLevel(nil)
        LogKit:SetGlobalLevel(nil)
        assert.are.equal(4, writes)
    end)

    it("stops persisting after BindLevels(nil)", function()
        local SettingsKit, S = Env.LoadSettingsKit()
        local db = openDatabase(SettingsKit, S)
        LogKit:BindLevels(db)
        assert.is_false(LogKit:BindLevels(nil))
        LogKit:ForAddon("MyAddon"):SetLevel("debug")
        assert.is_nil(db.global.logLevels.MyAddon)
        assert.are.equal("debug", (LogKit:ForAddon("MyAddon"):GetLevel()))
    end)

    it(
        "reports a refused write through the host error handler and keeps the session level",
        function()
            local SettingsKit, S = Env.LoadSettingsKit()
            local db = openDatabase(SettingsKit, S, 1)
            LogKit:BindLevels(db)
            LogKit:ForAddon("First"):SetLevel("debug")
            LogKit:ForAddon("Second"):SetLevel("trace")
            assert.are.equal("debug", db.global.logLevels.First)
            assert.is_nil(db.global.logLevels.Second)
            assert.are.equal("trace", (LogKit:ForAddon("Second"):GetLevel()))
            local reported = Env.TakeReportedErrors()
            assert.are.equal(1, #reported)
            assert.is_not_nil(
                tostring(reported[1].value):find("expected at most 1 entries", 1, true)
            )
        end
    )
end)
