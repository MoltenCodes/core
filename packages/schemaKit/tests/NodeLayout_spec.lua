local TestEnv = require("SchemaKitTestEnv")

-- The fields a layout 1 node (revisions 1 to 5) held, `false` when unused.
local LAYOUT_1_FIELDS = {
  "min",
  "max",
  "expectedMin",
  "expectedMax",
  "foundMax",
  "pattern",
  "expectedPattern",
  "valueSet",
  "valueList",
  "expectedEnum",
  "integer",
  "fieldNames",
  "fieldNodes",
  "fieldSet",
  "open",
  "of",
  "keys",
  "values",
  "inner",
  "hasDefault",
  "default",
  "alternatives",
  "check",
}

---Count the fields of a table.
---@param node table
---@return integer
local function countFields(node)
  local count = 0
  for _ in next, node do
    count = count + 1
  end
  return count
end

---Turn a compiled node into the fixed shape revisions 1 to 5 built.
---@param node table
local function makeLayout1(node)
  for index = 1, #LAYOUT_1_FIELDS do
    local field = LAYOUT_1_FIELDS[index]
    if node[field] == nil then
      node[field] = false
    end
  end
  node.layout = 1
end

describe("SchemaKit compiled node layout", function()
  after_each(TestEnv.Reset)

  it("builds nodes holding only the fields their kind uses", function()
    local S = TestEnv.NewPackage()
    local nodes = S._state.nodes
    local number = S.number()
    local boolean = S.boolean()
    local ranged = S.number({ min = 1, max = 2, integer = true })
    local closed = S.table({ fields = { x = number } })

    assert.are.equal(3, countFields(nodes[number]))
    assert.are.equal(3, countFields(nodes[boolean]))
    assert.are.equal(2, nodes[number].layout)
    assert.is_nil(nodes[number].integer)
    assert.is_true(nodes[ranged].integer)
    assert.is_nil(nodes[closed].open)
    for _, node in next, nodes do
      for _, value in next, node do
        assert.is_not_false(value)
      end
    end
  end)

  it("describes sparse nodes exactly as fixed ones were described", function()
    local S = TestEnv.NewPackage()
    assert.are.same({ kind = "number", integer = false }, S:Seal(S.number()):Describe())
    assert.are.same(
      { kind = "table", open = false, fieldNames = { "x" }, fields = { x = { kind = "boolean" } } },
      S:Seal(S.table({ fields = { x = S.boolean() } })):Describe()
    )
  end)

  it("rebuilds layout 1 nodes as sparse nodes on an upgrade from revision 5", function()
    local working = TestEnv.NewPackage().REVISION
    TestEnv.Reset()
    require("Registry")
    local previous = TestEnv.LoadRevision(5)
    local S = previous
    -- The spec holds this proxy: `state.nodes` is weak-keyed, so a proxy
    -- only a parent's compiled node refers to may leave the table at any
    -- collection (coverage runs allocate enough to trigger one).
    local optionalWithFalseDefault = S.optional(S.boolean(), false)
    local point = S.table({
      fields = {
        x = S.number({ min = 0 }),
        y = optionalWithFalseDefault,
        tag = S.optional(S.string({ pattern = "^%a+$" })),
        kind = S.enum({ "a", "b" }),
      },
    })
    local schema = S:Seal(S.array({ of = point, max = 3 }))
    -- A map and a oneOf, so every kind of child reference is re-pointed.
    local other =
      S:Seal(S.oneOf({ S.map({ keys = S.string(), values = point, max = 4 }), S.boolean() }))
    local _, failure = schema:Check({ { x = -1, kind = "a" } })
    assert.are.equal("[1].x", failure.path)
    local before = schema:Describe()

    local nodes = previous._state.nodes
    local oldPoint = nodes[point]
    for _, node in next, nodes do
      makeLayout1(node)
    end
    assert.are.equal(26, countFields(oldPoint))

    local current = require("SchemaKit")
    assert.are.equal(previous, current)
    assert.are.equal(working, current.REVISION)
    -- Revision 5 kept no members for the parts to replace: `Apply` comes
    -- from the Apply part, as in a session that embeds it.
    TestEnv.LoadPart("Rules")
    TestEnv.LoadPart("Apply")

    -- Every node behind a proxy is a sparse copy, and the children point
    -- at the copies too.
    for _, node in next, nodes do
      assert.are.equal(2, node.layout)
      for field, value in next, node do
        if field ~= "default" then
          assert.is_not_false(value)
        end
      end
    end
    local newPoint = nodes[point]
    assert.are_not.equal(oldPoint, newPoint)
    assert.are.equal(nodes[point].fieldNodes[1], nodes[point].fieldNodes[1])
    for index = 1, #newPoint.fieldNodes do
      assert.are.equal(2, newPoint.fieldNodes[index].layout)
    end

    -- The declared `false` default survives, and the schema still checks,
    -- fails, applies and describes as before, also after a full collection
    -- has cleared the entries of proxies nobody holds.
    collectgarbage("collect")
    local optionalNode = nodes[optionalWithFalseDefault]
    assert.are.equal("optional", optionalNode.kind)
    assert.is_true(optionalNode.hasDefault)
    assert.is_false(optionalNode.default)
    -- Fields are kept in sorted order (kind, tag, x, y): the parent's child
    -- reference and the proxy's entry point at the same rebuilt copy.
    assert.are.equal(optionalNode, newPoint.fieldNodes[4])
    assert.is_true(schema:Check({ { x = 1, kind = "b" } }))
    local _, again = schema:Check({ { x = -1, kind = "a" } })
    assert.are.equal(failure, again)
    assert.are.equal("[1].x", again.path)
    local ok, applied = schema:Apply({ { x = 1, kind = "a" } })
    assert.is_true(ok)
    assert.is_false(applied[1].y)
    assert.are.same(before, schema:Describe())
    assert.is_true(other:Check({ a = { x = 0, kind = "b" } }))
    assert.is_true(other:Check(true))
    assert.is_false((other:Check({ a = { x = -1, kind = "b" } })))

    -- A node built before the upgrade composes with one built after it.
    local line = current:Seal(current.table({ fields = { from = point } }))
    assert.is_true(line:Check({ from = { x = 2, kind = "a" } }))
    assert.is_false((line:Check({ from = { x = "no", kind = "a" } })))
  end)
end)
