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

---The fixed report a gate whose probe answered a secret value makes.
---@param name string
---@return string
local function secretAnswerReport(name)
    return 'ReadinessKit gate "'
        .. name
        .. '" probe answered a secret value; a probe must answer a plain true or false'
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

    it(
        "counts a secret answer at definition as a probe failure and keeps the gate pending",
        function()
            local secret = TestEnv.NewSecretValue()
            local gate = ReadinessKit:Gate("spells", function()
                return secret
            end)
            assert.are.equal(gate, ReadinessKit:Get("spells"))
            assert.is_false(gate:IsReady())
            assert.are.equal(1, gate:GetProbeErrorCount())
            assert.are.same({ secretAnswerReport("spells") }, TestEnv.ReportedErrors())
            assert.are.equal(1, TestEnv.ArmedTimerCount())
        end
    )

    it(
        "treats a secret answer from a poll like a raising probe: counted, reported once per round",
        function()
            local answer = false
            local gate = ReadinessKit:Gate("spells", function()
                return answer
            end, { timeoutSeconds = 1 })
            answer = TestEnv.NewSecretValue()
            TestEnv.Poll(500)
            assert.is_false(gate:IsReady())
            assert.are.equal(1, gate:GetProbeErrorCount())
            TestEnv.Poll(500)
            assert.are.equal(2, gate:GetProbeErrorCount())
            assert.are.same({ secretAnswerReport("spells") }, TestEnv.ReportedErrors())

            -- The timed-out gate starts a new round on Invalidate, which reports again.
            gate:Invalidate()
            TestEnv.Poll(500)
            assert.are.equal(2, #TestEnv.ReportedErrors())

            -- A plain answer afterwards still makes the gate ready.
            answer = true
            TestEnv.Poll(500)
            assert.is_true(gate:IsReady())
        end
    )

    it(
        "returns false from Probe for a secret answer and caches it like a negative answer",
        function()
            local calls = 0
            local secret = TestEnv.NewSecretValue()
            local gate = ReadinessKit:Gate("spells", function()
                calls = calls + 1
                return secret
            end)
            TestEnv.AdvanceMs(500)
            assert.is_false(gate:Probe())
            assert.is_false(gate:Probe())
            assert.are.equal(2, calls)
            assert.are.equal(2, gate:GetProbeErrorCount())
            assert.are.equal(1, #TestEnv.ReportedErrors())
        end
    )

    it("does not raise when a re-probe event gets a secret answer", function()
        local answer = false
        local gate = ReadinessKit:Gate("items", function()
            return answer
        end, { intervalSeconds = 60 })
        gate:ReprobeOn("GET_ITEM_INFO_RECEIVED")
        answer = TestEnv.NewSecretValue()
        TestEnv.Emit("GET_ITEM_INFO_RECEIVED")
        assert.is_false(gate:IsReady())
        assert.are.equal(1, gate:GetProbeErrorCount())
        assert.are.same({ secretAnswerReport("items") }, TestEnv.ReportedErrors())

        answer = true
        TestEnv.Emit("GET_ITEM_INFO_RECEIVED")
        assert.is_true(gate:IsReady())
    end)

    it(
        "upgrades a gate of the previous revision in place and treats its secret answer as a failure",
        function()
            local current = ReadinessKit.REVISION
            ReadinessKit = nil
            TestEnv.Reset()
            TestEnv.SetWowProfile("mainline")
            TestEnv.InstallWowApi()
            require("Registry")
            require("SignalKit")
            require("EventKit")
            require("TimerKit")
            local previous = TestEnv.LoadRevision(current - 1)
            local answer = false
            local gate = previous:Gate("talents", function()
                return answer
            end)
            local results = {}
            local waiter = gate:Await(function(isReady)
                results[#results + 1] = isReady
            end)

            package.loaded["ReadinessKit"] = nil
            local upgraded = require("ReadinessKit")
            assert.are.equal(previous, upgraded)
            assert.are.equal(current, upgraded.REVISION)
            assert.are.equal(gate, upgraded:Get("talents"))

            answer = TestEnv.NewSecretValue()
            TestEnv.Poll(500)
            assert.is_true(waiter:IsPending())
            assert.are.equal(1, gate:GetProbeErrorCount())
            assert.are.same({ secretAnswerReport("talents") }, TestEnv.ReportedErrors())

            answer = true
            TestEnv.Poll(500)
            assert.are.same({ true }, results)
        end
    )
end)
