local TestEnv = require("TestKitTestEnv")

describe("TestKit Before and After hooks", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("runs Before hooks, the body, then After hooks, for every test", function()
        local calls = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Before(function()
            calls[#calls + 1] = "before 1"
        end)
        suite:Before(function()
            calls[#calls + 1] = "before 2"
        end)
        suite:After(function()
            calls[#calls + 1] = "after"
        end)
        suite:Test("a", function()
            calls[#calls + 1] = "a"
        end)
        suite:Test("b", function()
            calls[#calls + 1] = "b"
        end)

        TestEnv.RunToEnd(TestKit)
        assert.are.same({
            "before 1",
            "before 2",
            "a",
            "after",
            "before 1",
            "before 2",
            "b",
            "after",
        }, calls)
    end)

    it("skips the body after a failing Before hook but still runs every After hook", function()
        local calls = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Before(function()
            error("setup failed")
        end)
        suite:After(function()
            calls[#calls + 1] = "after 1"
            error("teardown failed")
        end)
        suite:After(function()
            calls[#calls + 1] = "after 2"
        end)
        suite:Test("body", function()
            calls[#calls + 1] = "body"
        end)

        local report = TestEnv.RunToEnd(TestKit)
        local result = TestEnv.FindResult(report, "MyAddon", "body")
        assert.are.same({ "after 1", "after 2" }, calls)
        assert.are.equal("failed", result.status)
        -- The first failure wins.
        assert.is_truthy(result.message:find("setup failed", 1, true))
    end)

    it("fails a passing test whose After hook raises", function()
        local suite = TestKit:Suite("MyAddon")
        suite:After(function()
            error("teardown failed")
        end)
        suite:Test("body", function() end)

        local report = TestEnv.RunToEnd(TestKit)
        local result = TestEnv.FindResult(report, "MyAddon", "body")
        assert.are.equal("failed", result.status)
        assert.is_truthy(result.message:find("teardown failed", 1, true))
    end)

    it("hands hooks the test's context", function()
        local target = { value = 1 }
        local suite = TestKit:Suite("MyAddon")
        suite:Before(function(ctx)
            ctx:Replace(target, "value", 2)
        end)
        suite:Test("sees the Before replacement", function(ctx)
            ctx:Expect(target.value):ToBe(2)
        end)

        local report = TestEnv.RunToEnd(TestKit)
        assert.are.equal("passed", report.suites[1].tests[1].status)
        assert.are.equal(1, target.value)
    end)
end)
