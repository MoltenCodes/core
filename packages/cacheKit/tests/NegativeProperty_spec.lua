local TestEnv = require("CacheKitTestEnv")

---A naive model of a TTL cache with negative entries: every key records what
---it holds (`value` or the negative marker) and the millisecond at which it
---expires, checked against a clock the spec advances. Recency and eviction
---are outside this model, so the cache is opened unbounded.
---@return table model
local function newModel()
    local NEGATIVE = {}
    local model = { entries = {}, nowMs = 0, NEGATIVE = NEGATIVE }

    local function live(entry)
        return entry ~= nil and model.nowMs < entry.expiresAtMs
    end

    function model.Set(key, value, ttlMs)
        model.entries[key] = { value = value, expiresAtMs = model.nowMs + ttlMs }
    end

    function model.PutNegative(key, ttlMs)
        model.entries[key] = { value = NEGATIVE, expiresAtMs = model.nowMs + ttlMs }
    end

    ---What `Get` or `Peek` answers: the value, or `nil` plus the outcome.
    function model.Read(key)
        local entry = model.entries[key]
        if not live(entry) then
            return nil, nil
        end
        if entry.value == NEGATIVE then
            return nil, "negative"
        end
        return entry.value, nil
    end

    ---`Get` also removes an expired entry; `Peek` leaves it stored.
    function model.Get(key)
        local entry = model.entries[key]
        if entry ~= nil and not live(entry) then
            model.entries[key] = nil
        end
        return model.Read(key)
    end

    function model.Delete(key)
        local removed = model.entries[key] ~= nil
        model.entries[key] = nil
        return removed
    end

    function model.Clear()
        local count = model.Count()
        model.entries = {}
        return count
    end

    function model.Count()
        local count = 0
        for _ in pairs(model.entries) do
            count = count + 1
        end
        return count
    end

    return model
end

describe("CacheKit negative entry property", function()
    after_each(TestEnv.Reset)

    it("matches a naive TTL model over 5,000 deterministic operations", function()
        local CacheKit = TestEnv.NewPackage()
        local cacheTtlMs = 2500
        local cache = CacheKit:NewTtl({
            maxEntries = CacheKit.UNBOUNDED,
            ttlSeconds = cacheTtlMs / 1000,
        })
        local model = newModel()
        local keys = { "a", "b", "c", "d", "e", "f", "g", "h" }

        local seed = 424242
        local function nextRandom(limit)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed % limit + 1
        end

        for step = 1, 5000 do
            local key = keys[nextRandom(#keys)]
            local operation = nextRandom(12)
            if operation <= 3 then
                local value, outcome = cache:Get(key)
                local expectedValue, expectedOutcome = model.Get(key)
                assert.are.equal(expectedValue, value, "Get value at step " .. step)
                assert.are.equal(expectedOutcome, outcome, "Get outcome at step " .. step)
            elseif operation <= 5 then
                cache:Set(key, step)
                model.Set(key, step, cacheTtlMs)
            elseif operation <= 8 then
                local ttlSeconds = nextRandom(3)
                cache:PutNegative(key, ttlSeconds)
                model.PutNegative(key, ttlSeconds * 1000)
            elseif operation == 9 then
                assert.are.equal(model.Delete(key), cache:Delete(key), "Delete at step " .. step)
            elseif operation == 10 then
                assert.are.equal(model.Clear(), cache:Clear(), "Clear at step " .. step)
            else
                local milliseconds = nextRandom(1500)
                TestEnv.AdvanceMs(milliseconds)
                model.nowMs = model.nowMs + milliseconds
            end

            assert.are.equal(model.Count(), cache:GetCount(), "count at step " .. step)
            for index = 1, #keys do
                local expectedValue, expectedOutcome = model.Read(keys[index])
                local value, outcome = cache:Peek(keys[index])
                assert.are.equal(expectedValue, value, "Peek value at step " .. step)
                assert.are.equal(expectedOutcome, outcome, "Peek outcome at step " .. step)
            end
        end
    end)
end)
