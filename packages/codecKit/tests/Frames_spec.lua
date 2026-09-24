local TestEnv = require("CodecKitTestEnv")

describe("CodecKit frames", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local sample = {
    name = "Main bar",
    scale = 1.25,
    enabled = true,
    buttons = { 1, 2, 3, 5, 8, 13 },
    colors = { red = { 1, 0, 0, 1 }, text = "||cffff0000" },
    [2 ^ 60] = "large key",
  }

  it("writes the version byte and the stage flags", function()
    local cases = {
      { nil, "\1\1\3" },
      { { channel = "addon" }, "\1\5\3" },
      { { compress = "none", channel = "none" }, "\1\1\3" },
    }
    for index = 1, #cases do
      local ok, text = CodecKit:Encode(true, cases[index][1])
      assert.is_true(ok)
      assert.are.equal(cases[index][2], text)
    end
    local ok, text = CodecKit:Encode(true, { compress = "deflate" })
    assert.is_true(ok)
    assert.are.equal("\1\3", text:sub(1, 2))
    local _, deflated = CodecKit:Compress("\3")
    assert.are.equal(deflated, text:sub(3))
    ok, text = CodecKit:Encode(true, { compress = "deflate", channel = "addon" })
    assert.is_true(ok)
    assert.are.equal("\1\7", text:sub(1, 2))
  end)

  it("print-encodes the whole frame, header included", function()
    local ok, text = CodecKit:Encode(true, { channel = "print" })
    assert.is_true(ok)
    local _, expected = CodecKit:EncodeForPrint("\1\9\3")
    assert.are.equal(expected, text)
    assert.are.equal("!", text:sub(1, 1))
    ok, text = CodecKit:Encode(sample, { compress = "deflate", channel = "print" })
    assert.is_true(ok)
    local _, frame = CodecKit:DecodeForPrint(text)
    assert.are.equal("\1\11", frame:sub(1, 2))
  end)

  it("round-trips through every combination of stages and levels", function()
    for _, compress in ipairs({ "none", "deflate" }) do
      for _, channel in ipairs({ "none", "addon", "print" }) do
        for _, level in ipairs({ 1, 6, 9 }) do
          local options = { compress = compress, channel = channel, level = level }
          local ok, text = CodecKit:Encode(sample, options)
          assert.is_true(ok, tostring(text))
          local decoded, value = CodecKit:Decode(text)
          assert.is_true(decoded, tostring(value))
          assert.is_true(TestEnv.Same(sample, value))
          decoded, value = CodecKit:Decode(text, { channel = channel })
          assert.is_true(decoded, tostring(value))
        end
      end
    end
  end)

  it("round-trips every scalar through every channel", function()
    local zero = 0
    local values = { true, false, 0, -zero, 1.5, math.huge, "", "\0|\n\255", 2 ^ 70 }
    for _, channel in ipairs({ "none", "addon", "print" }) do
      for index = 1, #values do
        local ok, text = CodecKit:Encode(values[index], { channel = channel, compress = "deflate" })
        assert.is_true(ok)
        local decoded, value = CodecKit:Decode(text)
        assert.is_true(decoded)
        assert.is_true(TestEnv.Same(values[index], value))
      end
      local ok, text = CodecKit:Encode(nil, { channel = channel })
      assert.is_true(ok)
      local decoded, value = CodecKit:Decode(text)
      assert.is_true(decoded)
      assert.is_nil(value)
    end
  end)

  it("refuses a frame made for another channel when a channel is expected", function()
    local _, addon = CodecKit:Encode(1, { channel = "addon" })
    local _, print = CodecKit:Encode(1, { channel = "print" })
    local _, plain = CodecKit:Encode(1)
    local cases = {
      { addon, "print" },
      { addon, "none" },
      { print, "addon" },
      { plain, "addon" },
    }
    for index = 1, #cases do
      local ok, reason = CodecKit:Decode(cases[index][1], { channel = cases[index][2] })
      assert.is_false(ok)
      assert.are.equal("channelMismatch", reason)
    end
  end)

  it("refuses an unknown version", function()
    local cases = { "\2\1\3", "\0\1\3", "\127\1\3", "\128\1\3" }
    for index = 1, #cases do
      local ok, reason = CodecKit:Decode(cases[index])
      assert.is_false(ok)
      assert.are.equal("unsupportedVersion", reason)
    end
    local _, printed = CodecKit:EncodeForPrint("\2\9\3")
    local ok, reason = CodecKit:Decode(printed)
    assert.is_false(ok)
    assert.are.equal("unsupportedVersion", reason)
  end)

  it("refuses reserved, missing and contradictory flags", function()
    local cases = { "\1\17\3", "\1\0\3", "\1\2\3", "\1\13\3", "\1\9\3", "\1" }
    local reasons = {
      "malformedHeader",
      "malformedHeader",
      "malformedHeader",
      "malformedHeader",
      "malformedHeader",
      "truncated",
    }
    for index = 1, #cases do
      local ok, reason = CodecKit:Decode(cases[index])
      assert.is_false(ok)
      assert.are.equal(reasons[index], reason)
    end
    local _, printed = CodecKit:EncodeForPrint("\1\1\3")
    local ok, reason = CodecKit:Decode(printed)
    assert.is_false(ok)
    assert.are.equal("malformedHeader", reason)
  end)

  it("decodes a print frame pasted with wrapping and indentation", function()
    local ok, text = CodecKit:Encode(sample, { compress = "deflate", channel = "print" })
    assert.is_true(ok)
    local wrapped = {}
    for first = 1, #text, 16 do
      wrapped[#wrapped + 1] = "  " .. text:sub(first, first + 15)
    end
    local pasted = "\n" .. table.concat(wrapped, "\r\n\t") .. " \n"
    local decoded, value = CodecKit:Decode(pasted)
    assert.is_true(decoded, tostring(value))
    assert.is_true(TestEnv.Same(sample, value))
  end)

  it("accepts a print frame that starts with any whitespace %s strips", function()
    local _, text = CodecKit:Encode({ 1, 2 }, { channel = "print" })
    for _, prefix in ipairs({ " ", "\t", "\n", "\v", "\f", "\r" }) do
      local ok, value = CodecKit:Decode(prefix .. text)
      assert.is_true(ok, tostring(value))
      assert.are.same({ 1, 2 }, value)
    end
  end)

  it("keeps nil in the middle and at the end of an argument list", function()
    for _, channel in ipairs({ "none", "addon", "print" }) do
      local ok, text = CodecKit:EncodeMany({ channel = channel }, 1, nil, "three", nil, nil)
      assert.is_true(ok)
      local results = { CodecKit:DecodeMany(text) }
      assert.are.equal(6, select("#", CodecKit:DecodeMany(text)))
      assert.is_true(results[1])
      assert.are.equal(1, results[2])
      assert.is_nil(results[3])
      assert.are.equal("three", results[4])
    end
    local ok, text = CodecKit:EncodeMany(nil)
    assert.is_true(ok)
    assert.are.equal(1, select("#", CodecKit:DecodeMany(text)))
    ok, text = CodecKit:EncodeMany(nil, nil)
    assert.is_true(ok)
    assert.are.equal("\1\1\11\1\1", text)
    assert.are.equal(2, select("#", CodecKit:DecodeMany(text)))
  end)

  it("keeps Decode for one value and DecodeMany for lists", function()
    local _, list = CodecKit:EncodeMany(nil, 1, 2)
    local ok, reason = CodecKit:Decode(list)
    assert.is_false(ok)
    assert.are.equal("multipleValues", reason)
    local _, single = CodecKit:Encode({ 1, 2 })
    local decoded, value = CodecKit:DecodeMany(single)
    assert.is_true(decoded)
    assert.are.same({ 1, 2 }, value)
    assert.are.equal(2, select("#", CodecKit:DecodeMany(single)))
  end)

  it("refuses a list nested inside a value", function()
    local ok, reason = CodecKit:Deserialize("\8\1\11\0")
    assert.is_false(ok)
    assert.are.equal("unknownType", reason)
    ok, reason = CodecKit:Deserialize("\11\0")
    assert.is_false(ok)
    assert.are.equal("multipleValues", reason)
  end)

  it("builds the export string of the README example", function()
    local profile = { version = 3, bars = { { id = 1, scale = 1.2 }, { id = 2, scale = 0.8 } } }
    local ok, exportString = CodecKit:Encode(profile, { compress = "deflate", channel = "print" })
    assert.is_true(ok)
    assert.is_nil(exportString:find("[%s\"'`\\|{}%%/]"))
    local imported, value = CodecKit:Decode(exportString, { channel = "print" })
    assert.is_true(imported)
    assert.are.same(profile, value)
  end)
end)
