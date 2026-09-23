local TestEnv = require("HookKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into HookKit. A wrong `error` level shows up either as
---a different line number or as a message with no `file:line` prefix at all.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into HookKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
    local expectedLine = nil
    local function mark()
        expectedLine = debug.getinfo(2, "l").currentline + 1
    end
    local ok, value = pcall(action, mark)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local function noop() end

describe("HookKit error levels", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("points package argument errors at the caller", function()
        assertReportedAtCaller(
            "HookKit:ForAddon addonName must be a non-empty string",
            function(mark)
                mark()
                HookKit:ForAddon("")
            end
        )
        assertReportedAtCaller(
            "HookKit:CloseAddonScopes addonName must be a non-empty string",
            function(mark)
                mark()
                HookKit:CloseAddonScopes(nil)
            end
        )
    end)

    it("points every scope method's receiver error at the caller", function()
        local scope = HookKit:CreateScope()
        local methods = {
            "SecureHook",
            "SecureHookScript",
            "Hook",
            "RawHook",
            "HookScript",
            "RawHookScript",
            "Unhook",
            "UnhookAll",
            "IsHooked",
            "Original",
            "Hooks",
            "Close",
            "IsClosed",
            "GetActiveCount",
            "GetAddonName",
        }
        for _, method in ipairs(methods) do
            assertReportedAtCaller(
                "HookKit.Scope:" .. method .. " must be called on a HookKit scope",
                function(mark)
                    mark()
                    scope[method]({}, {}, "Method", noop)
                end
            )
        end
    end)

    it("points field-hook argument errors at the caller", function()
        local scope = HookKit:CreateScope()
        local target = { Method = noop, Secure = TestEnv.MarkSecure(function() end) }
        for _, method in ipairs({ "Hook", "RawHook", "SecureHook" }) do
            local prefix = "HookKit.Scope:" .. method
            assertReportedAtCaller(prefix .. " object must be a table", function(mark)
                mark()
                scope[method](scope, 1, "Method", noop)
            end)
            assertReportedAtCaller(prefix .. " method must be a non-empty string", function(mark)
                mark()
                scope[method](scope, target, "", noop)
            end)
            assertReportedAtCaller(prefix .. " handler must be a function", function(mark)
                mark()
                scope[method](scope, target, "Method", "not a function")
            end)
            assertReportedAtCaller(prefix .. ' target "Missing" is not a function', function(mark)
                mark()
                scope[method](scope, target, "Missing", noop)
            end)
        end

        scope:Hook(target, "Method", noop)
        assertReportedAtCaller(
            'HookKit.Scope:RawHook "Method" is already hooked in this scope; Unhook it first',
            function(mark)
                mark()
                scope:RawHook(target, "Method", noop)
            end
        )
        assertReportedAtCaller("HookKit.Scope:Hook options must be a table", function(mark)
            mark()
            scope:Hook(target, "Secure", noop, 1)
        end)
        assertReportedAtCaller(
            'HookKit.Scope:Hook refuses to hook secure "Secure" non-securely; '
                .. "use SecureHook, or pass options.forceSecure",
            function(mark)
                mark()
                scope:Hook(target, "Secure", noop)
            end
        )
        assertReportedAtCaller(
            'HookKit.Scope:RawHook refuses to hook secure "Secure" non-securely; '
                .. "use SecureHook, or pass options.forceSecure",
            function(mark)
                mark()
                scope:RawHook(target, "Secure", noop)
            end
        )
    end)

    it("points script-hook argument errors at the caller", function()
        local scope = HookKit:CreateScope()
        local frame = TestEnv.NewFrame()
        local protected = TestEnv.NewFrame({ protected = true })
        for _, method in ipairs({ "HookScript", "RawHookScript", "SecureHookScript" }) do
            local prefix = "HookKit.Scope:" .. method
            assertReportedAtCaller(prefix .. " frame must be a table", function(mark)
                mark()
                scope[method](scope, "frame", "OnShow", noop)
            end)
            assertReportedAtCaller(prefix .. " script must be a non-empty string", function(mark)
                mark()
                scope[method](scope, frame, 1, noop)
            end)
            assertReportedAtCaller(prefix .. " handler must be a function", function(mark)
                mark()
                scope[method](scope, frame, "OnShow", nil)
            end)
        end
        assertReportedAtCaller(
            "HookKit.Scope:SecureHookScript frame must have a HookScript method",
            function(mark)
                mark()
                scope:SecureHookScript({}, "OnShow", noop)
            end
        )
        assertReportedAtCaller(
            'HookKit.Scope:HookScript refuses to replace protected script "OnClick" '
                .. "of a protected frame; use SecureHookScript",
            function(mark)
                mark()
                scope:HookScript(protected, "OnClick", noop)
            end
        )
        assertReportedAtCaller(
            'HookKit.Scope:RawHookScript refuses to replace script "OnShow" of a protected '
                .. "frame; use SecureHookScript, or pass options.forceSecure",
            function(mark)
                mark()
                scope:RawHookScript(protected, "OnShow", noop)
            end
        )
        TestEnv.SetCombatLockdown(true)
        assertReportedAtCaller(
            "HookKit.Scope:HookScript cannot replace a script of a protected frame during combat lockdown",
            function(mark)
                mark()
                scope:HookScript(protected, "OnShow", noop, { forceSecure = true })
            end
        )
        TestEnv.SetCombatLockdown(false)
        scope:HookScript(frame, "OnShow", noop)
        assertReportedAtCaller(
            'HookKit.Scope:SecureHookScript "OnShow" is already hooked in this scope; Unhook it first',
            function(mark)
                mark()
                scope:SecureHookScript(frame, "OnShow", noop)
            end
        )
    end)

    it("points the review-added refusals at the caller", function()
        local scope = HookKit:CreateScope()
        local frame = TestEnv.NewFrame()
        HookKit:CreateScope():SecureHookScript(frame, "OnShow", noop)
        assertReportedAtCaller(
            'HookKit.Scope:HookScript refuses to replace script "OnShow": HookKit holds a '
                .. "SecureHookScript post-hook on it, which SetScript may drop; Unhook it first, "
                .. "or install the pre-hook before the post-hook",
            function(mark)
                mark()
                scope:HookScript(frame, "OnShow", noop)
            end
        )
        assertReportedAtCaller(
            "HookKit.Scope:RawHookScript frame is forbidden or not accessible in this context",
            function(mark)
                mark()
                scope:RawHookScript(TestEnv.NewFrame({ forbidden = true }), "OnShow", noop)
            end
        )
        assertReportedAtCaller(
            "HookKit:ForAddon must be called on the HookKit facade; use HookKit:ForAddon(...)",
            function(mark)
                mark()
                HookKit.ForAddon("MyAddon")
            end
        )
        assertReportedAtCaller(
            "HookKit:CloseAddonScopes must be called on the HookKit facade; "
                .. "use HookKit:CloseAddonScopes(...)",
            function(mark)
                mark()
                HookKit.CloseAddonScopes("MyAddon")
            end
        )
    end)

    it("points a hook attempt on a closed scope at the caller", function()
        local scope = HookKit:CreateScope()
        scope:Close()
        assertReportedAtCaller("HookKit.Scope:Hook cannot hook in a closed scope", function(mark)
            mark()
            scope:Hook({ Method = noop }, "Method", noop)
        end)
        assertReportedAtCaller(
            "HookKit.Scope:SecureHookScript cannot hook in a closed scope",
            function(mark)
                mark()
                scope:SecureHookScript(TestEnv.NewFrame(), "OnShow", noop)
            end
        )
    end)

    it("points lookup argument errors at the caller", function()
        local scope = HookKit:CreateScope()
        for _, method in ipairs({ "Unhook", "IsHooked", "Original" }) do
            local prefix = "HookKit.Scope:" .. method
            assertReportedAtCaller(prefix .. " object must be a table", function(mark)
                mark()
                scope[method](scope, 1, "Method")
            end)
            assertReportedAtCaller(prefix .. " method must be a non-empty string", function(mark)
                mark()
                scope[method](scope, {}, nil)
            end)
            assertReportedAtCaller(
                prefix .. " globalName must be a non-empty string",
                function(mark)
                    mark()
                    scope[method](scope, "")
                end
            )
        end
    end)

    it("points the missing-host error at the caller", function()
        local WithoutHost = TestEnv.NewPackageWithoutHookApi()
        local scope = WithoutHost:CreateScope()
        assertReportedAtCaller(
            "HookKit.Scope:SecureHook requires the host's hooksecurefunc",
            function(mark)
                mark()
                scope:SecureHook({ Method = noop }, "Method", noop)
            end
        )
    end)
end)
