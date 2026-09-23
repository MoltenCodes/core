local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit builders", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---Seal `node` and return whether `value` checks, and the failure's rule.
    ---@param node table
    ---@param value any
    ---@return boolean ok
    ---@return string? rule
    local function check(node, value)
        local ok, failure = S:Seal(node):Check(value)
        return ok, failure and failure.rule
    end

    describe("string", function()
        it("accepts any string without a spec", function()
            assert.is_true(check(S.string(), ""))
            assert.is_true(check(S.string({}), "anything"))
        end)

        it("refuses other types and nil", function()
            assert.are.same({ false, "type" }, { check(S.string(), 1) })
            assert.are.same({ false, "type" }, { check(S.string(), {}) })
            assert.are.same({ false, "required" }, { check(S.string(), nil) })
        end)

        it("bounds the length", function()
            local node = S.string({ min = 2, max = 4 })
            assert.is_true(check(node, "ab"))
            assert.is_true(check(node, "abcd"))
            assert.are.same({ false, "min" }, { check(node, "a") })
            assert.are.same({ false, "max" }, { check(node, "abcde") })
        end)

        it("matches a pattern", function()
            local node = S.string({ pattern = "^%a+$" })
            assert.is_true(check(node, "Frame"))
            assert.are.same({ false, "pattern" }, { check(node, "Frame1") })
        end)

        it("refuses at build time a pattern Lua would only reject while matching", function()
            -- Each of these finds nothing in "" without raising, so trying
            -- the pattern once is not enough: the matcher reports the broken
            -- part only when a subject gets that far.
            local malformed = { "a[", "a%", "(a", "a.)", "a%b", "a%bx", "a%fx", "(a)%2", "(a%1)" }
            for _, pattern in ipairs(malformed) do
                TestEnv.expectErrorContaining(
                    "SchemaKit.string pattern is not a valid Lua pattern",
                    function()
                        S.string({ pattern = pattern })
                    end
                )
            end
            TestEnv.expectErrorContaining(
                "SchemaKit.string pattern is not a valid Lua pattern",
                function()
                    S.string({ pattern = string.rep("()", 33) })
                end
            )
        end)

        it("accepts every well-formed pattern and checks with it", function()
            local subjects = { "", "a", "ab", "a]b", "(x)", "a%b", "x.y" }
            local wellFormed = {
                "a)",
                "^%a+$",
                "[]]",
                "[^]a]",
                "[%]]",
                "%bxy",
                "%f[%w]%w+",
                "(a)%1",
                "()a",
                "a$b",
                "a-b*c?d+",
                string.rep("()", 32),
            }
            for _, pattern in ipairs(wellFormed) do
                local schema = S:Seal(S.string({ pattern = pattern }))
                for _, subject in ipairs(subjects) do
                    local ok, failure = schema:Check(subject)
                    assert.are.equal(string.find(subject, pattern) ~= nil, ok)
                    if not ok then
                        assert.are.equal("pattern", failure.rule)
                    end
                end
            end
        end)

        it("restricts to a list", function()
            local node = S.string({ oneOf = { "TOP", "BOTTOM" } })
            assert.is_true(check(node, "TOP"))
            assert.are.same({ false, "enum" }, { check(node, "LEFT") })
        end)

        it("refuses invalid specs", function()
            TestEnv.expectErrorContaining("SchemaKit.string spec must be a table", function()
                S.string("x")
            end)
            TestEnv.expectErrorContaining(
                'SchemaKit.string spec contains unknown field "maxx"',
                function()
                    S.string({ maxx = 1 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string min must be a non-negative integer",
                function()
                    S.string({ min = -1 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string max must be a non-negative integer",
                function()
                    S.string({ max = 1.5 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string min must not be greater than max",
                function()
                    S.string({ min = 3, max = 2 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string pattern is not a valid Lua pattern",
                function()
                    S.string({ pattern = "[a" })
                end
            )
            TestEnv.expectErrorContaining("SchemaKit.string oneOf must not be empty", function()
                S.string({ oneOf = {} })
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.string oneOf must list strings only",
                function()
                    S.string({ oneOf = { "a", 1 } })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string oneOf values must not repeat",
                function()
                    S.string({ oneOf = { "a", "a" } })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.string is called with a dot, not a colon",
                function()
                    S:string({})
                end
            )
        end)
    end)

    describe("number", function()
        it("accepts numbers and refuses NaN", function()
            assert.is_true(check(S.number(), 0))
            assert.is_true(check(S.number(), -1.5))
            assert.are.same({ false, "type" }, { check(S.number(), "1") })
            assert.are.same({ false, "type" }, { check(S.number(), 0 / 0) })
        end)

        it("bounds the value inclusively", function()
            local node = S.number({ min = 0, max = 1 })
            assert.is_true(check(node, 0))
            assert.is_true(check(node, 1))
            assert.are.same({ false, "min" }, { check(node, -0.1) })
            assert.are.same({ false, "max" }, { check(node, 1.1) })
        end)

        it("restricts to finite whole numbers", function()
            local node = S.number({ integer = true })
            assert.is_true(check(node, 3))
            assert.are.same({ false, "integer" }, { check(node, 3.5) })
            assert.are.same({ false, "integer" }, { check(node, math.huge) })
        end)

        it("refuses invalid specs", function()
            TestEnv.expectErrorContaining("SchemaKit.number min must be a number", function()
                S.number({ min = "1" })
            end)
            TestEnv.expectErrorContaining("SchemaKit.number max must be a number", function()
                S.number({ max = 0 / 0 })
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.number min must not be greater than max",
                function()
                    S.number({ min = 2, max = 1 })
                end
            )
            TestEnv.expectErrorContaining("SchemaKit.number integer must be a boolean", function()
                S.number({ integer = 1 })
            end)
        end)
    end)

    describe("boolean", function()
        it("accepts true and false only", function()
            assert.is_true(check(S.boolean(), true))
            assert.is_true(check(S.boolean(), false))
            assert.are.same({ false, "type" }, { check(S.boolean(), 0) })
            assert.are.same({ false, "required" }, { check(S.boolean(), nil) })
        end)

        it("takes no arguments", function()
            TestEnv.expectErrorContaining("SchemaKit.boolean takes no arguments", function()
                S.boolean({})
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.boolean is called with a dot, not a colon",
                function()
                    S:boolean()
                end
            )
        end)
    end)

    describe("enum", function()
        it("accepts listed strings, numbers and booleans", function()
            local node = S.enum({ "a", 2, false })
            assert.is_true(check(node, "a"))
            assert.is_true(check(node, 2))
            assert.is_true(check(node, false))
            assert.are.same({ false, "enum" }, { check(node, "b") })
            assert.are.same({ false, "enum" }, { check(node, true) })
            assert.are.same({ false, "enum" }, { check(node, {}) })
        end)

        it("refuses invalid lists", function()
            TestEnv.expectErrorContaining("SchemaKit.enum values must be an array", function()
                S.enum("a")
            end)
            TestEnv.expectErrorContaining("SchemaKit.enum values must not be empty", function()
                S.enum({})
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.enum values must be an array without holes",
                function()
                    S.enum({ "a", nil, "c" })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.enum values must be strings, numbers or booleans",
                function()
                    S.enum({ {} })
                end
            )
            TestEnv.expectErrorContaining("SchemaKit.enum values must not be NaN", function()
                S.enum({ 0 / 0 })
            end)
        end)
    end)

    describe("table", function()
        it("checks declared fields and refuses undeclared ones", function()
            local node = S.table({ fields = { name = S.string(), level = S.number() } })
            assert.is_true(check(node, { name = "a", level = 1 }))
            assert.are.same({ false, "required" }, { check(node, { name = "a" }) })
            assert.are.same(
                { false, "unknown" },
                { check(node, { name = "a", level = 1, extra = true }) }
            )
            assert.are.same({ false, "type" }, { check(node, "table") })
        end)

        it("accepts undeclared fields when open", function()
            local node = S.table({ fields = { name = S.string() }, open = true })
            assert.is_true(check(node, { name = "a", extra = {} }))
        end)

        it("accepts an empty field set", function()
            assert.is_true(check(S.table({ fields = {} }), {}))
            assert.are.same({ false, "unknown" }, { check(S.table({ fields = {} }), { 1 }) })
        end)

        it("reads fields raw, ignoring a metatable on the value", function()
            local node = S.table({ fields = { name = S.string() } })
            local value = setmetatable({}, {
                __index = function()
                    return "from __index"
                end,
            })
            assert.are.same({ false, "required" }, { check(node, value) })
        end)

        it("refuses invalid specs", function()
            TestEnv.expectErrorContaining("SchemaKit.table spec must be a table", function()
                S.table()
            end)
            TestEnv.expectErrorContaining("SchemaKit.table fields must be a table", function()
                S.table({})
            end)
            -- A node is a table too; it must not read as a table with no fields.
            TestEnv.expectErrorContaining("SchemaKit.table fields must be a table", function()
                S.table({ fields = S.string() })
            end)
            TestEnv.expectErrorContaining("SchemaKit.table fields must be a table", function()
                S.table({ fields = S:Seal(S.string()) })
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.table field names must be non-empty strings",
                function()
                    S.table({ fields = { S.string() } })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.table fields.name must be a SchemaKit schema node or sealed schema",
                function()
                    S.table({ fields = { name = "string" } })
                end
            )
            TestEnv.expectErrorContaining("SchemaKit.table open must be a boolean", function()
                S.table({ fields = {}, open = 1 })
            end)
        end)
    end)

    describe("array", function()
        it("checks every element of a sequence", function()
            local node = S.array({ of = S.number() })
            assert.is_true(check(node, {}))
            assert.is_true(check(node, { 1, 2, 3 }))
            assert.are.same({ false, "type" }, { check(node, { 1, "2" }) })
        end)

        it("refuses holes and other keys", function()
            local node = S.array({ of = S.number() })
            assert.are.same({ false, "sequence" }, { check(node, { [1] = 1, [3] = 3 }) })
            local named = { 1 }
            named.name = 2
            assert.are.same({ false, "sequence" }, { check(node, named) })
        end)

        it("bounds the element count", function()
            local node = S.array({ of = S.number(), min = 1, max = 2 })
            assert.are.same({ false, "min" }, { check(node, {}) })
            assert.is_true(check(node, { 1, 2 }))
            assert.are.same({ false, "max" }, { check(node, { 1, 2, 3 }) })
        end)

        it("refuses invalid specs", function()
            TestEnv.expectErrorContaining(
                "SchemaKit.array of must be a SchemaKit schema node or sealed schema",
                function()
                    S.array({})
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.array max must be a non-negative integer",
                function()
                    S.array({ of = S.any(), max = -1 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.array min must not be greater than max",
                function()
                    S.array({ of = S.any(), min = 3, max = 2 })
                end
            )
        end)
    end)

    describe("map", function()
        it("checks every key and value", function()
            local node = S.map({ keys = S.string(), values = S.number(), max = 4 })
            assert.is_true(check(node, {}))
            assert.is_true(check(node, { a = 1, b = 2 }))
            assert.are.same({ false, "type" }, { check(node, { a = "1" }) })
            assert.are.same({ false, "type" }, { check(node, { [1] = 1 }) })
            assert.are.same(
                { false, "max" },
                { check(node, { a = 1, b = 2, c = 3, d = 4, e = 5 }) }
            )
        end)

        it("requires keys, values and max", function()
            TestEnv.expectErrorContaining(
                "SchemaKit.map keys must be a SchemaKit schema node",
                function()
                    S.map({ values = S.any(), max = 1 })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.map values must be a SchemaKit schema node",
                function()
                    S.map({ keys = S.string(), max = 1 })
                end
            )
            TestEnv.expectErrorContaining("SchemaKit.map max is required", function()
                S.map({ keys = S.string(), values = S.any() })
            end)
            TestEnv.expectErrorContaining("SchemaKit.map max must be a positive integer", function()
                S.map({ keys = S.string(), values = S.any(), max = 0 })
            end)
            TestEnv.expectErrorContaining("SchemaKit.map keys must not be optional", function()
                S.map({ keys = S.optional(S.string()), values = S.any(), max = 1 })
            end)
        end)
    end)

    describe("optional", function()
        it("accepts nil and otherwise checks the inner schema", function()
            local node = S.optional(S.number({ min = 1 }))
            assert.is_true(check(node, nil))
            assert.is_true(check(node, 2))
            assert.are.same({ false, "min" }, { check(node, 0) })
        end)

        it("does not fill the default during Check", function()
            local node = S.table({ fields = { scale = S.optional(S.number(), 1) } })
            local value = {}
            assert.is_true(check(node, value))
            assert.is_nil(value.scale)
        end)

        it("refuses a default the schema would refuse", function()
            TestEnv.expectErrorContaining(
                "SchemaKit.optional default: expected number >= 1, found smaller number",
                function()
                    S.optional(S.number({ min = 1 }), 0)
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.optional default.size: expected number, found string",
                function()
                    S.optional(S.table({ fields = { size = S.number() } }), { size = "big" })
                end
            )
        end)

        it("refuses a cyclic default and nested optionals", function()
            local cyclic = {}
            cyclic.self = cyclic
            TestEnv.expectErrorContaining(
                "SchemaKit.optional default nests deeper than 16 tables",
                function()
                    S.optional(S.any(), cyclic)
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.optional schema is already optional",
                function()
                    S.optional(S.optional(S.any()))
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.optional schema must be a SchemaKit schema node",
                function()
                    S.optional()
                end
            )
        end)
    end)

    describe("oneOf", function()
        it("accepts a value any alternative accepts", function()
            local node = S.oneOf({ S.string(), S.number({ integer = true }) })
            assert.is_true(check(node, "a"))
            assert.is_true(check(node, 1))
            assert.are.same({ false, "oneOf" }, { check(node, 1.5) })
            assert.are.same({ false, "oneOf" }, { check(node, true) })
            assert.are.same({ false, "required" }, { check(node, nil) })
        end)

        it("refuses invalid alternative lists", function()
            TestEnv.expectErrorContaining(
                "SchemaKit.oneOf alternatives must not be empty",
                function()
                    S.oneOf({})
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.oneOf alternatives[2] must be a SchemaKit schema node",
                function()
                    S.oneOf({ S.string(), "number" })
                end
            )
            TestEnv.expectErrorContaining(
                "SchemaKit.oneOf alternatives must not be optional; wrap the oneOf instead",
                function()
                    S.oneOf({ S.optional(S.string()) })
                end
            )
        end)
    end)

    describe("any", function()
        it("accepts every value except nil", function()
            local node = S.any()
            assert.is_true(check(node, false))
            assert.is_true(check(node, {}))
            assert.is_true(check(node, print))
            assert.are.same({ false, "required" }, { check(node, nil) })
        end)

        it("takes no arguments", function()
            TestEnv.expectErrorContaining("SchemaKit.any takes no arguments", function()
                S.any(1)
            end)
        end)
    end)

    describe("custom", function()
        it("accepts what the check accepts", function()
            local node = S.custom(function(value)
                return type(value) == "number" and value % 2 == 0
            end, "even number")
            assert.is_true(check(node, 4))
            assert.are.same({ false, "custom" }, { check(node, 3) })
            assert.are.same({ false, "required" }, { check(node, nil) })
        end)

        it("lets an error raised by the check propagate", function()
            local node = S.custom(function()
                error("custom check failed", 0)
            end, "anything")
            local schema = S:Seal(node)
            local ok, message = pcall(schema.Check, schema, 1)
            assert.is_false(ok)
            assert.are.equal("custom check failed", message)
        end)

        it("requires a function and a description", function()
            TestEnv.expectErrorContaining("SchemaKit.custom check must be a function", function()
                S.custom("x", "y")
            end)
            TestEnv.expectErrorContaining(
                "SchemaKit.custom description must be a non-empty string",
                function()
                    S.custom(function() end, "")
                end
            )
        end)
    end)

    describe("composition", function()
        it("accepts a sealed schema wherever a node is accepted", function()
            local point = S:Seal(S.table({ fields = { x = S.number(), y = S.number() } }))
            local path = S:Seal(S.array({ of = point, max = 8 }))
            assert.is_true(path:Check({ { x = 1, y = 2 } }))
            local ok, failure = path:Check({ { x = 1 } })
            assert.is_false(ok)
            assert.are.equal("[1].y", failure.path)
        end)

        it("shares one node between several parents", function()
            local name = S.string({ max = 4 })
            local node = S.table({ fields = { first = name, last = name } })
            local ok, failure = S:Seal(node):Check({ first = "Ann", last = "Longer" })
            assert.is_false(ok)
            assert.are.equal("last", failure.path)
        end)
    end)
end)
