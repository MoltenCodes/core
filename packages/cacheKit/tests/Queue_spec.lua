local TestEnv = require("CacheKitTestEnv")

---Collect what `queue:Iterate()` yields, oldest first.
---@param queue table
---@return any[] values
local function contentsOf(queue)
    local values = {}
    for position, value in queue:Iterate() do
        values[position] = value
    end
    return values
end

describe("CacheKit queue", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("pushes, peeks and pops in first-in, first-out order", function()
        local queue = CacheKit:NewQueue(3, "reject")
        assert.are.equal(3, queue:GetCapacity())
        assert.are.equal(0, queue:GetCount())
        assert.is_nil(queue:Peek())
        assert.is_nil(queue:Pop())

        assert.is_true(queue:Push("a"))
        assert.is_true(queue:Push("b"))
        assert.are.equal(2, queue:GetCount())
        assert.are.equal("a", queue:Peek())
        assert.are.equal("a", queue:Pop())
        assert.are.equal("b", queue:Pop())
        assert.is_nil(queue:Pop())
        assert.are.equal(0, queue:GetCount())
    end)

    it("stores false as an ordinary value", function()
        local queue = CacheKit:NewQueue(2, "reject")
        assert.is_true(queue:Push(false))
        assert.are.equal(1, queue:GetCount())
        assert.is_false(queue:Peek())
        assert.is_false(queue:Pop())
        assert.are.equal(0, queue:GetCount())
    end)

    it("wraps around the ring", function()
        local queue = CacheKit:NewQueue(3, "reject")
        for round = 1, 10 do
            assert.is_true(queue:Push(round))
            assert.is_true(queue:Push(round * 10))
            assert.are.equal(round, queue:Pop())
            assert.are.equal(round * 10, queue:Pop())
        end
        assert.are.equal(0, queue:GetCount())
        queue:Push("x")
        queue:Push("y")
        queue:Push("z")
        assert.are.same({ "x", "y", "z" }, contentsOf(queue))
    end)

    it("drops the oldest value under dropOldest", function()
        local queue = CacheKit:NewQueue(2, "dropOldest")
        queue:Push("a")
        queue:Push("b")
        local stored, dropped = queue:Push("c")
        assert.is_true(stored)
        assert.are.equal("a", dropped)
        assert.are.equal(2, queue:GetCount())
        assert.are.same({ "b", "c" }, contentsOf(queue))
        assert.are.equal("b", queue:Pop())
        assert.are.equal("c", queue:Pop())
    end)

    it("drops the pushed value under dropNewest", function()
        local queue = CacheKit:NewQueue(2, "dropNewest")
        queue:Push("a")
        queue:Push("b")
        local stored, dropped = queue:Push("c")
        assert.is_false(stored)
        assert.are.equal("c", dropped)
        assert.are.same({ "a", "b" }, contentsOf(queue))
    end)

    it("stores nothing and drops nothing under reject", function()
        local queue = CacheKit:NewQueue(2, "reject")
        queue:Push("a")
        queue:Push("b")
        local stored, dropped = queue:Push("c")
        assert.is_false(stored)
        assert.is_nil(dropped)
        assert.are.same({ "a", "b" }, contentsOf(queue))

        queue:Pop()
        assert.is_true(queue:Push("c"))
        assert.are.same({ "b", "c" }, contentsOf(queue))
    end)

    it("iterates from oldest to newest across the wrap point", function()
        local queue = CacheKit:NewQueue(4, "dropOldest")
        for value = 1, 6 do
            queue:Push(value)
        end
        assert.are.same({ 3, 4, 5, 6 }, contentsOf(queue))
        queue:Pop()
        assert.are.same({ 4, 5, 6 }, contentsOf(queue))
        assert.are.same({}, contentsOf(CacheKit:NewQueue(1, "reject")))
    end)

    it("clears every value and forgets what it held", function()
        local queue = CacheKit:NewQueue(3, "dropOldest")
        local marker = {}
        queue:Push(marker)
        queue:Push(2)
        queue:Push(3)
        queue:Push(4)

        assert.are.equal(3, queue:Clear())
        assert.are.equal(0, queue:GetCount())
        assert.is_nil(queue:Peek())
        for index = 1, 3 do
            assert.is_false(queue._slots[index])
        end
        assert.are.equal(0, queue:Clear())

        queue:Push("again")
        assert.are.same({ "again" }, contentsOf(queue))
    end)

    it("does not retain a popped value", function()
        local queue = CacheKit:NewQueue(2, "reject")
        local marker = {}
        queue:Push(marker)
        queue:Pop()
        assert.is_false(queue._slots[1])
    end)

    it("works with a capacity of one", function()
        local queue = CacheKit:NewQueue(1, "dropOldest")
        assert.is_true(queue:Push("a"))
        local stored, dropped = queue:Push("b")
        assert.is_true(stored)
        assert.are.equal("a", dropped)
        assert.are.equal("b", queue:Pop())
        assert.is_nil(queue:Pop())
    end)

    it("validates its constructor arguments", function()
        for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", 1025 }) do
            TestEnv.expectErrorContaining(
                "CacheKit:NewQueue capacity must be an integer from 1 to 1024 "
                    .. "(CacheKit:SetLimits maxQueueCapacity)",
                function()
                    CacheKit:NewQueue(invalid, "reject")
                end
            )
        end
        TestEnv.expectErrorContaining(
            "CacheKit:NewQueue capacity cannot be CacheKit.UNBOUNDED: "
                .. "the ring is allocated when the queue is created",
            function()
                CacheKit:NewQueue(CacheKit.UNBOUNDED, "reject")
            end
        )
        for _, invalid in ipairs({ "dropoldest", "drop", 1, {}, true }) do
            TestEnv.expectErrorContaining(
                'CacheKit:NewQueue overflow must be "dropOldest", "dropNewest" or "reject"',
                function()
                    CacheKit:NewQueue(4, invalid)
                end
            )
        end
        TestEnv.expectErrorContaining("CacheKit:NewQueue overflow must be", function()
            CacheKit:NewQueue(4)
        end)
    end)

    it("refuses a nil value and a missing receiver", function()
        local queue = CacheKit:NewQueue(2, "reject")
        TestEnv.expectErrorContaining("CacheKit.Queue:Push value must not be nil", function()
            queue:Push(nil)
        end)
        assert.are.equal(0, queue:GetCount())
        TestEnv.expectErrorContaining(
            "CacheKit.Queue:Pop must be called on a CacheKit queue",
            function()
                queue.Pop()
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit.Queue:Iterate must be called on a CacheKit queue",
            function()
                CacheKit.Queue.Iterate(CacheKit:NewLru({ maxEntries = 1 }))
            end
        )
    end)

    it("matches a naive array model over a deterministic workload", function()
        local capacity = 5
        local seed = 11
        local function nextRandom(limit)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed % limit + 1
        end

        for _, policy in ipairs({ "dropOldest", "dropNewest", "reject" }) do
            local queue = CacheKit:NewQueue(capacity, policy)
            local model = {}
            for step = 1, 1000 do
                local action = nextRandom(10)
                if action <= 6 then
                    local stored, dropped = queue:Push(step)
                    if #model < capacity then
                        model[#model + 1] = step
                        assert.is_true(stored)
                        assert.is_nil(dropped)
                    elseif policy == "dropOldest" then
                        local oldest = table.remove(model, 1)
                        model[#model + 1] = step
                        assert.is_true(stored)
                        assert.are.equal(oldest, dropped)
                    elseif policy == "dropNewest" then
                        assert.is_false(stored)
                        assert.are.equal(step, dropped)
                    else
                        assert.is_false(stored)
                        assert.is_nil(dropped)
                    end
                elseif action <= 9 then
                    assert.are.equal(model[1], queue:Pop())
                    table.remove(model, 1)
                else
                    assert.are.equal(#model, queue:Clear())
                    model = {}
                end
                assert.are.equal(#model, queue:GetCount())
                assert.are.equal(model[1], queue:Peek())
                assert.are.same(model, contentsOf(queue))
            end
        end
    end)
end)
