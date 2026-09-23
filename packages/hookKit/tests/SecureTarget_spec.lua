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
