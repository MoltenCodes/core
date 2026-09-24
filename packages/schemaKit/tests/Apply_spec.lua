local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit Apply", function()
  local S
  before_each(function()
    S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("fills defaults into a copy and leaves the value untouched", function()
    local schema = S:Seal(S.table({
      fields = {
        enabled = S.optional(S.boolean(), true),
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        name = S.string(),
        position = S.optional(
          S.table({
            fields = { x = S.optional(S.number(), 0), y = S.optional(S.number(), 0) },
          }),
          {}
        ),
      },
    }))

    local saved = { name = "Main", scale = 1.5 }
    local ok, result = schema:Apply(saved)
    assert.is_true(ok)
    assert.are.same(
      { enabled = true, scale = 1.5, name = "Main", position = { x = 0, y = 0 } },
      result
    )
    assert.are_not.equal(saved, result)
    assert.are.same({ name = "Main", scale = 1.5 }, saved)
  end)

  it("keeps a false value instead of the default", function()
    local schema = S:Seal(S.table({ fields = { enabled = S.optional(S.boolean(), true) } }))
    local _, result = schema:Apply({ enabled = false })
    assert.is_false(result.enabled)
  end)

  it("copies a table default freshly on every call", function()
    local schema = S:Seal(S.table({
      fields = { tags = S.optional(S.array({ of = S.string() }), { "a" }) },
    }))
    local _, first = schema:Apply({})
    local _, second = schema:Apply({})
    assert.are_not.equal(first.tags, second.tags)
    first.tags[2] = "b"
    assert.are.same({ "a" }, second.tags)
    local _, third = schema:Apply({})
    assert.are.same({ "a" }, third.tags)
  end)

  it("fills per-entry defaults of a map (a wildcard default)", function()
    local entry = S.table({
      fields = {
        shown = S.optional(S.boolean(), true),
        color = S.optional(S.string(), "white"),
      },
    })
    local schema = S:Seal(S.map({ keys = S.string(), values = S.optional(entry, {}), max = 64 }))

    local ok, result = schema:Apply({ fireball = { color = "red" }, frostbolt = {} })
    assert.is_true(ok)
    assert.are.same({
      fireball = { shown = true, color = "red" },
      frostbolt = { shown = true, color = "white" },
    }, result)

    local description = schema:Describe()
    assert.are.same({}, description.values.default)
  end)

  it("fills per-element defaults of an array", function()
    local schema = S:Seal(S.array({
      of = S.table({ fields = { id = S.number(), count = S.optional(S.number(), 1) } }),
      max = 8,
    }))
    local ok, result = schema:Apply({ { id = 1 }, { id = 2, count = 5 } })
    assert.is_true(ok)
    assert.are.same({ { id = 1, count = 1 }, { id = 2, count = 5 } }, result)
  end)

  it("fills a root default for nil and returns nil for an optional without one", function()
    local withDefault =
      S:Seal(S.optional(S.table({ fields = { a = S.optional(S.number(), 1) } }), {}))
    local ok, result = withDefault:Apply(nil)
    assert.is_true(ok)
    assert.are.same({ a = 1 }, result)

    local withoutDefault = S:Seal(S.optional(S.number()))
    local okNil, resultNil = withoutDefault:Apply(nil)
    assert.is_true(okNil)
    assert.is_nil(resultNil)
  end)

  it("returns false and the failure when the filled copy does not check", function()
    local schema = S:Seal(S.table({
      fields = { size = S.optional(S.number(), 1), name = S.string() },
    }))
    local ok, failure = schema:Apply({ size = 2 })
    assert.is_false(ok)
    assert.are.same(
      { path = "name", rule = "required", expected = "string", found = "nil" },
      failure
    )

    local okClosed, closed = schema:Apply({ name = "a", other = 1 })
    assert.is_false(okClosed)
    assert.are.equal("unknown", closed.rule)
  end)

  it("keeps undeclared fields of an open table", function()
    local shared = {}
    local schema = S:Seal(S.table({ fields = { a = S.optional(S.number(), 1) }, open = true }))
    local _, result = schema:Apply({ extra = shared })
    assert.are.equal(1, result.a)
    assert.are.equal(shared, result.extra)
  end)

  it("applies the first oneOf alternative that accepts the filled copy", function()
    local schema = S:Seal(S.oneOf({
      S.table({
        fields = { kind = S.enum({ "circle" }), radius = S.optional(S.number(), 1) },
      }),
      S.table({ fields = { kind = S.enum({ "square" }), side = S.optional(S.number(), 2) } }),
    }))
    local ok, result = schema:Apply({ kind = "square" })
    assert.is_true(ok)
    assert.are.same({ kind = "square", side = 2 }, result)

    local okBad, failure = schema:Apply({ kind = "triangle" })
    assert.is_false(okBad)
    assert.are.equal("oneOf", failure.rule)
  end)

  it("fails an oversized or too deep value with the same rule as Check", function()
    local schema = S:Seal(S.array({ of = S.number(), max = 2 }))
    local ok, failure = schema:Apply({ 1, 2, 3 })
    assert.is_false(ok)
    assert.are.equal("max", failure.rule)

    local holes = S:Seal(S.array({ of = S.number() }))
    local okHoles, holesFailure = holes:Apply({ [1] = 1, [3] = 3 })
    assert.is_false(okHoles)
    assert.are.equal("sequence", holesFailure.rule)
  end)
end)
