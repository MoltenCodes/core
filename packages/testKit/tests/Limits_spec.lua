local TestEnv = require("TestKitTestEnv")

-- Design principle 4a: every bound TestKit keeps is a default the consumer can
-- open. TestKit is development-only and retains the consumer's own tests, so
-- every limit but `maxEqualDepth` accepts `TestKit.UNBOUNDED`.

local function noop() end

local DEFAULTS = {
    maxSuites = 64,
    maxTests = 256,
    maxHooks = 16,
    maxLogLines = 64,
    maxFinishedCallbacks = 16,
    maxReplacements = 256,
    maxEqualDepth = 16,
}

describe("TestKit limits", function()
    local TestKit
    before_each(function()
        TestKit = TestEnv.NewReadyPackage("MyAddon")
    end)
    after_each(TestEnv.Reset)

    it("reports the defaults as a fresh table", function()
        local limits = TestKit:GetLimits()
        assert.are.same(DEFAULTS, limits)
        limits.maxSuites = 1
        assert.are.equal(64, TestKit:GetLimits().maxSuites)
        assert.are.equal("table", type(TestKit.UNBOUNDED))
    end)

    it("opens the 65th suite and lifts maxSuites with UNBOUNDED", function()
        TestKit:SetLimits({ maxSuites = 65 })
        for index = 1, 65 do
            assert.is_not_nil(TestKit:Suite("Suite" .. index))
        end
        assert.are.same({ nil, "full" }, { TestKit:Suite("Suite66") })

        TestKit:SetLimits({ maxSuites = TestKit.UNBOUNDED })
        assert.is_not_nil(TestKit:Suite("Suite66"))
    end)

    it("opens maxTests and maxHooks", function()
        TestKit:SetLimits({ maxTests = TestKit.UNBOUNDED, maxHooks = 17 })
        local suite = TestKit:Suite("Big")
        for index = 1, 300 do
            assert.is_true(suite:Test("test " .. index, noop))
        end
        for _ = 1, 17 do
            assert.is_true(suite:Before(noop))
        end
        assert.are.same({ nil, "full" }, { suite:Before(noop) })
    end)

    it("opens maxFinishedCallbacks", function()
        TestKit:SetLimits({ maxFinishedCallbacks = TestKit.UNBOUNDED })
        for _ = 1, 40 do
            assert.is_true(TestKit:OnFinished(noop))
        end
    end)

    it("opens maxLogLines and maxReplacements inside a test", function()
        TestKit:SetLimits({ maxLogLines = 70, maxReplacements = 300 })
        local accepted, replaced = 0, 0
        local target = {}
        local result = TestEnv.RunOne(TestKit, function(ctx)
            for index = 1, 71 do
                if ctx:Log("line " .. index) then
                    accepted = accepted + 1
                end
            end
            for index = 1, 300 do
                ctx:Replace(target, "key" .. index, index)
                replaced = replaced + 1
            end
            local _, reason = ctx:Replace(target, "one too many", 1)
            ctx:Expect(reason):ToBe("full")
        end)
        assert.are.equal("passed", result.status)
        assert.are.equal(70, accepted)
        assert.are.equal(70, #result.logs)
        assert.are.equal(300, replaced)
        assert.is_nil(next(target))
    end)

    it("raises maxEqualDepth up to 64 and refuses UNBOUNDED", function()
        TestKit:SetLimits({ maxEqualDepth = 20 })
        local deep, deepCopy = {}, {}
        local left, right = deep, deepCopy
        for _ = 1, 18 do
            left.next, right.next = {}, {}
            left, right = left.next, right.next
        end
        local result = TestEnv.RunOne(TestKit, function(ctx)
            ctx:Expect(deep):ToEqual(deepCopy)
        end)
        assert.are.equal("passed", result.status)

        TestEnv.expectErrorContaining(
            "limits.maxEqualDepth must be an integer from 1 to 64",
            function()
                TestKit:SetLimits({ maxEqualDepth = 65 })
            end
        )
        TestEnv.expectErrorContaining(
            "limits.maxEqualDepth cannot be TestKit.UNBOUNDED: ToEqual compares nested tables recursively",
            function()
                TestKit:SetLimits({ maxEqualDepth = TestKit.UNBOUNDED })
            end
        )
    end)

    it("applies a SetLimits table atomically and refuses bad input at the caller", function()
        TestEnv.expectErrorContaining(
            "limits.maxEqualDepth must be an integer from 1 to 64",
            function()
                TestKit:SetLimits({ maxSuites = 2, maxEqualDepth = 0 })
            end
        )
        assert.are.same(DEFAULTS, TestKit:GetLimits())

        TestEnv.expectErrorContaining("TestKit:SetLimits limits must be a table", function()
            TestKit:SetLimits("all")
        end)
        TestEnv.expectErrorContaining("limits.maxRuns is not a recognised limit", function()
            TestKit:SetLimits({ maxRuns = 2 })
        end)
        -- A table key is named by its type; its `__tostring` never runs.
        local ran = false
        local key = setmetatable({}, {
            __tostring = function()
                ran = true
                return "caller text"
            end,
        })
        TestEnv.expectErrorContaining("limits.<table> is not a recognised limit", function()
            TestKit:SetLimits({ [key] = 2 })
        end)
        assert.is_false(ran)
        for _, invalid in ipairs({ 0, -1, 1.5, "8", math.huge, 0 / 0, {} }) do
            TestEnv.expectErrorContaining(
                "limits.maxTests must be a positive integer or TestKit.UNBOUNDED",
                function()
                    TestKit:SetLimits({ maxTests = invalid })
                end
            )
        end

        local source = debug.getinfo(1, "S").short_src
        local line
        local ok, message = pcall(function()
            line = debug.getinfo(1, "l").currentline + 1
            TestKit:SetLimits({ maxHooks = 0 })
        end)
        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. line
                .. ": TestKit:SetLimits limits.maxHooks must be a positive integer"
                .. " or TestKit.UNBOUNDED",
            message
        )
        TestEnv.expectErrorContaining("must be called on the TestKit facade", function()
            TestKit.SetLimits({}, {})
        end)
        TestEnv.expectErrorContaining("must be called on the TestKit facade", function()
            TestKit.GetLimits({})
        end)
    end)

    it("keeps the limits across Reset", function()
        TestKit:SetLimits({ maxSuites = 3 })
        TestKit:Reset()
        assert.are.equal(3, TestKit:GetLimits().maxSuites)
    end)
end)
