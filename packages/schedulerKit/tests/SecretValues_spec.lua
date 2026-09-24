local TestEnv = require("SchedulerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that a call failed with `message` reported at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local function noop() end

---Load the module chain on the `mainline` host, whose `issecretvalue` reports
---the values `NewSecretValue` returns.
---@return table SchedulerKit
local function loadOnSecretHost()
    TestEnv.Reset()
    TestEnv.SetWowProfile("mainline")
    TestEnv.InstallWowApi()
    require("Registry")
    require("TimerKit")
    return require("SchedulerKit")
end

describe("SchedulerKit and secret values", function()
    local SchedulerKit
    before_each(function()
        SchedulerKit = loadOnSecretHost()
    end)
    after_each(TestEnv.Reset)

    ---Each case calls one public method with a secret where a check would
    ---compare it, and names the message expected at the caller's line.
    local cases = {
        {
            label = "SchedulerKit:ForAddon addonName",
            call = function(secret, mark)
                mark()
                SchedulerKit:ForAddon(secret)
            end,
        },
        {
            label = "SchedulerKit:CloseAddonScopes addonName",
            call = function(secret, mark)
                mark()
                SchedulerKit:CloseAddonScopes(secret)
            end,
        },
        {
            label = "SchedulerKit:Schedule priority",
            unpositioned = true,
            call = function(secret, mark)
                mark()
                SchedulerKit:Schedule(noop, { priority = secret })
            end,
        },
        {
            label = "SchedulerKit:Schedule name",
            unpositioned = true,
            call = function(secret, mark)
                mark()
                SchedulerKit:Schedule(noop, { name = secret })
            end,
        },
        {
            label = "SchedulerKit:After delay",
            unpositioned = true,
            call = function(secret, mark)
                mark()
                SchedulerKit:After(secret, noop)
            end,
        },
        {
            label = "SchedulerKit:SetFrameBudget milliseconds",
            call = function(secret, mark)
                mark()
                SchedulerKit:SetFrameBudget(secret)
            end,
        },
        {
            label = "SchedulerKit:SetMaxResumesPerFrame count",
            call = function(secret, mark)
                mark()
                SchedulerKit:SetMaxResumesPerFrame(secret)
            end,
        },
        {
            label = "SchedulerKit:Lane name",
            call = function(secret, mark)
                mark()
                SchedulerKit:Lane(secret)
            end,
        },
        {
            label = "SchedulerKit:Lane maxInFlight",
            call = function(secret, mark)
                mark()
                SchedulerKit:Lane("secret-lane", { maxInFlight = secret })
            end,
        },
        {
            label = "SchedulerKit:Lane retry.attempts",
            call = function(secret, mark)
                mark()
                SchedulerKit:Lane("secret-lane", { retry = { attempts = secret } })
            end,
        },
        {
            label = "SchedulerKit:Debounce leading",
            call = function(secret, mark)
                mark()
                SchedulerKit:Debounce(noop, 1, { leading = secret })
            end,
        },
        {
            label = "SchedulerKit:Coalesce maxKeys",
            call = function(secret, mark)
                mark()
                SchedulerKit:Coalesce(noop, 1, { maxKeys = secret })
            end,
        },
        {
            label = "SchedulerKit:Watch intervalSeconds",
            call = function(secret, mark)
                mark()
                SchedulerKit:Watch(noop, secret, noop)
            end,
        },
        {
            label = "SchedulerKit:SetLimits limits.maxLanes",
            call = function(secret, mark)
                mark()
                SchedulerKit:SetLimits({ maxLanes = secret })
            end,
        },
    }

    for _, case in ipairs(cases) do
        local label, call = case.label, case.call
        it("refuses a secret " .. label .. " at the caller's line", function()
            local line
            ---Record the line after the caller's, where each case calls the method.
            local function mark()
                line = debug.getinfo(2, "l").currentline + 1
            end
            local ok, value = pcall(call, TestEnv.NewSecretValue(), mark)
            if case.unpositioned then
                -- These facade methods reach their option and delay checks
                -- through a tail call, so the level every argument error of
                -- theirs uses (the secret refusal included) names no line.
                assert.is_false(ok)
                assert.are.equal(label .. " must not be a secret value", value)
                return
            end
            assertReportedAt(line, label .. " must not be a secret value", ok, value)
        end)
    end

    it("refuses a secret coalesce key at the caller's line and stores a secret value", function()
        local delivered
        local handle = SchedulerKit:Coalesce(function(set)
            delivered = set.key
        end, 1)

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            handle(TestEnv.NewSecretValue())
        end)
        assertReportedAt(
            line,
            "SchedulerKit coalesce handle key must not be a secret value",
            ok,
            value
        )

        local secretValue = TestEnv.NewSecretValue()
        assert.is_true(handle("key", secretValue))
        TestEnv.FireNative(#TestEnv.NativeTimers())
        assert.are.equal(secretValue, delivered)
    end)

    it("reports a secret facade-method argument at the caller's own line", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            SchedulerKit:ForAddon(TestEnv.NewSecretValue())
        end)
        assertReportedAt(
            line,
            "SchedulerKit:ForAddon addonName must not be a secret value",
            ok,
            value
        )
    end)

    it("still accepts ordinary arguments on a host with secret values", function()
        local scope = SchedulerKit:ForAddon("SecretHostAddon")
        local lane = SchedulerKit:Lane("ordinary", { maxInFlight = 2, retry = { attempts = 1 } })
        local ran = false
        scope:Schedule(function()
            ran = true
        end, { priority = SchedulerKit.Priority.HIGH, name = "ordinary" })
        SchedulerKit:SetLimits({ maxLanes = SchedulerKit.UNBOUNDED })
        TestEnv.Tick()
        assert.is_true(ran)
        assert.are.equal(lane, SchedulerKit:Lane("ordinary"))
    end)
end)
