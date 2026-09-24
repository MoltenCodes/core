local Env = require("LogKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file, which proves the error level points at the caller.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local DEFAULTS = {
    journalCapacity = 1024,
    maxSinks = 16,
    maxMessageLength = 1024,
    maxLoggers = 256,
}

describe("LogKit limits", function()
    local LogKit

    before_each(function()
        LogKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("reports the defaults through GetLimits and the constants", function()
        assert.are.same(DEFAULTS, LogKit:GetLimits())
        assert.are.equal(1024, LogKit.DEFAULT_JOURNAL_CAPACITY)
        assert.are.equal(16, LogKit.DEFAULT_MAX_SINKS)
        assert.are.equal(1024, LogKit.DEFAULT_MAX_MESSAGE_LENGTH)
        assert.are.equal(256, LogKit.DEFAULT_MAX_LOGGERS)
    end)

    it("returns a fresh table from every GetLimits call", function()
        local first = LogKit:GetLimits()
        first.maxSinks = 1
        assert.are_not.equal(first, LogKit:GetLimits())
        assert.are.equal(16, LogKit:GetLimits().maxSinks)
    end)

    it("accepts any subset and an empty table", function()
        LogKit:SetLimits({})
        assert.are.same(DEFAULTS, LogKit:GetLimits())
        LogKit:SetLimits({ maxSinks = 3, maxLoggers = LogKit.UNBOUNDED })
        local limits = LogKit:GetLimits()
        assert.are.equal(3, limits.maxSinks)
        assert.are.equal(LogKit.UNBOUNDED, limits.maxLoggers)
        assert.are.equal(1024, limits.journalCapacity)
    end)

    describe("maxMessageLength", function()
        local delivered

        before_each(function()
            delivered = {}
            LogKit:AddSink(function(record)
                delivered[#delivered + 1] = record.message
            end)
        end)

        it("truncates a longer message with a marker at exactly the limit", function()
            LogKit:SetLimits({ maxMessageLength = 16 })
            LogKit:ForAddon("MyAddon"):Warn("0123456789abcdefghij")
            assert.are.same({ "0123456789abc..." }, delivered)
            assert.are.equal(16, #delivered[1])
        end)

        it("leaves a message at the limit untouched", function()
            LogKit:SetLimits({ maxMessageLength = 16 })
            LogKit:ForAddon("MyAddon"):Warn("0123456789abcdef")
            assert.are.same({ "0123456789abcdef" }, delivered)
        end)

        it("truncates the formatted result, not the format string", function()
            LogKit:SetLimits({ maxMessageLength = 16 })
            LogKit:ForAddon("MyAddon"):Warn("%s", "0123456789abcdefghij")
            assert.are.same({ "0123456789abc..." }, delivered)
        end)

        it("never cuts inside a UTF-8 sequence", function()
            LogKit:SetLimits({ maxMessageLength = 16 })
            -- 12 ASCII bytes, then a three-byte character starting at byte 13.
            LogKit:ForAddon("MyAddon"):Warn("0123456789ab\226\130\172xyz")
            assert.are.same({ "0123456789ab..." }, delivered)
        end)

        it("stores the truncated text in the journal", function()
            LogKit:SetLimits({ maxMessageLength = 16 })
            LogKit:ForAddon("MyAddon"):Warn("0123456789abcdefghij")
            for _, _, _, message in LogKit:History() do
                assert.are.equal("0123456789abc...", message)
            end
        end)

        it("lifts the bound with UNBOUNDED", function()
            LogKit:SetLimits({ maxMessageLength = LogKit.UNBOUNDED })
            local long = string.rep("x", 5000)
            LogKit:ForAddon("MyAddon"):Warn(long)
            assert.are.same({ long }, delivered)
        end)
    end)

    describe("journalCapacity", function()
        it("accepts the ceiling when SignalKit allows it", function()
            local SignalKit = require("SignalKit")
            SignalKit:SetLimits({ maxJournalCapacity = 65536 })
            LogKit:SetLimits({ journalCapacity = 65536 })
            assert.are.equal(65536, LogKit:GetLimits().journalCapacity)
        end)

        it("refuses a capacity above SignalKit's maxJournalCapacity at the caller", function()
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                LogKit:SetLimits({ journalCapacity = 2048 })
            end)
            assertReportedAt(
                line,
                "LogKit:SetLimits limits.journalCapacity exceeds SignalKit maxJournalCapacity (1024); raise it with SignalKit:SetLimits first",
                ok,
                value
            )
            assert.are.equal(1024, LogKit:GetLimits().journalCapacity)
        end)

        it("refuses UNBOUNDED with the reason", function()
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                LogKit:SetLimits({ journalCapacity = LogKit.UNBOUNDED })
            end)
            assertReportedAt(
                line,
                "LogKit:SetLimits limits.journalCapacity cannot be LogKit.UNBOUNDED: the ring is allocated when the journal is created",
                ok,
                value
            )
        end)

        for _, case in ipairs({
            { label = "zero", value = 0 },
            { label = "a fraction", value = 2.5 },
            { label = "above the ceiling", value = 65537 },
            { label = "a string", value = "10" },
        }) do
            it("refuses " .. case.label .. " at the caller", function()
                local line
                local ok, value = pcall(function()
                    line = currentLine() + 1
                    LogKit:SetLimits({ journalCapacity = case.value })
                end)
                assertReportedAt(
                    line,
                    "LogKit:SetLimits limits.journalCapacity must be an integer from 1 to 65536",
                    ok,
                    value
                )
            end)
        end

        it("comes up at SignalKit's maxJournalCapacity when that is below the default", function()
            Env.Reset()
            Env.InstallWowApi()
            require("Registry")
            local SignalKit = require("SignalKit")
            SignalKit:SetLimits({ maxJournalCapacity = 100 })
            LogKit = require("LogKit")
            assert.are.equal(100, LogKit:GetLimits().journalCapacity)
        end)
    end)

    local invalidValues = {
        { label = "zero", value = 0 },
        { label = "a negative number", value = -1 },
        { label = "a fraction", value = 2.5 },
        { label = "infinity", value = math.huge },
        { label = "nan", value = 0 / 0 },
        { label = "a string", value = "10" },
        { label = "a table other than UNBOUNDED", value = {} },
    }
    for _, case in ipairs(invalidValues) do
        it(
            "refuses " .. case.label .. " for maxSinks and maxLoggers and changes nothing",
            function()
                for _, name in ipairs({ "maxSinks", "maxLoggers" }) do
                    local line
                    local ok, value = pcall(function()
                        line = currentLine() + 1
                        LogKit:SetLimits({ [name] = case.value })
                    end)
                    assertReportedAt(
                        line,
                        "LogKit:SetLimits limits."
                            .. name
                            .. " must be a positive integer or LogKit.UNBOUNDED",
                        ok,
                        value
                    )
                end
                assert.are.same(DEFAULTS, LogKit:GetLimits())
            end
        )
    end

    it("refuses a maxMessageLength below 16 at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:SetLimits({ maxMessageLength = 15 })
        end)
        assertReportedAt(
            line,
            "LogKit:SetLimits limits.maxMessageLength must be an integer of at least 16 or LogKit.UNBOUNDED",
            ok,
            value
        )
    end)

    it("refuses an unknown limit at the caller before changing a valid one", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:SetLimits({ maxSinks = 10, maxJournals = 5 })
        end)
        assertReportedAt(
            line,
            "LogKit:SetLimits limits.maxJournals is not a recognised limit",
            ok,
            value
        )
        assert.are.same(DEFAULTS, LogKit:GetLimits())
    end)

    it("refuses a non-string key and a non-table argument at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:SetLimits({ 5 })
        end)
        assertReportedAt(line, "LogKit:SetLimits limits.1 is not a recognised limit", ok, value)

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit:SetLimits(256)
        end)
        assertReportedAt(line, "LogKit:SetLimits limits must be a table", ok, value)
    end)

    it("refuses SetLimits and GetLimits called without the facade", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            LogKit.SetLimits({ maxSinks = 5 })
        end)
        assertReportedAt(
            line,
            "LogKit:SetLimits must be called on the LogKit facade; use LogKit:SetLimits(...)",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            LogKit.GetLimits()
        end)
        assertReportedAt(
            line,
            "LogKit:GetLimits must be called on the LogKit facade; use LogKit:GetLimits(...)",
            ok,
            value
        )
    end)

    it("lowers maxLoggers without removing existing loggers", function()
        LogKit:ForAddon("A")
        LogKit:ForAddon("B")
        LogKit:SetLimits({ maxLoggers = 1 })
        assert.is_not_nil(LogKit:ForAddon("B"))
        local _, reason = LogKit:ForAddon("C")
        assert.are.equal("capped", reason)
    end)
end)
