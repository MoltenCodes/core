local TestEnv = require("SchemaKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that an action failed with `message` reported at `expectedLine` of
---this spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---A value of `depth` nested tables, each holding the next under `child`.
---@param depth integer
---@return table
local function nestedValue(depth)
    local value = {}
    for _ = 2, depth do
        value = { child = value }
    end
    return value
end

describe("SchemaKit limits", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---A sealed schema accepting `levels` nested tables of the `nestedValue` shape.
    ---@param levels integer
    ---@return table
    local function nestedSchema(levels)
        local node = S.table({ fields = {} })
        for _ = 2, levels do
            node = S.table({ fields = { child = S.optional(node) } })
        end
        return S:Seal(node)
    end

    it("reports the defaults in a fresh table", function()
        local limits = S:GetLimits()
        assert.are.same({
            maxDepth = 16,
            maxPatternCaptures = 32,
            pathKeyLimit = 32,
            defaultArrayMax = 1024,
        }, limits)
        assert.are_not.equal(limits, S:GetLimits())
        limits.maxDepth = 1
        assert.are.equal(16, S:GetLimits().maxDepth)
        assert.are.equal("table", type(S.UNBOUNDED))
    end)

    it("changes only the limits it is given", function()
        S:SetLimits({ pathKeyLimit = 8 })
        local limits = S:GetLimits()
        assert.are.equal(8, limits.pathKeyLimit)
        assert.are.equal(16, limits.maxDepth)
    end)

    it("honours maxDepth up to its ceiling of 64", function()
        local schema = nestedSchema(70)
        assert.is_false(schema:Check(nestedValue(17)))

        S:SetLimits({ maxDepth = 64 })
        assert.is_true(schema:Check(nestedValue(64)))
        local ok, failure = schema:Check(nestedValue(65))
        assert.is_false(ok)
        assert.are.equal("depth", failure.rule)
        assert.are.equal("at most 64 nested tables", failure.expected)

        S:SetLimits({ maxDepth = 2 })
        local _, shallow = schema:Check(nestedValue(3))
        assert.are.equal("at most 2 nested tables", shallow.expected)
    end)

    it("honours maxPatternCaptures, which can only be lowered", function()
        S:SetLimits({ maxPatternCaptures = 2 })
        assert.is_true(S:Seal(S.string({ pattern = "(a)(b)" })):Check("ab"))
        TestEnv.expectErrorContaining(
            "SchemaKit.string pattern is not a valid Lua pattern",
            function()
                S.string({ pattern = "(a)(b)(c)" })
            end
        )
    end)

    it("honours pathKeyLimit in failure paths", function()
        local schema = S:Seal(S.map({ keys = S.string(), values = S.number(), max = 4 }))
        local key = string.rep("k", 100)
        S:SetLimits({ pathKeyLimit = 100 })
        local _, whole = schema:Check({ [key] = "x" })
        -- Within the limit an identifier-like key is shown bare.
        assert.are.equal(key, whole.path)

        S:SetLimits({ pathKeyLimit = 4 })
        local _, cut = schema:Check({ [key] = "x" })
        assert.are.equal('["kkkk..."]', cut.path)
    end)

    it("applies defaultArrayMax to arrays built after the change", function()
        local before = S:Seal(S.array({ of = S.number() }))
        S:SetLimits({ defaultArrayMax = 2 })
        local after = S:Seal(S.array({ of = S.number() }))

        assert.is_true(before:Check({ 1, 2, 3 }))
        local ok, failure = after:Check({ 1, 2, 3 })
        assert.is_false(ok)
        assert.are.equal("array of at most 2 elements", failure.expected)
        assert.are.equal(2, after:Describe().max)
    end)

    it("lifts the default array bound with UNBOUNDED", function()
        S:SetLimits({ defaultArrayMax = S.UNBOUNDED })
        assert.are.equal(S.UNBOUNDED, S:GetLimits().defaultArrayMax)
        local schema = S:Seal(S.array({ of = S.number() }))
        local value = {}
        for index = 1, 5000 do
            value[index] = index
        end
        assert.is_true(schema:Check(value))
        local applied, copy = schema:Apply(value)
        assert.is_true(applied)
        assert.are.equal(5000, #copy)
        assert.is_nil(schema:Describe().max)

        -- An explicit max still bounds the array.
        local bounded = S:Seal(S.array({ of = S.number(), max = 3 }))
        assert.is_false(bounded:Check({ 1, 2, 3, 4 }))
    end)

    it("refuses UNBOUNDED where a ceiling protects the stack, the matcher or a message", function()
        local cases = {
            {
                "maxDepth",
                "checking, applying and default validation recurse once per nesting level of a value its sender shapes",
            },
            {
                "maxPatternCaptures",
                "Lua 5.1 raises on a pattern with more than 32 captures (LUA_MAXCAPTURES)",
            },
            { "pathKeyLimit", "failure paths print keys a received message chooses" },
        }
        for _, case in ipairs(cases) do
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                S:SetLimits({ [case[1]] = S.UNBOUNDED })
            end)
            assertReportedAt(
                line,
                "SchemaKit:SetLimits limits."
                    .. case[1]
                    .. " cannot be SchemaKit.UNBOUNDED: "
                    .. case[2],
                ok,
                value
            )
        end
    end)

    it(
        "refuses values past a ceiling and invalid values at the caller, changing nothing",
        function()
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                S:SetLimits({ pathKeyLimit = 8, maxDepth = 65 })
            end)
            assertReportedAt(
                line,
                "SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64: "
                    .. "checking, applying and default validation recurse once per nesting level of a value its sender shapes",
                ok,
                value
            )
            assert.are.equal(32, S:GetLimits().pathKeyLimit)

            local captureLine
            local captureOk, captureValue = pcall(function()
                captureLine = currentLine() + 1
                S:SetLimits({ maxPatternCaptures = 33 })
            end)
            assertReportedAt(
                captureLine,
                "SchemaKit:SetLimits limits.maxPatternCaptures must be an integer from 1 to 32: "
                    .. "Lua 5.1 raises on a pattern with more than 32 captures (LUA_MAXCAPTURES)",
                captureOk,
                captureValue
            )

            for _, invalid in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
                TestEnv.expectErrorContaining(
                    "SchemaKit:SetLimits limits.pathKeyLimit must be an integer from 1 to 1024",
                    function()
                        S:SetLimits({ pathKeyLimit = invalid })
                    end
                )
                TestEnv.expectErrorContaining(
                    "SchemaKit:SetLimits limits.defaultArrayMax must be a positive integer or SchemaKit.UNBOUNDED",
                    function()
                        S:SetLimits({ defaultArrayMax = invalid })
                    end
                )
            end

            local unknownLine
            local unknownOk, unknownValue = pcall(function()
                unknownLine = currentLine() + 1
                S:SetLimits({ maxWidth = 1 })
            end)
            assertReportedAt(
                unknownLine,
                "SchemaKit:SetLimits limits.maxWidth is not a recognised limit",
                unknownOk,
                unknownValue
            )

            local tableLine
            local tableOk, tableValue = pcall(function()
                tableLine = currentLine() + 1
                S:SetLimits(8)
            end)
            assertReportedAt(
                tableLine,
                "SchemaKit:SetLimits limits must be a table",
                tableOk,
                tableValue
            )

            local dotLine
            local dotOk, dotValue = pcall(function()
                dotLine = currentLine() + 1
                S.SetLimits({ maxDepth = 8 })
            end)
            assertReportedAt(
                dotLine,
                "SchemaKit:SetLimits is called with a colon, not a dot",
                dotOk,
                dotValue
            )

            local getLine
            local getOk, getValue = pcall(function()
                getLine = currentLine() + 1
                S.GetLimits()
            end)
            assertReportedAt(
                getLine,
                "SchemaKit:GetLimits is called with a colon, not a dot",
                getOk,
                getValue
            )

            assert.are.same({
                maxDepth = 16,
                maxPatternCaptures = 32,
                pathKeyLimit = 32,
                defaultArrayMax = 1024,
            }, S:GetLimits())
        end
    )

    it("keeps the limits a consumer set and the sentinel across an in-place upgrade", function()
        local sentinel = S.UNBOUNDED
        S:SetLimits({ maxDepth = 4, pathKeyLimit = 5, defaultArrayMax = sentinel })
        local schema = nestedSchema(10)

        local nextRevision = S.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(sentinel, upgraded._state.unbounded)
        assert.are.same(
            { maxDepth = 4, maxPatternCaptures = 32, pathKeyLimit = 5, defaultArrayMax = sentinel },
            upgraded:GetLimits()
        )

        -- The upgraded checker and builders run under the inherited limits.
        local _, failure = schema:Check(nestedValue(5))
        assert.are.equal("at most 4 nested tables", failure.expected)
        local value = {}
        for index = 1, 2000 do
            value[index] = index
        end
        assert.is_true(upgraded:Seal(upgraded.array({ of = upgraded.number() })):Check(value))
    end)
end)
