local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit bounds", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---Build a schema of `levels` nested tables, each with one `child` field,
    ---and a value of `depth` nested tables of the same shape.
    ---@param levels integer
    ---@param depth integer
    ---@return table schema
    ---@return table value
    local function nested(levels, depth)
        local node = S.table({ fields = {} })
        for _ = 2, levels do
            node = S.table({ fields = { child = S.optional(node) } })
        end
        local value = {}
        for _ = 2, depth do
            value = { child = value }
        end
        return S:Seal(node), value
    end

    it("publishes its bounds", function()
        assert.are.equal(16, S.MAX_DEPTH)
        assert.are.equal(1024, S.DEFAULT_ARRAY_MAX)
    end)

    it("accepts a value 16 tables deep", function()
        local schema, value = nested(20, 16)
        assert.is_true(schema:Check(value))
    end)

    it("refuses a value 17 tables deep with rule depth", function()
        local schema, value = nested(20, 17)
        local ok, failure = schema:Check(value)
        assert.is_false(ok)
        assert.are.equal("depth", failure.rule)
        assert.are.equal("at most 16 nested tables", failure.expected)
        -- Lua 5.1's `string.rep` has no separator argument.
        local segments = {}
        for index = 1, 16 do
            segments[index] = "child"
        end
        assert.are.equal(table.concat(segments, "."), failure.path)

        local applied, applyFailure = schema:Apply(value)
        assert.is_false(applied)
        assert.are.equal("depth", applyFailure.rule)
    end)

    it("refuses an array over the default bound with rule max", function()
        local schema = S:Seal(S.array({ of = S.number() }))
        local value = {}
        for index = 1, 1024 do
            value[index] = index
        end
        assert.is_true(schema:Check(value))

        value[1025] = 1025
        local ok, failure = schema:Check(value)
        assert.is_false(ok)
        assert.are.equal("max", failure.rule)
        assert.are.equal("array of at most 1024 elements", failure.expected)
        assert.are.equal("table with more than 1024 entries", failure.found)
    end)

    it("stops counting an oversized array one past its bound", function()
        -- Every element is invalid, so reaching any element would report a
        -- type failure instead of the size failure.
        local schema = S:Seal(S.array({ of = S.number(), max = 3 }))
        local ok, failure = schema:Check({ "a", "b", "c", "d", "e" })
        assert.is_false(ok)
        assert.are.equal("max", failure.rule)
    end)

    it("refuses a map over its bound with rule max", function()
        local schema = S:Seal(S.map({ keys = S.number(), values = S.boolean(), max = 100 }))
        local value = {}
        for index = 1, 5000 do
            value[index] = true
        end
        local ok, failure = schema:Check(value)
        assert.is_false(ok)
        assert.are.equal("max", failure.rule)
        assert.are.equal("table with more than 100 entries", failure.found)
    end)

    it("stops at the first undeclared key of a closed table", function()
        local schema = S:Seal(S.table({ fields = { a = S.optional(S.number()) } }))
        local value = {}
        for index = 1, 5000 do
            value["key" .. index] = index
        end
        local ok, failure = schema:Check(value)
        assert.is_false(ok)
        assert.are.equal("unknown", failure.rule)
    end)
end)
