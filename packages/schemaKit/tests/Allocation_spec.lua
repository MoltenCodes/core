local TestEnv = require("SchemaKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("SchemaKit allocation #allocation", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---A settings-shaped schema touching every kind that recurses.
    ---@return table schema
    ---@return table value
    local function settingsSchema()
        local schema = S:Seal(S.table({
            fields = {
                enabled = S.boolean(),
                scale = S.number({ min = 0.5, max = 2 }),
                name = S.string({ max = 32, pattern = "^%a+$" }),
                anchor = S.string({ oneOf = { "TOP", "BOTTOM" } }),
                mode = S.enum({ "compact", "full" }),
                offset = S.oneOf({
                    S.number(),
                    S.table({ fields = { x = S.number(), y = S.number() } }),
                }),
                bars = S.array({
                    of = S.table({
                        fields = {
                            id = S.number({ integer = true }),
                            label = S.optional(S.string()),
                        },
                    }),
                    max = 8,
                }),
                colors = S.map({
                    keys = S.string(),
                    values = S.array({ of = S.number(), max = 4 }),
                    max = 16,
                }),
                extra = S.optional(S.any()),
                even = S.custom(function(value)
                    return type(value) == "number" and value % 2 == 0
                end, "even number"),
            },
        }))
        local value = {
            enabled = true,
            scale = 1,
            name = "Main",
            anchor = "TOP",
            mode = "full",
            offset = { x = 1, y = 2 },
            bars = { { id = 1, label = "one" }, { id = 2 } },
            colors = { red = { 1, 0, 0, 1 }, blue = { 0, 0, 1 } },
            even = 4,
        }
        return schema, value
    end

    it("allocates nothing for a valid Check of a nested table", function()
        local schema, value = settingsSchema()
        assert.is_true(schema:Check(value))

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                schema:Check(value)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Check allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing for a valid Check with a secret probe installed", function()
        local schema, value = settingsSchema()
        TestEnv.InstallSecretProbe({})
        assert.is_true(schema:Check(value))

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                schema:Check(value)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Check allocated " .. allocated .. " KiB")
    end)

    it("allocates nothing for a passing Assert", function()
        local schema, value = settingsSchema()
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                schema:Assert(value, "settings", 1)
            end
        end)
        assert.is_true(allocated < THRESHOLD_KILOBYTES, "Assert allocated " .. allocated .. " KiB")
    end)

    it("reuses the failure table for a root failure without allocating", function()
        local schema = S:Seal(S.number())
        local _, first = schema:Check("a")
        local otherTables = 0
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                local _, failure = schema:Check("a")
                if failure ~= first then
                    otherTables = otherTables + 1
                end
            end
        end)
        assert.are.equal(0, otherTables)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "failing Check allocated " .. allocated .. " KiB"
        )
    end)
end)
