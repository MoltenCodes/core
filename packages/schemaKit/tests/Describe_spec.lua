local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit Describe", function()
  local S
  before_each(function()
    S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("describes every kind as a plain table", function()
    local schema = S:Seal(S.table({
      fields = {
        name = S.string({ min = 1, max = 32, pattern = "^%a+$" }),
        anchor = S.optional(S.string({ oneOf = { "TOP", "BOTTOM" } }), "TOP"),
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        count = S.number({ integer = true }),
        shown = S.boolean(),
        mode = S.enum({ "compact", 2, true }),
        bars = S.array({ of = S.any(), min = 1 }),
        byName = S.map({
          keys = S.string(),
          values = S.optional(S.boolean(), false),
          max = 8,
        }),
        offset = S.oneOf({ S.number(), S.string() }),
        even = S.custom(function()
          return true
        end, "even number"),
      },
      open = true,
    }))

    assert.are.same({
      kind = "table",
      open = true,
      fieldNames = {
        "anchor",
        "bars",
        "byName",
        "count",
        "even",
        "mode",
        "name",
        "offset",
        "scale",
        "shown",
      },
      fields = {
        name = { kind = "string", min = 1, max = 32, pattern = "^%a+$" },
        anchor = {
          kind = "string",
          oneOf = { "TOP", "BOTTOM" },
          optional = true,
          default = "TOP",
        },
        scale = {
          kind = "number",
          min = 0.5,
          max = 2,
          integer = false,
          optional = true,
          default = 1,
        },
        count = { kind = "number", integer = true },
        shown = { kind = "boolean" },
        mode = { kind = "enum", values = { "compact", 2, true } },
        bars = { kind = "array", of = { kind = "any" }, min = 1, max = 1024 },
        byName = {
          kind = "map",
          keys = { kind = "string" },
          values = { kind = "boolean", optional = true, default = false },
          max = 8,
        },
        offset = {
          kind = "oneOf",
          alternatives = { { kind = "number", integer = false }, { kind = "string" } },
        },
        even = { kind = "custom", description = "even number" },
      },
    }, schema:Describe())
  end)

  it("returns a fresh table on every call", function()
    local schema = S:Seal(S.array({ of = S.string() }))
    local first = schema:Describe()
    local second = schema:Describe()
    assert.are_not.equal(first, second)
    assert.are_not.equal(first.of, second.of)
    assert.are.same(first, second)
  end)

  it("describes an optional root", function()
    local schema = S:Seal(S.optional(S.number()))
    assert.are.same({ kind = "number", integer = false, optional = true }, schema:Describe())
  end)
end)
