local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit sealed immutability", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("refuses writes to a sealed schema", function()
        local schema = S:Seal(S.number())
        TestEnv.expectErrorContaining(
            "SchemaKit schemas are sealed and cannot be modified",
            function()
                schema.Check = function()
                    return true
                end
            end
        )
        TestEnv.expectErrorContaining(
            "SchemaKit schemas are sealed and cannot be modified",
            function()
                schema.extra = 1
            end
        )
        assert.is_false((schema:Check("a")))
    end)

    it("refuses writes to a node", function()
        local node = S.string()
        TestEnv.expectErrorContaining("SchemaKit schema nodes are immutable", function()
            node.max = 1
        end)
    end)

    it("protects both metatables", function()
        local node = S.string()
        local schema = S:Seal(node)
        assert.are.equal("SchemaKit.Schema", getmetatable(schema))
        assert.are.equal("SchemaKit.Node", getmetatable(node))
        assert.has_error(function()
            setmetatable(schema, nil)
        end)
        assert.has_error(function()
            setmetatable(node, nil)
        end)
    end)

    it("is unaffected by later edits to the spec tables it was built from", function()
        local fields = { name = S.string() }
        local list = { "a", "b" }
        local node = S.table({ fields = fields })
        local mode = S.enum(list)
        fields.extra = S.any()
        list[3] = "c"

        assert.are.equal("unknown", select(2, S:Seal(node):Check({ name = "x", extra = 1 })).rule)
        assert.is_false((S:Seal(mode):Check("c")))
    end)

    it("is unaffected by later edits to a default or to a description", function()
        local default = { size = 1 }
        local schema = S:Seal(S.table({
            fields = { box = S.optional(S.table({ fields = { size = S.number() } }), default) },
        }))
        default.size = "big"
        local ok, result = schema:Apply({})
        assert.is_true(ok)
        assert.are.equal(1, result.box.size)

        local description = schema:Describe()
        description.fields.box.default.size = 99
        description.fieldNames[1] = "changed"
        assert.are.equal(1, schema:Describe().fields.box.default.size)
        assert.are.equal("box", schema:Describe().fieldNames[1])
    end)

    it("does not recognise a forged schema or node", function()
        local forged = setmetatable({}, { __index = S.Schema })
        TestEnv.expectErrorContaining(
            "SchemaKit.Schema:Check must be called on a sealed SchemaKit schema",
            function()
                forged:Check(1)
            end
        )
        TestEnv.expectErrorContaining(
            "SchemaKit:Seal node must be a SchemaKit schema node or sealed schema",
            function()
                S:Seal({ kind = "string" })
            end
        )
    end)

    it("seals a sealed schema again with its own options and failure table", function()
        local first = S:Seal(S.number())
        local second = S:Seal(first, { freshFailures = true })
        assert.are_not.equal(first, second)
        local _, a = second:Check("x")
        local _, b = second:Check("x")
        assert.are_not.equal(a, b)
        local _, c = first:Check("x")
        local _, d = first:Check("x")
        assert.are.equal(c, d)
    end)

    it("refuses invalid Seal options", function()
        TestEnv.expectErrorContaining("SchemaKit:Seal options must be a table", function()
            S:Seal(S.any(), true)
        end)
        TestEnv.expectErrorContaining(
            'SchemaKit:Seal options contains unknown field "fresh"',
            function()
                S:Seal(S.any(), { fresh = true })
            end
        )
        TestEnv.expectErrorContaining("SchemaKit:Seal freshFailures must be a boolean", function()
            S:Seal(S.any(), { freshFailures = 1 })
        end)
    end)
end)
