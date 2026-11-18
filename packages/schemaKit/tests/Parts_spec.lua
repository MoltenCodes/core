local TestEnv = require("SchemaKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local RULES_MISSING = "is in SchemaKit's Rules part, which is not loaded: "
  .. "add schemaKit\\parts\\SchemaKit-Rules.lua"
local APPLY_MISSING = "is in SchemaKit's Apply part, which is not loaded: "
  .. "add schemaKit\\parts\\SchemaKit-Apply.lua"

describe("SchemaKit parts", function()
  after_each(TestEnv.Reset)

  describe("without the Rules part", function()
    it(
      "raises the not-loaded message at the caller's line for custom, oneOf and a pattern",
      function()
        local S = TestEnv.NewCore()
        local line
        local ok, failure = pcall(function()
          line = currentLine() + 1
          S.custom(function()
            return true
          end, "anything")
        end)
        assertReportedAt(line, "SchemaKit.custom " .. RULES_MISSING, ok, failure)

        ok, failure = pcall(function()
          line = currentLine() + 1
          S.oneOf({ S.number(), S.boolean() })
        end)
        assertReportedAt(line, "SchemaKit.oneOf " .. RULES_MISSING, ok, failure)

        ok, failure = pcall(function()
          line = currentLine() + 1
          S.string({ pattern = "^%a+$" })
        end)
        assertReportedAt(line, "SchemaKit.string pattern " .. RULES_MISSING, ok, failure)
      end
    )

    it("builds and checks every other kind", function()
      local S = TestEnv.NewCore()
      local schema = S:Seal(S.table({
        fields = {
          name = S.string({ max = 8, oneOf = { "a", "b" } }),
          count = S.optional(S.number({ integer = true }), 1),
          list = S.array({ of = S.boolean() }),
          map = S.map({ keys = S.string(), values = S.any(), max = 2 }),
          kind = S.enum({ 1, 2 }),
        },
      }))
      assert.is_true(schema:Check({ name = "a", list = {}, map = {}, kind = 1 }))
      local ok, failure = schema:Check({ name = "c", list = {}, map = {}, kind = 1 })
      assert.is_false(ok)
      assert.are.equal("name", failure.path)
    end)
  end)

  describe("without the Apply part", function()
    it("raises the not-loaded message at the caller's line and still names a dot call", function()
      local S = TestEnv.NewCore()
      local schema = S:Seal(S.optional(S.number(), 1))
      local line
      local ok, failure = pcall(function()
        line = currentLine() + 1
        schema:Apply(nil)
      end)
      assertReportedAt(line, "SchemaKit.Schema:Apply " .. APPLY_MISSING, ok, failure)

      ok, failure = pcall(function()
        line = currentLine() + 1
        schema.Apply({}, nil)
      end)
      assertReportedAt(
        line,
        "SchemaKit.Schema:Apply must be called on a sealed SchemaKit schema",
        ok,
        failure
      )
    end)
  end)

  it("answers HasPart without raising, and refuses a name that is not a string", function()
    local S = TestEnv.NewCore()
    assert.is_false(S:HasPart("Rules"))
    assert.is_false(S:HasPart("Apply"))
    assert.is_false(S:HasPart("Unknown"))
    TestEnv.LoadPart("Rules")
    assert.is_true(S:HasPart("Rules"))
    assert.is_false(S:HasPart("Apply"))
    TestEnv.LoadPart("Apply")
    assert.is_true(S:HasPart("Apply"))

    local line
    local ok, failure = pcall(function()
      line = currentLine() + 1
      S:HasPart(1)
    end)
    assertReportedAt(line, "SchemaKit:HasPart partName must be a string", ok, failure)
    ok, failure = pcall(function()
      line = currentLine() + 1
      S.HasPart("Rules")
    end)
    assertReportedAt(line, "SchemaKit:HasPart is called with a colon, not a dot", ok, failure)

    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe({ [secret] = true })
    ok, failure = pcall(function()
      line = currentLine() + 1
      S:HasPart(secret)
    end)
    assertReportedAt(line, "SchemaKit:HasPart partName must not be a secret value", ok, failure)
  end)

  it("installs a part's members once it loads", function()
    local S = TestEnv.NewCore()
    TestEnv.LoadPart("Rules")
    TestEnv.LoadPart("Apply")
    local schema = S:Seal(S.optional(
      S.table({
        fields = {
          tag = S.optional(S.string({ pattern = "^%a+$" }), "x"),
          even = S.optional(S.custom(function(value)
            return type(value) == "number" and value % 2 == 0
          end, "even number")),
          either = S.optional(S.oneOf({ S.number(), S.boolean() })),
        },
      }),
      {}
    ))
    local ok, applied = schema:Apply(nil)
    assert.is_true(ok)
    assert.are.same({ tag = "x" }, applied)
    local _, failure = schema:Check({ even = 3 })
    assert.are.equal("custom", failure.rule)
  end)

  it("checks nodes built with the parts in a core loaded after them", function()
    local S = TestEnv.NewPackage()
    local schema = S:Seal(S.table({
      fields = {
        tag = S.string({ pattern = "^%a+$" }),
        even = S.custom(function(value)
          return type(value) == "number" and value % 2 == 0
        end, "even number"),
        either = S.oneOf({ S.number(), S.boolean() }),
      },
    }))
    -- A newer core over the same state: its file holds no part code, and its
    -- checker still reads every kind.
    local newer = TestEnv.LoadRevision(S.REVISION + 1)
    assert.are.equal(S, newer)
    assert.is_true(schema:Check({ tag = "abc", even = 2, either = true }))
    local _, failure = schema:Check({ tag = "a1", even = 2, either = true })
    assert.are.equal("tag", failure.path)
    assert.are.equal("pattern", failure.rule)
    _, failure = schema:Check({ tag = "a", even = 3, either = true })
    assert.are.equal("custom", failure.rule)
    _, failure = schema:Check({ tag = "a", even = 2, either = "no" })
    assert.are.equal("oneOf", failure.rule)
    -- The parts' members survive the newer core's commit.
    assert.is_true(newer:HasPart("Rules"))
    assert.is_true(newer
      :Seal(newer.custom(function()
        return true
      end, "anything"))
      :Check(1))
    assert.is_true((newer:Seal(newer.optional(newer.number(), 4)):Apply(nil)))
  end)

  it("refuses to load a part without the core", function()
    TestEnv.Reset()
    require("Registry")
    for _, partName in ipairs({ "Rules", "Apply" }) do
      local ok, failure = pcall(TestEnv.LoadPart, partName)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          "MoltenCodes SchemaKit part "
            .. partName
            .. " requires SchemaKit API 1 to be loaded first",
          1,
          true
        )
      )
    end
  end)

  it("keeps an installed part when the same part file runs again", function()
    local S = TestEnv.NewPackage()
    local custom = S.custom
    TestEnv.LoadPart("Rules")
    assert.are.equal(custom, S.custom)
  end)

  describe("an in-place upgrade from revision 6", function()
    it("keeps revision 6's builders and Apply while the parts are absent", function()
      TestEnv.Reset()
      require("Registry")
      local previous = TestEnv.LoadRevision6()
      local oldString, oldCustom = previous.string, previous.custom
      local oldOneOf, oldApply = previous.oneOf, previous.Schema.Apply
      local tagged = previous:Seal(previous.string({ pattern = "^%a+$" }))

      local current = require("SchemaKit")
      assert.are.equal(previous, current)
      assert.are.equal(7, current.REVISION)
      assert.are.equal(oldString, current.string)
      assert.are.equal(oldCustom, current.custom)
      assert.are.equal(oldOneOf, current.oneOf)
      assert.are.equal(oldApply, current.Schema.Apply)
      assert.is_false(current:HasPart("Rules"))

      -- Revision 6's builders make nodes the revision 7 checker reads.
      local schema = current:Seal(current.optional(
        current.table({
          fields = {
            tag = current.optional(current.string({ pattern = "^%d+$" }), "1"),
            either = current.optional(current.oneOf({ current.number(), current.boolean() })),
            even = current.optional(current.custom(function(value)
              return value % 2 == 0
            end, "even number")),
          },
        }),
        {}
      ))
      assert.is_true(schema:Check({ tag = "12", either = 1, even = 2 }))
      assert.is_false((schema:Check({ tag = "x" })))
      assert.is_false((tagged:Check("a1")))
      local ok, applied = schema:Apply(nil)
      assert.is_true(ok)
      assert.are.same({ tag = "1" }, applied)
    end)

    it("hands over to the parts once they load", function()
      TestEnv.Reset()
      require("Registry")
      local previous = TestEnv.LoadRevision6()
      local oldString, oldCustom = previous.string, previous.custom
      local oldApply = previous.Schema.Apply
      local current = require("SchemaKit")
      assert.are.equal(oldString, current.string)

      TestEnv.LoadPart("Rules")
      assert.are_not.equal(oldString, current.string)
      assert.are_not.equal(oldCustom, current.custom)
      assert.are.equal(oldApply, current.Schema.Apply)
      assert.is_not_nil(current._state.legacyMembers)

      TestEnv.LoadPart("Apply")
      assert.are_not.equal(oldApply, current.Schema.Apply)
      assert.is_nil(current._state.legacyMembers)
      local schema = current:Seal(current.optional(current.string({ pattern = "^%a$" }), "a"))
      local ok, applied = schema:Apply(nil)
      assert.is_true(ok)
      assert.are.equal("a", applied)
    end)

    it("cannot serve a revision 6 copy loaded after revision 7 without the parts", function()
      -- The documented limit: the older copy yields to the loaded core, so its
      -- addon reaches the stubs until some addon embeds the parts.
      local S = TestEnv.NewCore()
      local yielded = TestEnv.LoadRevision6()
      assert.are.equal(S, yielded)
      assert.are.equal(7, yielded.REVISION)
      local ok, failure = pcall(yielded.custom, function()
        return true
      end, "anything")
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find(RULES_MISSING, 1, true))
      TestEnv.LoadPart("Rules")
      assert.is_true(yielded
        :Seal(yielded.custom(function()
          return true
        end, "anything"))
        :Check(1))
    end)
  end)
end)
