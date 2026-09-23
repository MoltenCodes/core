local TestEnv = require("HookKitTestEnv")

describe("HookKit script pre-hooks and replacements", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("runs the handler before the previous script and returns its result", function()
        local calls = {}
        local frame = TestEnv.NewFrame()
        frame:SetScript("OnShow", function(_, value)
            calls[#calls + 1] = "previous " .. value
            return "previous result"
        end)
        local scope = HookKit:CreateScope()
        assert.is_true(scope:HookScript(frame, "OnShow", function(receiver, value)
            assert.are.equal(frame, receiver)
            calls[#calls + 1] = "handler " .. value
        end))

        assert.are.equal("previous result", TestEnv.RunScript(frame, "OnShow", "a"))
        assert.are.same({ "handler a", "previous a" }, calls)
        assert.are.equal("hookScript", select(2, scope:IsHooked(frame, "OnShow")))
    end)

    it("hooks a script that had no handler and restores nil on Unhook", function()
        local calls = 0
        local frame = TestEnv.NewFrame()
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnHide", function()
            calls = calls + 1
        end)
        assert.is_nil(scope:Original(frame, "OnHide"))

        TestEnv.RunScript(frame, "OnHide")
        assert.are.equal(1, calls)
        assert.is_true(scope:Unhook(frame, "OnHide"))
        assert.is_nil(frame:GetScript("OnHide"))
    end)

    it("restores the previous script on Unhook while it is still installed", function()
        local frame = TestEnv.NewFrame()
        local previous = function() end
        frame:SetScript("OnShow", previous)
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnShow", function() end)

        scope:Unhook(frame, "OnShow")
        assert.are.equal(previous, frame:GetScript("OnShow"))
    end)

    it("stays inert when another addon replaced the script after us", function()
        local calls = {}
        local frame = TestEnv.NewFrame()
        frame:SetScript("OnShow", function()
            calls[#calls + 1] = "previous"
        end)
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnShow", function()
            calls[#calls + 1] = "ours"
        end)
        local ours = frame:GetScript("OnShow")
        local foreign = function(...)
            calls[#calls + 1] = "foreign"
            return ours(...)
        end
        frame:SetScript("OnShow", foreign)

        scope:Unhook(frame, "OnShow")
        assert.are.equal(foreign, frame:GetScript("OnShow"))
        TestEnv.RunScript(frame, "OnShow")
        assert.are.same({ "foreign", "previous" }, calls)
    end)

    it("replaces a script with RawHookScript, passing the previous one first", function()
        local frame = TestEnv.NewFrame()
        local previous = function()
            return "previous"
        end
        frame:SetScript("OnEnter", previous)
        local scope = HookKit:CreateScope()
        assert.is_true(scope:RawHookScript(frame, "OnEnter", function(original, receiver)
            assert.are.equal(previous, original)
            assert.are.equal(frame, receiver)
            return "replaced"
        end))

        assert.are.equal("replaced", TestEnv.RunScript(frame, "OnEnter"))
        assert.are.equal(previous, scope:Original(frame, "OnEnter"))
        assert.are.equal("rawHookScript", select(2, scope:IsHooked(frame, "OnEnter")))
        scope:Unhook(frame, "OnEnter")
        assert.are.equal("previous", TestEnv.RunScript(frame, "OnEnter"))
    end)

    it("refuses a protected script of a protected frame, even with forceSecure", function()
        local frame = TestEnv.NewFrame({ protected = true })
        local scope = HookKit:CreateScope()
        for _, script in ipairs({
            "OnClick",
            "PreClick",
            "PostClick",
            "OnDoubleClick",
            "OnAttributeChanged",
        }) do
            TestEnv.expectErrorContaining(
                'HookKit.Scope:HookScript refuses to replace protected script "'
                    .. script
                    .. '" of a protected frame; use SecureHookScript',
                function()
                    scope:HookScript(frame, script, function() end, { forceSecure = true })
                end
            )
        end
        TestEnv.expectErrorContaining(
            'HookKit.Scope:RawHookScript refuses to replace protected script "OnClick"',
            function()
                scope:RawHookScript(frame, "OnClick", function() end)
            end
        )
        assert.are.equal(0, scope:GetActiveCount())
        assert.is_nil(frame:GetScript("OnClick"))
    end)

    it("hooks a protected script of a frame that is not protected", function()
        local plain = TestEnv.NewFrame()
        local withoutProbe = TestEnv.NewFrame({ withoutIsProtected = true })
        local scope = HookKit:CreateScope()
        assert.is_true(scope:HookScript(plain, "OnClick", function() end))
        assert.is_true(scope:HookScript(withoutProbe, "OnClick", function() end))
    end)

    it("needs forceSecure for any other script of a protected frame", function()
        local frame = TestEnv.NewFrame({ protected = true })
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining(
            'HookKit.Scope:HookScript refuses to replace script "OnShow" of a protected frame; '
                .. "use SecureHookScript, or pass options.forceSecure",
            function()
                scope:HookScript(frame, "OnShow", function() end)
            end
        )
        assert.is_true(scope:HookScript(frame, "OnShow", function() end, { forceSecure = true }))
    end)

    it("refuses to replace a protected frame's script in combat lockdown", function()
        local frame = TestEnv.NewFrame({ protected = true })
        local scope = HookKit:CreateScope()
        TestEnv.SetCombatLockdown(true)
        TestEnv.expectErrorContaining(
            "HookKit.Scope:HookScript cannot replace a script of a protected frame during combat lockdown",
            function()
                scope:HookScript(frame, "OnShow", function() end, { forceSecure = true })
            end
        )
    end)

    it("leaves the closure inert rather than calling SetScript in combat lockdown", function()
        local calls = {}
        local frame = TestEnv.NewFrame({ protected = true })
        local previous = function()
            calls[#calls + 1] = "previous"
        end
        frame:SetScript("OnShow", previous)
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnShow", function()
            calls[#calls + 1] = "ours"
        end, { forceSecure = true })
        local ours = frame:GetScript("OnShow")

        TestEnv.SetCombatLockdown(true)
        assert.is_true(scope:Unhook(frame, "OnShow"))
        assert.are.equal(ours, frame:GetScript("OnShow"))
        TestEnv.RunScript(frame, "OnShow")
        assert.are.same({ "previous" }, calls)
    end)

    it("records nothing when the host refuses SetScript", function()
        local frame = TestEnv.NewFrame()
        local scope = HookKit:CreateScope()
        frame.SetScript = function()
            error("unknown script", 0)
        end
        local ok, value = pcall(scope.HookScript, scope, frame, "OnBogus", function() end)
        assert.is_false(ok)
        assert.are.equal("unknown script", value)
        assert.is_false((scope:IsHooked(frame, "OnBogus")))
    end)

    it("refuses a frame without GetScript or SetScript", function()
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining(
            "HookKit.Scope:HookScript frame must have a GetScript method",
            function()
                scope:HookScript({}, "OnShow", function() end)
            end
        )
    end)
end)

describe("HookKit script replacement next to secure script hooks", function()
    local HookKit
    before_each(function()
        HookKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("refuses a pre-hook of a script HookKit secure-hooked in any scope", function()
        local frame = TestEnv.NewFrame()
        local secure = HookKit:CreateScope()
        local other = HookKit:CreateScope()
        secure:SecureHookScript(frame, "OnShow", function() end)

        for _, method in ipairs({ "HookScript", "RawHookScript" }) do
            TestEnv.expectErrorContaining(
                "HookKit.Scope:"
                    .. method
                    .. ' refuses to replace script "OnShow": HookKit holds a SecureHookScript'
                    .. " post-hook on it, which SetScript may drop",
                function()
                    other[method](other, frame, "OnShow", function() end)
                end
            )
        end
        assert.is_nil(frame:GetScript("OnShow"))

        secure:Unhook(frame, "OnShow")
        assert.is_true(other:HookScript(frame, "OnShow", function() end))
    end)

    it("allows the post-hook after the pre-hook", function()
        local calls = {}
        local frame = TestEnv.NewFrame()
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnShow", function()
            calls[#calls + 1] = "pre"
        end)
        HookKit:CreateScope():SecureHookScript(frame, "OnShow", function()
            calls[#calls + 1] = "post"
        end)
        TestEnv.RunScript(frame, "OnShow")
        assert.are.same({ "pre", "post" }, calls)
    end)

    it("keeps a later SecureHookScript post-hook when the pre-hook under it is released", function()
        local calls = {}
        local frame = TestEnv.NewFrame()
        frame:SetScript("OnShow", function()
            calls[#calls + 1] = "original"
        end)
        local scope = HookKit:CreateScope()
        scope:HookScript(frame, "OnShow", function()
            calls[#calls + 1] = "pre"
        end)
        local installed = frame:GetScript("OnShow")
        local secure = HookKit:CreateScope()
        secure:SecureHookScript(frame, "OnShow", function()
            calls[#calls + 1] = "post"
        end)

        -- Restoring with SetScript would drop the post-hook, so the pre-hook
        -- stays installed, inert, forwarding to the original.
        assert.is_true(scope:Unhook(frame, "OnShow"))
        assert.are.equal(installed, frame:GetScript("OnShow"))
        TestEnv.RunScript(frame, "OnShow")
        assert.are.same({ "original", "post" }, calls)

        -- Once the post-hook is released too, nothing is left to protect.
        secure:Unhook(frame, "OnShow")
        local again = HookKit:CreateScope()
        again:HookScript(frame, "OnShow", function() end)
        assert.is_true(again:Unhook(frame, "OnShow"))
        assert.are.equal(installed, frame:GetScript("OnShow"))
    end)

    it("refuses a forbidden frame at the caller and leaves a hook inert on it", function()
        local forbidden = TestEnv.NewFrame({ forbidden = true })
        local scope = HookKit:CreateScope()
        TestEnv.expectErrorContaining(
            "HookKit.Scope:SecureHookScript frame is forbidden or not accessible in this context",
            function()
                scope:SecureHookScript(forbidden, "OnShow", function() end)
            end
        )

        local frame = TestEnv.NewFrame({ forbidden = false })
        scope:HookScript(frame, "OnShow", function() end)
        local installed = frame:GetScript("OnShow")
        TestEnv.SetForbidden(frame, true)
        assert.is_true(scope:Unhook(frame, "OnShow"))
        assert.are.equal(installed, frame:GetScript("OnShow"))
    end)
end)
