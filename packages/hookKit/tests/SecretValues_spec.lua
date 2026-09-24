local TestEnv = require("HookKitTestEnv")

describe("HookKit and secret values", function()
    after_each(TestEnv.Reset)

    ---Load the module chain on a host whose `issecretvalue` reports `secret`,
    ---counting every probe.
    ---@param secret any
    ---@param withClientKit boolean
    ---@return table HookKit
    ---@return table probes `{ count = n }`
    local function loadWithSecret(secret, withClientKit)
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        TestEnv.InstallHookApi()
        local probes = { count = 0 }
        TestEnv.SetGlobal("issecretvalue", function(value)
            probes.count = probes.count + 1
            return rawequal(value, secret)
        end)
        require("Registry")
        if withClientKit then
            require("ClientKit")
        end
        return require("HookKit"), probes
    end

    it("passes secret arguments and results through every semantic untouched", function()
        local secret = TestEnv.NewSecretValue()
        local HookKit, probes = loadWithSecret(secret, true)
        local seen = {}
        local target = {
            Pre = function(value)
                return value
            end,
            Raw = function(value)
                return value
            end,
            Post = function(value)
                return value
            end,
        }
        local scope = HookKit:CreateScope()
        scope:Hook(target, "Pre", function(value)
            seen[#seen + 1] = value
        end)
        scope:RawHook(target, "Raw", function(original, value)
            seen[#seen + 1] = value
            return original(value)
        end)
        scope:SecureHook(target, "Post", function(value)
            seen[#seen + 1] = value
        end)
        local frame = TestEnv.NewFrame()
        scope:HookScript(frame, "OnEvent", function(_, value)
            seen[#seen + 1] = value
        end)
        local probesAfterInstall = probes.count

        assert.is_true(rawequal(secret, target.Pre(secret)))
        assert.is_true(rawequal(secret, target.Raw(secret)))
        assert.is_true(rawequal(secret, target.Post(secret)))
        TestEnv.RunScript(frame, "OnEvent", secret)

        assert.are.equal(4, #seen)
        for index = 1, #seen do
            assert.is_true(rawequal(secret, seen[index]))
        end
        -- The dispatch path never asks whether an argument is secret.
        assert.are.equal(probesAfterInstall, probes.count)
    end)

    it("passes a handler error built from a secret to the host unchanged", function()
        local secret = TestEnv.NewSecretValue()
        local HookKit = loadWithSecret(secret, true)
        local target = { Method = function() end }
        HookKit:CreateScope():Hook(target, "Method", function(value)
            error(value, 0)
        end)
        target.Method(secret)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_true(rawequal(secret, reported[1].value))
    end)

    for _, withClientKit in ipairs({ true, false }) do
        local label = withClientKit and "through ClientKit" or "through issecretvalue"
        it("refuses a secret method name " .. label, function()
            local HookKit = loadWithSecret("SecretMethod", withClientKit)
            local scope = HookKit:CreateScope()
            local target = { SecretMethod = function() end }
            TestEnv.expectErrorContaining(
                "HookKit.Scope:Hook method must not be a secret value",
                function()
                    scope:Hook(target, "SecretMethod", function() end)
                end
            )
            TestEnv.expectErrorContaining(
                "HookKit.Scope:IsHooked globalName must not be a secret value",
                function()
                    scope:IsHooked("SecretMethod")
                end
            )
            TestEnv.expectErrorContaining(
                "HookKit:ForAddon addonName must not be a secret value",
                function()
                    HookKit:ForAddon("SecretMethod")
                end
            )
        end)

        it("refuses a secret forceSecure at the caller's line " .. label, function()
            -- `true` stands in for a secret boolean: its type is boolean, so
            -- only the probe tells it apart from a plain flag.
            local HookKit = loadWithSecret(true, withClientKit)
            local scope = HookKit:CreateScope()
            local target = {
                Pre = function() end,
                Raw = function() end,
            }
            local frame = TestEnv.NewFrame()
            local options = { forceSecure = true }
            local function noop() end
            local source = debug.getinfo(1, "S").short_src
            local cases = {
                {
                    "HookKit.Scope:Hook",
                    function()
                        local _ = scope:Hook(target, "Pre", noop, options)
                    end,
                },
                {
                    "HookKit.Scope:RawHook",
                    function()
                        local _ = scope:RawHook(target, "Raw", noop, options)
                    end,
                },
                {
                    "HookKit.Scope:HookScript",
                    function()
                        local _ = scope:HookScript(frame, "OnShow", noop, options)
                    end,
                },
                {
                    "HookKit.Scope:RawHookScript",
                    function()
                        local _ = scope:RawHookScript(frame, "OnHide", noop, options)
                    end,
                },
            }
            for index = 1, #cases do
                local methodName, action = cases[index][1], cases[index][2]
                local line = debug.getinfo(action, "S").linedefined + 1
                local ok, value = pcall(action)
                assert.is_false(ok)
                assert.are.equal(
                    source
                        .. ":"
                        .. line
                        .. ": "
                        .. methodName
                        .. " options.forceSecure must not be a secret value",
                    value
                )
            end
            assert.are.equal(0, scope:GetActiveCount())
        end)

        it("still accepts a plain forceSecure while the probe exists " .. label, function()
            local HookKit = loadWithSecret("SecretMethod", withClientKit)
            local scope = HookKit:CreateScope()
            local target = { Pre = function() end }
            assert.is_true(scope:Hook(target, "Pre", function() end, { forceSecure = true }))
        end)
    end
end)
