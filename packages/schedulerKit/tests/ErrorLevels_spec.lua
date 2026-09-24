local TestEnv = require("SchedulerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `value` is the error `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number or
---as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param value any
local function assertReportedAt(expectedLine, message, value)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("SchedulerKit error levels", function()
    after_each(TestEnv.Reset)

    it("points the ShouldYield running-job guard at the caller", function()
        local SchedulerKit = TestEnv.NewPackage()
        local context
        SchedulerKit:Schedule(function(jobContext)
            context = jobContext
        end)
        TestEnv.Tick()

        -- The job has finished, so its context is no longer the running one.
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            context:ShouldYield()
        end)

        assert.is_false(ok)
        assertReportedAt(
            line,
            "SchedulerKit.Context:ShouldYield may only be called while its job is running",
            value
        )
    end)

    it("points the Yield running-job guard at the caller", function()
        local SchedulerKit = TestEnv.NewPackage()
        local context
        SchedulerKit:Schedule(function(jobContext)
            context = jobContext
        end)
        TestEnv.Tick()

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            context:Yield()
        end)

        assert.is_false(ok)
        assertReportedAt(
            line,
            "SchedulerKit.Context:Yield may only be called while its job is running",
            value
        )
    end)

    it("points the context receiver guard at the caller", function()
        local SchedulerKit = TestEnv.NewPackage()
        local Context = SchedulerKit.Context

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            Context.ShouldYield({})
        end)

        assert.is_false(ok)
        assertReportedAt(
            line,
            "SchedulerKit.Context:ShouldYield must be called on a SchedulerKit context",
            value
        )
    end)

    it("points CloseAddonScopes argument and receiver errors at the caller", function()
        local SchedulerKit = TestEnv.NewPackage()

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            SchedulerKit:CloseAddonScopes(42)
        end)
        assert.is_false(ok)
        assertReportedAt(
            line,
            "SchedulerKit:CloseAddonScopes addonName must be a non-empty string",
            value
        )

        local facadeLine
        local facadeOk, facadeValue = pcall(function()
            facadeLine = currentLine() + 1
            SchedulerKit.CloseAddonScopes({}, "Example")
        end)
        assert.is_false(facadeOk)
        assertReportedAt(
            facadeLine,
            "SchedulerKit:CloseAddonScopes must be called on the SchedulerKit facade; "
                .. "use SchedulerKit:CloseAddonScopes(addonName)",
            facadeValue
        )
    end)

    -- The scheduling methods used to reach their checks through a tail call
    -- (`return helper(...)`), which replaced the public method's frame: the
    -- level every argument error used then named a vanished frame and the
    -- message carried no position, in standard Lua 5.1 and on the Retail
    -- client alike. Each case below pins the caller's line instead.
    local function noop() end

    ---Each case calls one public method wrongly and names the message expected
    ---at the caller's line. `call` receives the facade, a fresh manual scope
    ---and `mark`, which records the line after its own as the calling line.
    local callerCases = {
        {
            message = "SchedulerKit:Schedule callback must be a function",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Schedule(42)
            end,
        },
        {
            message = "SchedulerKit:Schedule options must be a table",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Schedule(noop, 42)
            end,
        },
        {
            message = 'SchedulerKit:Schedule options contains unknown field "bogus"',
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Schedule(noop, { bogus = true })
            end,
        },
        {
            message = "SchedulerKit:Schedule priority must be one of SchedulerKit.Priority values",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Schedule(noop, { priority = 99 })
            end,
        },
        {
            message = "SchedulerKit:Schedule name must be a non-empty string",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Schedule(noop, { name = "" })
            end,
        },
        {
            message = "SchedulerKit:NextFrame callback must be a function",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:NextFrame(42)
            end,
        },
        {
            message = "SchedulerKit:NextFrame priority must be one of SchedulerKit.Priority values",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:NextFrame(noop, { priority = 0.5 })
            end,
        },
        {
            message = "SchedulerKit:After delay must be a finite number greater than or equal to zero",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:After(-1, noop)
            end,
        },
        {
            message = "SchedulerKit:After callback must be a function",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:After(1, 42)
            end,
        },
        {
            message = "SchedulerKit:After name must be a non-empty string",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:After(1, noop, { name = 42 })
            end,
        },
        {
            message = "SchedulerKit:Every interval must be a finite number greater than zero",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Every(0, noop)
            end,
        },
        {
            message = "SchedulerKit:Every callback must be a function",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Every(1, 42)
            end,
        },
        {
            message = "SchedulerKit:Every priority must be one of SchedulerKit.Priority values",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit:Every(1, noop, { priority = "HIGH" })
            end,
        },
        {
            message = "SchedulerKit.Scope:Schedule callback must be a function",
            call = function(_, scope, mark)
                mark()
                scope:Schedule(42)
            end,
        },
        {
            message = "SchedulerKit.Scope:Schedule priority must be one of SchedulerKit.Priority values",
            call = function(_, scope, mark)
                mark()
                scope:Schedule(noop, { priority = 99 })
            end,
        },
        {
            message = "SchedulerKit.Scope:NextFrame options must be a table",
            call = function(_, scope, mark)
                mark()
                scope:NextFrame(noop, "options")
            end,
        },
        {
            message = "SchedulerKit.Scope:After delay must be a finite number greater than or equal to zero",
            call = function(_, scope, mark)
                mark()
                scope:After(0 / 0, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:After name must be a non-empty string",
            call = function(_, scope, mark)
                mark()
                scope:After(1, noop, { name = "" })
            end,
        },
        {
            message = "SchedulerKit.Scope:Every interval must be a finite number greater than zero",
            call = function(_, scope, mark)
                mark()
                scope:Every(math.huge, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:Every callback must be a function",
            call = function(_, scope, mark)
                mark()
                scope:Every(1, nil)
            end,
        },
        {
            message = "SchedulerKit.Scope:Schedule cannot schedule work in a closed scope",
            call = function(_, scope, mark)
                scope:Close()
                mark()
                scope:Schedule(noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:After cannot schedule work in a closed scope",
            call = function(_, scope, mark)
                scope:Close()
                mark()
                scope:After(1, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:Schedule must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.Schedule({}, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:NextFrame must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.NextFrame({}, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:After must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.After(nil, 1, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:Every must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.Every({}, 1, noop)
            end,
        },
        {
            message = "SchedulerKit.Scope:CancelAll must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.CancelAll({})
            end,
        },
        {
            message = "SchedulerKit.Scope:Close must be called on a SchedulerKit scope",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Scope.Close("scope")
            end,
        },
        {
            message = "SchedulerKit.Job:Cancel must be called on a SchedulerKit job",
            call = function(SchedulerKit, _, mark)
                mark()
                SchedulerKit.Job.Cancel({})
            end,
        },
    }

    ---Run `case` and count the SchedulerKit.lua lines executed in a tail-called
    ---frame between its `mark()` and the raise.
    ---
    ---Standard Lua 5.1 keeps a "(tail call)" level on the stack where the
    ---replaced frame was, so there an error level still counts up to the
    ---caller's line through a tail call; the Retail client does not, and the
    ---message loses its position. The line alone therefore cannot catch a
    ---public method that went back to `return helper(...)`; this line hook
    ---does, because the frame such a call runs in sits on a "tail" level.
    ---@param SchedulerKit table
    ---@param case table
    ---@return integer tailCalledLines
    local function countTailCalledLines(SchedulerKit, case)
        local tailCalledLines = 0
        local previousHook, previousMask, previousCount = debug.gethook()
        local function onLine()
            local running = debug.getinfo(2, "S")
            local below = debug.getinfo(3, "S")
            if
                running ~= nil
                and below ~= nil
                and below.what == "tail"
                and running.source:find("SchedulerKit%.lua$") ~= nil
            then
                tailCalledLines = tailCalledLines + 1
            end
        end
        ---Arm the hook right before the case's own call, so the setup it does
        ---first is not counted.
        local function armHook()
            debug.sethook(onLine, "l")
        end
        pcall(case.call, SchedulerKit, SchedulerKit:CreateScope(), armHook)
        debug.sethook(previousHook, previousMask, previousCount)
        return tailCalledLines
    end

    ---Run one case and assert its message names the calling line, and that no
    ---tail call into the Kit happened on the way to the raise.
    ---@param SchedulerKit table
    ---@param case table
    local function assertCaseAtCaller(SchedulerKit, case)
        local line
        ---Record the line after the caller's, where each case calls the method.
        local function mark()
            line = debug.getinfo(2, "l").currentline + 1
        end
        local ok, value = pcall(case.call, SchedulerKit, SchedulerKit:CreateScope(), mark)
        assert.is_false(ok)
        assertReportedAt(line, case.message, value)
        assert.are.equal(0, countTailCalledLines(SchedulerKit, case), case.message)
    end

    for _, case in ipairs(callerCases) do
        it("reports '" .. case.message .. "' at the caller's line", function()
            assertCaseAtCaller(TestEnv.NewPackage(), case)
        end)
    end

    it("reports every case at the caller's line after a revision-15 upgrade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("TimerKit")

        local old = TestEnv.LoadRevision(15)
        local scope = old:CreateScope()
        local job = scope:After(5, noop)

        package.loaded["SchedulerKit"] = nil
        local upgraded = require("SchedulerKit")
        assert.are.equal(old, upgraded)
        assert.are.equal(16, upgraded.REVISION)

        -- The scope and job the older copy made keep working under the new one.
        assert.are.equal("delayed", job:GetState())
        assert.is_true(job:Cancel())
        assert.are.equal(0, scope:GetActiveCount())

        for _, case in ipairs(callerCases) do
            assertCaseAtCaller(upgraded, case)
        end
    end)
end)
