local Env = require("LogKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("LogKit error levels", function()
    local LogKit, logger

    before_each(function()
        LogKit = Env.NewPackage()
        logger = LogKit:ForAddon("MyAddon")
    end)
    after_each(function()
        Env.Reset()
    end)

    it("points ForAddon name errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:ForAddon("")
        end)
        assertReportedAt(line, "LogKit:ForAddon addonName must be a non-empty string", ok, value)

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:ForAddon(7)
        end)
        assertReportedAt(line, "LogKit:ForAddon addonName must be a non-empty string", ok, value)
    end)

    it("points facade receiver errors at the caller", function()
        for _, methodName in ipairs({
            "ForAddon",
            "SetGlobalLevel",
            "GetGlobalLevel",
            "AddSink",
            "RemoveSink",
            "ChatSink",
            "History",
            "RegisterCommand",
            "BindLevels",
        }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                LogKit[methodName]({}, "MyAddon")
            end)
            assertReportedAt(
                line,
                "LogKit:"
                    .. methodName
                    .. " must be called on the LogKit facade; use LogKit:"
                    .. methodName
                    .. "(...)",
                ok,
                value
            )
        end
    end)

    it("points logger receiver errors at the caller for every method", function()
        for _, methodName in ipairs({ "Trace", "Debug", "Info", "Warn", "Error" }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                logger[methodName]({}, "message")
            end)
            assertReportedAt(
                line,
                "LogKit.Logger:" .. methodName .. " must be called on a LogKit logger",
                ok,
                value
            )
        end
        for _, methodName in ipairs({ "Log", "IsEnabled", "SetLevel", "GetLevel", "GetAddonName" }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                logger[methodName]({}, "warn", "message")
            end)
            assertReportedAt(
                line,
                "LogKit.Logger:" .. methodName .. " must be called on a LogKit logger",
                ok,
                value
            )
        end
    end)

    it("points message errors of an enabled call at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            logger:Warn({})
        end)
        assertReportedAt(line, "LogKit.Logger:Warn message must be a string", ok, value)

        ok, value = pcall(function()
            line = currentLine() + 1
            logger:Log("error", 5)
        end)
        assertReportedAt(line, "LogKit.Logger:Log message must be a string", ok, value)

        local seventeen = {}
        for index = 1, 17 do
            seventeen[index] = index
        end
        ok, value = pcall(function()
            line = currentLine() + 1
            logger:Error("%d", unpack(seventeen))
        end)
        assertReportedAt(
            line,
            "LogKit.Logger:Error accepts at most 16 format arguments; received 17",
            ok,
            value
        )
    end)

    it("points level errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            logger:SetLevel("loud")
        end)
        assertReportedAt(
            line,
            "LogKit.Logger:SetLevel level must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:SetGlobalLevel(0)
        end)
        assertReportedAt(
            line,
            "LogKit:SetGlobalLevel level must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            logger:Log("off", "x")
        end)
        assertReportedAt(line, "LogKit.Logger:Log level cannot be off", ok, value)

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:History("MyAddon", 9)
        end)
        assertReportedAt(
            line,
            "LogKit:History minimumLevel must be a level name (trace, debug, info, warn, error, off) or a LogKit.LEVELS value",
            ok,
            value
        )
    end)

    it("points sink argument errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:AddSink(5)
        end)
        assertReportedAt(
            line,
            "LogKit:AddSink sink must be a function or a table with a Write method",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:ChatSink("frame")
        end)
        assertReportedAt(
            line,
            "LogKit:ChatSink chatFrame must be a table with an AddMessage method",
            ok,
            value
        )
    end)

    it("points BindLevels errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:BindLevels({})
        end)
        assertReportedAt(
            line,
            "LogKit:BindLevels requires SettingsKit API 1, which is not loaded (absent)",
            ok,
            value
        )

        Env.LoadSettingsKit()
        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:BindLevels({})
        end)
        assertReportedAt(line, "LogKit:BindLevels db must be a SettingsKit database", ok, value)
    end)
end)
