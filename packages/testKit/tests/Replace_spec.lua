local TestEnv = require("TestKitTestEnv")

describe("TestKit ctx:Replace", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("restores every replacement after a passing test, newest first", function()
        local target = { value = "original" }
        local seenInside = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Test("replaces twice", function(ctx)
            ctx:Replace(target, "value", "first")
            ctx:Replace(target, "value", "second")
            seenInside[#seenInside + 1] = target.value
        end)

        local report = TestEnv.RunToEnd(TestKit)
        assert.are.equal("passed", TestEnv.FindResult(report, "MyAddon", "replaces twice").status)
        assert.are.same({ "second" }, seenInside)
        -- Reverse order: "second" is undone to "first", then "first" to the original.
        assert.are.equal("original", target.value)
    end)

    it("restores after a test that raised, including keys that were nil", function()
        local target = { present = 1 }
        local suite = TestKit:Suite("MyAddon")
        suite:Test("raises", function(ctx)
            ctx:Replace(target, "absent", "added")
            ctx:Replace(target, "present", nil)
            error("boom")
        end)

        local report = TestEnv.RunToEnd(TestKit)
        local result = TestEnv.FindResult(report, "MyAddon", "raises")
        assert.are.equal("failed", result.status)
        assert.is_truthy(result.message:find("boom", 1, true))
        assert.is_nil(rawget(target, "absent"))
        assert.are.equal(1, target.present)
    end)

    it(
        "restores after a failed expectation and after an After hook, which still sees the replacement",
        function()
            local target = { value = 1 }
            local seenByAfter = nil
            local suite = TestKit:Suite("MyAddon")
            suite:After(function()
                seenByAfter = target.value
            end)
            suite:Test("fails", function(ctx)
                ctx:Replace(target, "value", 2)
                ctx:Expect(target.value):ToBe(3)
            end)

            TestEnv.RunToEnd(TestKit)
            assert.are.equal(2, seenByAfter)
            assert.are.equal(1, target.value)
        end
    )

    it("writes and restores raw, so a key reached through __index comes back to it", function()
        local prototype = { Method = "prototype" }
        local object = setmetatable({}, { __index = prototype })
        local suite = TestKit:Suite("MyAddon")
        suite:Test("shadows a method", function(ctx)
            local previous = ctx:Replace(object, "Method", "replacement")
            ctx:Expect(previous):ToBeNil()
            ctx:Expect(object.Method):ToBe("replacement")
        end)

        local report = TestEnv.RunToEnd(TestKit)
        assert.are.equal("passed", report.suites[1].tests[1].status)
        assert.is_nil(rawget(object, "Method"))
        assert.are.equal("prototype", object.Method)
    end)

    it("replaces a global and puts it back", function()
        -- selene: allow(global_usage)
        rawset(_G, "TestKitSpecGlobal", "host")
        local suite = TestKit:Suite("MyAddon")
        suite:Test("replaces a global", function(ctx)
            -- Replacing a host global is the point of this spec.
            -- selene: allow(global_usage)
            ctx:Replace(_G, "TestKitSpecGlobal", "mock")
            -- selene: allow(global_usage)
            ctx:Expect(rawget(_G, "TestKitSpecGlobal")):ToBe("mock")
        end)

        TestEnv.RunToEnd(TestKit)
        -- selene: allow(global_usage)
        assert.are.equal("host", rawget(_G, "TestKitSpecGlobal"))
        -- selene: allow(global_usage)
        rawset(_G, "TestKitSpecGlobal", nil)
    end)

    it("does not carry replacements from one test into the next", function()
        local target = { value = "original" }
        local seenBySecond = nil
        local suite = TestKit:Suite("MyAddon")
        suite:Test("first", function(ctx)
            ctx:Replace(target, "value", "mock")
        end)
        suite:Test("second", function()
            seenBySecond = target.value
        end)

        TestEnv.RunToEnd(TestKit)
        assert.are.equal("original", seenBySecond)
    end)

    it("refuses a nil or NaN key and a target that is not a table", function()
        local messages = {}
        local suite = TestKit:Suite("MyAddon")
        suite:Test("bad arguments", function(ctx)
            local _, nilKey = pcall(ctx.Replace, ctx, {}, nil, 1)
            local _, nanKey = pcall(ctx.Replace, ctx, {}, 0 / 0, 1)
            local _, notTable = pcall(ctx.Replace, ctx, "text", "key", 1)
            messages = { nilKey, nanKey, notTable }
        end)

        TestEnv.RunToEnd(TestKit)
        assert.is_truthy(messages[1]:find("key must not be nil", 1, true))
        assert.is_truthy(messages[2]:find("key must not be NaN", 1, true))
        assert.is_truthy(messages[3]:find("target must be a table", 1, true))
    end)

    it("refuses a context used after its test finished", function()
        local kept = nil
        local suite = TestKit:Suite("MyAddon")
        suite:Test("keeps its context", function(ctx)
            kept = ctx
        end)

        TestEnv.RunToEnd(TestKit)
        TestEnv.expectErrorContaining(
            "TestKit.Context:Replace was called after its test finished",
            function()
                kept:Replace({}, "key", 1)
            end
        )
    end)
end)
