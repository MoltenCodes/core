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
end)
