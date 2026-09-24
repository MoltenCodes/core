local TestEnv = require("CacheKitTestEnv")

describe("CacheKit snapshots and secret values", function()
    after_each(TestEnv.Reset)

    ---Load the module chain on a host whose `issecretvalue` reports `secret`.
    ---@param secret table
    ---@return table CacheKit
    local function loadWithSecret(secret)
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return rawequal(value, secret)
        end)
        require("Registry")
        require("SignalKit")
        require("EventKit")
        return require("CacheKit")
    end

    it("refuses a secret key or value at the reader line", function()
        local secret = {}
        local CacheKit = loadWithSecret(secret)
        local source = debug.getinfo(1, "S").short_src

        local keyLine
        local keyed = CacheKit:NewSnapshot(function(fill)
            keyLine = debug.getinfo(1, "l").currentline + 1
            fill(secret, 1)
        end)
        local keyOk, keyValue = pcall(keyed.Refresh, keyed)
        assert.is_false(keyOk)
        assert.are.equal(
            source .. ":" .. keyLine .. ": CacheKit.Snapshot fill key must not be a secret value",
            keyValue
        )

        local valued = CacheKit:NewSnapshot(function(fill)
            fill("a", secret)
        end)
        TestEnv.expectErrorContaining(
            "CacheKit.Snapshot fill value must not be a secret value",
            function()
                valued:Refresh()
            end
        )
        assert.are.equal(0, valued:GetCount())
    end)

    it("refuses a secret limit value at the caller before comparing it", function()
        -- A number stands in for a secret number: without the probe asked
        -- first, it would pass as a valid limit.
        local CacheKit = loadWithSecret(37)
        local source = debug.getinfo(1, "S").short_src
        local cases = {
            {
                call = function()
                    CacheKit:NewLru({ maxEntries = 37 })
                end,
                message = "CacheKit:NewLru maxEntries must be a positive integer or CacheKit.UNBOUNDED",
            },
            {
                call = function()
                    CacheKit:Memoize(tostring, { maxEntries = 37 })
                end,
                message = "CacheKit:Memoize maxEntries must be a positive integer or CacheKit.UNBOUNDED",
            },
            {
                call = function()
                    CacheKit:NewQueue(37, "reject")
                end,
                message = "CacheKit:NewQueue capacity must be an integer from 1 to 1024 (CacheKit:SetLimits maxQueueCapacity)",
            },
            {
                call = function()
                    CacheKit:SetLimits({ maxQueueCapacity = 37 })
                end,
                message = "CacheKit:SetLimits limits.maxQueueCapacity must be an integer from 1 to 65536",
            },
        }
        for index = 1, #cases do
            local ok, value = pcall(cases[index].call)
            assert.is_false(ok)
            -- The position is the closure's line in this file: the caller's.
            assert.are.equal(source .. ":", value:sub(1, #source + 1))
            assert.is_truthy(value:find(cases[index].message, 1, true))
        end
        assert.are.equal(1024, CacheKit:GetLimits().maxQueueCapacity)
    end)

    it("stores and returns a secret value without comparing it", function()
        local secret = {}
        local CacheKit = loadWithSecret(secret)
        local cache = CacheKit:NewLru({ maxEntries = 4 })
        cache:Set("unit", secret)
        assert.are.equal(secret, cache:Get("unit"))
        assert.are.equal(secret, cache:Peek("unit"))

        local calls = 0
        local memoized = CacheKit:Memoize(function()
            calls = calls + 1
            return secret
        end, { maxEntries = 4 })
        assert.are.equal(secret, memoized("unit"))
        assert.are.equal(secret, memoized("unit"))
        assert.are.equal(1, calls)
    end)

    it("accepts ordinary values when the probe exists", function()
        local CacheKit = loadWithSecret({})
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fill("a", 1)
        end)
        local added = snapshot:Refresh()
        assert.are.same({ "a" }, added)
    end)
end)
