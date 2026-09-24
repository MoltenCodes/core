local TestEnv = require("LifecycleKitTestEnv")

local expectErrorContaining = TestEnv.expectErrorContaining

-- EventKit isolates listener errors at the event-bus boundary, so an error that
-- LifecycleKit re-raises from inside a host event dispatch is reported through
-- the host error handler instead of escaping `Emit`. These helpers observe that
-- report while still asserting the exact error object LifecycleKit produced.
local function takeSingleReportedError()
    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    return reported[1].value
end

local function expectReportedErrorContaining(expected, callback)
    callback()
    local value = takeSingleReportedError()
    assert.is_not_nil(string.find(tostring(value), expected, 1, true))
end

describe("LifecycleKit validation", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("rejects invalid addon names", function()
        expectErrorContaining("addonName must be a non-empty string", function()
            LifecycleKit:ForAddon(42)
        end)
        expectErrorContaining("addonName must be a non-empty string", function()
            LifecycleKit:ForAddon("")
        end)
    end)

    it("rejects invalid callbacks", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        expectErrorContaining("callback must be a function", function()
            life:OnLoaded(false)
        end)
        expectErrorContaining("callback must be a function", function()
            life:OnReady({})
        end)
        expectErrorContaining("callback must be a function", function()
            life:OnShutdown("no")
        end)
    end)

    it("does not cache a partially constructed instance when event setup fails", function()
        -- The package reads this host global at load time, so the spec has to install it in the global table.
        -- selene: allow(global_usage)
        local Registry = rawget(rawget(_G, "MoltenCodes"), "Registry")
        local EventKit = Registry:Get("eventKit", 1)
        local originalOnce = EventKit.Once
        EventKit.Once = function()
            error("synthetic setup failure")
        end

        expectErrorContaining("synthetic setup failure", function()
            LifecycleKit:ForAddon("RetryAddon")
        end)
        EventKit.Once = originalOnce

        local life = LifecycleKit:ForAddon("RetryAddon")
        TestEnv.LoadAddon("RetryAddon")
        assert.is_true(life:IsLoaded())
    end)

    it("leaves phase state committed when a callback raises", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        life:OnLoaded(function()
            error("boom")
        end)
        expectReportedErrorContaining("boom", function()
            TestEnv.LoadAddon("MyAddon")
        end)
        assert.is_true(life:IsLoaded())
    end)

    it("delivers all subscribers and preserves the first error when several fail", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local seen = {}

        life:OnLoaded(function()
            seen[#seen + 1] = "first"
            error("first failure")
        end)
        life:OnLoaded(function()
            seen[#seen + 1] = "second"
            error("second failure")
        end)
        local final = life:OnLoaded(function()
            seen[#seen + 1] = "third"
        end)

        expectReportedErrorContaining("first failure", function()
            TestEnv.LoadAddon("MyAddon")
        end)
        assert.are.same({ "first", "second", "third" }, seen)
        assert.is_false(final:IsConnected())
    end)
    it("preserves false as a valid first callback error object", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function()
            error(false)
        end)
        life:OnLoaded(function()
            laterCalls = laterCalls + 1
            error("second failure")
        end)
        life:OnLoaded(function()
            laterCalls = laterCalls + 1
        end)

        TestEnv.LoadAddon("MyAddon")

        assert.are.equal(false, takeSingleReportedError())
        assert.are.equal(2, laterCalls)
    end)

    it("preserves nil as a valid callback error object", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function()
            error(nil)
        end)
        life:OnLoaded(function()
            laterCalls = laterCalls + 1
        end)

        TestEnv.LoadAddon("MyAddon")

        assert.is_nil(takeSingleReportedError())
        assert.are.equal(1, laterCalls)
    end)

    it("delivers later phase subscribers before re-raising the first callback error", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local laterCalls = 0
        life:OnLoaded(function()
            error("first failure")
        end)
        local later = life:OnLoaded(function()
            laterCalls = laterCalls + 1
        end)

        expectReportedErrorContaining("first failure", function()
            TestEnv.LoadAddon("MyAddon")
        end)
        assert.are.equal(1, laterCalls)
        assert.is_false(later:IsConnected())
    end)
end)

-- These specs pin the Lua error level of argument validation. The reported
-- position must be the line in this spec file that called the public method:
-- not a line inside LifecycleKit, and not a frame further up the stack.
describe("LifecycleKit argument error positions", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("reports ForAddon argument errors at the caller's file and line", function()
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            LifecycleKit:ForAddon("")
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit:ForAddon addonName must be a non-empty string",
            message
        )
    end)

    it("reports OnLoaded argument errors at the caller's file and line", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            life:OnLoaded(5)
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit.Instance:OnLoaded callback must be a function",
            message
        )
    end)

    it("reports OnReady argument errors at the caller's file and line", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            life:OnReady(5)
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit.Instance:OnReady callback must be a function",
            message
        )
    end)

    it("reports OnShutdown argument errors at the caller's file and line", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            life:OnShutdown(5)
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit.Instance:OnShutdown callback must be a function",
            message
        )
    end)
end)

describe("LifecycleKit callback error propagation", function()
    local LifecycleKit
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("re-raises the original error object from a replayed callback", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        TestEnv.LoadAddon("MyAddon")

        local errorObject = { reason = "replay failure" }
        local ok, message = pcall(function()
            life:OnLoaded(function()
                error(errorObject)
            end)
        end)

        assert.is_false(ok)
        assert.are.equal(errorObject, message)
        assert.is_true(life:IsLoaded())
    end)

    it("re-raises the original error object from a dispatched callback", function()
        local life = LifecycleKit:ForAddon("MyAddon")
        local errorObject = { reason = "dispatch failure" }
        life:OnLoaded(function()
            error(errorObject)
        end)

        TestEnv.LoadAddon("MyAddon")

        assert.are.equal(errorObject, takeSingleReportedError())
        assert.is_true(life:IsLoaded())
    end)

    it("preserves a false error object on both the replay and the dispatch path", function()
        local dispatched = LifecycleKit:ForAddon("DispatchedAddon")
        dispatched:OnLoaded(function()
            error(false)
        end)
        TestEnv.LoadAddon("DispatchedAddon")
        local dispatchMessage = takeSingleReportedError()

        local replayed = LifecycleKit:ForAddon("ReplayedAddon")
        TestEnv.LoadAddon("ReplayedAddon")
        local replayOk, replayMessage = pcall(function()
            replayed:OnLoaded(function()
                error(false)
            end)
        end)

        assert.is_false(replayOk)
        assert.are.equal(dispatchMessage, replayMessage)
        assert.is_false(replayMessage)
    end)
end)

-- The combat gate and halted-state methods validate their arguments at the
-- caller too, pinned the same way as the phase subscriptions above.
describe("LifecycleKit combat and halt argument error positions", function()
    local LifecycleKit, life
    before_each(function()
        LifecycleKit = TestEnv.NewPackage()
        life = LifecycleKit:ForAddon("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("reports WhenOutOfCombat argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            life:WhenOutOfCombat(5)
        end)
        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit.Instance:WhenOutOfCombat callback must be a function",
            message
        )
    end)

    it("reports OnCombatStart and OnCombatEnd argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        local startLine, endLine
        local startOk, startMessage = pcall(function()
            startLine = debug.getinfo(1, "l").currentline + 1
            life:OnCombatStart("no")
        end)
        local endOk, endMessage = pcall(function()
            endLine = debug.getinfo(1, "l").currentline + 1
            life:OnCombatEnd({})
        end)

        assert.is_false(startOk)
        assert.are.equal(
            source
                .. ":"
                .. startLine
                .. ": LifecycleKit.Instance:OnCombatStart callback must be a function",
            startMessage
        )
        assert.is_false(endOk)
        assert.are.equal(
            source
                .. ":"
                .. endLine
                .. ": LifecycleKit.Instance:OnCombatEnd callback must be a function",
            endMessage
        )
    end)

    it("reports OnHalted and OnDependencyHalted argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        local haltedLine, dependencyLine
        local haltedOk, haltedMessage = pcall(function()
            haltedLine = debug.getinfo(1, "l").currentline + 1
            life:OnHalted(false)
        end)
        local dependencyOk, dependencyMessage = pcall(function()
            dependencyLine = debug.getinfo(1, "l").currentline + 1
            life:OnDependencyHalted(1)
        end)

        assert.is_false(haltedOk)
        assert.are.equal(
            source
                .. ":"
                .. haltedLine
                .. ": LifecycleKit.Instance:OnHalted callback must be a function",
            haltedMessage
        )
        assert.is_false(dependencyOk)
        assert.are.equal(
            source
                .. ":"
                .. dependencyLine
                .. ": LifecycleKit.Instance:OnDependencyHalted callback must be a function",
            dependencyMessage
        )
    end)

    it("reports Halt argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        local callLine
        local ok, message = pcall(function()
            callLine = debug.getinfo(1, "l").currentline + 1
            life:Halt("")
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. callLine
                .. ": LifecycleKit.Instance:Halt reason must be a non-empty string",
            message
        )
        assert.is_false(life:IsHalted())
    end)

    it("reports DependsOn argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        local nameLine, selfLine
        local nameOk, nameMessage = pcall(function()
            nameLine = debug.getinfo(1, "l").currentline + 1
            life:DependsOn(nil)
        end)
        local selfOk, selfMessage = pcall(function()
            selfLine = debug.getinfo(1, "l").currentline + 1
            life:DependsOn("MyAddon")
        end)

        assert.is_false(nameOk)
        assert.are.equal(
            source
                .. ":"
                .. nameLine
                .. ": LifecycleKit.Instance:DependsOn addonName must be a non-empty string",
            nameMessage
        )
        assert.is_false(selfOk)
        assert.are.equal(
            source
                .. ":"
                .. selfLine
                .. ": LifecycleKit.Instance:DependsOn addonName must name another addon",
            selfMessage
        )
    end)

    it("reports SetCombatQueueLimit argument errors at the caller", function()
        local source = debug.getinfo(1, "S").short_src
        for _, invalid in ipairs({ 0, -1, 1.5, "8", math.huge, 0 / 0, {} }) do
            local callLine
            local ok, message = pcall(function()
                callLine = debug.getinfo(1, "l").currentline + 1
                life:SetCombatQueueLimit(invalid)
            end)
            assert.is_false(ok)
            assert.are.equal(
                source
                    .. ":"
                    .. callLine
                    .. ": LifecycleKit.Instance:SetCombatQueueLimit limit must be a positive integer"
                    .. " or LifecycleKit.UNBOUNDED",
                message
            )
        end
        assert.are.equal(64, life:GetCombatQueueLimit())
    end)
end)
