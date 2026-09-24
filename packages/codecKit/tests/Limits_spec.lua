local TestEnv = require("CodecKitTestEnv")

describe("CodecKit limits", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---A table nested `depth` levels deep, the top level counting as one.
  local function nested(depth)
    local root = {}
    local current = root
    for _ = 2, depth do
      local child = {}
      current[1] = child
      current = child
    end
    return root
  end

  it("starts bounded and reports fresh copies", function()
    local limits = CodecKit:GetLimits()
    assert.are.same({
      maxDepth = 16,
      maxValues = 65536,
      maxStringLength = 65536,
      maxOutputBytes = 1048576,
      maxListValues = 4096,
    }, limits)
    limits.maxDepth = 1
    assert.are.equal(16, CodecKit:GetLimits().maxDepth)
    assert.are_not.equal(limits, CodecKit:GetLimits())
  end)

  it("changes any subset and keeps the rest", function()
    CodecKit:SetLimits({ maxDepth = 4 })
    CodecKit:SetLimits({ maxValues = 10, maxOutputBytes = 64 })
    assert.are.same({
      maxDepth = 4,
      maxValues = 10,
      maxStringLength = 65536,
      maxOutputBytes = 64,
      maxListValues = 4096,
    }, CodecKit:GetLimits())
    CodecKit:SetLimits({})
    assert.are.equal(4, CodecKit:GetLimits().maxDepth)
  end)

  it("refuses a value outside a limit's range without changing anything", function()
    local cases = {
      { maxDepth = 0 },
      { maxDepth = 129 },
      { maxValues = 1.5 },
      { maxStringLength = -1 },
      { maxOutputBytes = 2 ^ 31 },
      { maxListValues = 0 },
      { maxListValues = 7901 },
      { maxValues = {} },
      { maxDepth = CodecKit.UNBOUNDED },
      { maxOutputBytes = CodecKit.UNBOUNDED },
      { maxListValues = CodecKit.UNBOUNDED },
      { maxValues = CodecKit.UNBOUNDED, maxDepth = CodecKit.UNBOUNDED },
      { maxDepth = "8" },
      { maxDepth = 8, unknown = 1 },
    }
    for index = 1, #cases do
      assert.has_error(function()
        CodecKit:SetLimits(cases[index])
      end)
    end
    assert.are.same({
      maxDepth = 16,
      maxValues = 65536,
      maxStringLength = 65536,
      maxOutputBytes = 1048576,
      maxListValues = 4096,
    }, CodecKit:GetLimits())
  end)

  it("publishes one UNBOUNDED sentinel table, kept across a reload", function()
    assert.are.equal("table", type(CodecKit.UNBOUNDED))
    assert.are.equal(CodecKit.UNBOUNDED, CodecKit._state.unbounded)
    assert.are.equal(CodecKit.UNBOUNDED, TestEnv.ReloadPackage().UNBOUNDED)
  end)

  it("lifts maxValues and maxStringLength with UNBOUNDED on both sides", function()
    local sentinel = CodecKit.UNBOUNDED
    CodecKit:SetLimits({ maxValues = sentinel, maxStringLength = sentinel })
    local limits = CodecKit:GetLimits()
    assert.are.equal(sentinel, limits.maxValues)
    assert.are.equal(sentinel, limits.maxStringLength)

    local many = {}
    for index = 1, 70000 do
      many[index] = true
    end
    local long = string.rep("x", 70000)
    local ok, bytes = CodecKit:Serialize({ many, long })
    assert.is_true(ok)
    local decodedOk, decoded = CodecKit:Deserialize(bytes)
    assert.is_true(decodedOk)
    assert.are.equal(70000, #decoded[1])
    assert.are.equal(long, decoded[2])

    CodecKit:SetLimits({ maxValues = 65536, maxStringLength = 65536 })
    local refused, reason = CodecKit:Deserialize(bytes)
    assert.is_false(refused)
    assert.are.equal("maxValues", reason)
  end)

  it("still bounds lifted counts and lengths by maxOutputBytes", function()
    CodecKit:SetLimits({
      maxValues = CodecKit.UNBOUNDED,
      maxStringLength = CodecKit.UNBOUNDED,
      maxOutputBytes = 1000,
    })
    local ok, reason = CodecKit:Serialize(string.rep("x", 2000))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    local many = {}
    for index = 1, 2000 do
      many[index] = true
    end
    ok, reason = CodecKit:Serialize(many)
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)

    -- A hostile array claiming 2^40 values: the count cannot fit in the
    -- bytes that remain, whatever maxValues says.
    ok, reason = CodecKit:Deserialize("\8\128\128\128\128\128\32")
    assert.is_false(ok)
    assert.are.equal("truncated", reason)
    ok, reason = CodecKit:Deserialize(string.rep("\1", 1001))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
  end)

  it("bounds nesting depth on both sides", function()
    assert.is_true((CodecKit:Serialize(nested(16))))
    local ok, reason = CodecKit:Serialize(nested(17))
    assert.is_false(ok)
    assert.are.equal("maxDepth", reason)

    CodecKit:SetLimits({ maxDepth = 20 })
    local _, deep = CodecKit:Encode(nested(20))
    CodecKit:SetLimits({ maxDepth = 16 })
    ok, reason = CodecKit:Decode(deep)
    assert.is_false(ok)
    assert.are.equal("maxDepth", reason)
  end)

  it("bounds the value count, keys included, on both sides", function()
    CodecKit:SetLimits({ maxValues = 5 })
    assert.is_true((CodecKit:Serialize({ 1, 2, 3, 4 })))
    local ok, reason = CodecKit:Serialize({ 1, 2, 3, 4, 5 })
    assert.is_false(ok)
    assert.are.equal("maxValues", reason)
    ok, reason = CodecKit:Serialize({ a = 1, b = 2, c = 3 })
    assert.is_false(ok)
    assert.are.equal("maxValues", reason)
    ok, reason = CodecKit:EncodeMany(nil, 1, 2, 3, 4, 5, 6)
    assert.is_false(ok)
    assert.are.equal("maxValues", reason)

    CodecKit:SetLimits({ maxValues = 100 })
    local _, bytes = CodecKit:Serialize({ 1, 2, 3, 4, 5, 6, 7, 8 })
    local _, list = CodecKit:EncodeMany(nil, 1, 2, 3, 4, 5, 6)
    CodecKit:SetLimits({ maxValues = 5 })
    ok, reason = CodecKit:Deserialize(bytes)
    assert.is_false(ok)
    assert.are.equal("maxValues", reason)
    ok, reason = CodecKit:DecodeMany(list)
    assert.is_false(ok)
    assert.are.equal("maxValues", reason)
  end)

  it("bounds single strings, values and keys alike, on both sides", function()
    CodecKit:SetLimits({ maxStringLength = 8 })
    assert.is_true((CodecKit:Serialize(string.rep("x", 8))))
    for _, value in ipairs({
      string.rep("x", 9),
      { string.rep("x", 9) },
      { [string.rep("k", 9)] = 1 },
    }) do
      local ok, reason = CodecKit:Serialize(value)
      assert.is_false(ok)
      assert.are.equal("maxStringLength", reason)
    end
    CodecKit:SetLimits({ maxStringLength = 100 })
    local _, bytes = CodecKit:Serialize(string.rep("x", 9))
    CodecKit:SetLimits({ maxStringLength = 8 })
    local ok, reason = CodecKit:Deserialize(bytes)
    assert.is_false(ok)
    assert.are.equal("maxStringLength", reason)
  end)

  it("bounds the output of every stage", function()
    CodecKit:SetLimits({ maxOutputBytes = 100 })
    local fits = string.rep("x", 90)
    local ok, reason = CodecKit:Serialize(string.rep("x", 99))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok, reason = CodecKit:Serialize({ fits, fits })
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok, reason = CodecKit:EncodeForPrint(fits)
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok, reason = CodecKit:EncodeForAddon(string.rep("|", 60))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok, reason = CodecKit:Encode(string.rep("x", 80), { channel = "print" })
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok, reason = CodecKit:Encode(string.rep("|", 60), { channel = "addon" })
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    assert.is_true((CodecKit:Encode(string.rep("x", 200), { compress = "deflate" }) == false))
    ok, reason = CodecKit:Decode(string.rep("!", 200))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
  end)

  it("bounds print input, whitespace included, before stripping it", function()
    CodecKit:SetLimits({ maxOutputBytes = 100 })
    local ok, reason = CodecKit:DecodeForPrint("!!!!!" .. string.rep(" ", 100))
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
    ok = CodecKit:DecodeForPrint("!!!!!" .. string.rep(" ", 90))
    assert.is_true(ok)
  end)

  it("refuses a decompressed body that outgrows maxOutputBytes", function()
    local _, text = CodecKit:Encode(string.rep("y", 4000), { compress = "deflate" })
    CodecKit:SetLimits({ maxOutputBytes = 1000 })
    local ok, reason = CodecKit:Decode(text)
    assert.is_false(ok)
    assert.are.equal("maxOutputBytes", reason)
  end)

  it("accepts the maxDepth ceiling of 128 on both sides", function()
    CodecKit:SetLimits({ maxDepth = 128 })
    local ok, text = CodecKit:Encode(nested(128), { compress = "deflate" })
    assert.is_true(ok)
    local decodedOk = CodecKit:Decode(text)
    assert.is_true(decodedOk)
  end)

  it("caps an argument list at maxListValues, raised up to 7900", function()
    local entries = {}
    for index = 1, 7901 do
      entries[index] = index
    end
    CodecKit:SetLimits({ maxListValues = 7900 })
    local ok, text = CodecKit:EncodeMany(nil, unpack(entries, 1, 7900))
    assert.is_true(ok)
    assert.are.equal(7901, select("#", CodecKit:DecodeMany(text)))
    local refused, reason = CodecKit:EncodeMany(nil, unpack(entries, 1, 7901))
    assert.is_false(refused)
    assert.are.equal("maxValues", reason)

    CodecKit:SetLimits({ maxListValues = 10 })
    assert.are.equal(10, CodecKit:GetLimits().maxListValues)
    refused, reason = CodecKit:EncodeMany(nil, unpack(entries, 1, 11))
    assert.is_false(refused)
    assert.are.equal("maxValues", reason)
    refused, reason = CodecKit:DecodeMany(text)
    assert.is_false(refused)
    assert.are.equal("maxValues", reason)
  end)

  it("caps an argument list at 4096 entries by default on both sides, without raising", function()
    local entries = {}
    for index = 1, 4097 do
      entries[index] = index
    end
    local ok, text = CodecKit:EncodeMany(nil, unpack(entries, 1, 4096))
    assert.is_true(ok)
    assert.are.equal(4097, select("#", CodecKit:DecodeMany(text)))
    local refused, reason = CodecKit:EncodeMany(nil, unpack(entries, 1, 4097))
    assert.is_false(refused)
    assert.are.equal("maxValues", reason)

    -- A hostile list of 9000 nils fits every other bound, and `unpack`
    -- cannot return that many values in Lua 5.1: the decoder must refuse
    -- it rather than raise. 9000 is the varint 0xA8 0x46.
    CodecKit:SetLimits({ maxValues = CodecKit.UNBOUNDED, maxListValues = 7900 })
    local hostile = "\1\1\11\168\70" .. string.rep("\1", 9000)
    local called, decoded, why = pcall(CodecKit.DecodeMany, CodecKit, hostile)
    assert.is_true(called, tostring(decoded))
    assert.is_false(decoded)
    assert.are.equal("maxValues", why)
  end)

  it("is shared by every consumer of the package", function()
    CodecKit:SetLimits({ maxDepth = 2 })
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(2, reloaded:GetLimits().maxDepth)
    local ok, reason = reloaded:Serialize(nested(3))
    assert.is_false(ok)
    assert.are.equal("maxDepth", reason)
  end)
end)
