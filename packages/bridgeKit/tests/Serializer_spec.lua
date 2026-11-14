-- BridgeKit's AceSerializer-3.0 writer and reader beyond the recorded
-- fixtures: round trips, number edges, every refusal, the limits as the
-- serializer applies them, hostile input, secret values and argument errors.
local Env = require("BridgeKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Pack every value with its count.
local function pack(...)
  local packed = { ... }
  packed.n = select("#", ...)
  return packed
end

---Serialise `...` and read the text back, returning the values read.
---@return table values packed, without the leading `true`
local function roundTrip(BridgeKit, ...)
  local ok, text = BridgeKit:AceSerialize(...)
  assert.is_true(ok, tostring(text))
  local results = pack(BridgeKit:AceDeserialize(text))
  assert.is_true(results[1], tostring(results[2]))
  local values = { unpack(results, 2, results.n) }
  values.n = results.n - 1
  return values
end

---A table nested `depth` levels deep: depth 1 is `{}`.
local function nested(depth)
  local root = {}
  local current = root
  for _ = 2, depth do
    current[1] = {}
    current = current[1]
  end
  return root
end

---AceSerializer text of a table nested `depth` levels deep.
local function nestedText(depth)
  return "^1" .. string.rep("^T^N1", depth - 1) .. "^T^t" .. string.rep("^t", depth - 1) .. "^^"
end

describe("BridgeKit AceSerializer", function()
  local BridgeKit
  before_each(function()
    BridgeKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  describe("round trips", function()
    it("keeps every byte of a string", function()
      local bytes = {}
      for byte = 0, 255 do
        bytes[#bytes + 1] = string.char(byte)
      end
      local text = table.concat(bytes)
      assert.are.equal(text, roundTrip(BridgeKit, text)[1])
    end)

    it("keeps the count of values, nils included", function()
      local values = roundTrip(BridgeKit, nil, 1, nil, nil)
      assert.are.equal(4, values.n)
      local expected = { nil, 1, nil, nil }
      expected.n = 4
      assert.are.same(expected, values)
    end)

    it("keeps numbers exactly, at the edges of the double range", function()
      local numbers = {
        0,
        -0.0,
        1,
        -1,
        0.1,
        1 / 3,
        2 ^ 53,
        2 ^ 53 + 2,
        -(2 ^ 53) - 2,
        5e-324,
        2.2250738585072014e-308,
        1.7976931348623157e308,
        -1.7976931348623157e308,
        math.huge,
        -math.huge,
        123456789.123456789,
      }
      for _, number in ipairs(numbers) do
        local read = roundTrip(BridgeKit, number)[1]
        assert.are.equal(number, read)
        if number == 0 then
          assert.are.equal(1 / number, 1 / read)
        end
      end
    end)

    it("keeps random doubles exactly", function()
      math.randomseed(20261115)
      for _ = 1, 500 do
        local number = (math.random() - 0.5) * 2 ^ math.random(-1060, 1020)
        assert.are.equal(number, roundTrip(BridgeKit, number)[1])
      end
    end)

    it("keeps nested tables with every key type", function()
      -- A table holding every kind of key is what is under test.
      -- selene: allow(mixed_table)
      local source = {
        "first",
        [2.5] = { deep = { deeper = true } },
        [true] = false,
        name = "value with ^ and ~ and spaces",
        [-3] = -math.huge,
      }
      assert.are.same(source, roundTrip(BridgeKit, source)[1])
    end)

    it("writes a table referenced twice twice, as Ace does", function()
      local shared = { 1 }
      local values = roundTrip(BridgeKit, { a = shared, b = shared })
      assert.are.same({ a = { 1 }, b = { 1 } }, values[1])
      assert.are_not.equal(values[1].a, values[1].b)
    end)
  end)

  describe("writer refusals", function()
    it("refuses a function, a coroutine and userdata", function()
      assert.are.same({ false, "unsupportedType" }, { BridgeKit:AceSerialize(print) })
      assert.are.same(
        { false, "unsupportedType" },
        { BridgeKit:AceSerialize(coroutine.create(function() end)) }
      )
      assert.are.same({ false, "unsupportedType" }, { BridgeKit:AceSerialize({ newproxy() }) })
    end)

    it("refuses NaN as a value and inside a table", function()
      assert.are.same({ false, "nan" }, { BridgeKit:AceSerialize(0 / 0) })
      assert.are.same({ false, "nan" }, { BridgeKit:AceSerialize({ 0 / 0 }) })
    end)

    it("refuses a cycle, and a table that contains itself", function()
      local cycle = {}
      cycle.self = cycle
      assert.are.same({ false, "cycle" }, { BridgeKit:AceSerialize(cycle) })
      local outer = { inner = {} }
      outer.inner.back = outer
      assert.are.same({ false, "cycle" }, { BridgeKit:AceSerialize(outer) })
    end)

    it("refuses nesting deeper than maxDepth, a top-level table being depth 1", function()
      BridgeKit:SetLimits({ maxDepth = 3 })
      assert.is_true((BridgeKit:AceSerialize(nested(3))))
      assert.are.same({ false, "maxDepth" }, { BridgeKit:AceSerialize(nested(4)) })
    end)

    it("refuses more values than maxValues, keys included", function()
      BridgeKit:SetLimits({ maxValues = 3 })
      -- A table, one key and one value: three.
      assert.is_true((BridgeKit:AceSerialize({ a = 1 })))
      assert.are.same({ false, "maxValues" }, { BridgeKit:AceSerialize({ a = 1 }, 2) })
    end)

    it("refuses a string longer than maxStringLength, counted before escaping", function()
      BridgeKit:SetLimits({ maxStringLength = 4 })
      assert.is_true((BridgeKit:AceSerialize("~~~~")))
      assert.are.same({ false, "maxStringLength" }, { BridgeKit:AceSerialize("12345") })
    end)

    it("refuses text longer than maxTextBytes", function()
      BridgeKit:SetLimits({ maxTextBytes = 10 })
      -- `^1^Sabcd^^` is ten bytes.
      assert.are.same({ true, "^1^Sabcd^^" }, { BridgeKit:AceSerialize("abcd") })
      assert.are.same({ false, "maxTextBytes" }, { BridgeKit:AceSerialize("abcde") })
    end)

    it("refuses at every token that would pass maxTextBytes", function()
      -- `^1^T^t^^` is eight bytes: the start code, the table, its end, the end code.
      for limit = 2, 7 do
        BridgeKit:SetLimits({ maxTextBytes = limit })
        assert.are.same(
          { false, "maxTextBytes" },
          { BridgeKit:AceSerialize({}) },
          "limit " .. limit
        )
      end
      BridgeKit:SetLimits({ maxTextBytes = 8 })
      assert.are.same({ true, "^1^T^t^^" }, { BridgeKit:AceSerialize({}) })
      BridgeKit:SetLimits({ maxTextBytes = 1 })
      assert.are.same({ false, "maxTextBytes" }, { BridgeKit:AceSerialize() })
    end)

    it("lifts maxValues and maxStringLength with UNBOUNDED", function()
      BridgeKit:SetLimits({ maxValues = BridgeKit.UNBOUNDED, maxStringLength = BridgeKit.UNBOUNDED })
      local many = {}
      for index = 1, 40000 do
        many[index] = index
      end
      assert.is_true((BridgeKit:AceSerialize(many)))
      assert.is_true((BridgeKit:AceSerialize(string.rep("x", 70000))))
    end)
  end)

  describe("reader", function()
    it("refuses nesting deeper than maxDepth", function()
      BridgeKit:SetLimits({ maxDepth = 3 })
      assert.is_true((BridgeKit:AceDeserialize(nestedText(3))))
      assert.are.same({ false, "maxDepth" }, { BridgeKit:AceDeserialize(nestedText(4)) })
    end)

    it("refuses more values than maxValues", function()
      BridgeKit:SetLimits({ maxValues = 2 })
      assert.is_true((BridgeKit:AceDeserialize("^1^N1^N2^^")))
      assert.are.same({ false, "maxValues" }, { BridgeKit:AceDeserialize("^1^N1^N2^N3^^") })
    end)

    it("refuses a string longer than maxStringLength once unescaped", function()
      BridgeKit:SetLimits({ maxStringLength = 2 })
      assert.is_true((BridgeKit:AceDeserialize("^1^S~}~|^^")))
      assert.are.same({ false, "maxStringLength" }, { BridgeKit:AceDeserialize("^1^Sabc^^") })
    end)

    it("refuses text longer than maxTextBytes before reading it", function()
      BridgeKit:SetLimits({ maxTextBytes = 8 })
      assert.is_true((BridgeKit:AceDeserialize("^1^N1^^")))
      assert.are.same({ false, "maxTextBytes" }, { BridgeKit:AceDeserialize("^1^N12^^ ") })
    end)

    it("refuses more top-level values than maxListValues", function()
      BridgeKit:SetLimits({ maxListValues = 2 })
      assert.is_true((BridgeKit:AceDeserialize("^1^N1^N2^^")))
      assert.are.same({ false, "maxListValues" }, { BridgeKit:AceDeserialize("^1^N1^N2^N3^^") })
    end)

    it("returns the most values the default maxListValues allows through unpack", function()
      local text = "^1" .. string.rep("^N1", 4096) .. "^^"
      local results = pack(BridgeKit:AceDeserialize(text))
      assert.is_true(results[1])
      assert.are.equal(4097, results.n)
    end)

    it("never raises on any prefix of valid text, and refuses every proper one", function()
      local ok, text =
        BridgeKit:AceSerialize({ a = { 1, 2.5, "~^ x" }, [true] = false }, 1 / 3, "end")
      assert.is_true(ok)
      for length = 0, #text - 1 do
        local prefix = text:sub(1, length)
        local called, result = pcall(BridgeKit.AceDeserialize, BridgeKit, prefix)
        assert.is_true(called, "raised on " .. prefix)
        -- A prefix that cuts the end code leaves the end code half there, or
        -- missing; either way it is not the whole text.
        assert.is_false(result, "accepted " .. prefix)
      end
    end)

    it("never raises on hostile text", function()
      local hostile = {
        string.rep("^T", 100000),
        "^1" .. string.rep("^T", 100000),
        "^1" .. string.rep("^S~", 1000) .. "^^",
        "^1^F" .. string.rep("9", 400) .. "^f99999^^",
        "^1^F1^f-99999^^",
        "^1^N" .. string.rep("9", 400) .. "^^",
        "^1" .. string.rep("^", 1000),
        string.rep("\0", 1000),
        "^1^T^N1^T^N1^T^Z^t^t^t^^",
      }
      for _, text in ipairs(hostile) do
        local called = pcall(BridgeKit.AceDeserialize, BridgeKit, text)
        assert.is_true(called)
      end
    end)

    it("reads back a subnormal number Ace's own reader reads as zero", function()
      -- Written as `^F` because `tostring` does not round-trip it; Ace reads
      -- `mantissa * 2^exponent`, and 2^-1076 alone underflows to zero.
      local subnormal = -9.8166466600146602358e-309
      local ok, text = BridgeKit:AceSerialize(subnormal)
      assert.is_true(ok)
      assert.is_truthy(text:find("^1^F", 1, true))
      assert.are.equal(subnormal, select(2, BridgeKit:AceDeserialize(text)))
    end)

    it("agrees with Ace's arithmetic where the power overflows", function()
      local ok, value = BridgeKit:AceDeserialize("^1^F0^f2000^^")
      assert.is_true(ok)
      assert.is_true(value ~= value, "0 * 2^2000 is NaN, as in Ace")
      assert.are.same({ true, math.huge }, { BridgeKit:AceDeserialize("^1^F0.5^f1024^^") })
      -- So a key that reads as NaN that way is refused, as Ace refuses it.
      assert.are.same({ false, "invalidKey" }, { BridgeKit:AceDeserialize("^1^T^F0^f2000^B^t^^") })
    end)

    it("computes a non-integer exponent, which no writer produces, as Ace does", function()
      assert.are.same({ true, 2 ^ 0.5 }, { BridgeKit:AceDeserialize("^1^F1^f0.5^^") })
    end)

    it("reads huge exponents as infinity and tiny ones as zero", function()
      assert.are.same({ true, math.huge }, { BridgeKit:AceDeserialize("^1^F1^f99999^^") })
      assert.are.same({ true, 0 }, { BridgeKit:AceDeserialize("^1^F1^f-99999^^") })
    end)
  end)

  describe("secret values and argument errors", function()
    it("raises at the caller for a secret value anywhere in the arguments", function()
      local secret = {}
      Env.MarkSecret(secret)
      local line
      local ok, failure = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        BridgeKit:AceSerialize(1, { nested = { secret } })
      end)
      assert.is_false(ok)
      assert.are.equal(
        SOURCE .. ":" .. line .. ": BridgeKit:AceSerialize value must not contain a secret value",
        failure
      )
    end)

    it("raises at the caller for a secret table key", function()
      local secretKey = {}
      Env.MarkSecret(secretKey)
      local ok, failure = pcall(function()
        BridgeKit:AceSerialize({ [secretKey] = 1 })
      end)
      assert.is_false(ok)
      assert.is_truthy(failure:find("must not contain a secret value", 1, true))
    end)

    it("raises at the caller for a secret or non-string text", function()
      local secret = "^1^Sx^^"
      Env.MarkSecret(secret)
      local line
      local ok, failure = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        BridgeKit:AceDeserialize(secret)
      end)
      assert.is_false(ok)
      assert.are.equal(
        SOURCE .. ":" .. line .. ": BridgeKit:AceDeserialize text must not be a secret value",
        failure
      )
      ok, failure = pcall(function()
        BridgeKit:AceDeserialize(42)
      end)
      assert.is_false(ok)
      assert.is_truthy(failure:find("BridgeKit:AceDeserialize text must be a string", 1, true))
    end)

    it("raises at the caller for a dot call", function()
      local line
      local ok, failure = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        BridgeKit.AceSerialize("x")
      end)
      assert.is_false(ok)
      assert.are.equal(
        SOURCE
          .. ":"
          .. line
          .. ": BridgeKit:AceSerialize must be called on the BridgeKit facade; use BridgeKit:AceSerialize(...)",
        failure
      )
    end)
  end)

  describe("on a client whose tostring writes infinity as 1.#INF", function()
    local nativeToString = tostring
    before_each(function()
      Env.Reset()
      -- The Windows C runtime spells infinity this way; BridgeKit reads
      -- `tostring` once at load, so the stand-in goes in before it loads.
      -- selene: allow(global_usage)
      rawset(_G, "tostring", function(value)
        if value == math.huge then
          return "1.#INF"
        elseif value == -math.huge then
          return "-1.#INF"
        end
        return nativeToString(value)
      end)
      BridgeKit = Env.NewPackage()
    end)
    after_each(function()
      -- selene: allow(global_usage)
      rawset(_G, "tostring", nativeToString)
    end)

    it("writes Ace's own infinity spelling, which reads back", function()
      assert.are.same(
        { true, "^1^N1.#INF^N-1.#INF^^" },
        { BridgeKit:AceSerialize(math.huge, -math.huge) }
      )
      assert.are.same(
        { true, math.huge, -math.huge },
        { BridgeKit:AceDeserialize("^1^N1.#INF^N-1.#INF^^") }
      )
    end)
  end)
end)
