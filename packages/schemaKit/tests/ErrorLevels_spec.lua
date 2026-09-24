local TestEnv = require("SchemaKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("SchemaKit error levels", function()
  local S
  before_each(function()
    S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points builder errors at the caller", function()
    local cases = {
      {
        "SchemaKit.string min must be a non-negative integer",
        function()
          S.string({ min = -1 })
        end,
      },
      {
        'SchemaKit.string spec contains unknown field "aaa"',
        function()
          S.string({ zzz = 1, aaa = 1 })
        end,
      },
      {
        "SchemaKit.string pattern is not a valid Lua pattern",
        function()
          S.string({ pattern = "%" })
        end,
      },
      {
        "SchemaKit.number min must not be greater than max",
        function()
          S.number({ min = 2, max = 1 })
        end,
      },
      {
        "SchemaKit.boolean is called with a dot, not a colon",
        function()
          S:boolean()
        end,
      },
      {
        "SchemaKit.enum values must not repeat",
        function()
          S.enum({ 1, 1 })
        end,
      },
      {
        "SchemaKit.table fields.x must be a SchemaKit schema node or sealed schema",
        function()
          S.table({ fields = { x = 1 } })
        end,
      },
      {
        "SchemaKit.array max must be a non-negative integer",
        function()
          S.array({ of = S.any(), max = "many" })
        end,
      },
      {
        "SchemaKit.map max is required",
        function()
          S.map({ keys = S.any(), values = S.any() })
        end,
      },
      {
        "SchemaKit.optional default: expected string, found number",
        function()
          S.optional(S.string(), 1)
        end,
      },
      {
        "SchemaKit.oneOf alternatives must be an array",
        function()
          S.oneOf(S.any())
        end,
      },
      {
        "SchemaKit.custom description must be a non-empty string",
        function()
          S.custom(print)
        end,
      },
    }

    for index = 1, #cases do
      local message, action = cases[index][1], cases[index][2]
      local line = debug.getinfo(action, "S").linedefined + 1
      local ok, value = pcall(action)
      assertReportedAt(line, message, ok, value)
    end
  end)

  it("points Seal errors at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      S:Seal("node")
    end)
    assertReportedAt(
      line,
      "SchemaKit:Seal node must be a SchemaKit schema node or sealed schema",
      ok,
      value
    )

    local dotLine
    local dotOk, dotValue = pcall(function()
      dotLine = currentLine() + 1
      S.Seal(S.any())
    end)
    assertReportedAt(dotLine, "SchemaKit:Seal is called with a colon, not a dot", dotOk, dotValue)

    local optionsLine
    local optionsOk, optionsValue = pcall(function()
      optionsLine = currentLine() + 1
      S:Seal(S.any(), { freshFailures = "yes" })
    end)
    assertReportedAt(
      optionsLine,
      "SchemaKit:Seal freshFailures must be a boolean",
      optionsOk,
      optionsValue
    )
  end)

  it("points receiver errors at the caller", function()
    local schema = S:Seal(S.any())
    local methods = { "Check", "Assert", "Apply", "Describe" }
    for index = 1, #methods do
      local name = methods[index]
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        schema[name]({}, 1)
      end)
      assertReportedAt(
        line,
        "SchemaKit.Schema:" .. name .. " must be called on a sealed SchemaKit schema",
        ok,
        value
      )
    end
  end)

  it("points Assert failures at the line that called Assert by default", function()
    local schema = S:Seal(S.table({ fields = { size = S.number({ max = 10 }) } }))
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      schema:Assert({ size = 11 }, "options")
    end)
    assertReportedAt(line, "options.size: expected number <= 10, found larger number", ok, value)

    local rootLine
    local rootOk, rootValue = pcall(function()
      rootLine = currentLine() + 1
      schema:Assert(false)
    end)
    assertReportedAt(rootLine, "value: expected table, found boolean", rootOk, rootValue)

    local indexed = S:Seal(S.array({ of = S.string() }))
    local indexLine
    local indexOk, indexValue = pcall(function()
      indexLine = currentLine() + 1
      indexed:Assert({ "a", 2 }, "names", 1)
    end)
    assertReportedAt(indexLine, "names[2]: expected string, found number", indexOk, indexValue)
  end)

  it("points Assert failures at the caller's caller with level 2", function()
    local schema = S:Seal(S.number())

    -- A Kit's public function validating its own argument.
    local function publicFunction(argument)
      return schema:Assert(argument, "PublicFunction count", 2)
    end

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      publicFunction("three")
    end)
    assertReportedAt(line, "PublicFunction count: expected number, found string", ok, value)
    assert.are.equal(3, publicFunction(3))
  end)

  it("points Assert argument errors at the caller", function()
    local schema = S:Seal(S.any())
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      schema:Assert(1, "", 1)
    end)
    assertReportedAt(
      line,
      "SchemaKit.Schema:Assert argumentName must be a non-empty string",
      ok,
      value
    )

    local levelLine
    local levelOk, levelValue = pcall(function()
      levelLine = currentLine() + 1
      schema:Assert(1, "x", 0)
    end)
    assertReportedAt(
      levelLine,
      "SchemaKit.Schema:Assert level must be a positive integer",
      levelOk,
      levelValue
    )
  end)

  it("points writes to sealed objects at the writing line", function()
    local schema = S:Seal(S.any())
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      schema.extra = 1
    end)
    assertReportedAt(line, "SchemaKit schemas are sealed and cannot be modified", ok, value)

    local node = S.any()
    local nodeLine
    local nodeOk, nodeValue = pcall(function()
      nodeLine = currentLine() + 1
      node.extra = 1
    end)
    assertReportedAt(nodeLine, "SchemaKit schema nodes are immutable", nodeOk, nodeValue)
  end)
end)
