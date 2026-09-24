local TestEnv = require("BrokerKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("BrokerKit allocation", function()
    local BrokerKit
    local object
    before_each(function()
        BrokerKit = TestEnv.NewPackage()
        object = BrokerKit:New("MyAddon", { text = "Ready", value = 0 })
        BrokerKit:New("Other")
        BrokerKit:New("Third")
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing for a write of the same value", function()
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                object.text = "Ready"
                object:Set("value", 0)
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "same-value writes allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing for a changed write with per-attribute and any listeners", function()
        local fired = 0
        object:OnChange("text", function()
            fired = fired + 1
        end)
        object:OnChange(function()
            fired = fired + 1
        end)
        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                object.text = index % 2 == 0 and "Even" or "Odd"
                object:Set("value", index)
            end
        end)
        -- A text change fires its own list and the any list; a value change the any list.
        assert.are.equal(ITERATIONS * 3, fired)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "changed writes allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing for a changed write while exposed to LibDataBroker", function()
        local library = TestEnv.InstallLibDataBroker()
        BrokerKit:ExposeToLibDataBroker()
        local writes = library.attributeWrites
        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                object.value = index
            end
        end)
        assert.are.equal(writes + ITERATIONS, library.attributeWrites)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "exposed writes allocated " .. allocated .. " KiB"
        )
    end)

    it("allocates nothing for reads, Get and Iterate", function()
        local misses = 0
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                if
                    object.text ~= "Ready"
                    or object:Get("value") ~= 0
                    or object.name ~= "MyAddon"
                then
                    misses = misses + 1
                end
                if BrokerKit:Get("Other") == nil then
                    misses = misses + 1
                end
                for _, each in BrokerKit:Iterate() do
                    if each.name == nil then
                        misses = misses + 1
                    end
                end
            end
        end)
        assert.are.equal(0, misses)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "reads allocated " .. allocated .. " KiB")
    end)
end)
