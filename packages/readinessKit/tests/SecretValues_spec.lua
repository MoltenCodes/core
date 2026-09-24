local TestEnv = require("ReadinessKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local function probe()
    return false
end

---Load the module chain on the `mainline` host, whose `issecretvalue` reports
---the values `NewSecretValue` returns.
---@return table ReadinessKit
local function loadOnSecretHost()
    TestEnv.Reset()
    TestEnv.SetWowProfile("mainline")
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("TimerKit")
    return require("ReadinessKit")
end

describe("ReadinessKit and secret values", function()
    local ReadinessKit
    before_each(function()
        ReadinessKit = loadOnSecretHost()
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret gate name at the caller's line before comparing it", function()
        local secret = TestEnv.NewSecretValue()
        local gateLine
        local gateOk, gateValue = pcall(function()
            gateLine = currentLine() + 1
            ReadinessKit:Gate(secret, probe)
        end)
        assertReportedAt(
            gateLine,
            "ReadinessKit:Gate name must not be a secret value",
            gateOk,
            gateValue
        )

        local getLine
        local getOk, getValue = pcall(function()
            getLine = currentLine() + 1
            ReadinessKit:Get(secret)
        end)
        assertReportedAt(
            getLine,
            "ReadinessKit:Get name must not be a secret value",
            getOk,
            getValue
        )
    end)

    it("refuses a secret event name at the caller's line", function()
        local gate = ReadinessKit:Gate("spells", probe)
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            gate:ReprobeOn(TestEnv.NewSecretValue())
        end)
        assertReportedAt(
            line,
            "ReadinessKit.Gate:ReprobeOn eventName must not be a secret value",
            ok,
            value
        )
    end)

    it("refuses each secret option at the caller's line and defines no gate", function()
        for _, field in ipairs({ "intervalSeconds", "timeoutSeconds", "maxWaiters" }) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                ReadinessKit:Gate("spells", probe, { [field] = TestEnv.NewSecretValue() })
            end)
            assertReportedAt(
                line,
                "ReadinessKit:Gate " .. field .. " must not be a secret value",
                ok,
                value
            )
        end
        assert.is_nil(ReadinessKit:Get("spells"))
    end)

    it("still accepts ordinary arguments on a host with secret values", function()
        local gate = ReadinessKit:Gate("spells", probe, {
            intervalSeconds = 1,
            timeoutSeconds = false,
            maxWaiters = ReadinessKit.UNBOUNDED,
        })
        assert.are.equal(gate, ReadinessKit:Get("spells"))
        assert.is_false(gate:IsReady())
    end)
end)
