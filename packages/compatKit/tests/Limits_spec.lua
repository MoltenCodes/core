local Env = require("CompatKitTestEnv")

local DEFAULT_LIMITS = { maxShims = 64, maxProviders = 32, maxProviderKinds = 32 }

---The message `SetLimits` raises for an invalid value of `name`.
---@param name string
---@return string
local function invalidMessage(name)
    return "CompatKit:SetLimits limits."
        .. name
        .. " must be a positive integer or CompatKit.UNBOUNDED"
end

describe("CompatKit limits", function()
    local CompatKit

    before_each(function()
        CompatKit = Env.NewPackage()
    end)
    after_each(Env.Reset)

    ---Register `count` shims with distinct names.
    ---@param count integer
    ---@param prefix string
    local function registerShims(count, prefix)
        for index = 1, count do
            assert.is_true(CompatKit:Shim(prefix .. index, 1, function() end))
        end
    end

    it("reports the defaults through GetLimits, as a fresh table", function()
        assert.are.same(DEFAULT_LIMITS, CompatKit:GetLimits())
        local first = CompatKit:GetLimits()
        first.maxShims = 1
        assert.are_not.equal(first, CompatKit:GetLimits())
        assert.are.same(DEFAULT_LIMITS, CompatKit:GetLimits())
    end)

    it("refuses a shim beyond maxShims with full, and counts new names only", function()
        CompatKit:SetLimits({ maxShims = 2 })
        registerShims(2, "fix")
        assert.are.same({ false, "full" }, { CompatKit:Shim("fix3", 1, function() end) })
        -- A newer version of an existing name is not a new shim.
        assert.are.same({ true, "replaced" }, { CompatKit:Shim("fix1", 2, function() end) })
        assert.are.equal(2, #CompatKit:GetShims())
    end)

    it("counts skips waiting for their shim against maxShims", function()
        CompatKit:SetLimits({ maxShims = 2 })
        assert.is_true(CompatKit:SkipShim("a"))
        assert.is_true(CompatKit:SkipShim("b"))
        assert.is_true(CompatKit:SkipShim("b"))
        assert.are.same({ false, "full" }, { CompatKit:SkipShim("c") })
        -- The skipped name's shim takes over the slot its skip holds.
        assert.are.same({ true, "pending" }, { CompatKit:Shim("a", 1, function() end) })
        assert.are.same({ false, "full" }, { CompatKit:Shim("d", 1, function() end) })
        assert.are.same({ false, "full" }, { CompatKit:SkipShim("d") })
        -- Skipping a registered shim never needs a slot.
        assert.is_true(CompatKit:SkipShim("a"))
        assert.are.equal(1, #CompatKit:GetShims())
        CompatKit:SetLimits({ maxShims = CompatKit.UNBOUNDED })
        assert.is_true(CompatKit:SkipShim("c"))
        assert.is_true(CompatKit:Shim("d", 1, function() end))
    end)

    it("lifts maxShims with UNBOUNDED and reports the sentinel back", function()
        CompatKit:SetLimits({ maxShims = CompatKit.UNBOUNDED })
        assert.are.equal(CompatKit.UNBOUNDED, CompatKit:GetLimits().maxShims)
        registerShims(70, "fix")
        assert.are.equal(70, #CompatKit:GetShims())
    end)

    it("refuses a provider beyond maxProviders with full, per kind", function()
        CompatKit:SetLimits({ maxProviders = 1 })
        local output = CompatKit:Providers("output")
        local storage = CompatKit:Providers("storage")
        assert.is_true(output:Register("chat", "sink"))
        assert.are.same({ false, "full" }, { output:Register("frame", "sink") })
        assert.is_true(storage:Register("saved", "db"))
        -- Unregistering frees the slot.
        assert.is_true(output:Unregister("chat"))
        assert.is_true(output:Register("frame", "sink"))
    end)

    it("lifts maxProviders with UNBOUNDED", function()
        CompatKit:SetLimits({ maxProviders = CompatKit.UNBOUNDED })
        local output = CompatKit:Providers("output")
        for index = 1, 40 do
            assert.is_true(output:Register("sink" .. index, index))
        end
        assert.are.equal(40, #output:List())
    end)

    it("refuses a kind beyond maxProviderKinds at the caller, and lifts it", function()
        CompatKit:SetLimits({ maxProviderKinds = 1 })
        CompatKit:Providers("output")
        assert.are.equal(CompatKit:Providers("output"), CompatKit:Providers("output"))
        Env.expectErrorContaining("CompatKit:Providers refuses more than 1 kinds", function()
            CompatKit:Providers("storage")
        end)
        CompatKit:SetLimits({ maxProviderKinds = CompatKit.UNBOUNDED })
        assert.is_table(CompatKit:Providers("storage"))
    end)

    it("lowers a limit without removing what exists", function()
        registerShims(3, "fix")
        CompatKit:SetLimits({ maxShims = 1 })
        assert.are.equal(3, #CompatKit:GetShims())
        assert.are.same({ false, "full" }, { CompatKit:Shim("fix4", 1, function() end) })
    end)

    local invalidValues = {
        { label = "zero", value = 0 },
        { label = "a negative number", value = -3 },
        { label = "a fraction", value = 1.5 },
        { label = "infinity", value = math.huge },
        { label = "nan", value = 0 / 0 },
        { label = "a string", value = "64" },
        { label = "a table other than UNBOUNDED", value = {} },
    }
    for _, case in ipairs(invalidValues) do
        it("refuses " .. case.label .. " for every limit without changing anything", function()
            for _, name in ipairs({ "maxShims", "maxProviders", "maxProviderKinds" }) do
                Env.expectErrorContaining(invalidMessage(name), function()
                    CompatKit:SetLimits({ [name] = case.value })
                end)
            end
            assert.are.same(DEFAULT_LIMITS, CompatKit:GetLimits())
        end)
    end

    it("changes nothing when one value of several is invalid", function()
        local ok = pcall(CompatKit.SetLimits, CompatKit, { maxShims = 200, maxProviders = 0 })
        assert.is_false(ok)
        assert.are.same(DEFAULT_LIMITS, CompatKit:GetLimits())
    end)

    it("refuses an unknown limit, a non-string key and a non-table argument", function()
        Env.expectErrorContaining(
            "CompatKit:SetLimits limits.maxEntries is not a recognised limit",
            function()
                CompatKit:SetLimits({ maxEntries = 10 })
            end
        )
        Env.expectErrorContaining(
            "CompatKit:SetLimits limits.1 is not a recognised limit",
            function()
                CompatKit:SetLimits({ 10 })
            end
        )
        Env.expectErrorContaining("CompatKit:SetLimits limits must be a table", function()
            CompatKit:SetLimits(nil)
        end)
    end)

    it("refuses SetLimits called without the facade", function()
        Env.expectErrorContaining(
            "CompatKit:SetLimits must be called on the CompatKit facade; use CompatKit:SetLimits(...)",
            function()
                CompatKit.SetLimits({ maxShims = 5 })
            end
        )
    end)
end)
