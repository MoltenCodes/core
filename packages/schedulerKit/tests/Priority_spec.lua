local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit priorities", function()
    after_each(TestEnv.Reset)

    it("is FIFO within a priority lane", function()
        local SchedulerKit = TestEnv.NewPackage()
        local order = {}
        for index = 1, 5 do
            SchedulerKit:Schedule(function()
                order[#order + 1] = index
            end, { priority = SchedulerKit.Priority.NORMAL })
        end

        TestEnv.Tick()
        assert.are.same({ 1, 2, 3, 4, 5 }, order)
    end)

    it("gives high priority more service while preserving lower-priority progress", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(8)
        local order = {}

        for index = 1, 8 do
            SchedulerKit:Schedule(function()
                order[#order + 1] = "H" .. index
            end, { priority = SchedulerKit.Priority.HIGH })
        end
        for index = 1, 3 do
            SchedulerKit:Schedule(function()
                order[#order + 1] = "N" .. index
            end, { priority = SchedulerKit.Priority.NORMAL })
        end
        SchedulerKit:Schedule(function() order[#order + 1] = "L" end, {
            priority = SchedulerKit.Priority.LOW,
        })
        SchedulerKit:Schedule(function() order[#order + 1] = "I" end, {
            priority = SchedulerKit.Priority.IDLE,
        })

        TestEnv.Tick()
        assert.are.same({ "H1", "H2", "H3", "H4", "N1", "N2", "L", "I" }, order)
        TestEnv.Tick()
        assert.are.same(
            { "H1", "H2", "H3", "H4", "N1", "N2", "L", "I", "H5", "H6", "H7", "H8", "N3" },
            order
        )
    end)

    it("keeps the fairness cursor across frames", function()
        local SchedulerKit = TestEnv.NewPackage()
        SchedulerKit:SetMaxResumesPerFrame(1)
        local order = {}
        for index = 1, 8 do
            SchedulerKit:Schedule(function() order[#order + 1] = "H" end, {
                priority = SchedulerKit.Priority.HIGH,
            })
        end
        SchedulerKit:Schedule(function() order[#order + 1] = "N" end, {
            priority = SchedulerKit.Priority.NORMAL,
        })

        for _ = 1, 5 do TestEnv.Tick() end
        assert.are.same({ "H", "H", "H", "H", "N" }, order)
    end)
end)
