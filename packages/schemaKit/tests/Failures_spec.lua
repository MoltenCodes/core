local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit failures", function()
  local S
  before_each(function()
    S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reports path, rule, expected and found", function()
    local schema = S:Seal(S.table({
      fields = {
        frames = S.array({
          of = S.table({ fields = { point = S.string({ oneOf = { "TOP", "BOTTOM" } }) } }),
          max = 8,
        }),
      },
    }))

    local ok, failure = schema:Check({ frames = { { point = "TOP" }, {}, { point = "LEFT" } } })
    assert.is_false(ok)
    assert.are.same({
      path = "frames[2].point",
      rule = "required",
      expected = 'one of "TOP", "BOTTOM"',
      found = "nil",
    }, failure)
  end)

  it("reports the first failing field in sorted name order", function()
    local schema = S:Seal(S.table({ fields = { b = S.number(), a = S.number(), c = S.number() } }))
    local _, failure = schema:Check({ a = 1 })
    assert.are.equal("b", failure.path)
  end)

  it("never includes the checked value", function()
    local schema = S:Seal(S.table({
      fields = {
        name = S.string({ max = 3, pattern = "^%a+$" }),
        level = S.number({ max = 10 }),
        mode = S.enum({ "a", "b" }),
      },
    }))

    local _, nameFailure = schema:Check({ name = "Password123", level = 1, mode = "a" })
    assert.are.equal("string of length 11", nameFailure.found)
    assert.is_nil(nameFailure.expected:find("Password", 1, true))

    local _, levelFailure = schema:Check({ name = "abc", level = 987654, mode = "a" })
    assert.are.equal("larger number", levelFailure.found)
    assert.is_nil(levelFailure.expected:find("987654", 1, true))

    local _, modeFailure = schema:Check({ name = "abc", level = 1, mode = "hunter2" })
    assert.are.equal("unlisted string", modeFailure.found)
    assert.are.equal("enum", modeFailure.rule)
  end)

  it("reuses one failure table per schema", function()
    local schema = S:Seal(S.number())
    local _, first = schema:Check("a")
    local _, second = schema:Check(true)
    assert.are.equal(first, second)
    assert.are.equal("boolean", second.found)
    assert.are.equal("", second.path)
  end)

  it("returns a fresh failure table with freshFailures", function()
    local schema = S:Seal(S.number(), { freshFailures = true })
    local _, first = schema:Check("a")
    local _, second = schema:Check(true)
    assert.are_not.equal(first, second)
    assert.are.equal("string", first.found)
    assert.are.equal("boolean", second.found)
  end)

  it("gives each schema its own failure table", function()
    local node = S.number()
    local left, right = S:Seal(node), S:Seal(node)
    local _, leftFailure = left:Check("a")
    local _, rightFailure = right:Check(true)
    assert.are_not.equal(leftFailure, rightFailure)
    assert.are.equal("string", leftFailure.found)
  end)

  it("renders unusual keys safely and briefly", function()
    local schema = S:Seal(S.map({ keys = S.any(), values = S.number(), max = 4 }))

    local _, spaced = schema:Check({ ["two words"] = "x" })
    assert.are.equal('["two words"]', spaced.path)

    local _, long = schema:Check({ [string.rep("k", 40)] = "x" })
    assert.are.equal('["' .. string.rep("k", 32) .. '..."]', long.path)

    local _, newline = schema:Check({ ["a\nb"] = "x" })
    assert.are.equal('["a\\010b"]', newline.path)

    local _, boolean = schema:Check({ [true] = "x" })
    assert.are.equal("[true]", boolean.path)

    local _, fraction = schema:Check({ [1.5] = "x" })
    assert.are.equal("[1.5]", fraction.path)

    local _, tableKey = schema:Check({ [{}] = "x" })
    assert.are.equal("[table]", tableKey.path)
  end)

  it("makes World of Warcraft escape codes and control bytes in keys visible", function()
    local schema = S:Seal(S.map({ keys = S.any(), values = S.number(), max = 4 }))

    local _, texture = schema:Check({ ["|Tx:999|t\27"] = "x" })
    assert.are.equal('["||Tx:999||t\\027"]', texture.path)

    local _, controls = schema:Check({ ['a\0b\rc\127d\\e"f'] = "x" })
    assert.are.equal('["a\\000b\\013c\\127d\\\\e\\"f"]', controls.path)

    -- No raw pipe or control byte survives anywhere in the path.
    assert.is_nil(texture.path:find("%c"))
    assert.is_nil(texture.path:gsub("||", ""):find("|", 1, true))
  end)

  it("never cuts a long key inside a UTF-8 sequence", function()
    local schema = S:Seal(S.map({ keys = S.any(), values = S.number(), max = 4 }))
    -- 31 ASCII bytes, then "é" (0xC3 0xA9) straddling the 32-byte limit.
    local key = string.rep("a", 31) .. "\195\169" .. "tail"
    local _, failure = schema:Check({ [key] = "x" })
    assert.are.equal('["' .. string.rep("a", 31) .. '..."]', failure.path)

    -- A sequence that ends exactly at the limit is kept whole.
    local whole = string.rep("a", 30) .. "\195\169" .. "tail"
    local _, kept = schema:Check({ [whole] = "x" })
    assert.are.equal('["' .. string.rep("a", 30) .. '\195\169..."]', kept.path)
  end)

  it("names a failing map key as a key", function()
    local schema = S:Seal(S.map({ keys = S.string(), values = S.any(), max = 4 }))
    local ok, failure = schema:Check({ [7] = true })
    assert.is_false(ok)
    assert.are.same(
      { path = "[7]", rule = "type", expected = "key string", found = "number" },
      failure
    )
  end)

  it("reports a oneOf failure at the oneOf, not inside an alternative", function()
    local schema = S:Seal(S.table({
      fields = {
        anchor = S.oneOf({
          S.string(),
          S.table({ fields = { x = S.number(), y = S.number() } }),
        }),
      },
    }))
    local ok, failure = schema:Check({ anchor = { x = 1 } })
    assert.is_false(ok)
    assert.are.same({
      path = "anchor",
      rule = "oneOf",
      expected = "string or table",
      found = "table",
    }, failure)
  end)

  it("reports undeclared fields with rule unknown", function()
    local schema = S:Seal(S.table({ fields = { a = S.number() } }))
    local _, failure = schema:Check({ a = 1, zzz = 2 })
    assert.are.same({
      path = "zzz",
      rule = "unknown",
      expected = "only declared fields",
      found = "undeclared field",
    }, failure)
  end)

  it("reports a custom check with its description", function()
    local schema = S:Seal(S.array({
      of = S.custom(function(value)
        return value == "ok"
      end, "the string ok"),
    }))
    local _, failure = schema:Check({ "ok", "no" })
    assert.are.same(
      { path = "[2]", rule = "custom", expected = "the string ok", found = "string" },
      failure
    )
  end)

  it("reports number rule details", function()
    local schema = S:Seal(S.number({ integer = true, min = 1, max = 5 }))
    local _, fraction = schema:Check(1.5)
    assert.are.same({ "integer", "integer", "fractional number" }, {
      fraction.rule,
      fraction.expected,
      fraction.found,
    })
    local _, small = schema:Check(0)
    assert.are.same(
      { "min", "integer >= 1", "smaller number" },
      { small.rule, small.expected, small.found }
    )
    local _, nan = schema:Check(0 / 0)
    assert.are.same({ "type", "NaN" }, { nan.rule, nan.found })
  end)

  it("stays correct when a custom check re-enters the same schema", function()
    local schema
    local inner = S.custom(function(value)
      if type(value) == "table" then
        return (schema:Check(value.child))
      end
      return value == 1
    end, "one or a table holding one")
    schema = S:Seal(S.array({ of = inner, max = 4 }))

    assert.is_true(schema:Check({ 1, { child = { 1 } } }))
    local ok, failure = schema:Check({ 1, { child = { 2 } } })
    assert.is_false(ok)
    assert.are.equal("[2]", failure.path)
    assert.are.equal("custom", failure.rule)
  end)
end)
