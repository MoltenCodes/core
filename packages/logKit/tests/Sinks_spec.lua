local Env = require("LogKitTestEnv")

describe("LogKit sinks", function()
    local LogKit, logger

    before_each(function()
        LogKit = Env.NewPackage()
        logger = LogKit:ForAddon("MyAddon")
    end)
    after_each(function()
        Env.Reset()
    end)

    it("calls a function sink with the record", function()
        local seen
        LogKit:AddSink(function(record)
            seen = {
                addon = record.addon,
                level = record.level,
                levelName = record.levelName,
                message = record.message,
            }
        end)
        logger:Warn("hello %s", "world")
        assert.are.same({
            addon = "MyAddon",
            level = LogKit.LEVELS.warn,
            levelName = "warn",
            message = "hello world",
        }, seen)
    end)

    it("calls a table sink through its Write method with the sink as receiver", function()
        local sink = { lines = {} }
        function sink:Write(record)
            self.lines[#self.lines + 1] = record.levelName .. " " .. record.message
        end
        LogKit:AddSink(sink)
        logger:Error("boom")
        assert.are.same({ "error boom" }, sink.lines)
    end)

    it("reuses one record table across messages", function()
        local first, second
        LogKit:AddSink(function(record)
            if first == nil then
                first = record
            else
                second = record
            end
        end)
        logger:Warn("one")
        logger:Warn("two")
        assert.are.equal(first, second)
        assert.are.equal("two", first.message)
    end)

    it("delivers to every sink in registration order and removes by handle", function()
        local order = {}
        local first = LogKit:AddSink(function()
            order[#order + 1] = "first"
        end)
        LogKit:AddSink(function()
            order[#order + 1] = "second"
        end)
        logger:Warn("x")
        assert.are.same({ "first", "second" }, order)

        assert.is_true(LogKit:RemoveSink(first))
        assert.is_false(LogKit:RemoveSink(first))
        assert.is_false(LogKit:RemoveSink({}))
        assert.is_false(LogKit:RemoveSink(nil))
        logger:Warn("y")
        assert.are.same({ "first", "second", "second" }, order)
    end)

    it("isolates a failing sink and reports it through the host error handler", function()
        local reached = 0
        LogKit:AddSink(function()
            error("sink broke")
        end)
        LogKit:AddSink(function()
            reached = reached + 1
        end)
        assert.has_no.errors(function()
            logger:Warn("x")
        end)
        assert.are.equal(1, reached)
        local reported = Env.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(tostring(reported[1].value):find("sink broke", 1, true))
    end)

    it("lets a sink remove itself during a message and still calls the others", function()
        local calls = {}
        local handle
        handle = LogKit:AddSink(function()
            calls[#calls + 1] = "self-removing"
            LogKit:RemoveSink(handle)
        end)
        LogKit:AddSink(function()
            calls[#calls + 1] = "other"
        end)
        logger:Warn("x")
        logger:Warn("y")
        assert.are.same({ "self-removing", "other", "other" }, calls)
    end)

    it("starts a sink added during a message with the next message", function()
        local calls = 0
        LogKit:AddSink(function(record)
            if record.message == "x" then
                LogKit:AddSink(function()
                    calls = calls + 1
                end)
            end
        end)
        logger:Warn("x")
        assert.are.equal(0, calls)
        logger:Warn("y")
        assert.are.equal(1, calls)
    end)

    it("refuses more than maxSinks sinks with full", function()
        LogKit:SetLimits({ maxSinks = 2 })
        assert.is_not_nil(LogKit:AddSink(function() end))
        local second = LogKit:AddSink(function() end)
        assert.is_not_nil(second)
        local handle, reason = LogKit:AddSink(function() end)
        assert.is_nil(handle)
        assert.are.equal("full", reason)
        LogKit:RemoveSink(second)
        assert.is_not_nil(LogKit:AddSink(function() end))
    end)

    it("refuses a sink that is neither a function nor a table with Write", function()
        Env.expectErrorContaining(
            "LogKit:AddSink sink must be a function or a table with a Write method",
            function()
                LogKit:AddSink({})
            end
        )
        Env.expectErrorContaining("LogKit:AddSink sink must be a function", function()
            LogKit:AddSink("print")
        end)
    end)

    it(
        "survives an error handler that raises: the caller is not raised into and sinks keep working",
        function()
            local reached = {}
            Env.SetGlobal("geterrorhandler", function()
                return function()
                    error("handler broke")
                end
            end)
            local printed = {}
            local originalPrint = print
            -- selene: allow(global_usage)
            _G.print = function(text)
                printed[#printed + 1] = tostring(text)
            end
            LogKit:AddSink(function(record)
                if record.message == "first" then
                    error("sink broke")
                end
                reached[#reached + 1] = record.message
            end)
            local ok, failure = pcall(function()
                logger:Warn("first")
                logger:Warn("second")
            end)
            -- selene: allow(global_usage)
            _G.print = originalPrint
            assert.is_true(ok, failure)
            assert.is_false(LogKit._state.delivering)
            assert.are.same({ "second" }, reached)
            assert.are.equal(1, #printed)
            assert.is_not_nil(printed[1]:find("sink broke", 1, true))
        end
    )

    it("lets a sink remove another sink during a message", function()
        local calls = {}
        local victim
        LogKit:AddSink(function()
            calls[#calls + 1] = "remover"
            LogKit:RemoveSink(victim)
        end)
        victim = LogKit:AddSink(function()
            calls[#calls + 1] = "victim"
        end)
        LogKit:AddSink(function()
            calls[#calls + 1] = "last"
        end)
        logger:Warn("x")
        logger:Warn("y")
        assert.are.same({ "remover", "last", "remover", "last" }, calls)
        assert.are.equal(2, #LogKit._state.sinks)
    end)

    it("looks a table sink's Write up at every call", function()
        local sink = { lines = {} }
        function sink:Write(record)
            self.lines[#self.lines + 1] = "old " .. record.message
        end
        LogKit:AddSink(sink)
        logger:Warn("one")
        function sink:Write(record)
            self.lines[#self.lines + 1] = "new " .. record.message
        end
        logger:Warn("two")
        assert.are.same({ "old one", "new two" }, sink.lines)
    end)

    it("returns false from RemoveSink for a secret handle without raising", function()
        assert.is_false(LogKit:RemoveSink(Env.NewSecretValue()))
    end)

    it("reports a journal firing SignalKit refuses and still feeds the sinks", function()
        local SignalKit = require("SignalKit")
        SignalKit:SetLimits({ maxJournalArguments = 2 })
        local seen = {}
        LogKit:AddSink(function(record)
            seen[#seen + 1] = record.message
        end)
        assert.has_no.errors(function()
            logger:Warn("unrecorded")
        end)
        assert.are.same({ "unrecorded" }, seen)
        local reported = Env.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_not_nil(tostring(reported[1].value):find("records at most 2 arguments", 1, true))
        local count = 0
        for _ in LogKit:History() do
            count = count + 1
        end
        assert.are.equal(0, count)
    end)

    describe("chat sink", function()
        it("prints [addon] level: message to DEFAULT_CHAT_FRAME with the level coloured", function()
            Env.InstallChatApi()
            LogKit:AddSink(LogKit:ChatSink())
            logger:Warn("careful")
            logger:Error("broken %d", 3)
            assert.are.same({
                "[MyAddon] |cffffa500warn|r: careful",
                "[MyAddon] |cffff4040error|r: broken 3",
            }, Env.ChatLines())
        end)

        it("colours every level", function()
            Env.InstallChatApi()
            LogKit:AddSink(LogKit:ChatSink())
            logger:SetLevel("trace")
            logger:Trace("t")
            logger:Debug("d")
            logger:Info("i")
            assert.are.same({
                "[MyAddon] |cff9d9d9dtrace|r: t",
                "[MyAddon] |cff6699ffdebug|r: d",
                "[MyAddon] |cffffffffinfo|r: i",
            }, Env.ChatLines())
        end)

        it("prints to the chat frame it was given", function()
            Env.InstallChatApi()
            local lines = {}
            local frame = {
                AddMessage = function(_, text)
                    lines[#lines + 1] = text
                end,
            }
            LogKit:AddSink(LogKit:ChatSink(frame))
            logger:Warn("mine")
            assert.are.same({ "[MyAddon] |cffffa500warn|r: mine" }, lines)
            assert.are.same({}, Env.ChatLines())
        end)

        it("falls back to print without a chat frame", function()
            local printed = {}
            local originalPrint = print
            -- selene: allow(global_usage)
            _G.print = function(text)
                printed[#printed + 1] = text
            end
            LogKit:AddSink(LogKit:ChatSink())
            local ok, failure = pcall(logger.Warn, logger, "printed")
            -- selene: allow(global_usage)
            _G.print = originalPrint
            assert.is_true(ok, failure)
            assert.are.same({ "[MyAddon] |cffffa500warn|r: printed" }, printed)
        end)

        it("reads DEFAULT_CHAT_FRAME when the line is written", function()
            LogKit:AddSink(LogKit:ChatSink())
            Env.InstallChatApi()
            logger:Warn("late frame")
            assert.are.same({ "[MyAddon] |cffffa500warn|r: late frame" }, Env.ChatLines())
        end)

        it("refuses a chat frame without AddMessage", function()
            Env.expectErrorContaining(
                "LogKit:ChatSink chatFrame must be a table with an AddMessage method",
                function()
                    LogKit:ChatSink({})
                end
            )
        end)
    end)
end)
