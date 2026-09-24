local Env = require("CompatKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CompatKit allocation", function()
    local CompatKit
    local registry

    before_each(function()
        CompatKit = Env.NewPackage()
        registry = CompatKit:Providers("output")
        registry:Register("chat", "chat-sink", nil, 0)
        registry:Register("dead", "dead-sink", function()
            return false
        end, 10)
        registry:Register("probed", "probed-sink", function()
            return true
        end, 5)
    end)
    after_each(Env.Reset)

    ---@param label string
    ---@param workload fun()
    local function assertAllocatesNothing(label, workload)
        workload()
        local allocated = Env.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                workload()
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            label .. " allocated " .. allocated .. " KiB"
        )
    end

    it("allocates nothing for a memoised Resolve", function()
        assert.are.same({ "probed-sink", "probed" }, { registry:Resolve() })
        assertAllocatesNothing("Resolve", function()
            registry:Resolve()
        end)
    end)

    it("allocates nothing for Resolve with a live or dead preferred provider", function()
        assertAllocatesNothing("Resolve(preferred)", function()
            registry:Resolve("chat")
            registry:Resolve("dead")
            registry:Resolve("unknown")
        end)
    end)

    it("allocates nothing for a cascade that finds no live provider", function()
        registry:Unregister("chat")
        registry:Unregister("probed")
        assert.are.same({ nil, "none" }, { registry:Resolve() })
        assertAllocatesNothing("Resolve with no live provider", function()
            registry:Resolve()
        end)
    end)

    it("allocates nothing for the cascade after the memoised provider dies", function()
        local highAlive, lowAlive = true, true
        registry:Register("high", "high-sink", function()
            return highAlive
        end, 20)
        registry:Register("low", "low-sink", function()
            return lowAlive
        end, 15)
        assert.are.same({ "high-sink", "high" }, { registry:Resolve() })
        assertAllocatesNothing("Resolve after the memo dies", function()
            highAlive, lowAlive = false, true
            registry:Resolve() -- the memo dies; the cascade answers "low"
            highAlive, lowAlive = true, false
            registry:Resolve() -- the memo dies again; the cascade answers "high"
        end)
    end)

    it("allocates nothing for a repeated Providers lookup", function()
        assertAllocatesNothing("Providers", function()
            CompatKit:Providers("output")
        end)
    end)
end)
