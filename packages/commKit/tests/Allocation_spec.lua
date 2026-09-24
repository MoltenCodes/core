local TestEnv = require("CommKitTestEnv")

-- Each workload repeats its operation many times, so a single table per call
-- would show up as tens of kilobytes. The threshold leaves room for the few
-- bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CommKit allocation #allocation", function()
    local CommKit
    before_each(function()
        CommKit = TestEnv.NewPackage()
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

    it("allocates nothing to receive and deliver a single chunk", function()
        local received = 0
        CommKit:CreateScope():Register("CKTest", function()
            received = received + 1
        end)
        assertAllocatesNothing("single-chunk receive", function()
            TestEnv.Deliver("CKTest", "\001hello there", "PARTY", "Friend-Realm")
        end)
        assert.are.equal(ITERATIONS + 1, received)
    end)

    it("allocates nothing for a message on a prefix nobody registered", function()
        CommKit:CreateScope():Register("CKTest", function() end)
        assertAllocatesNothing("foreign prefix", function()
            TestEnv.Deliver("Other", "\001hello there", "PARTY", "Friend-Realm")
        end)
    end)

    it("allocates nothing for the handle and queue queries", function()
        local handle = CommKit:CreateScope():Send({
            prefix = "CKTest",
            text = "hello",
            distribution = "PARTY",
        })
        assertAllocatesNothing("queries", function()
            handle:GetState()
            handle:GetBytesSent()
            CommKit:GetQueueDepth()
            CommKit:GetQueueDepth(CommKit.Priority.BULK)
            CommKit:GetBudget()
        end)
    end)
end)
