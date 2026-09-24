local TestEnv = require("HookKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("HookKit allocation #allocation", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---@param label string
    ---@param workload fun()
    local function assertAllocatesNothing(label, workload)
        workload()
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                workload()
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            label .. " allocated " .. allocated .. " KiB"
        )
    end

    it("allocates nothing on a hooked call of each semantic", function()
        local counter = 0
        local function handler()
            counter = counter + 1
        end
        local target = {}
        function target.Pre(first, second)
            return first, second
        end
        target.Raw = target.Pre
        target.Post = target.Pre
        local scope = HookKit:CreateScope()
        scope:Hook(target, "Pre", handler)
        scope:RawHook(target, "Raw", function(original, first, second)
            return original(first, second)
        end)
        scope:SecureHook(target, "Post", handler)
        local frame = TestEnv.NewFrame()
        scope:HookScript(frame, "OnUpdate", handler)
        local script = frame:GetScript("OnUpdate")

        assertAllocatesNothing("pre-hook", function()
            target.Pre(1, "a")
        end)
        assertAllocatesNothing("replacement", function()
            target.Raw(1, "a")
        end)
        assertAllocatesNothing("secure post-hook", function()
            target.Post(1, "a")
        end)
        assertAllocatesNothing("script pre-hook", function()
            script(frame, 0.016)
        end)
        assert.is_true(counter > ITERATIONS)
    end)

    it("allocates nothing on a call through an inert closure", function()
        local target = {
            Method = function(value)
                return value
            end,
        }
        local scope = HookKit:CreateScope()
        scope:Hook(target, "Method", function() end)
        local inert = target.Method
        target.Method = function(value)
            return inert(value)
        end
        scope:Unhook(target, "Method")

        assertAllocatesNothing("inert closure", function()
            target.Method(1)
        end)
    end)

    it("allocates nothing for IsHooked, Original and GetActiveCount", function()
        local target = { Method = function() end }
        local scope = HookKit:CreateScope()
        scope:Hook(target, "Method", function() end)
        local stranger = {}

        assertAllocatesNothing("lookups", function()
            scope:IsHooked(target, "Method")
            scope:IsHooked(stranger, "Method")
            scope:Original(target, "Method")
            scope:GetActiveCount()
        end)
    end)
end)
