local Env = require("CompatKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file. A wrong `error` level shows up either as a different line
---number or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---Run `action` and assert it raised `message` at the line of the call
---inside `action`: the one statement on the line after `function()`.
---@param message string
---@param action fun()
local function assertRaisesAtCaller(message, action)
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assertReportedAt(line, message, ok, value)
end

describe("CompatKit error levels", function()
    local CompatKit

    before_each(function()
        CompatKit = Env.NewPackage()
    end)
    after_each(Env.Reset)

    it("points Shim argument errors at the caller", function()
        local noop = function() end
        assertRaisesAtCaller("CompatKit:Shim name must be a non-empty string", function()
            CompatKit:Shim("", 1, noop)
        end)
        assertRaisesAtCaller("CompatKit:Shim version must be a positive integer", function()
            CompatKit:Shim("fix", 0, noop)
        end)
        assertRaisesAtCaller("CompatKit:Shim version must be a positive integer", function()
            CompatKit:Shim("fix", 1.5, noop)
        end)
        assertRaisesAtCaller("CompatKit:Shim implementation must be a function", function()
            CompatKit:Shim("fix", 1, "later")
        end)
        assertRaisesAtCaller("CompatKit:Shim options must be a table or nil", function()
            CompatKit:Shim("fix", 1, noop, "retail")
        end)
        assertRaisesAtCaller('CompatKit:Shim options contains unknown field "flavors"', function()
            CompatKit:Shim("fix", 1, noop, { flavors = { "mainline" } })
        end)
        assertRaisesAtCaller("CompatKit:Shim options.description must be a string", function()
            CompatKit:Shim("fix", 1, noop, { description = 42 })
        end)
        assertRaisesAtCaller(
            "CompatKit:Shim options.flavours must be a non-empty array of flavour ids",
            function()
                CompatKit:Shim("fix", 1, noop, { flavours = {} })
            end
        )
        assertRaisesAtCaller(
            "CompatKit:Shim options.flavours contains an invalid flavour id",
            function()
                CompatKit:Shim("fix", 1, noop, { flavours = { "mainline", 7 } })
            end
        )
        assertRaisesAtCaller(
            "CompatKit:Shim options.covers must be a non-empty array of API names",
            function()
                CompatKit:Shim("fix", 1, noop, { covers = "C_TooltipInfo.GetUnit" })
            end
        )
        for _, invalidName in ipairs({
            "C_TooltipInfo GetUnit",
            "C_Foo.",
            "Foo.9Bar",
            ".Bar",
            "9Foo",
        }) do
            assertRaisesAtCaller(
                "CompatKit:Shim options.covers contains an invalid API name",
                function()
                    CompatKit:Shim("fix", 1, noop, { covers = { invalidName } })
                end
            )
        end
    end)

    it("points SkipShim, GetShims, Apply and Providers errors at the caller", function()
        assertRaisesAtCaller("CompatKit:SkipShim name must be a non-empty string", function()
            CompatKit:SkipShim(nil)
        end)
        assertRaisesAtCaller("CompatKit:Providers kind must be a non-empty string", function()
            CompatKit:Providers("")
        end)
        assertRaisesAtCaller(
            "CompatKit:GetShims must be called on the CompatKit facade; use CompatKit:GetShims(...)",
            function()
                CompatKit.GetShims()
            end
        )
        assertRaisesAtCaller(
            "CompatKit:Apply must be called on the CompatKit facade; use CompatKit:Apply(...)",
            function()
                CompatKit.Apply()
            end
        )
        assertRaisesAtCaller(
            "CompatKit:Shim must be called on the CompatKit facade; use CompatKit:Shim(...)",
            function()
                CompatKit.Shim("fix", 1, function() end)
            end
        )
        assertRaisesAtCaller(
            "CompatKit:SkipShim must be called on the CompatKit facade; use CompatKit:SkipShim(...)",
            function()
                CompatKit.SkipShim("fix")
            end
        )
        assertRaisesAtCaller(
            "CompatKit:Providers must be called on the CompatKit facade; use CompatKit:Providers(...)",
            function()
                CompatKit.Providers("output")
            end
        )
    end)

    it("points Apply re-entry at the caller inside the shim", function()
        local line
        local ok, value
        CompatKit:Shim("reentrant", 1, function()
            ok, value = pcall(function()
                line = currentLine() + 1
                CompatKit:Apply()
            end)
        end)
        CompatKit:Apply()
        assertReportedAt(line, "CompatKit:Apply cannot be called from inside a shim", ok, value)
    end)

    it("points provider registry argument and receiver errors at the caller", function()
        local registry = CompatKit:Providers("output")
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Register name must be a non-empty string",
            function()
                registry:Register(42, "sink")
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Register implementation must not be nil",
            function()
                registry:Register("chat", nil)
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Register probe must be a function or nil",
            function()
                registry:Register("chat", "sink", true)
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Register priority must be an integer",
            function()
                registry:Register("chat", "sink", nil, 1.5)
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Unregister name must be a non-empty string",
            function()
                registry:Unregister("")
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Resolve preferred must be a non-empty string",
            function()
                registry:Resolve(7)
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:Resolve must be called on a provider registry;"
                .. " use registry:Resolve(...)",
            function()
                registry.Resolve()
            end
        )
        assertRaisesAtCaller(
            "CompatKit.ProviderRegistry:List must be called on a provider registry;"
                .. " use registry:List(...)",
            function()
                registry.List({})
            end
        )
    end)

    it("points context helper argument errors at the shim's line", function()
        local line
        local ok, value
        CompatKit:Shim("probe", 1, function(context)
            ok, value = pcall(function()
                line = currentLine() + 1
                context.hasApi("")
            end)
        end)
        CompatKit:Apply()
        assertReportedAt(
            line,
            "CompatKit.ShimContext.hasApi name must be a non-empty string",
            ok,
            value
        )
    end)

    it("points SetLimits and GetLimits errors at the caller", function()
        assertRaisesAtCaller("CompatKit:SetLimits limits must be a table", function()
            CompatKit:SetLimits(64)
        end)
        assertRaisesAtCaller(
            "CompatKit:SetLimits limits.maxEntries is not a recognised limit",
            function()
                CompatKit:SetLimits({ maxEntries = 10 })
            end
        )
        assertRaisesAtCaller(
            "CompatKit:SetLimits limits.maxShims must be a positive integer or CompatKit.UNBOUNDED",
            function()
                CompatKit:SetLimits({ maxShims = 0 })
            end
        )
        assertRaisesAtCaller(
            "CompatKit:GetLimits must be called on the CompatKit facade; use CompatKit:GetLimits(...)",
            function()
                CompatKit.GetLimits()
            end
        )
    end)

    it("points a write into a read-only view at the writer", function()
        assertRaisesAtCaller(
            'CompatKit.CATALOGUE is read-only; field "extra" cannot be written',
            function()
                CompatKit.CATALOGUE.extra = true
            end
        )
        assertRaisesAtCaller(
            'CompatKit.CATALOGUE[1] is read-only; field "reason" cannot be written',
            function()
                CompatKit.CATALOGUE[1].reason = "none"
            end
        )
    end)
end)
