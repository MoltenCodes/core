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

    it("accepts ordinary values when the probe exists", function()
        local CacheKit = loadWithSecret({})
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fill("a", 1)
        end)
        local added = snapshot:Refresh()
        assert.are.same({ "a" }, added)
    end)
end)
