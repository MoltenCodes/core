local TestEnv = require("TestKitTestEnv")

---Return the part of a failure message after its `file:line: ` prefix.
---@param message string
---@return string
local function withoutPosition(message)
  return (message:gsub("^[^:]+:%d+: ", ""))
end

describe("TestKit matchers", function()
  local TestKit
  before_each(function()
    TestKit = TestEnv.NewReadyPackage("MyAddon")
  end)
  after_each(TestEnv.Reset)

  ---Run `body` as a test and return its failure message, or nil when it passed.
  ---@param body fun(ctx: table)
  ---@return string?
  local function failureOf(body)
    local result = TestEnv.RunOne(TestKit, body)
    if result.status == "passed" then
      return nil
    end
    return withoutPosition(result.message)
  end

  it("passes every matcher that holds", function()
    assert.is_nil(failureOf(function(ctx)
      local shared = {}
      ctx:Expect(shared):ToBe(shared)
      ctx:Expect({ a = { 1, 2 } }):ToEqual({ a = { 1, 2 } })
      ctx:Expect(0):ToBeTruthy()
      ctx:Expect(""):ToBeTruthy()
      ctx:Expect(nil):ToBeNil()
      ctx
        :Expect(function()
          error("boom")
        end)
        :ToRaise()
      ctx
        :Expect(function()
          error("code 42")
        end)
        :ToRaise("code %d+")
    end))
  end)

  it("passes every negated matcher that holds", function()
    assert.is_nil(failureOf(function(ctx)
      ctx:Expect({}).Not:ToBe({})
      ctx:Expect({ 1 }).Not:ToEqual({ 2 })
      ctx:Expect(false).Not:ToBeTruthy()
      ctx:Expect(nil).Not:ToBeTruthy()
      ctx:Expect(0).Not:ToBeNil()
      ctx:Expect(function() end).Not:ToRaise()
      ctx
        :Expect(function()
          error("other")
        end).Not
        :ToRaise("code")
    end))
  end)

  it("describes a ToBe failure by type and value", function()
    assert.are.equal(
      "expected number 1 to be number 2",
      failureOf(function(ctx)
        ctx:Expect(1):ToBe(2)
      end)
    )
    assert.are.equal(
      'expected string "a" not to be string "a"',
      failureOf(function(ctx)
        ctx:Expect("a").Not:ToBe("a")
      end)
    )
    assert.are.equal(
      "expected table to be table",
      failureOf(function(ctx)
        ctx:Expect({}):ToBe({})
      end)
    )
  end)

  it("names the path of the first difference in ToEqual", function()
    assert.are.equal(
      'expected table to equal table (at .items[2].name: string "b" where string "c" was expected)',
      failureOf(function(ctx)
        ctx
          :Expect({ items = { { name = "a" }, { name = "b" } } })
          :ToEqual({ items = { { name = "a" }, { name = "c" } } })
      end)
    )
    assert.are.equal(
      "expected table to equal table (at .missing: nil where number 1 was expected)",
      failureOf(function(ctx)
        ctx:Expect({}):ToEqual({ missing = 1 })
      end)
    )
    assert.are.equal(
      'expected number 1 to equal string "1" (number 1 where string "1" was expected)',
      failureOf(function(ctx)
        ctx:Expect(1):ToEqual("1")
      end)
    )
  end)

  it("stops ToEqual at 16 levels, which also ends a cycle", function()
    local cycle = {}
    cycle.self = cycle
    local other = {}
    other.self = other
    local message = failureOf(function(ctx)
      ctx:Expect(cycle):ToEqual(other)
    end)
    assert.is_truthy(message:find("tables nested deeper than 16 levels", 1, true))

    local deep, deepCopy = {}, {}
    local left, right = deep, deepCopy
    for _ = 1, 15 do
      left.next, right.next = {}, {}
      left, right = left.next, right.next
    end
    assert.is_nil(failureOf(function(ctx)
      ctx:Expect(deep):ToEqual(deepCopy)
    end))
  end)

  it("ignores metatables in ToEqual", function()
    assert.is_nil(failureOf(function(ctx)
      local withMeta = setmetatable({ a = 1 }, {
        __index = function()
          return "invented"
        end,
      })
      ctx:Expect(withMeta):ToEqual({ a = 1 })
    end))
  end)

  it("describes ToBeTruthy and ToBeNil failures", function()
    assert.are.equal(
      "expected boolean false to be truthy",
      failureOf(function(ctx)
        ctx:Expect(false):ToBeTruthy()
      end)
    )
    assert.are.equal(
      "expected number 0 to be nil",
      failureOf(function(ctx)
        ctx:Expect(0):ToBeNil()
      end)
    )
    assert.are.equal(
      "expected nil not to be nil",
      failureOf(function(ctx)
        ctx:Expect(nil).Not:ToBeNil()
      end)
    )
  end)

  it("describes ToRaise failures, with and without a pattern", function()
    assert.are.equal(
      "expected function to raise (it returned normally)",
      failureOf(function(ctx)
        ctx:Expect(function() end):ToRaise()
      end)
    )
    local mismatch = failureOf(function(ctx)
      ctx
        :Expect(function()
          error("wrong", 0)
        end)
        :ToRaise("right")
    end)
    assert.are.equal(
      'expected function to raise an error matching "right" (it raised string "wrong")',
      mismatch
    )
    local negated = failureOf(function(ctx)
      ctx
        :Expect(function()
          error("code 7", 0)
        end).Not
        :ToRaise("code")
    end)
    assert.are.equal(
      'expected function not to raise an error matching "code" (it raised string "code 7")',
      negated
    )
    assert.are.equal(
      'expected function to raise an error matching "x" (it raised table)',
      failureOf(function(ctx)
        ctx
          :Expect(function()
            error({})
          end)
          :ToRaise("x")
      end)
    )
  end)

  it("refuses ToRaise on something that is not a function, even negated", function()
    assert.are.equal(
      "expected number 1: ToRaise needs a function",
      failureOf(function(ctx)
        ctx:Expect(1).Not:ToRaise()
      end)
    )
  end)

  it("asserts taint with issecurevariable in ToBeSecure", function()
    local asked = {}
    TestEnv.SetGlobal("issecurevariable", function(first, second)
      asked[#asked + 1] = { first, second }
      if second == nil then
        return first == "CreateFrame", "SomeAddon"
      end
      return second == "clean", "SomeAddon"
    end)
    local frame = {}

    assert.is_nil(failureOf(function(ctx)
      ctx:Expect(nil):ToBeSecure(nil, "CreateFrame")
      ctx:Expect(nil):ToBeSecure(frame, "clean")
      ctx:Expect(nil).Not:ToBeSecure(frame, "dirty")
    end))
    assert.are.same({ { "CreateFrame", nil }, { frame, "clean" }, { frame, "dirty" } }, asked)

    assert.are.equal(
      'expected field "dirty" to be secure (tainted by string "SomeAddon")',
      failureOf(function(ctx)
        ctx:Expect(nil):ToBeSecure(frame, "dirty")
      end)
    )
    assert.are.equal(
      'expected global "CreateFrame" not to be secure',
      failureOf(function(ctx)
        ctx:Expect(nil).Not:ToBeSecure(nil, "CreateFrame")
      end)
    )
  end)

  it("refuses ToBeSecure on a host without issecurevariable, even negated", function()
    assert.are.equal(
      'expected global "CreateFrame": issecurevariable is not available on this host',
      failureOf(function(ctx)
        ctx:Expect(nil).Not:ToBeSecure(nil, "CreateFrame")
      end)
    )
  end)

  it("fails with ctx:Fail and a default message", function()
    assert.are.equal(
      "failed",
      failureOf(function(ctx)
        ctx:Fail()
      end)
    )
    assert.are.equal(
      "error object: table",
      failureOf(function(ctx)
        ctx:Fail({})
      end)
    )
  end)

  it("describes an error object that is not a string", function()
    local result = TestEnv.RunOne(TestKit, function()
      error({ code = 1 })
    end)
    assert.are.equal("error object: table", result.message)
    result = TestEnv.RunOne(TestKit, function()
      error(false)
    end)
    assert.are.equal("error object: boolean false", result.message)
  end)
end)
