local TestEnv = require("TestKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at the line after the
---one that called `mark`. A wrong `error` level shows up either as a
---different line number or as a message with no `file:line` prefix at all.
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

describe("TestKit error levels", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("points facade argument errors at the caller", function()
        local cases = {
            {
                "TestKit:Suite name must be a non-empty string",
                function(mark)
                    mark()
                    TestKit:Suite("")
                end,
            },
            {
                'TestKit:Suite name must not contain "/"',
                function(mark)
                    mark()
                    TestKit:Suite("a/b")
                end,
            },
            {
                "TestKit:Suite options must be a table",
                function(mark)
                    mark()
                    TestKit:Suite("a", true)
                end,
            },
            {
                'TestKit:Suite options contains unknown field "phases"',
                function(mark)
                    mark()
                    TestKit:Suite("a", { phases = "ready" })
                end,
            },
            {
                'TestKit:Suite phase must be "loaded" or "ready"',
                function(mark)
                    mark()
                    TestKit:Suite("a", { phase = "shutdown" })
                end,
            },
            {
                "TestKit:Suite addonName must be a non-empty string",
                function(mark)
                    mark()
                    TestKit:Suite("a", { addonName = "" })
                end,
            },
            {
                "TestKit:Suite timeoutSeconds must be a finite number greater than zero",
                function(mark)
                    mark()
                    TestKit:Suite("a", { timeoutSeconds = 0 })
                end,
            },
            {
                "TestKit:Run filter must be a non-empty string",
                function(mark)
                    mark()
                    TestKit:Run(1)
                end,
            },
            {
                'TestKit:Run filter must be "suite" or "suite/test"',
                function(mark)
                    mark()
                    TestKit:Run("a/")
                end,
            },
            {
                "TestKit:OnFinished callback must be a function",
                function(mark)
                    mark()
                    TestKit:OnFinished(nil)
                end,
            },
            {
                "TestKit:Run must be called on the TestKit facade",
                function(mark)
                    mark()
                    TestKit.Run("MyAddon")
                end,
            },
            {
                "TestKit:Suite must be called on the TestKit facade",
                function(mark)
                    mark()
                    TestKit.Suite("MyAddon")
                end,
            },
            {
                "TestKit:Report must be called on the TestKit facade",
                function(mark)
                    mark()
                    TestKit.Report()
                end,
            },
            {
                "TestKit:OnFinished must be called on the TestKit facade",
                function(mark)
                    mark()
                    TestKit.OnFinished(noop)
                end,
            },
            {
                "TestKit:Reset must be called on the TestKit facade",
                function(mark)
                    mark()
                    TestKit.Reset()
                end,
            },
        }
        for index = 1, #cases do
            assertReportedAtCaller(cases[index][1], cases[index][2])
        end
    end)

    it("points suite method errors at the caller", function()
        local suite = TestKit:Suite("MyAddon")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            suite.Test({}, "a", noop)
        end)
        assert.is_false(ok)
        assert.are.equal(
            SOURCE .. ":" .. line .. ": TestKit.Suite:Test must be called on a TestKit suite",
            value
        )

        local cases = {
            {
                "TestKit.Suite:Test name must be a non-empty string",
                function(mark)
                    mark()
                    suite:Test(nil, noop)
                end,
            },
            {
                "TestKit.Suite:Test fn must be a function",
                function(mark)
                    mark()
                    suite:Test("a", "not a function")
                end,
            },
            {
                "TestKit.Suite:Skip reason must be a non-empty string",
                function(mark)
                    mark()
                    suite:Skip("a", "")
                end,
            },
            {
                "TestKit.Suite:Before fn must be a function",
                function(mark)
                    mark()
                    suite:Before(nil)
                end,
            },
            {
                "TestKit.Suite:After fn must be a function",
                function(mark)
                    mark()
                    suite:After(nil)
                end,
            },
            {
                "TestKit.Suite:GetName must be called on a TestKit suite",
                function(mark)
                    mark()
                    suite.GetName(nil)
                end,
            },
        }
        for index = 1, #cases do
            assertReportedAtCaller(cases[index][1], cases[index][2])
        end
    end)

    it("points context and matcher errors, and matcher failures, at the test's own line", function()
        local suite = TestKit:Suite("MyAddon")
        local expected = {}
        local function add(name, message, body)
            suite:Test(name, function(ctx)
                body(ctx, function()
                    local line = debug.getinfo(2, "l").currentline + 1
                    expected[name] = SOURCE .. ":" .. line .. ": " .. message
                end)
            end)
        end
        add("failure", "expected number 1 to be number 2", function(ctx, mark)
            mark()
            ctx:Expect(1):ToBe(2)
        end)
        add("negated failure", "expected number 1 not to equal number 1", function(ctx, mark)
            mark()
            ctx:Expect(1).Not:ToEqual(1)
        end)
        add("refusal", "expected number 1: ToRaise needs a function", function(ctx, mark)
            mark()
            ctx:Expect(1):ToRaise()
        end)
        add("fail", "on purpose", function(ctx, mark)
            mark()
            ctx:Fail("on purpose")
        end)
        add(
            "wait arguments",
            "TestKit.Context:WaitFor timeoutSeconds must be a finite number greater than zero",
            function(ctx, mark)
                mark()
                ctx:WaitFor("EVENT", -1)
            end
        )
        add(
            "wait until arguments",
            "TestKit.Context:WaitUntil predicate must be a function",
            function(ctx, mark)
                mark()
                ctx:WaitUntil(nil, 1)
            end
        )
        add(
            "replace arguments",
            "TestKit.Context:Replace target must be a table",
            function(ctx, mark)
                mark()
                ctx:Replace(nil, "key", 1)
            end
        )
        add(
            "context receiver",
            "TestKit.Context:Log must be called on a TestKit context",
            function(ctx, mark)
                mark()
                ctx.Log({}, "line")
            end
        )
        add(
            "matcher receiver",
            "TestKit.Matcher:ToBe must be called on a TestKit matcher",
            function(ctx, mark)
                mark()
                ctx:Expect(1).ToBe({}, 1)
            end
        )
        add(
            "secure key",
            "TestKit.Matcher:ToBeSecure key must be a non-empty string",
            function(ctx, mark)
                mark()
                ctx:Expect(nil):ToBeSecure(nil, "")
            end
        )
        add(
            "pattern",
            "TestKit.Matcher:ToRaise pattern must be a non-empty string",
            function(ctx, mark)
                mark()
                ctx:Expect(noop):ToRaise("")
            end
        )

        local report = TestEnv.RunToEnd(TestKit)
        local results = report.suites[1].tests
        assert.are.equal(11, #results)
        for index = 1, #results do
            local result = results[index]
            assert.are.equal("failed", result.status, result.name)
            assert.are.equal(expected[result.name], result.message, result.name)
        end
    end)
end)
