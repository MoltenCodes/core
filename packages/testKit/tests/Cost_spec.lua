local TestEnv = require("TestKitTestEnv")

---Count native timers that are neither cancelled nor spent.
---@return integer
local function armedTimerCount()
    local count = 0
    local natives = TestEnv.NativeTimers()
    for index = 1, #natives do
        local native = natives[index]
        if not native.cancelled and (native.repeating or not native.fired) then
            count = count + 1
        end
    end
    return count
end

describe("TestKit cost", function()
    after_each(TestEnv.Reset)

    it("creates no frame, timer or OnUpdate handler by loading or registering suites", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("EventKit")
        require("LifecycleKit")
        require("TimerKit")
        require("SchedulerKit")
        local framesBefore = #TestEnv.Frames()

        local TestKit = require("TestKit")
        local suite = TestKit:Suite("MyAddon")
        suite:Test("registered", function() end)
        suite:Before(function() end)

        assert.are.equal(framesBefore, #TestEnv.Frames())
        assert.are.equal(0, #TestEnv.NativeTimers())
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
    end)

    it("leaves no armed timer, connection or OnUpdate handler behind after a run", function()
        local TestKit = TestEnv.NewReadyPackage("MyAddon")
        local suite = TestKit:Suite("MyAddon", { timeoutSeconds = 1 })
        suite:Test("waits for an event", function(ctx)
            ctx:WaitFor("SOME_EVENT", 0.5)
        end)
        suite:Test("waits until", function(ctx)
            ctx:WaitUntil(function()
                return false
            end, 0.1)
        end)
        suite:Test("times out", function(ctx)
            ctx:WaitFor("NEVER_FIRES", 30)
        end)

        local report = TestEnv.RunToEnd(TestKit, nil, 400)
        assert.is_not_nil(report)
        TestEnv.Frame()
        assert.are.equal(0, armedTimerCount())
        assert.are.equal(0, TestEnv.ActiveOnUpdateCount())
        local frames = TestEnv.Frames()
        for index = 1, #frames do
            assert.is_nil(frames[index].registrations.SOME_EVENT)
            assert.is_nil(frames[index].registrations.NEVER_FIRES)
        end
    end)
end)
