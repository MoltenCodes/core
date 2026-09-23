local TestEnv = require("HookKitTestEnv")

local GLOBAL_NAME = "HookKitSpecSecureTarget"

describe("HookKit secure-target refusal", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(function()
        TestEnv.SetGlobal(GLOBAL_NAME, nil)
        TestEnv.Reset()
    end)

    it("refuses a non-secure hook of a secure method", function()
        local target = { Method = TestEnv.MarkSecure(function() end) }
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining(
            'HookKit.Scope:Hook refuses to hook secure "Method" non-securely; '
                .. "use SecureHook, or pass options.forceSecure",
            function()
                scope:Hook(target, "Method", function() end)
            end
        )
        TestEnv.expectErrorContaining(
            'HookKit.Scope:RawHook refuses to hook secure "Method" non-securely',
            function()
                scope:RawHook(target, "Method", function() end)
            end
        )
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_true(scope:SecureHook(target, "Method", function() end))
    end)

    it("refuses a secure global and accepts forceSecure", function()
        local original = TestEnv.MarkSecure(function()
            return "secure"
        end)
        TestEnv.SetGlobal(GLOBAL_NAME, original)
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining('refuses to hook secure "' .. GLOBAL_NAME .. '"', function()
            scope:Hook(GLOBAL_NAME, function() end)
        end)

        assert.is_true(scope:Hook(GLOBAL_NAME, function() end, { forceSecure = true }))
        assert.are.equal("secure", TestEnv.GetGlobal(GLOBAL_NAME)())
    end)

    it("remembers the secure status from before the first non-secure hook", function()
        local target = { Method = TestEnv.MarkSecure(function() end) }
        local forced = HookKit:CreateScope()
        forced:Hook(target, "Method", function() end, { forceSecure = true })

        -- The field now holds addon code, so the host reports it as insecure;
        -- another scope must still be refused.
        local isSecureVariable = TestEnv.GetGlobal("issecurevariable")
        assert.is_false(isSecureVariable(target, "Method"))
        local other = HookKit:CreateScope()
        TestEnv.expectErrorContaining('refuses to hook secure "Method"', function()
            other:Hook(target, "Method", function() end)
        end)

        -- Also after the forced hook is gone.
        forced:Unhook(target, "Method")
        TestEnv.expectErrorContaining('refuses to hook secure "Method"', function()
            other:RawHook(target, "Method", function() end)
        end)
    end)

    it("treats nothing as secure on a host without issecurevariable", function()
        local WithoutHost = TestEnv.NewPackageWithoutHookApi()
        local target = { Method = TestEnv.MarkSecure(function() end) }
        assert.is_true(WithoutHost:CreateScope():Hook(target, "Method", function() end))
    end)

    it("refuses bad options", function()
        local scope = HookKit:CreateScope()
        local target = { Method = function() end }
        TestEnv.expectErrorContaining("HookKit.Scope:Hook options must be a table", function()
            scope:Hook(target, "Method", function() end, true)
        end)
        TestEnv.expectErrorContaining(
            'HookKit.Scope:Hook options contains unknown field "force"',
            function()
                scope:Hook(target, "Method", function() end, { force = true })
            end
        )
        TestEnv.expectErrorContaining(
            "HookKit.Scope:Hook options.forceSecure must be a boolean",
            function()
                scope:Hook(target, "Method", function() end, { forceSecure = "yes" })
            end
        )
    end)
end)

describe("HookKit secure status of inherited methods", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("uses a stub that reports an absent raw key as secure, as the client does", function()
        local isSecureVariable = TestEnv.GetGlobal("issecurevariable")
        local object = setmetatable({}, { __index = { Method = function() end } })
        assert.is_true(isSecureVariable(object, "Method"))
    end)

    it("asks about the table that holds an inherited addon method", function()
        local mixin = { Refresh = function() end }
        local base = setmetatable({}, { __index = mixin })
        local object = setmetatable({}, { __index = base })
        local scope = HookKit:CreateScope()
        assert.is_true(scope:Hook(object, "Refresh", function() end))
        assert.is_true(scope:RawHook(TestEnv.NewFrame(), "Show", function() end))
    end)

    it("refuses a method inherited from a secure table", function()
        local secureMethods = { Show = TestEnv.MarkSecure(function() end) }
        local frame = setmetatable({}, { __index = secureMethods })
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining('refuses to hook secure "Show"', function()
            scope:Hook(frame, "Show", function() end)
        end)
        assert.is_true(scope:Hook(frame, "Show", function() end, { forceSecure = true }))
    end)

    it("treats a method behind an __index function as not secure-checkable", function()
        local secureMethod = TestEnv.MarkSecure(function() end)
        local object = setmetatable({}, {
            __index = function()
                return secureMethod
            end,
        })
        assert.is_true(HookKit:CreateScope():Hook(object, "Method", function() end))
    end)

    it("stops following an __index chain deeper than eight tables", function()
        local holder = { Method = TestEnv.MarkSecure(function() end) }
        local current = holder
        for _ = 1, 9 do
            current = setmetatable({}, { __index = current })
        end
        assert.is_true(HookKit:CreateScope():Hook(current, "Method", function() end))
    end)
end)
