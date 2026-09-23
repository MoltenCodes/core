local TestEnv = require("TestKitTestEnv")

describe("TestKit results and Report", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("tallies every status and publishes the documented shape", function()
        local suite = TestKit:Suite("MyAddon", { timeoutSeconds = 1 })
        suite:Test("passes", function(ctx)
            ctx:Log("hello")
        end)
        suite:Test("fails", function(ctx)
            ctx:Fail("on purpose")
        end)
        suite:Skip("skipped", "not on this client")
        suite:Test("times out", function(ctx)
            ctx:WaitFor("NEVER_FIRES", 5)
        end)
        local other = TestKit:Suite("Other", { phase = "loaded", addonName = "MyAddon" })
        other:Test("passes too", function() end)

        local report = TestEnv.RunToEnd(TestKit, nil, 400)
        assert.is_not_nil(report)
        assert.are.same(
            { suites = 2, tests = 5, passed = 2, failed = 1, skipped = 1, timeout = 1 },
            report.totals
        )

        local first = report.suites[1]
        assert.are.equal("MyAddon", first.name)
        assert.are.equal("ready", first.phase)
        assert.are.equal("MyAddon", first.addonName)
        assert.are.same({ "passes", "fails", "skipped", "times out" }, {
            first.tests[1].name,
            first.tests[2].name,
            first.tests[3].name,
            first.tests[4].name,
        })

        assert.are.same({ "hello" }, first.tests[1].logs)
        assert.is_nil(first.tests[1].message)
        assert.are.equal("number", type(first.tests[1].durationMs))

        assert.are.equal("failed", first.tests[2].status)
        assert.is_truthy(first.tests[2].message:find("on purpose", 1, true))

        assert.are.equal("skipped", first.tests[3].status)
        assert.are.equal("not on this client", first.tests[3].message)

        assert.are.equal("timeout", first.tests[4].status)
        assert.is_truthy(first.tests[4].message:find("within 1 seconds", 1, true))

        assert.are.equal("Other", report.suites[2].name)
        assert.are.equal("loaded", report.suites[2].phase)
    end)

    it("measures duration on the wall clock", function()
        local suite = TestKit:Suite("MyAddon")
        suite:Test("waits three frames", function(ctx)
            ctx:WaitUntil(function()
                return false
            end, 0.04)
        end)

        local report = TestEnv.RunToEnd(TestKit)
        assert.is_true(report.suites[1].tests[1].durationMs >= 32)
    end)

    it("returns a fresh copy on every call", function()
        local suite = TestKit:Suite("MyAddon")
        suite:Test("logs", function(ctx)
            ctx:Log("line")
        end)
        TestEnv.RunToEnd(TestKit)

        local first = TestKit:Report()
        first.suites[1].tests[1].logs[1] = "changed"
        first.totals.passed = 99
        local second = TestKit:Report()
        assert.are_not.equal(first, second)
        assert.are.equal("line", second.suites[1].tests[1].logs[1])
        assert.are.equal(1, second.totals.passed)
    end)

    it("replaces a re-run test's result in place", function()
        local attempts = 0
        local suite = TestKit:Suite("MyAddon")
        suite:Test("flaky", function(ctx)
            attempts = attempts + 1
            if attempts == 1 then
                ctx:Fail("first attempt")
            end
        end)
        suite:Test("stable", function() end)

        TestEnv.RunToEnd(TestKit)
        local report = TestEnv.RunToEnd(TestKit, "MyAddon/flaky")
        assert.are.equal(2, #report.suites[1].tests)
        assert.are.equal("flaky", report.suites[1].tests[1].name)
        assert.are.equal("passed", report.suites[1].tests[1].status)
        assert.are.equal(2, report.totals.passed)
    end)

    it("keeps at most 64 log lines", function()
        local accepted = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Test("logs a lot", function(ctx)
            for index = 1, 70 do
                accepted[index] = ctx:Log("line " .. index)
            end
        end)

        local report = TestEnv.RunToEnd(TestKit)
        local logs = report.suites[1].tests[1].logs
        assert.are.equal(64, #logs)
        assert.is_true(accepted[64])
        assert.is_false(accepted[65])
        assert.are.equal("line 64", logs[64])
    end)

    it("cuts a long line to 256 bytes", function()
        local suite = TestKit:Suite("MyAddon")
        suite:Test("logs a long line", function(ctx)
            ctx:Log(string.rep("x", 1000))
            ctx:Log({})
        end)

        local report = TestEnv.RunToEnd(TestKit)
        local logs = report.suites[1].tests[1].logs
        assert.are.equal(string.rep("x", 256) .. "... (1000 bytes)", logs[1])
        assert.are.equal("error object: table", logs[2])
    end)

    it("reports no suite that has not run", function()
        TestKit:Suite("MyAddon"):Test("never run", function() end)
        assert.are.same({
            suites = {},
            totals = { suites = 0, tests = 0, passed = 0, failed = 0, skipped = 0, timeout = 0 },
        }, TestKit:Report())
    end)
end)
