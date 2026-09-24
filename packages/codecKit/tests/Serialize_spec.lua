local TestEnv = require("CodecKitTestEnv")

describe("CodecKit serialisation", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---Serialise, deserialise and compare with `TestEnv.Same`.
  local function roundTrip(value)
    local ok, bytes = CodecKit:Serialize(value)
    assert.is_true(ok, tostring(bytes))
    local decoded, back = CodecKit:Deserialize(bytes)
    assert.is_true(decoded, tostring(back))
    assert.is_true(TestEnv.Same(value, back), "round trip changed " .. tostring(value))
    return bytes
  end

  local zero = 0
  local negativeZero = -zero
  local nan = math.huge - math.huge

  it("writes the documented bytes for every scalar kind", function()
    local cases = {
      { nil, "01" },
      { false, "02" },
      { true, "03" },
      { 0, "0400" },
      { 1, "0401" },
      { 127, "047f" },
      { 128, "048001" },
      { 300, "04ac02" },
      { -1, "0501" },
      { -300, "05ac02" },
      { 2 ^ 53, "048080808080808010" },
      { -(2 ^ 53), "058080808080808010" },
      { 1.5, "063ff8000000000000" },
      { -2.5, "06c004000000000000" },
      { math.huge, "067ff0000000000000" },
      { -math.huge, "06fff0000000000000" },
      { nan, "067ff8000000000000" },
      { negativeZero, "068000000000000000" },
      { 2 ^ -1074, "060000000000000001" },
      { "", "0700" },
      { "hi", "07026869" },
    }
    for index = 1, #cases do
      local ok, bytes = CodecKit:Serialize(cases[index][1])
      assert.is_true(ok)
      assert.are.equal(cases[index][2], TestEnv.Hex(bytes), "case " .. index)
    end
  end)

  it("round-trips booleans, nil and integers of every size", function()
    local values = {
      true,
      false,
      0,
      1,
      -1,
      127,
      128,
      16383,
      16384,
      2 ^ 31,
      2 ^ 32 + 1,
      2 ^ 53 - 1,
      2 ^ 53,
      -(2 ^ 53),
    }
    for index = 1, #values do
      roundTrip(values[index])
    end
    assert.are.equal("01", TestEnv.Hex(roundTrip(nil)))
  end)

  it("round-trips integers past 2^53 exactly as doubles", function()
    for _, value in ipairs({ 2 ^ 53 + 2, 2 ^ 60, -(2 ^ 63), 2 ^ 64, 1e300, -1e300 }) do
      local bytes = roundTrip(value)
      assert.are.equal(6, bytes:byte(1))
    end
  end)

  it("round-trips floats that do not survive tostring", function()
    local values = { 0.1, 1 / 3, math.pi, 2 / 3, 1e-310, 123456789.123456789, 0.1 + 0.2 }
    for index = 1, #values do
      local value = values[index]
      roundTrip(value)
    end
    assert.are_not.equal(0.1 + 0.2, tonumber(tostring(0.1 + 0.2)))
  end)

  it("round-trips the IEEE-754 edges", function()
    local largestSubnormal = 2 ^ -1022 - 2 ^ -1074
    local edges = {
      math.huge,
      -math.huge,
      nan,
      negativeZero,
      2 ^ -1074,
      -(2 ^ -1074),
      largestSubnormal,
      2 ^ -1022,
      1.7976931348623157e308,
      -1.7976931348623157e308,
      2 ^ 1023,
    }
    for index = 1, #edges do
      roundTrip(edges[index])
    end
    local _, bytes = CodecKit:Serialize(largestSubnormal)
    assert.are.equal("06000fffffffffffff", TestEnv.Hex(bytes))
    local _, back = CodecKit:Deserialize(TestEnv.Unhex("068000000000000000"))
    assert.are.equal(-math.huge, 1 / back)
  end)

  it("round-trips strings with every byte, the escape byte and pipes", function()
    local all = {}
    for value = 0, 255 do
      all[#all + 1] = string.char(value)
    end
    local values = {
      "",
      "\0",
      "\255",
      "|",
      "||cffff0000red|r",
      "\n\r\t",
      table.concat(all),
      string.rep("x", 65536),
    }
    for index = 1, #values do
      roundTrip(values[index])
    end
  end)

  it("chooses the array, map and mixed layouts", function()
    assert.are.equal("0800", TestEnv.Hex(roundTrip({})))
    assert.are.equal("080204010402", TestEnv.Hex(roundTrip({ 1, 2 })))
    assert.are.equal("090107016103", TestEnv.Hex(roundTrip({ a = true })))
    -- Mixed tables are the layout under test.
    -- selene: allow(mixed_table)
    assert.are.equal("0a010401010701780402", TestEnv.Hex(roundTrip({ 1, x = 2 })))
  end)

  it("round-trips nested, mixed and sparse tables", function()
    -- Mixed tables are the layout under test.
    -- selene: allow(mixed_table)
    roundTrip({ 1, 2, 3, { 4, 5, { 6 } }, name = "bar", flags = { a = true, b = false } })
    roundTrip({ [1] = "a", [2] = "b", [4] = "d", [10] = "j" })
    roundTrip({ [0] = "zero", [-1] = "minus", [1.5] = "half", [2 ^ 60] = "big" })
    roundTrip({ [true] = 1, [false] = 0 })
    roundTrip({ [{ 1, 2 }] = "table key", [{ k = "v" }] = { nested = true } })
    roundTrip({ { {}, {} }, {}, { {} } })
  end)

  it("reads a hole as the end of the array part", function()
    local value = { 1, 2 }
    value[4] = 4
    local bytes = roundTrip(value)
    assert.are.equal(10, bytes:byte(1))
  end)

  it("duplicates a table referenced twice instead of preserving sharing", function()
    local shared = { 1 }
    local ok, bytes = CodecKit:Serialize({ shared, shared })
    assert.is_true(ok)
    local _, back = CodecKit:Deserialize(bytes)
    assert.are.same({ { 1 }, { 1 } }, back)
    assert.are_not.equal(back[1], back[2])
  end)

  it("ignores metatables and reads raw contents", function()
    local value = setmetatable({ 1 }, {
      __index = function()
        error("metamethod ran")
      end,
      __len = function()
        error("metamethod ran")
      end,
    })
    local ok, bytes = CodecKit:Serialize(value)
    assert.is_true(ok)
    local _, back = CodecKit:Deserialize(bytes)
    assert.are.same({ 1 }, back)
    assert.is_nil(getmetatable(back))
  end)

  it("refuses functions, userdata and threads anywhere", function()
    local values = {
      print,
      coroutine.create(function() end),
      newproxy and newproxy() or io.stdout,
      { 1, print },
      { key = print },
      { [print] = true },
    }
    for index = 1, #values do
      local ok, reason = CodecKit:Serialize(values[index])
      assert.is_false(ok)
      assert.are.equal("unsupportedType", reason)
    end
  end)

  it("refuses cycles at every distance", function()
    local selfCycle = {}
    selfCycle.me = selfCycle
    local long = { { { {} } } }
    long[1][1][1][1] = long
    local keyCycle = {}
    keyCycle[keyCycle] = true
    for _, value in ipairs({ selfCycle, long, keyCycle }) do
      local ok, reason = CodecKit:Serialize(value)
      assert.is_false(ok)
      assert.are.equal("cycle", reason)
    end
  end)
end)
